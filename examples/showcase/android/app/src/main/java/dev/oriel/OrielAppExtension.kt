package dev.oriel

import android.app.Activity
import android.content.Context
import android.os.Handler
import android.os.Looper
import java.io.File

/**
 * An app extension's Android implementation (AppOptions.extensions in
 * build.zig, `.android.class`): Zig calls it by name with
 * `oriel.extensions.get(name).call(...)`, the page only through what Zig
 * exposes (docs/extensions.md).
 *
 * The class needs a public zero-argument constructor; the generated
 * [OrielExtensions] registry constructs it (no reflection) on the first call
 * or `load()`. A class may also implement [OrielAndroidExtension] for its
 * Activity and WebView hooks.
 */
interface OrielAppExtension {
    /**
     * One call, on the extension's own worker thread (one at a time unless
     * the build sets `.concurrency`): block as long as needed, and poll
     * [OrielCall.isCancelled] in long work. Return the reply (JSON by
     * convention); throw [OrielExtensionError] to fail with a code.
     */
    fun call(method: String, input: ByteArray, call: OrielCall): ByteArray

    /**
     * oriel.lifecycle, on the main thread: "background", "foreground",
     * "memory_pressure" (level "moderate" or "critical"), "suspend",
     * "resume", "terminating". Return quickly.
     */
    fun onLifecycle(event: String, level: String?) {}

    /** Once, on the worker, before the first call. */
    fun onLoad(ctx: OrielExtensionContext) {}
}

/** A failure the caller sees as error.ExtensionFailed with this code and message. */
class OrielExtensionError(val code: String, message: String) : Exception(message)

/** What an extension may use outside a call: its name, events, the app's directories. */
open class OrielExtensionContext internal constructor(val extension: String) {
    /** The application context. */
    val context: Context get() = OrielRuntime.app

    /** The Activity in front, or null (the app may be in the background). */
    val activity: Activity? get() = OrielRuntime.foreground

    val filesDir: File get() = OrielRuntime.app.filesDir
    val cacheDir: File get() = OrielRuntime.app.cacheDir

    /** An event for Zig's onEvent handlers and the page (`extension:<name>`). */
    fun emit(name: String, data: ByteArray) = NativeLib.onExtensionEvent(extension.bytes(), name.bytes(), data)

    /** Run [block] on the main thread (UI work). */
    fun runOnUi(block: () -> Unit) {
        if (Looper.myLooper() == Looper.getMainLooper()) block() else ui.post(block)
    }

    private companion object {
        val ui = Handler(Looper.getMainLooper())
    }
}

/** One call: [isCancelled] turns true when the caller cancels or times out. */
class OrielCall internal constructor(extension: String, private val id: Long) : OrielExtensionContext(extension) {
    val isCancelled: Boolean get() = NativeLib.extensionCancelled(id)
}
