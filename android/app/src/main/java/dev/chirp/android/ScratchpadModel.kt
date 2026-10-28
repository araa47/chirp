package dev.chirp.android

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.view.inputmethod.EditorInfo
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.core.content.ContextCompat
import androidx.lifecycle.ViewModel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient

/** Places a dictated final in an ordinary text value the way the keyboard places one in an editor. */
internal object ScratchpadText {
    private fun needsSpace(previous: Char?) = previous != null && !previous.isWhitespace() && previous != '\'' && previous != '"' &&
        Character.getType(previous) != Character.START_PUNCTUATION.toInt() &&
        Character.getType(previous) != Character.INITIAL_QUOTE_PUNCTUATION.toInt()

    fun insert(value: TextFieldValue, text: String, commands: Boolean): TextFieldValue {
        val start = value.selection.min.coerceIn(0, value.text.length); val end = value.selection.max.coerceIn(start, value.text.length)
        val before = value.text.substring(0, start); val after = value.text.substring(end)
        val shaped = FinalCasing.shape(text, FinalCasing.midSentence(before.takeLast(FinalCasing.LOOKBEHIND)), commands)
        val lead = if (shaped.isNotEmpty() && !shaped.first().isWhitespace() && needsSpace(before.lastOrNull())) " " else ""
        val trail = if (shaped.isNotEmpty() && !shaped.last().isWhitespace() && after.firstOrNull()?.isLetterOrDigit() == true) " " else ""
        val inserted = lead + shaped + trail
        return TextFieldValue(before + inserted + after, TextRange(start + inserted.length))
    }
}

/**
 * The floating mic's in-process hand-off to the Scratchpad (#167): memory only, never an Intent extra, prefs or a
 * log. Taken once by the next Scratchpad screen, and dropped if nobody takes it within [TTL_MS].
 */
internal object ScratchpadHandoff {
    private const val TTL_MS = 30_000L
    private var text: String? = null
    private var at = 0L
    @Synchronized fun put(value: String) { text = value; at = android.os.SystemClock.elapsedRealtime() }
    @Synchronized fun take(): String? {
        val value = text?.takeIf { android.os.SystemClock.elapsedRealtime() - at < TTL_MS }
        text = null
        return value
    }
}

/**
 * Everything the Scratchpad shows, in memory only: it survives rotation with the activity's view model and
 * is dropped with it. Nothing is written to preferences, files or logs; only an opted-in history records finals.
 */
internal class ScratchpadModel(
    context: Context,
    private val store: SettingsStore = SettingsStore(context.applicationContext),
    private val history: DictationHistory = DictationHistory(context.applicationContext),
    private val captureFactory: (Context, (ByteArray) -> Boolean, (Double) -> Unit, (DictationStatus?) -> Unit) -> Capture = ::captureForBuild,
    private val transportFactory: (OkHttpClient, Pairing, (ServerEvent) -> Unit, () -> Unit) -> ImeTransport = { client, pairing, event, failure ->
        val main = Handler(Looper.getMainLooper())
        StreamTransport(client, pairing, dispatch = { callback -> main.post { callback() } }, event = event, failure = failure)
    },
    private val micGranted: () -> Boolean = {
        ContextCompat.checkSelfPermission(context.applicationContext, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
    },
    private val pairing: () -> Pairing? = { store.pairing() },
    private val fetchHealth: (OkHttpClient, Pairing) -> Health? = { client, paired ->
        try { ChirpNetwork.health(client, paired) } catch (_: Exception) { null }
    },
    private val tailscale: TailscaleControl = AndroidTailscale(context.applicationContext),
    private val io: (() -> Unit) -> Unit = HistoryIo::run,
    private val notes: NotesSessions? = null,
) : ViewModel() {
    private val app = context.applicationContext as android.app.Application
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var client: OkHttpClient? = null
    private var session: DictationStream? = null
    private var privateUtterance = false
    private var refreshing = 0
    /** The notes library for "Save as note"; built lazily so merely opening the Scratchpad touches no storage. */
    private val library by lazy { notes ?: NotesSessions(app) }

    private var rawBase: TextFieldValue? = null
    private var rawInserted: TextFieldValue? = null
    private var rawWords: String? = null
    private var rawHistoryId: String? = null
    var rawUntil by mutableStateOf<Long?>(null)
        private set
    val rawAvailable get() = rawUntil?.let { android.os.SystemClock.elapsedRealtime() < it } == true && field == rawInserted
    fun useRaw() {
        if (!rawAvailable) return
        val before = rawBase ?: return
        val words = rawWords ?: return
        field = ScratchpadText.insert(before, words, store.spokenCommands)
        rawHistoryId?.let { id -> io { history.usedRaw(id) } }
        clearRaw(); status = StatusLine.PAD_KEPT
    }
    private fun clearRaw() { rawBase = null; rawInserted = null; rawWords = null; rawUntil = null; rawHistoryId = null }
    var field by mutableStateOf(TextFieldValue(""))
    var status by mutableStateOf<DictationStatus>(StatusLine.PAD_IDLE)
        internal set
    var partial by mutableStateOf("")
        private set
    var active by mutableStateOf(false)
        private set
    var stopping by mutableStateOf(false)
        private set
    var polishing by mutableStateOf(false)
        private set
    var level by mutableDoubleStateOf(0.0)
        private set
    var retained by mutableStateOf(false)
        private set
    private var health by mutableStateOf(store.health)
    private var styleId by mutableStateOf(store.defaultStyle)
    /** Clean-up on or off for this screen only; the keyboard's own setting is untouched. */
    var cleanup by mutableStateOf(store.correction)
        private set

    val profiles get() = CleanupStyles.profiles(health)
    val cleanupAvailable get() = health.cleanupAvailable()
    val style get() = profiles.firstOrNull { it.id == styleId } ?: profiles.first()
    val historyOn get() = history.enabled
    var paired by mutableStateOf(pairing() != null)
        private set
    val hasText get() = field.text.isNotBlank()

    fun choose(profile: CorrectionProfile?) {
        if (active) return
        if (profile == null) cleanup = false else { cleanup = true; styleId = profile.id }
    }

    private fun http() = client ?: ChirpNetwork.client(app).also { client = it }
    private fun sync() {
        val current = session
        active = current != null; stopping = current?.stopping == true; polishing = current?.polishing == true
    }
    private fun tailscaleStatus(paired: Pairing): DictationStatus? = when {
        !TailscaleControl.routes(paired.base) -> null
        !tailscale.installed() -> StatusLine.TAILSCALE_MISSING
        !tailscale.connected() -> StatusLine.TAILSCALE_OFF
        else -> null
    }

    /** Refreshes the Mac's clean-up styles. Called when the screen comes to the front. */
    fun refresh() {
        val paired = pairing().also { this.paired = it != null } ?: return
        val id = ++refreshing
        scope.launch {
            val latest = withContext(Dispatchers.IO) { fetchHealth(http(), paired) } ?: return@launch
            if (id != refreshing) return@launch
            store.health = latest; health = latest; retained = latest.debugRetention
            if (!latest.cleanupAvailable()) cleanup = false
        }
    }

    fun toggle() { if (active) stop() else start() }
    fun stop() { session?.stop(); sync() }

    fun start() {
        if (active) return
        clearRaw()
        if (!micGranted()) { status = StatusLine.ALLOW_MICROPHONE; return }
        val paired = pairing().also { this.paired = it != null } ?: run { status = StatusLine.NOT_PAIRED; return }
        privateUtterance = PrivateSession.enabled
        val chosen = style
        partial = ""; level = 0.0
        val stream = DictationStream(
            deadlines = store.health?.operationDeadlines ?: OperationDeadlines(),
            transportFactory = { event, failed -> transportFactory(http(), paired, event, failed) },
            captureFactory = { frame, lvl, done -> captureFactory(app, frame, lvl, done) },
            changed = { text, event ->
                // A failed connection to a tailnet Mac usually means Tailscale is off; say that instead.
                status = if (text == ConnectionFailure.Kind.OTHER) tailscaleStatus(paired) ?: text else text
                if (event != null) partial = event.text
                sync()
            },
            level = { level = it },
            retention = { retained = it; store.health = store.health?.copy(debugRetention = it) },
            final = { result ->
                val base = field
                field = ScratchpadText.insert(base, result.text, store.spokenCommands)
                val id = java.util.UUID.randomUUID().toString()
                if (!privateUtterance && !PrivateSession.enabled) io { history.record(result.text, result.raw.takeIf { result.corrected }, "Scratchpad", HISTORY_EDITOR, id) }
                if (result.corrected && result.raw != result.text) {
                    rawBase = base; rawInserted = field; rawWords = result.raw; rawHistoryId = id
                    val deadline = android.os.SystemClock.elapsedRealtime() + 5000
                    rawUntil = deadline
                    scope.launch { kotlinx.coroutines.delay(5000); if (rawUntil == deadline) clearRaw() }
                }
                status = if (result.correctionError != null) StatusLine.PAD_KEPT else StatusLine.PAD_FINISHED
            },
            ended = { session = null; partial = ""; level = 0.0; sync(); client?.let(ChirpNetwork::release) },
        )
        session = stream; sync()
        stream.start(cleanup && cleanupAvailable, chosen.id, prompt = store.promptEdits[chosen.id])
    }

    fun cancel(message: DictationStatus = StatusLine.PAD_IDLE) {
        val old = session; session = null; old?.cancel()
        partial = ""; level = 0.0; sync(); status = message
    }

    /** Leaving the screen discards a live utterance; one already being finished keeps going into the text. */
    fun pause() { if (active && !stopping) cancel() }

    fun clear() {
        if (!active) { clearRaw(); field = TextFieldValue(""); status = StatusLine.PAD_IDLE }
    }

    /** Text handed over by the floating mic's "Open in Scratchpad": it becomes the page, or a new paragraph after what is there. */
    fun receive(text: String) {
        if (active || text.isBlank()) return
        val joined = if (field.text.isBlank()) text else field.text.trimEnd() + "\n\n" + text
        field = TextFieldValue(joined, TextRange(joined.length))
    }

    private enum class SaveNote { SAVED, OFF, FAILED }

    /** "Save as note" (spec §D): the whole text becomes one new note in the library. Never while recording. */
    fun saveAsNote() {
        if (active) { status = StatusLine.STOP_FIRST; return }
        val text = field.text.trim()
        if (text.isEmpty()) return
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                try {
                    if (!library.enabled) SaveNote.OFF
                    else {
                        val note = NotesDocument().apply { userEdit(0, 0, text) }
                        if (library.put(java.util.UUID.randomUUID().toString(), note.toJson())) SaveNote.SAVED else SaveNote.FAILED
                    }
                } catch (_: Exception) { SaveNote.FAILED }
            }
            status = when (result) {
                SaveNote.SAVED -> StatusLine.NOTE_SAVED
                SaveNote.OFF -> StatusLine.NOTES_OFF
                SaveNote.FAILED -> StatusLine.NOTE_FAILED
            }
        }
    }

    override fun onCleared() {
        session?.cancel(); session = null
        scope.cancel()
        field = TextFieldValue(""); partial = ""
        client?.let(ChirpNetwork::dispose); client = null
    }

    companion object {
        // Plain editor: history's own rules (on by default, never password fields) decide whether a final is kept.
        private val HISTORY_EDITOR by lazy { EditorInfo().apply { inputType = InputType.TYPE_CLASS_TEXT } }
    }
}
