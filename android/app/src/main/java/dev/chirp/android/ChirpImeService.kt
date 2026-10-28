package dev.chirp.android

import android.content.res.Configuration
import android.os.Handler
import android.os.Looper
import android.view.ContextThemeWrapper
import android.view.View
import android.view.inputmethod.EditorInfo
import helium314.keyboard.event.Event
import helium314.keyboard.keyboard.internal.keyboard_parser.floris.KeyCode
import helium314.keyboard.latin.LatinIME

/** The existing IME component now contains HeliBoard plus in-process Chirp dictation. */
open class ChirpImeService : LatinIME() {
    private val handler = Handler(Looper.getMainLooper())
    private var reconfiguring = false
    private var closingHistory = false
    private var heldShortcut = 0
    private var showForShortcut = false
    private val history: KeyboardHistory by lazy { createHistory { dictation.insertText(it) } }
    internal open fun createHistory(insert: (String) -> Boolean) = KeyboardHistory(this, insert)
    private val dictation: KeyboardDictation by lazy {
        KeyboardDictation(this, ::createCapture, ::createTransport, ::prepareChirpDictation, ::finishChirpDictation,
            history = history, started = { history.close() }, learning = createLearning())
    }
    internal open fun createLearning() = EditLearning(this)
    protected open fun createCapture(frame: (ByteArray) -> Boolean, level: (Double) -> Unit, done: (String?) -> Unit): Capture =
        captureForBuild(this, frame, level, done)
    protected open fun createTransport(client: okhttp3.OkHttpClient, pairing: Pairing, event: (ServerEvent) -> Unit, failure: () -> Unit): ImeTransport =
        StreamTransport(client, pairing, dispatch = { callback -> handler.post { callback() } }, event = event, failure = failure)

    override fun onEvaluateFullscreenMode() = false
    override fun onCreateInputView(): View = super.onCreateInputView()
    // HeliBoard's InputView positions its keyboard frame at the bottom and owns window insets.
    // Insert in that frame, including when HeliBoard replaces the view on a theme/layout change.
    override fun setInputView(keys: View) {
        val suggestions = keys.findViewById<android.widget.RelativeLayout>(helium314.keyboard.latin.R.id.suggestion_strip_view)
        val previous = suggestions.findViewWithTag<KeyboardStrip>("chirp_strip")?.also(suggestions::removeView)
        val strip = KeyboardStrip(ContextThemeWrapper(this, R.style.Theme_Chirp)).apply { tag = "chirp_strip"; previous?.let(::continueTimer) }
        strip.mount(suggestions)
        dictation.attach(strip)
        history.mount(keys, strip)
        super.setInputView(keys)
    }
    override fun onChirpVoiceClick(): Boolean { dictation.toggle(); return true }
    override fun onChirpVoiceTouch(action: Int): Boolean { dictation.touch(action); return true }
    override fun onEvent(event: Event) {
        if (event.keyCode != KeyCode.VOICE_INPUT) { dictation.beforeEdit(); history.close() }
        super.onEvent(event)
    }
    override fun onTextInput(rawText: String?) { dictation.beforeEdit(); super.onTextInput(rawText) }
    override fun onStartInput(attribute: EditorInfo?, restarting: Boolean) {
        if (!reconfiguring) { history.close(); dictation.input(attribute, restarting) }
        super.onStartInput(attribute, restarting)
    }
    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        dictation.shown(); history.shown()
    }
    // Back closes the history panel and returns to the keys instead of hiding the keyboard.
    override fun onKeyDown(keyCode: Int, event: android.view.KeyEvent): Boolean {
        if (keyCode == android.view.KeyEvent.KEYCODE_BACK && history.open) { closingHistory = true; history.close(); return true }
        val shortcut = HardwareShortcut.action(keyCode, event, SettingsStore(this).hardwareShortcut, dictation.active)
        if (shortcut != HardwareShortcut.Action.NONE && hardwareShortcut(shortcut)) { heldShortcut = keyCode; return true }
        return super.onKeyDown(keyCode, event)
    }
    override fun onKeyUp(keyCode: Int, event: android.view.KeyEvent): Boolean {
        if (keyCode == android.view.KeyEvent.KEYCODE_BACK && closingHistory) { closingHistory = false; return true }
        if (keyCode == heldShortcut) { heldShortcut = 0; return true }
        return super.onKeyUp(keyCode, event)
    }
    // With a hardware keyboard the soft input view may be suppressed; show it so the strip carries status and Cancel.
    private fun hardwareShortcut(action: HardwareShortcut.Action): Boolean {
        if (action == HardwareShortcut.Action.TOGGLE && !isInputViewShown && currentInputEditorInfo?.isPasswordField() == false) {
            showForShortcut = true; updateInputViewShown()
        }
        return dictation.hardware(action)
    }
    override fun onEvaluateInputViewShown() = showForShortcut || super.onEvaluateInputViewShown()
    override fun onUpdateSelection(oldSelStart: Int, oldSelEnd: Int, newSelStart: Int, newSelEnd: Int, candidatesStart: Int, candidatesEnd: Int) {
        val owned = dictation.ownsComposition
        dictation.selection(oldSelStart, oldSelEnd, newSelStart, newSelEnd, candidatesStart, candidatesEnd)
        if (!owned) super.onUpdateSelection(oldSelStart, oldSelEnd, newSelStart, newSelEnd, candidatesStart, candidatesEnd)
    }
    override fun onFinishInputView(finishingInput: Boolean) {
        if (!reconfiguring) { dictation.hidden(); history.close() }
        super.onFinishInputView(finishingInput)
    }
    override fun onWindowHidden() { if (!reconfiguring) { dictation.hidden(); history.close() }; super.onWindowHidden() }
    override fun onFinishInput() { if (!reconfiguring) { dictation.hidden(); history.close(); showForShortcut = false }; super.onFinishInput() }
    override fun onUnbindInput() { dictation.hidden(); history.close(); super.onUnbindInput() }
    override fun onConfigurationChanged(newConfig: Configuration) {
        reconfiguring = true
        try { super.onConfigurationChanged(newConfig) } finally { reconfiguring = false }
    }
    override fun onDestroy() { dictation.destroy(); history.destroy(); handler.removeCallbacksAndMessages(null); super.onDestroy() }
}
