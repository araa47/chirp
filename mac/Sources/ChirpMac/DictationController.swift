import AppKit
import Carbon.HIToolbox
import ChirpCore
import ChirpUI

/// Glue between the pure state machine and the system: capture, socket, HUD, insertion.
@MainActor
final class DictationController {
    private(set) var machine = DictationMachine()
    private(set) var health: Health?
    /// The styles with their default prompts: live from the server, else the last-known copy. Settings shows them.
    private(set) var styleCatalog = StyleCatalog.cached(settings)
    private(set) var healthError: String?
    var onChange: (() -> Void)?
    /// Called on every press of the dictation hotkey (the setup window's "Try it" step listens for it).
    var onHotkeyPressed: (() -> Void)?
    /// Live Notes is recording and holds the engine: a new dictation shows a toast instead of starting.
    var isBlocked: () -> Bool = { false }
    /// Asked before each press reaches the machine: true when Notes took it (its window is frontmost).
    var routeToNotes: (_ dictationActive: Bool) -> Bool = { _ in false }
    static let blockedMessage = "Notes is recording — stop it to dictate"

    let hud = HUDController()
    private let mic = DictationMic(capture: AudioCapture(engine: SystemCaptureEngine(pickedDevice: { InputDevice.pickedID(uid: settings.inputDeviceUID) })))
    private let inserter = TextInserter(env: SystemInsertion.environment(), pasteboard: SystemPasteboard())
    private let autoEnter = AutoEnterSender(env: SystemInsertion.autoEnterEnvironment())
    /// ⇧ was held when this dictation stopped: no Return after it (unless the hotkey itself uses ⇧).
    private var autoEnterSkipped = false
    /// Dictation history (on by default): every committed dictation is kept here, sealed, on this Mac.
    var history: DictationHistory?
    /// The app that was frontmost when this dictation started (its history entry names it).
    private var target: (bundleID: String?, name: String?) = (nil, nil)
    /// When the microphone opened, and the seconds it stayed open.
    private var captureStartedAt: ContinuousClock.Instant?
    /// When this dictation started (uptime), for the microphone latency in the log.
    private var startedAt: TimeInterval = 0
    /// The press (uptime) that opened the microphone before any dictation started (`HotkeyGesture.opensMicOnPress`).
    private var preRollPress: TimeInterval?
    private var capturedSeconds: TimeInterval = 0
    /// The last dictation's history entry, so "Use raw" can record what is really in the field.
    private var lastHistoryID: UUID?
    /// Learn from my edits (on while history is on): watches the field after an insertion, and shapes the next `start`.
    var learning: EditLearning?

    let privateSession = PrivateSession()
    /// Once private at any point, this utterance stays private through insertion and expiry.
    private var privateDictation = false
    private var privacyTimer: Timer?
    private var lockObserver: NSObjectProtocol?

    init() {
        privateSession.onChange = { [weak self] in
            guard let self else { return }
            if self.privateSession.isActive {
                self.learning?.watcher.cancel()
                if self.machine.state.isActive { self.privateDictation = true }
            }
            self.hud.model.privateSession = self.privateSession.isActive || (self.machine.state.isActive && self.privateDictation)
            self.onChange?()
        }
        privacyTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.privateSession.expireIfNeeded() }
        }
        lockObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.privateSession.screenLocked() }
            }
    }

    private var session: RollingDictationSession?
    private var eventTask: Task<Void, Never>?
    private var epoch = 0
    private var pendingFinal: FinalResult?
    /// The raw transcript from `correcting`: what is inserted if clean-up fails. Never logged; cleared on every exit.
    private var polishingRaw: String?
    /// "Insert raw immediately": the raw insertion started when `correcting` arrived (nil outcome: cancelled first).
    private var rawInsertTask: Task<InsertionOutcome?, Never>?
    private var startOptions = StartOptions()
    /// The hotkey's presses for the current mode and shortcut; rebuilt whenever the hotkey is registered.
    private var gesture = HotkeyGesture()

    /// Legacy-server fallback; current servers advertise their effective budget.
    static let correctionTimeout: TimeInterval = 12
    private static let cancellable: [DictationState] = [.connecting, .listening, .finalizing, .correcting]

    static let dictateID: UInt32 = 1
    private static let escapeID: UInt32 = 2
    private static let rawID: UInt32 = 3

    /// The 5 s window after a cleaned insertion in which the Use raw hotkey (⌃⌥Z by default) and the menu offer it (the
    /// HUD is already gone).
    private(set) lazy var rawOffer = RawOffer(
        hotkey: { settings.useRawHotkey },
        register: { combo, take in HotKeyCenter.shared.register(id: Self.rawID, combo: combo, onDown: take) },
        unregister: { HotKeyCenter.shared.unregister(id: Self.rawID) },
        use: { [weak self] in self?.useRaw() },
        onChange: { [weak self] in self?.onChange?() })

    /// The menu's main switch. Every hotkey registration goes through it, so a paused Chirp stays unreachable.
    private(set) lazy var gate = PauseGate(
        register: { [weak self] in
            guard let self else { return false }
            let combo = settings.hotkey
            self.gesture = HotkeyGesture(mode: settings.activationMode, modifierOnly: combo.isModifierOnly,
                                         singleKey: combo.isSingleModifierKey)
            self.machine.mode = settings.activationMode
            return HotKeyCenter.shared.register(id: Self.dictateID, combo: combo,
                                                onDown: { [weak self] in self?.hotkeyDown() },
                                                onUp: { [weak self] in self?.hotkeyUp() },
                                                onChord: { [weak self] in self?.hotkeyChord() })
        },
        unregister: { HotKeyCenter.shared.unregister(id: Self.dictateID) },
        onChange: { [weak self] in self?.onChange?() })

    var isPaused: Bool { gate.isPaused }

    /// The shortcut recorder holds the hotkey released.
    private var hotkeySuspended = false

    /// (Re)registers the dictation hotkey from settings (nothing while paused).
    @discardableResult
    func registerHotkey() -> Bool {
        hotkeySuspended = false
        return gate.registerHotkey()
    }

    /// Releases the dictation hotkey while the shortcut recorder listens; `registerHotkey()` takes it back.
    func suspendHotkey() {
        hotkeySuspended = true
        gate.suspendHotkey()
    }

    /// A hotkey matched from the event tap cannot register before Accessibility is granted; try again once it is.
    func retryHotkeyIfNeeded() {
        guard !gate.isPaused, !hotkeySuspended, !gate.hotkeyRegistered, settings.hotkey.needsEventTap,
              Permissions.accessibilityGranted else { return }
        registerHotkey()
    }

    /// The menu's switch: pausing ends a dictation under way and releases the hotkeys; resuming registers the hotkey again.
    func setRunning(_ running: Bool) {
        if !running {
            if Self.cancellable.contains(state) { escape() }
            rawOffer.close()
        }
        gate.setRunning(running)
    }

    var state: DictationState { machine.state }
    var debugRetention: Bool { hud.model.debugRetention || (health?.debugRetention ?? false) }

    // MARK: input from the hotkeys

    func hotkeyDown() {
        let now = ProcessInfo.processInfo.systemUptime
        if gesture.opensMicOnPress { openOnPress(at: now) }
        deliver(gesture.down(at: now))
        guard gesture.needsArmTimer else { dropPreRoll(); return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(HotkeyGesture.armDelay))
            guard let self else { return }
            self.deliver(self.gesture.armDue(pressedAt: now, at: ProcessInfo.processInfo.systemUptime))
            // Armed, a tap, or nothing (a chord, an early release, a key-up that never came): decided by now.
            self.dropPreRoll(of: now)
        }
    }
    func hotkeyUp() {
        deliver(gesture.up(at: ProcessInfo.processInfo.systemUptime))
        dropPreRoll()
    }
    func hotkeyChord() {
        deliver(gesture.chord())
        dropPreRoll()
    }

    /// Right ⌥ (one modifier key): open the microphone on the press, before the gesture knows whether it is a
    /// dictation, so its first words are not lost to `HotkeyGesture.armDelay`. The audio stays in `mic`, in memory and
    /// at most a second, and is sent only if this press starts a dictation (`begin`); otherwise `dropPreRoll` closes
    /// the microphone and drops it unsent.
    private func openOnPress(at t: TimeInterval) {
        guard !machine.state.isActive, !isBlocked(), Permissions.microphoneGranted, !mic.isOpen else { return }
        do {
            try mic.open()
            preRollPress = t
        } catch {
            mic.close()   // `begin` tries again and reports the failure
        }
    }

    /// Closes a microphone opened on a press (all of them, or only `press`'s) that has not become a dictation.
    private func dropPreRoll(of press: TimeInterval? = nil) {
        guard let opened = preRollPress, press == nil || press == opened else { return }
        preRollPress = nil
        if !machine.state.isActive { mic.close() }
    }
    func escape() { send(.escape) }

    private func deliver(_ events: [DictationEvent]) {
        for event in events {
            if case .hotkeyDown = event {
                if routeToNotes(machine.state.isActive) { return }
                onHotkeyPressed?()
                if showBlockedToast() { return }
            }
            send(event)
        }
    }

    /// "Start/Stop dictation" in the menu: starts a dictation or finishes the one under way, in either mode.
    func toggleDictation() {
        guard !isPaused, !showBlockedToast() else { return }
        send(.toggle)
    }

    /// While Notes records, an idle dictation does not start: a short HUD toast says why and no event is sent.
    private func showBlockedToast() -> Bool {
        guard !machine.state.isActive, isBlocked() else { return false }
        hud.cancelHide()
        hud.model.reset()
        hud.model.status = Self.blockedMessage
        hud.model.indicator = .warning
        hud.model.silence()
        hud.show()
        hud.announce(Self.blockedMessage)
        hud.hide(after: 1.5)
        return true
    }

    // MARK: health

    func refreshHealth() async {
        let config = settings.serverConfig()
        do {
            health = try await config.fetchHealth()
            healthError = nil
            styleCatalog = await StyleCatalog.refresh(settings) { try await config.fetchProfiles() }
        } catch {
            health = nil
            healthError = "Server unreachable at \(config.host)"
            styleCatalog = .cached(settings)
        }
        onChange?()
    }

    // MARK: state machine plumbing

    private func send(_ event: DictationEvent) {
        let before = machine.state
        let effects = machine.handle(event)
        if machine.state != before {

            chirpLog.info("state \(String(describing: before), privacy: .public) -> \(String(describing: self.machine.state), privacy: .public)")
            // Esc is only claimed while a dictation is active, so it is untouched the rest of the time.
            if Self.cancellable.contains(machine.state) {
                HotKeyCenter.shared.register(id: Self.escapeID, combo: .escape) { [weak self] in self?.escape() }
            } else {
                HotKeyCenter.shared.unregister(id: Self.escapeID)
            }
            renderStatus()
            onChange?()
        }
        for effect in effects { run(effect) }
        // After the effects: the stop cue plays once capture has ended, and the start cue as the microphone opens (see
        // begin). The microphone never waits for the cue; its window is zeroed in what is sent.
        if let cue = SoundCue.cue(from: before, to: machine.state, enabled: settings.soundsEnabled) {
            if cue == .start { mic.excludeCue(at: ProcessInfo.processInfo.systemUptime, length: Sounds.startCueWindow()) }
            Sounds.play(cue)
        }
    }

    private func renderStatus() {
        switch machine.state {
        case .idle, .inserting: break
        case .connecting: hud.model.status = HUDStatus.connecting
        case .listening: hud.model.status = HUDStatus.listening; hud.announce(HUDStatus.listening)
        case .finalizing: hud.model.status = HUDStatus.finishing
        case .correcting: hud.model.status = HUDStatus.polishing; hud.model.indicator = .sparkle
        case .error(let m): hud.model.status = m; hud.model.isError = true; hud.model.indicator = .warning
        }
    }

    private func run(_ effect: DictationEffect) {
        switch effect {
        case .start: begin()
        case .finalize: finalize()
        case .cancel: teardown(cancelServer: true); hud.hide(); inserter.forgetUndo()
        case .abort(let message):
            teardown(cancelServer: true)
            inserter.forgetUndo()
            hud.model.status = message
            hud.model.isError = true
            hud.model.indicator = .warning
            hud.model.silence()
            hud.show()
            hud.announce(message)
            hud.hide(after: 3.5)
        case .insert: insert()
        }
    }

    private func begin() {
        epoch += 1
        let myEpoch = epoch
        pendingFinal = nil
        polishingRaw = nil
        rawInsertTask = nil
        autoEnterSkipped = false
        inserter.forgetUndo()
        rawOffer.close()
        hud.cancelHide()
        hud.model.reset()
        hud.model.status = HUDStatus.connecting
        hud.model.debugRetention = health?.debugRetention ?? false
        // The frontmost app picks the style now, before the HUD or any permission prompt can change focus.
        let frontmost = NSWorkspace.shared.frontmostApplication
        target = (frontmost?.bundleIdentifier, frontmost?.localizedName)
        captureStartedAt = nil
        capturedSeconds = 0
        privateDictation = privateSession.isActive
        hud.model.privateSession = privateDictation
        hud.model.duration = "0:00 / 10:00"
        lastHistoryID = nil
        // A new dictation ends the last one's edit window (what the user changed so far is learned).
        if privateDictation { learning?.watcher.cancel() } else { learning?.watcher.finish() }
        startOptions = settings.startOptions(frontmostBundleID: frontmost?.bundleIdentifier,
                                             available: health?.correctionProfiles)
        startOptions.correction = settings.permitsCorrection(health: health)
        if !privateDictation, settings.learningEnabled, let learning, !Self.excludedFromHistory(target.bundleID) {
            startOptions.learned = learning.payload(for: target.bundleID)
        }
        hud.model.styleName = startOptions.correction ? CorrectionProfile.name(for: startOptions.correctionProfile, in: health) : nil
        hud.model.wordWaveform = startOptions.wordTimings
        hud.show()
        startedAt = ProcessInfo.processInfo.systemUptime
        preRollPress = nil   // a microphone opened on the press is this dictation's now
        chirpLog.info("microphone authorization=\(Permissions.microphone.rawValue, privacy: .public) accessibility=\(Permissions.accessibilityGranted, privacy: .public)")
        // With access granted the microphone opens now, before the start cue plays (see `send`): no task hop, no wait.
        // Audio from before the socket is ready queues in the stream session.
        if Permissions.microphoneGranted {
            startStreaming(epoch: myEpoch)
            return
        }
        Task {
            guard await Permissions.requestMicrophone() else {
                if epoch == myEpoch, machine.state.isActive {
                    Permissions.openSettings(.microphone)
                    send(.failed("Microphone access denied — enable it in System Settings"))
                }
                return
            }
            guard epoch == myEpoch, machine.state == .connecting || machine.state == .listening else { return }
            startStreaming(epoch: myEpoch)
        }
    }

    private func startStreaming(epoch myEpoch: Int) {
        let config = settings.serverConfig(), options = startOptions
        let session = RollingDictationSession(
            correctionTimeout: health?.operationTimeout(.dictation, fallback: Self.correctionTimeout) ?? Self.correctionTimeout,
            commands: settings.spokenCommands,
            makeStream: { StreamSession(config: config, options: options) })
        self.session = session
        let autoStop = machine.mode == .autoStop ? AutoStopDetector(silence: settings.autoStopSilence) : nil
        let sink = CaptureSink(session: session, autoStop: autoStop) { [weak self] level, elapsed in
            Task { @MainActor in
                guard let self, self.epoch == myEpoch else { return }
                self.hud.model.pushLevel(level.rms)
                self.hud.model.duration = Self.durationLabel(elapsed)
            }
        } onSilence: { [weak self] in
            Task { @MainActor in
                guard let self, self.epoch == myEpoch, self.machine.state.isActive else { return }
                self.send(.failed("No microphone signal"))
            }
        } onAutoStop: { [weak self] in
            Task { @MainActor in
                guard let self, self.epoch == myEpoch else { return }
                self.send(.silence)
            }
        } onLimit: { [weak self] in
            // The whole dictation, across ordered rolling sockets, is limited to ten minutes.
            Task { @MainActor in
                guard let self, self.epoch == myEpoch, self.machine.state == .listening else { return }
                chirpLog.info("dictation limit reached seconds=\(Int(CaptureSink.limitSeconds), privacy: .public)")
                self.send(.toggle)
            }
        }
        do { try mic.open() } catch {
            mic.close()
            // Called from `begin`, inside `send`: report the failure after it returns.
            let message = error is CaptureError ? "No microphone input device" : "Could not start the microphone"
            Task { @MainActor [weak self] in
                guard let self, self.epoch == myEpoch, self.machine.state.isActive else { return }
                self.send(.failed(message))
            }
            return
        }
        mic.attach(onFailure: { [weak self] in
            Task { @MainActor in
                guard let self, self.epoch == myEpoch, self.machine.state.isActive else { return }
                self.send(.failed("The microphone stopped — check the input device"))
            }
        }) { frame, muted in sink.handle(frame, muted: muted) }
        captureStartedAt = .now
        eventTask = Task { [weak self] in
            await session.open()
            for await event in session.events {
                guard let self, self.epoch == myEpoch else { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: StreamEvent) {
        switch event {
        case .message(.ready(_, _, let debug)):
            hud.model.debugRetention = debug
            send(.serverReady)
        case .message(.partial(_, let text, let stable, let words)):
            guard [.connecting, .listening, .finalizing].contains(machine.state) else { return }
            let (s, u) = splitPartial(text: text, stable: stable)
            hud.model.stable = s
            hud.model.unstable = u
            hud.model.showWords(text: text, words: words)
        case .message(.correcting(_, let raw, let profile, let words)):
            guard machine.state == .finalizing else { return }
            beginPolishing(raw: raw, profile: profile, words: words)
        case .message(.final(let f)):
            if machine.state == .listening || machine.state == .connecting { send(.toggle) }
            pendingFinal = f
            send(.finalReceived)
        case .message(.error(let code, let message)):
            if machine.state == .correcting { failCorrection(); return }
            send(.failed(Self.friendly(code: code, message: message)))
        case .message(.unknown): break
        case .closed(let reason):
            if machine.state == .correcting { failCorrection(); return }
            if [.connecting, .listening, .finalizing].contains(machine.state) {
                send(.failed(reason == "Utterance too long" ? Self.tooLong : reason ?? "Connection closed"))
            }
        }
    }

    /// `correcting` arrived: show the raw transcript at once, solid, with the polishing state and the style chip.
    private func beginPolishing(raw: String, profile: String, words: [WordTiming]?) {
        polishingRaw = raw
        hud.model.beginPolishing(raw: raw, style: profile.isEmpty ? hud.model.styleName ?? "" : CorrectionProfile.name(for: profile, in: health), words: words)
        send(.correctingReceived)
        hud.announce(HUDStatus.polishing)
        let myEpoch = epoch
        // "Insert raw immediately": only where the AX write can be replaced in place later; elsewhere the cleaned
        // text is inserted once, as usual.
        if settings.insertRawFirst, inserter.canReplaceInPlace() {
            rawInsertTask = Task { [weak self] in
                guard let self, self.epoch == myEpoch, self.machine.state == .correcting else { return nil }
                return await self.inserter.insert(raw, undoRaw: raw, undoWindow: TextInserter.swapWindow)
            }
        }
    }

    /// Clean-up timed out, errored or lost its socket: keep the raw transcript.
    private func failCorrection() {
        guard machine.state == .correcting else { return }
        pendingFinal = FinalResult(text: polishingRaw ?? "", corrected: false, correctionError: "timeout")
        send(.correctionFailed)
    }

    /// A server that rejected one rolling segment.
    static let tooLong = "This dictation segment was too long — try again"

    private static func durationLabel(_ seconds: TimeInterval) -> String {
        let total = min(Int(seconds), Int(RollingDictationSegmenter.maxTotal))
        return String(format: "%d:%02d / 10:00", total / 60, total % 60)
    }

    private static func friendly(code: String, message: String) -> String {
        switch code {
        case "auth": "Server rejected the token (check ~/.config/chirp/token)"
        case "busy": "Server is busy — try again"
        case "too_long": tooLong
        case "bad_audio": "Didn't catch that — try again"
        case "bad_request": "Clean-up prompt is too long"
        case "engine": "Speech engine hiccup — try again"
        default: message
        }
    }

    private func finalize() {
        autoEnterSkipped = NSEvent.modifierFlags.contains(.shift) && Int(settings.hotkey.modifiers) & shiftKey == 0
        stopCapture()
        hud.model.silence()
        guard let session else {
            pendingFinal = FinalResult(text: "")
            send(.finalReceived)
            return
        }
        Task { await session.stop() }
    }

    private func stopCapture() {
        // Timings only: how long after the dictation started the microphone opened (negative: it was already open from
        // the press) and when its first frame arrived.
        if let opened = mic.openedAt {
            let first = mic.firstFrameAt.map { String(Int((($0 - startedAt) * 1000).rounded())) } ?? "-"
            chirpLog.info("dictation mic open_ms=\(Int(((opened - self.startedAt) * 1000).rounded()), privacy: .public) first_frame_ms=\(first, privacy: .public)")
        }
        mic.close()
        if let start = captureStartedAt {
            let d = (ContinuousClock.now - start).components
            capturedSeconds = Double(d.seconds) + Double(d.attoseconds) / 1e18
            captureStartedAt = nil
        }
    }

    private func teardown(cancelServer: Bool) {
        epoch += 1   // invalidates every in-flight callback of the old session
        pendingFinal = nil
        polishingRaw = nil
        rawInsertTask = nil
        stopCapture()
        eventTask?.cancel()
        eventTask = nil
        if let s = session {
            Task { cancelServer ? await s.cancel() : await s.close() }
        }
        session = nil
    }

    // MARK: insertion

    private func insert() {
        // Consume the final: nothing but the inserter's short-lived undo state may outlive this insertion.
        guard let final = pendingFinal else { send(.insertionFinished); return }
        pendingFinal = nil
        polishingRaw = nil
        let rawFirst = rawInsertTask
        rawInsertTask = nil
        // What was learned applies to the text itself too, so it works with clean-up off or an older server.
        let text = startOptions.learned?.apply(to: final.text) ?? final.text
        let s = session
        session = nil
        eventTask?.cancel(); eventTask = nil
        Task { await s?.close() }
        guard !text.isEmpty else {
            hud.model.polishing = false
            hud.model.diff = nil
            hud.model.stable = ""
            hud.model.unstable = ""
            hud.model.status = HUDStatus.noSpeech
            hud.model.indicator = .none
            hud.announce(HUDStatus.noSpeech)
            hud.model.silence()
            hud.hide(after: 1.5)
            send(.insertionFinished)
            return
        }
        let myEpoch = epoch
        Task {
            guard self.epoch == myEpoch else { return }
            if let rawFirst, let early = await rawFirst.value {
                await replaceRaw(early, with: final, text: text)
            } else {
                // The cleaned text is shown with its changes highlighted, once, while it is inserted: never before.
                if final.canUseRaw, settings.showChangesAfterCleanup { hud.model.startChangeHighlight(raw: final.raw, cleaned: text) }
                else if !final.corrected, let words = final.words { hud.model.finishWords(text: text, words: words) }
                else { hud.model.settle(on: text) }
                hud.model.status = HUDStatus.inserting
                hud.model.indicator = .waveform
                let secure = SystemInsertion.focusedFieldIsSecure()
                let outcome = await inserter.insert(text, undoRaw: final.canUseRaw && settings.showRawAfterCleanup ? final.raw : nil)
                keep(outcome, final: final, text: text, secureField: secure)
                watchEdits(outcome, text: text, raw: final.raw, secureField: secure)
                let lingers = show(outcome, final: final)
                await pressReturn(after: outcome, hudLingers: lingers)
            }
            send(.insertionFinished)
        }
    }

    /// "Insert raw immediately" finished its raw insertion earlier; swap in the cleaned text when the AX insert was
    /// verified and the range still holds it, otherwise leave the raw text where it is.
    private func replaceRaw(_ early: InsertionOutcome, with final: FinalResult, text: String) async {
        var shown = final
        if early == .inserted(.ax), final.canUseRaw || final.text != final.raw {
            if settings.showChangesAfterCleanup { hud.model.startChangeHighlight(raw: final.raw, cleaned: text) }
            else { hud.model.settle(on: text) }
            if await inserter.replaceInserted(with: text) {
                let secure = SystemInsertion.focusedFieldIsSecure()
                keep(early, final: final, text: text, secureField: secure)
                watchEdits(early, text: text, raw: final.raw, secureField: secure)
                let lingers = show(early, final: final)
                await pressReturn(after: early, hudLingers: lingers)
                return
            }
            hud.model.settle(on: final.raw)
            shown = FinalResult(text: final.raw, corrected: false, correctionError: "replace")
        } else {
            inserter.forgetUndo()
            hud.model.settle(on: final.raw)
            if final.canUseRaw { shown = FinalResult(text: final.raw, corrected: false, correctionError: "replace") }
            else { shown.text = final.raw }
        }
        let secure = SystemInsertion.focusedFieldIsSecure()
        keep(early, final: shown, text: shown.text.trimmingCharacters(in: .whitespacesAndNewlines), secureField: secure)
        watchEdits(early, text: shown.text, raw: final.raw, secureField: secure)
        let lingers = show(early, final: shown)
        await pressReturn(after: early, hudLingers: lingers)
    }

    /// "Press Return after inserting": one Return once the text is in, then a small "↵ sent" on a HUD that is still up.
    /// A HUD already fading away is not brought back for it: the Return shows in the app.
    private func pressReturn(after outcome: InsertionOutcome, hudLingers: Bool) async {
        let mode = settings.autoEnter
        guard mode != .off else { return }
        let skipped = autoEnterSkipped
        guard await autoEnter.send(after: outcome, mode: mode, rules: settings.appStyles, skipped: skipped) else { return }
        guard hudLingers else { hud.announce("Return sent"); return }
        hud.model.status += HUDStatus.returnSent
        hud.show()
        hud.hide(after: 1.2)
        hud.announce(hud.model.status)
    }

    /// Shows the outcome, and returns whether the HUD stays up for it (false: it is already fading out).
    @discardableResult
    private func show(_ outcome: InsertionOutcome, final: FinalResult) -> Bool {
        let p = OutcomePresentation.of(outcome, final: final, offerRaw: settings.showRawAfterCleanup,
                                       showChanges: settings.showChangesAfterCleanup)
        hud.model.status = p.status
        hud.model.indicator = p.indicator
        hud.model.cleaned = p.cleaned
        hud.model.keptOriginal = p.keptOriginal
        hud.model.isError = p.isError
        hud.model.showUseRaw = p.showUseRaw
        hud.model.onUseRaw = p.showUseRaw ? { [weak self] in self?.useRaw() } : nil
        // A successful insertion fades the HUD at once (and never brings one up just to fade it, as Insert Again would).
        if p.linger > 0 { hud.show(); hud.hide(after: p.linger) } else { hud.hide() }
        hud.announce(p.status)
        if p.offersRawOutsideHUD, inserter.canUseRaw, !isPaused { rawOffer.open(avoiding: settings.hotkey) }
        // How each dictation ended and how long the HUD stays for it: never the text.
        chirpLog.info("dictation outcome=\(outcome.logName, privacy: .public) cleaned=\(p.cleaned, privacy: .public) kept=\(p.keptOriginal, privacy: .public) hud_linger=\(p.linger, privacy: .public)")
        return p.linger > 0
    }

    /// Replace the inserted correction with the raw transcript, in place for a verified AX insertion and otherwise
    /// by copying it; the inserter refuses once the undo window has expired or the target changed.
    private func useRaw() {
        guard !machine.state.isActive else { return }
        hud.model.showUseRaw = false
        hud.model.cleaned = false
        hud.model.stable = ""
        Task {
            // Chirp is about to change the field itself: that is not the user's edit.
            learning?.watcher.cancel()
            guard let outcome = await inserter.useRaw() else { return }
            hud.model.isError = outcome == .refusedSecure
            hud.show()
            if outcome != .refusedSecure, let id = lastHistoryID, let history { Task { await history.usedRaw(id) } }
            switch outcome {
            case .inserted: hud.model.status = "Inserted raw"; hud.model.indicator = .success
            case .refusedSecure: hud.model.status = "Secure field — unchanged"; hud.model.indicator = .warning
            default: hud.model.status = "Copied raw — ⌘V"; hud.model.indicator = .clipboard
            }
            hud.announce(hud.model.status)
            hud.hide(after: 1.5)
        }
    }
}

// MARK: dictation history

extension DictationController {
    /// Keeps a committed dictation in the history when it is on and the policy allows (never a secure field, an
    /// excluded app, a refused insertion or an empty text). Nothing about it is logged.
    fileprivate func keep(_ outcome: InsertionOutcome, final: FinalResult, text: String, secureField: Bool) {
        lastHistoryID = nil
        guard !privateDictation, !privateSession.isActive, let history, HistoryPolicy.shouldRecord(enabled: settings.historyEnabled, outcome: outcome, secureField: secureField,
                                                      bundleID: target.bundleID, excluded: settings.historyExcludedApps, text: text)
        else { return }
        let raw = final.corrected ? final.raw.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        let audio = final.timings?.audio.map { $0 / 1000 } ?? capturedSeconds
        let entry = DictationEntry(date: Date(), text: text, raw: raw, bundleID: target.bundleID, appName: target.name,
                                 duration: audio, style: final.corrected ? startOptions.correctionProfile : nil)
        lastHistoryID = entry.id
        Task { await history.record(entry) }
    }

    static func excludedFromHistory(_ bundleID: String?) -> Bool {
        bundleID.map(settings.historyExcludedApps.contains) ?? false
    }

    /// Learn from my edits: after an insertion, watch that field for the user's fixes. A verified AX write says where it
    /// went; a paste (Chromium, Electron) or an unconfirmed write is looked for in the field once the app applies it.
    /// Never a secure field, an excluded app, or while learning (or history) is off. The log names the gate, never the text.
    fileprivate func watchEdits(_ outcome: InsertionOutcome, text: String, raw: String, secureField: Bool) {
        guard let learning else { return }
        let target = self.target, app = target.bundleID ?? "-"
        func skip(_ gate: String) { chirpLog.info("learn skip gate=\(gate, privacy: .public) app=\(app, privacy: .public)") }
        let plan = LearnWatchPlan.plan(learningEnabled: settings.learningEnabled, historyEnabled: settings.historyEnabled,
                                       isPrivate: privateDictation || privateSession.isActive,
                                       excluded: Self.excludedFromHistory(target.bundleID), secureField: secureField,
                                       outcome: outcome, axRange: inserter.lastAXRange)
        if case .skip(let gate) = plan { return skip(gate) }
        if case .watch(let range) = plan, let field = AXWatchedField.focused() {
            learning.watcher.watch(field, inserted: text, range: range, raw: raw, bundleID: target.bundleID, appName: target.name)
            return
        }
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier { AXWatchedField.requestAccessibility(pid: pid) }
        Task {
            await learning.watcher.watchPasted({ AXWatchedField.focused() }, inserted: text, raw: raw, bundleID: target.bundleID,
                                               appName: target.name)
        }
    }

    /// The HUD's small "Learned: Kubernetes" the first time a correction becomes active (never over a dictation).
    func showLearned(_ items: [LearnedItem]) {
        guard let first = items.first, !machine.state.isActive else { return }
        let more = items.count > 1 ? " +\(items.count - 1)" : ""
        hud.cancelHide()
        hud.model.reset()
        hud.model.status = "Learned: \(first.correction.title)\(more)"
        hud.model.indicator = .sparkle
        hud.model.silence()
        hud.show()
        hud.announce(hud.model.status)
        hud.hide(after: 2)
    }

    /// History's Insert Again: `text` into the focused field of the frontmost app the way a dictation is inserted (AX,
    /// then paste, then a copy), with the same HUD result. Never while a dictation runs or Chirp is paused, and never
    /// into a secure field. It is not kept again.
    func insertAgain(_ text: String) async {
        guard !machine.state.isActive, !isPaused else { NSSound.beep(); return }
        inserter.forgetUndo()
        rawOffer.close()
        hud.cancelHide()
        hud.model.reset()
        hud.model.settle(on: text)
        let outcome = await inserter.insert(text)
        show(outcome, final: FinalResult(text: text))
    }
}

/// Runs on the audio thread: forwards frames to the socket in order and measures levels.
final class CaptureSink: @unchecked Sendable {
    private let session: RollingDictationSession
    private let onLevel: @Sendable (Level, TimeInterval) -> Void
    private let onSilence: @Sendable () -> Void
    private let lock = NSLock()
    private let onAutoStop: @Sendable () -> Void
    private let onLimit: @Sendable () -> Void
    private var limitSent = false
    private var guardState = SilenceGuard()
    private var autoStop: AutoStopDetector?
    private var clock: TimeInterval = 0

    init(session: RollingDictationSession, autoStop: AutoStopDetector? = nil, onLevel: @escaping @Sendable (Level, TimeInterval) -> Void,
         onSilence: @escaping @Sendable () -> Void, onAutoStop: @escaping @Sendable () -> Void = {},
         onLimit: @escaping @Sendable () -> Void = {}) {
        self.session = session
        self.autoStop = autoStop
        self.onLevel = onLevel
        self.onSilence = onSilence
        self.onAutoStop = onAutoStop
        self.onLimit = onLimit
    }

    /// Total capture ceiling; the socket wrapper rolls individual segments below the protocol limit.
    static let limitSeconds = RollingDictationSegmenter.maxTotal

    /// `muted`: the frame was zeroed for the start cue. It is sent and counted, but the silence and auto-stop
    /// detectors do not hear it (as before, when the microphone opened after the cue).
    func handle(_ frame: Data, muted: Bool = false) {
        session.sendAudio(frame)
        let level = muted ? .zero : Level(pcm16: frame)
        let (silent, paused, limit, elapsed) = lock.withLock { () -> (Bool, Bool, Bool, TimeInterval) in
            clock += Double(frame.count / 2) / PCMConverter.sampleRate
            let limit = !limitSent && clock >= Self.limitSeconds
            if limit { limitSent = true }
            guard !muted else { return (false, false, limit, clock) }
            return (guardState.feed(level, at: clock), autoStop?.feed(level, at: clock) ?? false, limit, clock)
        }
        onLevel(level, elapsed)
        if silent { onSilence() }
        if paused { onAutoStop() }
        if limit { onLimit() }
    }
}
