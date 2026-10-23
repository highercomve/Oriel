package dev.oriel

import android.webkit.MimeTypeMap
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileInputStream
import java.io.InputStream

/**
 * oriel.media_scheme on Android (src/modules/media_scheme/android.zig): the
 * files below the root Zig sets, at `https://app.localhost/media/<path>`,
 * straight from the WebView's request interception, with no port and nothing
 * read into memory. `<audio>` and `<video>` seek with Range requests.
 *
 * Android's WebView applies a request's Range to the stream it is given (it
 * skips to the first byte itself, keeping our 206 and Content-Range; see
 * tauri-apps/wry#1864): so a ranged answer is a 206 whose body is the whole
 * file's stream, and the WebView's skip lands on the first byte asked for.
 * Ranges from 2 GiB up aren't served (Chromium checks them as 32-bit ints).
 */
internal object OrielMedia {
    const val PREFIX = "/media/"

    @Volatile private var root: File? = null
    /** Follow symlinks only while they stay inside the root (else refuse every one). */
    @Volatile private var insideRoot = true

    /** Serve below `path` ("" stops serving); `refuseAllLinks` per SymlinkPolicy. */
    fun setRoot(path: String, refuseAllLinks: Boolean) {
        root = if (path.isEmpty()) null else File(path).canonicalFile
        insideRoot = !refuseAllLinks
    }

    /** Background thread (shouldInterceptRequest). */
    fun serve(request: WebResourceRequest): WebResourceResponse {
        val base = root ?: return status(404, "Not Found")
        if (request.method != "GET" && request.method != "HEAD") return status(405, "Method Not Allowed")
        val rel = request.url.path?.removePrefix(PREFIX) ?: return status(404, "Not Found")
        if (rel.isEmpty() || rel.split('/').any { it == ".." }) return status(404, "Not Found")
        val file = File(base, rel)
        if (!insideRoot && hasLink(base, file)) return status(404, "Not Found")
        val real = file.canonicalFile
        if (!real.path.startsWith(base.path + File.separator) || !real.isFile) return status(404, "Not Found")

        val size = real.length()
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(real.extension.lowercase()) ?: "application/octet-stream"
        val headers = mutableMapOf(
            "Accept-Ranges" to "bytes",
            "Cache-Control" to "no-store",
            "Access-Control-Allow-Origin" to OrielWindow.APP_ORIGIN,
        )
        val range = request.requestHeaders.entries.firstOrNull { it.key.equals("Range", ignoreCase = true) }?.value
        if (range == null) {
            headers["Content-Length"] = size.toString()
            return WebResourceResponse(mime, null, 200, "OK", headers, open(real, request))
        }
        // One range: "bytes=N-", "bytes=N-M" or "bytes=-N" (the last N).
        val spec = range.trim().removePrefix("bytes=")
        if (spec.contains(',') || !range.trim().startsWith("bytes=")) {
            headers["Content-Length"] = size.toString()
            return WebResourceResponse(mime, null, 200, "OK", headers, open(real, request))
        }
        val dash = spec.indexOf('-')
        if (dash < 0) return unsatisfiable(size, headers)
        val a = spec.substring(0, dash).trim()
        val b = spec.substring(dash + 1).trim()
        val start: Long
        val end: Long
        if (a.isEmpty()) {
            val n = b.toLongOrNull() ?: return unsatisfiable(size, headers)
            start = maxOf(size - n, 0)
            end = size - 1
        } else {
            start = a.toLongOrNull() ?: return unsatisfiable(size, headers)
            end = if (b.isEmpty()) size - 1 else minOf(b.toLongOrNull() ?: return unsatisfiable(size, headers), size - 1)
        }
        if (start >= size || start > end || start >= Int.MAX_VALUE) return unsatisfiable(size, headers)
        headers["Content-Range"] = "bytes $start-$end/$size"
        headers["Content-Length"] = (end - start + 1).toString()
        // A suffix range ("bytes=-N") isn't skipped by the WebView: that body starts at `start`.
        val body = if (a.isEmpty()) open(real, request).also { it.skipFully(start) } else open(real, request)
        return WebResourceResponse(mime, null, 206, "Partial Content", headers, body)
    }

    private fun open(f: File, request: WebResourceRequest): InputStream =
        if (request.method == "HEAD") ByteArrayInputStream(ByteArray(0)) else FileInputStream(f)

    private fun InputStream.skipFully(n: Long) {
        var left = n
        while (left > 0) {
            val s = skip(left)
            if (s <= 0) break
            left -= s
        }
    }

    /** A symlink anywhere from `base` down to `file` (refuse_all). */
    private fun hasLink(base: File, file: File): Boolean {
        var f: File? = file
        while (f != null && f.path.length > base.path.length) {
            if (java.nio.file.Files.isSymbolicLink(f.toPath())) return true
            f = f.parentFile
        }
        return false
    }

    private fun unsatisfiable(size: Long, headers: MutableMap<String, String>): WebResourceResponse {
        headers["Content-Range"] = "bytes */$size"
        return WebResourceResponse("text/plain", "utf-8", 416, "Range Not Satisfiable", headers, ByteArrayInputStream(ByteArray(0)))
    }

    private fun status(code: Int, reason: String) =
        WebResourceResponse("text/plain", "utf-8", code, reason, emptyMap(), ByteArrayInputStream(ByteArray(0)))
}
