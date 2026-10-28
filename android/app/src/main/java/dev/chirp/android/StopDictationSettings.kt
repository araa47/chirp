package dev.chirp.android

import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import dev.chirp.android.ui.ChoiceChips
import dev.chirp.android.ui.LearnMore
import dev.chirp.android.ui.SettingsItem

/** One row for a Dictation group: "When I tap" (default) or "When I pause" with the pause length the Mac offers. Read by the keyboard at each start. */
@Composable
internal fun StopDictationSettings() {
    val context = LocalContext.current
    val store = remember { SettingsStore(context) }
    var onPause by remember { mutableStateOf(store.stopOnPause) }
    var pause by remember { mutableDoubleStateOf(store.pauseSeconds) }
    SettingsItem {
        val whenPause = stringResource(R.string.stop_when_pause)
        val whenTap = stringResource(R.string.stop_when_tap)
        Text(stringResource(R.string.stop_title), style = MaterialTheme.typography.bodyLarge)
        ChoiceChips(listOf(false, true), onPause, { if (it) whenPause else whenTap }) { onPause = it; store.stopOnPause = it }
        if (onPause) {
            Text(stringResource(R.string.stop_pause_length), style = MaterialTheme.typography.bodyMedium)
            ChoiceChips(AutoStopDetector.CHOICES, pause, AutoStopDetector::label) { pause = it; store.pauseSeconds = it }
        }
        LearnMore(stringResource(R.string.stop_title), stringResource(if (onPause) R.string.stop_info_pause else R.string.stop_info_tap))
    }
}
