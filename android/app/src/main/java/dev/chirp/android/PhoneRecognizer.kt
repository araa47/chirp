package dev.chirp.android

import android.annotation.SuppressLint
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.res.Resources
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import dev.chirp.android.ui.SettingsGroup
import dev.chirp.android.ui.SwitchRow

/** One live dictation as the keyboard sees it, whichever engine hears it. */
internal interface Utterance {
    val stopping: Boolean
    val polishing: Boolean
    /** False while an earlier part of a long dictation lands and listening goes on. */
    val landingLast: Boolean get() = true
    fun stop()
    fun cancel()
}

/** Android's own recogniser for one utterance; the fake in tests replaces it. Callbacks arrive on the main thread. */
internal interface PhoneRecognizer {
    interface Listener {
        fun partial(text: String)
        fun final(text: String)
        fun level(value: Double)
        fun error(code: Int)
    }
    fun start(listener: Listener, pauseMs: Long?)
    fun stop()
    /** Releases the microphone and the service binding; no callback follows. */
    fun cancel()
}

/** `createOnDeviceSpeechRecognizer`: Android promises recognition on the device, by the phone's speech service, never Chirp's Mac engine. */
internal class AndroidPhoneRecognizer(private val context: Context) : PhoneRecognizer {
    private var recognizer: SpeechRecognizer? = null
    override fun start(listener: PhoneRecognizer.Listener, pauseMs: Long?) {
        val created = SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        recognizer = created
        created.setRecognitionListener(object : RecognitionListener {
            override fun onReadyForSpeech(params: Bundle?) = Unit
            override fun onBeginningOfSpeech() = Unit
            override fun onRmsChanged(rmsdB: Float) = listener.level(((rmsdB + 2f) / 12f).toDouble())
            override fun onBufferReceived(buffer: ByteArray?) = Unit
            override fun onEndOfSpeech() = Unit
            override fun onError(error: Int) { if (recognizer === created) { release(); listener.error(error) } }
            override fun onResults(results: Bundle?) { if (recognizer === created) { release(); listener.final(best(results)) } }
            override fun onPartialResults(partialResults: Bundle?) { if (recognizer === created) listener.partial(best(partialResults)) }
            override fun onEvent(eventType: Int, params: Bundle?) = Unit
        })
        created.startListening(Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH)
            .putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            .putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            .putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            .apply { pauseMs?.let { putExtra(RecognizerIntent.EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, it) } })
    }
    override fun stop() { recognizer?.stopListening() }
    override fun cancel() { recognizer?.cancel(); release() }
    private fun release() { val old = recognizer; recognizer = null; old?.destroy() }
    private fun best(results: Bundle?) = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull().orEmpty()
    companion object {
        fun available(context: Context) = try { SpeechRecognizer.isOnDeviceRecognitionAvailable(context) } catch (_: Exception) { false }
    }
}

/** One phone-recognised utterance: raw text only, no clean-up, and what was heard survives a failure. */
internal class PhoneDictation(
    private val recognizer: PhoneRecognizer,
    private val changed: (DictationStatus, ServerEvent.Partial?) -> Unit,
    private val level: (Double) -> Unit,
    private val final: (ServerEvent.Final) -> Unit,
    private val kept: (String, DictationStatus) -> Unit,
    private val ended: () -> Unit,
    private val handler: Handler = Handler(Looper.getMainLooper()),
) : Utterance {
    private var live = false
    private var sequence = 0L
    private var heard: String? = null
    private var listening: DictationStatus = StatusLine.PHONE_LISTENING
    override var stopping = false
        private set
    override val polishing get() = false
    private val timeout = Runnable { fail(SpeechRecognizer.ERROR_CLIENT) }

    fun start(status: DictationStatus, pauseSeconds: Double?) {
        check(!live)
        live = true; listening = status
        changed(status, null)
        recognizer.start(object : PhoneRecognizer.Listener {
            override fun partial(text: String) {
                if (live && text.isNotBlank() && text != heard) { heard = text; changed(if (stopping) StatusLine.PHONE_FINISHING else listening, ServerEvent.Partial(++sequence, text, "")) }
            }
            override fun final(text: String) {
                if (!live) return
                close(false)
                try { if (text.isBlank()) changed(StatusLine.NO_SPEECH, null) else this@PhoneDictation.final(ServerEvent.Final(text, text, false)) } finally { ended() }
            }
            override fun level(value: Double) { if (live && !stopping) this@PhoneDictation.level(value) }
            override fun error(code: Int) = fail(code)
        }, pauseSeconds?.let { (it * 1000).toLong() })
    }
    override fun stop() {
        if (!live || stopping) return
        stopping = true; changed(StatusLine.PHONE_FINISHING, null)
        recognizer.stop(); handler.postDelayed(timeout, FINISH_MS)
    }
    override fun cancel() { if (live) { close(true); ended() } }
    private fun fail(code: Int) {
        if (!live) return
        val partial = heard?.takeIf { it.isNotBlank() }
        close(true)
        try { if (partial != null) kept(partial, reason(code)) else changed(reason(code), null) } finally { ended() }
    }
    private fun close(cancel: Boolean) {
        live = false; heard = null; handler.removeCallbacks(timeout)
        if (cancel) recognizer.cancel()
    }
    companion object {
        const val FINISH_MS = 5000L
        fun reason(code: Int) = when (code) {
            SpeechRecognizer.ERROR_NO_MATCH, SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> StatusLine.NO_SPEECH
            SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> StatusLine.ALLOW_MICROPHONE
            SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED, SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE -> StatusLine.PHONE_NO_LANGUAGE
            SpeechRecognizer.ERROR_RECOGNIZER_BUSY -> StatusLine.PHONE_BUSY
            else -> StatusLine.PHONE_FAILED
        }
    }
}

/** The opt-in "use this phone's recogniser when the Mac is unavailable" decision and its recogniser. */
internal class PhoneFallback(
    private val enabled: () -> Boolean,
    private val available: () -> Boolean,
    private val recognizer: () -> PhoneRecognizer,
    val provider: String? = null,
) {
    /** Password fields are refused before this is asked. */
    fun usable() = enabled() && available()
    /** A Mac attempt that failed for a reachability reason, with nothing heard, hands the next utterance to the phone. TLS means the Mac answered. */
    fun handsOver(kind: ConnectionFailure.Kind?, moved: Boolean) = kind != null && kind != ConnectionFailure.Kind.TLS && !moved && usable()
    fun session(changed: (DictationStatus, ServerEvent.Partial?) -> Unit, level: (Double) -> Unit, final: (ServerEvent.Final) -> Unit,
                kept: (String, DictationStatus) -> Unit, ended: () -> Unit) = PhoneDictation(recognizer(), changed, level, final, kept, ended)
    /** TalkBack's description of the "on phone" chip; never claims the Mac's engine. */
    fun disclosure(resources: Resources) = resources.getString(R.string.phone_disclosure, provider ?: resources.getString(R.string.phone_generic))
    companion object {
        fun android(context: Context) = PhoneFallback({ SettingsStore(context).phoneFallback }, { AndroidPhoneRecognizer.available(context) },
            { AndroidPhoneRecognizer(context) }, provider(context))
        /** The app label of the system's on-device recognition service (e.g. Android System Intelligence), or null. */
        @SuppressLint("DiscouragedApi")
        fun provider(context: Context): String? = try {
            val system = Resources.getSystem()
            val id = system.getIdentifier("config_defaultOnDeviceSpeechRecognitionService", "string", "android")
            ComponentName.unflattenFromString(system.getString(id))?.let { component ->
                context.packageManager.let { it.getApplicationLabel(it.getApplicationInfo(component.packageName, 0)).toString() }
            }?.takeIf { it.isNotBlank() }
        } catch (_: Exception) { null }
    }
}

@Composable
internal fun PhoneFallbackSettings() {
    val context = LocalContext.current
    val store = remember { SettingsStore(context) }
    val available = remember { AndroidPhoneRecognizer.available(context) }
    val provider = remember { PhoneFallback.provider(context) }
    var enabled by remember { mutableStateOf(store.phoneFallback) }
    SettingsGroup(stringResource(R.string.phone_fallback_group)) {
        SwitchRow(stringResource(R.string.phone_fallback_use), enabled && available, { enabled = it; store.phoneFallback = it }, enabled = available,
            summary = stringResource(if (!available) R.string.phone_fallback_none else R.string.phone_fallback_off),
            infoTitle = if (available) stringResource(R.string.phone_fallback_use) else null,
            infoBody = if (available) stringResource(R.string.phone_fallback_info, provider ?: stringResource(R.string.phone_fallback_generic)) else null)
    }
}
