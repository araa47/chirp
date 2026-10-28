package dev.chirp.android

import android.Manifest
import android.accessibilityservice.AccessibilityService
import android.annotation.SuppressLint
import android.app.KeyguardManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.content.res.Configuration
import android.graphics.Rect
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PersistableBundle
import android.os.SystemClock
import android.provider.Settings
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.Toast
import androidx.core.content.ContextCompat
import androidx.core.view.isVisible

/**
 * Opt-in, event-driven floating mic (#167). The system binding stays idle; no idle mic, socket or polling.
 * The bubble shows only on a focused, enabled, non-password editable field; a final that can't be inserted
 * waits in the panel (Ready to copy) instead of being dropped. Text lives in memory only.
 */
open class ChirpAccessibilityService : AccessibilityService(), FloatingMicOverlay.Host {
    private enum class Surface { BUBBLE, HOLD, PANEL }
    private val handler = Handler(Looper.getMainLooper())
    private val store by lazy { SettingsStore(this) }
    private val manager by lazy { getSystemService(WindowManager::class.java) }
    private val learning by lazy { createLearning().apply { eligible = { !locked() && !privateUtterance && learningPermitted(focused) } } }
    private var learningEditor: android.view.inputmethod.EditorInfo? = null
    private var learnedPayload = LearnedPayload()
    private var privateUtterance = false
    private var historyId: String? = null
    private val history by lazy { DictationHistory(this) }
    private val gesture = MicGesture()
    private var overlay: FloatingMicOverlay? = null
    private var focused: AccessibilityNodeInfo? = null
    private var target: FocusedInsertion? = null
    private var stream: DictationStream? = null
    private var client: okhttp3.OkHttpClient? = null
    private var pendingStart = false
    private var pendingStop = false
    private var surface = Surface.BUBBLE
    private var state = FloatingState.IDLE
    private var status: DictationStatus? = null
    private var partial = ""
    private var stable = ""
    /** Ready to copy, or what was heard before an error: memory only, cleared on Done, Hide, screen off or after 2 minutes. */
    private var kept = ""
    private var copyMode = false
    private var polishing = false
    private var raw: String? = null
    private var level = 0.0
    private var retained = false
    private var committing = false
    /** "Hide here": the app the bubble is hidden in until it leaves the foreground. Session only, never persisted. */
    private var hiddenIn: String? = null
    private val dictating get() = stream != null || pendingStart
    private val screen = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action == Intent.ACTION_SCREEN_OFF) onInterrupt()
            else if (intent?.action == Intent.ACTION_USER_PRESENT) {
                focused = findFocus(AccessibilityNodeInfo.FOCUS_INPUT); refresh()
            }
        }
    }
    override fun onCreate() {
        super.onCreate()
        ContextCompat.registerReceiver(this, screen, IntentFilter().apply {
            addAction(Intent.ACTION_SCREEN_OFF); addAction(Intent.ACTION_USER_PRESENT)
        }, ContextCompat.RECEIVER_NOT_EXPORTED)
    }
    private fun locked() = getSystemService(KeyguardManager::class.java).isKeyguardLocked
    private val undoExpiry = Runnable { forgetUndo(); collapse() }
    private val insertedDone = Runnable { if (state == FloatingState.INSERTED) collapse() }
    private val keptExpiry = Runnable { if (state == FloatingState.READY_TO_COPY || state == FloatingState.ERROR) { clearKept(); collapse() } }

    private fun overlay() = overlay ?: FloatingMicOverlay(this, manager, store, this).also { overlay = it }

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        event ?: return
        if (locked()) { onInterrupt(); return }
        if (overlay?.owns(event.windowId) == true) return
        when (event.eventType) {
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> {
                val foreground = event.packageName?.toString()
                val now = findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
                // "Hide in this app" ends when the app leaves the foreground: another app's window, or the input focus
                // no longer in it at all (Home). A keyboard popup leaves the focus where it was, so it doesn't count.
                if (foreground != null && foreground != hiddenIn && foreground != packageName && !isKeyboard(foreground)) hiddenIn = null
                if (hiddenIn != null && now?.packageName?.toString() != hiddenIn && foreground?.let(::isKeyboard) != true) hiddenIn = null
                // The same field still focused (a keyboard popup, a dialog over nothing editable): only re-place.
                if (now != null && now == focused) { refresh(); return }
                // A window transition never carries a final into a different app: finish what was said into Ready to copy.
                learning.watcher.finish(sample = false)
                if (dictating) leaveField()
                if (state == FloatingState.POLISHED || state == FloatingState.INSERTED) { forgetUndo(); state = FloatingState.IDLE; surface = Surface.BUBBLE; overlay?.closePanel() }
                focused = now?.takeIf { it.isEditable }
                refresh()
            }
            AccessibilityEvent.TYPE_VIEW_FOCUSED -> {
                val source = event.source
                if (source == focused) return
                // Only the system's input focus counts: a WebView can report focus for a textarea it doesn't hold.
                if (source != null && source != findFocus(AccessibilityNodeInfo.FOCUS_INPUT)) return
                learning.watcher.finish(sample = false)
                if (dictating) leaveField()
                if (state == FloatingState.POLISHED) { forgetUndo(); collapseQuietly() }
                focused = source?.takeIf { it.isEditable }
                refresh()
            }
            AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED, AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED -> {
                if (committing) return
                val source = event.source
                if (source != focused) {
                    // A field focused before its window settled sends no focus event; a tap in it still moves the caret.
                    if (source != null && !dictating && surface == Surface.BUBBLE && source.isFocused && source.isEditable &&
                        source == findFocus(AccessibilityNodeInfo.FOCUS_INPUT)) { focused = source; refresh() }
                    return
                }
                edited()
            }
            else -> Unit // Only the four configured event types are handled.
        }
    }
    /** Any edit ends the Use raw window; the edit itself is the user's. */
    private fun edited() {
        learning.watcher.sample()
        if (raw != null && target?.matchesFinal() != true) { forgetUndo(); collapse() }
        if (surface == Surface.BUBBLE) refresh()
    }
    override fun onServiceConnected() {
        super.onServiceConnected()
        if (Build.VERSION.SDK_INT >= 33) serviceInfo = serviceInfo.apply {
            flags = flags or android.accessibilityservice.AccessibilityServiceInfo.FLAG_INPUT_METHOD_EDITOR
        }
        focused = findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        refresh()
    }

    /** Android 13+ exposes the real IME privacy flags without replacing the user's keyboard.
     * On older versions the floating mic cannot prove a field is not incognito, so it does not learn. */
    @androidx.annotation.RequiresApi(33)
    override fun onCreateInputMethod(): android.accessibilityservice.InputMethod =
        object : android.accessibilityservice.InputMethod(this) {
            override fun onStartInput(attribute: android.view.inputmethod.EditorInfo, restarting: Boolean) {
                learning.watcher.finish(sample = false)
                learningEditor = android.view.inputmethod.EditorInfo().apply {
                    inputType = attribute.inputType; imeOptions = attribute.imeOptions; packageName = attribute.packageName
                }
                super.onStartInput(attribute, restarting)
            }
            override fun onFinishInput() {
                learning.watcher.finish(sample = false); learningEditor = null
                super.onFinishInput()
            }
        }
    internal open fun learningEditorInfo(): android.view.inputmethod.EditorInfo? = learningEditor
    private fun learningPermitted(node: AccessibilityNodeInfo?): Boolean {
        val info = learningEditorInfo() ?: return false
        return node?.packageName?.toString() == info.packageName && DictationHistory.allowed(info) && FocusedInsertion.learningPrivateAllowed(node)
    }

    private fun isKeyboard(pkg: String) = Settings.Secure.getString(contentResolver, Settings.Secure.DEFAULT_INPUT_METHOD)
        ?.let { ComponentName.unflattenFromString(it)?.packageName == pkg } == true

    private fun area(node: AccessibilityNodeInfo?): Area? = node?.let {
        val rect = Rect(); it.getBoundsInScreen(rect)
        if (rect.isEmpty) null else Area(rect.left, rect.top, rect.right, rect.bottom)
    }

    /** Shows, moves or hides the bubble for the focused field; a panel in use stays where it is. */
    private fun refresh() {
        when (surface) {
            Surface.HOLD -> return
            // A panel with nothing in it closes when its field goes; one holding words or a live utterance stays put.
            Surface.PANEL -> if (state == FloatingState.IDLE && !dictating && FocusedInsertion.eligibility(focused) == FocusedInsertion.Eligibility.NONE) {
                collapseQuietly()
            } else { overlay?.placePanel(area(focused)); return }
            Surface.BUBBLE -> Unit
        }
        val node = focused
        val eligibility = FocusedInsertion.eligibility(node)
        // Chirp Keyboard has its own mic, so the bubble steps aside while it is the input method (#165 §1.1).
        val hidden = eligibility == FocusedInsertion.Eligibility.NONE || chirpKeyboardActive(this) ||
            (hiddenIn != null && node?.packageName?.toString() == hiddenIn)
        if (hidden) { overlay?.hideBubble(animated = true); return }
        overlay().showBubble(area(node), eligibility == FocusedInsertion.Eligibility.COPY)
    }

    /** Back to the bubble, discarding any panel; never while an utterance is live. */
    private fun collapse() {
        if (dictating) return
        collapseQuietly()
        refresh()
    }
    private fun collapseQuietly() {
        handler.removeCallbacks(insertedDone)
        overlay?.closePanel(); overlay?.leaveHold()
        surface = Surface.BUBBLE
        if (!dictating) { state = FloatingState.IDLE; status = null; partial = ""; stable = ""; polishing = false }
    }

    // ---- Bubble gestures (FloatingMicOverlay.Host) -----------------------------------------------------------

    override fun tap() { expand(); begin() }
    override fun holdStart() {
        if (dictating) return
        if (store.haptics) overlay?.bubble?.performHapticFeedback(HapticFeedbackConstants.CONFIRM)
        surface = Surface.HOLD
        overlay?.enterHold()
        begin()
    }
    override fun holdEnd() { if (surface == Surface.HOLD) stop() }
    override fun holdCancel() { cancel(); collapse() }
    override fun hideHere() {
        val app = focused?.packageName?.toString() ?: return
        hiddenIn = app
        cancel(); clearKept()
        overlay?.hideBubble(animated = false)
        Toast.makeText(this, getString(R.string.bubble_hidden), Toast.LENGTH_SHORT).show()
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun expand() {
        if (surface == Surface.PANEL && overlay?.panel != null) return
        surface = Surface.PANEL
        val view = overlay().openPanel()
        view.mic.setOnClickListener { if (!dictating) begin() else stop() } // TalkBack's double tap.
        view.mic.setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> act(gesture.down(SystemClock.uptimeMillis(), dictating))
                MotionEvent.ACTION_UP -> act(gesture.up(SystemClock.uptimeMillis()))
                MotionEvent.ACTION_CANCEL -> act(gesture.cancel())
            }; true
        }
        view.cancel.setOnClickListener { cancel(); collapse() }
        view.hide.setOnClickListener { cancel(); clearKept(); collapse() }
        view.done.setOnClickListener { clearKept(); collapse() }
        view.raw.setOnClickListener { useRaw() }
        view.copy.setOnClickListener { copyKept() }
        view.scratchpad.setOnClickListener {
            val text = kept.takeIf { it.isNotBlank() } ?: return@setOnClickListener
            clearKept(); collapse()
            ScratchpadActivity.open(this, text)
        }
        view.fix.setOnClickListener { fix() }
        render()
    }
    private fun act(action: MicGesture.Action) {
        when (action) {
            MicGesture.Action.START -> begin()
            MicGesture.Action.STOP -> stop()
            MicGesture.Action.CANCEL -> cancel()
            MicGesture.Action.NONE -> Unit
        }
    }

    // ---- Dictation -------------------------------------------------------------------------------------------

    private fun begin() {
        if (dictating) return
        if (locked()) { onInterrupt(); return }
        learning.watcher.finish()
        forgetUndo(); clearKept()
        val eligibility = FocusedInsertion.eligibility(focused)
        if (eligibility == FocusedInsertion.Eligibility.NONE) { collapse(); return }
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            fail(StatusLine.BUBBLE_NO_MICROPHONE); return
        }
        val paired = loadPairing() ?: run { fail(StatusLine.BUBBLE_NOT_PAIRED); return }
        tailscaleProblem(paired)?.let { fail(it); return }
        privateUtterance = PrivateSession.enabled
        historyId = null
        target = FocusedInsertion.from(focused)
        copyMode = target == null
        partial = ""; stable = ""; polishing = false; level = 0.0; status = null
        state = FloatingState.CONNECTING
        pendingStart = true; pendingStop = false
        try {
            // AOSP binds accessibility with INCLUDE_CAPABILITIES and ALLOW_BACKGROUND_ACTIVITY_STARTS.
            // Still promote explicitly as a microphone FGS and handle OEM/permission denial without recording.
            ContextCompat.startForegroundService(this, Intent(this, ChirpAccessibilityService::class.java).setAction(START))
        } catch (_: RuntimeException) {
            pendingStart = false; target?.forget(); target = null
            fail(StatusLine.BUBBLE_BLOCKED); return
        }
        render()
    }
    /** A tailnet pairing with the VPN down can't reach the Mac: say so before opening the mic. */
    private fun tailscaleProblem(paired: Pairing): DictationStatus? {
        if (!TailscaleControl.routes(paired.base)) return null
        val control = tailscale()
        return when {
            !control.installed() -> StatusLine.TAILSCALE_MISSING
            !control.connected() -> StatusLine.TAILSCALE_OFF
            else -> null
        }
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == CANCEL) { cancel(); collapse(); return START_NOT_STICKY }
        if (intent?.action != START || !pendingStart) { cancel(); return START_NOT_STICKY }
        try {
            val notifications = getSystemService(NotificationManager::class.java)
            notifications.createNotificationChannel(NotificationChannel(CHANNEL, getString(R.string.bubble_channel), NotificationManager.IMPORTANCE_LOW))
            val cancel = PendingIntent.getService(this, 0, Intent(this, ChirpAccessibilityService::class.java).setAction(CANCEL),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            // Never any dictated text; removed when the utterance ends.
            val notification = Notification.Builder(this, CHANNEL).setSmallIcon(R.drawable.ic_chirp_notification)
                .setContentTitle(getString(R.string.bubble_listening_title)).setContentText(getString(R.string.bubble_listening_text))
                .setOngoing(true).addAction(Notification.Action.Builder(null, getString(R.string.panel_cancel), cancel).build()).build()
            startForeground(12, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
            val paired = loadPairing() ?: error("Pairing required")
            val network = ChirpNetwork.client(this); client = network
            val session = DictationStream(
            deadlines = store.health?.operationDeadlines ?: OperationDeadlines(),
                transportFactory = { event, failure -> createTransport(network, paired, event, failure) },
                captureFactory = ::createCapture,
                changed = { text, event -> changed(text, event, paired) },
                level = { value -> level = value; overlay?.panel?.level(value); overlay?.level(value) },
                retention = { retained = it; store.health = store.health?.copy(debugRetention = it); render() },
                correcting = { polishing = true; render() },
                kept = { heard, reason -> keep(heard, FloatingState.ERROR, reason) },
                final = ::finalReady,
                ended = {
                    stream = null; pendingStart = false
                    client?.let(ChirpNetwork::dispose); client = null
                    stopForeground(STOP_FOREGROUND_REMOVE); stopSelf()
                    if (raw == null) { target?.forget(); target = null }
                    ended()
                },
            )
            stream = session; pendingStart = false
            val pkg = focused?.packageName?.toString()
            learning.prepare(pkg, !privateUtterance && learningPermitted(focused)) { payload ->
                if (stream === session) {
                    learnedPayload = payload
                    val style = store.style(pkg)
                    session.start(store.correction, style.id, prompt = store.promptEdits[style.id], learned = payload)
                    if (pendingStop) session.stop()
                }
            }
            haptic()
            if (pendingStop) session.stop()
        } catch (_: RuntimeException) {
            cancel(); fail(StatusLine.BUBBLE_BLOCKED)
        }
        return START_NOT_STICKY
    }
    private fun changed(text: DictationStatus, event: ServerEvent.Partial?, paired: Pairing) {
        if (event != null) { partial = event.text; stable = event.stable }
        when (text) {
            StatusLine.CONNECTING -> state = FloatingState.CONNECTING
            StatusLine.LISTENING -> state = FloatingState.LISTENING
            StatusLine.FINISHING -> state = FloatingState.FINISHING
            StatusLine.POLISHING -> { state = FloatingState.FINISHING; polishing = true }
            else -> {
                // Errors: an unreachable Mac on a tailnet pairing with the VPN down says so, with Turn on.
                val offline = BubbleFix.forStatus(text) == BubbleFix.CHECK_AGAIN
                state = FloatingState.ERROR
                status = (if (offline) tailscaleProblem(paired) else null) ?: text
            }
        }
        render()
    }
    private fun finalReady(received: ServerEvent.Final) {
        val result = received.copy(text = if (!privateUtterance && LearnedStore(this).allowed && learningPermitted(focused)) learnedPayload.apply(received.text) else received.text)
        committing = true
        val inserted = try { !locked() && target?.insert(result.text) == true } catch (_: RuntimeException) { false } finally { committing = false }
        partial = ""; stable = ""
        if (!inserted) { target?.forget(); target = null; keep(result.text, FloatingState.READY_TO_COPY); return }
        val insertion = target
        val node = focused
        if (!privateUtterance && !PrivateSession.enabled && node != null && insertion != null && learningPermitted(node)) {
            val pkg = node.packageName?.toString()
            val info = android.view.inputmethod.EditorInfo().apply { inputType = node.inputType; packageName = pkg }
            val id = java.util.UUID.randomUUID().toString(); historyId = id
            HistoryIo.run { history.record(result.text, result.raw.takeIf { result.corrected }, pkg, info, id) }
            insertion.learningText?.let { learning.watch(it, insertion.learningStart, result.raw, pkg, insertion::readForLearning) }
        }
        if (result.corrected && result.text != result.raw) {
            raw = result.raw; state = FloatingState.POLISHED
            actionUntil = SystemClock.elapsedRealtime() + UNDO_MS
            handler.removeCallbacks(undoExpiry); handler.postDelayed(undoExpiry, UNDO_MS)
        } else {
            target?.forget(); target = null; state = FloatingState.INSERTED
            handler.postDelayed(insertedDone, 1200)
        }
    }
    /** Never lose a final (#167): words that can't go in the field wait in the panel, for Copy or the Scratchpad. */
    private fun keep(text: String, into: FloatingState, reason: DictationStatus? = null) {
        kept = text; state = into; status = reason
        handler.removeCallbacks(keptExpiry); handler.postDelayed(keptExpiry, KEPT_MS)
        if (surface != Surface.PANEL) expand() else render()
    }
    private fun ended() {
        partial = ""; stable = ""
        if (state == FloatingState.CONNECTING || state == FloatingState.LISTENING || state == FloatingState.FINISHING) state = FloatingState.IDLE
        when {
            state == FloatingState.IDLE && surface == Surface.HOLD -> collapse()
            state == FloatingState.INSERTED && surface == Surface.HOLD -> render()
            state != FloatingState.IDLE && state != FloatingState.INSERTED && surface != Surface.PANEL -> expand()
            else -> render()
        }
    }
    private fun fail(message: DictationStatus) {
        state = FloatingState.ERROR; status = message
        if (surface != Surface.PANEL) expand() else render()
    }
    private fun stop() {
        pendingStop = true; stream?.stop(); haptic(); render()
    }
    /** The field lost focus or the app changed mid-utterance: stop listening; the final then lands in Ready to copy. */
    private fun leaveField() {
        if (pendingStart && stream == null) { cancel(); return }
        if (surface == Surface.HOLD) { overlay?.leaveHold(); surface = Surface.BUBBLE }
        // The field is gone: the final can only wait in Ready to copy, never land in whatever has focus now.
        target?.forget(); target = null
        stop()
    }
    private fun cancel() {
        pendingStart = false; pendingStop = false
        val old = stream; stream = null; old?.cancel()
        client?.let(ChirpNetwork::dispose); client = null
        stopForeground(STOP_FOREGROUND_REMOVE); stopSelf()
        forgetUndo(); target?.forget(); target = null
        partial = ""; stable = ""; polishing = false; level = 0.0
        if (state != FloatingState.READY_TO_COPY && state != FloatingState.ERROR) state = FloatingState.IDLE
        render()
    }
    private fun forgetUndo() {
        handler.removeCallbacks(undoExpiry); raw = null
        if (!dictating) { target?.forget(); target = null }
    }
    private fun clearKept() {
        handler.removeCallbacks(keptExpiry); kept = ""
        if (state == FloatingState.READY_TO_COPY || state == FloatingState.ERROR) { state = FloatingState.IDLE; status = null }
    }
    private fun useRaw() {
        val text = raw ?: return
        learning.watcher.cancel()
        committing = true
        val inserted = try { !locked() && target?.useRaw(text) == true } catch (_: RuntimeException) { false } finally { committing = false }
        forgetUndo()
        // The field moved on: the raw words still aren't lost.
        if (inserted) { historyId?.let { id -> HistoryIo.run { history.usedRaw(id) } }; collapse() } else keep(text, FloatingState.READY_TO_COPY)
    }
    /** Copy is always a tap, never automatic, and marked sensitive. */
    private fun copyKept() {
        val text = kept.takeIf { it.isNotBlank() } ?: return
        val clip = ClipData.newPlainText(getString(R.string.bubble_clip_label), text)
        clip.description.extras = PersistableBundle().apply {
            putBoolean(if (Build.VERSION.SDK_INT >= 33) ClipDescription.EXTRA_IS_SENSITIVE else "android.content.extra.IS_SENSITIVE", true)
        }
        getSystemService(ClipboardManager::class.java)?.setPrimaryClip(clip)
        Toast.makeText(this, getString(R.string.bubble_copied), Toast.LENGTH_SHORT).show()
        clearKept(); collapse()
    }
    private fun fix() {
        fun open(intent: Intent) { cancel(); clearKept(); collapse(); startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)) }
        fun setup(section: String) = open(Intent(this, SetupActivity::class.java).putExtra("section", section))
        when (status?.let(BubbleFix::forStatus)) {
            BubbleFix.PAIR -> setup("pair")
            BubbleFix.MICROPHONE -> open(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null)))
            BubbleFix.CHECK_AGAIN, BubbleFix.TRY_AGAIN -> { clearKept(); begin() }
            // Turning the VPN on leaves the panel ready to dictate again; otherwise Tailscale itself, then Chirp's network help.
            BubbleFix.TAILSCALE_ON -> if (tailscale().connect()) { clearKept(); render() } else { clearKept(); collapse(); if (!tailscale().open()) setup("network") }
            BubbleFix.TAILSCALE_OPEN -> { clearKept(); collapse(); if (!tailscale().open()) setup("network") }
            BubbleFix.TAILSCALE_SETUP -> setup("network")
            BubbleFix.QUICK_DICTATE -> {
                // #168's Quick dictate panel when this build has it, otherwise the Scratchpad.
                val quick = Intent().setClassName(this, "$packageName.QuickDictateActivity")
                open(if (packageManager.resolveActivity(quick, 0) != null) quick else ScratchpadActivity.intent(this))
            }
            BubbleFix.SETTINGS -> open(Intent(this, SetupActivity::class.java))
            null -> { clearKept(); collapse() }
        }
    }
    internal open fun createLearning() = EditLearning(this)
    protected open fun loadPairing(): Pairing? = store.pairing()
    internal open fun tailscale(): TailscaleControl = AndroidTailscale(this)
    internal open fun createCapture(frame: (ByteArray) -> Boolean, level: (Double) -> Unit, done: (DictationStatus?) -> Unit): Capture =
        captureForBuild(this, frame, level, done)
    internal open fun createTransport(client: okhttp3.OkHttpClient, pairing: Pairing, event: (ServerEvent) -> Unit, failure: () -> Unit): ImeTransport =
        StreamTransport(client, pairing, dispatch = { callback -> handler.post { callback() } }, event = event, failure = failure)
    private fun haptic() { if (store.haptics) overlay?.bubble?.performHapticFeedback(HapticFeedbackConstants.CONFIRM) }

    private var actionUntil: Long? = null
    private fun render() {
        val model = PanelModel(state, status,
            text = if (state == FloatingState.READY_TO_COPY || state == FloatingState.ERROR) kept else partial,
            stable = stable, polishing = polishing, copyMode = copyMode, level = level,
            retention = retained || store.health?.debugRetention == true)
        when (surface) {
            Surface.PANEL -> overlay?.panel?.let { panel ->
                val wasPolished = panel.countdown.isVisible
                panel.render(model, actionUntil)
                if (state == FloatingState.POLISHED && !wasPolished) panel.countdown.run(UNDO_MS)
                overlay?.placePanel()
            }
            Surface.HOLD -> overlay?.hold(
                when (state) {
                    FloatingState.CONNECTING -> getString(R.string.bubble_connecting)
                    FloatingState.LISTENING -> partial.ifEmpty { getString(R.string.panel_listening) }
                    FloatingState.FINISHING -> getString(if (polishing) R.string.panel_polishing else R.string.panel_finishing)
                    FloatingState.INSERTED -> getString(R.string.bubble_inserted)
                    else -> ""
                },
                when (state) {
                    FloatingState.LISTENING -> RippleView.Mode.LIVE
                    FloatingState.CONNECTING, FloatingState.FINISHING -> RippleView.Mode.STATIC
                    else -> RippleView.Mode.OFF
                }, level, touchable = !pendingStop)
            Surface.BUBBLE -> Unit
        }
    }
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        // A fold, unfold or rotation: the posture's own saved spot applies.
        if (surface == Surface.PANEL) overlay?.placePanel(area(focused)) else if (surface == Surface.BUBBLE) refresh()
    }
    override fun onInterrupt() {
        learning.watcher.cancel(); learningEditor = null
        cancel(); clearKept(); forgetUndo()
        focused = null; surface = Surface.BUBBLE; state = FloatingState.IDLE
        handler.removeCallbacks(insertedDone)
        overlay?.removeAll(); overlay = null
    }
    override fun onUnbind(intent: Intent?): Boolean { onInterrupt(); return super.onUnbind(intent) }
    override fun onDestroy() {
        onInterrupt(); unregisterReceiver(screen); handler.removeCallbacksAndMessages(null); super.onDestroy()
    }
    companion object {
        private const val START = "dev.chirp.android.START_DICTATION"
        private const val CANCEL = "dev.chirp.android.CANCEL_DICTATION"
        private const val CHANNEL = "dictation"
        internal const val UNDO_MS = 5000L
        internal const val KEPT_MS = 120_000L
    }
}
