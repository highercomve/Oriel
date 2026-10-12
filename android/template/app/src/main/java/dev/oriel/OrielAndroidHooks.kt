package dev.oriel

import android.app.Activity
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Bundle
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebView

/**
 * Android platform hooks: app-owned classes registered by
 * AppOptions.android.hooks (docs/platform-hooks.md).
 *
 * Hooks are constructed once per process, in declaration order. Callbacks
 * run on the UI thread. A hook must key Activity/window-specific state by
 * that Activity/WebView, and release it in the corresponding destroyed callback.
 * Do not replace Oriel's WebView clients or bridge; use the interception hooks.
 */
interface OrielAndroidHooks {
    /** Supplies a request-code namespace that cannot collide with another hook. */
    fun onRegistered(context: OrielAndroidHooksContext) {}
    fun onActivityCreated(activity: Activity, savedInstanceState: Bundle?) {}
    fun onActivityStarted(activity: Activity) {}
    fun onActivityResumed(activity: Activity) {}
    fun onActivityPaused(activity: Activity) {}
    fun onActivityStopped(activity: Activity) {}
    fun onActivityDestroyed(activity: Activity) {}
    fun onSaveInstanceState(activity: Activity, outState: Bundle) {}
    fun onConfigurationChanged(activity: Activity, configuration: Configuration) {}
    fun onNewIntent(activity: Activity, intent: Intent) {}

    /** Called after Oriel installs its clients and bridge, before navigation. */
    fun onWebViewCreated(view: WebView, windowLabel: String) {}
    fun onWebViewAttached(activity: Activity, view: WebView, windowLabel: String) {}
    fun onWebViewDetached(activity: Activity, view: WebView, windowLabel: String) {}
    fun onWebViewDestroyed(view: WebView, windowLabel: String) {}

    /**
     * Return true to own the request and complete callback exactly once (null
     * on cancellation). False leaves callback untouched for the next hook
     * or Oriel's default picker. Only the first true result handles a request.
     */
    fun onShowFileChooser(activity: Activity, view: WebView, callback: ValueCallback<Array<Uri>>, params: WebChromeClient.FileChooserParams): Boolean = false

    /** Use context.requestCode(...) for requests; Oriel's 0x4F00..0x4FFF is reserved. */
    fun onActivityResult(activity: Activity, requestCode: Int, resultCode: Int, data: Intent?): Boolean = false
    fun onRequestPermissionsResult(activity: Activity, requestCode: Int, permissions: Array<String>, grantResults: IntArray): Boolean = false
}

/** Per-hook request-code namespace, assigned in build.zig declaration order. */
class OrielAndroidHooksContext internal constructor(private val index: Int) {
    init { require(index in 0..63) { "Hook index must be in 0..63" } }
    /** Each hook class owns 256 request codes, separate from Oriel and other hooks. */
    fun requestCode(localCode: Int): Int {
        require(localCode in 0..255) { "Hook request code must be in 0..255" }
        return 0x8000 + index * 256 + localCode
    }
}
