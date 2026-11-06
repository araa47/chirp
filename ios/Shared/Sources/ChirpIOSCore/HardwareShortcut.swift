import ChirpCore
import Foundation

/// The hardware-keyboard dictation shortcut in the app (#259): one modifier key on its own (Right ⌥ by default) or a
/// key with modifiers, held to talk or pressed to start and stop. Keys are USB HID usages (`UIKeyboardHIDUsage` raw
/// values) and modifiers are `UIKeyModifierFlags` bits, so this stays UIKit-free and testable on the Mac.
public struct HardwareShortcut: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        /// Talk while the keys are held; letting go inserts.
        case hold
        /// A press starts, the next press inserts.
        case toggle
    }

    /// `UIKeyModifierFlags` raw values for ⇧⌃⌥⌘ (caps lock and the keypad flag are never part of a shortcut).
    public struct Modifiers: OptionSet, Codable, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1 << 17)
        public static let control = Modifiers(rawValue: 1 << 18)
        public static let option = Modifiers(rawValue: 1 << 19)
        public static let command = Modifiers(rawValue: 1 << 20)
        public static let relevant: Modifiers = [.shift, .control, .option, .command]

        /// ⌃⌥⇧⌘ in the order Apple writes them.
        public var symbols: String {
            (contains(.control) ? "⌃" : "") + (contains(.option) ? "⌥" : "") + (contains(.shift) ? "⇧" : "") + (contains(.command) ? "⌘" : "")
        }
    }

    public var key: Int
    /// Empty for a modifier key on its own.
    public var modifiers: Modifiers
    public var mode: Mode
    public var enabled: Bool

    public init(key: Int, modifiers: Modifiers = [], mode: Mode = .hold, enabled: Bool = true) {
        self.key = key
        self.modifiers = HIDKey.isModifier(key) ? [] : modifiers.intersection(.relevant)
        self.mode = mode
        self.enabled = enabled
    }

    /// Right ⌥ on its own, held to talk: the Mac's default, and the left ⌥ keeps typing special characters.
    public static let standard = HardwareShortcut(key: HIDKey.rightOption)

    /// One modifier key pressed on its own (Right ⌥, Right ⌘…), with no other key.
    public var isModifierOnly: Bool { HIDKey.isModifier(key) }

    /// "Right ⌥ Option", "⌥Space", "⌃⌥D".
    public var title: String { isModifierOnly ? HIDKey.name(key) : modifiers.symbols + HIDKey.name(key) }

    /// What the menu and Settings say the shortcut does.
    public var instruction: String {
        switch mode {
        case .hold: "Hold \(title) to dictate. Let go to insert."
        case .toggle: "Press \(title) to dictate. Press it again to insert."
        }
    }

    /// The same keys with another mode or switch.
    public func with(mode: Mode? = nil, enabled: Bool? = nil) -> HardwareShortcut {
        HardwareShortcut(key: key, modifiers: modifiers, mode: mode ?? self.mode, enabled: enabled ?? self.enabled)
    }

    /// The stored shortcut, or the default when there is none or it can no longer fire (a file edited by hand).
    public static func resolve(_ stored: HardwareShortcut?) -> HardwareShortcut {
        guard let stored else { return .standard }
        guard case .success = HardwareShortcutValidation.validate(key: stored.key, modifiers: stored.modifiers) else {
            return standard.with(mode: stored.mode, enabled: stored.enabled)
        }
        return stored
    }
}

/// USB HID keyboard usages (`UIKeyboardHIDUsage`) the shortcut names. The shortcut is stored as a key, not a character,
/// like the Mac's key codes.
public enum HIDKey {
    public static let escape = 0x29
    public static let space = 0x2C
    public static let capsLock = 0x39
    public static let leftControl = 0xE0, leftShift = 0xE1, leftOption = 0xE2, leftCommand = 0xE3
    public static let rightControl = 0xE4, rightShift = 0xE5, rightOption = 0xE6, rightCommand = 0xE7

    public static func isModifier(_ key: Int) -> Bool { (leftControl...rightCommand).contains(key) }

    /// The held keys without modifier keys whose flag is no longer down: a release lost while Chirp was not
    /// receiving keys must not leave ⌥ "held" forever.
    static func pruned(_ held: Set<Int>, modifiers: HardwareShortcut.Modifiers) -> Set<Int> {
        held.filter { key in modifier(of: key).map { modifiers.contains($0) } ?? true }
    }
    public static func isShift(_ key: Int) -> Bool { key == leftShift || key == rightShift }

    /// The modifier flag a modifier key sets.
    public static func modifier(of key: Int) -> HardwareShortcut.Modifiers? {
        switch key {
        case leftControl, rightControl: .control
        case leftShift, rightShift: .shift
        case leftOption, rightOption: .option
        case leftCommand, rightCommand: .command
        default: nil
        }
    }

    /// F1–F24 neither type nor move the cursor, so they alone may start a dictation.
    public static func isFunctionKey(_ key: Int) -> Bool { (0x3A...0x45).contains(key) || (0x68...0x73).contains(key) }

    /// Every other key types, moves the cursor or edits; it needs ⌃, ⌥ or ⌘ to be a shortcut.
    public static func isTypingKey(_ key: Int) -> Bool { !isModifier(key) && !isFunctionKey(key) }

    private static let names: [Int: String] = {
        var names: [Int: String] = [
            leftControl: "Left ⌃ Control", leftShift: "Left ⇧ Shift", leftOption: "Left ⌥ Option", leftCommand: "Left ⌘ Command",
            rightControl: "Right ⌃ Control", rightShift: "Right ⇧ Shift", rightOption: "Right ⌥ Option", rightCommand: "Right ⌘ Command",
            0x28: "Return", escape: "Esc", 0x2A: "Delete", 0x2B: "Tab", space: "Space", 0x2D: "-", 0x2E: "=", 0x2F: "[", 0x30: "]",
            0x31: "\\", 0x33: ";", 0x34: "'", 0x35: "`", 0x36: ",", 0x37: ".", 0x38: "/", capsLock: "Caps Lock",
            0x4A: "Home", 0x4B: "Page Up", 0x4C: "⌦", 0x4D: "End", 0x4E: "Page Down",
            0x4F: "→", 0x50: "←", 0x51: "↓", 0x52: "↑",
        ]
        for (i, letter) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() { names[0x04 + i] = String(letter) }
        for (i, digit) in "1234567890".enumerated() { names[0x1E + i] = String(digit) }
        for i in 0..<12 { names[0x3A + i] = "F\(i + 1)"; names[0x68 + i] = "F\(i + 13)" }
        return names
    }()

    public static func name(_ key: Int) -> String { names[key] ?? "Key \(key)" }

    /// The character a menu's key equivalent uses for this key, when it has one (letters, digits, punctuation, Space).
    public static func character(_ key: Int) -> Character? {
        if key == space { return " " }
        guard let name = names[key], name.count == 1, !isModifier(key) else { return nil }
        return Character(name.lowercased())
    }
}

/// Which recorded shortcuts can start a dictation, and why not. The Mac's rules (`HotKeyValidation`) for iPadOS keys.
public enum HardwareShortcutValidation {
    public enum Rejection: Error, Equatable, Sendable {
        case noModifier, shiftOnly, shiftAlone, escape
        case reserved(String)
        /// Another Chirp shortcut already uses it ("Start Dictation", "Notes").
        case inUse(String)

        /// One sentence for the recorder to show under the field.
        public var reason: String {
            switch self {
            case .noModifier: "On its own this key would stop typing. Add ⌃, ⌥ or ⌘, or press a modifier key alone."
            case .shiftOnly: "⇧ alone would break typing. Add ⌃, ⌥ or ⌘."
            case .shiftAlone: "⇧ on its own is pressed for every capital letter. Try Right ⌥ Option."
            case .escape: "Esc cancels a dictation, so it can’t start one."
            case .reserved(let owner): "iPadOS uses this shortcut for \(owner)."
            case .inUse(let owner): "Already used for \(owner) in Chirp. Pick another."
            }
        }
    }

    private static let reserved: [(key: Int, modifiers: HardwareShortcut.Modifiers, owner: String)] = [
        (HIDKey.space, .command, "Spotlight"),
        (HIDKey.space, .control, "switching keyboard languages"),
        (HIDKey.space, [.control, .command], "Emoji & Symbols"),
        (0x2B, .command, "the app switcher"), (0x2B, [.command, .shift], "the app switcher"),
        (0x0B, .command, "the Home Screen"),
        (0x20, [.command, .shift], "screenshots"), (0x21, [.command, .shift], "screenshots"),
    ]

    /// Chirp's own menu shortcuts (`DictationCommands`, `NavigationCommands`, Notes), which the app keeps working.
    public static let chirpShortcuts: [(key: Int, modifiers: HardwareShortcut.Modifiers, owner: String)] = [
        (0x28, .command, "Start Dictation"), (0x37, .command, "Cancel Dictation"),
        (0x06, [.command, .shift], "Copy Result"), (0x1D, [.control, .option], "Use Raw Transcript"),
        (0x0E, [.command, .shift], "the keyboard session"),
        (0x1E, .command, "Notes"), (0x1F, .command, "Dictate"), (0x20, .command, "History"), (0x21, .command, "Settings"),
        (0x11, .command, "New Note"), (0x11, [.control, .option], "New note and record"), (0x09, .command, "Search notes"),
        (0x15, [.command, .shift], "recording a note"), (0x13, [.command, .shift], "pausing a note"),
        (0x08, [.command, .shift], "Edit by voice"), (0x17, [.command, .option], "the transcript"),
    ]

    /// `modifiers` are the flags held with `key`; a modifier key's own code makes a modifier-only shortcut.
    public static func validate(key: Int, modifiers raw: HardwareShortcut.Modifiers) -> Result<HardwareShortcut, Rejection> {
        if key == HIDKey.escape { return .failure(.escape) }
        if HIDKey.isModifier(key) {
            return HIDKey.isShift(key) ? .failure(.shiftAlone) : .success(HardwareShortcut(key: key))
        }
        let modifiers = raw.intersection(.relevant)
        let typing = HIDKey.isTypingKey(key)
        if modifiers.isEmpty, typing { return .failure(.noModifier) }
        if modifiers == .shift, typing { return .failure(.shiftOnly) }
        if let hit = reserved.first(where: { $0.key == key && $0.modifiers == modifiers }) { return .failure(.reserved(hit.owner)) }
        if let hit = chirpShortcuts.first(where: { $0.key == key && $0.modifiers == modifiers }) { return .failure(.inUse(hit.owner)) }
        return .success(HardwareShortcut(key: key, modifiers: modifiers))
    }
}

/// Matches the shortcut against the app's key presses, with the Mac's `ShortcutMatcher` rules. A key shortcut is down
/// while its key is held with exactly its modifiers, and its presses are swallowed so a focused field never types them.
/// A modifier on its own is never swallowed (it keeps working for everything else): it is down only when pressed
/// with nothing else held, and any other key meanwhile makes it a `chord` (the user meant ⌥← or ⌥E, not
/// dictation); nothing more fires until it is let go. Right ⌥ with Left ⌥ already held is not Right ⌥ alone.
public struct HardwareShortcutMatcher: Sendable {
    public enum Action: Sendable, Equatable { case down, up, chord }
    public struct Outcome: Sendable, Equatable {
        public var action: Action?
        /// Keep the press from the focused field.
        public var swallow = false
        public static let none = Outcome(action: nil)
    }

    private enum Phase: Sendable { case idle, pressed, spoiled }

    public let shortcut: HardwareShortcut
    private var phase = Phase.idle
    private var held: Set<Int> = []

    public init(shortcut: HardwareShortcut) { self.shortcut = shortcut }

    public var isPressed: Bool { phase == .pressed }

    /// A key went down; `modifiers` are the flags UIKit reports with it.
    public mutating func began(key: Int, modifiers: HardwareShortcut.Modifiers) -> Outcome {
        held = HIDKey.pruned(held, modifiers: modifiers)
        let before = held
        held.insert(key)
        if shortcut.isModifierOnly {
            switch phase {
            case .pressed:
                phase = .spoiled
                return Outcome(action: .chord)
            case .spoiled:
                return .none
            case .idle:
                guard key == shortcut.key else { return .none }
                // Anything already held (Left ⌥, ⌘, a letter) means another shortcut: wait for the key to be let go.
                guard before.isEmpty, modifiers.intersection(.relevant).subtracting(HIDKey.modifier(of: key) ?? []).isEmpty else {
                    phase = .spoiled
                    return .none
                }
                phase = .pressed
                return Outcome(action: .down)
            }
        }
        guard key == shortcut.key else { return .none }
        if phase == .pressed { return Outcome(action: nil, swallow: true) }
        guard modifiers.intersection(.relevant) == shortcut.modifiers else { return .none }
        phase = .pressed
        return Outcome(action: .down, swallow: true)
    }

    public mutating func ended(key: Int) -> Outcome {
        held.remove(key)
        if shortcut.isModifierOnly {
            guard key == shortcut.key else { return .none }
            defer { phase = .idle }
            return phase == .pressed ? Outcome(action: .up) : .none
        }
        guard phase == .pressed, key == shortcut.key else { return .none }
        phase = .idle
        return Outcome(action: .up, swallow: true)
    }

    /// The app lost the keyboard (it left the foreground, or UIKit cancelled the presses): keys may be let go unseen,
    /// so a press under way ends as if released.
    public mutating func reset() -> Outcome {
        held = []
        defer { phase = .idle }
        return phase == .pressed ? Outcome(action: .up) : .none
    }
}

/// What the app does with the shortcut.
public enum HardwareShortcutCommand: Sendable, Equatable { case start, stop, cancel, toggle }

/// The matcher's presses turned into dictation commands by the Mac's `HotkeyGesture` timing. Hold: a key shortcut starts
/// on press and inserts on release; a modifier alone starts once held alone for `HotkeyGesture.armDelay`, so a quick
/// ⌥ tap or ⌥← never starts one, and a chord after that cancels. Toggle: a key shortcut toggles on press; a modifier
/// alone toggles on a clean tap of at most `HotkeyGesture.tapLimit`.
public struct HardwareShortcutGesture: Sendable {
    public let mode: HardwareShortcut.Mode
    private var gesture: HotkeyGesture

    public init(shortcut: HardwareShortcut) {
        mode = shortcut.mode
        gesture = HotkeyGesture(mode: shortcut.mode == .hold ? .holdToTalk : .autoStop, modifierOnly: shortcut.isModifierOnly)
    }

    /// The owner calls `armDue(pressedAt:at:)` `HotkeyGesture.armDelay` after a press.
    public var needsArmTimer: Bool { gesture.needsArmTimer }

    public mutating func handle(_ action: HardwareShortcutMatcher.Action, at time: TimeInterval) -> [HardwareShortcutCommand] {
        switch action {
        case .down: commands(gesture.down(at: time))
        case .up: commands(gesture.up(at: time))
        case .chord: commands(gesture.chord())
        }
    }

    public mutating func armDue(pressedAt start: TimeInterval, at time: TimeInterval) -> [HardwareShortcutCommand] {
        commands(gesture.armDue(pressedAt: start, at: time))
    }

    private func commands(_ events: [DictationEvent]) -> [HardwareShortcutCommand] {
        events.compactMap { event in
            switch (mode, event) {
            case (.hold, .hotkeyDown): .start
            case (.hold, .hotkeyUp): .stop
            case (.hold, .hotkeyChord): .cancel
            case (.toggle, .hotkeyDown): .toggle
            default: nil
            }
        }
    }
}

/// The settings recorder: the next shortcut pressed. A key with its modifiers records on press; a modifier key records
/// when it is let go with no other key pressed meanwhile (so ⌥ then Space records ⌥Space, not ⌥). Esc stops recording.
public struct HardwareShortcutRecorder: Sendable {
    public enum Result: Sendable, Equatable {
        case recorded(HardwareShortcut)
        case rejected(HardwareShortcutValidation.Rejection)
        case cancelled
    }

    private var lone: Int?
    private var held: Set<Int> = []

    public init() {}

    public mutating func began(key: Int, modifiers: HardwareShortcut.Modifiers) -> Result? {
        held = HIDKey.pruned(held, modifiers: modifiers)
        let before = held
        held.insert(key)
        if key == HIDKey.escape, modifiers.intersection(.relevant).isEmpty { return .cancelled }
        if HIDKey.isModifier(key) {
            lone = before.isEmpty ? key : nil
            return nil
        }
        lone = nil
        switch HardwareShortcutValidation.validate(key: key, modifiers: modifiers) {
        case .success(let shortcut): return .recorded(shortcut)
        case .failure(let rejection): return .rejected(rejection)
        }
    }

    public mutating func ended(key: Int) -> Result? {
        held.remove(key)
        guard key == lone else { return nil }
        lone = nil
        switch HardwareShortcutValidation.validate(key: key, modifiers: []) {
        case .success(let shortcut): return .recorded(shortcut)
        case .failure(let rejection): return .rejected(rejection)
        }
    }
}
