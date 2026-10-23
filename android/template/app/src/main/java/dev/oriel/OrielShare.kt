package dev.oriel

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import android.util.Log
import android.util.Patterns
import android.webkit.MimeTypeMap
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * oriel.share on Android (src/modules/share/android.zig).
 *
 * Receiving: the main Activity's ACTION_SEND / SEND_MULTIPLE intent filters
 * (from build.zig's `.share_target`). The shared streams are opened
 * read-only and their descriptors handed to Zig (`NativeLib.onShare`); a
 * stream that isn't a seekable file (a pipe) is copied into the cache first.
 *
 * Sending: Intent.createChooser, files through OrielFileProvider. The chosen
 * target comes back through a PendingIntent; Android doesn't report a
 * dismissal, so the chooser counts as dismissed when an Oriel window is in
 * front again without a choice.
 */
internal object OrielShare {
    private const val TAG = "OrielShare"
    private const val HANDLED = "dev.oriel.share.handled"
    private const val CHOSEN = "dev.oriel.share.CHOSEN"
    private const val IN_DIR = "oriel-share-in"

    private val main = Handler(Looper.getMainLooper())

    // --- Receiving -----------------------------------------------------------

    /**
     * Hand a share intent to Zig (off the UI thread: providers can be slow,
     * pipes are copied). True if `intent` was a share. Each intent is
     * delivered once: a recreated Activity or a launch from Recents carries
     * the same intent again.
     */
    fun receive(context: Context, intent: Intent): Boolean {
        val action = intent.action
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return false
        if (intent.getBooleanExtra(HANDLED, false) || intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return true
        intent.putExtra(HANDLED, true)
        val app = context.applicationContext
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
        val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)
        val type = intent.type
        val uris = streams(intent)
        Thread({
            val json = JSONObject()
            // A text that is just a link is the share's URL (a browser's "share page").
            val trimmed = text?.trim()
            if (trimmed != null && isUrl(trimmed)) json.put("url", trimmed) else if (text != null) json.put("text", text)
            if (subject != null) json.put("subject", subject)
            val files = JSONArray()
            for (uri in uris) open(app, uri, type)?.let { files.put(it) }
            json.put("files", files)
            main.post {
                try {
                    NativeLib.onShare(json.toString().bytes())
                } catch (e: UnsatisfiedLinkError) {
                    Log.e(TAG, "a share came, but the app was built without oriel.share", e)
                    closeAll(files)
                }
            }
        }, "oriel-share").start()
        return true
    }

    private fun streams(intent: Intent): List<Uri> {
        val out = ArrayList<Uri>()
        if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            @Suppress("DEPRECATION")
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.let { out.addAll(it) }
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)?.let { out.add(it) }
        }
        // Some apps put the streams only in the ClipData.
        if (out.isEmpty()) intent.clipData?.let { clip ->
            for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let { out.add(it) }
        }
        return out
    }

    private fun isUrl(s: String): Boolean =
        !s.contains(Regex("\\s")) && (s.startsWith("http://") || s.startsWith("https://")) && Patterns.WEB_URL.matcher(s).matches()

    /** `{ fd, name, mime, size }` for one stream, or null if it can't be read. */
    private fun open(context: Context, uri: Uri, intentType: String?): JSONObject? {
        val cr = context.contentResolver
        var name: String? = null
        var size = -1L
        try {
            cr.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { c ->
                if (c.moveToFirst()) {
                    val n = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val s = c.getColumnIndex(OpenableColumns.SIZE)
                    if (n >= 0 && !c.isNull(n)) name = c.getString(n)
                    if (s >= 0 && !c.isNull(s)) size = c.getLong(s)
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "no metadata for a shared stream", e)
        }
        val fileName = (name ?: uri.lastPathSegment ?: "file").substringAfterLast('/').ifEmpty { "file" }
        val mime = cr.getType(uri)
            ?: MimeTypeMap.getSingleton().getMimeTypeFromExtension(fileName.substringAfterLast('.', "").lowercase())
            ?: intentType?.takeIf { !it.contains('*') }
            ?: "application/octet-stream"
        return try {
            var pfd = cr.openFileDescriptor(uri, "r") ?: return null
            if (pfd.statSize < 0) pfd = copied(context, pfd, fileName) // a pipe
            val fd = pfd.detachFd()
            JSONObject().put("fd", fd).put("name", fileName).put("mime", mime).put("size", if (size >= 0) size else -1L)
        } catch (e: Exception) {
            Log.w(TAG, "a shared stream can't be opened: $uri", e)
            null
        }
    }

    /** A pipe's contents as a cache file, open; the file is unlinked at once. */
    private fun copied(context: Context, pfd: ParcelFileDescriptor, name: String): ParcelFileDescriptor {
        val dir = File(context.cacheDir, IN_DIR).apply { mkdirs() }
        val file = File.createTempFile("in", "-" + name.takeLast(64).replace(Regex("[^A-Za-z0-9._-]"), "_"), dir)
        try {
            ParcelFileDescriptor.AutoCloseInputStream(pfd).use { input -> file.outputStream().use { input.copyTo(it) } }
            return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
        } finally {
            file.delete()
        }
    }

    private fun closeAll(files: JSONArray) {
        for (i in 0 until files.length()) try {
            ParcelFileDescriptor.adoptFd(files.getJSONObject(i).getInt("fd")).close()
        } catch (_: Exception) {}
    }

    // --- Sending -------------------------------------------------------------

    /** The chooser is open, no target picked yet. */
    private var pending = false
    private var chosenReceiver: BroadcastReceiver? = null

    /**
     * Open the system chooser with `{ title, text, url, files: [{ path, name, mime }] }`
     * (the files are in OrielFileProvider's directory). False if it can't open.
     */
    fun send(context: Context, from: Activity?, request: ByteArray): Boolean {
        val req = JSONObject(request.utf8())
        val title = req.optString("title").ifEmpty { null }
        val text = listOfNotNull(req.optString("text").ifEmpty { null }, req.optString("url").ifEmpty { null }).joinToString("\n").ifEmpty { null }
        val files = req.optJSONArray("files") ?: JSONArray()
        val uris = ArrayList<Uri>()
        val mimes = ArrayList<String>()
        for (i in 0 until files.length()) {
            val f = files.getJSONObject(i)
            uris += OrielFileProvider.uriFor(context, File(f.getString("path")))
            mimes += f.optString("mime", "application/octet-stream")
        }
        if (text == null && uris.isEmpty()) return false
        val intent = Intent(if (uris.size > 1) Intent.ACTION_SEND_MULTIPLE else Intent.ACTION_SEND)
        intent.type = when {
            uris.isEmpty() -> "text/plain"
            mimes.distinct().size == 1 -> mimes[0]
            mimes.map { it.substringBefore('/') }.distinct().size == 1 -> mimes[0].substringBefore('/') + "/*"
            else -> "*/*"
        }
        if (text != null) intent.putExtra(Intent.EXTRA_TEXT, text)
        if (title != null) {
            intent.putExtra(Intent.EXTRA_SUBJECT, title)
            intent.putExtra(Intent.EXTRA_TITLE, title)
        }
        if (uris.size == 1) intent.putExtra(Intent.EXTRA_STREAM, uris[0])
        if (uris.size > 1) intent.putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
        if (uris.isNotEmpty()) {
            // The grant travels with the ClipData.
            val clip = ClipData.newUri(context.contentResolver, title ?: "", uris[0])
            for (u in uris.drop(1)) clip.addItem(ClipData.Item(u))
            intent.clipData = clip
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }

        listenForChoice(context)
        val callback = PendingIntent.getBroadcast(
            context, 0x4F53, Intent(CHOSEN).setPackage(context.packageName),
            PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0),
        )
        val chooser = Intent.createChooser(intent, title, callback.intentSender)
        if (from == null) chooser.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            (from ?: context).startActivity(chooser)
            pending = true
            true
        } catch (e: Exception) {
            Log.e(TAG, "cannot open the share sheet", e)
            false
        }
    }

    private fun listenForChoice(context: Context) {
        if (chosenReceiver != null) return
        val r = object : BroadcastReceiver() {
            override fun onReceive(c: Context, intent: Intent) {
                @Suppress("DEPRECATION")
                val target = intent.getParcelableExtra<ComponentName>(Intent.EXTRA_CHOSEN_COMPONENT)
                finish(true, target?.packageName)
            }
        }
        val app = context.applicationContext
        if (Build.VERSION.SDK_INT >= 33) app.registerReceiver(r, IntentFilter(CHOSEN), Context.RECEIVER_NOT_EXPORTED)
        else app.registerReceiver(r, IntentFilter(CHOSEN))
        chosenReceiver = r
    }

    /**
     * An Oriel window is in front again: a chooser still pending was
     * dismissed (the choice broadcast, when there was one, comes first or
     * within moments).
     */
    fun onWindowResumed() {
        if (!pending) return
        main.postDelayed({ if (pending) finish(false, null) }, 600)
    }

    private fun finish(completed: Boolean, target: String?) {
        if (!pending) return
        pending = false
        try {
            NativeLib.onShareSent(completed, target?.bytes())
        } catch (_: UnsatisfiedLinkError) {}
    }
}
