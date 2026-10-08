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

/**
 * Read-only access for other apps to files Oriel shares from its cache
 * (`<cacheDir>/oriel-shared/`): the clipboard's images. Not exported; access
 * is granted per URI (the clipboard grants it to the app pasting).
 */
class OrielFileProvider : ContentProvider() {
    companion object {
        private const val DIR = "oriel-shared"

        fun authority(context: Context) = "${context.packageName}.oriel.files"

        /** A fresh file in `<cacheDir>/oriel-shared/<group>/`. */
        fun newFile(context: Context, group: String, name: String): File {
            val dir = File(File(context.cacheDir, DIR), group)
            dir.deleteRecursively() // one shared file per group at a time
            dir.mkdirs()
            return File(dir, name)
        }

        fun uriFor(context: Context, file: File): Uri {
            val base = File(context.cacheDir, DIR).canonicalPath
            val rel = file.canonicalPath.removePrefix("$base/")
            return Uri.Builder().scheme("content").authority(authority(context)).encodedPath("/" + Uri.encode(rel, "/")).build()
        }
    }

    override fun onCreate() = true

    private fun fileFor(uri: Uri): File? {
        val context = context ?: return null
        val base = File(context.cacheDir, DIR).canonicalFile
        val file = File(base, uri.path ?: return null).canonicalFile
        return if (file.path.startsWith(base.path + "/") && file.isFile) file else null
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor? {
        if (mode != "r") throw SecurityException("read-only")
        val file = fileFor(uri) ?: throw java.io.FileNotFoundException(uri.toString())
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun getType(uri: Uri): String? = when (fileFor(uri)?.extension?.lowercase()) {
        "png" -> "image/png"
        "txt" -> "text/plain"
        null -> null
        else -> "application/octet-stream"
    }

    override fun query(uri: Uri, projection: Array<String>?, selection: String?, selectionArgs: Array<String>?, sortOrder: String?): Cursor? {
        val file = fileFor(uri) ?: return null
        val cols = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        val cursor = MatrixCursor(cols)
        cursor.addRow(cols.map { if (it == OpenableColumns.SIZE) file.length() else if (it == OpenableColumns.DISPLAY_NAME) file.name else null }.toTypedArray<Any?>())
        return cursor
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<String>?) = 0
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<String>?) = 0
}
