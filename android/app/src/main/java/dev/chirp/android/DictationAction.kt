package dev.chirp.android

import androidx.annotation.StringRes

/** The one fix a dictation status offers ([DictationStatus.action]); server error messages never choose one.
 * Prompt actions keep their status text visible beside a button instead of replacing it. */
internal enum class DictationAction(@StringRes val label: Int, val prompt: Boolean = false) {
    PAIR(R.string.action_pair), MICROPHONE(R.string.action_microphone), NETWORK(R.string.action_network),
    TAILSCALE_ON(R.string.action_tailscale_on, prompt = true), TAILSCALE_OPEN(R.string.action_tailscale_open, prompt = true),
    TAILSCALE_SETUP(R.string.action_tailscale_setup, prompt = true);
}
