import AppKit
import ChirpCore

/// A global shortcut that runs one action from any app: Paste Last Dictation (⌃⌥V) and Dictation History (⌃⌥H) by
/// default. Like the other hotkeys it follows the menu's main switch, and the Settings recorder releases it while it
/// listens.
@MainActor
final class ActionHotkey {
    let shortcut: ChirpShortcut
    private let id: UInt32
    var action: () -> Void = {}
    var onChange: (() -> Void)?

    init(_ shortcut: ChirpShortcut, id: UInt32) {
        self.shortcut = shortcut
        self.id = id
    }

    private(set) lazy var gate = PauseGate(
        register: { [weak self] in
            guard let self else { return false }
            return HotKeyCenter.shared.register(id: self.id, combo: settings[shortcut: self.shortcut],
                                                onDown: { [weak self] in self?.action() })
        },
        unregister: { [weak self] in if let self { HotKeyCenter.shared.unregister(id: self.id) } },
        onChange: { [weak self] in self?.onChange?() })

    @discardableResult
    func register() -> Bool { gate.registerHotkey() }
    func suspend() { gate.suspendHotkey() }
    func setRunning(_ running: Bool) { gate.setRunning(running) }
    /// The shortcut for the menu, or nil while it is not registered (paused, or another app owns it).
    var title: String? { gate.hotkeyRegistered ? settings[shortcut: shortcut].title : nil }
}
