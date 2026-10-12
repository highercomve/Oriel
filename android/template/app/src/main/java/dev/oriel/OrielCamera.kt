package dev.oriel

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import android.webkit.ValueCallback
import android.webkit.WebChromeClient.FileChooserParams
import java.io.ByteArrayOutputStream
import java.io.File
import java.util.concurrent.Executors

/**
 * oriel.camera on Android (src/modules/camera/android.zig), active when the
 * module is on: the manifest then declares [OrielCaptureProvider], which is
 * how this knows (and where `.camera = .{ .transcode = ... }` is kept, as
 * the provider's meta-data).
 *
 * - `<input type="file" accept="image/...">`: with `capture`, the camera app
 *   (CAMERA asked first when the manifest declares it), its photo written
 *   into the capture provider; without, the system photo picker
 *   (`ACTION_PICK_IMAGES` on 13+, `ACTION_GET_CONTENT` before; several with
 *   `multiple`). Picks the WebView can't decode (HEIC, AVIF) are transcoded
 *   to JPEG off the UI thread. App extensions see the chooser first.
 * - `capturePhoto` (Zig): the same intents; the photo is decoded, scaled to
 *   fit `maxSide` (orientation applied) and encoded on a worker, then
 *   answered once through NativeLib.onCameraResult.
 *
 * One request at a time: a new one cancels the one pending.
 */
internal object OrielCamera {
    private const val TAG = "OrielCamera"
    // Oriel's request codes (0x4F00..0x4FFF, OrielActivity).
    const val REQ_CHOOSER_CAMERA = 0x4F10
    const val REQ_CHOOSER_LIBRARY = 0x4F11
    const val REQ_PHOTO_CAMERA = 0x4F12
    const val REQ_PHOTO_LIBRARY = 0x4F13
    fun owns(requestCode: Int) = requestCode in REQ_CHOOSER_CAMERA..REQ_PHOTO_LIBRARY

    // NativeLib.onCameraResult statuses (src/modules/camera/android.zig).
    private const val STATUS_OK = 0
    private const val STATUS_CANCELLED = 1
    private const val STATUS_UNSUPPORTED = 2
    private const val STATUS_PERMISSION_DENIED = 3
    private const val STATUS_FAILED = 4
    private const val STATUS_TOO_LARGE = 5
    /** src/modules/camera/common.zig: max_bytes. */
    private const val MAX_BYTES = 32 shl 20

    /** The long side transcoded chooser picks keep at least (subsampled by powers of two). */
    private const val TRANSCODE_SIDE = 1600
    private const val TRANSCODE_QUALITY = 90
    private const val META_TRANSCODE = "dev.oriel.camera.transcode"

    /** Formats every WebView decodes; other picks are transcoded to JPEG. */
    private val webReadable = setOf("image/jpeg", "image/png", "image/webp", "image/gif")
    private val imageExtensions = setOf(".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".heic", ".heif", ".avif")

    private val main = Handler(Looper.getMainLooper())
    private val worker by lazy { Executors.newSingleThreadExecutor { Thread(it, "oriel-camera") } }

    /** What's waiting for a camera or picker result (UI thread). */
    private sealed class Pending(val host: Activity) {
        /** The camera's output file. */
        var file: File? = null
        /** The page's `<input type=file>`. */
        class Chooser(host: Activity, val callback: ValueCallback<Array<Uri>>) : Pending(host)
        /** Zig's capturePhoto. */
        class Photo(host: Activity, val request: Long, val maxSide: Int, val png: Boolean, val quality: Int) : Pending(host)
    }
    private var pending: Pending? = null

    private class Config(val enabled: Boolean, val transcode: Boolean)
    private val config: Config by lazy {
        val app = OrielRuntime.app
        val info = try {
            app.packageManager.resolveContentProvider(OrielCaptureProvider.authority(app), PackageManager.GET_META_DATA)
        } catch (e: Exception) {
            null
        }
        Config(info != null, info?.metaData?.getBoolean(META_TRANSCODE, true) ?: true)
    }

    /** The app declares CAMERA: the camera app then needs it granted (Android refuses otherwise). */
    private val cameraDeclared: Boolean by lazy {
        val app = OrielRuntime.app
        try {
            @Suppress("DEPRECATION")
            app.packageManager.getPackageInfo(app.packageName, PackageManager.GET_PERMISSIONS)
                .requestedPermissions?.contains(Manifest.permission.CAMERA) == true
        } catch (e: Exception) {
            false
        }
    }

    // ---------------------------------------------------------------------
    // <input type="file" accept="image/*" [capture] [multiple]>
    // ---------------------------------------------------------------------

    /** Whether every accepted type is an image ("image/" types, ".jpg" extensions). */
    private fun imagesOnly(types: Array<String>): Boolean {
        val list = types.flatMap { it.split(',') }.map { it.trim().lowercase() }.filter { it.isNotEmpty() }
        return list.isNotEmpty() && list.all { it.startsWith("image/") || it in imageExtensions }
    }

    /** Handle an image chooser (after the app's extensions passed); false leaves it to the default picker. */
    fun onShowFileChooser(activity: OrielActivity, callback: ValueCallback<Array<Uri>>, params: FileChooserParams): Boolean {
        if (!config.enabled || !imagesOnly(params.acceptTypes)) return false
        cancelPending()
        val chooser = Pending.Chooser(activity, callback)
        pending = chooser
        val multiple = params.mode == FileChooserParams.MODE_OPEN_MULTIPLE
        if (!params.isCaptureEnabled) {
            if (!startLibrary(activity, REQ_CHOOSER_LIBRARY, multiple)) finishChooser(chooser, null)
            return true
        }
        withCamera { granted ->
            if (pending !== chooser) return@withCamera
            if (!granted) return@withCamera finishChooser(chooser, null)
            if (!startCamera(activity, chooser, REQ_CHOOSER_CAMERA)) {
                // No camera app: the picker instead.
                if (!startLibrary(activity, REQ_CHOOSER_LIBRARY, multiple)) finishChooser(chooser, null)
            }
        }
        return true
    }

    private fun finishChooser(chooser: Pending.Chooser, uris: Array<Uri>?) {
        if (pending === chooser) pending = null
        if (uris == null) chooser.file?.delete()
        chooser.callback.onReceiveValue(uris)
    }

    // ---------------------------------------------------------------------
    // capturePhoto (Zig)
    // ---------------------------------------------------------------------

    /** Start a capture; false when it can't (no Activity, the module off). */
    fun capturePhoto(request: Long, source: Int, maxSide: Int, format: Int, quality: Int): Boolean {
        val host = OrielRuntime.foreground ?: return false
        if (!config.enabled) return false
        cancelPending()
        val photo = Pending.Photo(host, request, maxSide.coerceIn(1, 8192), format == 1, quality.coerceIn(1, 100))
        pending = photo
        if (source == 1) {
            if (!startLibrary(host, REQ_PHOTO_LIBRARY, false)) answer(photo, STATUS_UNSUPPORTED)
            return true
        }
        withCamera { granted ->
            if (pending !== photo) return@withCamera
            if (!granted) return@withCamera answer(photo, STATUS_PERMISSION_DENIED)
            if (!startCamera(host, photo, REQ_PHOTO_CAMERA)) answer(photo, STATUS_UNSUPPORTED)
        }
        return true
    }

    /** Answer Zig once (any thread). */
    private fun answer(photo: Pending.Photo, status: Int, width: Int = 0, height: Int = 0, data: ByteArray? = null) {
        main.post { if (pending === photo) pending = null }
        photo.file?.delete()
        NativeLib.onCameraResult(photo.request, status, width, height, data)
    }

    // ---------------------------------------------------------------------
    // Intents and results
    // ---------------------------------------------------------------------

    /** CAMERA, asked first when the manifest declares it. */
    private fun withCamera(done: (Boolean) -> Unit) {
        if (!cameraDeclared) return done(true)
        OrielPermissions.ensure(listOf(OrielPermissions.CAMERA), done)
    }

    private fun startCamera(activity: Activity, target: Pending, requestCode: Int): Boolean {
        val file = try {
            OrielCaptureProvider.newFile(activity)
        } catch (e: Exception) {
            Log.w(TAG, "cannot create the capture file", e)
            return false
        }
        val uri = OrielCaptureProvider.uriFor(activity, file)
        target.file = file
        val intent = Intent(MediaStore.ACTION_IMAGE_CAPTURE)
            .putExtra(MediaStore.EXTRA_OUTPUT, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        // The grant travels with the clip (EXTRA_OUTPUT alone isn't granted).
        intent.clipData = ClipData.newRawUri("photo", uri)
        return start(activity, intent, requestCode).also { if (!it) file.delete() }
    }

    private fun startLibrary(activity: Activity, requestCode: Int, multiple: Boolean): Boolean {
        val intent = if (Build.VERSION.SDK_INT >= 33) {
            Intent(MediaStore.ACTION_PICK_IMAGES).apply {
                type = "image/*"
                if (multiple) putExtra(MediaStore.EXTRA_PICK_IMAGES_MAX, MediaStore.getPickImagesMaxLimit())
            }
        } else {
            Intent(Intent.ACTION_GET_CONTENT).setType("image/*").addCategory(Intent.CATEGORY_OPENABLE)
                .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, multiple)
        }
        return start(activity, intent, requestCode)
    }

    private fun start(activity: Activity, intent: Intent, requestCode: Int): Boolean = try {
        @Suppress("DEPRECATION")
        activity.startActivityForResult(intent, requestCode)
        true
    } catch (e: ActivityNotFoundException) {
        false
    } catch (e: SecurityException) {
        Log.w(TAG, "cannot start ${intent.action}", e)
        false
    }

    /** OrielActivity.onActivityResult for [owns] codes (UI thread). */
    fun onActivityResult(activity: Activity, requestCode: Int, resultCode: Int, data: Intent?) {
        val p = pending ?: return
        val ok = resultCode == Activity.RESULT_OK
        when (requestCode) {
            REQ_CHOOSER_CAMERA, REQ_CHOOSER_LIBRARY -> {
                val chooser = p as? Pending.Chooser ?: return
                if (requestCode == REQ_CHOOSER_CAMERA) {
                    val file = chooser.file
                    revoke(activity, file)
                    if (!ok || file == null || file.length() == 0L) return finishChooser(chooser, null)
                    return finishChooser(chooser, arrayOf(OrielCaptureProvider.uriFor(activity, file)))
                }
                val picked = if (ok) urisOf(data) else null
                if (picked.isNullOrEmpty()) return finishChooser(chooser, null)
                if (!config.transcode) return finishChooser(chooser, picked)
                val app = activity.applicationContext
                worker.execute {
                    val served = picked.map { readable(app, it) }.toTypedArray()
                    main.post {
                        if (pending === chooser) finishChooser(chooser, served)
                        else served.forEach { u -> OrielCaptureProvider.fileFor(app, u)?.delete() }
                    }
                }
            }
            REQ_PHOTO_CAMERA, REQ_PHOTO_LIBRARY -> {
                val photo = p as? Pending.Photo ?: return
                if (requestCode == REQ_PHOTO_CAMERA) revoke(activity, photo.file)
                val source = if (!ok) null else if (requestCode == REQ_PHOTO_CAMERA) {
                    photo.file?.takeIf { it.length() > 0L }?.let { OrielCaptureProvider.uriFor(activity, it) }
                } else urisOf(data)?.firstOrNull()
                if (source == null) return answer(photo, STATUS_CANCELLED)
                val app = activity.applicationContext
                worker.execute { encode(app, photo, source) }
            }
        }
    }

    private fun urisOf(data: Intent?): Array<Uri>? {
        data ?: return null
        val clip = data.clipData
        if (clip != null && clip.itemCount > 0) return Array(clip.itemCount) { clip.getItemAt(it).uri }
        return data.data?.let { arrayOf(it) }
    }

    private fun revoke(context: Context, file: File?) {
        file ?: return
        context.revokeUriPermission(OrielCaptureProvider.uriFor(context, file), Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
    }

    /** The host Activity went away with a request pending: cancel it. */
    fun onActivityDestroyed(activity: Activity) {
        if (!activity.isChangingConfigurations && pending?.host === activity) cancelPending()
    }

    private fun cancelPending() {
        when (val p = pending) {
            is Pending.Chooser -> finishChooser(p, null)
            is Pending.Photo -> answer(p, STATUS_CANCELLED)
            null -> {}
        }
        pending = null
    }

    // ---------------------------------------------------------------------
    // Decoding (worker thread)
    // ---------------------------------------------------------------------

    /**
     * A chooser pick the WebView reads as is, or its JPEG transcode in the
     * capture provider (long side kept, or halved while it stays at least
     * TRANSCODE_SIDE). On any failure the original, so the page sees the
     * WebView's own error.
     */
    private fun readable(app: Context, picked: Uri): Uri {
        val type = try { app.contentResolver.getType(picked) } catch (e: Exception) { null }
        if (type != null && type in webReadable) return picked
        return try {
            val bitmap = decode(app, picked) { w, h ->
                var sample = 1
                var longest = maxOf(w, h)
                while (longest / 2 >= TRANSCODE_SIDE && sample < 64) { sample *= 2; longest /= 2 }
                Pair(w / sample, h / sample)
            }
            val file = OrielCaptureProvider.newFile(app)
            try {
                file.outputStream().use { if (!bitmap.compress(Bitmap.CompressFormat.JPEG, TRANSCODE_QUALITY, it)) throw IllegalStateException("JPEG encoding failed") }
            } catch (e: Throwable) {
                file.delete()
                throw e
            } finally {
                bitmap.recycle()
            }
            OrielCaptureProvider.uriFor(app, file)
        } catch (e: Throwable) {
            // Throwable: a huge photo can still exhaust the heap.
            Log.w(TAG, "cannot transcode the picked image ($type)", e)
            picked
        }
    }

    /** Decode `uri` (HEIC and AVIF where the OS can; orientation applied) at the size `size(w, h)` picks. */
    private fun decode(app: Context, uri: Uri, size: (Int, Int) -> Pair<Int, Int>): Bitmap {
        val source = ImageDecoder.createSource(app.contentResolver, uri)
        return try {
            ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
                val (w, h) = size(info.size.width, info.size.height)
                decoder.setTargetSize(maxOf(w, 1), maxOf(h, 1))
                // Software: compress() can't read hardware bitmaps.
                decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
            }
        } catch (e: java.io.IOException) {
            // Some HEIF/AVIF files only BitmapFactory reads (no orientation there).
            decodeWithBitmapFactory(app, uri, size) ?: throw e
        }
    }

    private fun decodeWithBitmapFactory(app: Context, uri: Uri, size: (Int, Int) -> Pair<Int, Int>): Bitmap? {
        val resolver = app.contentResolver
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, bounds) }
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return null
        val (w, h) = size(bounds.outWidth, bounds.outHeight)
        var sample = 1
        while (bounds.outWidth / (sample * 2) >= w && bounds.outHeight / (sample * 2) >= h && sample < 64) sample *= 2
        val options = BitmapFactory.Options().apply { inSampleSize = sample }
        val decoded = resolver.openInputStream(uri)?.use { BitmapFactory.decodeStream(it, null, options) } ?: return null
        if (decoded.width == w && decoded.height == h) return decoded
        return Bitmap.createScaledBitmap(decoded, maxOf(w, 1), maxOf(h, 1), true).also { if (it !== decoded) decoded.recycle() }
    }

    private fun encode(app: Context, photo: Pending.Photo, uri: Uri) {
        val bitmap = try {
            decode(app, uri) { w, h ->
                val longest = maxOf(w, h)
                if (longest <= photo.maxSide) Pair(w, h)
                else Pair(Math.round(w.toDouble() * photo.maxSide / longest).toInt(), Math.round(h.toDouble() * photo.maxSide / longest).toInt())
            }
        } catch (e: Throwable) {
            Log.w(TAG, "cannot decode the photo", e)
            return answer(photo, STATUS_FAILED)
        }
        try {
            val out = ByteArrayOutputStream()
            val format = if (photo.png) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG
            if (!bitmap.compress(format, photo.quality, out)) return answer(photo, STATUS_FAILED)
            if (out.size() > MAX_BYTES) return answer(photo, STATUS_TOO_LARGE)
            answer(photo, STATUS_OK, bitmap.width, bitmap.height, out.toByteArray())
        } catch (e: Throwable) {
            Log.w(TAG, "cannot encode the photo", e)
            answer(photo, STATUS_FAILED)
        } finally {
            bitmap.recycle()
        }
    }
}
