package dev.chirp.android

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.core.content.edit
import dev.chirp.android.ui.ActionRow
import dev.chirp.android.ui.SettingsGroup
import dev.chirp.android.ui.LearnMore
import dev.chirp.android.ui.SettingsItem
import dev.chirp.android.ui.SwitchRow
import helium314.keyboard.latin.settings.Defaults
import helium314.keyboard.latin.settings.Settings
import helium314.keyboard.latin.utils.ChecksumCalculator
import helium314.keyboard.latin.utils.JniUtils
import helium314.keyboard.latin.utils.getActivity
import helium314.keyboard.latin.utils.protectedPrefs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/**
 * Swipe typing through HeliBoard's user-supplied gesture library loader ([JniUtils]).
 * Chirp never downloads a library and published builds bundle none; the user picks a file and Chirp verifies it
 * the same way HeliBoard does. A personal build made with `-Pchirp.gestureLib` packages one ([Status.BUILT_IN]).
 */
internal object GestureLibrary {
    const val MAX_BYTES = 64L * 1024 * 1024
    enum class Status { ACTIVE, BUILT_IN, NOT_LOADED, NONE }
    enum class Check { KNOWN, UNKNOWN, NOT_LIBRARY, WRONG_ABI }

    fun file(context: Context) = File(context.filesDir, JniUtils.JNI_LIB_IMPORT_FILE_NAME)
    fun abi(): String = Build.SUPPORTED_ABIS[0]

    /** [JniUtils] loads an added file first; loaded without one means the APK's (or system's) library. */
    fun status(context: Context, loaded: Boolean = JniUtils.sHaveGestureLib) = when {
        loaded && file(context).isFile -> Status.ACTIVE
        loaded -> Status.BUILT_IN
        file(context).isFile -> Status.NOT_LOADED
        else -> Status.NONE
    }

    /** Minimal ELF header check: a shared object built for this phone's primary ABI. */
    fun inspect(header: ByteArray, abi: String): Check {
        if (header.size < 20 || header[0] != 0x7f.toByte() || header[1] != 'E'.code.toByte() ||
            header[2] != 'L'.code.toByte() || header[3] != 'F'.code.toByte()) return Check.NOT_LIBRARY
        val type = (header[16].toInt() and 0xff) or ((header[17].toInt() and 0xff) shl 8)
        if (header[5].toInt() != 1 || type != 3) return Check.NOT_LIBRARY // little-endian ET_DYN
        val machine = (header[18].toInt() and 0xff) or ((header[19].toInt() and 0xff) shl 8)
        val wanted = when (abi) { "arm64-v8a" -> 183 to 2; "x86_64" -> 62 to 2; "armeabi-v7a" -> 40 to 1; "x86" -> 3 to 1; else -> -1 to 0 }
        return if (machine == wanted.first && header[4].toInt() == wanted.second) Check.UNKNOWN else Check.WRONG_ABI
    }

    fun verdict(header: ByteArray, checksum: String, abi: String, expected: String): Check {
        val check = inspect(header, abi)
        return if (check == Check.UNKNOWN && checksum.equals(expected, ignoreCase = true)) Check.KNOWN else check
    }

    /** Same layout as HeliBoard's LoadGestureLibPreference: read-only file plus its accepted checksum. */
    fun install(context: Context, candidate: File, checksum: String) {
        val target = file(context)
        target.setWritable(true); target.delete()
        context.protectedPrefs().edit(commit = true) { putString(Settings.PREF_LIBRARY_CHECKSUM, checksum) }
        candidate.copyTo(target)
        target.setReadOnly()
        candidate.delete()
    }

    fun remove(context: Context) {
        file(context).apply { setWritable(true); delete() }
        context.protectedPrefs().edit(commit = true) { remove(Settings.PREF_LIBRARY_CHECKSUM) }
    }

    fun candidate(context: Context) = File(context.filesDir, "chirp-gesture-candidate")

    /** Copies the picked document privately, then checks header, ABI and SHA-256. */
    fun stage(context: Context, uri: Uri, abi: String = abi()): Pair<Check, String> {
        val target = candidate(context)
        target.setWritable(true); target.delete()
        context.contentResolver.openInputStream(uri)?.use { input ->
            target.outputStream().use { output ->
                val buffer = ByteArray(64 * 1024); var total = 0L
                while (true) {
                    val read = input.read(buffer); if (read < 0) break
                    total += read
                    if (total > MAX_BYTES) { output.close(); target.delete(); return Check.NOT_LIBRARY to "" }
                    output.write(buffer, 0, read)
                }
            }
        } ?: return Check.NOT_LIBRARY to ""
        target.setReadOnly()
        val header = ByteArray(20)
        val headerBytes = target.inputStream().use { input ->
            var count = 0
            while (count < header.size) { val read = input.read(header, count, header.size - count); if (read < 0) break; count += read }
            count
        }
        if (headerBytes < header.size) { target.setWritable(true); target.delete(); return Check.NOT_LIBRARY to "" }
        val checksum = ChecksumCalculator.checksum(target) ?: ""
        val check = verdict(header, checksum, abi, JniUtils.expectedDefaultChecksum())
        if (check == Check.NOT_LIBRARY || check == Check.WRONG_ABI) { target.setWritable(true); target.delete() }
        return check to checksum
    }
}

/** HeliBoard loads native code once per process; relaunch the current screen in a fresh process. */
internal fun restartChirp(activity: Activity) {
    activity.startActivity(Intent(activity.intent).setClass(activity, activity.javaClass)
        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
    Runtime.getRuntime().exit(0)
}

internal fun swipeTypingSummary(context: Context) = context.getString(when (GestureLibrary.status(context)) {
    GestureLibrary.Status.ACTIVE -> R.string.swipe_summary_active
    GestureLibrary.Status.BUILT_IN -> R.string.swipe_summary_built_in
    GestureLibrary.Status.NOT_LOADED -> R.string.swipe_summary_not_loaded
    GestureLibrary.Status.NONE -> R.string.swipe_summary_none
})

@Composable
internal fun SwipeTypingSettings() {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val abi = remember { GestureLibrary.abi() }
    val status = remember { GestureLibrary.status(context) }
    var staged by remember { mutableStateOf<Pair<GestureLibrary.Check, String>?>(null) }
    var confirmRemove by remember { mutableStateOf(false) }
    var busy by remember { mutableStateOf(false) }
    val prefs = remember { keyboardPrefs(context) }
    var enabled by remember { mutableStateOf(prefs.getBoolean(Settings.PREF_GESTURE_INPUT, Defaults.PREF_GESTURE_INPUT)) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri == null) return@rememberLauncherForActivityResult
        busy = true
        scope.launch {
            staged = withContext(Dispatchers.IO) {
                runCatching { GestureLibrary.stage(context, uri) }.getOrElse { GestureLibrary.Check.NOT_LIBRARY to "" }
            }
            busy = false
        }
    }
    fun restart() { context.getActivity()?.let(::restartChirp) }
    SettingsGroup(stringResource(R.string.swipe_title)) {
        when (status) {
            GestureLibrary.Status.ACTIVE -> {
                SwitchRow(stringResource(R.string.swipe_to_type), enabled, {
                    enabled = it; prefs.edit { putBoolean(Settings.PREF_GESTURE_INPUT, it) }
                }, summary = stringResource(R.string.swipe_to_type_added))
                ActionRow(stringResource(R.string.swipe_remove), { confirmRemove = true }, destructive = true)
            }
            GestureLibrary.Status.BUILT_IN -> SwitchRow(stringResource(R.string.swipe_to_type), enabled, {
                enabled = it; prefs.edit { putBoolean(Settings.PREF_GESTURE_INPUT, it) }
            }, summary = stringResource(R.string.swipe_to_type_built_in))
            GestureLibrary.Status.NOT_LOADED -> {
                SettingsItem {
                    Text(stringResource(R.string.swipe_not_loaded, abi),
                        style = MaterialTheme.typography.bodySmall)
                }
                ActionRow(stringResource(R.string.swipe_remove), { confirmRemove = true }, destructive = true)
            }
            GestureLibrary.Status.NONE -> SettingsItem {
                Text(stringResource(R.string.swipe_none), style = MaterialTheme.typography.bodyMedium)
                LearnMore(stringResource(R.string.swipe_title), stringResource(R.string.swipe_learn_more, abi))
                OutlinedButton({ picker.launch(arrayOf("*/*")) }, Modifier.fillMaxWidth(), enabled = !busy) {
                    Text(stringResource(if (busy) R.string.swipe_checking else R.string.swipe_add))
                }
            }
        }
    }
    staged?.let { (check, checksum) ->
        fun dismiss() { GestureLibrary.candidate(context).apply { setWritable(true); delete() }; staged = null }
        when (check) {
            GestureLibrary.Check.NOT_LIBRARY, GestureLibrary.Check.WRONG_ABI -> AlertDialog(onDismissRequest = ::dismiss,
                title = { Text(stringResource(if (check == GestureLibrary.Check.WRONG_ABI) R.string.swipe_wrong_abi else R.string.swipe_not_library)) },
                text = { Text(if (check == GestureLibrary.Check.WRONG_ABI) stringResource(R.string.swipe_wrong_abi_body, abi)
                    else stringResource(R.string.swipe_not_library_body)) },
                confirmButton = { TextButton(::dismiss) { Text(stringResource(R.string.settings_ok)) } })
            else -> AlertDialog(onDismissRequest = ::dismiss,
                title = { Text(stringResource(if (check == GestureLibrary.Check.KNOWN) R.string.swipe_known else R.string.swipe_unknown)) },
                text = { Text(if (check == GestureLibrary.Check.KNOWN) stringResource(R.string.swipe_known_body, abi)
                    else stringResource(R.string.swipe_unknown_body, checksum.take(12), abi)) },
                confirmButton = { TextButton({
                    GestureLibrary.install(context, GestureLibrary.candidate(context), checksum); staged = null; restart()
                }) { Text(stringResource(if (check == GestureLibrary.Check.KNOWN) R.string.swipe_install_restart else R.string.swipe_use_anyway)) } },
                dismissButton = { TextButton(::dismiss) { Text(stringResource(R.string.settings_cancel)) } })
        }
    }
    if (confirmRemove) AlertDialog(onDismissRequest = { confirmRemove = false },
        title = { Text(stringResource(R.string.swipe_remove_confirm)) },
        text = { Text(stringResource(R.string.swipe_remove_confirm_body)) },
        confirmButton = { TextButton({ GestureLibrary.remove(context); confirmRemove = false; restart() }) { Text(stringResource(R.string.swipe_remove_restart)) } },
        dismissButton = { TextButton({ confirmRemove = false }) { Text(stringResource(R.string.settings_cancel)) } })
}
