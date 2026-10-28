package dev.chirp.android

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.speech.RecognizerIntent
import android.text.InputType
import android.view.inputmethod.EditorInfo
import androidx.compose.runtime.*
import androidx.core.content.ContextCompat
import androidx.lifecycle.ViewModel
import okhttp3.OkHttpClient

/** One visible utterance. No service, saved state, or persisted text outside opted-in history. */
internal class QuickDictateModel(
    context: Context,
    private val store: SettingsStore = SettingsStore(context),
    private val history: DictationHistory = DictationHistory(context),
    private val captureFactory: (Context, (ByteArray) -> Boolean, (Double) -> Unit, (DictationStatus?) -> Unit) -> Capture = ::captureForBuild,
    private val transportFactory: (OkHttpClient, Pairing, (ServerEvent) -> Unit, () -> Unit) -> ImeTransport = { client, pairing, event, failure ->
        val main = Handler(Looper.getMainLooper())
        StreamTransport(client, pairing, dispatch = { callback -> main.post { callback() } }, event = event, failure = failure)
    },
    private val micGranted: () -> Boolean = { ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED },
    private val pairing: () -> Pairing? = store::pairing,
    private val tailscale: TailscaleControl = AndroidTailscale(context),
    private val io: (() -> Unit) -> Unit = HistoryIo::run,
) : ViewModel() {
    private val app = context.applicationContext as android.app.Application
    private var client: OkHttpClient? = null
    private var stream: DictationStream? = null
    private var privateUtterance = false
    var status by mutableStateOf<DictationStatus>(StatusLine.CONNECTING)
        internal set
    var partial by mutableStateOf("")
        private set
    var stable by mutableStateOf("")
        private set
    var text by mutableStateOf("")
        private set
    var raw by mutableStateOf<String?>(null)
        private set
    var active by mutableStateOf(false)
        private set
    var stopping by mutableStateOf(false)
        private set
    var level by mutableDoubleStateOf(0.0)
        private set
    var retained by mutableStateOf(false)
        private set
    var errorCode by mutableStateOf<Int?>(null)
        private set
    var completed: ((String) -> Unit)? = null
    var appLabel: String = "Quick dictate"
    var targetPackage: String? = null
    private val learning = EditLearning(context, io = io)
    private var learnedPayload = LearnedPayload()
    private var waitingForLearn = false
    private var stopBeforeLearn = false
    var closeAt by mutableStateOf<Long?>(null)
    val copied get() = text.isNotBlank()

    private fun sync() { active = stream != null; stopping = stream?.stopping == true }
    fun start() {
        if (active || copied) return
        errorCode = null
        if (!micGranted()) { fail(StatusLine.ALLOW_MICROPHONE, RecognizerIntent.RESULT_AUDIO_ERROR); return }
        val paired = pairing() ?: run { fail(StatusLine.NOT_PAIRED, RecognizerIntent.RESULT_SERVER_ERROR); return }
        privateUtterance = PrivateSession.enabled
        partial = ""; stable = ""
        val http = client ?: ChirpNetwork.client(app).also { client = it }
        val session = DictationStream(
            deadlines = store.health?.operationDeadlines ?: OperationDeadlines(),
            transportFactory = { event, failure -> transportFactory(http, paired, event, failure) },
            captureFactory = { frame, meter, done -> captureFactory(app, frame, meter, done) },
            changed = { message, event ->
                status = if (message == ConnectionFailure.Kind.OTHER && TailscaleControl.routes(paired.base)) when {
                    !tailscale.installed() -> StatusLine.TAILSCALE_MISSING
                    !tailscale.connected() -> StatusLine.TAILSCALE_OFF
                    else -> message
                } else message
                if (event != null) { partial = event.text; stable = event.stable }
                sync()
            },
            level = { level = it }, retention = { retained = it },
            final = { result ->
                text = if (!privateUtterance && LearnedStore(app).allowed) learnedPayload.apply(result.text) else result.text; raw = result.raw.takeIf { result.corrected && it != result.text }
                status = StatusLine.COPIED_PASTE
                closeAt = android.os.SystemClock.elapsedRealtime() + 4_000
                val label = appLabel
                val original = raw
                if (!privateUtterance && !PrivateSession.enabled) io { history.record(text, original, label, EditorInfo().apply { inputType = InputType.TYPE_CLASS_TEXT; packageName = targetPackage }) }
                completed?.invoke(text)
            },
            ended = {
                stream = null; partial = ""; stable = ""; level = 0.0; sync()
                client?.let(ChirpNetwork::release)
                if (!copied && errorCode == null) errorCode = errorFor(status)
            },
            pauseSeconds = store.autoStopSeconds,
        )
        stream = session; sync()
        waitingForLearn = true; stopBeforeLearn = false
        learning.prepare(targetPackage, !privateUtterance) { payload ->
            if (stream === session) {
                waitingForLearn = false; learnedPayload = payload
                val style = store.style(targetPackage)
                session.start(store.correction && store.health.cleanupAvailable(), style.id, prompt = store.promptEdits[style.id], learned = payload)
                if (stopBeforeLearn) session.stop()
                sync()
            }
        }
    }
    private fun fail(message: DictationStatus, code: Int) { status = message; errorCode = code }
    fun stop() { if (waitingForLearn) { stopBeforeLearn = true; stopping = true } else { stream?.stop(); sync() } }
    /** Every departure cancels, including a final still being polished. */
    fun cancel() {
        waitingForLearn = false; stopBeforeLearn = false
        val old = stream; stream = null; old?.cancel()
        partial = ""; stable = ""; level = 0.0; sync()
    }
    fun useRaw() { raw?.let { text = it; raw = null; completed?.invoke(it) } }
    override fun onCleared() {
        completed = null; cancel(); text = ""; raw = null
        client?.let(ChirpNetwork::dispose); client = null
    }
    companion object {
        fun errorFor(status: DictationStatus): Int = when (status) {
            StatusLine.ALLOW_MICROPHONE, StatusLine.MICROPHONE_NEEDED, StatusLine.MICROPHONE_UNAVAILABLE, StatusLine.MICROPHONE_BLOCKED,
            StatusLine.NO_SPEECH -> RecognizerIntent.RESULT_AUDIO_ERROR
            is ConnectionFailure.Kind, StatusLine.CONNECTION_SLOW, StatusLine.TAILSCALE_OFF, StatusLine.TAILSCALE_STALLED,
            StatusLine.TAILSCALE_MISSING, StatusLine.TAILSCALE_CONNECTED -> RecognizerIntent.RESULT_NETWORK_ERROR
            else -> RecognizerIntent.RESULT_SERVER_ERROR
        }
    }
}
