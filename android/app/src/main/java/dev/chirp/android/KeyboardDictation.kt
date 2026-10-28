package dev.chirp.android

import android.Manifest
import android.content.pm.PackageManager
import android.inputmethodservice.InputMethodService
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.inputmethod.EditorInfo
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** Owns voice state, separate from HeliBoard's typing/composing state. All editor calls are main-thread. */
internal class KeyboardDictation(
    private val host: InputMethodService,
    private val captureFactory: ((ByteArray) -> Boolean, (Double) -> Unit, (DictationStatus?) -> Unit) -> Capture,
    private val transportFactory: (okhttp3.OkHttpClient, Pairing, (ServerEvent) -> Unit, () -> Unit) -> ImeTransport,
    private val prepare: () -> Unit,
    private val resync: (Int, Int) -> Unit,
    private val pairing: () -> Pairing? = { SettingsStore(host).pairing() },
    private val checkHealth: Boolean = true,
    private val history: HistoryRecorder? = null,
    private val started: () -> Unit = {},
    private val tailscale: TailscaleControl = AndroidTailscale(host),
    private val healthCheck: (okhttp3.Call) -> Health = ChirpNetwork::health,
    private val cues: Cues = Cues(host),
    private val policy: PrewarmPolicy = PrewarmPolicy(),
    private val fallback: PhoneFallback = PhoneFallback.android(host),
    private val learning: EditLearning = EditLearning(host),
) {
    private val handler = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val store = SettingsStore(host)
    private val client = ChirpNetwork.client(host)
    init { learning.eligible = { visible && !privateUtterance && DictationHistory.allowed(host.currentInputEditorInfo) } }
    private var learnedPayload = LearnedPayload()
    private var waitingForLearn = false
    private var stopBeforeLearn = false
    private val gesture = MicGesture()
    private var strip: KeyboardStrip? = null
    private var session: Utterance? = null
    private var warmed: ImeTransport? = null
    private var warmEvent: ((ServerEvent) -> Unit)? = null
    private var warmFailure: (() -> Unit)? = null
    private val warmExpiry = Runnable { closeWarm() }
    private fun closeWarm() {
        handler.removeCallbacks(warmExpiry)
        warmed?.close(immediate = true); warmed = null
        warmEvent = null; warmFailure = null
    }
    private fun prewarm(paired: Pairing) {
        if (active || warmed != null || !policy.shouldPrewarm(targetPackage)) return
        warmed = transportFactory(client, paired, { warmEvent?.invoke(it) }, {
            warmed?.failureKind?.takeIf { it.offline }?.let(::noteReach)
            warmed = null; warmFailure?.invoke()
        }).also { it.connect() }
        handler.postDelayed(warmExpiry, 30000)
    }
    private fun takeTransport(paired: Pairing, event: (ServerEvent) -> Unit, failure: () -> Unit): ImeTransport {
        handler.removeCallbacks(warmExpiry)
        val ready = warmed
        warmed = null
        return if (ready != null) { warmEvent = event; warmFailure = failure; ready }
        else transportFactory(client, paired, event, failure)
    }
    private var composing: ComposingSession? = null
    private val partialFrames = PartialFrames({ partial ->
        applying = true
        try { if (!moved) composing?.partial(partial) } finally { applying = false }
    })
    private var visible = false
    private var destroyed = false
    private var applying = false
    private var version = 0
    private var healthCall: okhttp3.Call? = null
    private var message: DictationStatus = StatusLine.IDLE
    private var text = ""
    private var undo = false
    private var actionUntil: Long? = null
    private var notice = false
    private var targetPackage: String? = null
    private var styleOverride: String? = null
    private var currentStyle = CorrectionProfile("default", "Default")
    private var retained = false
    private var selectionStart = -1
    private var selectionEnd = -1
    private var insertionStart = -1
    // The caret left the utterance: stop, stop touching the editor's caret, land the final where it was spoken.
    private var moved = false
    // Where our own commit left the caret when one segment of a long dictation hands over to the next.
    private var handoff: Pair<Int, Int>? = null
    private var pressAt = 0L
    private var firstPartial: Long? = null
    private var stopAt: Long? = null
    private var finalLatency: Long? = null
    private var privateUtterance = false
    private var historyInfo: EditorInfo? = null
    private var historyId: String? = null
    private var words = 0
    private val expiry = Runnable { forgetUndo(); notice = false; words = 0; message = StatusLine.IDLE; render() }
    // Tailscale is checked only for tailnet pairings, locally and without DNS. Ignoring or dismissing
    // the prompt keeps it away for this keyboard process until Tailscale is next seen connected.
    private var tailnet = false
    private var vpn = false
    private var tailscaleDismissed = false
    private var tailscaleWatch: AutoCloseable? = null
    private val tailscaleTimeout = Runnable {
        if (active || message != StatusLine.TAILSCALE_CONNECTING) return@Runnable
        if (tailscale.connected()) tailscaleChanged() else { notice = false; message = StatusLine.TAILSCALE_STALLED; render() }
    }
    // The last health/prewarm failure marks the Mac offline for 30 s: the mic shows it before the user speaks.
    private val offline = OfflineState()
    private var offlineDismissed = false
    private var checking = false
    private val offlineExpiry = Runnable { if (message == StatusLine.OFFLINE) message = StatusLine.IDLE; render() }
    private var secondsLeft: Int? = null
    private var spokenLeft: Int? = null
    // Phone recogniser: this utterance (and its notice) came from it; a Mac failure before anything was heard hands over to it.
    private var onPhone = false
    private var handover = false
    val active get() = session != null
    val ownsComposition get() = active || applying

    // The touch listener owns real presses; accessibility services reach the mic through the click listener below.
    @android.annotation.SuppressLint("ClickableViewAccessibility")
    fun attach(view: KeyboardStrip) {
        strip = view
        // Real touches are push-to-talk: press starts, a short tap keeps listening (tap again to stop), a hold stops on release.
        // Click stays for accessibility services, which activate the mic without touch events.
        view.mic.setOnClickListener { toggle() }
        view.mic.setOnTouchListener { v, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> { v.isPressed = true; touch(MotionEvent.ACTION_DOWN); true }
                MotionEvent.ACTION_UP -> { v.isPressed = false; touch(MotionEvent.ACTION_UP); true }
                MotionEvent.ACTION_CANCEL -> { v.isPressed = false; touch(MotionEvent.ACTION_CANCEL); true }
                else -> true
            }
        }
        // Options moved off the mic's long press to the ⋯ beside it; TalkBack also gets them as an action on the mic.
        view.options.setOnClickListener { if (!active) quickOptions() }
        androidx.core.view.ViewCompat.addAccessibilityAction(view.mic, host.getString(R.string.strip_options)) { _, _ -> if (!active) { quickOptions(); true } else false }
        view.status.setOnClickListener { val next = action(); if (next != null) openAction(next) else if (message == StatusLine.OFFLINE) start() }
        view.action.setOnClickListener { action()?.let(::openAction) }
        view.cancel.setOnClickListener {
            if (action()?.prompt == true) tailscaleDismissed = true
            if (message == StatusLine.OFFLINE) offlineDismissed = true
            handler.removeCallbacks(tailscaleTimeout); cancel(StatusLine.CANCELLED)
        }
        view.raw.setOnClickListener {
            val target = composing ?: return@setOnClickListener
            applying = true
            learning.watcher.cancel()
            val changed = try { target.useRaw(selectionStart, selectionEnd) } finally { applying = false }
            if (changed) {
                selectionStart = target.selectionStart; selectionEnd = target.selectionEnd
                historyId?.let { history?.usedRaw(it) }
                forgetUndo(); message = StatusLine.USED_RAW; handler.postDelayed(expiry, 5000); resync(selectionStart, selectionEnd)
            }
            render()
        }
        view.revert.setOnClickListener {
            val target = composing ?: return@setOnClickListener
            applying = true
            learning.watcher.cancel()
            val changed = try { target.undo(selectionStart, selectionEnd) } finally { applying = false }
            if (changed) { selectionStart = target.selectionStart; selectionEnd = target.selectionEnd; resync(selectionStart, selectionEnd) }
            forgetUndo(); showNotice(if (changed) StatusLine.REMOVED else StatusLine.NOTHING_TO_UNDO)
        }
        render()
    }
    private fun setup(section: String = "settings") {
        host.requestHideSelf(0)
        host.startActivity(android.content.Intent(host, SetupActivity::class.java)
            .putExtra("section", section).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK or
                android.content.Intent.FLAG_ACTIVITY_CLEAR_TOP or android.content.Intent.FLAG_ACTIVITY_SINGLE_TOP))
    }
    private fun action() = message.action
    private fun openAction(action: DictationAction) {
        when (action) {
            DictationAction.PAIR -> setup("pair")
            DictationAction.MICROPHONE -> host.startActivity(android.content.Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                android.net.Uri.fromParts("package", host.packageName, null)).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK))
            DictationAction.NETWORK, DictationAction.TAILSCALE_OPEN -> if (!tailscale.open()) setup("network")
            DictationAction.TAILSCALE_SETUP -> setup("network")
            // One tap asks Tailscale to connect with consent it already holds; it cannot grant VPN consent.
            DictationAction.TAILSCALE_ON -> if (tailscale.connect()) {
                handler.removeCallbacks(expiry); handler.removeCallbacks(tailscaleTimeout)
                message = StatusLine.TAILSCALE_CONNECTING; notice = true; render()
                handler.postDelayed(tailscaleTimeout, 10000)
            } else if (!tailscale.open()) setup("network")
        }
    }
    private fun tailscaleStatus(): DictationStatus? = when {
        !tailnet -> null
        !tailscale.installed() -> StatusLine.TAILSCALE_MISSING
        !tailscale.connected() -> StatusLine.TAILSCALE_OFF
        else -> null
    }
    private fun tailscaleMessage() = action()?.prompt == true || message == StatusLine.TAILSCALE_CONNECTING
    private fun promptTailscale() {
        if (active || undo || notice || tailscaleDismissed) return
        tailscaleStatus()?.let { message = it }
    }
    private fun tailscaleChanged() {
        if (!visible || destroyed) return
        val now = tailscale.connected()
        if (now) {
            handler.removeCallbacks(tailscaleTimeout); tailscaleDismissed = false
            if (tailscaleMessage()) showNotice(StatusLine.TAILSCALE_CONNECTED)
            if (!vpn) pairing()?.let { closeWarm(); reach(it) }
        } else if (vpn) { promptTailscale(); render() }
        vpn = now
    }
    private fun promptOffline() {
        if (!visible || active || undo || notice || offlineDismissed || !offline.active() || tailscaleStatus() != null) return
        message = StatusLine.OFFLINE
    }
    /** null or a kind that isn't about reachability means the Mac answered, so the offline mark is dropped. */
    private fun noteReach(kind: ConnectionFailure.Kind?) {
        if (kind?.offline == true) {
            offline.failed(kind)
            handler.removeCallbacks(offlineExpiry); handler.postDelayed(offlineExpiry, offline.remaining())
            promptOffline()
        }
        else {
            offline.reachable(); offlineDismissed = false; handler.removeCallbacks(offlineExpiry)
            if (message == StatusLine.OFFLINE) message = StatusLine.IDLE
        }
        render()
    }
    /** A mic tap while marked offline re-checks health for at most 3 s, then dictates or names the reason. A second tap skips the check. */
    private fun retry(paired: Pairing): Boolean {
        if (!offline.active()) return false
        if (checking) { checking = false; return false }
        checking = true; notice = true; message = StatusLine.CHECKING; render()
        reach(paired, quick = true) { kind ->
            if (!checking) return@reach
            checking = false
            if (kind == null) { notice = false; message = StatusLine.IDLE; start() } else showNotice(tailscaleStatus() ?: kind)
        }
        return true
    }
    private fun quickOptions() {
        val anchor = strip?.mic ?: return
        StripMenu(anchor).apply {
            if (store.health.cleanupAvailable()) {
                toggle(host.getString(R.string.options_cleanup), correctionLabel(store.health), store.correction) { store.correction = it }
                section(host.getString(R.string.options_style))
                val selected = styleOverride ?: store.style(targetPackage).id
                CleanupStyles.profiles(store.health).forEach { profile ->
                    radio(profile.name, host.getString(R.string.options_rewrites).takeIf { profile.rewrites }, selected == profile.id) { styleOverride = profile.id; currentStyle = profile; render() }
                }
            } else note(host.getString(R.string.options_cleanup_off))
            section(host.getString(R.string.options_chirp))
            item(R.drawable.ic_settings, host.getString(R.string.options_settings)) { setup() }
            show()
        }
    }
    fun touch(action: Int) {
        if (session?.stopping == true) return
        val command = when (action) {
            MotionEvent.ACTION_DOWN -> gesture.down(SystemClock.uptimeMillis(), active)
            MotionEvent.ACTION_UP -> gesture.up(SystemClock.uptimeMillis())
            MotionEvent.ACTION_CANCEL -> gesture.cancel()
            else -> MicGesture.Action.NONE
        }
        when (command) {
            MicGesture.Action.START -> start()
            MicGesture.Action.STOP -> if (active) stop()
            MicGesture.Action.CANCEL -> cancel(StatusLine.CANCELLED)
            MicGesture.Action.NONE -> Unit
        }
    }
    fun toggle() { if (active) stop() else start() }
    /** Hardware-keyboard keys; true when the key was ours. Without a shown input view the host reveals the strip first. */
    fun hardware(action: HardwareShortcut.Action): Boolean = when (action) {
        HardwareShortcut.Action.TOGGLE -> {
            if (host.currentInputEditorInfo?.isPasswordField() == true || destroyed) false
            else { if (!visible) shown(); if (session?.stopping != true) toggle(); true }
        }
        HardwareShortcut.Action.CANCEL -> if (active) { cancel(StatusLine.CANCELLED); true } else false
        HardwareShortcut.Action.NONE -> false
    }
    fun input(info: EditorInfo?, restarting: Boolean) {
        learning.watcher.finish(sample = false)
        // HeliBoard owns view recreation; a real editor restart invalidates this utterance.
        if (active || undo) cancel()
        targetPackage = info?.packageName; styleOverride = null
        selectionStart = info?.initialSelStart ?: -1
        selectionEnd = info?.initialSelEnd ?: -1
    }
    fun shown() {
        if (destroyed) return
        visible = true
        val paired = pairing()
        tailnet = paired != null && TailscaleControl.routes(paired.base)
        if (tailnet) {
            vpn = tailscale.connected()
            tailscaleWatch?.close(); tailscaleWatch = tailscale.watch(::tailscaleChanged)
            promptTailscale()
        }
        promptOffline()
        render()
        if (paired != null) { if (policy.healthDue()) reach(paired) else prewarm(paired) }
    }
    private fun reach(paired: Pairing, quick: Boolean = false, then: ((ConnectionFailure.Kind?) -> Unit)? = null) {
        prewarm(paired)
        if (!checkHealth) { if (then != null) { noteReach(null); then(null) }; return }
        val id = ++version
        val call = ChirpNetwork.healthCall(client, paired)
        if (quick) call.timeout().timeout(3, java.util.concurrent.TimeUnit.SECONDS)
        ChirpNetwork.cancel(healthCall); healthCall = call
        scope.launch {
            try {
                val health = withContext(Dispatchers.IO) { healthCheck(call) }
                if (!visible || destroyed || version != id) return@launch
                healthCall = null; noteReach(null)
                if (tailscaleMessage()) { handler.removeCallbacks(tailscaleTimeout); notice = false; message = StatusLine.IDLE }
                store.health = health; retained = health.debugRetention; render()
                then?.invoke(null)
            } catch (e: Exception) {
                if (version != id || !visible || destroyed) return@launch
                healthCall = null; policy.healthFailed()
                val kind = ConnectionFailure.classify(e)
                noteReach(kind); then?.invoke(kind.takeIf { it.offline || it == ConnectionFailure.Kind.TLS })
            }
        }
    }
    private fun start(phone: Boolean = false) {
        if (!visible || destroyed || active) return
        if (ContextCompat.checkSelfPermission(host, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            showNotice(StatusLine.ALLOW_MICROPHONE); return
        }
        val info = host.currentInputEditorInfo ?: return
        if (info.isPasswordField()) {
            showNotice(StatusLine.PASSWORD_FIELD); return
        }
        val paired = pairing() ?: run { showNotice(StatusLine.NOT_PAIRED); return }
        onPhone = phone || fallback.usable() && (offline.active() || tailscaleStatus() != null)
        if (!onPhone && retry(paired)) return
        checking = false
        val connection = host.currentInputConnection ?: return
        learning.watcher.finish()
        forgetUndo(); notice = false; words = 0; started(); prepare(); policy.dictated(targetPackage)
        privateUtterance = PrivateSession.enabled
        historyInfo = info; historyId = null; learnedPayload = LearnedPayload()
        currentStyle = CleanupStyles.profiles(store.health).firstOrNull { it.id == styleOverride } ?: store.style(targetPackage)
        insertionStart = minOf(selectionStart, selectionEnd).takeIf { it >= 0 } ?: minOf(info.initialSelStart, info.initialSelEnd)
        moved = false; handoff = null
        composing = compose(connection)
        secondsLeft = null; spokenLeft = null
        text = ""; pressAt = SystemClock.elapsedRealtime(); firstPartial = null; stopAt = null; finalLatency = null
        if (onPhone) { listenOnPhone(if (phone) StatusLine.PHONE_HANDOVER else StatusLine.PHONE_LISTENING); return }
        var timer: SessionTimer? = null
        val stream = RollingDictation(
            deadlines = store.health?.operationDeadlines ?: OperationDeadlines(),
            transportFactory = { event, failed -> val warm = warmed != null; takeTransport(paired, event, failed).also { timer?.attach(it, warm) } },
            captureFactory = captureFactory,
            changed = { status, partial ->
                // The user just tried to dictate, so a dismissed Tailscale prompt may return as the reason.
                val kind = status as? ConnectionFailure.Kind
                if (kind?.offline == true) noteReach(kind)
                handover = fallback.handsOver(kind, moved)
                message = if (kind != null) tailscaleStatus() ?: status else status
                if (status.error) cue(Cue.ERROR)
                if (partial != null) {
                    if (firstPartial == null) firstPartial = SystemClock.elapsedRealtime() - pressAt
                    text = partial.text
                    partialFrames.offer(partial)
                }
                render()
            },
            level = { strip?.level(it) },
            retention = {
                ++version // a late health response must not overwrite Ready's retention flag
                noteReach(null); retained = it; store.health = store.health?.copy(debugRetention = it); render()
            },
            final = { land(it) },
            kept = { heard, reason -> land(ServerEvent.Final(heard, heard, false), reason) },
            correcting = { event ->
                partialFrames.clear()
                text = event.raw
                currentStyle = CleanupStyles.profiles(store.health).firstOrNull { it.id == event.profile } ?: currentStyle
                applying = true
                try { if (!moved) composing?.partial(ServerEvent.Partial(event.seq, event.raw, "")) } finally { applying = false }
            },
            pauseSeconds = store.autoStopSeconds, countdown = ::countdown,
            timing = { SessionTimer(TimingLog(host), { TimingNetworks.current(host) }).also { timer = it } },
            next = { nextSegment(connection) },
            ended = {
                session = null; secondsLeft = null; spokenLeft = null
                warmEvent = null; warmFailure = null
                if (!notice && visible) { notice = true; handler.postDelayed(expiry, 5000) }
                if (!undo) { composing?.cancel(awayStart, selectionEnd); composing = null }
                text = ""; resync(selectionStart, selectionEnd)
                ChirpNetwork.release(client); render()
                if (handover) handler.post { if (handover) { handover = false; start(phone = true) } }
            },
        )
        session = stream
        waitingForLearn = true; stopBeforeLearn = false
        learning.prepare(targetPackage, !privateUtterance && DictationHistory.allowed(info)) { payload ->
            if (session === stream && visible && !destroyed) {
                waitingForLearn = false; learnedPayload = payload
                stream.start(store.correction && store.health.cleanupAvailable(), currentStyle.id,
                    instructions = "", prompt = store.promptEdits[currentStyle.id], learned = payload)
                if (stopBeforeLearn) stream.stop()
            }
        }
        haptic(); cue(Cue.START)
    }
    /** One utterance on the phone's own recogniser while the Mac can't be reached: raw text, never cleaned, history as usual. */
    private fun listenOnPhone(status: DictationStatus) {
        val phone = fallback.session(changed = { value, partial ->
            message = value
            if (value.error) cue(Cue.ERROR)
            if (partial != null) { if (firstPartial == null) firstPartial = SystemClock.elapsedRealtime() - pressAt; text = partial.text; partialFrames.offer(partial) }
            render()
        }, level = { strip?.level(it) }, final = { land(it) }, kept = { heard, reason -> land(ServerEvent.Final(heard, heard, false), reason) }, ended = {
            session = null
            if (!notice && visible) { notice = true; handler.postDelayed(expiry, 5000) }
            if (!undo) { composing?.cancel(awayStart, selectionEnd); composing = null }
            text = ""; resync(selectionStart, selectionEnd); render()
        })
        session = phone; phone.start(status, store.autoStopSeconds)
        haptic(); cue(Cue.START)
    }
    private val awayStart get() = if (moved) selectionStart else -1
    private fun compose(connection: android.view.inputmethod.InputConnection) = ComposingSession(connection, insertionStart) { value ->
        android.text.SpannableString(value).apply {
            setSpan(android.text.style.UnderlineSpan(), 0, length, android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
            val ink = VoicePalette.of(host).ink and 0x00ffffff or 0xbb000000.toInt()
            setSpan(android.text.style.ForegroundColorSpan(ink), 0, length, android.text.Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
        }
    }.also { it.shapeFinal(store.spokenCommands) }
    /** A long dictation's segment landed (or came back empty): the next one composes right after it. */
    private fun nextSegment(connection: android.view.inputmethod.InputConnection) {
        partialFrames.clear()
        val landed = undo || composing == null
        if (!landed) { applying = true; try { composing?.cancel(awayStart, selectionEnd) } finally { applying = false } }
        if (landed) insertionStart = minOf(selectionStart, selectionEnd)
        handoff = insertionStart to (if (landed) maxOf(selectionStart, selectionEnd) else insertionStart)
        forgetUndo(); notice = false; text = ""; strip?.nextSegment()
        composing = compose(host.currentInputConnection ?: connection)
    }
    /** Commits a final, or what was heard before a failure ([reason]), and offers Undo for five seconds. */
    private fun land(received: ServerEvent.Final, reason: DictationStatus? = null) {
        val result = received.copy(text = if (!privateUtterance && LearnedStore(host).allowed && DictationHistory.allowed(host.currentInputEditorInfo)) learnedPayload.apply(received.text) else received.text)
        partialFrames.clear()
        val target = composing
        applying = true
        val inserted = try { target?.final(result, awayStart, selectionEnd) == true } finally { applying = false }
        if (inserted && target != null && target.selectionStart >= 0) { selectionStart = target.selectionStart; selectionEnd = target.selectionEnd }
        // Only after the last segment of a long dictation, never after a kept/partial result or once the caret left.
        val sent = inserted && reason == null && !moved && session?.landingLast != false && pressEnter(result.text)
        // A long dictation announces its words once, after the last segment, and stays quiet between segments.
        notice = inserted; words = if (inserted && reason == null) words + result.text.trim().split(Regex("\\s+")).size else 0
        historyId = if (inserted && !privateUtterance) history?.record(result.text, result.raw.takeIf { result.corrected }, historyInfo, partial = reason != null) else null
        if (inserted && session?.landingLast != false) { haptic(); cue(Cue.INSERTED) }
        message = if (!inserted) reason ?: StatusLine.FIELD_UNAVAILABLE
            else if (reason != null) KeptStatus(reason)
            else (if (result.correctionError != null) StatusLine.KEPT_ORIGINAL else if (result.corrected) StatusLine.CLEANED else StatusLine.INSERTED)
                .let { if (sent) SentStatus(it) else it }
        if (inserted && !sent && reason == null && !privateUtterance && target != null) {
            val value = target.committedText
            val connection = host.currentInputConnection
            if (value != null && connection != null && target.spanEnd >= value.length) {
                learning.watch(value, target.spanEnd - value.length, result.raw, targetPackage) {
                    if (host.currentInputConnection === connection) connection.learningText() else null
                }
            }
        }
        text = ""; finalLatency = stopAt?.let { SystemClock.elapsedRealtime() - it }
        undo = inserted && !sent && (target?.spanEnd ?: -1) >= 0
        actionUntil = SystemClock.elapsedRealtime() + 5000
        if (notice) handler.postDelayed(expiry, 5000)
        if (!undo) { composing?.forgetUndo(); composing = null }
    }
    /** "Press Send after dictating": the field's Send/Go/Done or Enter, once the text is in. False when not asked for or refused. */
    private fun pressEnter(landed: String): Boolean {
        val mode = store.autoEnter
        if (mode == AutoEnterMode.OFF || landed.isBlank()) return false
        val press = AutoEnter.press(host.currentInputEditorInfo, mode, store.appStyles[targetPackage] == "chat") ?: return false
        return AutoEnter.send(host.currentInputConnection, press)
    }
    /** Reinserts a history entry through the same boundary/selection path as a dictated final. */
    fun insertText(value: String): Boolean {
        learning.watcher.cancel()
        if (destroyed || value.isBlank()) return false
        if (active || undo) cancel()
        val connection = host.currentInputConnection ?: return false
        val info = host.currentInputEditorInfo
        prepare()
        val anchor = minOf(selectionStart, selectionEnd).takeIf { it >= 0 } ?: info?.let { minOf(it.initialSelStart, it.initialSelEnd) } ?: -1
        val insertion = ComposingSession(connection, anchor)
        applying = true
        val inserted = try { insertion.final(ServerEvent.Final(value, value, false)) } finally { applying = false }
        if (inserted && anchor >= 0) { selectionStart = insertion.selectionStart; selectionEnd = insertion.selectionEnd }
        resync(selectionStart, selectionEnd)
        if (inserted) haptic() else showNotice(StatusLine.FIELD_UNAVAILABLE)
        return inserted
    }
    private fun countdown(left: Int) {
        if (secondsLeft == null && store.haptics) strip?.mic?.performHapticFeedback(HapticFeedbackConstants.CLOCK_TICK)
        secondsLeft = left
        // The status is a live region: speak the count only at a few marks, not every second.
        if (left in SPOKEN_MARKS) spokenLeft = left
        render()
    }
    private fun stop() { stopAt = SystemClock.elapsedRealtime(); if (waitingForLearn) stopBeforeLearn = true else session?.stop(); haptic(); cue(Cue.STOP); render() }
    fun beforeEdit() {
        if (active || undo) cancel()
        else if (message == StatusLine.OFFLINE) { offlineDismissed = true; message = StatusLine.IDLE; render() }
        else if (tailscaleMessage()) {
            // Typing past the prompt means "not now": give the suggestion row back.
            tailscaleDismissed = true; handler.removeCallbacks(tailscaleTimeout)
            notice = false; message = StatusLine.IDLE; render()
        }
    }
    fun selection(oldStart: Int, oldEnd: Int, start: Int, end: Int, composingStart: Int, composingEnd: Int) {
        selectionStart = start; selectionEnd = end
        if (!applying && !active) learning.watcher.sample()
        if (applying) return
        if (active) {
            if (composingStart >= 0 && start == composingEnd && end == composingEnd) { insertionStart = composingStart; handoff = null }
            else if ((start != oldStart || end != oldEnd) && handoff != (start to end)) moveAway()
        } else if (undo && (start != composing?.selectionStart || end != composing?.selectionEnd)) {
            // forgetUndo cancels the expiry; keep the "cleaned" notice from pinning the row open.
            forgetUndo(); if (notice) handler.postDelayed(expiry, 5000); render()
        }
    }
    private fun moveAway() {
        moved = true; gesture.cancel(); partialFrames.clear()
        if (session?.stopping != true) { stopAt = SystemClock.elapsedRealtime(); session?.stop() }
        render()
    }
    fun cancel(status: DictationStatus = StatusLine.IDLE) {
        gesture.cancel(); partialFrames.clear(); handover = false
        // Clear editor composition before notifying HeliBoard that it can resume typing.
        applying = true
        try { composing?.cancel(awayStart, selectionEnd) } finally { applying = false }
        composing = null; forgetUndo()
        val old = session; session = null; old?.cancel()
        notice = false; words = 0; message = status; text = ""; render()
    }
    private fun forgetUndo() { actionUntil = null; handler.removeCallbacks(expiry); undo = false; composing?.forgetUndo(); if (!active) composing = null }
    fun hidden() {
        learning.watcher.finish(sample = false)
        visible = false; ++version; checking = false; ChirpNetwork.cancel(healthCall); healthCall = null
        tailscaleWatch?.close(); tailscaleWatch = null; handler.removeCallbacks(tailscaleTimeout)
        closeWarm(); cancel(); ChirpNetwork.release(client, cancel = true)
    }
    fun destroy() {
        destroyed = true; hidden(); scope.cancel(); handler.removeCallbacksAndMessages(null)
        strip = null; ChirpNetwork.dispose(client)
    }
    private fun showNotice(value: DictationStatus) {
        message = value; notice = true; words = 0; onPhone = false
        if (value.error) cue(Cue.ERROR)
        handler.removeCallbacks(expiry); handler.postDelayed(expiry, 5000); render()
    }
    private fun cue(cue: Cue) { if (store.soundCues) cues.play(cue) }
    private fun haptic() { if (store.haptics) strip?.mic?.performHapticFeedback(HapticFeedbackConstants.CONFIRM) }
    // One spoken result per final: the status live region is silent while listening and reads this once.
    private fun announcement(raw: Boolean) = when {
        active || words == 0 -> null
        raw -> host.getString(R.string.status_polished_spoken)
        notice -> host.resources.getQuantityString(R.plurals.status_inserted_words, words, words)
        else -> null
    }
    private fun render() {
        val res = host.resources
        val left = secondsLeft?.takeIf { active && session?.stopping != true }
        // The countdown and the debug timings follow whichever form of the line the strip shows.
        val decorate = { line: String ->
            val shown = left?.let { res.getString(R.string.status_seconds_left, line, it) } ?: line
            if (store.debugOverlay) res.getString(R.string.status_debug_timings, shown, firstPartial?.toString() ?: "—", finalLatency?.toString() ?: "—") else shown
        }
        val line = message.resolve(res)
        val raw = undo && composing?.rawAvailable == true
        strip?.show(message, "", active, session?.stopping == true, raw, retained || store.health?.debugRetention == true,
            actionUntil = actionUntil, polishing = session?.polishing == true, style = currentStyle.name, notice = notice, undoable = undo, offline = offline.active(), countdown = left != null,
            phone = fallback.disclosure(res).takeIf { onPhone && (active || notice) }, decorate = decorate)
        strip?.status?.isClickable = action() != null || message == StatusLine.OFFLINE
        val disclosure = if (retained || store.health?.debugRetention == true) res.getString(R.string.strip_debug_retention_spoken) else ""
        strip?.status?.contentDescription = disclosure + (action()?.let { res.getString(R.string.status_with_action_spoken, line, res.getString(it.label)) }
            ?: if (message == StatusLine.OFFLINE) res.getString(R.string.status_offline_description)
            else announcement(raw) ?: if (left != null) spokenLeft?.let { res.getString(R.string.status_seconds_left, line, it) } ?: line else decorate(line))
    }
    private companion object {
        val SPOKEN_MARKS = setOf(15, 10, 5, 3, 2, 1)
    }
}
