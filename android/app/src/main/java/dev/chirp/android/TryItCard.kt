package dev.chirp.android

import android.content.res.ColorStateList
import android.text.InputType
import android.view.View
import android.widget.EditText
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import dev.chirp.android.ui.NavRow
import dev.chirp.android.ui.SettingsGroup
import kotlinx.coroutines.launch

/** First-run card on Home: a real field to type and dictate into, and the keyboard picker. Stays until dismissed. */
@Composable
internal fun TryItCard(store: SettingsStore, onDismiss: () -> Unit) {
    val context = LocalContext.current
    Surface(Modifier.fillMaxWidth(), shape = MaterialTheme.shapes.large, color = MaterialTheme.colorScheme.surfaceContainer) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Text(stringResource(R.string.try_it_title), Modifier.semantics { heading() }, style = MaterialTheme.typography.titleLarge)
            Text(stringResource(if (store.inputMode == InputMode.OWN_KEYBOARD) R.string.try_it_body_bubble else R.string.try_it_body_keyboard),
                style = MaterialTheme.typography.bodyMedium)
            // Deliberately a real native editor: exercises the same InputConnection/accessibility path as other apps.
            val editorInk = MaterialTheme.colorScheme.onSurface.toArgb()
            val editorHint = MaterialTheme.colorScheme.onSurfaceVariant.toArgb()
            val editorAccent = MaterialTheme.colorScheme.primary.toArgb()
            val editorPrompt = stringResource(R.string.try_it_hint)
            val bringEditor = remember { BringIntoViewRequester() }
            val editorScope = rememberCoroutineScope()
            AndroidView(factory = { editorContext -> EditText(editorContext).apply {
                hint = editorPrompt; minLines = 3
                inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE or InputType.TYPE_TEXT_FLAG_AUTO_CORRECT or InputType.TYPE_TEXT_FLAG_CAP_SENTENCES
                onFocusChangeListener = View.OnFocusChangeListener { _, focused ->
                    if (focused) postDelayed({ editorScope.launch { bringEditor.bringIntoView() } }, 350)
                }
                isSaveEnabled = false; importantForAutofill = View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS
            } }, update = { editor ->
                editor.setTextColor(editorInk); editor.setHintTextColor(editorHint)
                editor.backgroundTintList = ColorStateList.valueOf(editorAccent)
            }, modifier = Modifier.fillMaxWidth().bringIntoViewRequester(bringEditor))
            if (store.inputMode != InputMode.OWN_KEYBOARD) SettingsGroup {
                NavRow(stringResource(R.string.setup_choose_keyboard), { context.getSystemService(android.view.inputmethod.InputMethodManager::class.java).showInputMethodPicker() })
            }
            TextButton({ store.tryItDismissed = true; onDismiss() }, Modifier.align(Alignment.End)) { Text(stringResource(R.string.try_it_dismiss)) }
        }
    }
}
