package dev.oriel

import android.annotation.SuppressLint
import android.content.Context
import android.content.MutableContextWrapper
import android.graphics.Bitmap
import android.graphics.Color
import android.net.Uri
import android.os.Message
import android.util.Log
import android.view.View
import android.view.ViewGroup
import android.webkit.ConsoleMessage
import android.webkit.PermissionRequest
import android.webkit.RenderProcessGoneDetail
import android.webkit.ValueCallback
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.webkit.JavaScriptReplyProxy
import androidx.webkit.WebMessageCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import java.io.ByteArrayInputStream

/**
 * One Oriel window: a WebView that lives as long as the window, shown in an
 * [OrielActivity] while the window is visible. With the native renderer
 * (FLAG_NATIVE, -Dnative_ui) it is a [NuiView] instead and no WebView is
 * ever created. The WebView is created with a
 * [MutableContextWrapper] so it survives its Activity (hidden windows keep
 * running, recreated Activities get the same page).
 */
@SuppressLint("SetJavaScriptEnabled")
internal class OrielWindow(
    val id: Int,
    val label: String,
    var title: String,
    val url: String,
    var width: Int,
    var height: Int,
    val minWidth: Int,
    val minHeight: Int,
    val flags: Int,
    private val bridgeScript: String,
    private val originRules: Set<String>,
) {
    companion object {
        const val FLAG_VISIBLE = 1 shl 0
        const val FLAG_RESIZABLE = 1 shl 1
        const val FLAG_DECORATIONS = 1 shl 2
        const val FLAG_TRANSPARENT = 1 shl 3
        const val FLAG_DEVTOOLS = 1 shl 4
        const val FLAG_FOCUS = 1 shl 5
        const val FLAG_MAIN = 1 shl 6
        const val FLAG_MEDIA = 1 shl 7
        const val FLAG_NATIVE = 1 shl 8

        const val HELLO = "__oriel_hello__"
        const val APP_ORIGIN = "https://app.localhost"
        const val ISOLATION_ORIGIN = "https://isolation.localhost"
        private const val TAG = "Oriel"
        private const val MAX_QUEUED = 256
    }

    private val context = MutableContextWrapper(OrielRuntime.app)
    val native get() = flags and FLAG_NATIVE != 0
    var webView: WebView? = if (native) null else createWebView()
        private set
    private val nui: NuiView? = if (native) NuiView(context, id) { w, h ->
        val density = context.resources.displayMetrics.density
        cssWidth = (w / density).toInt()
        cssHeight = (h / density).toInt()
    }.also { Nui.views[id] = it } else null
    /** What the Activity shows. */
    private val content: View get() = nui ?: webView!!
    var activity: OrielActivity? = null
    /** The current main-frame document's reply channel (from its hello). */
    private var replyProxy: JavaScriptReplyProxy? = null
    /** Messages posted before the document said hello. */
    private val queued = ArrayDeque<String>()
    var fullscreen = false
    var maximized = false
    /** The page's size in CSS px (dp), updated on layout. */
    var cssWidth = 0
    var cssHeight = 0
    var destroyed = false
        private set

    val isMain get() = flags and FLAG_MAIN != 0
    val isShown get() = activity?.let { !it.isFinishing && it.hasWindowFocusOrVisible() } ?: false

    private fun createWebView(): WebView {
        val view = WebView(context)
        WebView.setWebContentsDebuggingEnabled(flags and FLAG_DEVTOOLS != 0)
        view.settings.apply {
            javaScriptEnabled = true
            domStorageEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            mediaPlaybackRequiresUserGesture = false
            javaScriptCanOpenWindowsAutomatically = true
            setSupportMultipleWindows(true)
            loadWithOverviewMode = false
            useWideViewPort = false
            builtInZoomControls = false
        }
        if (flags and FLAG_TRANSPARENT != 0) view.setBackgroundColor(Color.TRANSPARENT)
        view.webViewClient = Client()
        view.webChromeClient = Chrome()
        view.addOnLayoutChangeListener { v, l, t, r, b, _, _, _, _ ->
            val density = v.resources.displayMetrics.density
            cssWidth = ((r - l) / density).toInt()
            cssHeight = ((b - t) / density).toInt()
        }
        installBridge(view)
        return view
    }

    private fun installBridge(view: WebView) {
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER)) {
            Log.e(TAG, "this WebView has no WebMessageListener: update Android System WebView; the page gets no IPC")
            return
        }
        WebViewCompat.addWebMessageListener(view, "__orielNative", originRules, object : WebViewCompat.WebMessageListener {
            override fun onPostMessage(view: WebView, message: WebMessageCompat, sourceOrigin: Uri, isMainFrame: Boolean, replyProxy: JavaScriptReplyProxy) {
                onMessage(message.data ?: return, sourceOrigin, isMainFrame, replyProxy)
            }
        })
        if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            WebViewCompat.addDocumentStartJavaScript(view, bridgeScript, originRules)
        } else {
            Log.w(TAG, "this WebView can't add document-start scripts: the bridge is injected when each page starts loading")
        }
    }

    private fun onMessage(data: String, origin: Uri, isMainFrame: Boolean, proxy: JavaScriptReplyProxy) {
        if (!isMainFrame) {
            // Only main frames are served: refuse right here.
            val id = Regex("\"id\"\\s*:\\s*(\\d+)").find(data)?.groupValues?.get(1)
            if (id != null) proxy.postMessage("{\"__oriel_reply\":true,\"id\":$id,\"error\":\"Forbidden\"}")
            return
        }
        if (data == HELLO) {
            replyProxy = proxy
            while (queued.isNotEmpty()) proxy.postMessage(queued.removeFirst())
            return
        }
        NativeLib.onMessage(id, data.bytes(), origin.toString().trimEnd('/').bytes())
    }

    /** A reply or event for the current document (queued until its hello). */
    fun post(json: String) {
        val proxy = replyProxy
        if (proxy != null) {
            proxy.postMessage(json)
        } else {
            if (queued.size >= MAX_QUEUED) queued.removeFirst()
            queued.addLast(json)
        }
    }

    fun eval(script: String) = webView?.evaluateJavascript(script, null)

    fun load(target: String) = webView?.loadUrl(target)

    /** The back button: the page's history first. */
    fun goBack(): Boolean {
        if (nui != null) return NuiNative.back(id)
        val view = webView ?: return false
        if (!view.canGoBack()) return false
        view.goBack()
        return true
    }

    /** Show the WebView in `host` (moving it out of an old Activity). */
    fun attachTo(host: OrielActivity) {
        activity = host
        context.baseContext = host
        (content.parent as? ViewGroup)?.removeView(content)
        host.setContent(content)
        host.applyTitle(title)
        host.applyFullscreen(fullscreen)
    }

    fun detachFrom(host: OrielActivity) {
        if (activity !== host) return
        activity = null
        context.baseContext = OrielRuntime.app
        (content.parent as? ViewGroup)?.removeView(content)
    }

    fun destroy() {
        destroyed = true
        activity?.finishByRuntime()
        activity = null
        (content.parent as? ViewGroup)?.removeView(content)
        if (nui != null) Nui.views.remove(id)
        webView?.stopLoading()
        webView?.destroy()
        queued.clear()
        replyProxy = null
    }

    /** The renderer died: a fresh WebView on the same URL. */
    private fun recreate() {
        val host = activity
        val old = webView ?: return
        (old.parent as? ViewGroup)?.removeView(old)
        old.destroy()
        replyProxy = null
        webView = createWebView()
        host?.let { attachTo(it) }
        load(url)
    }

    private inner class Client : WebViewClient() {
        override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
            val u = request.url.toString()
            if (!u.startsWith("$APP_ORIGIN/") && u != APP_ORIGIN && !u.startsWith("$ISOLATION_ORIGIN/") && u != ISOLATION_ORIGIN) return null
            val encoded = NativeLib.serve(id, u.bytes()) ?: return null
            return decodeResponse(encoded)
        }

        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
            val u = request.url.toString()
            // The isolation frame is an iframe of the app's page.
            if (!request.isForMainFrame && u.startsWith(ISOLATION_ORIGIN)) return false
            return !NativeLib.navigation(id, u.bytes(), request.hasGesture())
        }

        override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
            replyProxy = null // a new document: it says hello again
            if (!WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) view.evaluateJavascript(bridgeScript, null)
        }

        override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
            if (request.isForMainFrame) {
                Log.w(TAG, "load failed: ${request.url} (${error.errorCode} ${error.description})")
                NativeLib.onLoadFailed(id)
            }
        }

        override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
            Log.e(TAG, "web content process gone (crashed: ${detail.didCrash()}); reloading")
            if (view === webView) recreate()
            return true
        }
    }

    private inner class Chrome : WebChromeClient() {
        /** window.open / target=_blank: capture the URL, let Oriel decide. */
        override fun onCreateWindow(view: WebView, isDialog: Boolean, isUserGesture: Boolean, resultMsg: Message): Boolean {
            val probe = WebView(view.context)
            probe.webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(v: WebView, request: WebResourceRequest): Boolean {
                    NativeLib.newWindow(id, request.url.toString().bytes(), isUserGesture)
                    v.post { v.destroy() }
                    return true
                }
            }
            val transport = resultMsg.obj as WebView.WebViewTransport
            transport.webView = probe
            resultMsg.sendToTarget()
            return true
        }

        override fun onCloseWindow(window: WebView) {
            NativeLib.onCloseRequested(id)
        }

        override fun onPermissionRequest(request: PermissionRequest) {
            var kinds = 0
            for (r in request.resources) {
                if (r == PermissionRequest.RESOURCE_AUDIO_CAPTURE) kinds = kinds or 1
                if (r == PermissionRequest.RESOURCE_VIDEO_CAPTURE) kinds = kinds or 2
            }
            val origin = request.origin.toString().trimEnd('/')
            if (kinds == 0 || flags and FLAG_MEDIA == 0 || !NativeLib.allowMedia(id, origin.bytes(), kinds)) {
                request.deny()
                return
            }
            val needed = mutableListOf<Int>()
            if (kinds and 1 != 0) needed += OrielPermissions.MICROPHONE
            if (kinds and 2 != 0) needed += OrielPermissions.CAMERA
            OrielPermissions.ensure(needed) { granted -> if (granted) request.grant(request.resources) else request.deny() }
        }

        override fun onShowFileChooser(view: WebView, callback: ValueCallback<Array<Uri>>, params: FileChooserParams): Boolean {
            val host = activity ?: return false
            return host.chooseFiles(params.createIntent(), params.mode == FileChooserParams.MODE_OPEN_MULTIPLE, callback)
        }

        override fun onConsoleMessage(message: ConsoleMessage): Boolean {
            Log.d(TAG, "[$label] ${message.message()} (${message.sourceId()}:${message.lineNumber()})")
            return true
        }
    }

    /** "status\nmime\nName: value\n...\n\nbody" (src/platform/android/scheme.zig). */
    private fun decodeResponse(bytes: ByteArray): WebResourceResponse? {
        var nl = bytes.indexOf('\n'.code.toByte())
        if (nl < 0) return null
        val status = String(bytes, 0, nl, Charsets.US_ASCII).toIntOrNull() ?: return null
        var start = nl + 1
        nl = indexOf(bytes, '\n'.code.toByte(), start)
        if (nl < 0) return null
        val mime = String(bytes, start, nl - start, Charsets.US_ASCII)
        start = nl + 1
        val headers = HashMap<String, String>()
        while (true) {
            nl = indexOf(bytes, '\n'.code.toByte(), start)
            if (nl < 0) return null
            if (nl == start) {
                start = nl + 1
                break
            }
            val line = String(bytes, start, nl - start, Charsets.UTF_8)
            val colon = line.indexOf(':')
            if (colon > 0) headers[line.substring(0, colon).trim()] = line.substring(colon + 1).trim()
            start = nl + 1
        }
        val body = ByteArrayInputStream(bytes, start, bytes.size - start)
        val mimeType = mime.substringBefore(';').trim()
        val charset = if (mimeType.startsWith("text/") || mimeType.endsWith("javascript") || mimeType.endsWith("json")) "utf-8" else null
        val reason = when (status) { 200 -> "OK"; 404 -> "Not Found"; else -> "Status" }
        return WebResourceResponse(mimeType, charset, status, reason, headers, body)
    }

    private fun indexOf(bytes: ByteArray, b: Byte, from: Int): Int {
        for (i in from until bytes.size) if (bytes[i] == b) return i
        return -1
    }
}

internal fun Context.dp(px: Int): Int = (px / resources.displayMetrics.density).toInt()
internal fun Context.px(dp: Int): Int = (dp * resources.displayMetrics.density).toInt()
