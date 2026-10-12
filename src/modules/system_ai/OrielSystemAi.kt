package dev.oriel

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import com.google.mlkit.genai.common.DownloadStatus
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.common.GenAiException
import com.google.mlkit.genai.common.StreamingCallback
import com.google.mlkit.genai.prompt.GenerateContentRequest
import com.google.mlkit.genai.prompt.Generation
import com.google.mlkit.genai.prompt.GenerativeModel
import com.google.mlkit.genai.prompt.ImagePart
import com.google.mlkit.genai.prompt.SystemInstruction
import com.google.mlkit.genai.prompt.TextPart
import com.google.mlkit.genai.prompt.generateContentRequest
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.TimeoutCancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.locks.ReentrantLock

/**
 * oriel.system_ai on Android (src/modules/system_ai.zig): Gemini Nano
 * through ML Kit's GenAI Prompt API (AICore). Oriel's own app extension
 * "oriel.system_ai", added to the project only with -Dsystem_ai.
 *
 * Methods (JSON replies; the wire format is in src/modules/system_ai/core.zig):
 * "status", "capabilities", "download", "generate". Events: "token" (the
 * reply's next piece, UTF-8) and "download" (JSON progress). Failures are
 * [OrielExtensionError]s with the codes core.zig maps: unavailable,
 * not_ready, busy, cancelled, timeout, too_large, invalid_request.
 */
class OrielSystemAi : OrielAppExtension {
    /** One generate or download at a time; status answers meanwhile (two workers). */
    private val lock = ReentrantLock()
    @Volatile private var client: GenerativeModel? = null

    private fun model(): GenerativeModel = synchronized(this) {
        client ?: Generation.getClient().also { client = it }
    }

    override fun call(method: String, input: ByteArray, call: OrielCall): ByteArray {
        if (Looper.myLooper() == Looper.getMainLooper()) throw OrielExtensionError("wrong_thread", "System AI never runs on the UI thread")
        val reply = when (method) {
            "status" -> blocking(call, STATUS_MS) { status() }
            "capabilities" -> blocking(call, STATUS_MS) { capabilities() }
            "download" -> exclusive { blocking(call, DOWNLOAD_MS) { download(call) } }
            "generate" -> exclusive { blocking(call, GENERATE_MS) { generate(input, call) } }
            else -> throw OrielExtensionError("invalid_request", "no method $method")
        }
        return reply.toString().toByteArray(Charsets.UTF_8)
    }

    /** Frees the model on critical memory pressure, unless it's working. */
    override fun onLifecycle(event: String, level: String?) {
        if (event != "memory_pressure" || level != "critical" || !lock.tryLock()) return
        try {
            synchronized(this) {
                client?.close()
                client = null
            }
        } finally {
            lock.unlock()
        }
    }

    private inline fun <T> exclusive(block: () -> T): T {
        if (!lock.tryLock()) throw OrielExtensionError("busy", "System AI is already generating or downloading")
        try {
            return block()
        } finally {
            lock.unlock()
        }
    }

    /**
     * [block] on a coroutine, bounded by [timeoutMs], cancelled when the Zig
     * caller cancels or gives up (polled every [POLL_MS]).
     */
    private fun <T> blocking(call: OrielCall, timeoutMs: Long, block: suspend CoroutineScope.() -> T): T = try {
        runBlocking {
            val work = async(Dispatchers.Default) { withTimeout(timeoutMs) { block() } }
            // Ends: the work completes, fails or times out within timeoutMs.
            while (!work.isCompleted) {
                if (call.isCancelled) {
                    work.cancel()
                    throw OrielExtensionError("cancelled", "cancelled")
                }
                withTimeoutOrNull(POLL_MS) { work.join() }
            }
            work.await()
        }
    } catch (e: OrielExtensionError) {
        throw e
    } catch (e: TimeoutCancellationException) {
        throw OrielExtensionError("timeout", "System AI didn't finish within ${timeoutMs / 1000} s")
    } catch (e: GenAiException) {
        throw OrielExtensionError(genAiCode(e.errorCode), e.message ?: "ML Kit GenAI error ${e.errorCode}")
    }

    /** ML Kit's error codes as core.zig's, else "genai_<n>". */
    private fun genAiCode(code: Int): String = when (code) {
        GenAiException.ErrorCode.NOT_AVAILABLE, GenAiException.ErrorCode.NOT_SUPPORTED,
        GenAiException.ErrorCode.AICORE_INCOMPATIBLE, GenAiException.ErrorCode.NEEDS_SYSTEM_UPDATE -> "unavailable"
        GenAiException.ErrorCode.BUSY -> "busy"
        GenAiException.ErrorCode.CANCELLED -> "cancelled"
        GenAiException.ErrorCode.REQUEST_TOO_LARGE -> "too_large"
        GenAiException.ErrorCode.INVALID_INPUT_IMAGE, GenAiException.ErrorCode.REQUEST_TOO_SMALL -> "invalid_request"
        else -> "genai_$code"
    }

    private fun statusJson(state: String, reason: String) = JSONObject().put("state", state).put("reason", reason)

    private suspend fun featureStatus(): Int = model().checkStatus()

    private suspend fun status(): JSONObject {
        val state = try {
            featureStatus()
        } catch (e: Exception) {
            // No AICore, or an AICore that refuses this app: unavailable, not a failure.
            Log.i(TAG, "checkStatus failed", e)
            return statusJson("unavailable", "Gemini Nano isn't available on this device (AICore: ${e.message ?: e.javaClass.simpleName}).")
        }
        return when (state) {
            FeatureStatus.AVAILABLE -> statusJson("available", "Gemini Nano is ready on this device.")
            FeatureStatus.DOWNLOADABLE -> statusJson("downloadable", "This device supports Gemini Nano: download it first.")
            FeatureStatus.DOWNLOADING -> statusJson("downloading", "Android is downloading Gemini Nano.")
            else -> statusJson("unavailable", "Gemini Nano isn't available on this device (it needs a supported phone with AICore, such as a Pixel 9 or a recent Galaxy S).")
        }
    }

    private suspend fun capabilities(): JSONObject {
        val ready = runCatching { featureStatus() }.getOrNull() == FeatureStatus.AVAILABLE
        val tokens = if (ready) runCatching { model().getTokenLimit() }.getOrDefault(0) else 0
        return JSONObject()
            .put("images", true)
            .put("max_images", 1)
            .put("streaming", true)
            .put("structured_output", false)
            .put("max_input_tokens", tokens)
    }

    private suspend fun download(call: OrielCall): JSONObject {
        when (runCatching { featureStatus() }.getOrDefault(FeatureStatus.UNAVAILABLE)) {
            FeatureStatus.AVAILABLE -> return status()
            FeatureStatus.UNAVAILABLE -> throw OrielExtensionError("unavailable", "Gemini Nano isn't available on this device: there is nothing to download.")
            else -> Unit // downloadable, or downloading: follow it
        }
        var total = 0L
        var last = 0L
        model().download().collect { s ->
            when (s) {
                is DownloadStatus.DownloadStarted -> {
                    total = s.bytesToDownload
                    emitDownload(call, "started", 0, total)
                }
                is DownloadStatus.DownloadProgress -> {
                    // At most 5 a second: each is a page event.
                    val now = SystemClock.elapsedRealtime()
                    if (now - last >= 200) {
                        last = now
                        emitDownload(call, "progress", s.totalBytesDownloaded, total)
                    }
                }
                is DownloadStatus.DownloadCompleted -> emitDownload(call, "completed", total, total)
                is DownloadStatus.DownloadFailed -> {
                    emitDownload(call, "failed", 0, total)
                    throw s.e
                }
            }
        }
        return status()
    }

    private fun emitDownload(call: OrielCall, state: String, downloaded: Long, total: Long) {
        call.emit("download", JSONObject().put("state", state).put("downloaded", downloaded).put("total", total).toString().toByteArray(Charsets.UTF_8))
    }

    private suspend fun generate(input: ByteArray, call: OrielCall): JSONObject {
        when (runCatching { featureStatus() }.getOrDefault(FeatureStatus.UNAVAILABLE)) {
            FeatureStatus.AVAILABLE -> Unit
            FeatureStatus.DOWNLOADABLE -> throw OrielExtensionError("not_ready", "Gemini Nano isn't downloaded yet: call download() first.")
            FeatureStatus.DOWNLOADING -> throw OrielExtensionError("not_ready", "Gemini Nano is still downloading: try again when status() says available.")
            else -> throw OrielExtensionError("unavailable", "Gemini Nano isn't available on this device.")
        }
        val req = Wire.parse(input)
        if (req.images.size > 1) throw OrielExtensionError("invalid_request", "Gemini Nano takes one image per request (capabilities().max_images)")
        val bitmap = req.images.firstOrNull()?.let { decode(it) }
        try {
            var prompt = req.prompt
            if (req.schema != null) prompt += "\n\nAnswer with JSON only, following this JSON schema:\n${req.schema}"
            val system = req.system.isNotEmpty() && runCatching { model().isSystemPromptAvailable() }.getOrDefault(false)
            if (req.system.isNotEmpty() && !system) prompt = req.system + "\n\n" + prompt
            val configure: GenerateContentRequest.Builder.() -> Unit = {
                temperature = req.temperature
                maxOutputTokens = req.maxTokens
            }
            val text = TextPart(prompt)
            val request = when {
                bitmap != null && system -> generateContentRequest(SystemInstruction(req.system), ImagePart(bitmap), text, configure)
                bitmap != null -> generateContentRequest(ImagePart(bitmap), text, configure)
                system -> generateContentRequest(SystemInstruction(req.system), text, configure)
                else -> generateContentRequest(text, configure)
            }
            val streamed = StringBuilder()
            val onText = object : StreamingCallback {
                override fun onNewText(text: String) {
                    if (call.isCancelled || streamed.length + text.length > MAX_REPLY_CHARS) return
                    streamed.append(text)
                    if (req.stream) call.emit("token", text.toByteArray(Charsets.UTF_8))
                }
            }
            val response = model().generateContent(request, onText)
            val reply = response.candidates.firstOrNull()?.text ?: streamed.toString()
            if (reply.length > MAX_REPLY_CHARS) throw OrielExtensionError("too_large", "the reply is over 1 MiB")
            return JSONObject().put("text", reply)
        } finally {
            bitmap?.recycle()
        }
    }

    /** An image, scaled down by powers of two to at most [MAX_SIDE] pixels a side. */
    private fun decode(image: Wire.Image): Bitmap {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(image.bytes, 0, image.bytes.size, bounds)
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) throw OrielExtensionError("invalid_request", "Android can't decode the image (${image.mime})")
        var sample = 1
        while (maxOf(bounds.outWidth, bounds.outHeight) / sample > MAX_SIDE && sample < 64) sample *= 2
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        return BitmapFactory.decodeByteArray(image.bytes, 0, image.bytes.size, options)
            ?: throw OrielExtensionError("invalid_request", "Android can't decode the image (${image.mime})")
    }

    /** generate's input: u32 LE header length, the JSON header, the images' bytes. */
    private class Wire(
        val system: String,
        val prompt: String,
        val images: List<Image>,
        val temperature: Float,
        val maxTokens: Int,
        val schema: String?,
        val stream: Boolean,
    ) {
        class Image(val mime: String, val bytes: ByteArray)

        companion object {
            fun parse(input: ByteArray): Wire {
                if (input.size < 4) throw OrielExtensionError("invalid_request", "a truncated request")
                val n = ByteBuffer.wrap(input, 0, 4).order(ByteOrder.LITTLE_ENDIAN).int
                if (n < 0 || n > input.size - 4) throw OrielExtensionError("invalid_request", "a truncated request")
                val h = JSONObject(String(input, 4, n, Charsets.UTF_8))
                var at = 4 + n
                val list = h.optJSONArray("images")
                val count = list?.length() ?: 0
                if (count > 4) throw OrielExtensionError("too_large", "more than 4 images")
                val images = ArrayList<Image>(count)
                for (i in 0 until count) {
                    val img = list!!.getJSONObject(i)
                    val size = img.getInt("size")
                    if (size < 0 || size > input.size - at) throw OrielExtensionError("invalid_request", "a truncated image")
                    images.add(Image(img.optString("mime", "image/jpeg"), input.copyOfRange(at, at + size)))
                    at += size
                }
                return Wire(
                    h.optString("system", ""),
                    h.getString("prompt"),
                    images,
                    h.optDouble("temperature", 0.2).toFloat(),
                    h.optInt("max_tokens", 1024),
                    if (h.isNull("schema")) null else h.optString("schema"),
                    h.optBoolean("stream", false),
                )
            }
        }
    }

    private companion object {
        const val TAG = "OrielSystemAi"
        const val STATUS_MS = 20_000L
        const val GENERATE_MS = 180_000L
        const val DOWNLOAD_MS = 600_000L
        const val POLL_MS = 100L
        const val MAX_SIDE = 2048
        /** 1 MiB of UTF-16 (src/modules/system_ai/core.zig checks the bytes). */
        const val MAX_REPLY_CHARS = 1 shl 20
    }
}
