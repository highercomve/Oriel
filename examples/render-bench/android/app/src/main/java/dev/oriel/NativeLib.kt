package dev.oriel

/**
 * The natives of liboriel.so (src/platform/android/exports.zig, entry.zig).
 * Text crosses JNI as UTF-8 byte arrays: JNI's "modified UTF-8" would
 * mangle emoji.
 */
internal object NativeLib {
    /** 1 = started, 2 = already running, 0 = failed. */
    @JvmStatic external fun start(files: ByteArray, cache: ByteArray, external: ByteArray, args: Array<ByteArray>): Int
    @JvmStatic external fun isRunning(): Boolean
    @JvmStatic external fun onMessage(window: Int, data: ByteArray, origin: ByteArray)
    /** The encoded response ("status\nmime\nheaders\n\nbody"), or null for the network. */
    @JvmStatic external fun serve(window: Int, url: ByteArray): ByteArray?
    /** Whether the webview may load `url` (a top-level navigation). */
    @JvmStatic external fun navigation(window: Int, url: ByteArray, gesture: Boolean): Boolean
    @JvmStatic external fun newWindow(window: Int, url: ByteArray, gesture: Boolean)
    @JvmStatic external fun onCloseRequested(window: Int)
    @JvmStatic external fun onLoadFailed(window: Int)
    /** getUserMedia: kinds bit 0 microphone, bit 1 camera. */
    @JvmStatic external fun allowMedia(window: Int, origin: ByteArray, kinds: Int): Boolean
    @JvmStatic external fun onNewIntent(args: Array<ByteArray>)
    @JvmStatic external fun onPermissionResult(kind: Int, status: Int)
    @JvmStatic external fun onFileDialogResult(path: ByteArray?)
    /** A folder call's answer (OrielRuntime.FOLDER_* status); `request` is Zig's. */
    @JvmStatic external fun onFolderResult(request: Long, status: Int, data: ByteArray?)
    /** A tile tap, notification action, headset button or keyboard event (OrielSystem). */
    @JvmStatic external fun onSystemEvent(name: ByteArray, data: ByteArray)
    /** A registered keyboard shortcut was pressed (src/plugins/global_shortcut/android.zig). */
    @JvmStatic external fun onShortcut(id: ByteArray)
    /** The system speech recognizer (OrielSpeech): kind 0 partial, 1 final, 2 level, 3 error, 4 ended. */
    @JvmStatic external fun onSpeech(kind: Int, text: ByteArray)
    /** OrielMdns: the answer to mdnsRegister (kind 0; `name` is the announced name) or mdnsBrowse (kind 1). */
    @JvmStatic external fun onMdnsResult(kind: Int, id: Int, ok: Boolean, code: Int, name: ByteArray?)
    /** OrielMdns: a browser's found/lost event, in src/modules/network/mdns.zig's wire format. */
    @JvmStatic external fun onMdnsEvent(id: Int, event: ByteArray)
}

internal fun ByteArray.utf8(): String = String(this, Charsets.UTF_8)
internal fun String.bytes(): ByteArray = toByteArray(Charsets.UTF_8)
