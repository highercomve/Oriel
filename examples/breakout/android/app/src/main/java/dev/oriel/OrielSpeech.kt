package dev.oriel

import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import java.util.Locale

/**
 * The system speech recognizer for `oriel.dictation`'s `.system` engine
 * (src/modules/dictation/android.zig): on a Pixel, Google's on-device model.
 * Continuous dictation: Android's recognizer stops after each utterance,
 * so it restarts until [stop]. Results go to Zig as [NativeLib.onSpeech]
 * with a kind: 0 partial, 1 final, 2 level (0-100), 3 error (the code),
 * 4 ended (after [stop]). UI thread only, like every SpeechRecognizer call.
 */
internal object OrielSpeech {
    private var recognizer: SpeechRecognizer? = null
    private var intent: Intent? = null
    private var active = false
    private var downloadAsked = false

    /** Recognizers want a region ("es-ES", not "es"): the device's own if it
     *  speaks that language, else the language's most common one. */
    private fun tag(language: String): String {
        if (language.contains('-')) return language
        val device = Locale.getDefault()
        if (device.language == language && device.country.isNotEmpty()) return "$language-${device.country}"
        val region = mapOf(
            "en" to "US", "es" to "ES", "de" to "DE", "fr" to "FR", "it" to "IT", "pt" to "BR", "nl" to "NL",
            "ja" to "JP", "ko" to "KR", "zh" to "CN", "ru" to "RU", "pl" to "PL", "tr" to "TR", "sv" to "SE",
        )[language]
        return if (region != null) "$language-$region" else language
    }

    /** Bit 0: a recognizer is installed; bit 1: it runs on the device. */
    fun available(): Int {
        val ctx = OrielRuntime.app
        var bits = 0
        if (SpeechRecognizer.isRecognitionAvailable(ctx)) bits = bits or 1
        if (Build.VERSION.SDK_INT >= 31 && SpeechRecognizer.isOnDeviceRecognitionAvailable(ctx)) bits = bits or 3
        return bits
    }

    fun start(language: String, onDevice: Boolean): Boolean {
        stopNow()
        val ctx = OrielRuntime.app
        val r = try {
            if (onDevice && Build.VERSION.SDK_INT >= 31 && SpeechRecognizer.isOnDeviceRecognitionAvailable(ctx)) {
                SpeechRecognizer.createOnDeviceSpeechRecognizer(ctx)
            } else if (SpeechRecognizer.isRecognitionAvailable(ctx)) {
                SpeechRecognizer.createSpeechRecognizer(ctx)
            } else {
                return false
            }
        } catch (e: Exception) {
            return false
        }
        val i = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            if (language.isNotEmpty() && language != "auto") {
                putExtra(RecognizerIntent.EXTRA_LANGUAGE, tag(language))
            } else if (Build.VERSION.SDK_INT >= 34) {
                // "auto": detect among the device's language and common ones
                // (Android 14+; older recognizers use the device's language).
                putExtra(RecognizerIntent.EXTRA_ENABLE_LANGUAGE_DETECTION, true)
                val langs = linkedSetOf(tag(Locale.getDefault().language), "en-US", "es-ES", "de-DE", "fr-FR")
                putExtra(RecognizerIntent.EXTRA_LANGUAGE_DETECTION_ALLOWED_LANGUAGES, ArrayList(langs))
                putExtra(RecognizerIntent.EXTRA_ENABLE_LANGUAGE_SWITCH, RecognizerIntent.LANGUAGE_SWITCH_BALANCED)
            }
            // Dictation: long pauses don't end the session (we restart anyway).
            putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, 1500L)
            if (Build.VERSION.SDK_INT >= 33) putExtra(RecognizerIntent.EXTRA_ENABLE_FORMATTING, RecognizerIntent.FORMATTING_OPTIMIZE_QUALITY)
        }
        downloadAsked = false
        r.setRecognitionListener(listener)
        recognizer = r
        intent = i
        active = true
        return try {
            r.startListening(i)
            true
        } catch (e: Exception) {
            stopNow()
            false
        }
    }

    /** Stop listening: the last results arrive, then kind 4 (ended). */
    fun stop() {
        if (!active) {
            send(4, "")
            return
        }
        active = false
        try {
            recognizer?.stopListening()
        } catch (e: Exception) {
            finish()
        }
    }

    private fun stopNow() {
        active = false
        recognizer?.destroy()
        recognizer = null
    }

    private fun finish() {
        stopNow()
        send(4, "")
    }

    private fun restart() {
        val r = recognizer ?: return
        val i = intent ?: return
        try {
            r.startListening(i)
        } catch (e: Exception) {
            finish()
        }
    }

    private fun send(kind: Int, text: String) = NativeLib.onSpeech(kind, text.bytes())

    private fun best(results: Bundle?): String =
        results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull() ?: ""

    private val listener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {}
        override fun onBeginningOfSpeech() {}
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() {}
        override fun onEvent(eventType: Int, params: Bundle?) {}

        /** dB, roughly -2 (quiet) to 10 (loud): 0-100 for the page. */
        override fun onRmsChanged(rmsdB: Float) {
            send(2, (((rmsdB + 2f) / 12f).coerceIn(0f, 1f) * 100).toInt().toString())
        }

        override fun onPartialResults(partialResults: Bundle?) {
            val text = best(partialResults)
            if (text.isNotEmpty()) send(0, text)
        }

        override fun onResults(results: Bundle?) {
            val text = best(results)
            if (text.isNotEmpty()) send(1, text)
            if (active) restart() else finish()
        }

        override fun onError(error: Int) {
            // No speech or nothing matched: normal between utterances.
            val quiet = error == SpeechRecognizer.ERROR_NO_MATCH || error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT
            if (active && quiet) {
                restart()
                return
            }
            // The language's pack isn't on the device: ask the system to fetch
            // it (Android 13+; the next session can use it).
            val missing = error == SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE || error == SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED
            if (missing && Build.VERSION.SDK_INT >= 33 && !downloadAsked) {
                downloadAsked = true
                try {
                    intent?.let { recognizer?.triggerModelDownload(it) }
                    send(3, "download")
                } catch (e: Exception) {
                    send(3, error.toString())
                }
                finish()
                return
            }
            if (!quiet) send(3, error.toString())
            finish()
        }
    }
}
