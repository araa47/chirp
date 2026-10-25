import UIKit
import ChirpIOSCore
import KeyboardPolicy

/// Delete key: reports touch-down/up so the controller can repeat while held. VoiceOver activation
/// sends neither, so it is mapped to a single press+release.
private final class HoldRepeatButton: UIButton {
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    override func accessibilityActivate() -> Bool { onPress?(); onRelease?(); return true }
}

/// Keyboard extension entry class. Capture and network remain in the app. All screen decisions live in
/// `KeyboardPresenter` (KeyboardPolicy package); this class only gathers inputs and applies the result.
@MainActor
final class ChirpKeyboardViewController: UIInputViewController {
    private let status = UILabel()
    private let detail = UILabel()
    private let warning = UILabel()
    private let primary = UIButton(type: .system)
    private let cancel = UIButton(type: .system)
    private let raw = UIButton(type: .system)
    private let style = UIButton(type: .system)
    private let end = UIButton(type: .system)
    private let globe = UIButton(type: .system)
    private let space = UIButton(type: .system)
    private let delete = HoldRepeatButton(type: .system)
    private let enter = UIButton(type: .system)
    private let open = UIButton(type: .system)
    private var bridge: KeyboardBridgeClient?
    private var state: BridgeState?
    private var policy = OwnedInsertion()
    private var timer: Timer?
    private var applying = false
    private var visible = false
    private var rawUntil: Date?
    private var kept = false
    private var notice: String?
    private var noticeUntil: Date?
    private var rawRequested = false
    private var startPending = false
    private var pendingUntil: Date?
    private var fallback: String?
    private var clock = RecordingClock()
    private var styleItems: [StyleItem] = []
    private var privacyOn = false
    private var repeatTimer: Timer?
    private var repeatCount = 0
    private lazy var haptic = UIImpactFeedbackGenerator(style: .light)
    private var stack: UIStackView!
    private var openRow: UIStackView!
    private var keyHeights: [NSLayoutConstraint] = []
    private var insets: [NSLayoutConstraint] = []
    private var primaryHeight: NSLayoutConstraint!
    private var primaryCap: NSLayoutConstraint!
    private var appliedMetrics: KeyboardMetrics?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        status.font = .preferredFont(forTextStyle: .headline)
        detail.font = .preferredFont(forTextStyle: .caption1)
        warning.font = .preferredFont(forTextStyle: .caption1)
        warning.textColor = .systemRed
        for label in [status, detail, warning] {
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
        }
        status.accessibilityTraits.insert(.updatesFrequently)
        status.accessibilityIdentifier = "chirp.keyboard.status"
        detail.accessibilityIdentifier = "chirp.keyboard.detail"
        configure(primary, title: "Open Chirp to start session", symbol: "arrow.up.forward.app", id: "primary",
                  action: #selector(primaryTapped), prominent: true)
        configure(cancel, title: "Cancel", symbol: "xmark", id: "cancel", action: #selector(cancelTapped))
        configure(raw, title: "Use raw", symbol: "arrow.uturn.backward", id: "raw", action: #selector(rawTapped))
        configure(style, title: "Style", symbol: "sparkles", id: "style", action: nil)
        configure(end, title: "End", symbol: "mic.slash", id: "end", action: #selector(endTapped))
        end.accessibilityLabel = "End session"
        configure(globe, title: nil, symbol: "globe", id: "globe", action: nil)
        globe.accessibilityLabel = "Next keyboard"
        globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        configure(space, title: "Space", symbol: nil, id: "space", action: #selector(spaceTapped))
        configure(delete, title: nil, symbol: "delete.left", id: "delete", action: nil)
        delete.accessibilityLabel = "Delete"
        delete.accessibilityHint = "Touch and hold to keep deleting."
        delete.addTarget(self, action: #selector(deleteDown), for: .touchDown)
        delete.addTarget(self, action: #selector(deleteUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        delete.onPress = { [weak self] in self?.deleteDown() }
        delete.onRelease = { [weak self] in self?.deleteUp() }
        configure(enter, title: nil, symbol: "return", id: "return", action: #selector(returnTapped))
        enter.accessibilityLabel = "Return"
        configure(open, title: "Open Chirp", symbol: "arrow.up.forward.app", id: "open", action: #selector(openTapped))
        open.configuration = .plain()
        open.configuration?.title = "Open Chirp"
        open.configuration?.image = UIImage(systemName: "arrow.up.forward.app")
        open.configuration?.imagePadding = 4
        open.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
        open.titleLabel?.adjustsFontForContentSizeCategory = true
        style.showsMenuAsPrimaryAction = true

        let primaryBox = UIView()
        primary.translatesAutoresizingMaskIntoConstraints = false
        primaryBox.addSubview(primary)
        primaryHeight = primary.heightAnchor.constraint(greaterThanOrEqualToConstant: KeyboardMetrics.minimumPrimaryHeight)
        primaryCap = primary.widthAnchor.constraint(lessThanOrEqualToConstant: 440)
        let fill = [primary.leadingAnchor.constraint(equalTo: primaryBox.leadingAnchor),
                    primary.trailingAnchor.constraint(equalTo: primaryBox.trailingAnchor)]
        fill.forEach { $0.priority = .defaultHigh }
        NSLayoutConstraint.activate(fill + [
            primary.centerXAnchor.constraint(equalTo: primaryBox.centerXAnchor),
            primary.topAnchor.constraint(equalTo: primaryBox.topAnchor),
            primary.bottomAnchor.constraint(equalTo: primaryBox.bottomAnchor),
            primaryHeight, primaryCap])

        openRow = UIStackView(arrangedSubviews: [open, UIView()])
        openRow.isHidden = true
        let secondary = row([cancel, raw, style])
        let typing = row([globe, space, delete, enter, end], fill: false)
        for key in [globe, delete, enter, end] {
            key.setContentHuggingPriority(.required, for: .horizontal)
            key.widthAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        }
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        stack = UIStackView(arrangedSubviews: [status, detail, warning, openRow, primaryBox, secondary, typing])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        insets = [stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                  stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                  stack.topAnchor.constraint(equalTo: view.topAnchor),
                  stack.bottomAnchor.constraint(equalTo: view.bottomAnchor)]
        NSLayoutConstraint.activate(insets)
        registerForTraitChanges([UITraitVerticalSizeClass.self]) { (self: Self, _) in self.render() }
        applyMetrics()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        timer?.invalidate(); timer = nil
        stopRepeat()
        cancelOwnedActiveUtterance()
        bridge = nil; state = nil
        visible = true
        invalidateOwnership()
        if hasFullAccess {
            do {
                bridge = try KeyboardBridgeClient()
                bridge?.onChange = { [weak self] in self?.reconcile() }
            } catch { fallback = "Shared session unavailable. Open Chirp to finish setup." }
            // Lets the app's setup checklist show "keyboard ready". Only a timestamp is stored.
            try? KeyboardSetupStore(root: SharedConfiguration(bundle: .main).containerURL()).recordFullAccess()
        }
        reconcile()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcile() }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopRepeat()
        cancelOwnedActiveUtterance()
        visible = false
        timer?.invalidate(); timer = nil
        bridge = nil; state = nil
        invalidateOwnership()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyMetrics()
        if globe.isHidden == needsInputModeSwitchKey { render() }
    }

    override func textWillChange(_ textInput: (any UITextInput)?) {
        super.textWillChange(textInput)
        if !applying { invalidateOwnership() }
    }
    override func selectionWillChange(_ textInput: (any UITextInput)?) {
        super.selectionWillChange(textInput)
        if !applying { invalidateOwnership() }
    }
    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        if !applying { invalidateOwnership(); render() }
    }
    override func selectionDidChange(_ textInput: (any UITextInput)?) {
        super.selectionDidChange(textInput)
        if !applying { invalidateOwnership(); render() }
    }

    // MARK: Layout

    private func configure(_ button: UIButton, title: String?, symbol: String?, id: String, action: Selector?,
                           prominent: Bool = false) {
        var configuration = prominent ? UIButton.Configuration.filled() : UIButton.Configuration.tinted()
        configuration.title = title
        configuration.image = symbol.flatMap { UIImage(systemName: $0) }
        configuration.imagePadding = 6
        configuration.cornerStyle = prominent ? .large : .medium
        configuration.titleLineBreakMode = .byTruncatingTail
        let textStyle: UIFont.TextStyle = prominent ? .title3 : .body
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            let font = UIFont.preferredFont(forTextStyle: textStyle)
            attributes.font = prominent ? UIFont.systemFont(ofSize: font.pointSize, weight: .semibold) : font
            return attributes
        }
        button.configuration = configuration
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.numberOfLines = 2
        button.accessibilityLabel = title
        button.accessibilityIdentifier = "chirp.keyboard." + id
        if !prominent && id != "open" {
            keyHeights.append(button.heightAnchor.constraint(greaterThanOrEqualToConstant: 48))
            keyHeights.last?.isActive = true
        }
        if let action { button.addTarget(self, action: action, for: .touchUpInside) }
    }

    private func row(_ buttons: [UIButton], fill: Bool = true) -> UIStackView {
        let result = UIStackView(arrangedSubviews: buttons)
        if fill { result.distribution = .fillEqually }
        return result
    }

    private var compactHeight: Bool { traitCollection.verticalSizeClass == .compact }

    /// iPad: wider spacing, primary capped and centered. Compact height (landscape iPhone): smaller keys.
    private func applyMetrics() {
        let metrics = KeyboardMetrics.make(width: Double(view.bounds.width), compactHeight: compactHeight)
        guard metrics != appliedMetrics else { return }
        appliedMetrics = metrics
        ([stack!] + stack.arrangedSubviews.compactMap { $0 as? UIStackView }).forEach { $0.spacing = metrics.spacing }
        keyHeights.forEach { $0.constant = metrics.keyHeight }
        primaryHeight.constant = metrics.primaryHeight
        primaryCap.isActive = metrics.maxPrimaryWidth != nil
        primaryCap.constant = metrics.maxPrimaryWidth ?? 0
        insets[0].constant = metrics.inset; insets[1].constant = -metrics.inset
        insets[2].constant = 8; insets[3].constant = -8
    }

    // MARK: Ownership

    private func context() -> CursorContext {
        let proxy = textDocumentProxy
        return CursorContext(documentID: proxy.documentIdentifier,
                             before: proxy.documentContextBeforeInput,
                             after: proxy.documentContextAfterInput, selection: proxy.selectedText,
                             hasText: proxy.hasText)
    }

    private func invalidateOwnership() {
        // Losing real ownership also ends a held Delete; the hold's own presses never owned anything.
        if policy.generation != nil || startPending { stopRepeat() }
        policy.invalidate(); rawUntil = nil; rawRequested = false; startPending = false; pendingUntil = nil; kept = false
    }

    private func cancelOwnedActiveUtterance() {
        // No IPC after access revocation. On hide, only cancel our still-current
        // utterance; never cancel an app/companion recording or end the session.
        guard hasFullAccess, !policy.isFinal, let owned = policy.utteranceID,
              let state, state.generation == policy.generation, state.utteranceID == owned,
              state.phase == .connecting || state.phase == .listening || state.phase == .correcting else { return }
        try? bridge?.send(.cancel, state: state, utteranceID: owned)
    }

    private func reconcile() {
        guard visible else { return }
        guard hasFullAccess else {
            invalidateOwnership(); bridge = nil; state = nil; render(); return
        }
        do {
            if bridge == nil {
                bridge = try KeyboardBridgeClient()
                bridge?.onChange = { [weak self] in self?.reconcile() }
            }
            let current = try bridge?.state()
            if current?.generation != state?.generation { invalidateOwnership() }
            state = current
            guard let current, current.leaseUntil > Date() else {
                invalidateOwnership(); render(); return
            }
            fallback = nil
            if startPending && Date() >= (pendingUntil ?? .distantPast) { invalidateOwnership() }
            if let generation = policy.generation, let utterance = policy.utteranceID {
                if let active = current.utteranceID, active != utterance {
                    if !startPending { invalidateOwnership() }
                } else if current.utteranceID == utterance {
                    startPending = false; pendingUntil = nil
                    for result in try bridge?.results(generation: generation, utteranceID: utterance) ?? [] {
                        apply(result, leaseUntil: current.leaseUntil)
                    }
                }
            }
        } catch {
            state = nil; invalidateOwnership()
            fallback = "Session unavailable. Open Chirp to recover your dictation."
        }
        render()
    }

    private func apply(_ result: BridgeResult, leaseUntil: Date) {
        let kind: ResultKind
        switch result.kind {
        case .partial: kind = .partial
        case .correcting: kind = .correcting
        case .final: kind = .final
        case .raw: kind = .raw
        }
        let event = TextEvent(id: result.id, generation: result.generation, utteranceID: result.utteranceID,
                              kind: kind, text: result.text, sequence: result.sequence,
                              createdAt: result.createdAt, expiresAt: result.expiresAt, segment: result.segment ?? 0)
        guard let plan = policy.plan(event, context: context(), now: Date(), leaseUntil: leaseUntil,
                                     rawRequested: rawRequested, commands: state?.spokenCommands == true) else { return }
        startPending = false
        guard execute(plan), policy.didApply(plan, observed: context(), now: Date()) else {
            invalidateOwnership(); return
        }
        if kind == .final { kept = result.kept == true; pressReturnIfAsked(after: plan, result: result) }
        if kind == .final, let original = result.raw, original != result.text {
            rawUntil = Date().addingTimeInterval(5)
        }
        if kind == .raw { rawUntil = nil; rawRequested = false }
    }

    /// UIKit edits are synchronous requests, but hosts may apply them differently.
    /// Verify every intermediate context and stop immediately if one disagrees.
    private func execute(_ plan: EditPlan) -> Bool {
        guard context().matches(plan.expected) else { return false }
        applying = true
        defer { applying = false }
        return VerifiedEditor.apply(plan, context: { self.context() },
                                    deleteBackward: { self.textDocumentProxy.deleteBackward() },
                                    insertText: { self.textDocumentProxy.insertText($0) })
    }

    private func send(_ action: BridgeAction, utteranceID: UUID? = nil) {
        guard hasFullAccess, let bridge, let state, state.leaseUntil > Date() else { render(); return }
        do { try bridge.send(action, state: state, utteranceID: utteranceID ?? state.utteranceID) }
        catch { fallback = "Command could not reach Chirp. Open Chirp to check the session." }
        render()
    }

    // MARK: Actions

    /// Light feedback on start/stop. Keyboards without Full Access may not use haptics, so skip them.
    private func tick() { if hasFullAccess { haptic.impactOccurred() } }

    @objc private func primaryTapped() {
        guard hasFullAccess else { render(); return }
        reconcile()
        guard let state, state.leaseUntil > Date() else { openTapped(); return }
        switch state.phase {
        case .connecting, .listening:
            tick(); send(.stop)
        case .correcting:
            break
        case .armed, .finished:
            guard !startPending else { return }
            let utterance = UUID()
            guard policy.begin(generation: state.generation, utteranceID: utterance,
                               context: context(), now: Date()) else { render(); return }
            stopRepeat(); tick()
            rawUntil = nil; rawRequested = false; startPending = true
            pendingUntil = Date().addingTimeInterval(5)
            send(.start, utteranceID: utterance)
        case .idle, .failed:
            openTapped()
        }
    }

    @objc private func cancelTapped() {
        if policy.canUndo(now: Date()) { undo(); return }
        guard !policy.isFinal else { return }
        let utterance = policy.utteranceID ?? state?.utteranceID
        if let plan = policy.cancel(context: context()) {
            if execute(plan) { policy = OwnedInsertion() } else { invalidateOwnership() }
        }
        rawUntil = nil; rawRequested = false; startPending = false; pendingUntil = nil
        send(.cancel, utteranceID: utterance)
    }
    /// Auto-Enter: after the last segment's final, wait for the host to settle, then type Return only if the editor
    /// still shows exactly what we left (a cursor move or edit cancels it).
    private func pressReturnIfAsked(after plan: EditPlan, result: BridgeResult) {
        let mode = AutoEnterMode(rawValue: state?.autoEnter ?? "") ?? .off
        guard textDocumentProxy.isSecureTextEntry != true,
              AutoEnter.presses(mode: mode, returnKey: returnKey(), kept: result.kept == true, moved: false,
                                lastSegment: state?.phase == .finished, text: plan.replacement) else { return }
        let landed = context()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.visible, self.policy.isFinal, self.context().matches(landed) else { return }
            self.textDocumentProxy.insertText("\n")
            // Sent: nothing is left to undo or swap.
            self.policy.release(); self.rawUntil = nil; self.rawRequested = false; self.kept = false
            self.show("Finished · " + AutoEnter.sent)
            self.render()
        }
    }
    private func returnKey() -> ReturnKey {
        switch textDocumentProxy.returnKeyType ?? .default {
        case .default: .plain
        case .send: .send
        case .go: .go
        case .done: .done
        case .join: .join
        case .route: .route
        case .continue: .continue
        case .search, .google, .yahoo: .search
        case .next, .emergencyCall: .next
        @unknown default: .other
        }
    }

    /// Removes the dictation that just landed, only if the editor still shows exactly what we inserted.
    private func undo() {
        if let plan = policy.undo(context: context(), now: Date()), execute(plan) { show("Dictation removed") }
        else { show("Text changed — nothing to undo") }
        policy.release(); rawUntil = nil; rawRequested = false; kept = false
        render()
    }
    private func show(_ text: String) { notice = text; noticeUntil = Date().addingTimeInterval(3) }
    @objc private func rawTapped() {
        guard let rawUntil, Date() < rawUntil, policy.isFinal, !rawRequested else { return }
        rawRequested = true
        send(.useRaw, utteranceID: policy.utteranceID)
    }
    @objc private func endTapped() { send(.end); invalidateOwnership() }
    @objc private func spaceTapped() { invalidateOwnership(); textDocumentProxy.insertText(" "); render() }
    @objc private func returnTapped() { invalidateOwnership(); textDocumentProxy.insertText("\n"); render() }
    @objc private func openTapped() {
        fallback = "Open Chirp manually if iOS refuses. Return here using Back to app or the app switcher."
        render()
        guard let url = URL(string: "chirp://session/start") else { return }
        if openThroughApplication(url) {
            fallback = "Set up the session in Chirp, then return using the app switcher."
            render()
            return
        }
        // The completion's thread is unspecified; @Sendable keeps it free of main-actor isolation checks.
        extensionContext?.open(url, completionHandler: { @Sendable [weak self] opened in
            Task { @MainActor [weak self] in
                self?.fallback = opened
                    ? "Set up the session in Chirp, then return using the app switcher."
                    : "iOS could not open Chirp from this keyboard. Open Chirp manually, then return here."
                self?.render()
            }
        })
    }
    /// `extensionContext.open` always fails for keyboards (it serves Today widgets only). The UIApplication at
    /// the end of the responder chain still opens URLs, but its `open(_:options:)` is extension-unavailable,
    /// so it is called through its selector. Personal-install only: an App Store review risk (see README).
    private func openThroughApplication(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication, application.responds(to: selector) {
                typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
                let open = unsafeBitCast(application.method(for: selector), to: Open.self)
                open(application, selector, url as NSURL, [:] as NSDictionary, nil)
                return true
            }
            responder = current.next
        }
        return false
    }

    // MARK: Delete press-and-hold

    @objc private func deleteDown() {
        stopRepeat()
        invalidateOwnership()
        deleteOnce()
        repeatTimer = scheduleRepeat(after: KeyRepeat.initialDelay)
    }
    @objc private func deleteUp() { stopRepeat() }

    private func scheduleRepeat(after delay: TimeInterval) -> Timer {
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in self?.repeatFired() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func repeatFired() {
        // A hold never edits through an owned utterance: if one appears, stop instead of racing it.
        guard repeatTimer != nil, policy.generation == nil, !startPending else { stopRepeat(); return }
        deleteOnce()
        repeatCount += 1
        repeatTimer = scheduleRepeat(after: KeyRepeat.interval(afterRepeats: repeatCount))
    }

    private func deleteOnce() {
        applying = true
        textDocumentProxy.deleteBackward()
        applying = false
        render()
    }

    private func stopRepeat() {
        repeatTimer?.invalidate(); repeatTimer = nil; repeatCount = 0
    }

    // MARK: Render

    private func inputs() -> KeyboardInputs {
        let now = Date()
        var i = KeyboardInputs(now: now)
        i.hasFullAccess = hasFullAccess
        if hasFullAccess, let state {
            i.phase = KeyboardPhase(rawValue: state.phase.rawValue)
            i.leaseUntil = state.leaseUntil; i.sessionExpiresAt = state.sessionExpiresAt
            i.styleID = state.styleID; i.availableStyleIDs = state.availableStyleIDs
            i.debugRetention = state.debugRetention; i.privacyMode = state.privacyMode
            i.errorCode = state.errorCode.flatMap { KeyboardError(rawValue: $0.rawValue) }
        }
        i.ownsUtterance = policy.generation != nil
        i.isFinal = policy.isFinal; i.requiresRecovery = policy.requiresRecovery
        i.rawUntil = rawUntil; i.rawRequested = rawRequested; i.startPending = startPending
        i.undoAvailable = policy.canUndo(now: now); i.kept = kept
        i.notice = now < (noticeUntil ?? .distantPast) ? notice : nil
        i.fallback = fallback
        let live = hasFullAccess && (state?.leaseUntil ?? .distantPast) > now
        let owned = state.flatMap { $0.generation == policy.generation && !policy.isFinal ? policy.utteranceID : nil }
        clock.observe(phase: live ? i.phase : nil, ownedUtterance: live && owned == state?.utteranceID ? owned : nil, now: now)
        i.recordingStartedAt = clock.startedAt
        i.needsGlobe = needsInputModeSwitchKey
        i.compactHeight = compactHeight
        return i
    }

    private func render() {
        let screen = KeyboardPresenter.screen(inputs())
        status.text = screen.status
        detail.text = screen.detail; detail.isHidden = !screen.showsDetail
        warning.text = screen.warning; warning.isHidden = screen.warning == nil
        let action = screen.primary
        primary.configuration?.title = action.title
        primary.configuration?.image = UIImage(systemName: action.symbol)
        primary.configuration?.baseBackgroundColor = action.kind == .stop ? .systemRed : nil
        primary.accessibilityLabel = action.title
        primary.accessibilityHint = action.hint
        primary.isEnabled = action.isEnabled
        cancel.isEnabled = screen.cancelEnabled
        cancel.configuration?.title = screen.showsUndo ? "Undo" : "Cancel"
        cancel.configuration?.image = UIImage(systemName: screen.showsUndo ? "arrow.uturn.backward" : "xmark")
        cancel.accessibilityIdentifier = screen.showsUndo ? "chirp.keyboard.undo" : "chirp.keyboard.cancel"
        cancel.accessibilityLabel = screen.showsUndo ? "Undo last dictation" : "Cancel"
        raw.isEnabled = screen.rawEnabled
        raw.configuration?.title = screen.rawTitle
        raw.accessibilityLabel = "Use raw"
        raw.accessibilityValue = screen.rawSecondsLeft.map { "\($0) seconds left" }
        style.isEnabled = screen.styleEnabled
        style.configuration?.title = screen.styleTitle
        style.accessibilityLabel = screen.styleTitle
        // Rebuilding the menu while it is open would dismiss it, so only replace it when items change.
        if screen.styleItems != styleItems || screen.privacyOn != privacyOn {
            styleItems = screen.styleItems; privacyOn = screen.privacyOn
            let styles = styleItems.map { item in
                UIAction(title: item.title, state: item.isChecked ? .on : .off) { [weak self] _ in
                    self?.send(.style(item.id))
                }
            }
            let on = privacyOn
            let privacy = UIAction(title: "Private session · exclude history", state: on ? .on : .off) { [weak self] _ in
                self?.send(.privacy(!on))
            }
            style.menu = UIMenu(children: [UIMenu(options: .displayInline, children: styles), UIMenu(options: .displayInline, children: [privacy])])
        }
        end.isEnabled = screen.endEnabled
        openRow.isHidden = !screen.showsOpenChirp
        globe.isHidden = !screen.showsGlobe
    }
}
