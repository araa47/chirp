import ChirpCore
import ChirpIOSCore
import Combine
import ObjectiveC
import SwiftUI
import UIKit

/// Every key press in the app passes through `UIApplication.sendEvent(_:)` before any view sees it, whichever field
/// has focus, so a modifier held on its own (which SwiftUI's `onKeyPress` and `UIKeyCommand` never report) can start a
/// dictation there. A SwiftUI app runs its own `UIApplication` subclass and ignores `NSPrincipalClass`, so the
/// override goes onto that class at launch with the public Objective-C runtime, calling the original for everything
/// it does not keep.
@MainActor enum PressHook {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        let cls: AnyClass = type(of: UIApplication.shared)
        let selector = #selector(UIApplication.sendEvent(_:))
        guard let method = class_getInstanceMethod(cls, selector) else { return }
        typealias Send = @convention(c) (UIApplication, Selector, UIEvent) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Send.self)
        let send: @convention(block) (UIApplication, UIEvent) -> Void = { app, event in
            if let presses = event as? UIPressesEvent, MainActor.assumeIsolated({ HardwareShortcutController.shared.handle(presses) }) { return }
            original(app, selector, event)
        }
        let implementation = imp_implementationWithBlock(send)
        // Add the override to the app's own class; when it already has one, wrap that one.
        if !class_addMethod(cls, selector, implementation, method_getTypeEncoding(method)) {
            method_setImplementation(method, implementation)
        }
    }
}

/// The in-app hardware-keyboard shortcut (#259): Right ⌥ (or the recorded keys) held to talk, or pressed to start and
/// stop, on the same dictation path as the mic. The text goes into the Chirp field you were typing in, or onto
/// Dictate when no field has focus. Esc cancels. Matching rules are the Mac's (`HardwareShortcutMatcher`).
@MainActor
final class HardwareShortcutController: ObservableObject {
    static let shared = HardwareShortcutController()

    @Published private(set) var shortcut = HardwareShortcut.standard
    /// The settings recorder is waiting for keys.
    @Published private(set) var recording = false
    /// Why the last recorded keys cannot be the shortcut.
    @Published private(set) var rejection: String?
    /// A dictation the shortcut started has not landed yet.
    @Published private(set) var active = false
    /// It lands in a focused text field (the listening bar shows), not on Dictate.
    @Published private(set) var intoField = false

    /// Opens Dictate for a dictation with no field to land in.
    var showDictate: (() -> Void)?
    /// Offers a press to Notes first (with whether a dictation is under way); true when Notes took it.
    var notesKey: ((Bool) -> Bool)?

    private weak var model: SessionCoordinator?
    private weak var field: UIResponder?
    private var matcher = HardwareShortcutMatcher(shortcut: .standard)
    private var gesture = HardwareShortcutGesture(shortcut: .standard)
    private var recorder: HardwareShortcutRecorder?
    private var utterance: UUID?
    /// The dictation reached `.connecting`.
    private var begun = false
    private var phaseWatch: AnyCancellable?
    private var preferencesWatch: AnyCancellable?
    private var resignWatch: AnyCancellable?

    #if DEBUG
    var debugModel: SessionCoordinator? { model }
    #endif

    func attach(_ model: SessionCoordinator) {
        guard self.model !== model else { return }
        self.model = model
        PressHook.install()
        #if DEBUG
        HardwareShortcutSeam.start()
        #endif
        // Preferences load after launch and can change in another scene: follow them.
        preferencesWatch = model.$preferences.map(\.hardwareShortcut).removeDuplicates().sink { [weak self] stored in
            Task { @MainActor in
                guard let self else { return }
                let resolved = HardwareShortcut.resolve(stored)
                if resolved != self.shortcut { self.apply(resolved) }
            }
        }
        phaseWatch = model.$phase.dropFirst().sink { [weak self] phase in Task { @MainActor in self?.phaseChanged(phase) } }
        // Keys let go while Chirp was in the background never reach it: a hold under way ends there.
        resignWatch = NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)
            .sink { [weak self] _ in Task { @MainActor in self?.lostKeyboard() } }
    }

    /// Saves a new shortcut (keys, mode or switch) to the app group's preferences.
    func update(_ new: HardwareShortcut) {
        apply(new)
        guard let model else { return }
        model.preferences.hardwareShortcut = new == .standard ? nil : new
        model.savePreferences()
    }

    func startRecording() {
        cancelPress()
        recorder = HardwareShortcutRecorder(); recording = true; rejection = nil
    }

    func stopRecording() { recorder = nil; recording = false }

    private func apply(_ new: HardwareShortcut) {
        cancelPress()
        shortcut = new
        matcher = HardwareShortcutMatcher(shortcut: new)
        gesture = HardwareShortcutGesture(shortcut: new)
    }

    // MARK: Key presses

    /// Returns true to keep the event from the app (the shortcut's own key, or keys pressed into the recorder).
    func handle(_ event: UIPressesEvent) -> Bool {
        var swallow = false
        for press in event.allPresses {
            guard let key = press.key else { continue }
            let usage = key.keyCode.rawValue
            let modifiers = HardwareShortcut.Modifiers(rawValue: key.modifierFlags.rawValue)
            switch press.phase {
            case .began: swallow = began(usage, modifiers) || swallow
            case .ended: swallow = ended(usage) || swallow
            case .cancelled: lostKeyboard()
            default: continue
            }
        }
        return swallow
    }

    #if DEBUG
    /// UI tests (`--chirp-hwkey-seam`): the shortcut's own key pressed or let go, through the same path as a `UIPress`.
    /// XCUITest can hold only the left modifiers and cannot press Right ⌥ (or Esc after it) on its own.
    static var seam: Bool { ProcessInfo.processInfo.arguments.contains("--chirp-ui-test") && ProcessInfo.processInfo.arguments.contains("--chirp-hwkey-seam") }
    func simulate(began: Bool, key: Int? = nil, modifiers: HardwareShortcut.Modifiers? = nil) {
        let key = key ?? shortcut.key
        if began { _ = self.began(key, modifiers ?? (HIDKey.modifier(of: key) ?? shortcut.modifiers)) } else { _ = ended(key) }
    }
    #endif

    private func began(_ key: Int, _ modifiers: HardwareShortcut.Modifiers) -> Bool {
        if recorder != nil {
            if let result = recorder?.began(key: key, modifiers: modifiers) { recorded(result) }
            return !HIDKey.isModifier(key)
        }
        if key == HIDKey.escape, active, let model, [.connecting, .listening].contains(model.phase) {
            cancelDictation()
            return true
        }
        guard shortcut.enabled else { return false }
        let outcome = matcher.began(key: key, modifiers: modifiers)
        if let action = outcome.action { act(action) }
        return outcome.swallow
    }

    private func ended(_ key: Int) -> Bool {
        if recorder != nil {
            if let result = recorder?.ended(key: key) { recorded(result) }
            return !HIDKey.isModifier(key)
        }
        let outcome = matcher.ended(key: key)
        if let action = outcome.action { act(action) }
        return outcome.swallow
    }

    private func recorded(_ result: HardwareShortcutRecorder.Result) {
        switch result {
        case .recorded(let new): stopRecording(); rejection = nil; update(new.with(mode: shortcut.mode, enabled: true))
        case .rejected(let why): rejection = why.reason
        case .cancelled: stopRecording()
        }
    }

    private func act(_ action: HardwareShortcutMatcher.Action) {
        let now = ProcessInfo.processInfo.systemUptime
        run(gesture.handle(action, at: now))
        guard action == .down, gesture.needsArmTimer else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(HotkeyGesture.armDelay))
            guard let self else { return }
            self.run(self.gesture.armDue(pressedAt: now, at: ProcessInfo.processInfo.systemUptime))
        }
    }

    private func lostKeyboard() {
        if let action = matcher.reset().action { act(action) }
    }

    /// Settings changed mid-press: drop the press without acting on it.
    private func cancelPress() {
        _ = matcher.reset()
        gesture = HardwareShortcutGesture(shortcut: shortcut)
    }

    // MARK: Dictation

    private var busy: Bool { [.connecting, .listening, .correcting].contains(model?.phase ?? .idle) }

    func run(_ commands: [HardwareShortcutCommand]) {
        for command in commands {
            switch command {
            case .start: if !notesTook() { start() }
            case .stop: if active { model?.stopDictation() }
            case .cancel: if active { cancelDictation() }
            case .toggle: if active { model?.stopDictation() } else if !notesTook() { start() }
            }
        }
    }

    /// A press goes to Notes when the Notes tab is on screen (record, pause, resume), whatever field has focus, as in
    /// the Mac's Notes window; a dictation under way keeps the key.
    private func notesTook() -> Bool {
        guard let notesKey else { return false }
        return notesKey(active || busy)
    }

    private func start() {
        guard let model, !active, !busy, model.paired, !model.working else { return }
        let id = UUID()
        utterance = id; active = true
        field = Self.focusedField()
        intoField = field != nil
        if !intoField { showDictate?() }
        Task {
            do { try await model.begin(source: .app, id: id, autoStop: shortcut.mode != .hold) }
            catch {
                guard utterance == id else { return }
                finish(); model.show(error)
            }
        }
    }

    private func cancelDictation() {
        model?.cancelDictation()
        finish()
    }

    private func phaseChanged(_ phase: SessionPhase) {
        guard active, let model else { return }
        switch phase {
        case .finished:
            let text = LongText.join([model.earlierText, model.text].filter { !$0.isEmpty })
            if let field, !text.isEmpty { Self.insert(text, into: field) }
            finish()
        // Starting without a session arms one first: `.armed` only ends the dictation once it was under way.
        case .armed: if begun { finish() }
        case .idle, .failed: finish()
        case .connecting, .listening, .correcting: begun = true
        }
    }

    private func finish() { active = false; begun = false; intoField = false; field = nil; utterance = nil }

    // MARK: The focused field

    private static weak var found: UIResponder?

    /// The text field or view that has keyboard focus, found the public way: an action sent to nil goes to it.
    static func focusedField() -> UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.chirpReportFirstResponder), to: nil, from: nil, for: nil)
        // Text fields and views only (SwiftUI's TextField and TextEditor are these): SwiftUI's own responders can
        // adopt the text protocols too. Never a password field.
        guard let view = found as? UIView, view is UITextField || view is UITextView, let input = view as? UITextInput,
              input.isSecureTextEntry != true, onScreen(view) else { return nil }
        return view
    }

    /// A field on another tab can keep focus while out of sight; only one the user can see takes the text.
    private static func onScreen(_ view: UIView) -> Bool {
        guard let window = view.window, window.isKeyWindow else { return false }
        var node: UIView? = view
        while let current = node {
            if current.isHidden || current.alpha < 0.01 { return false }
            node = current.superview
        }
        return view.convert(view.bounds, to: window).intersects(window.bounds)
    }

    fileprivate static func report(_ responder: UIResponder) { found = responder }

    /// Types the text at the caret like the keyboard would, with a space first after a word.
    static func insert(_ text: String, into responder: UIResponder) {
        guard let input = responder as? (UIResponder & UITextInput) else { return }
        var piece = text
        if let range = input.selectedTextRange, let before = input.position(from: range.start, offset: -1),
           let previous = input.textRange(from: before, to: range.start).flatMap(input.text(in:)),
           let last = previous.last, !last.isWhitespace, !piece.hasPrefix(" ") {
            piece = " " + piece
        }
        input.insertText(piece)
    }
}

extension UIResponder {
    @objc fileprivate func chirpReportFirstResponder() { HardwareShortcutController.report(self) }
}

/// While a shortcut dictation goes into a field: a slim bar at the bottom with the live words and how to finish.
struct ShortcutListeningBar: ViewModifier {
    @ObservedObject var model: SessionCoordinator
    @ObservedObject var shortcuts: HardwareShortcutController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if shortcuts.active, shortcuts.intoField { bar.padding(.horizontal, ChirpSpacing.s16).padding(.bottom, ChirpSpacing.s24).frame(maxWidth: 640) }
        }
    }

    private var status: String {
        switch model.phase {
        case .connecting: "Connecting…"
        case .correcting: "Polishing…"
        default: "Listening…"
        }
    }

    private var hint: String {
        shortcuts.shortcut.mode == .hold ? "Let go of \(shortcuts.shortcut.title) to insert · ⌘. cancels"
            : "Press \(shortcuts.shortcut.title) again to insert · ⌘. cancels"
    }

    private var bar: some View {
        HStack(spacing: ChirpSpacing.s12) {
            Ripple(level: 0.35, reduceMotion: reduceMotion || model.phase != .listening).frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.text.isEmpty ? status : model.text).font(.body).foregroundStyle(Color.chirp.ink)
                    .lineLimit(2).truncationMode(.head)
                    .accessibilityIdentifier("chirp.hwkey.live")
                Text(hint).font(.footnote).foregroundStyle(Color.chirp.inkMuted).lineLimit(1).minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ChirpSpacing.s16).padding(.vertical, ChirpSpacing.s12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: ChirpRadius.panel, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(status) \(hint)")
        .accessibilityIdentifier("chirp.hwkey.listening")
    }
}

/// Settings → Dictation → Hardware keyboard shortcut: the switch, the recorder, hold or toggle, and how to dictate from
/// other apps with a key.
struct HardwareShortcutSettings: View {
    @ObservedObject var shortcuts: HardwareShortcutController
    @ObservedObject var model: SessionCoordinator
    @AppStorage(DictationKey.workedKey) private var keyWorked = false
    @State private var keySetup = false
    private var shortcut: HardwareShortcut { shortcuts.shortcut }

    var body: some View {
        SettingsPageScroll {
            SettingsGroup {
                SwitchRow(title: "Keyboard shortcut", isOn: shortcut.enabled,
                          summary: shortcut.enabled ? shortcut.instruction : "Off",
                          symbol: "keyboard",
                          infoTitle: "Keyboard shortcut",
                          infoBody: "Works with a hardware keyboard while Chirp is open. The text goes into the Chirp field you are typing in, or onto Dictate when no field has focus. ⌘. cancels. A modifier key on its own only counts when you press no other key with it, so ⌥ shortcuts and special characters keep working.",
                          identifier: "chirp.hwkey.enabled",
                          set: { shortcuts.update(shortcut.with(enabled: $0)) })
            }
            if shortcut.enabled {
                SettingsGroup(title: "Shortcut") {
                    Button {
                        if shortcuts.recording { shortcuts.stopRecording() } else { shortcuts.startRecording() }
                    } label: {
                        RowTile(hasSummary: true) {
                            RowText(title: shortcuts.recording ? "Press the keys…" : shortcut.title,
                                    summary: shortcuts.recording ? "A modifier key on its own, such as Right ⌘, or a key with ⌃, ⌥ or ⌘. Esc stops."
                                        : "Tap to record another",
                                    symbol: shortcuts.recording ? "record.circle" : "command",
                                    color: shortcuts.recording ? Color.chirp.record : Color.chirp.ink)
                            Spacer(minLength: 0)
                        }
                    }
                    .buttonStyle(.rowPress)
                    .accessibilityLabel(shortcuts.recording ? "Press the keys…" : shortcut.title)
                    .accessibilityHint(shortcuts.recording ? "Press the new shortcut, or Esc to stop" : "Records another shortcut")
                    .accessibilityIdentifier("chirp.hwkey.record")
                    if let rejection = shortcuts.rejection {
                        SettingsItem {
                            Label(rejection, systemImage: "exclamationmark.circle").font(.subheadline)
                                .foregroundStyle(Color.chirp.record).accessibilityIdentifier("chirp.hwkey.rejection")
                        }
                    }
                    if shortcut.key != HardwareShortcut.standard.key {
                        ActionRow(title: "Use Right ⌥ Option", symbol: "arrow.counterclockwise", identifier: "chirp.hwkey.reset") {
                            shortcuts.update(HardwareShortcut.standard.with(mode: shortcut.mode))
                        }
                    }
                }
                SettingsGroup(title: "Mode") {
                    SettingsItem {
                        ChoiceChips(options: HardwareShortcut.Mode.allCases,
                                    selection: Binding(get: { shortcut.mode }, set: { shortcuts.update(shortcut.with(mode: $0)) }),
                                    label: { $0 == .hold ? "Hold to talk" : "Press to start and stop" })
                            .accessibilityIdentifier("chirp.hwkey.mode")
                    }
                }
            }
            SettingsGroup(title: "In other apps") {
                ActionRow(title: "Set up a dictation key",
                          summary: keyWorked ? "Toggle Chirp dictation has run" : "One key to start and stop dictation in any app",
                          symbol: keyWorked ? "checkmark.circle" : "command", identifier: "chirp.hwkey.setupKey") { keySetup = true }
                SettingsItem { HardwareKeyboardOtherAppsGuide() }
            }
        }
        .sheet(isPresented: $keySetup) { DictationKeySetup(model: model) }
        .navigationTitle("Hardware keyboard")
        .onDisappear { shortcuts.stopRecording() }
    }
}

/// Outside Chirp only a press-to-start-and-stop key is possible (#259): iPadOS has no system-wide keys for apps, and
/// a keyboard extension such as Chirp Keyboard never receives hardware key presses. Set up a dictation key gives the
/// steps; this is the why.
struct HardwareKeyboardOtherAppsGuide: View {
    var body: some View {
        VStack(alignment: .leading, spacing: ChirpSpacing.s8) {
            Text("Outside Chirp a key can start and stop dictation, but not hold to talk: iPadOS has no system-wide keys for apps, and on-screen keyboards such as Chirp Keyboard don’t receive hardware keys. The key runs Toggle Chirp dictation through Full Keyboard Access; the text is copied for ⌘V.")
            Text("Without a key, press ⌘Space in any app, type Toggle dictation and press Return.")
        }
        .font(.footnote).foregroundStyle(Color.chirp.inkMuted)
        .padding(.vertical, ChirpSpacing.s4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chirp.hwkey.otherApps")
    }
}

#if DEBUG
/// UI tests only (`--chirp-hwkey-seam`): the test runner presses and lets go of keys with Darwin notifications
/// (`dev.chirp.ios.debug.hwkey.down`, `up`, `escape`, `rightCommand`), fed to `simulate` like a `UIPress`, and
/// `toggle` runs Toggle Chirp dictation as a Full Keyboard Access key would. Nothing to
/// tap, so no bar or keyboard over it can swallow a press.
@MainActor enum HardwareShortcutSeam {
    private static var observations: [DarwinObservation] = []

    static func start() {
        guard HardwareShortcutController.seam, observations.isEmpty else { return }
        observations = ["down", "up", "escape", "rightCommand", "toggle"].map { name in
            DarwinSignal(name: "dev.chirp.ios.debug.hwkey." + name).observe { Task { @MainActor in fire(name) } }
        }
    }

    private static func fire(_ name: String) {
        let shortcuts = HardwareShortcutController.shared
        switch name {
        case "down": shortcuts.simulate(began: true)
        case "up": shortcuts.simulate(began: false)
        case "escape": shortcuts.simulate(began: true, key: HIDKey.escape, modifiers: [])
        // A Full Keyboard Access key running Toggle Chirp dictation (the intent's own path).
        case "toggle": Task { _ = try? await shortcuts.debugModel?.perform(action: .toggle) }
        default:
            // Right ⌘ pressed and let go on its own (what the recorder records).
            shortcuts.simulate(began: true, key: HIDKey.rightCommand, modifiers: .command)
            shortcuts.simulate(began: false, key: HIDKey.rightCommand)
        }
    }
}
#endif
