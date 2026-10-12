package dev.oriel.showcase

import android.os.Build
import android.util.Log
import dev.oriel.OrielAppExtension
import dev.oriel.OrielCall
import dev.oriel.OrielExtensionContext
import dev.oriel.OrielExtensionError
import org.json.JSONException
import org.json.JSONObject

/**
 * The "showcase.echo" app extension on Android (build.zig, `.extensions`):
 * the contract of src/echo_desktop.zig and ios/EchoExtension.m. `reverse`
 * takes `{"text": "..."}`, answers `{"text": <reversed>, "platform",
 * "device"}` and emits it as the `reversed` event.
 */
class EchoExtension : OrielAppExtension {
    override fun onLoad(ctx: OrielExtensionContext) {
        Log.i(TAG, "${ctx.extension}: loaded")
    }

    override fun call(method: String, input: ByteArray, call: OrielCall): ByteArray {
        if (method != "reverse") throw OrielExtensionError("unknown_method", "showcase.echo has no method $method")
        val text = try {
            JSONObject(String(input, Charsets.UTF_8)).getString("text")
        } catch (e: JSONException) {
            throw OrielExtensionError("bad_input", "expected {\"text\": \"...\"}")
        }
        // By code point, so emoji stay whole.
        val reversed = text.codePoints().toArray().reversedArray().let { String(it, 0, it.size) }
        val reply = JSONObject()
            .put("text", reversed)
            .put("platform", "Kotlin on Android ${Build.VERSION.RELEASE}")
            .put("device", "${Build.MANUFACTURER} ${Build.MODEL}")
            .toString()
            .toByteArray(Charsets.UTF_8)
        call.emit("reversed", reply)
        return reply
    }

    override fun onLifecycle(event: String, level: String?) {
        Log.i(TAG, "showcase.echo: lifecycle $event${level?.let { " ($it)" } ?: ""}")
    }

    private companion object {
        const val TAG = "OrielShowcase"
    }
}
