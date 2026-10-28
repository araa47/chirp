package dev.chirp.android

import android.content.Intent
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import dev.chirp.android.settings.connectionSummary
import dev.chirp.android.ui.NavRow
import dev.chirp.android.ui.SettingsGroup
import dev.chirp.android.ui.SwitchRow

/** HeliBoard's Chirp section: connection, the clean-up switch and a way in. Everything else lives in [dev.chirp.android.settings.SettingsScreen]. */
@Composable
internal fun ChirpSettingsSection() {
    val context = LocalContext.current
    val store = remember { SettingsStore(context) }
    var cleanup by remember { mutableStateOf(store.correction) }
    fun open(section: String) { context.startActivity(Intent(context, SetupActivity::class.java).putExtra("section", section)) }
    val pairing = store.pairing()
    val connection = connectionSummary(pairing != null, pairing?.base?.host.orEmpty(), null, false, store.health)
    Column(Modifier.fillMaxWidth().padding(20.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        Text(stringResource(R.string.app_name), style = MaterialTheme.typography.titleLarge)
        SettingsGroup {
            NavRow(connection.title.text(), { open("connection") }, summary = connection.summary?.text(), icon = connection.kind.icon)
            if (store.health.cleanupAvailable()) SwitchRow(stringResource(R.string.settings_cleanup), cleanup, { cleanup = it; store.correction = it },
                summary = cleanupDescription(store.health).text())
            NavRow(stringResource(R.string.settings_open_chirp), { open("settings") })
        }
        HorizontalDivider()
    }
}
