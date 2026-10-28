package dev.chirp.android

import android.content.Context
import android.content.Intent
import android.provider.Settings
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.core.net.toUri
import dev.chirp.android.ui.ActionRow
import dev.chirp.android.ui.SettingsGroup
import dev.chirp.android.ui.SettingsItem
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient

internal sealed interface UpdateStatus {
    data object Idle : UpdateStatus
    data object Checking : UpdateStatus
    data object Current : UpdateStatus
    data object Downloading : UpdateStatus
    data object Installing : UpdateStatus
    /** Android must allow Chirp to install apps first; the update stays on offer. */
    data class NeedsPermission(val info: UpdateInfo) : UpdateStatus
    class Available(val info: UpdateInfo) : UpdateStatus
    class Failed(val message: String) : UpdateStatus
}

/** Check, download and hand off an update from the paired Mac; only tailnet pairings qualify (see [AppUpdates.base]). */
internal class UpdateController(
    private val context: Context,
    private val scope: CoroutineScope,
    private val client: OkHttpClient,
    private val pairing: () -> Pairing? = { SettingsStore(context).pairing() },
    private val installed: () -> Long = { context.packageManager.getPackageInfo(context.packageName, 0).longVersionCode },
) {
    var status by mutableStateOf<UpdateStatus>(UpdateStatus.Idle); private set
    private var busy = false

    /** [manual] false (automatic on opening settings): stay silent unless there is an update. */
    fun check(manual: Boolean = true) {
        if (busy) return
        busy = true
        if (manual) status = UpdateStatus.Checking
        scope.launch {
            val result: UpdateStatus = try {
                withContext(Dispatchers.IO) {
                    val base = pairing()?.let(AppUpdates::base) ?: return@withContext UpdateStatus.Failed(context.getString(R.string.update_needs_tailscale))
                    AppUpdates.check(client, base, installed())?.let { UpdateStatus.Available(it) } ?: UpdateStatus.Current
                }
            } catch (_: Exception) { UpdateStatus.Failed(context.getString(R.string.update_unreachable)) }
            busy = false
            if (manual || result is UpdateStatus.Available) status = result
        }
    }

    fun install(info: UpdateInfo) {
        if (busy) return
        if (!UpdateInstaller.canInstall(context)) { status = UpdateStatus.NeedsPermission(info); return }
        busy = true; status = UpdateStatus.Downloading
        scope.launch {
            val error = try {
                withContext(Dispatchers.IO) {
                    val dir = UpdateInstaller.directory(context).apply { deleteRecursively() }
                    val apk = java.io.File(dir, "update.apk")
                    AppUpdates.download(client.newBuilder().callTimeout(0, java.util.concurrent.TimeUnit.SECONDS).build(), info, apk)
                    UpdateInstaller.install(context, apk, info)
                }
            } catch (_: Exception) { context.getString(R.string.update_download_failed) }
            busy = false
            status = if (error == null) UpdateStatus.Installing else UpdateStatus.Failed(error)
        }
    }

    fun allowInstalls() {
        context.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, "package:${context.packageName}".toUri()).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}

/** Updates section of Chirp settings. Checks once when shown; installs only after a tap and Android's own confirmation. */
@Composable
internal fun UpdateSettings(controller: UpdateController? = null) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val client = remember { ChirpNetwork.client(context) }
    DisposableEffect(client) { onDispose { ChirpNetwork.dispose(client) } }
    val updates = controller ?: remember { UpdateController(context, scope, client) }
    LaunchedEffect(updates) { updates.check(manual = false) }
    val status = updates.status
    val working = status == UpdateStatus.Checking || status == UpdateStatus.Downloading
    SettingsGroup(stringResource(R.string.update_title)) {
        SettingsItem {
            Text(stringResource(R.string.update_body),
                style = MaterialTheme.typography.bodySmall)
            when (status) {
                UpdateStatus.Idle -> {}
                UpdateStatus.Checking -> Text(stringResource(R.string.update_checking))
                UpdateStatus.Current -> Text(stringResource(R.string.update_current))
                UpdateStatus.Downloading -> Text(stringResource(R.string.update_downloading))
                UpdateStatus.Installing -> Text(stringResource(R.string.update_installing))
                is UpdateStatus.NeedsPermission -> {
                    Text(stringResource(R.string.update_needs_permission))
                    OutlinedButton(updates::allowInstalls, Modifier.fillMaxWidth()) { Text(stringResource(R.string.update_allow_installs)) }
                    Button({ updates.install(status.info) }, Modifier.fillMaxWidth()) { Text(stringResource(R.string.update_install)) }
                }
                is UpdateStatus.Available -> {
                    Text(stringResource(R.string.update_available, status.info.versionName))
                    Button({ updates.install(status.info) }, Modifier.fillMaxWidth()) { Text(stringResource(R.string.update_install)) }
                }
                is UpdateStatus.Failed -> Text(status.message)
            }
        }
        ActionRow(stringResource(R.string.update_check), { updates.check() }, enabled = !working)
    }
}
