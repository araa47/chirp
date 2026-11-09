package dev.chirp.android

import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.res.stringResource
import dev.chirp.android.ui.ChoiceChips
import dev.chirp.android.ui.LearnMore
import dev.chirp.android.ui.SettingsItem
import dev.chirp.android.ui.SwitchRow

/**
 * The "Stop dictation" group: "When I tap" (default) or "When I pause" with the pause length the Mac offers, and "Keep
 * listening until I stop", which overrides both and hides them. Read by every dictation entry point at each start.
 */
@Composable
internal fun StopDictationSettings() {
    val context = LocalContext.current
    val resources = LocalResources.current
    val store = remember { SettingsStore(context) }
    var onPause by remember { mutableStateOf(store.stopOnPause) }
    var pause by remember { mutableDoubleStateOf(store.pauseSeconds) }
    var keep by remember { mutableStateOf(store.continuousListening) }
    SwitchRow(stringResource(R.string.stop_keep_listening), keep, { keep = it; store.continuousListening = it },
        summary = stringResource(R.string.stop_keep_listening_info))
    if (!keep) SettingsItem {
        val whenPause = stringResource(R.string.stop_when_pause)
        val whenTap = stringResource(R.string.stop_when_tap)
        // The group above is titled "Stop dictation" (as on iOS), so the chips need no second label.
        ChoiceChips(listOf(false, true), onPause, { if (it) whenPause else whenTap }) { onPause = it; store.stopOnPause = it }
        if (onPause) {
            Text(stringResource(R.string.stop_pause_length), style = MaterialTheme.typography.bodyMedium)
            ChoiceChips(AutoStopDetector.CHOICES, pause, { AutoStopDetector.label(it).resolve(resources) }) { pause = it; store.pauseSeconds = it }
        }
        LearnMore(stringResource(R.string.stop_title), stringResource(if (onPause) R.string.stop_info_pause else R.string.stop_info_tap),
            label = stringResource(R.string.stop_about))
    }
}
