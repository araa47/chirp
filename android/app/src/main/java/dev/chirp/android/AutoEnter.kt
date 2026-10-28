package dev.chirp.android

import android.text.InputType
import androidx.annotation.StringRes
import android.view.KeyEvent
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputConnection

/** Whether Chirp presses the editor's Send/Enter after a finished dictation. Off by default. */
enum class AutoEnterMode(val key: String, @StringRes val label: Int) {
    OFF("off", R.string.auto_enter_off), ALWAYS("always", R.string.auto_enter_always), CHAT_APPS("chat", R.string.auto_enter_chat);
    companion object { fun of(key: String?) = entries.firstOrNull { it.key == key } ?: OFF }
}

/** What to press: the field's own editor action, or a plain Enter key. */
internal sealed interface EnterPress {
    data class Action(val id: Int) : EnterPress
    data object Enter : EnterPress
}

internal object AutoEnter {
    /**
     * What to press for [info] in [mode], or null for nothing. [chatApp] is the app's rule being the Chat style.
     * Never in a password field. A Send/Go/Done action is performed as an editor action; NEXT/PREVIOUS (they move focus)
     * and SEARCH are left alone. Without an action a plain Enter goes out, except in a multi-line field whose app
     * declared "no action" (Enter there means a newline): only "Always" presses it.
     */
    fun press(info: EditorInfo?, mode: AutoEnterMode, chatApp: Boolean): EnterPress? {
        if (info == null || mode == AutoEnterMode.OFF || (mode == AutoEnterMode.CHAT_APPS && !chatApp) || password(info.inputType)) return null
        val action = info.imeOptions and EditorInfo.IME_MASK_ACTION
        return when (action) {
            EditorInfo.IME_ACTION_SEND, EditorInfo.IME_ACTION_GO, EditorInfo.IME_ACTION_DONE -> EnterPress.Action(action)
            EditorInfo.IME_ACTION_NEXT, EditorInfo.IME_ACTION_PREVIOUS, EditorInfo.IME_ACTION_SEARCH -> null
            EditorInfo.IME_ACTION_NONE -> if (multiLine(info) && mode != AutoEnterMode.ALWAYS) null else EnterPress.Enter
            else -> EnterPress.Enter
        }
    }

    /** Presses it; false when the editor refused or is gone. */
    fun send(connection: InputConnection?, press: EnterPress): Boolean = connection != null && try {
        when (press) {
            is EnterPress.Action -> connection.performEditorAction(press.id)
            EnterPress.Enter -> connection.sendKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER)) &&
                connection.sendKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER))
        }
    } catch (_: RuntimeException) { false }

    private fun multiLine(info: EditorInfo) = info.inputType and InputType.TYPE_TEXT_FLAG_MULTI_LINE != 0 ||
        info.imeOptions and EditorInfo.IME_FLAG_NO_ENTER_ACTION != 0

    private fun password(inputType: Int): Boolean {
        val variation = inputType and InputType.TYPE_MASK_VARIATION
        return when (inputType and InputType.TYPE_MASK_CLASS) {
            InputType.TYPE_CLASS_TEXT -> variation == InputType.TYPE_TEXT_VARIATION_PASSWORD ||
                variation == InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD || variation == InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD
            InputType.TYPE_CLASS_NUMBER -> variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD
            else -> false
        }
    }
}
