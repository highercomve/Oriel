package dev.oriel

import android.webkit.MimeTypeMap
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileInputStream
import java.io.IOException
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
 *
 * While Zig has a media source (`media_scheme.setSource`), it answers instead
 * of the root: its size from `NativeLib.mediaSize`, its bytes from
 * `NativeLib.mediaRead` through [SourceStream], whose skip only moves its
 * position, so a seek reads nothing before the first byte asked for.
 */
internal object OrielMedia {
    const val PREFIX = "/media/"
    /** The most one `NativeLib.mediaRead` copies (source.zig's chunk_size). */
    private const val CHUNK = 256 * 1024

    @Volatile private var root: File? = null
    /** Follow symlinks only while they stay inside the root (else refuse every one). */
    @Volatile private var insideRoot = true
    /** Zig's media source answers instead of the root. */
    @Volatile private var source = false

    /** Serve below `path` ("" stops serving); `refuseAllLinks` per SymlinkPolicy. */
    fun setRoot(path: String, refuseAllLinks: Boolean) {
        root = if (path.isEmpty()) null else File(path).canonicalFile
        insideRoot = !refuseAllLinks
    }

    /** Serve Zig's media source (true) or the root again (false). */
    fun setSource(active: Boolean) {
        source = active
    }

    /** Background thread (shouldInterceptRequest). */
    fun serve(request: WebResourceRequest): WebResourceResponse {
        val fromSource = source
        val base = root
        if (!fromSource && base == null) return status(404, "Not Found")
        if (request.method != "GET" && request.method != "HEAD") return status(405, "Method Not Allowed")
        val rel = request.url.path?.removePrefix(PREFIX) ?: return status(404, "Not Found")
        if (rel.isEmpty() || rel.split('/').any { it == ".." }) return status(404, "Not Found")

        if (fromSource) {
            // Zig checks the path again (source.zig's validPath) before the source sees it.
            val path = rel.bytes()
            val size = NativeLib.mediaSize(path)
            if (size < 0) return status(404, "Not Found")
            return respond(request, mimeOf(rel.substringAfterLast('/').substringAfterLast('.', "")), size) { SourceStream(path, size) }
        }

        val dir = base ?: return status(404, "Not Found")
        val file = File(dir, rel)
        if (!insideRoot && hasLink(dir, file)) return status(404, "Not Found")
        val real = file.canonicalFile
        if (!real.path.startsWith(dir.path + File.separator) || !real.isFile) return status(404, "Not Found")
        return respond(request, mimeOf(real.extension), real.length()) { FileInputStream(real) }
    }

    /**
     * The answer for a file of `size` bytes whose body `open` streams from
     * byte 0: 200, or 206 for one range (the WebView skips to its start), or
     * 416; HEAD gets the headers and an empty body.
     */
    private fun respond(request: WebResourceRequest, mime: String, size: Long, open: () -> InputStream): WebResourceResponse {
        val headers = mutableMapOf(
            "Accept-Ranges" to "bytes",
            "Cache-Control" to "no-store",
            "Access-Control-Allow-Origin" to OrielWindow.APP_ORIGIN,
        )
        val range = request.requestHeaders.entries.firstOrNull { it.key.equals("Range", ignoreCase = true) }?.value
        if (range == null) {
            headers["Content-Length"] = size.toString()
            return WebResourceResponse(mime, null, 200, "OK", headers, body(request, open))
        }
        // One range: "bytes=N-", "bytes=N-M" or "bytes=-N" (the last N).
        val spec = range.trim().removePrefix("bytes=")
        if (spec.contains(',') || !range.trim().startsWith("bytes=")) {
            headers["Content-Length"] = size.toString()
            return WebResourceResponse(mime, null, 200, "OK", headers, body(request, open))
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
        val stream = if (a.isEmpty()) body(request, open).also { it.skipFully(start) } else body(request, open)
        return WebResourceResponse(mime, null, 206, "Partial Content", headers, stream)
    }

    private fun body(request: WebResourceRequest, open: () -> InputStream): InputStream =
        if (request.method == "HEAD") ByteArrayInputStream(ByteArray(0)) else open()

    private fun mimeOf(extension: String): String =
        MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension.lowercase()) ?: "application/octet-stream"

    /**
     * A media source's `path` (`size` bytes) as a stream. Reads go to
     * `NativeLib.mediaRead` at the current position, a chunk at a time into
     * one reused buffer; `skip` only moves the position (the WebView's skip
     * to a range's first byte reads nothing).
     */
    private class SourceStream(private val path: ByteArray, private val size: Long) : InputStream() {
        private var pos = 0L
        private val buf = ByteArray(CHUNK)
        /** `buf` holds the source's bytes [bufStart, bufStart + bufLen). */
        private var bufStart = 0L
        private var bufLen = 0

        override fun read(): Int {
            if (!fill()) return -1
            val v = buf[(pos - bufStart).toInt()].toInt() and 0xff
            pos++
            return v
        }

        override fun read(b: ByteArray, off: Int, len: Int): Int {
            if (off < 0 || len < 0 || len > b.size - off) throw IndexOutOfBoundsException()
            if (len == 0) return 0
            if (!fill()) return -1
            val at = (pos - bufStart).toInt()
            val n = minOf(len.toLong(), (bufLen - at).toLong(), size - pos).toInt()
            System.arraycopy(buf, at, b, off, n)
            pos += n
            return n
        }

        /** Only moves the position, clamped to the size. */
        override fun skip(n: Long): Long {
            if (n <= 0) return 0
            val s = minOf(n, size - pos).coerceAtLeast(0)
            pos += s
            return s
        }

        override fun available(): Int = 0

        /** Makes the byte at `pos` buffered, reading from the source there if it isn't; false at the end. */
        private fun fill(): Boolean {
            if (pos >= size) return false
            if (pos >= bufStart && pos < bufStart + bufLen) return true
            val n = NativeLib.mediaRead(path, pos, buf)
            if (n < 0) throw IOException("media source: read failed at $pos")
            if (n == 0) return false
            bufStart = pos
            bufLen = n
            return true
        }
    }

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
