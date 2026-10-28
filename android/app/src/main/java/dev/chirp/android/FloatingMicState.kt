package dev.chirp.android

import androidx.annotation.StringRes

/** The floating mic panel's states (#167). The bubble itself is idle, or listening while held. */
internal enum class FloatingState { IDLE, CONNECTING, LISTENING, FINISHING, INSERTED, POLISHED, READY_TO_COPY, ERROR }

/** Each floating mic error carries exactly one fix (#167), chosen by the status's type; server text is never shown. */
internal enum class BubbleFix(@StringRes val label: Int, @StringRes val description: Int) {
    PAIR(R.string.action_pair, R.string.fix_pair_description),
    MICROPHONE(R.string.fix_microphone, R.string.fix_microphone_description),
    CHECK_AGAIN(R.string.fix_check_again, R.string.fix_check_again_description),
    TAILSCALE_ON(R.string.action_tailscale_on, R.string.fix_tailscale_on_description),
    TAILSCALE_OPEN(R.string.action_tailscale_open, R.string.action_tailscale_open),
    TAILSCALE_SETUP(R.string.action_tailscale_setup, R.string.fix_tailscale_setup_description),
    QUICK_DICTATE(R.string.fix_quick_dictate, R.string.fix_quick_dictate_description),
    SETTINGS(R.string.fix_settings, R.string.fix_settings_description),
    TRY_AGAIN(R.string.fix_try_again, R.string.fix_try_again_description);

    companion object {
        fun forStatus(status: DictationStatus): BubbleFix? = when (status) {
            StatusLine.BUBBLE_NOT_PAIRED, StatusLine.NOT_PAIRED, StatusLine.PAIRING_REFUSED -> PAIR
            StatusLine.BUBBLE_NO_MICROPHONE, StatusLine.ALLOW_MICROPHONE, StatusLine.MICROPHONE_NEEDED -> MICROPHONE
            StatusLine.BUBBLE_BLOCKED -> QUICK_DICTATE
            StatusLine.TAILSCALE_OFF -> TAILSCALE_ON
            StatusLine.TAILSCALE_STALLED -> TAILSCALE_OPEN
            StatusLine.TAILSCALE_MISSING -> TAILSCALE_SETUP
            is ConnectionFailure.Kind, StatusLine.CONNECTION_SLOW, StatusLine.SERVER_SLOW -> CHECK_AGAIN
            StatusLine.PROMPT_TOO_LONG -> SETTINGS
            else -> TRY_AGAIN.takeIf { status.error }
        }
    }
}

/**
 * Everything the panel draws, so a render is a pure function of it. [text]/[stable] are live partials or, in
 * Ready to copy and errors, the kept words.
 */
internal data class PanelModel(
    val state: FloatingState,
    val status: DictationStatus? = null,
    val text: String = "",
    val stable: String = "",
    val polishing: Boolean = false,
    val copyMode: Boolean = false,
    val level: Double = 0.0,
    val retention: Boolean = false,
) {
    val fix: BubbleFix? get() = if (state == FloatingState.ERROR) status?.let(BubbleFix::forStatus) else null
    val active get() = state == FloatingState.CONNECTING || state == FloatingState.LISTENING || state == FloatingState.FINISHING

    /** The one line under the header. Errors say their own reason. */
    val headline: UiText get() = when (state) {
        FloatingState.IDLE -> UiText.Res(if (copyMode) R.string.panel_copy_mode else R.string.panel_tap_to_dictate)
        FloatingState.CONNECTING -> StatusLine.CONNECTING
        FloatingState.LISTENING -> UiText.Res(R.string.panel_headline_listening)
        FloatingState.FINISHING -> UiText.Res(if (polishing) R.string.panel_polishing else R.string.panel_finishing)
        FloatingState.INSERTED, FloatingState.POLISHED -> UiText.Res(R.string.panel_inserted)
        FloatingState.READY_TO_COPY -> UiText.Res(if (copyMode) R.string.panel_copy_mode else R.string.panel_not_inserted)
        FloatingState.ERROR -> status ?: UiText.Raw("")
    }
}
