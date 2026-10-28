package dev.chirp.android

import android.Manifest
import android.annotation.SuppressLint
import android.content.Intent
import android.content.res.Configuration
import android.content.pm.PackageManager
import android.inputmethodservice.InputMethodService
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.InputType
import android.view.HapticFeedbackConstants
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.view.inputmethod.InputMethodSubtype
import android.view.ContextThemeWrapper
import android.widget.Button
import android.widget.CheckBox
import android.widget.TextView
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@SuppressLint("SetTextI18n")
internal open class LegacyVoiceImeService : InputMethodService() {
    private enum class Phase { IDLE, CONNECTING, RECORDING, FINALIZING }
    private val handler = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val store by lazy { SettingsStore(this) }
    private val client by lazy { ChirpNetwork.client() }
    private val gesture = MicGesture()
    private var phase = Phase.IDLE
    private var visible = false
    private var reconfiguring = false
    @Volatile private var generation = 0
    @Volatile private var transport: ImeTransport? = null
    private var pairing: Pairing? = null
    private var preReady: PreReadyBuffer? = null
    private var audioFinished = false
    private var streamReady = false
    private var stopSent = false
    private var viewGeneration = 0
    private var readyVersion = 0
    private var pressAt: Long? = null
    private var firstPartialLatency: Long? = null
    private var stopToFinal: Long? = null
    private var pendingHealth: okhttp3.Call? = null
    private var capture: Capture? = null
    private var composing: ComposingSession? = null
    private var status = "Tap to dictate · hold to talk"
    private var partial = ""
    private var stable = ""
    private var voiceMode = false
    private lateinit var panel: LegacyVoicePanel
    private var retained = false
    private var rtt: Long? = null
    private var stopAt: Long? = null
    private var finalLatency: Long? = null
    private var undo = false
    private var expectedCursor = -1
    private var selectionStart = -1
    private var selectionEnd = -1
    private var lastSequence = -1L
    private var composingStart = -1
    private var expiry: Runnable? = null
    private var deadline: Runnable? = null
    private lateinit var strip: TextView
    private lateinit var debug: TextView
    private lateinit var banner: TextView
    private lateinit var mic: Button
    private lateinit var raw: Button
    private lateinit var correction: CheckBox

    override fun onEvaluateFullscreenMode() = false

    @SuppressLint("ClickableViewAccessibility")
    override fun onCreateInputView(): View {
        panel = LegacyVoicePanel(ContextThemeWrapper(this, R.style.Theme_Chirp))
        val column = panel.extras
        banner = panel.banner
        strip = panel.transcript
        mic = panel.mic
        mic.setOnClickListener {
            if (phase == Phase.IDLE) startSession() else stopSession()
        }
        mic.setOnTouchListener { _, event ->
            if (phase == Phase.FINALIZING) return@setOnTouchListener true
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> act(gesture.down(SystemClock.uptimeMillis(), phase != Phase.IDLE))
                MotionEvent.ACTION_UP -> act(gesture.up(SystemClock.uptimeMillis()))
                MotionEvent.ACTION_CANCEL -> act(gesture.cancel())
            }
            true
        }
        correction = CheckBox(this).apply {
            setOnCheckedChangeListener { _, checked -> store.correction = checked }
        }.also { column.addView(it) }
        panel.control("✕", "Cancel dictation") {
            cancelSession("Cancelled")
            if (voiceMode && store.returnToPrevious) previousKeyboard()
        }
        panel.control("⌫", "Backspace") { edit { currentInputConnection?.deleteSurroundingTextInCodePoints(1, 0) } }
        panel.control("Space", "Insert space") { edit { currentInputConnection?.commitText(" ", 1) } }
        panel.control("↵", "Enter or editor action") { edit { enter() } }
        panel.control("⌨ back", "Previous keyboard") { cancelSession(); previousKeyboard() }
        raw = panel.raw
        raw.setOnClickListener {
            val inserted = composing?.useRaw(expectedCursor) == true
            if (inserted) forgetUndo()
            render()
            if (inserted && store.returnToPrevious) previousKeyboard()
        }
        column.button("Chirp setup") {
            cancelSession()
            startActivity(Intent(this, SetupActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
        debug = label("", 12f).also { column.addView(it) }
        render()
        return panel
    }
    private fun act(action: MicGesture.Action) {
        when (action) {
            MicGesture.Action.START -> startSession()
            MicGesture.Action.STOP -> stopSession()
            MicGesture.Action.CANCEL -> cancelSession("Cancelled")
            MicGesture.Action.NONE -> Unit
        }
    }
    private fun startSession() {
        if (!visible || phase != Phase.IDLE) return
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            status = "Grant microphone permission in Chirp setup"; render(); return
        }
        val info = currentInputEditorInfo ?: return
        val variation = info.inputType and InputType.TYPE_MASK_VARIATION
        if (variation in setOf(InputType.TYPE_TEXT_VARIATION_PASSWORD, InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD,
                InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD) ||
            (info.inputType and InputType.TYPE_MASK_CLASS == InputType.TYPE_CLASS_NUMBER && variation == InputType.TYPE_NUMBER_VARIATION_PASSWORD)) {
            status = "Dictation unavailable in password fields"; render(); return
        }
        val connection = currentInputConnection ?: run { status = "Select a text field first"; render(); return }
        if (pairing == null) { status = "Pair with your computer in Chirp setup"; render(); return }
        forgetUndo()
        val id = ++generation
        pressAt = SystemClock.elapsedRealtime()
        composing = ComposingSession(connection)
        expectedCursor = minOf(selectionStart, selectionEnd).takeIf { it >= 0 } ?: minOf(info.initialSelStart, info.initialSelEnd)
        composingStart = -1; lastSequence = -1
        phase = Phase.CONNECTING
        audioFinished = false; streamReady = false; stopSent = false
        status = "Connecting to your computer…"; partial = ""; stable = ""
        stopAt = null; finalLatency = null; stopToFinal = null; firstPartialLatency = null
        val buffer = PreReadyBuffer(send = { bytes -> transport?.audio(bytes) == true })
        preReady = buffer
        // Start capture before any network work. The buffer owns and zeroes every PCM frame.
        capture = createCapture(
            frame = { bytes -> buffer.offer(bytes) },
            level = { value -> handler.post {
                if (generation == id && phase in setOf(Phase.CONNECTING, Phase.RECORDING)) {
                    panel.level(value)
                }
            } },
            done = { error -> handler.post {
                if (generation == id) {
                    capture = null
                    if (error != null) cancelSession(error.resolve(resources)) else finishAudio(id)
                }
            } })
        capture?.start(); haptic(); render()
        setDeadline(id, 18000, "Computer unreachable — is Tailscale on?")
        if (ensureTransport()?.start(store.correction) != true) cancelSession("Computer unreachable — is Tailscale on?")
    }
    private fun onServerEvent(id: Int, event: ServerEvent) {
        when (event) {
            is ServerEvent.Ready -> {
                if (streamReady || phase !in setOf(Phase.CONNECTING, Phase.FINALIZING)) {
                    cancelSession("Unexpected server response"); return
                }
                ++readyVersion
                retained = event.debugRetention
                store.health = store.health?.copy(debugRetention = retained)
                streamReady = true
                clearDeadline()
                if (preReady?.ready() != true) { cancelSession("Connection too slow — try again"); return }
                if (phase == Phase.CONNECTING) { phase = Phase.RECORDING; status = "Listening…" }
                if (audioFinished) sendStop(id)
            }
            is ServerEvent.Partial -> {
                if (!streamReady || phase !in setOf(Phase.RECORDING, Phase.FINALIZING) || event.seq <= lastSequence) return
                lastSequence = event.seq
                if (firstPartialLatency == null && event.text.isNotEmpty())
                    firstPartialLatency = pressAt?.let { SystemClock.elapsedRealtime() - it }
                partial = event.text; stable = event.stable
                // Some editors refuse composing spans: the panel still shows live text.
                composing?.partial(event)
            }
            is ServerEvent.Final -> {
                if (phase != Phase.FINALIZING || !stopSent) { cancelSession("Unexpected server response"); return }
                stopToFinal = stopAt?.let { SystemClock.elapsedRealtime() - it }
                clearDeadline()
                capture?.stop(); capture = null
                preReady?.cancel(); preReady = null
                phase = Phase.IDLE; streamReady = false
                transport?.close(immediate = true); transport = null
                client.connectionPool.evictAll()
                val insertionStart = if (composingStart >= 0) composingStart else expectedCursor
                if (composing?.final(event) != true) { cancelSession("Text field unavailable — try again"); return }
                expectedCursor = insertionStart + (composing?.committedLength ?: 0)
                finalLatency = stopAt?.let { SystemClock.elapsedRealtime() - it }
                status = "Tap to dictate again"; partial = ""; stable = ""
                undo = event.corrected && event.raw != event.text
                if (undo) {
                    render() // Start the undo window after the control is visible.
                    expiry = Runnable {
                        forgetUndo(); render()
                        if (visible && store.returnToPrevious) previousKeyboard()
                    }.also { handler.postDelayed(it, 5000) }
                    return
                } else {
                    composing = null
                    if (store.returnToPrevious) previousKeyboard()
                }
            }
            is ServerEvent.Failure -> cancelSession(when (event.code) {
                "auth" -> "Pairing refused — pair again in Chirp setup"
                "busy" -> "Chirp server is busy — try again"
                "too_long" -> "Dictation limit is 120 seconds"
                "bad_audio" -> "No audio received — try again"
                else -> "Speech engine unavailable — try again"
            })
            is ServerEvent.Correcting, ServerEvent.Unknown -> Unit
        }
        render()
    }
    private fun stopSession() {
        if (phase !in setOf(Phase.CONNECTING, Phase.RECORDING)) return
        phase = Phase.FINALIZING; status = "Finishing…"; stopAt = SystemClock.elapsedRealtime()
        haptic(); capture?.stop(); render()
        // Completion waits for recorder.release, and Ready if the press ended before connection.
    }
    private fun finishAudio(id: Int) {
        audioFinished = true
        if (phase != Phase.FINALIZING) {
            phase = Phase.FINALIZING; stopAt = SystemClock.elapsedRealtime(); status = "Finishing…"
        }
        if (streamReady) sendStop(id)
        render()
    }
    private fun sendStop(id: Int) {
        if (stopSent) return
        if (transport?.stop() != true) { cancelSession("Computer unreachable — is Tailscale on?"); return }
        stopSent = true
        setDeadline(id, 60000, "Chirp server took too long — try again")
    }
    private fun cancelSession(message: String = "Tap to dictate · hold to talk") {
        val active = phase != Phase.IDLE
        ++generation
        clearDeadline(); forgetUndo()
        preReady?.cancel(); preReady = null
        capture?.stop(); capture = null
        transport?.close(cancel = active, immediate = !active); transport = null
        client.connectionPool.evictAll()
        composing?.cancel(); composing = null
        partial = ""; stable = ""; phase = Phase.IDLE; status = message
        audioFinished = false; streamReady = false; stopSent = false
        render()
    }
    internal open fun createCapture(frame: (ByteArray) -> Boolean, level: (Double) -> Unit,
                                     done: (DictationStatus?) -> Unit): Capture = PcmCapture(frame, level, done)

    internal open fun createTransport(paired: Pairing, event: (ServerEvent) -> Unit,
                                      failure: () -> Unit): ImeTransport = StreamTransport(client, paired,
        dispatch = { callback -> handler.post { callback() } }, event = event, failure = failure)

    protected open fun loadPairing(): Pairing? = store.pairing()

    private fun ensureTransport(): ImeTransport? {
        transport?.let { return it }
        val paired = pairing ?: return null
        if (!visible) return null
        lateinit var stream: ImeTransport
        stream = createTransport(paired,
            event = { event -> if (transport === stream && phase != Phase.IDLE) onServerEvent(generation, event) },
            failure = {
                if (transport === stream) {
                    transport = null
                    if (phase != Phase.IDLE) cancelSession("Computer unreachable — is Tailscale on?")
                }
            })
        transport = stream
        stream.connect()
        return stream
    }
    protected open fun refreshHealth() {
        val paired = pairing ?: return
        val id = viewGeneration
        val readyAtStart = readyVersion
        pendingHealth?.cancel()
        val call = ChirpNetwork.healthCall(client, paired)
        pendingHealth = call
        scope.launch {
            try {
                val started = SystemClock.elapsedRealtime()
                val response = withContext(Dispatchers.IO) { ChirpNetwork.health(call) }
                val health = if (readyVersion == readyAtStart) response else response.copy(debugRetention = retained)
                if (!visible || id != viewGeneration) return@launch
                pendingHealth = null
                rtt = SystemClock.elapsedRealtime() - started
                val old = store.health
                if (!health.correctionAvailable || correctionLabel(old) != correctionLabel(health) ||
                    (health.correctionLeavesMachine && health.correctionHost == null)) store.correction = false
                store.health = health; retained = health.debugRetention
                render()
            } catch (_: Exception) {
                if (id == viewGeneration) pendingHealth = null
                // Cached metadata remains visible; this request never gates recording.
            }
        }
    }
    private fun hideResources() {
        visible = false; ++viewGeneration
        cancelSession()
        pendingHealth?.cancel(); pendingHealth = null
        transport?.close(immediate = true); transport = null
        client.dispatcher.cancelAll(); client.connectionPool.evictAll()
        pairing = null
    }
    private fun setDeadline(id: Int, ms: Long, message: String) {
        clearDeadline()
        deadline = Runnable { if (generation == id) cancelSession(message) }.also { handler.postDelayed(it, ms) }
    }
    private fun clearDeadline() { deadline?.let(handler::removeCallbacks); deadline = null }
    private fun forgetUndo() {
        expiry?.let(handler::removeCallbacks); expiry = null; undo = false; composing?.forgetUndo()
    }
    private fun haptic() { if (store.haptics && ::mic.isInitialized) mic.performHapticFeedback(HapticFeedbackConstants.CONFIRM) }
    private fun edit(action: () -> Unit) { cancelSession(); action() }
    private fun enter() {
        val info = currentInputEditorInfo ?: return
        val action = info.imeOptions and EditorInfo.IME_MASK_ACTION
        if (info.imeOptions and EditorInfo.IME_FLAG_NO_ENTER_ACTION == 0 && action != EditorInfo.IME_ACTION_NONE &&
            action != EditorInfo.IME_ACTION_UNSPECIFIED) currentInputConnection?.performEditorAction(action)
        else {
            currentInputConnection?.sendKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER))
            currentInputConnection?.sendKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER))
        }
    }
    protected open fun previousKeyboard() {
        // The IME token can already be invalid after a hide/unbind from an editor callback.
        try {
            if (!switchToPreviousInputMethod()) getSystemService(InputMethodManager::class.java).showInputMethodPicker()
        } catch (_: RuntimeException) {
            status = "Choose a keyboard with the system keyboard button"; render()
        }
    }
    private fun render() {
        if (!::strip.isInitialized) return
        panel.show(status, partial, stable, phase != Phase.IDLE, phase == Phase.FINALIZING)
        if (partial.isEmpty()) strip.text = status
        banner.retention(retained || store.health?.debugRetention == true)
        correction.text = correctionLabel(store.health)
        correction.isEnabled = phase == Phase.IDLE && store.health?.let {
            it.correctionAvailable && (!it.correctionLeavesMachine || it.correctionHost != null)
        } == true
        correction.isChecked = store.correction
        raw.visibility = if (undo) View.VISIBLE else View.GONE
        debug.visibility = if (store.debugOverlay) View.VISIBLE else View.GONE
        debug.text = "Press→first partial: ${firstPartialLatency ?: "—"} ms · stop→final: ${stopToFinal ?: "—"} ms\n" +
            "Stop→commit: ${finalLatency ?: "—"} ms · health RTT: ${rtt ?: "—"} ms"
    }
    override fun onStartInput(attribute: EditorInfo?, restarting: Boolean) {
        super.onStartInput(attribute, restarting)
        if (!reconfiguring) {
            cancelSession()
            selectionStart = attribute?.initialSelStart ?: -1
            selectionEnd = attribute?.initialSelEnd ?: -1
        }
    }
    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        val wasVisible = visible
        visible = true
        if (!wasVisible) {
            ++viewGeneration
            pairing = loadPairing()
            refreshHealth()
            if (voiceMode) startSession()
        }
        render()
    }
    override fun onCurrentInputMethodSubtypeChanged(newSubtype: InputMethodSubtype?) {
        super.onCurrentInputMethodSubtypeChanged(newSubtype)
        voiceMode = newSubtype?.mode == "voice"
    }
    override fun onFinishInputView(finishingInput: Boolean) {
        if (!reconfiguring) hideResources()
        if (!reconfiguring) super.onFinishInputView(finishingInput)
    }
    override fun onWindowHidden() {
        if (!reconfiguring) hideResources()
        super.onWindowHidden()
    }
    override fun onFinishInput() { if (!reconfiguring) { cancelSession(); super.onFinishInput() } }
    override fun onUnbindInput() { hideResources(); super.onUnbindInput() }
    override fun onConfigurationChanged(newConfig: Configuration) {
        // The service and capture survive resizing/folding; framework recreates only the view.
        reconfiguring = true
        try { super.onConfigurationChanged(newConfig) } finally { reconfiguring = false }
        render()
    }
    override fun onUpdateSelection(oldSelStart: Int, oldSelEnd: Int, newSelStart: Int, newSelEnd: Int,
                                   candidatesStart: Int, candidatesEnd: Int) {
        super.onUpdateSelection(oldSelStart, oldSelEnd, newSelStart, newSelEnd, candidatesStart, candidatesEnd)
        selectionStart = newSelStart; selectionEnd = newSelEnd
        if (phase != Phase.IDLE) {
            if (candidatesStart >= 0 && newSelStart == candidatesEnd && newSelEnd == candidatesEnd) {
                composingStart = candidatesStart
            } else if (newSelStart != oldSelStart || newSelEnd != oldSelEnd) cancelSession("Text field changed — start again")
        } else if (undo && (newSelStart != expectedCursor || newSelEnd != expectedCursor)) {
            forgetUndo(); render()
        }
    }
    override fun onDestroy() {
        hideResources(); scope.cancel(); handler.removeCallbacksAndMessages(null)
        ChirpNetwork.dispose(client); super.onDestroy()
    }
}
