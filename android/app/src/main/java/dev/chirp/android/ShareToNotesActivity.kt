package dev.chirp.android

import android.content.Intent
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Receives only the requested share; it never forwards text to another Activity or the speech server. */
open class ShareToNotesActivity : ComponentActivity() {
    internal open fun library() = NotesSessions(applicationContext)
    private var shared: String? = null
    private var subject: String? = null
    private var message by mutableStateOf<String?>(null)
    private var saving by mutableStateOf(false)
    // Keep the selected session identity: if it ends, never append into its replacement.
    private var target: NotesControls.Session? = null
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 33) setRecentsScreenshotEnabled(false)
        shared = if (intent.action == Intent.ACTION_SEND && intent.type == "text/plain")
            intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString() else null
        subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)?.take(200)
        message = when {
            shared == null -> getString(R.string.share_notes_only_text)
            shared!!.length > MAX_TEXT -> getString(R.string.share_notes_too_long)
            shared!!.isBlank() -> getString(R.string.share_notes_empty)
            else -> null
        }
        if (message != null) shared = null
        target = NotesControls.session?.takeIf { canAppend(it) }
        setContent {
            ChirpTheme {
                ShareToNotesDialog(target?.takeIf { canAppend(it) }?.shareTitle, message, shared != null && !saving,
                    save = { save(false) }, append = { save(true) }, cancel = ::finish)
            }
        }
    }
    internal fun save(append: Boolean) {
        val text = shared ?: return
        if (saving) return
        if (append) {
            val current = target
            if (current != null && NotesControls.session === current && canAppend(current) && current.appendShared(text)) finish()
            else { target = null; message = getString(R.string.share_notes_stopped) }
            return
        }
        saving = true
        lifecycleScope.launch {
            val error = withContext(Dispatchers.IO) {
                try {
                    val notes = library()
                    if (!notes.enabled) getString(R.string.share_notes_off)
                    else {
                        val note = NotesDocument().apply {
                            userEdit(0, 0, text)
                            name = subject?.trim()?.takeIf(String::isNotBlank) ?: text.lineSequence().firstOrNull { it.isNotBlank() }?.trim()?.take(200)
                        }
                        if (notes.put(note.uid, note.toJson())) null else getString(R.string.share_notes_save_failed)
                    }
                } catch (_: Exception) { getString(R.string.share_notes_save_failed) }
            }
            saving = false
            if (error == null) finish() else message = error
        }
    }
    override fun onDestroy() { shared = null; subject = null; target = null; super.onDestroy() }
    companion object {
        const val MAX_TEXT = 100_000
        internal fun canAppend(session: NotesControls.Session) = session.state == NotesRecorder.State.RECORDING || session.state == NotesRecorder.State.PAUSED
    }
}

@Composable
internal fun ShareToNotesDialog(recordingTitle: String?, message: String?, enabled: Boolean,
                               save: () -> Unit, append: () -> Unit, cancel: () -> Unit) {
    AlertDialog(onDismissRequest = cancel,
        title = { Text(stringResource(R.string.share_notes_title)) },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(message ?: stringResource(R.string.share_notes_message))
                if (recordingTitle != null) OutlinedButton(append, Modifier.fillMaxWidth(), enabled = enabled) {
                    Text(stringResource(R.string.share_notes_add_to, recordingTitle))
                }
            }
        },
        confirmButton = { TextButton(save, enabled = enabled) { Text(stringResource(R.string.share_notes_save_new)) } },
        dismissButton = { TextButton(cancel) { Text(stringResource(R.string.notes_action_cancel)) } })
}
