package dev.chirp.android

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** What the speaker model is doing, when it needs saying. */
internal sealed interface SpeakerModelNotice {
    val ui: UiText

    data object CancelFailed : SpeakerModelNotice { override val ui = UiText.Res(R.string.notes_status_speaker_cancel_failed) }
    data object DownloadFailed : SpeakerModelNotice { override val ui = UiText.Res(R.string.notes_status_speaker_download_failed) }
    /** Getting it ready; [megabytes] is the download, rounded up, when the Mac reports it. */
    data class Preparing(val megabytes: Int?) : SpeakerModelNotice {
        override val ui get() = if (megabytes == null) UiText.Res(R.string.notes_status_speaker_preparing) else UiText.Res(R.string.notes_status_speaker_preparing_size, megabytes)
    }
}

/** Shared by Notes and Settings. Model readiness never writes the user's preference. */
internal class NotesSpeakerModel(
    private val store: SettingsStore,
    private val scope: CoroutineScope,
    private val io: suspend (suspend () -> Unit) -> Unit,
    private val fetch: () -> Health?,
    private val request: (String) -> String?,
    private val changed: (Health?) -> Unit = {},
) {
    var enabled by mutableStateOf(store.notesLabelSpeakers)
        private set
    var health by mutableStateOf(store.health)
        private set
    var state by mutableStateOf(health?.speakersModel)
        private set
    var cancelFailed by mutableStateOf(false)
        private set
    private var downloadFailed = false
    private var damaged = false
    private var wanted = false
    private var attempted = false
    private var pending = 0
    private var refreshing = 0
    private var poll: Job? = null
    private val commands = Mutex()
    val available get() = health?.notesSpeakers == true
    val ready get() = enabled && available && state == "ready"
    val retryable get() = cancelFailed || state == "failed"
    val status: SpeakerModelNotice? get() = when {
        cancelFailed -> SpeakerModelNotice.CancelFailed
        !enabled || !available -> null
        state == "failed" -> SpeakerModelNotice.DownloadFailed
        state == "downloading" || state == "not_downloaded" ->
            SpeakerModelNotice.Preparing(health?.speakersModelBytes?.let { (it / 1_000_000.0).toInt() + if (it % 1_000_000L > 0) 1 else 0 })
        else -> null
    }

    /** A note starts capture first; the download and health check run independently. */
    fun activate() {
        enabled = store.notesLabelSpeakers
        wanted = enabled
        ensureDownload()
        refresh()
    }

    fun refresh() {
        enabled = store.notesLabelSpeakers
        if (!enabled) wanted = false
        val id = ++refreshing
        poll?.cancel()
        scope.launch {
            var latest: Health? = null
            io { latest = fetch() }
            if (id != refreshing || pending > 0) return@launch
            latest?.let {
                health = it; store.health = it; state = if (damaged || downloadFailed && it.speakersModel !in setOf("ready", "downloading")) "failed" else it.speakersModel
                changed(it)
                ensureDownload()
            }
            if (state == "downloading") poll = scope.launch { delay(3000); refresh() }
        }
    }

    fun setLabels(on: Boolean) {
        val cancel = !on && (state == "downloading" || pending > 0 || cancelFailed)
        enabled = on; store.notesLabelSpeakers = on
        wanted = on
        if (on) cancelFailed = false
        changed(health)
        if (cancel) command("cancel")
        else if (on) { attempted = false; ensureDownload(); refresh() }
    }

    /** An installed file can still fail to load. Retry replaces it rather than trusting size-only health. */
    fun unavailable() {
        if (!enabled || state != "ready") return
        damaged = true; state = "failed"
    }

    fun retry() {
        if (cancelFailed) command("cancel")
        else if (enabled && available) { attempted = false; command("download") }
    }

    fun remove() { wanted = false; command("remove") }

    private fun ensureDownload() {
        if (wanted && enabled && available && state == "not_downloaded" && !attempted && pending == 0) command("download")
    }

    private fun command(action: String) {
        ++refreshing; poll?.cancel()
        if (action == "download") { attempted = true; downloadFailed = false; state = "downloading" }
        pending++
        scope.launch {
            commands.withLock {
                // An off tap while a download POST is in flight queues cancellation behind it.
                var result: String? = null
                io {
                    if (action == "download" && damaged) {
                        if (request("remove") != "not_downloaded") return@io
                        damaged = false
                    }
                    result = request(action)
                }
                pending--
                if (action == "download") downloadFailed = result == null
                if (action == "cancel") cancelFailed = result == null || result == "downloading"
                state = result ?: "failed"
                changed(health)
                if (pending == 0) {
                    if (state == "downloading" || result != null) refresh()
                }
            }
        }
    }
}
