package dev.chirp.android.shell

import androidx.annotation.StringRes
import dev.chirp.android.R

/** [next] reads after "Next: " (lower-case start); [action] is the card's button. */
internal enum class SetupNeed(@StringRes val next: Int, @StringRes val action: Int, val section: String) {
    Pair(R.string.setup_next_pair, R.string.setup_action_pair, "pair"),
    Microphone(R.string.setup_next_microphone, R.string.setup_action_allow, "microphone"),
    Keyboard(R.string.setup_next_keyboard, R.string.setup_action_set_up, "input"),
    FloatingMic(R.string.setup_next_floating_mic, R.string.setup_action_set_up, "input"),
}

internal data class SetupProgress(val missing: SetupNeed?, val done: Int)

/** Pairing, microphone, then the chosen input method: exactly three prerequisites. */
internal fun setupProgress(paired: Boolean, mic: Boolean, keyboard: Boolean, selected: Boolean,
                           floating: Boolean, ownKeyboard: Boolean): SetupProgress {
    val steps = listOf(SetupNeed.Pair to paired, SetupNeed.Microphone to mic,
        (if (ownKeyboard) SetupNeed.FloatingMic else SetupNeed.Keyboard) to
            (if (ownKeyboard) floating else keyboard && selected))
    return SetupProgress(steps.firstOrNull { !it.second }?.first, steps.count { it.second })
}

/** The one fix Home's connection card offers. */
internal enum class HomeFix(@StringRes val label: Int) {
    Pair(R.string.setup_action_pair), Microphone(R.string.setup_action_allow), TailscaleOn(R.string.setup_action_turn_on), Retry(R.string.setup_action_check_again)
}

/** Compact status for the Notes top bar. Setup help belongs in Settings → Connection. */
internal data class NotesConnectionStatus(@StringRes val label: Int, val connected: Boolean)

internal fun notesConnectionStatus(paired: Boolean, reachable: Boolean?, tailscaleOff: Boolean, phone: Boolean) = when {
    paired && reachable != false && !tailscaleOff -> NotesConnectionStatus(R.string.notes_connection_computer, true)
    !paired && phone -> NotesConnectionStatus(R.string.notes_connection_phone, false)
    else -> NotesConnectionStatus(R.string.notes_connection_offline, false)
}
