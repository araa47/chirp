package dev.chirp.android

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.TextFieldValue
import androidx.core.content.ContextCompat
import androidx.lifecycle.ViewModel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient

/**
 * What the Notes screen shows: it survives rotation and folding with the activity's view model. Until the notes are
 * saved, only the sealed recovery copy ([NotesJournal], when on) outlives the process; nothing goes to preferences or logs.
 */
internal class NotesModel(
    context: Context,
    private val store: SettingsStore = SettingsStore(context.applicationContext),
    private val captureFactory: ((ByteArray, Float) -> Unit, (Double) -> Unit, (String?) -> Unit) -> Capture = { frame, level, done -> NotesCapture(frame, level, done, notesInputForBuild(context.applicationContext)) },
    private val transportFactory: (OkHttpClient, Pairing, (ServerEvent) -> Unit, () -> Unit) -> ImeTransport = { client, pairing, event, failure ->
        val main = Handler(Looper.getMainLooper())
        StreamTransport(client, pairing, dispatch = { callback -> main.post { callback() } }, event = event, failure = failure,
            maxQueued = NotesRecorder.MAX_QUEUED_BYTES)
    },
    private val apiFactory: (OkHttpClient, Pairing) -> NotesApi = ::HttpNotesApi,
    private val micGranted: () -> Boolean = {
        ContextCompat.checkSelfPermission(context.applicationContext, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
    },
    private val pairing: () -> Pairing? = { store.pairing() },
    private val fetchHealth: (OkHttpClient, Pairing) -> Health? = { client, paired ->
        try { ChirpNetwork.health(client, paired) } catch (_: Exception) { null }
    },
    /** `POST /v1/speakers/model` (automatic download while labels are on); the model's state after it, null when it failed. */
    private val speakerModel: (OkHttpClient, Pairing, String) -> String? = { client, paired, action ->
        try { ChirpNetwork.speakerModel(client, paired, action) } catch (_: Exception) { null }
    },
    private val voicesRequest: (OkHttpClient, Pairing, VoiceAction?) -> SavedVoices = ChirpNetwork::savedVoices,
    private val tailscale: TailscaleControl = AndroidTailscale(context.applicationContext),
    /** Starts or stops the microphone foreground service; the recording itself lives here. */
    private val foreground: (Boolean) -> Unit = { on -> NotesService.set(context.applicationContext, on) },
    private val io: suspend (suspend () -> Unit) -> Unit = { withContext(Dispatchers.IO) { it() } },
    private val journal: NotesJournal? = NotesJournal(context.applicationContext, store = store),
    private val sessions: NotesSessions? = NotesSessions(context.applicationContext),
    private val timings: NotesTimingLog? = NotesTimingLog(context.applicationContext),
    /** Fire-and-forget storage work, in order, off the main thread. */
    private val background: (() -> Unit) -> Unit = NotesIo::run,
    /** Audio encoding, off the main thread and apart from [background] so a long encode never delays a text save. */
    private val audioWork: (() -> Unit) -> Unit = NotesAudioIo::run,
    private val audioDecoder: AudioDecoder = MediaCodecAacDecoder(),
) : ViewModel(), NotesControls.Session {
    @Volatile private var persistenceEpoch = 0
    private var consentPairing: Pairing? = null
    val canApplyRetranscribed get() = !retranscriber?.staged.isNullOrEmpty()
    private var retranscribeJob: Job? = null
    private var retranscriber: NotesRetranscriber? = null
    private var retranscribeTarget: String? = null
    private var retranscribeSegments: List<NotesSegment> = emptyList()
    var retranscribeSheet by mutableStateOf(false)
    var retranscribeSegment by mutableStateOf<Int?>(null)
    var retranscribeFailure by mutableStateOf<String?>(null)
    var rebuildReview: String?
        get() = RetranscribeGate.rebuilds[document.uid]
        set(value) { if (value == null) RetranscribeGate.rebuilds.remove(document.uid) else RetranscribeGate.rebuilds[document.uid] = value }
    var rebuildChoice by mutableStateOf(store.notesRebuild)
    var retranscribeNotice by mutableStateOf<String?>(null)
    val retranscribing get() = RetranscribeGate.progress?.noteId == document.uid || RetranscribeGate.owner?.retranscribeTarget == document.uid
    val retranscribeProgress get() = RetranscribeGate.progress?.takeIf { it.noteId == document.uid }
    val allowRetranscribe get() = revision.let { store.notesAllowRetranscribe }
    val canRetranscribe get() = allowRetranscribe && !state.active && document.audio.isNotEmpty() && RetranscribeGate.owner == null
    val retranscribeCleanup get() = options().correction
    val retranscribeHealth get() = health
    val retranscribeDestination get() = (consentPairing ?: pairing())?.base?.host ?: "your computer"
    val retranscribeClips get() = document.audio.filter { retranscribeSegment == null || it.segment == retranscribeSegment }

    fun askRetranscribe(segment: Int? = null) {
        if (!canRetranscribe) return
        consentPairing = pairing()
        retranscribeSegment = segment; retranscribeSheet = true
        scope.launch { var next: Health? = null; io { consentPairing?.let { next = fetchHealth(http(), it) } }; next?.let { health = it; store.health = it } }
    }

    private var retranscribeGeneration = 0
    private var transcriptApplied = false
    fun cancelRetranscribeFor(id: String) { if (RetranscribeGate.owner === this && retranscribeTarget == id) cancelRetranscribe() }

    fun cancelRetranscribe() {
        retranscribeGeneration++
        retranscribeJob?.cancel(); retranscriber?.cancel(); retranscriber = null
        retranscribeFailure = null; retranscribeNotice = if (transcriptApplied) "Transcript updated" else "Cancelled. Nothing changed."
        if (RetranscribeGate.owner === this) { RetranscribeGate.owner = null; RetranscribeGate.progress = null; store.notesRetranscribeInterrupted = false }
    }

    fun startRetranscribe() {
        val health = health ?: return
        val pairedAtConsent = consentPairing ?: pairing() ?: return
        val currentPairing = pairing()
        if (pairedAtConsent.base != currentPairing?.base || pairedAtConsent.token != currentPairing.token) { retranscribeSheet = false; message = "Pairing changed. Open Re-transcribe again."; return }
        if (!canRetranscribe || !health.notesRetranscribe || pairing() == null) return
        retranscribeSheet = false; transcriptApplied = false; retranscribeNotice = null; retranscribeFailure = null
        store.notesRebuild = rebuildChoice
        val clips = retranscribeClips.toList()
        val rebuild = rebuildChoice
        val target = document.uid
        retranscribeTarget = target; retranscribeSegments = document.segments.toList()
        val bodyVersion = document.version
        keepSession()
        RetranscribeGate.owner = this
        RetranscribeGate.progress = RetranscribeProgress(target, 0, clips.size, 0.0, clips.sumOf { it.duration })
        store.notesRetranscribeInterrupted = true
        val runner = NotesRetranscriber({ event, failure -> transportFactory(http(), pairedAtConsent, event, failure) }, audioDecoder, decode = { work ->
            var decoded: ByteArray? = null; io { decoded = work() }; requireNotNull(decoded)
        }).also { retranscriber = it }
        val generation = ++retranscribeGeneration
        retranscribeJob = scope.launch {
            try {
                // Finish already queued encodes before decoding; no encoder scratch file belongs to this run.
                kotlinx.coroutines.suspendCancellableCoroutine<Unit> { continuation -> audioWork { mainHandler.post { if (continuation.isActive) continuation.resume(Unit) {} } } }
                val results = runner.run(target, clips, health, options().correction, { sessions?.clipBytes(target, it) }) { RetranscribeGate.progress = it }
                // Drain queued autosaves before preparing the single transcript replacement.
                kotlinx.coroutines.suspendCancellableCoroutine<Unit> { continuation -> background { mainHandler.post { if (continuation.isActive) continuation.resume(Unit) {} } } }
                if (!store.notesAllowRetranscribe) throw kotlinx.coroutines.CancellationException()
                val applied = applyRetranscribed(results)
                if (applied && rebuild && health.correctionAvailable && health.notesStructure) rebuildTranscript(bodyVersion)
            } catch (e: kotlinx.coroutines.CancellationException) { runner.cancel(); throw e }
            catch (e: Exception) {
                if (transcriptApplied) { retranscribeNotice = "Couldn’t rebuild the notes. Transcript updated."; return@launch }
                val code = (e as? RetranscribeError)?.code
                if (code == "auth" || code == "revoked") {
                    runner.cancel(); paired = false; message = "Pair your computer again"; retranscriber = null
                } else retranscribeFailure = "Couldn’t finish re-transcribing. Nothing changed."
            } finally {
                if (generation == retranscribeGeneration) {
                    RetranscribeGate.progress = null
                    if (RetranscribeGate.owner === this@NotesModel && retranscribeFailure == null) RetranscribeGate.owner = null
                    store.notesRetranscribeInterrupted = false
                }
            }
        }
    }

    fun applyRetranscribed(results: Map<Int, RetranscribedSegment> = retranscriber?.staged.orEmpty()): Boolean {
        if (results.isEmpty()) { retranscribeNotice = "No segments updated. Nothing changed."; retranscribeFailure = null; return false }
        val kept = sessions ?: return false
        val target = retranscribeTarget ?: return false
        val live = NotesSessionHolder.owner(target) ?: this.takeIf { document.uid == target }
        live?.let { it.persistenceEpoch++ }
        val record = kept.open(target) ?: return false
        val current = live?.document ?: NotesDocument.fromJson(record.document)
        if (current.segments != retranscribeSegments || current.audio.none { clip -> results.containsKey(clip.segment) }) {
            retranscribeFailure = "This transcript changed. Re-transcribe again."; return false
        }
        val copy = NotesDocument.fromJson(current.toJson())
        if (!copy.applyRetranscription(results)) { retranscribeNotice = "No segments updated. Nothing changed."; return false }
        val json = copy.toJson().put("elapsed", record.document.optDouble("elapsed", 0.0))
        if (!kept.put(target, json, expectedRevision = record.revision)) { retranscribeFailure = "This note changed. Re-transcribe again."; return false }
        live?.let {
            it.document.applyRetranscription(results, at = requireNotNull(copy.previousTranscript).at)
            // The revision-checked write already saved this exact state. Don’t queue a second, unguarded autosave.
            it.keptKey = it.key(); it.savedKey = it.keptKey
            it.sync()
        }
        val total = retranscribeSegments.size
        retranscribeNotice = if (results.size == total) "Transcript updated" else "${results.size} of $total updated. ${total - results.size} kept their old text."
        transcriptApplied = true
        retranscribeFailure = null; retranscriber = null
        if (retranscribeJob?.isActive != true && RetranscribeGate.owner === this) { RetranscribeGate.owner = null; RetranscribeGate.progress = null }
        return true
    }

    fun restoreTranscript() {
        if (retranscribing || state.active) return
        persistenceEpoch++
        if (document.restorePreviousTranscript()) { sync(); keepSession(); retranscribeNotice = "Previous transcript restored" }
    }

    private suspend fun rebuildTranscript(bodyVersion: Int) {
        val target = retranscribeTarget ?: return
        val owner = NotesSessionHolder.owner(target) ?: this.takeIf { document.uid == target }
        val sourceDocument = owner?.document ?: sessions?.open(target)?.document?.let(NotesDocument::fromJson) ?: return
        val rebuilt = (owner?.recorder ?: recorder).rebuildNotes(sourceDocument)
        if (rebuilt == null) { retranscribeNotice = "Couldn’t rebuild the notes. Transcript updated."; return }
        if (owner == null || owner.document !== sourceDocument) { RetranscribeGate.rebuilds[target] = rebuilt; return }
        if (owner.document.version != bodyVersion) owner.rebuildReview = rebuilt
        else { owner.recorder.applyRebuild(rebuilt); owner.retranscribeNotice = "Notes rebuilt" }
    }

    fun acceptRebuild() { rebuildReview?.let { recorder.applyRebuild(it) }; rebuildReview = null; retranscribeNotice = "Notes rebuilt" }

    private val app = context.applicationContext as android.app.Application
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private var client: OkHttpClient? = null
    private var api: NotesApi? = null
    private var ticker: Job? = null
    private var inForeground = false
    private var editing = false
    private var published: NotesRecorder.State? = null
    private var publishedCommand = false
    private var lastSpeakerError: String? = null
    private var committedCount = 0
    private var pendingSeen = 0
    private var visible = true
    private var counter: NotesSessionCounter? = null
    /** What was last written to the library, so an unchanged note is not written again. */
    private var keptKey: List<Any?>? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var saveScheduled = false
    private val saveRunnable = Runnable { saveScheduled = false; autosave(now = true) }
    /** Bumped by every open, so a load that finishes after another one started (or after New) is dropped. */
    private var openRequest = 0
    /** Restoring a document is not an edit: recorder callbacks must not resave it or change its list position. */
    private var loading = false
    /** "Stop current and continue here": the note to continue once the recording that was stopped has ended. */
    private var continueAfterStop: String? = null
    /** What was last saved to a file; the notes are unsaved ([dirty]) once anything differs. */
    private var savedKey: List<Any?>? = null
    private var health by mutableStateOf(store.health)
    /** Bumped on every recorder change, so Compose reads the recorder's plain fields afresh. */
    private var revision by mutableIntStateOf(0)

    var field by mutableStateOf(TextFieldValue(""))
        private set
    var focused = false
        set(value) { field = value; reportFocus() }
    var message by mutableStateOf<String?>(null)
    var raw by mutableStateOf(false)
    var paired by mutableStateOf(pairing() != null)
        private set
    /** "Structure notes": on by default only while structuring stays on the Mac (text never leaves it). */
    var structureEnabled by mutableStateOf(health?.correctionLeavesMachine != true)
        private set
    val labelSpeakers get() = speakerModelControl.enabled
    /** "Recovered unsaved notes from 14:03 · 52 min", until the user saves, discards or records. */
    var recovered by mutableStateOf<String?>(null)
        private set
    /** The library's live notes for the "Recent notes" sheet, newest first; loaded on demand. */
    var recent by mutableStateOf<List<NotesIndexEntry>>(emptyList())
        private set
    /** The library, for the list-detail screens: the index flow, search, rename, trash, restore, purge and kept audio. */
    val library: NotesSessions? get() = sessions
    /** Battery saver: the screen is off (or Notes is out of sight), so editor updates, the ticker and the meter wait. */
    override var quiet = false
        private set

    private fun http() = client ?: ChirpNetwork.client(app).also { client = it }

    private val streams: ((ServerEvent) -> Unit, () -> Unit) -> ImeTransport = { event, failed -> transportFactory(http(), requireNotNull(pairing()), event, failed) }

    val recorder = NotesRecorder(
        transportFactory = streams,
        captureFactory = captureFactory,
        structure = { request -> call { it.structure(request) } },
        reorganize = { request -> call { it.reorganize(request) } },
        options = options(), health = health, structuringEnabled = structureEnabled,
        editNotes = { request -> call { it.edit(request) } },
    ).also { it.onChange = ::sync }

    /** Edit by voice: the Command button and the notification action. */
    private val voiceEdit = NotesVoiceEdit(recorder, streams,
        microphone = { sink, ended -> captureFactory({ bytes, _ -> sink(bytes) }, {}, ended).also { it.start() } },
        selection = { field.selection.takeIf { !it.collapsed }?.let { it.min to it.max } }, scope = scope).also { it.onChange = ::sync }
    /** A press that is still down ended its command on release; one already listening (latched) ends on the next press. */
    private var commandDown = false

    private suspend fun <T> call(body: (NotesApi) -> T): T {
        val current = api ?: apiFactory(http(), requireNotNull(pairing())).also { api = it }
        (current as? HttpNotesApi)?.deadlines = health?.operationDeadlines ?: OperationDeadlines()
        var result: Result<T>? = null
        io { result = runCatching { body(current) } }
        return requireNotNull(result).getOrThrow()
    }

    /** Clean-up with the hidden `live_notes` style when the Mac has it, else the default style and its edited prompt. */
    private fun options() = NotesRecorder.Options(store.correction && health.cleanupAvailable(),
        if (health?.notesCorrection == true) "live_notes" else "default",
        if (health?.notesCorrection == true) null else store.promptEdits["default"])

    /** A session that ended without Save or Discard (process killed, crash, restart) comes back stopped and unsaved. */
    private fun recover(journal: NotesJournal) = scope.launch {
        var json: org.json.JSONObject? = null
        io { json = journal.read() }
        val copy = json ?: return@launch
        if (recorder.state.active || !recorder.document.isEmpty) return@launch
        val restored = try { NotesDocument.fromJson(copy) } catch (_: Exception) { journal.delete(); return@launch }
        val seconds = copy.optDouble("elapsed", 0.0)
        recorder.restore(restored, seconds)
        if (restored.isEmpty) { journal.delete(); return@launch }
        // A recovered session is a library note, marked Recovered; the recovery copy has done its job.
        sessions?.takeIf { it.enabled }?.let { kept ->
            background { kept.put(restored.uid, copy, recovered = true) }
            keptKey = key(); savedKey = keptKey
            journal.delete()
        }
        recovered = "Recovered unsaved notes from " + java.text.SimpleDateFormat("HH:mm", java.util.Locale.getDefault()).format(java.util.Date(restored.startedAt)) +
            " · " + (seconds / 60).toInt().coerceAtLeast(1) + " min"
    }

    // What the screen reads.
    override val state get() = revision.let { recorder.state }
    override val shareTitle get() = displayTitle
    override fun appendShared(text: String): Boolean {
        if (state != NotesRecorder.State.RECORDING && state != NotesRecorder.State.PAUSED) return false
        appendText(text)
        return true
    }

    /** History and Share use the same user-edit path as typing, claiming any AI tail before appending. */
    fun appendText(text: String) {
        val before = document.text
        edit(TextFieldValue(before + (if (before.isBlank()) "" else "\n\n") + text))
        keepSession()
    }
    val document get() = revision.let { recorder.document }
    val structuring get() = revision.let { recorder.structuring }
    val reorganizing get() = revision.let { recorder.reorganizeStatus }
    val level get() = revision.let { recorder.level }
    val retained get() = revision.let { recorder.debugRetention } || health?.debugRetention == true
    val recording get() = state.capturing
    val busy get() = state == NotesRecorder.State.STOPPING
    val paused get() = state == NotesRecorder.State.PAUSED
    val hasContent get() = !document.isEmpty
    private fun key() = recorder.document.let { listOf(it.id, it.version, it.segments.size, it.name, it.speakerVersion, recorder.state.active) }
    /** Content that no Save has written as it is now: leaving or New asks first, and the recovery copy keeps it. */
    val dirty get() = revision.let { hasContent && savedKey != key() }
    val title get() = document.title().removePrefix("# ")
    val displayTitle get() = document.displayTitle()
    val recoveryOn get() = journal?.enabled == true
    /** "Keep notes on this phone": stopped notes are kept in Recent notes, so leaving or New need not ask. */
    val keeps get() = sessions?.enabled == true
    val canUndoRebuild get() = canUndo && recorder.undoKind == NotesChange.Kind.REBUILD
    val canUndo get() = revision.let { recorder.canUndo }
    val canOrganize get() = reorganizing !is Reorganizing.Unavailable && !reorganizing.running && !busy && document.text.isNotBlank()
    /** The switch is offered once the Mac's health says structuring exists and clean-up is on. */
    val structureAvailable get() = health?.let { it.correctionAvailable && it.notesStructure } == true
    val structureHost get() = health?.takeIf { it.correctionLeavesMachine }?.correctionHost
    var elapsed by mutableStateOf(0.0)
        private set
    override val recordedSeconds get() = recorder.elapsed

    val hearing get() = document.let { d -> listOf(d.unstructuredTail, d.livePartial).filter(String::isNotBlank).joinToString(" ") }

    val elapsedText get() = elapsed.toInt().let { s -> if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s / 60 % 60, s % 60) else "%02d:%02d".format(s / 60, s % 60) }

    val status: String get() = voiceEditStatus?.let(NotesVoiceEditText::status) ?: message ?: when (state) {
        NotesRecorder.State.IDLE -> if (paired) IDLE else "Pair your computer in Chirp settings"
        NotesRecorder.State.STARTING -> "Connecting to your computer…"
        NotesRecorder.State.RECORDING -> organizingText ?: if (structuring == Structuring.Running) "Updating notes…" else "Listening…"
        NotesRecorder.State.PAUSED -> recorder.error?.let { "Couldn’t resume: $it" } ?: organizingText ?: "Paused"
        NotesRecorder.State.STOPPING -> (organizingText ?: "Finishing…") + (revision.let { recorder.stoppingElapsed }?.takeIf { it >= 3000 }?.let { " · ${it / 1000} s" } ?: "")
        NotesRecorder.State.STOPPED -> organizingText ?: "Stopped"
        NotesRecorder.State.ERROR -> recorder.error?.let { error ->
            // A failed connection to a tailnet Mac usually means Tailscale is off; say that instead.
            if (error.startsWith("Computer unreachable")) pairing()?.let(::tailscaleStatus) ?: error else error
        } ?: "Notes stopped"
    }

    // Edit by voice.
    /** The Mac can edit notes by voice (health), so the Command button is offered. */
    val voiceEditAvailable get() = revision.let { recorder.canEdit }
    val voiceEditStatus: VoiceEditStatus? get() = revision.let { voiceEdit.status.takeIf { it.isBusy } }
    val listeningForCommand get() = revision.let { voiceEdit.status.isListening }
    val canCommand get() = revision.let { voiceEdit.status.isListening || voiceEdit.canStart }
    /** The note for the last edit that did not apply. */
    val voiceEditNote: String? get() = revision.let { (voiceEdit.status as? VoiceEditStatus.Done)?.let { NotesVoiceEditText.note(it.outcome) } }
    /** "Edited · Undo" after a voice edit applied, until the next edit, a click or [NotesVoiceEdit.CHIP_MS]. */
    val showEditedChip get() = revision.let { (voiceEdit.status as? VoiceEditStatus.Done)?.outcome == NotesEditOutcome.Applied && recorder.canUndoEdit }
    val voiceEditDone: VoiceEditStatus? get() = revision.let { voiceEdit.status.takeIf { it is VoiceEditStatus.Done } }
    fun dismissVoiceEdit() = voiceEdit.dismiss()
    fun undoVoiceEdit() { recorder.undoEdit(); voiceEdit.dismiss() }
    fun cancelCommand() = voiceEdit.cancel()
    /** The Command button went down: start a command, or (a latched one) end it. */
    fun commandPress() {
        if (voiceEdit.status.isListening) { voiceEdit.finish(); commandDown = false; return }
        message = null
        voiceEdit.start()
        commandDown = voiceEdit.status.isListening
    }
    /** The button came up after [heldMs]: a hold ends the command, a tap leaves it listening until the next press. */
    fun commandRelease(heldMs: Long) {
        val ours = commandDown; commandDown = false
        if (ours && heldMs >= NotesVoiceEdit.HOLD_MS) voiceEdit.finish()
    }
    override val commanding: Boolean? get() = revision.let { if (recorder.canEdit) voiceEdit.status.isListening else null }
    override fun command() { message = null; voiceEdit.toggle() }

    private val organizingText get() = when (val r = reorganizing) {
        is Reorganizing.Organizing -> "Organizing notes… ${r.step}/${r.of}"
        Reorganizing.Running -> "Organizing notes…"
        else -> null
    }

    /** Why the notes are a plain editor and live transcript, or null when structuring runs. */
    val explanation: String? get() = when ((structuring as? Structuring.Off)?.why) {
        StructuringOff.CORRECTION_OFF -> "Clean-up is off on your computer, so these notes are a plain editor beside the live transcript."
        StructuringOff.UNSUPPORTED -> "Chirp on your computer is too old to structure notes — update it. The transcript still works."
        StructuringOff.WAITING -> if (paired) "Checking your computer…" else null
        else -> null
    }

    val organizeNote: String? get() = when (val r = reorganizing) {
        is Reorganizing.Failed -> "Couldn’t organize (${r.label}) — will retry"
        is Reorganizing.Organized -> if (r.failed == 0) "Organized" else "Organized · ${r.failed} kept as they were" + (r.reason?.let { " ($it)" } ?: "")
        Reorganizing.Conflict -> "Notes changed while organizing — try again"
        Reorganizing.TooLong -> "Too long to organize — split the last section with a heading"
        Reorganizing.TooShort -> "Nothing to organize yet — keep going"
        else -> (structuring as? Structuring.Failed)?.let { "Couldn’t update notes (${it.label}) — retrying with the next segment" }
    }

    private fun tailscaleStatus(paired: Pairing): String? = when {
        !TailscaleControl.routes(paired.base) -> null
        !tailscale.installed() -> StatusLine.TAILSCALE_MISSING.resolve(app.resources) // SHIM-339
        !tailscale.connected() -> StatusLine.TAILSCALE_OFF.resolve(app.resources) // SHIM-339
        else -> null
    }

    val speakerModelControl: NotesSpeakerModel = NotesSpeakerModel(store, scope, io,
        fetch = { pairing()?.let { fetchHealth(http(), it) } },
        request = { action -> pairing()?.let { speakerModel(http(), it, action) } },
        changed = { latest ->
            val first = health == null
            health = latest
            if (first && latest != null) structureEnabled = !latest.correctionLeavesMachine
            recorder.configure(structureEnabled, latest)
            recorder.labelSpeakers = speakerModelControlReady()
            recorder.recognizeVoices = rememberVoices
            if (latest?.speakerVoices == true) refreshVoices()
            if (!recorder.state.active) recorder.options = options()
        })

    private fun speakerModelControlReady(): Boolean = speakerModelControl.ready
    /** Refreshes authenticated health when Notes comes to the front, including model progress. */
    fun refresh() {
        paired = pairing() != null
        speakerModelControl.refresh()
        refreshVoices()
    }

    fun setStructure(on: Boolean) { structureEnabled = on; recorder.configure(on, health) }
    val speakersAvailable get() = speakerModelControl.available
    val speakerModelState get() = speakerModelControl.state
    val speakerNote: String? get() = revision.let {
        if (labelSpeakers && speakersAvailable && recorder.speakerError != null && recorder.speakerError != "unavailable")
            "Couldn’t label the last segment’s speakers." else null
    }
    fun setSpeakerLabels(on: Boolean) = speakerModelControl.setLabels(on)

    val savedVoices = SavedVoicesModel(scope, io) { action ->
        voicesRequest(http(), pairing() ?: throw VoiceLibraryError("auth"), action)
    }
    val voicesAvailable get() = health?.speakerVoices == true
    val rememberVoices get() = voicesAvailable && (savedVoices.library?.enabled ?: health?.speakersVoices?.enabled ?: false)
    var voiceNotice by mutableStateOf<String?>(null)
        private set
    private val voicePrefs = app.getSharedPreferences("chirp_voice_notice", Context.MODE_PRIVATE)
    private data class Enrollment(val document: NotesDocument, val person: Int, val name: String, val voice: String?,
                                  var attempted: Int = -1, var running: Boolean = false)
    private val enrollments = mutableMapOf<Int, Enrollment>()

    fun acknowledgeVoiceNotice() { voicePrefs.edit().putBoolean("shown", true).apply(); voiceNotice = null }
    fun disableRememberVoices() {
        acknowledgeVoiceNotice(); enrollments.clear(); recorder.recognizeVoices = false
        scope.launch {
            savedVoices.perform(VoiceAction.Disable(false))
            message = savedVoices.error
        }
    }
    fun refreshVoices() {
        if (!voicesAvailable) return
        scope.launch {
            savedVoices.perform(null)
            recorder.recognizeVoices = rememberVoices
        }
    }
    private fun rememberSpeaker(person: Int, remember: Boolean = true, update: Boolean = false, previousVoice: String? = null) {
        val document = recorder.document
        val id = document.roster.resolve(person)
        enrollments.remove(id)
        if (!remember || !voicesAvailable) return
        val name = document.roster.person(id)?.name ?: return
        if (!validVoiceName(name)) return
        val recognized = previousVoice ?: document.roster.person(id)?.recognized?.voice
        val voice = recognized ?: savedVoices.library?.voices?.firstOrNull { it.name.equals(name, true) }?.id
        enrollments[id] = Enrollment(document, id, name, voice)
        scope.launch {
            // Read the server-wide switch before naming stores anything.
            if (savedVoices.perform(null)?.enabled == true) retryEnrollments(force = update)
            else { enrollments.remove(id); recorder.recognizeVoices = false; message = savedVoices.error }
        }
    }
    private fun retryEnrollments(force: Boolean = false) {
        if (!rememberVoices) return
        val doc = recorder.document
        enrollments.values.toList().forEach { pending ->
            if (pending.document !== doc || doc.roster.displayName(pending.person) != pending.name) {
                enrollments.remove(pending.person); return@forEach
            }
            if (pending.running || (!force && pending.attempted == doc.segments.size)) return@forEach
            val source = doc.roster.source(pending.person, recorder.speakerSession) ?: run {
                message = "Record a little more with them, then try again"; return@forEach
            }
            pending.running = true; pending.attempted = doc.segments.size
            scope.launch {
                val result = savedVoices.perform(VoiceAction.Remember(pending.name, source, pending.voice))
                pending.running = false
                if (enrollments[pending.person] !== pending || recorder.document !== doc) return@launch
                if (result != null) {
                    if (message == VoiceLibraryError("too_short").userMessage) message = null
                    enrollments.remove(pending.person)
                    if (!voicePrefs.getBoolean("shown", false)) voiceNotice = pending.name
                } else {
                    message = savedVoices.error
                    // Only a short voice is eligible for an automatic retry at the next segment.
                    if (savedVoices.errorCode != "too_short") enrollments.remove(pending.person)
                }
            }
        }
    }
    fun updateVoice(person: Int) = rememberSpeaker(person, update = true)
    fun rejectVoice(person: Int) {
        if (retranscribing) return
        val doc = recorder.document
        val old = doc.roster.displayName(person)
        enrollments.remove(doc.roster.resolve(person))
        doc.rejectVoice(person)
        val new = doc.roster.displayName(person)
        if (old != new && doc.nameCount(old) > 0) edit(TextFieldValue(doc.replacingName(old, new)))
        sync(); keep(now = true)
    }

    /** Rename a person everywhere in the note; [replaceInNotes] also swaps their old name in the notes' text. */
    fun renameSpeaker(person: Int, name: String, replaceInNotes: Boolean = false, remember: Boolean = true) {
        if (retranscribing) return
        val document = recorder.document
        val old = document.roster.displayName(person)
        val previousVoice = document.roster.person(document.roster.resolve(person))?.recognized?.voice
        document.renameSpeaker(person, cleanVoiceName(name))
        val new = document.roster.displayName(person)
        if (replaceInNotes && new != old) edit(TextFieldValue(document.replacingName(old, new)))
        sync(); keep(now = true)
        rememberSpeaker(person, remember, previousVoice = previousVoice)
    }

    /** The note just recorded has people nobody has named: "Who was speaking?" shows until they are named or the next recording starts. */
    private var namePromptFor by mutableStateOf<String?>(null)
    val askToNameSpeakers: Boolean get() = revision.let {
        namePromptFor == recorder.document.uid && !recorder.state.active && recorder.document.roster.unnamed.isNotEmpty()
    }

    /** The "Name speakers" sheet is open. */
    var nameSpeakersOpen by mutableStateOf(false)

    /** Names from recent notes, for the sheet's autocomplete; loaded when the sheet opens. */
    var recentNames by mutableStateOf<List<String>>(emptyList())
        private set
    fun loadRecentNames() {
        refreshVoices()
        val kept = sessions ?: return
        val uid = recorder.document.uid
        scope.launch { var names = emptyList<String>(); io { names = kept.speakerNames(excluding = uid) }; recentNames = names }
    }

    /**
     * Name several people at once (blank goes back to "Person N"); [replaceInNotes] also swaps each old name in the notes'
     * text, in one pass. Naming anyone settles the "Who was speaking?" line.
     */
    fun renameSpeakers(names: Map<Int, String>, replaceInNotes: Boolean = false, merges: Map<Int, Int> = emptyMap(), remember: Set<Int> = names.keys) {
        if (retranscribing) return
        val document = recorder.document
        val oldVoices = document.roster.active.associateWith { document.roster.person(it)?.recognized?.voice }
        val oldNames = document.roster.active.associateWith(document.roster::displayName)
        for ((person, into) in merges) document.mergeSpeaker(person, into)
        for ((person, name) in names) {
            val target = document.roster.resolve(person)
            if (name.trim().take(SpeakerRoster.MAX_NAME).ifEmpty { "Person $target" } != document.roster.displayName(target))
                document.renameSpeaker(target, cleanVoiceName(name))
        }
        val renames = oldNames.mapNotNull { (id, old) ->
            document.roster.displayName(id).let { if (it != old) old to it else null }
        }.toMap()
        namePromptFor = null
        if (replaceInNotes && renames.isNotEmpty()) edit(TextFieldValue(document.replacingNames(renames)))
        sync(); keep(now = true)
        for (person in names.keys) {
            val name = document.roster.person(person)?.name
            val notSaved = name != null && document.roster.person(person)?.recognized == null &&
                savedVoices.library?.voices.orEmpty().none { it.name.equals(name, true) }
            if (oldNames[person] != document.roster.displayName(person) || person !in remember || notSaved)
                rememberSpeaker(person, person in remember, previousVoice = oldVoices[person])
        }
    }

    fun mergeSpeaker(person: Int, into: Int) { if (retranscribing) return; recorder.document.mergeSpeaker(person, into); sync(); keep(now = true) }
    fun separateSpeaker(person: Int) { if (retranscribing) return; recorder.document.separateSpeaker(person); sync(); keep(now = true) }
    fun reassignTurn(segment: Int, turn: Int, person: Int?) {
        if (retranscribing) return
        if (document.reassignTurn(segment, turn, person)) { sync(); keep(now = true) }
    }
    fun setAuto(on: Boolean) = recorder.setAuto(on)
    val auto get() = revision.let { recorder.autoReorganize }

    fun toggle() { if (state.active) stop() else start() }

    fun start() {
        if (retranscribing) { message = "Finish re-transcribing first"; return }
        if (state.active) return
        if (voiceEdit.holdsMicrophone) { message = "Finish the spoken edit first"; return }
        message = null; recovered = null
        if (!micGranted()) { message = "Allow microphone in Chirp settings"; return }
        pairing().also { paired = it != null } ?: run { message = "Pair your computer in Chirp settings"; return }
        recorder.options = options()
        recorder.configure(structureEnabled, health)
        recorder.keepAudio = sessions?.let { it.enabled && it.keepAudio } == true
        recorder.labelSpeakers = speakerModelControl.ready
        // Recording into a finished note continues it: a quiet divider marks where, and the audio clock goes on.
        if (recorder.state.let { it == NotesRecorder.State.STOPPED || it == NotesRecorder.State.ERROR } && document.segments.isNotEmpty())
            recorder.document.addBoundary(recorder.elapsed, System.currentTimeMillis())
        recorder.start()
        speakerModelControl.activate()
    }

    /**
     * Continue recording into the library note [id]: it opens (unless it is the open note), a capture boundary is added and
     * new segments carry on from its stored audio clock. False when another note is recording and [stopCurrent] is not
     * set (offer "Stop current and continue here"); with it, that recording stops first and this one starts after.
     */
    fun continueRecording(id: String, stopCurrent: Boolean = false): Boolean {
        if (state.active) {
            if (recorder.document.uid == id) return true
            if (!stopCurrent) return false
            continueAfterStop = id; stop()
            return true
        }
        scope.launch { if (recorder.document.uid == id || load(id)) start() }
        return true
    }

    override fun stop() { message = null; recorder.stop() }
    override fun pause() { message = null; recorder.pause() }
    override fun resume() { if (voiceEdit.holdsMicrophone) { message = "Finish the spoken edit first"; return }; message = null; recorder.resume() }
    fun togglePause() { if (paused) resume() else pause() }

    /** Rename: the title of the notes, the export and the saved file; blank goes back to the start time. */
    fun rename(name: String) {
        recorder.document.name = name.trim().take(MAX_NAME).ifEmpty { null }
        sync(); keep(now = true)
    }

    /** Save: the export goes through [open] off the main thread; the notes count as saved unless they changed meanwhile. */
    fun save(open: () -> java.io.OutputStream?) {
        val text = export(); val what = key()
        scope.launch {
            var ok = false
            io { ok = try { open()?.use { it.write(text.toByteArray(Charsets.UTF_8)) } != null } catch (_: Exception) { false } }
            if (!ok) { message = "Couldn’t save — try another place, or Share"; return@launch }
            savedKey = what; recovered = null; message = "Saved"
            if (!dirty) journal?.delete()
            revision++
        }
    }

    /**
     * Autosave: with the library on (the default) every note keeps itself, there is no Save step. Written at once after a
     * commit, an AI change or a state change, otherwise at most every [SAVE_MS]; a blank, never-named note is not kept. The
     * recovery copy stands down once the library has the note.
     */
    private fun autosave(now: Boolean) {
        if (loading) return
        val kept = sessions?.takeIf { it.enabled } ?: return
        if (!now) { if (!saveScheduled) { saveScheduled = true; mainHandler.postDelayed(saveRunnable, SAVE_MS) }; return }
        mainHandler.removeCallbacks(saveRunnable); saveScheduled = false
        val document = recorder.document
        val what = key()
        if (document.untouched || keptKey == what) return
        val json = document.toJson().put("elapsed", recorder.elapsed)
        val epoch = persistenceEpoch
        background { if (persistenceEpoch == epoch) kept.put(document.uid, json) }
        keptKey = what; savedKey = what; recovered = null
        journal?.delete()
    }

    /** Keeps the open note now (leaving, New, a stop). True when the note is in the library, or was never worth keeping. */
    fun keepSession(): Boolean {
        sessions?.takeIf { it.enabled } ?: return false
        autosave(now = true)
        revision++
        return true
    }

    fun loadRecent() { val kept = sessions ?: return; scope.launch { var list = emptyList<NotesIndexEntry>(); io { list = kept.entries() }; recent = list } }

    /** Opens a library note in place of the current notes (the current one is kept first). */
    fun open(entry: NotesIndexEntry) = open(entry.id)

    fun open(id: String) {
        if (state.active) return
        scope.launch { load(id) }
    }

    /** The note's record off the main thread; false when it is gone or recording began meanwhile. Late loads are dropped. */
    private suspend fun load(id: String): Boolean {
        val kept = sessions ?: return false
        if (state.active) return false
        keepSession()
        val request = ++openRequest
        var record: NotesRecord? = null
        io { record = kept.open(id) }
        if (request != openRequest || state.active) return false
        val found = record ?: run { message = "Couldn’t open these notes"; return false }
        val document = try { NotesDocument.fromJson(found.document) } catch (_: Exception) { message = "Couldn’t open these notes"; return false }
        loading = true
        try {
            recorder.restore(document, found.document.optDouble("elapsed", 0.0))
            field = TextFieldValue(recorder.document.text)
            message = null; recovered = null; elapsed = recorder.elapsed
            savedKey = key(); keptKey = savedKey
        } finally { loading = false }
        journal?.delete()
        revision++
        return true
    }

    /** Delete: into Recently Deleted. A note that is recording cannot be deleted until it is stopped. */
    fun trash(id: String): Boolean {
        val kept = sessions ?: return false
        RetranscribeGate.owner?.takeIf { it.retranscribeTarget == id }?.cancelRetranscribe()
        if (state.active && recorder.document.uid == id) return false
        recent = recent.filter { it.id != id }
        if (id == recorder.document.uid) { openRequest++; keptKey = null; if (!state.active) clear() }
        background { kept.trash(id) }
        return true
    }

    fun deleteKept(entry: NotesIndexEntry) { trash(entry.id) }

    /** Delete only this note's kept audio. The text and transcript stay. */
    fun deleteAudio() {
        if (retranscribing) return
        val id = document.uid
        background {
            if (sessions?.deleteAudio(id) == true) mainHandler.post {
                if (document.uid == id) { recorder.document.clearClips(); revision++ }
            }
        }
    }

    /** Encodes and stores a committed segment's audio, off the main thread, after the note's own write. */
    private fun keepClip(documentId: Long, segment: Int, offset: Double, pcm: ByteArray) {
        val kept = sessions?.takeIf { it.enabled && it.keepAudio }
        val document = recorder.document
        if (kept == null || document.id != documentId) { pcm.fill(0); return }
        autosave(now = true) // The note is queued for writing before its first clip is.
        val uid = document.uid
        audioWork {
            val encoded = kept.encodeClip(pcm); pcm.fill(0)
            if (encoded != null) background {
                kept.storeClip(uid, segment, offset, pcm.size, encoded)?.let { clip ->
                    mainHandler.post { if (recorder.document.id == documentId) { recorder.document.addClip(clip); revision++ } }
                }
            }
        }
    }

    /** The screen came into or went out of sight (the activity's start and stop). */
    fun visible(on: Boolean) {
        visible = on; updateQuiet()
        // Without the recording's service Android silences a hidden app's microphone, so a command on its own microphone ends.
        if (!on && !recorder.state.active) voiceEdit.cancel()
    }

    private fun updateQuiet() {
        val now = !visible && store.notesBatterySaver
        if (now == quiet) return
        quiet = now; recorder.quiet = now; counter?.quiet(now)
        // Out of sight: nothing more to do. Back: the editor, partial line and clock catch up at once.
        if (!now) sync()
        retick()
        if (recorder.state.active) NotesControls.publish(app, this)
    }

    private fun retick() {
        ticker?.cancel()
        ticker = if (inForeground && !quiet) scope.launch { while (isActive) { delay(1000); elapsed = recorder.elapsed; revision++ } } else null
    }

    fun organize() { message = null; recorder.organize() }
    fun undo() = recorder.undoOrganize()

    /** A local typed note: no microphone, pairing or server work. */
    fun newNote() {
        if (state.active) return
        keepSession()
        clear()
        recorder.document.typedNote = true
        sync(); keep(now = true)
    }

    /** New: an empty document (only while not recording). */
    fun clear() {
        if (state.active) return
        ++openRequest
        recorder.reset(); field = TextFieldValue(""); message = null; elapsed = 0.0; recovered = null; savedKey = null; keptKey = null
        journal?.delete()
    }

    /** The editor's new value: the text change goes to the document as the user's edit. */
    fun edit(value: TextFieldValue) {
        val old = recorder.document.text
        editing = true
        try { NotesDocument.diff(old, value.text, NotesChange.Kind.USER)?.let { recorder.userEdit(it.start, it.end, it.replacement); voiceEdit.dismiss() } }
        finally { editing = false }
        field = value
        reportFocus()
    }

    private fun reportFocus() = recorder.editorFocus(
        inTail = focused && recorder.document.touchesTail(field.selection.min, field.selection.max), composing = field.composition != null)

    /**
     * Replays AI changes onto the editor, keeping the caret where the user left it. With the battery saver on and the
     * screen off, only the work that matters off screen runs (state, notification, recovery copy, service); the editor
     * and the clock catch up when the screen is back.
     */
    private fun sync() {
        if (recorder.speakerError != lastSpeakerError) {
            lastSpeakerError = recorder.speakerError
            if (lastSpeakerError == "unavailable") {
                speakerModelControl.unavailable()
                recorder.labelSpeakers = speakerModelControl.ready
            }
        }
        val quiet = quiet
        val changes = if (quiet) emptyList() else recorder.takePendingChanges()
        counter?.let { if (quiet) it.skipped++ else it.updates++ }
        if (!quiet && !editing) {
            var value = field
            for (change in changes) {
                val composition = value.composition?.takeIf { it.max <= change.start }
                value = TextFieldValue(change.applied(value.text), TextRange(change.map(value.selection.start), change.map(value.selection.end)), composition)
            }
            val text = recorder.document.text
            if (value.text != text) value = TextFieldValue(text, TextRange(value.selection.start.coerceAtMost(text.length), value.selection.end.coerceAtMost(text.length)))
            if (value != field) field = value
        }
        if (!quiet) elapsed = recorder.elapsed
        val state = recorder.state
        val commits = recorder.document.segments.size
        if (commits != committedCount) retryEnrollments()
        val stateChanged = state != published
        val commanding = voiceEdit.status.isListening
        if (stateChanged || commanding != publishedCommand) { published = state; publishedCommand = commanding; NotesControls.publish(app, this) }
        val aiChanged = if (quiet) recorder.pendingCount != pendingSeen else changes.isNotEmpty()
        pendingSeen = recorder.pendingCount
        // At once after a commit, an AI change or a state change; otherwise at most every 2 s.
        keep(now = aiChanged || commits != committedCount || stateChanged)
        committedCount = commits
        val active = state.active
        if (active != inForeground) {
            inForeground = active; foreground(active)
            if (active) counter = NotesSessionCounter(SystemClock::uptimeMillis, recorder, store.notesBatterySaver).also { it.quiet(quiet) }
            else { counter?.let { c -> timings?.let { log -> val t = c.finish(System.currentTimeMillis()); background { log.record(t) } } }; counter = null }
            retick()
            if (!active) client?.let(ChirpNetwork::release)
        }
        if (stateChanged && state == NotesRecorder.State.STOPPED) {
            keepSession()
            if (recorder.document.roster.unnamed.isNotEmpty()) namePromptFor = recorder.document.uid
        }
        if (stateChanged && !state.active) continueAfterStop?.let { id -> continueAfterStop = null; scope.launch { if (load(id)) start() } }
        if (!quiet) revision++
    }

    /** The recovery copy follows the notes while they are unsaved, and goes once they are saved or empty. */
    private fun keep(now: Boolean) {
        if (loading) return
        autosave(now)
        journal?.update({ if (dirty) recorder.document.toJson().put("elapsed", recorder.elapsed) else null }, now)
    }

    /** Copy and Share: the notes, then the transcript, as Markdown. */
    fun export() = document.exportMarkdown()

    override fun onCleared() {
        cancelRetranscribe()
        // Swiped away from Recents is not a discard: the recovery copy (or the kept session) stays for next time.
        keepSession()
        journal?.flush()
        voiceEdit.cancel()
        NotesControls.release(app, this)
        recorder.onChange = null
        recorder.dispose()
        ticker?.cancel()
        if (inForeground) { inForeground = false; foreground(false) }
        scope.cancel()
        field = TextFieldValue("")
        client?.let(ChirpNetwork::dispose); client = null; api = null
    }

    init {
        if (store.notesRetranscribeInterrupted && RetranscribeGate.owner == null) {
            retranscribeNotice = "Re-transcribe was interrupted. Nothing changed."
            store.notesRetranscribeInterrupted = false
        }
        scope.launch { RetranscribeGate.allowed.collect { if (!store.notesAllowRetranscribe) { retranscribeSheet = false; if (RetranscribeGate.owner === this@NotesModel) cancelRetranscribe(); revision++ } else revision++ } }
        recorder.audioSink = ::keepClip
        journal?.let(::recover)
    }

    companion object {
        const val IDLE = "Tap Record to take notes"
        const val MAX_NAME = 120
        /** The library is written at most this often while notes change. */
        const val SAVE_MS = 2000L
    }
}
