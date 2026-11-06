import UIKit
import ChirpIOSCore
import KeyboardKit
import KeyboardPolicy
import KeyboardTyping

/// The input view: lets the keys play the system click through `UIDevice.playInputClick`.
private final class ClickInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

/// Keyboard extension entry class: a full typing keyboard (KeyboardKit's system-style keys, see `KeyboardTyping`)
/// under Chirp's one top row. Capture and network remain in the app. All Chirp screen decisions live in `KeyboardPresenter`
/// (KeyboardPolicy package); this class only gathers inputs and applies the result.
@MainActor
final class ChirpKeyboardViewController: KeyboardInputViewController {
    private let topRow = KeyboardTopRow()
    private let overlay = KeyboardInfoOverlay()
    private let chrome = TypingChrome()
    private var keys: UIViewController?
    private var autocomplete: ChirpAutocompleteService?
    private var style: UIButton { overlay.style }
    private var bridge: KeyboardBridgeClient?
    private var bridgeState: BridgeState?
    private var policy = OwnedInsertion()
    private var timer: Timer?
    private var applying = false
    private var visible = false
    private var rawUntil: Date?
    private var typingUntil: Date?
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
    private var documentID: UUID?
    /// Learn from my edits: the last final this keyboard inserted, watched for the user's fix (`LearningWatch`).
    private var watch: LearningWatch?
    private var learnedStore: IOSLearnedStore?
    private lazy var haptic = UIImpactFeedbackGenerator(style: .light)
    private var stack: UIStackView!
    private var rowHeight: NSLayoutConstraint!
    private var overlayInsets: [NSLayoutConstraint] = []
    private var appliedMetrics: KeyboardMetrics?

    override func loadView() {
        inputView = ClickInputView(frame: .zero, inputViewStyle: .keyboard)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // No background of our own: the input view's `.keyboard` surface is the system keyboard's surround.
        let typing = TypingKeyboard.install(on: self) { [weak self] in self?.hasFullAccess ?? false }
        autocomplete = typing.autocomplete
        typing.actions.willEdit = { [weak self] in self?.userWillType() }
        overlay.accessibilityViewIsModal = true
        topRow.options.addTarget(self, action: #selector(infoTapped), for: .touchUpInside)
        topRow.primary.addTarget(self, action: #selector(primaryTapped), for: .touchUpInside)
        overlay.close.addTarget(self, action: #selector(infoTapped), for: .touchUpInside)
        overlay.end.addTarget(self, action: #selector(endTapped), for: .touchUpInside)
        topRow.cancel.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        topRow.undo.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        topRow.raw.addTarget(self, action: #selector(rawTapped), for: .touchUpInside)
        topRow.open.addTarget(self, action: #selector(openTapped), for: .touchUpInside)

        // The keys (with KeyboardKit's suggestion bar on top of them) fill the view; Chirp's one top row lies over the
        // suggestion bar, as Android's strip lies over HeliBoard's.
        stack = UIStackView()
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        topRow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topRow)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay)
        rowHeight = topRow.heightAnchor.constraint(equalToConstant: 40)
        overlayInsets = [overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor), overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor)]
        NSLayoutConstraint.activate(overlayInsets + [
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor), stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor), stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            topRow.topAnchor.constraint(equalTo: view.topAnchor), rowHeight,
            topRow.leadingAnchor.constraint(equalTo: view.leadingAnchor), topRow.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: topRow.bottomAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6),
        ])
        registerForTraitChanges([UITraitVerticalSizeClass.self]) { (self: Self, _) in self.applyMetrics(); self.render() }
        applyMetrics()
    }

    /// KeyboardKit would rebuild its whole view on every appearance (and drop Chirp's row); the keys are built once
    /// under the top row instead.
    override func viewWillSetupKeyboardView() {
        guard keys == nil else { return }
        let host = TypingKeyboard.makeKeys(for: self, chrome: chrome)
        addChild(host)
        stack.addArrangedSubview(host.view)
        host.didMove(toParent: self)
        keys = host
        view.bringSubviewToFront(topRow)
        view.bringSubviewToFront(overlay)
    }

    override func viewWillSetupInitialKeyboardType() { applyFieldLayout() }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        timer?.invalidate(); timer = nil
        cancelOwnedActiveUtterance()
        bridge = nil; bridgeState = nil
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
        loadLexicon()
        reconcile()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.reconcile() }
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // KeyboardKit's first setup runs after the first appearance and maps a few field types differently.
        applyFieldLayout()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        finishWatch()
        cancelOwnedActiveUtterance()
        setInfo(open: false)
        visible = false
        timer?.invalidate(); timer = nil
        bridge = nil; bridgeState = nil
        invalidateOwnership()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        applyMetrics()
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
        // Another field took focus: open its layout (number pad, e-mail keys…) as Apple's keyboard does.
        if textDocumentProxy.chirpDocumentIdentifier != documentID { finishWatch(); applyFieldLayout() }
        if !applying { invalidateOwnership(); render() }
    }
    override func selectionDidChange(_ textInput: (any UITextInput)?) {
        super.selectionDidChange(textInput)
        if !applying { invalidateOwnership(); render() }
    }

    // MARK: Layout

    private var compactHeight: Bool { traitCollection.verticalSizeClass == .compact }

    /// The top row follows the system's predictive bar in height; the suggestions leave room for ⋯ and the mic. Both
    /// rows have a fixed height, so the keyboard is the same height in every bridgeState.
    private func applyMetrics() {
        let metrics = KeyboardMetrics.make(width: Double(view.bounds.width), compactHeight: compactHeight)
        guard metrics != appliedMetrics else { return }
        appliedMetrics = metrics
        rowHeight.constant = metrics.suggestionHeight
        chrome.suggestionHeight = metrics.suggestionHeight
        chrome.leadingInset = metrics.inset + KeyboardMetrics.controlWidth
        chrome.trailingInset = metrics.inset + KeyboardMetrics.controlWidth
        overlayInsets[0].constant = metrics.inset; overlayInsets[1].constant = -metrics.inset
        topRow.apply(metrics)
    }

    /// The host field's keyboard type picks the first layout; autocorrect follows the field and the layout.
    private func applyFieldLayout() {
        let proxy = textDocumentProxy
        documentID = proxy.chirpDocumentIdentifier
        let layout = TypingLayout(keyboardTypeRawValue: (proxy.keyboardType ?? .default).rawValue)
        TypingKeyboard.apply(layout, to: self)
        autocomplete?.allowsAutocorrect = layout.allowsAutocorrect && proxy.autocorrectionType != .no
            && proxy.spellCheckingType != .no
    }

    /// Text replacements and contact names for suggestions; read on device, never stored by Chirp.
    private func loadLexicon() {
        // iOS calls back on a background queue; @Sendable keeps the closure free of main-actor isolation checks.
        requestSupplementaryLexicon { @Sendable [weak self] lexicon in
            let entries = lexicon.entries.map { LexiconEntry(input: $0.userInput, output: $0.documentText) }
            Task { @MainActor [weak self] in self?.autocomplete?.lexicon = entries }
        }
    }

    // MARK: Ownership

    private func context() -> CursorContext {
        let proxy = textDocumentProxy
        // No identifier (the field is going away): a fresh one, so nothing owned is ever matched against it.
        return CursorContext(documentID: proxy.chirpDocumentIdentifier ?? UUID(),
                             before: proxy.documentContextBeforeInput,
                             after: proxy.documentContextAfterInput, selection: proxy.selectedText,
                             hasText: proxy.hasText)
    }

    private func invalidateOwnership() {
        policy.invalidate(); rawUntil = nil; rawRequested = false; startPending = false; pendingUntil = nil; kept = false
    }

    private func cancelOwnedActiveUtterance() {
        // No IPC after access revocation. On hide, only cancel our still-current
        // utterance; never cancel an app/companion recording or end the session.
        guard hasFullAccess, !policy.isFinal, let owned = policy.utteranceID,
              let bridgeState, bridgeState.generation == policy.generation, bridgeState.utteranceID == owned,
              bridgeState.phase == .connecting || bridgeState.phase == .listening || bridgeState.phase == .correcting else { return }
        try? bridge?.send(.cancel, state: bridgeState, utteranceID: owned)
    }

    private func reconcile() {
        guard visible else { return }
        observeWatch()
        guard hasFullAccess else {
            invalidateOwnership(); bridge = nil; bridgeState = nil; render(); return
        }
        do {
            if bridge == nil {
                bridge = try KeyboardBridgeClient()
                bridge?.onChange = { [weak self] in self?.reconcile() }
            }
            let current = try bridge?.state()
            if current?.generation != bridgeState?.generation { invalidateOwnership() }
            bridgeState = current
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
            bridgeState = nil; invalidateOwnership()
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
                                     rawRequested: rawRequested, commands: bridgeState?.spokenCommands == true) else { return }
        startPending = false
        guard execute(plan), policy.didApply(plan, observed: context(), now: Date()) else {
            invalidateOwnership(); return
        }
        if kind == .final { kept = result.kept == true; startWatch(result); pressReturnIfAsked(after: plan, result: result) }
        if kind == .final, let original = result.raw, original != result.text {
            rawUntil = Date().addingTimeInterval(5)
        }
        // Chirp itself changed the text: nothing the user did since is learned.
        if kind == .raw { rawUntil = nil; rawRequested = false; watch = nil }
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

    // MARK: Learn from my edits

    /// Watches the final just inserted, for up to a minute in the same field: never a secure field, a private session,
    /// or while learning is off. Only Chirp's own store, in the app group, ever sees the fix.
    private func startWatch(_ result: BridgeResult) {
        finishWatch()
        guard hasFullAccess, textDocumentProxy.isSecureTextEntry != true, bridgeState?.privacyMode == false else { return }
        let landed = context()
        guard landed.isUsable, let before = landed.before, let after = landed.after else { return }
        if learnedStore == nil {
            let configuration = SharedConfiguration(bundle: .main)
            learnedStore = try? IOSLearnedStore(root: configuration.containerURL(),
                                                secrets: KeychainSecretStore(accessGroup: configuration.keychainAccessGroup))
        }
        guard learnedStore?.allowed == true else { return }
        watch = LearningWatch(documentID: landed.documentID, before: before, after: after, inserted: policy.ownedText,
                              said: result.raw ?? result.text, now: Date())
    }

    /// Each reconcile: one look at the field, or the end of the window.
    private func observeWatch() {
        guard let watch else { return }
        if Date() >= watch.until { finishWatch(); return }
        sampleWatch()
    }

    private func sampleWatch() {
        if textDocumentProxy.isSecureTextEntry == true || bridgeState?.privacyMode == true { watch = nil; return }
        let now = context()
        guard now.isUsable else { return }
        watch?.observe(documentID: now.documentID, before: now.before, after: now.after)
    }

    /// Ends the window and learns the fix, if the user made one inside the dictated span. Past the window, the field
    /// is not read again.
    private func finishWatch() {
        if Date() < watch?.until ?? .distantPast { sampleWatch() }
        guard let ended = watch else { return }
        watch = nil
        guard let edited = ended.edited, bridgeState?.privacyMode != true,
              let learned = try? learnedStore?.learn(inserted: ended.inserted, edited: edited, said: ended.said),
              let first = learned.first else { return }
        show("Learned: " + first.correction.title)
        render()
    }

    private func send(_ action: BridgeAction, utteranceID: UUID? = nil) {
        guard hasFullAccess, let bridge, let bridgeState, bridgeState.leaseUntil > Date() else { render(); return }
        do { try bridge.send(action, state: bridgeState, utteranceID: utteranceID ?? bridgeState.utteranceID) }
        catch { fallback = "Command could not reach Chirp. Open Chirp to check the session." }
        render()
    }

    // MARK: Actions

    /// Light feedback on start/stop. Keyboards without Full Access may not use haptics, so skip them.
    private func tick() { if hasFullAccess { haptic.impactOccurred() } }

    /// Typing next to a dictation the keyboard owns releases it first (its text stays; nothing more lands there).
    private func userWillType() {
        typingUntil = Date().addingTimeInterval(8)
        guard policy.generation != nil || startPending else { return }
        invalidateOwnership()
        render()
    }

    @objc private func primaryTapped() {
        guard hasFullAccess else { render(); return }
        reconcile()
        guard let bridgeState, bridgeState.leaseUntil > Date() else { openTapped(); return }
        switch bridgeState.phase {
        case .connecting, .listening:
            tick(); send(.stop)
        case .correcting:
            break
        case .armed, .finished:
            guard !startPending else { return }
            // A new dictation ends the last one's window: what the user fixed so far is learned.
            finishWatch()
            let utterance = UUID()
            guard policy.begin(generation: bridgeState.generation, utteranceID: utterance,
                               context: context(), now: Date()) else { render(); return }
            tick()
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
        let utterance = policy.utteranceID ?? bridgeState?.utteranceID
        if let plan = policy.cancel(context: context()) {
            if execute(plan) { policy = OwnedInsertion() } else { invalidateOwnership() }
        }
        rawUntil = nil; rawRequested = false; startPending = false; pendingUntil = nil
        send(.cancel, utteranceID: utterance)
    }
    /// Auto-Enter: after the last segment's final, wait for the host to settle, then type Return only if the editor
    /// still shows exactly what we left (a cursor move or edit cancels it).
    private func pressReturnIfAsked(after plan: EditPlan, result: BridgeResult) {
        let mode = AutoEnterMode(rawValue: bridgeState?.autoEnter ?? "") ?? .off
        guard textDocumentProxy.isSecureTextEntry != true,
              AutoEnter.presses(mode: mode, returnKey: returnKey(), kept: result.kept == true, moved: false,
                                lastSegment: bridgeState?.phase == .finished, text: plan.replacement) else { return }
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
        ReturnKey(returnKeyTypeRawValue: (textDocumentProxy.returnKeyType ?? .default).rawValue)
    }

    /// Removes the dictation that just landed, only if the editor still shows exactly what we inserted.
    private func undo() {
        watch = nil
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
    @objc private func endTapped() { setInfo(open: false); send(.end); invalidateOwnership() }
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

    // MARK: Render

    private func inputs() -> KeyboardInputs {
        let now = Date()
        var i = KeyboardInputs(now: now)
        i.hasFullAccess = hasFullAccess
        if hasFullAccess, let bridgeState {
            i.phase = KeyboardPhase(rawValue: bridgeState.phase.rawValue)
            i.leaseUntil = bridgeState.leaseUntil; i.sessionExpiresAt = bridgeState.sessionExpiresAt
            i.styleID = bridgeState.styleID; i.availableStyleIDs = bridgeState.availableStyleIDs
            i.debugRetention = bridgeState.debugRetention; i.privacyMode = bridgeState.privacyMode
            i.errorCode = bridgeState.errorCode.flatMap { KeyboardError(rawValue: $0.rawValue) }
        }
        i.ownsUtterance = policy.generation != nil
        i.isFinal = policy.isFinal; i.requiresRecovery = policy.requiresRecovery
        i.rawUntil = rawUntil; i.rawRequested = rawRequested; i.startPending = startPending
        i.undoAvailable = policy.canUndo(now: now); i.undoUntil = policy.undoUntil; i.kept = kept
        i.notice = now < (noticeUntil ?? .distantPast) ? notice : nil
        i.fallback = fallback
        let live = hasFullAccess && (bridgeState?.leaseUntil ?? .distantPast) > now
        let owned = bridgeState.flatMap { $0.generation == policy.generation && !policy.isFinal ? policy.utteranceID : nil }
        clock.observe(phase: live ? i.phase : nil, ownedUtterance: live && owned == bridgeState?.utteranceID ? owned : nil, now: now)
        i.recordingStartedAt = clock.startedAt
        i.typing = now < (typingUntil ?? .distantPast)
        i.compactHeight = compactHeight
        #if DEBUG && targetEnvironment(simulator)
        KeyboardPreview.apply(to: &i)
        #endif
        return i
    }

    private func render() {
        let screen = KeyboardPresenter.screen(inputs())
        topRow.apply(screen)
        #if DEBUG && targetEnvironment(simulator)
        if KeyboardPreview.preset != nil { setInfo(open: KeyboardPreview.opensInfo) }
        #endif
        overlay.detail.text = screen.detail
        overlay.remaining.text = screen.remaining
        overlay.remaining.isHidden = screen.remaining == nil
        // ⋯ is only in the idle and not-ready rows; dictating or finishing closes its panel.
        if screen.detail == nil || !(screen.topRow == .suggestions || screen.topRow == .notReady) { setInfo(open: false) }
        // Chirp's state takes over the suggestion row while it applies; otherwise the word suggestions show.
        if chrome.showsSuggestions != screen.showsSuggestions { chrome.showsSuggestions = screen.showsSuggestions }
        // Rebuilding the menu while it is open would dismiss it, so only replace it when items change.
        if screen.styleItems != styleItems || screen.privacyOn != privacyOn {
            styleItems = screen.styleItems; privacyOn = screen.privacyOn
            let styles = styleItems.map { item in
                UIAction(title: item.title, state: item.isChecked ? .on : .off) { [weak self] _ in
                    self?.send(.style(item.id))
                }
            }
            let on = privacyOn
            let privacy = UIAction(title: KeyboardPresenter.privateTitle, state: on ? .on : .off) { [weak self] _ in
                self?.send(.privacy(!on))
            }
            style.menu = UIMenu(children: [UIMenu(options: .displayInline, children: styles), UIMenu(options: .displayInline, children: [privacy])])
        }
        overlay.end.isHidden = !screen.endEnabled
        style.isHidden = !screen.showsStyle
        style.configuration?.title = screen.styleTitle
        style.accessibilityLabel = "Style: " + screen.styleTitle
        style.accessibilityHint = "Opens the style menu."
    }

    // MARK: Info overlay

    @objc private func infoTapped() { setInfo(open: overlay.isHidden) }

    private func setInfo(open: Bool) {
        guard overlay.isHidden == open else { return }
        overlay.isHidden = !open
        stripInfoAccessibility(open: open)
        UIAccessibility.post(notification: .screenChanged, argument: open ? overlay.detail : topRow.options)
    }

    private func stripInfoAccessibility(open: Bool) {
        topRow.options.configuration?.baseForegroundColor = open ? KeyboardPalette.koi : KeyboardPalette.inkMuted
        topRow.options.accessibilityValue = open ? "Expanded" : nil
    }
}
