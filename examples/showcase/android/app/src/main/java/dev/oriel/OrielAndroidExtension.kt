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
 * App-owned Android behavior registered by AppOptions.android.extensions.
 *
 * Extensions are constructed once per process, in declaration order. Callbacks
 * run on the UI thread. An extension must key Activity/window-specific state by
 * that Activity/WebView, and release it in the corresponding destroyed callback.
 * Do not replace Oriel's WebView clients or bridge; use the interception hooks.
 */
interface OrielAndroidExtension {
    /** Supplies a request-code namespace that cannot collide with another extension. */
    fun onRegistered(context: OrielAndroidExtensionContext) {}
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
     * on cancellation). False leaves callback untouched for the next extension
     * or Oriel's default picker. Only the first true result handles a request.
     */
    fun onShowFileChooser(activity: Activity, view: WebView, callback: ValueCallback<Array<Uri>>, params: WebChromeClient.FileChooserParams): Boolean = false

    /** Use context.requestCode(...) for requests; Oriel's 0x4F00..0x4FFF is reserved. */
    fun onActivityResult(activity: Activity, requestCode: Int, resultCode: Int, data: Intent?): Boolean = false
    fun onRequestPermissionsResult(activity: Activity, requestCode: Int, permissions: Array<String>, grantResults: IntArray): Boolean = false
}

/** Per-extension request-code namespace, assigned in build.zig declaration order. */
class OrielAndroidExtensionContext internal constructor(private val index: Int) {
    init { require(index in 0..63) { "Extension index must be in 0..63" } }
    /** Each extension owns 256 request codes, separate from Oriel and other extensions. */
    fun requestCode(localCode: Int): Int {
        require(localCode in 0..255) { "Extension request code must be in 0..255" }
        return 0x8000 + index * 256 + localCode
    }
}
