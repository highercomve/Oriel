package dev.oriel

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioPlaybackCaptureConfiguration
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.util.Log
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * oriel.audio_capture's "system" source on Android: what other apps play,
 * through AudioPlaybackCapture (Android 10+). Opening it asks the user
 * (MediaProjection's consent dialog, once per projection); the app's
 * foreground service then also has the `mediaProjection` type, which Android
 * 14 requires before the projection can be had. Each stream is an AudioRecord
 * whose mono f32 samples a thread writes into a pipe: Zig reads the other end
 * (src/modules/audio_capture/android.zig), so no JNI on its capture thread.
 *
 * Apps can opt out of being captured (`allowAudioPlaybackCapture`, and the
 * USAGE_VOICE_COMMUNICATION of calls is never captured): those are silent.
 * The projection ends with the last stream, or when the user stops it from
 * the system (the cast indicator): open streams then end (the pipe closes).
 */
internal object OrielSystemAudio {
    private const val TAG = "OrielSystemAudio"
    const val REQ_PROJECTION = 0x4F20

    // NativeLib.onSystemAudio statuses.
    private const val OK = 0
    private const val UNSUPPORTED = 1
    private const val NO_PERMISSION = 2
    private const val DENIED = 3
    private const val FAILED = 4

    private val main = Handler(Looper.getMainLooper())
    private var projection: MediaProjection? = null
    /** Requests waiting for the consent dialog: id -> rate. */
    private val waiting = LinkedHashMap<Long, Int>()
    private val streams = HashMap<Long, Capture>()

    private class Capture(val record: AudioRecord, val out: ParcelFileDescriptor) {
        @Volatile var running = true
        var thread: Thread? = null
    }

    /** Whether this Android can capture other apps' audio at all. */
    fun supported(): Boolean = Build.VERSION.SDK_INT >= 29

    /**
     * Open a stream at `rate` Hz for request `id` (main thread). The answer
     * comes later, in NativeLib.onSystemAudio(id, fd, status).
     */
    fun open(context: Context, from: Activity?, id: Long, rate: Int) {
        if (!supported()) return answer(id, -1, UNSUPPORTED)
        if (context.checkSelfPermission(android.Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED)
            return answer(id, -1, NO_PERMISSION)
        projection?.let { return start(it, id, rate) }
        waiting[id] = rate
        if (waiting.size > 1) return // the dialog is up already
        val activity = from ?: return failWaiting(FAILED, "no window to ask from")
        val mpm = context.getSystemService(MediaProjectionManager::class.java)
        try {
            @Suppress("DEPRECATION")
            activity.startActivityForResult(mpm.createScreenCaptureIntent(), REQ_PROJECTION)
        } catch (e: Exception) {
            Log.e(TAG, "cannot ask for screen capture consent", e)
            failWaiting(FAILED, null)
        }
    }

    /** The consent dialog's answer (OrielActivity.onActivityResult). */
    fun onConsent(context: Context, resultCode: Int, data: Intent?) {
        if (resultCode != Activity.RESULT_OK || data == null) return failWaiting(DENIED, null)
        // Android 14: the service has the mediaProjection type before the
        // projection is taken (OrielAudioService does it, then calls onProjection).
        val intent = Intent(context, OrielAudioService::class.java)
            .putExtra(OrielAudioService.EXTRA_PROJECTION_CODE, resultCode)
            .putExtra(OrielAudioService.EXTRA_PROJECTION_DATA, data)
        try {
            context.startForegroundService(intent)
        } catch (e: Exception) {
            Log.e(TAG, "cannot start the capture service", e)
            failWaiting(FAILED, null)
        }
    }

    /** The service took the projection (or failed to: null). Main thread. */
    fun onProjection(p: MediaProjection?) {
        if (p == null) return failWaiting(FAILED, "no projection")
        projection = p
        p.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() {
                main.post {
                    if (projection === p) projection = null
                    for (c in streams.values.toList()) stopCapture(c)
                    streams.clear()
                    OrielAudioService.projectionEnded()
                }
            }
        }, main)
        val requests = waiting.toList()
        waiting.clear()
        for ((id, rate) in requests) start(p, id, rate)
    }

    private fun start(p: MediaProjection, id: Long, rate: Int) {
        try {
            val config = AudioPlaybackCaptureConfiguration.Builder(p)
                .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
                .addMatchingUsage(AudioAttributes.USAGE_GAME)
                .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
                .build()
            val format = AudioFormat.Builder()
                .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                .setSampleRate(rate)
                .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
                .build()
            val minBytes = AudioRecord.getMinBufferSize(rate, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_FLOAT)
            @Suppress("MissingPermission")
            val record = AudioRecord.Builder()
                .setAudioFormat(format)
                .setBufferSizeInBytes(maxOf(minBytes, rate * 4 / 5)) // ~200 ms
                .setAudioPlaybackCaptureConfig(config)
                .build()
            if (record.state != AudioRecord.STATE_INITIALIZED) {
                record.release()
                return answer(id, -1, FAILED)
            }
            val pipe = ParcelFileDescriptor.createPipe()
            val capture = Capture(record, pipe[1])
            record.startRecording()
            capture.thread = Thread({ pump(capture, rate) }, "oriel-system-audio").apply { start() }
            streams[id] = capture
            answer(id, pipe[0].detachFd(), OK)
        } catch (e: Exception) {
            Log.e(TAG, "cannot capture system audio", e)
            answer(id, -1, FAILED)
            endIfIdle()
        }
    }

    /** AudioRecord -> the pipe, as little-endian f32, until stopped. */
    private fun pump(c: Capture, rate: Int) {
        val samples = FloatArray(maxOf(rate / 20, 256)) // 50 ms
        val bytes = ByteBuffer.allocate(samples.size * 4).order(ByteOrder.LITTLE_ENDIAN)
        try {
            FileOutputStream(c.out.fileDescriptor).use { out ->
                while (c.running) {
                    val n = c.record.read(samples, 0, samples.size, AudioRecord.READ_BLOCKING)
                    if (n < 0) break
                    bytes.clear()
                    bytes.asFloatBuffer().put(samples, 0, n)
                    out.write(bytes.array(), 0, n * 4)
                }
            }
        } catch (_: Exception) {
            // The reader went (EPIPE): the stream is closed.
        } finally {
            // Released here, not by close(): a read may still be in progress there.
            c.record.release()
            try { c.out.close() } catch (_: Exception) {}
        }
    }

    /** Close the stream of request `id` (main thread). */
    fun close(id: Long) {
        waiting.remove(id)
        val c = streams.remove(id) ?: return
        stopCapture(c)
        endIfIdle()
    }

    /** Stop a stream: its read returns, and the pump thread releases it. */
    private fun stopCapture(c: Capture) {
        c.running = false
        try { c.record.stop() } catch (_: Exception) {}
    }

    /** No stream left: the projection (and its indicator) goes. */
    private fun endIfIdle() {
        if (streams.isNotEmpty() || waiting.isNotEmpty()) return
        val p = projection ?: return
        projection = null
        p.stop()
        OrielAudioService.projectionEnded()
    }

    private fun failWaiting(status: Int, why: String?) {
        if (why != null) Log.w(TAG, "system audio: $why")
        val ids = waiting.keys.toList()
        waiting.clear()
        for (id in ids) answer(id, -1, status)
    }

    private fun answer(id: Long, fd: Int, status: Int) {
        try {
            NativeLib.onSystemAudio(id, fd, status)
        } catch (e: UnsatisfiedLinkError) {
            if (fd >= 0) try { ParcelFileDescriptor.adoptFd(fd).close() } catch (_: Exception) {}
        }
    }
}
