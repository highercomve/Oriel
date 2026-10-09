package dev.oriel

import android.app.Activity
import android.content.Intent

/** Generated registration only. Implementations belong to the app's sources. */
internal object OrielAppExtensions {
    val registered: List<OrielAndroidExtension> by lazy {
        listOf<OrielAndroidExtension>().also { extensions ->
            extensions.forEachIndexed { index, extension -> extension.onRegistered(OrielAndroidExtensionContext(index)) }
        }
    }

    private fun owner(requestCode: Int): OrielAndroidExtension? =
        registered.getOrNull((requestCode - 0x8000) / 256)

    fun activityResult(activity: Activity, requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode in 0x8000..0xBFFF) return owner(requestCode)?.onActivityResult(activity, requestCode, resultCode, data) ?: false
        return registered.any { it.onActivityResult(activity, requestCode, resultCode, data) }
    }

    fun permissionResult(activity: Activity, requestCode: Int, permissions: Array<String>, grantResults: IntArray): Boolean {
        if (requestCode in 0x8000..0xBFFF) return owner(requestCode)?.onRequestPermissionsResult(activity, requestCode, permissions, grantResults) ?: false
        return registered.any { it.onRequestPermissionsResult(activity, requestCode, permissions, grantResults) }
    }
}
