package dev.oriel

import android.content.Context
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import java.util.Locale

/**
 * oriel.tts's `.system` engine on Android: the device's TextToSpeech (Google's
 * voices on most phones), nothing to download. One utterance at a time, cut
 * into pieces the engine takes (getMaxSpeechInputLength); its progress goes
 * to Zig as NativeLib.onTtsEvent(id, kind): 0 started, 1 finished, 2 failed,
 * 3 stopped (src/modules/tts/android.zig).
 */
internal object OrielTts {
    private const val TAG = "OrielTts"
    private const val STARTED = 0
    private const val FINISHED = 1
    private const val FAILED = 2
    private const val STOPPED = 3

    private var tts: TextToSpeech? = null
    private var ready = false
    /** An utterance asked for before the engine was ready. */
    private var queued: (() -> Unit)? = null
    /** The current utterance: its id and how many pieces are left. */
    private var current = 0L
    private var left = 0

    private fun engine(context: Context): TextToSpeech {
        tts?.let { return it }
        val t = TextToSpeech(context.applicationContext) { status ->
            ready = status == TextToSpeech.SUCCESS
            if (!ready) Log.w(TAG, "the TextToSpeech engine didn't start ($status)")
            val q = queued
            queued = null
            if (ready) q?.invoke() else if (current != 0L) event(current, FAILED)
        }
        t.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String) {
                val id = idOf(utteranceId)
                if (id == current && utteranceId.endsWith(":0")) event(id, STARTED)
            }

            override fun onDone(utteranceId: String) {
                val id = idOf(utteranceId)
                if (id != current) return
                left -= 1
                if (left <= 0) {
                    current = 0L
                    event(id, FINISHED)
                }
            }

            @Deprecated("API 21's")
            override fun onError(utteranceId: String) = failed(utteranceId)
            override fun onError(utteranceId: String, errorCode: Int) = failed(utteranceId)

            override fun onStop(utteranceId: String, interrupted: Boolean) {
                val id = idOf(utteranceId)
                if (id == current) {
                    current = 0L
                    event(id, STOPPED)
                }
            }

            private fun failed(utteranceId: String) {
                val id = idOf(utteranceId)
                if (id == current) {
                    current = 0L
                    event(id, FAILED)
                }
            }
        })
        tts = t
        return t
    }

    private fun idOf(utteranceId: String): Long = utteranceId.substringBefore(':').toLongOrNull() ?: -1L

    /** Read `text` (a BCP 47 language, "" = the device's), at `rate` (1 = normal). */
    fun speak(context: Context, id: Long, text: String, language: String, rate: Float) {
        val t = engine(context)
        if (current != 0L) {
            val old = current
            current = 0L
            t.stop()
            event(old, STOPPED)
        }
        current = id
        val go = {
            if (current == id) {
                if (language.isNotEmpty()) {
                    val r = t.setLanguage(Locale.forLanguageTag(language))
                    if (r == TextToSpeech.LANG_MISSING_DATA || r == TextToSpeech.LANG_NOT_SUPPORTED)
                        Log.w(TAG, "no voice for $language: the device's default")
                }
                t.setSpeechRate(rate)
                val pieces = split(text, maxOf(TextToSpeech.getMaxSpeechInputLength() - 16, 200))
                left = pieces.size
                if (pieces.isEmpty()) {
                    current = 0L
                    event(id, FINISHED)
                } else {
                    for ((i, p) in pieces.withIndex()) {
                        val mode = if (i == 0) TextToSpeech.QUEUE_FLUSH else TextToSpeech.QUEUE_ADD
                        if (t.speak(p, mode, Bundle(), "$id:$i") != TextToSpeech.SUCCESS) {
                            if (current == id) {
                                current = 0L
                                t.stop()
                                event(id, FAILED)
                            }
                            break
                        }
                    }
                }
            }
        }
        if (ready) go() else queued = go
    }

    fun stop() {
        val old = current
        current = 0L
        queued = null
        tts?.stop()
        if (old != 0L) event(old, STOPPED)
    }

    /** Whether the device has a TextToSpeech engine at all. */
    fun available(context: Context): Boolean =
        context.packageManager.queryIntentServices(android.content.Intent(TextToSpeech.Engine.INTENT_ACTION_TTS_SERVICE), 0).isNotEmpty()

    /** Pieces of at most `max` chars, cut at sentence ends, else spaces. */
    private fun split(text: String, max: Int): List<String> {
        val out = ArrayList<String>()
        var rest = text.trim()
        while (rest.length > max) {
            var cut = rest.lastIndexOfAny(charArrayOf('.', '!', '?', '\n'), max)
            if (cut < max / 2) cut = rest.lastIndexOf(' ', max)
            if (cut <= 0) cut = max
            out += rest.substring(0, cut + 1).trim()
            rest = rest.substring(cut + 1).trim()
        }
        if (rest.isNotEmpty()) out += rest
        return out
    }

    private fun event(id: Long, kind: Int) {
        try {
            NativeLib.onTtsEvent(id, kind)
        } catch (_: UnsatisfiedLinkError) {}
    }
}
