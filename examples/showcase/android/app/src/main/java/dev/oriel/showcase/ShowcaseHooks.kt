package dev.oriel.showcase

import android.util.Log
import android.webkit.WebView
import dev.oriel.OrielAndroidHooks

/**
 * Android platform hooks (build.zig, `.android.hooks`): the counterpart of
 * src/platform_hooks.zig on the desktop. Logs each web view Oriel creates
 * and destroys (`adb logcat -s ShowcaseHooks`).
 */
class ShowcaseHooks : OrielAndroidHooks {
    override fun onWebViewCreated(view: WebView, windowLabel: String) {
        Log.i(TAG, "web view of \"$windowLabel\" created (android.webkit.WebView)")
    }

    override fun onWebViewDestroyed(view: WebView, windowLabel: String) {
        Log.i(TAG, "web view of \"$windowLabel\" destroyed")
    }

    private companion object {
        const val TAG = "ShowcaseHooks"
    }
}
