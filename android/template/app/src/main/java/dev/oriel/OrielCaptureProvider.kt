package dev.oriel

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File
import java.io.FileNotFoundException

/**
 * oriel.camera's photos (`<cacheDir>/oriel-captures/`): the camera app
 * writes into one through `EXTRA_OUTPUT`, and the page reads the ones
 * delivered to `<input type=file>`. Declared in the manifest's components
 * region only when the camera module is on (`<app id>.oriel.capture`); not
 * exported, access is granted per URI. Only files Oriel created, named
 * `capture-<digits>.jpg` (src/modules/camera/common.zig, validCaptureName),
 * are served: nothing else in the cache is reachable through it.
 */
class OrielCaptureProvider : ContentProvider() {
    companion object {
        private const val DIR = "oriel-captures"
        private val NAME = Regex("capture-[0-9]{1,20}\\.jpg")
        private const val DAY_MS = 24L * 60 * 60 * 1000

        fun authority(context: Context) = "${context.packageName}.oriel.capture"

        fun dir(context: Context) = File(context.cacheDir, DIR)

        /** A new empty file for a photo; files older than a day are swept first. */
        fun newFile(context: Context): File {
            val dir = dir(context).apply { mkdirs() }
            val old = System.currentTimeMillis() - DAY_MS
            dir.listFiles()?.forEach { if (it.lastModified() < old) it.delete() }
            return File.createTempFile("capture-", ".jpg", dir)
        }

        fun uriFor(context: Context, file: File): Uri =
            Uri.Builder().scheme("content").authority(authority(context)).appendPath(file.name).build()

        /** The file behind one of this provider's URIs, or null. */
        fun fileFor(context: Context, uri: Uri): File? {
            if (uri.authority != authority(context)) return null
            val segments = uri.pathSegments
            if (segments.size != 1 || !NAME.matches(segments[0])) return null
            val root = dir(context).canonicalFile
            val file = File(root, segments[0]).canonicalFile
            return if (file.parentFile == root && file.isFile) file else null
        }
    }

    override fun onCreate() = true

    private fun file(uri: Uri): File = fileFor(context ?: throw FileNotFoundException(), uri) ?: throw FileNotFoundException(uri.toString())

    /** Read, or write (the camera app's EXTRA_OUTPUT): never create. */
    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor =
        ParcelFileDescriptor.open(file(uri), ParcelFileDescriptor.parseMode(mode))

    override fun getType(uri: Uri): String? = "image/jpeg"

    override fun query(uri: Uri, projection: Array<String>?, selection: String?, selectionArgs: Array<String>?, sortOrder: String?): Cursor? {
        val f = file(uri)
        val cols = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        return MatrixCursor(cols).apply {
            addRow(cols.map { when (it) { OpenableColumns.DISPLAY_NAME -> f.name; OpenableColumns.SIZE -> f.length(); else -> null } }.toTypedArray<Any?>())
        }
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<String>?) = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<String>?) = 0
}
