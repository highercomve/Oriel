package dev.oriel

import android.util.Log
import java.util.concurrent.ConcurrentHashMap

/**
 * The app extensions' registry (AppOptions.extensions, regenerated on every
 * build) and the calls liboriel.so makes through [OrielRuntime]
 * (src/platform/android/extensions.zig). Replies start with a status byte:
 * 0 ok, 1 failed (code NUL message), 2 unavailable, 3 cancelled.
 */
internal object OrielExtensions {
    private const val TAG = "Oriel"
    private const val OK: Byte = 0
    private const val FAILED: Byte = 1
    private const val UNAVAILABLE: Byte = 2

    /** The declared classes, constructed directly (R8 keeps them by name). */
    private fun create(name: String): OrielAppExtension? = when (name) {
        "showcase.echo" -> dev.oriel.showcase.EchoExtension()
        else -> null
    }

    private val loaded = ConcurrentHashMap<String, OrielAppExtension>()

    /** The extension's instance, made and loaded once (its first worker). */
    fun load(name: String): Boolean {
        if (loaded.containsKey(name)) return true
        val ext = create(name) ?: return false
        try {
            ext.onLoad(OrielExtensionContext(name))
        } catch (t: Throwable) {
            Log.e(TAG, "extension $name: onLoad failed", t)
        }
        loaded[name] = ext
        return true
    }

    fun call(name: String, method: String, input: ByteArray, id: Long): ByteArray {
        val ext = loaded[name] ?: return byteArrayOf(UNAVAILABLE)
        return try {
            val reply = ext.call(method, input, OrielCall(name, id))
            ByteArray(reply.size + 1).also {
                it[0] = OK
                System.arraycopy(reply, 0, it, 1, reply.size)
            }
        } catch (e: OrielExtensionError) {
            failure(e.code, e.message ?: "")
        } catch (t: Throwable) {
            Log.w(TAG, "extension $name.$method failed", t)
            failure(t.javaClass.simpleName, t.message ?: t.toString())
        }
    }

    fun lifecycle(name: String, event: String, level: String?) {
        val ext = loaded[name] ?: return
        try {
            ext.onLifecycle(event, level)
        } catch (t: Throwable) {
            Log.e(TAG, "extension $name: onLifecycle($event) failed", t)
        }
    }

    private fun failure(code: String, message: String): ByteArray {
        val c = code.bytes()
        val m = message.bytes()
        val out = ByteArray(2 + c.size + m.size)
        out[0] = FAILED
        System.arraycopy(c, 0, out, 1, c.size)
        out[1 + c.size] = 0
        System.arraycopy(m, 0, out, 2 + c.size, m.size)
        return out
    }
}
