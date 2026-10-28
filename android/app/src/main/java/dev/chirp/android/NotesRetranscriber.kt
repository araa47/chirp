package dev.chirp.android

import androidx.annotation.StringRes
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout

/** Process-wide opt-out and one run per device, shared by the live and browsing models. */
internal object RetranscribeGate {
    val rebuilds = androidx.compose.runtime.mutableStateMapOf<String, String>()
    val allowed = kotlinx.coroutines.flow.MutableStateFlow(true)
    var owner by mutableStateOf<NotesModel?>(null)
    var progress by mutableStateOf<RetranscribeProgress?>(null)
}

internal data class RetranscribeProgress(val noteId: String, val done: Int, val total: Int, val seconds: Double, val duration: Double, val waiting: Boolean = false) {
    val label: UiText get() = if (waiting) UiText.Res(R.string.notes_status_rt_waiting)
        else UiText.Res(R.string.notes_status_rt_progress, done, total, clock(seconds), clock(duration))
    private fun clock(value: Double) = UiText.Res(R.string.notes_status_clock_short, value.toInt() / 60, value.toInt() % 60)
}

/** What the banner says when a re-transcribe, a restore or a rebuild ended; [restorable] offers Undo for the transcript. */
internal sealed interface RetranscribeNotice {
    val ui: UiText
    /** The transcript now holds new text, so the previous one can be restored. */
    val restorable get() = false

    data object Updated : RetranscribeNotice { override val ui = UiText.Res(R.string.notes_status_rt_updated); override val restorable = true }
    data object Cancelled : RetranscribeNotice { override val ui = UiText.Res(R.string.notes_status_rt_cancelled) }
    data object NoneUpdated : RetranscribeNotice { override val ui = UiText.Res(R.string.notes_status_rt_none) }
    data object RebuildFailed : RetranscribeNotice { override val ui = UiText.Res(R.string.notes_status_rt_rebuild_failed); override val restorable = true }
    data class Partial(val updated: Int, val total: Int) : RetranscribeNotice {
        override val ui get() = UiText.Plural(R.plurals.notes_status_rt_partial, total - updated, listOf(updated, total, total - updated))
        override val restorable get() = true
    }
    data object Restored : RetranscribeNotice { override val ui = UiText.Res(R.string.notes_status_rt_restored) }
    /** The notes were rebuilt from the new transcript; Undo takes the rebuild back. */
    data object Rebuilt : RetranscribeNotice { override val ui = UiText.Res(R.string.notes_status_rt_rebuilt) }
    data object Interrupted : RetranscribeNotice { override val ui = UiText.Res(R.string.notes_status_rt_interrupted) }
}

/** Why a re-transcribe changed nothing. */
internal enum class RetranscribeFailure(@StringRes id: Int) {
    FAILED(R.string.notes_status_rt_failed), TRANSCRIPT_CHANGED(R.string.notes_status_rt_transcript_changed), NOTE_CHANGED(R.string.notes_status_rt_note_changed);
    val ui = UiText.Res(id)
}

internal class RetranscribeError(val code: String) : Exception(code)

/** All answers stay in memory until the caller makes one revision-checked write. */
internal class NotesRetranscriber(
    private val streams: ((ServerEvent) -> Unit, () -> Unit) -> ImeTransport,
    private val decoder: AudioDecoder = MediaCodecAacDecoder(),
    private val decode: suspend (() -> ByteArray) -> ByteArray = { withContext(Dispatchers.IO) { it() } },
    private val backoff: suspend (Long) -> Unit = { delay(it) },
) {
    val staged = linkedMapOf<Int, RetranscribedSegment>()
    private var wire: ImeTransport? = null
    fun cancel() { wire?.close(cancel = true); wire = null; staged.clear() }

    suspend fun run(noteId: String, clips: List<NotesAudioClip>, health: Health, correction: Boolean,
                    read: (Int) -> ByteArray?, progress: (RetranscribeProgress) -> Unit): Map<Int, RetranscribedSegment> {
        require(health.notesRetranscribe)
        staged.clear()
        var seconds = 0.0
        val duration = clips.sumOf { it.duration }
        var context = ""
        try {
            for ((index, clip) in clips.withIndex()) {
                currentCoroutineContext().ensureActive()
                progress(RetranscribeProgress(noteId, index, clips.size, seconds, duration))
                val pcm = try { decode { val encoded = read(clip.segment) ?: error("missing clip"); try { decoder.decode(encoded) } finally { encoded.fill(0) } } }
                    catch (e: CancellationException) { throw e } catch (_: Exception) { null }
                if (pcm != null) try {
                    var attempts = 0
                    while (true) {
                        try {
                            val answer = transcribe(pcm, health, correction, if (health.notesContext) context.takeLast(500) else null)
                            staged[clip.segment] = RetranscribedSegment(clip, answer.first, answer.second)
                            context = answer.first.text
                            break
                        } catch (e: RetranscribeError) {
                            when (e.code) {
                                "busy" -> {
                                    if (++attempts >= 10) throw e
                                    progress(RetranscribeProgress(noteId, index, clips.size, seconds, duration, waiting = true))
                                    backoff(minOf(30_000L, 2000L shl (attempts - 1)))
                                }
                                "engine", "bad_audio", "too_long" -> break
                                else -> throw e
                            }
                        }
                    }
                } finally { pcm.fill(0) }
                seconds += clip.duration
                progress(RetranscribeProgress(noteId, index + 1, clips.size, seconds, duration))
            }
            return staged.toMap()
        } finally { wire?.close(); wire = null }
    }

    private suspend fun transcribe(pcm: ByteArray, health: Health, correction: Boolean, context: String?): Pair<ServerEvent.Final, String?> {
        val events = Channel<ServerEvent>(Channel.UNLIMITED)
        val transport = streams({ events.trySend(it) }, { events.trySend(ServerEvent.Failure("connection")) }).also { wire = it }
        try {
            transport.retranscription(context)
            if (!transport.start(correction, "live_notes", "")) throw RetranscribeError("connection")
            val ready = withTimeout(70_000) { events.receive() }
            if (ready is ServerEvent.Failure) throw RetranscribeError(ready.code)
            if (ready !is ServerEvent.Ready) throw RetranscribeError("protocol")
            var offset = 0
            while (offset < pcm.size) {
                currentCoroutineContext().ensureActive()
                val frame = pcm.copyOfRange(offset, minOf(offset + 3200, pcm.size))
                try {
                    withTimeout(25_000) { while (!transport.audio(frame)) { delay(10); events.tryReceive().getOrNull()?.let { if (it is ServerEvent.Failure) throw RetranscribeError(it.code) } } }
                } finally { frame.fill(0) }
                offset += 3200
            }
            if (!transport.stop()) throw RetranscribeError("connection")
            var budget = 25_000L
            while (true) {
                when (val event = withTimeout(budget) { events.receive() }) {
                    is ServerEvent.Final -> return event to (event.engine ?: ready.engine)
                    is ServerEvent.Failure -> throw RetranscribeError(event.code)
                    is ServerEvent.Correcting -> budget = health.operationDeadlines.timeoutMs("notes_correction", 25_000)
                    else -> Unit
                }
            }
        } catch (_: kotlinx.coroutines.TimeoutCancellationException) { throw RetranscribeError("timeout") }
        finally { transport.close(cancel = true); wire = null; events.close() }
    }
}
