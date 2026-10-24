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

internal fun swipeTypingSummary(context: Context) = when (GestureLibrary.status(context)) {
    GestureLibrary.Status.ACTIVE -> "Swipe typing: on, using the gesture library you added"
    GestureLibrary.Status.BUILT_IN -> "Swipe typing: on, built into this build of Chirp"
    GestureLibrary.Status.NOT_LOADED -> "Swipe typing: the added library did not load"
    GestureLibrary.Status.NONE -> "Swipe typing: optional. Add a gesture library in Chirp settings → Keyboard → Swipe typing"
}

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
    SettingsGroup("Swipe typing") {
        when (status) {
            GestureLibrary.Status.ACTIVE -> {
                SwitchRow("Swipe to type", enabled, {
                    enabled = it; prefs.edit { putBoolean(Settings.PREF_GESTURE_INPUT, it) }
                }, summary = "Using the gesture library you added. Trail and preview options are in Keyboard layouts & settings → Gesture typing.")
                ActionRow("Remove gesture library", { confirmRemove = true }, destructive = true)
            }
            GestureLibrary.Status.BUILT_IN -> SwitchRow("Swipe to type", enabled, {
                enabled = it; prefs.edit { putBoolean(Settings.PREF_GESTURE_INPUT, it) }
            }, summary = "Built into this build of Chirp. Trail and preview options are in Keyboard layouts & settings → Gesture typing.")
            GestureLibrary.Status.NOT_LOADED -> {
                SettingsItem {
                    Text("The library you added did not load on this phone ($abi). Remove it, then add a compatible file.",
                        style = MaterialTheme.typography.bodySmall)
                }
                ActionRow("Remove gesture library", { confirmRemove = true }, destructive = true)
            }
            GestureLibrary.Status.NONE -> SettingsItem {
                Text("Chirp has no built-in swipe typing. You can add a compatible gesture library yourself.", style = MaterialTheme.typography.bodyMedium)
                LearnMore("Swipe typing", "Like HeliBoard, Chirp can use a compatible gesture library " +
                    "that you add yourself, usually Google's libjni_latinimegoogle.so taken from a Google Apps (GApps) package. " +
                    "Chirp never downloads or includes it. Using it is your choice and is subject to that library's own licence.\n\n" +
                    "This phone needs the $abi version. Chirp checks the file's SHA-256 against the known release and warns " +
                    "about anything else. A library not built for 16 KB memory pages may fail to load on Android 15+ phones " +
                    "that use them. The library runs inside Chirp with Chirp's permissions, including network access, " +
                    "so use only a file from a source you trust.")
                OutlinedButton({ picker.launch(arrayOf("*/*")) }, Modifier.fillMaxWidth(), enabled = !busy) {
                    Text(if (busy) "Checking…" else "Add gesture library…")
                }
            }
        }
    }
    staged?.let { (check, checksum) ->
        fun dismiss() { GestureLibrary.candidate(context).apply { setWritable(true); delete() }; staged = null }
        when (check) {
            GestureLibrary.Check.NOT_LIBRARY, GestureLibrary.Check.WRONG_ABI -> AlertDialog(onDismissRequest = ::dismiss,
                title = { Text(if (check == GestureLibrary.Check.WRONG_ABI) "Wrong library version" else "Not a gesture library") },
                text = { Text(if (check == GestureLibrary.Check.WRONG_ABI) "That library is for a different processor. This phone needs the $abi version."
                    else "That file is not an Android native library. Nothing was installed.") },
                confirmButton = { TextButton(::dismiss) { Text("OK") } })
            else -> AlertDialog(onDismissRequest = ::dismiss,
                title = { Text(if (check == GestureLibrary.Check.KNOWN) "Verified gesture library" else "Unknown library") },
                text = { Text(if (check == GestureLibrary.Check.KNOWN)
                    "The SHA-256 matches the known gesture library for $abi. Chirp will restart to load it."
                    else "Its SHA-256 (${checksum.take(12)}…) does not match the known library for $abi. It may be another version " +
                        "or a modified file. Continue only if you trust where it came from. An incompatible library can crash " +
                        "the keyboard when you swipe; you can remove it here. Chirp will restart to load it.") },
                confirmButton = { TextButton({
                    GestureLibrary.install(context, GestureLibrary.candidate(context), checksum); staged = null; restart()
                }) { Text(if (check == GestureLibrary.Check.KNOWN) "Install and restart" else "Use anyway and restart") } },
                dismissButton = { TextButton(::dismiss) { Text("Cancel") } })
        }
    }
    if (confirmRemove) AlertDialog(onDismissRequest = { confirmRemove = false },
        title = { Text("Remove gesture library?") },
        text = { Text("Swipe typing turns off. Chirp will restart.") },
        confirmButton = { TextButton({ GestureLibrary.remove(context); confirmRemove = false; restart() }) { Text("Remove and restart") } },
        dismissButton = { TextButton({ confirmRemove = false }) { Text("Cancel") } })
}
