package dev.oriel

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.accessibility.AccessibilityManager

/**
 * Oriel's permission kinds (src/core/permissions/common.zig, in order) as
 * Android runtime permissions. Statuses: 0 granted, 1 denied, 2 prompt,
 * 3 unknown.
 */
internal object OrielPermissions {
    const val MICROPHONE = 0
    const val CAMERA = 1
    const val SCREEN_CAPTURE = 2
    const val ACCESSIBILITY = 3
    const val LOCATION = 4
    const val NOTIFICATIONS = 5
    const val SYSTEM_AUDIO = 6

    private const val GRANTED = 0
    private const val DENIED = 1
    private const val PROMPT = 2

    /** Request codes: 0x4E00 + kind for Oriel's requests, 0x4E80 for internal ones. */
    private const val BASE = 0x4E00
    private const val INTERNAL = 0x4E80
    private var internalDone: ((Boolean) -> Unit)? = null

    private fun permission(kind: Int): String? = when (kind) {
        MICROPHONE -> Manifest.permission.RECORD_AUDIO
        CAMERA -> Manifest.permission.CAMERA
        LOCATION -> Manifest.permission.ACCESS_FINE_LOCATION
        NOTIFICATIONS -> if (Build.VERSION.SDK_INT >= 33) Manifest.permission.POST_NOTIFICATIONS else null
        else -> null
    }

    private val prefs get() = OrielRuntime.app.getSharedPreferences("dev.oriel.permissions", Context.MODE_PRIVATE)

    fun status(kind: Int): Int {
        return when (kind) {
            SCREEN_CAPTURE, SYSTEM_AUDIO -> PROMPT // MediaProjection asks every session
            // Only an app with an accessibility service has something to enable.
            ACCESSIBILITY -> if (!hasAccessibilityService()) DENIED else if (accessibilityEnabled()) GRANTED else PROMPT
            NOTIFICATIONS -> if (Build.VERSION.SDK_INT < 33) {
                if (OrielRuntime.notificationsEnabled()) GRANTED else DENIED
            } else runtimeStatus(kind)
            else -> if (permission(kind) == null) 3 else runtimeStatus(kind)
        }
    }

    private fun runtimeStatus(kind: Int): Int {
        val p = permission(kind) ?: return GRANTED
        if (OrielRuntime.app.checkSelfPermission(p) == PackageManager.PERMISSION_GRANTED) return GRANTED
        // Denied for good: asked before and Android won't show the prompt again.
        val host = OrielRuntime.foreground
        val asked = prefs.getBoolean("asked.$kind", false)
        if (asked && host != null && !host.shouldShowRequestPermissionRationale(p)) return DENIED
        return PROMPT
    }

    private fun accessibilityEnabled(): Boolean {
        val am = OrielRuntime.app.getSystemService(AccessibilityManager::class.java)
        return am.getEnabledAccessibilityServiceList(-1).any { it.resolveInfo.serviceInfo.packageName == OrielRuntime.app.packageName }
    }

    /** Whether the app declares an AccessibilityService. */
    private fun hasAccessibilityService(): Boolean {
        val app = OrielRuntime.app
        val intent = Intent("android.accessibilityservice.AccessibilityService").setPackage(app.packageName)
        return app.packageManager.queryIntentServices(intent, 0).isNotEmpty()
    }

    /** Show the system prompt; the answer goes to NativeLib.onPermissionResult. */
    fun request(kind: Int): Boolean {
        // Without a service the settings page has nothing of the app's to turn on.
        if (kind == ACCESSIBILITY && !hasAccessibilityService()) return false
        if (kind == ACCESSIBILITY) return openSettings(kind).also { if (it) NativeLib.onPermissionResult(kind, status(kind)) }
        val p = permission(kind) ?: return false
        val host = OrielRuntime.foreground ?: return false
        prefs.edit().putBoolean("asked.$kind", true).apply()
        host.requestPermissions(arrayOf(p), BASE + kind)
        return true
    }

    /** For the webview's own requests: every kind granted, asking as needed. */
    fun ensure(kinds: List<Int>, done: (Boolean) -> Unit) {
        val missing = kinds.mapNotNull { permission(it) }.filter { OrielRuntime.app.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isEmpty()) return done(true)
        val host = OrielRuntime.foreground ?: return done(false)
        internalDone?.invoke(false)
        internalDone = done
        host.requestPermissions(missing.toTypedArray(), INTERNAL)
    }

    fun onResult(activity: OrielActivity, requestCode: Int, permissions: Array<String>, results: IntArray) {
        if (requestCode == INTERNAL) {
            val done = internalDone ?: return
            internalDone = null
            done(results.isNotEmpty() && results.all { it == PackageManager.PERMISSION_GRANTED })
            return
        }
        val kind = requestCode - BASE
        if (kind !in 0..6) return
        val granted = results.isNotEmpty() && results.all { it == PackageManager.PERMISSION_GRANTED }
        val st = if (granted) GRANTED else if (permissions.any { !activity.shouldShowRequestPermissionRationale(it) }) DENIED else PROMPT
        NativeLib.onPermissionResult(kind, st)
    }

    fun openSettings(kind: Int): Boolean {
        val app = OrielRuntime.app
        val intent = when (kind) {
            ACCESSIBILITY -> Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
            NOTIFICATIONS -> Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, app.packageName)
            else -> Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", app.packageName, null))
        }.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        return try {
            app.startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }
}
