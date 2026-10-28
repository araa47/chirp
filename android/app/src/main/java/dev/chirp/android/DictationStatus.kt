package dev.chirp.android

import android.content.res.Resources
import androidx.annotation.StringRes

/**
 * A dictation status line (#339). The keyboard strip, floating mic panel, Quick dictate and the Scratchpad decide
 * tint, cue and fix from the type; the words come from resources only where they are shown. Server messages are
 * never one of these.
 */
internal sealed interface DictationStatus : UiText {
    /** The strip's and Scratchpad's shorter form ("Ready", "Polished"…). */
    fun shown(resources: Resources): String = resolve(resources)
    /** The part before " — " that names the reason when what was heard is kept. */
    fun brief(resources: Resources): String = resolve(resources)
    val action: DictationAction? get() = null
    val error: Boolean get() = false
    /** A success notice: the strip's check mark and success tint. */
    val positive: Boolean get() = false
}

internal enum class StatusLine(
    @StringRes val id: Int,
    override val action: DictationAction? = null,
    override val error: Boolean = action != null && !action.prompt,
    override val positive: Boolean = false,
    @StringRes private val shownId: Int = id,
    @StringRes private val briefId: Int = id,
) : DictationStatus {
    IDLE(R.string.status_idle, shownId = R.string.status_ready),
    /** The strip before the keyboard first renders. */
    TAP_MIC(R.string.status_tap_mic, shownId = R.string.status_ready),
    CONNECTING(R.string.status_connecting),
    LISTENING(R.string.status_listening),
    FINISHING(R.string.status_finishing),
    POLISHING(R.string.status_polishing),
    PHONE_LISTENING(R.string.status_phone_listening),
    PHONE_FINISHING(R.string.status_phone_finishing),
    PHONE_HANDOVER(R.string.status_phone_handover),
    INSERTED(R.string.status_inserted, positive = true, shownId = R.string.status_finished),
    CLEANED(R.string.status_cleaned, positive = true, shownId = R.string.status_polished),
    KEPT_ORIGINAL(R.string.status_kept_original, shownId = R.string.status_kept_heard),
    USED_RAW(R.string.status_used_raw, positive = true),
    REMOVED(R.string.status_removed, positive = true),
    NOTHING_TO_UNDO(R.string.status_nothing_to_undo),
    CANCELLED(R.string.status_cancelled),
    CHECKING(R.string.status_checking),
    OFFLINE(R.string.status_offline),
    TAILSCALE_CONNECTING(R.string.status_tailscale_connecting),
    TAILSCALE_CONNECTED(R.string.status_tailscale_connected, positive = true),
    TAILSCALE_OFF(R.string.status_tailscale_off, DictationAction.TAILSCALE_ON),
    TAILSCALE_STALLED(R.string.status_tailscale_stalled, DictationAction.TAILSCALE_OPEN),
    TAILSCALE_MISSING(R.string.status_tailscale_missing, DictationAction.TAILSCALE_SETUP),
    ALLOW_MICROPHONE(R.string.status_allow_microphone, DictationAction.MICROPHONE),
    MICROPHONE_NEEDED(R.string.status_microphone_needed, DictationAction.MICROPHONE),
    MICROPHONE_UNAVAILABLE(R.string.status_microphone_unavailable, DictationAction.MICROPHONE),
    MICROPHONE_BLOCKED(R.string.status_microphone_blocked, DictationAction.MICROPHONE, briefId = R.string.status_microphone_unavailable),
    NO_SIGNAL(R.string.status_no_signal, error = true),
    PASSWORD_FIELD(R.string.status_password_field, error = true),
    NOT_PAIRED(R.string.status_not_paired, DictationAction.PAIR),
    PAIRING_REFUSED(R.string.status_pairing_refused, DictationAction.PAIR, briefId = R.string.status_pairing_refused_brief),
    NO_SPEECH(R.string.status_no_speech, error = true),
    ENGINE_HICCUP(R.string.status_engine_hiccup, error = true),
    ENGINE_UNAVAILABLE(R.string.status_engine_unavailable, error = true, briefId = R.string.status_engine_unavailable_brief),
    BUSY(R.string.status_busy, error = true, briefId = R.string.status_busy_brief),
    TOO_LONG(R.string.status_too_long, error = true),
    PROMPT_TOO_LONG(R.string.status_prompt_too_long, error = true, briefId = R.string.status_prompt_too_long_brief),
    SERVER_SLOW(R.string.status_server_slow, error = true),
    CONNECTION_SLOW(R.string.status_connection_slow, DictationAction.NETWORK),
    UNEXPECTED(R.string.status_unexpected),
    FIELD_UNAVAILABLE(R.string.status_field_unavailable, error = true),
    PHONE_NO_LANGUAGE(R.string.status_phone_no_language),
    PHONE_BUSY(R.string.status_phone_busy, briefId = R.string.status_phone_busy_brief),
    PHONE_FAILED(R.string.status_phone_failed, briefId = R.string.status_phone_failed_brief),
    // Floating mic (#167): each names its one fix.
    BUBBLE_NOT_PAIRED(R.string.status_bubble_not_paired),
    BUBBLE_NO_MICROPHONE(R.string.status_bubble_no_microphone),
    BUBBLE_BLOCKED(R.string.status_bubble_blocked),
    // Quick dictate and the Scratchpad.
    COPIED_PASTE(R.string.status_copied_paste),
    COPIED(R.string.status_copied),
    PAD_IDLE(R.string.status_pad_idle),
    PAD_FINISHED(R.string.status_finished),
    PAD_KEPT(R.string.status_kept_heard),
    STOP_FIRST(R.string.status_stop_first),
    NOTE_SAVED(R.string.status_note_saved),
    NOTES_OFF(R.string.status_notes_off),
    NOTE_FAILED(R.string.status_note_failed);

    override fun resolve(resources: Resources): String = resources.getString(id)
    override fun shown(resources: Resources): String = resources.getString(shownId)
    override fun brief(resources: Resources): String = resources.getString(briefId)
}

/** What was heard landed after [reason] ended the dictation. A lost connection is named as one, whatever the transport saw. */
internal data class KeptStatus(val reason: DictationStatus) : DictationStatus {
    private val lost get() = reason.action == DictationAction.NETWORK || reason == StatusLine.SERVER_SLOW
    override fun resolve(resources: Resources) =
        resources.getString(R.string.status_kept, if (lost) resources.getString(R.string.status_connection_lost) else reason.brief(resources))
    // A connection failure keeps no fix: the words are in and the next dictation retries.
    override val action get() = reason.action.takeUnless { lost }
    override val error get() = reason.error && !lost && reason !is ConnectionFailure.Kind
}

/** The field's Send/Go was pressed after [result] landed. */
internal data class SentStatus(val result: StatusLine) : DictationStatus {
    override fun resolve(resources: Resources) = resources.getString(R.string.status_sent, result.resolve(resources))
    override fun shown(resources: Resources) = resources.getString(R.string.status_sent, result.shown(resources))
    override val positive get() = result.positive
}
