#if os(macOS)
import Carbon.HIToolbox

/// Chirp's global shortcuts, each recorded in Settings › Shortcuts with the same rules (`HotKeyValidation`) and
/// refused when another of them already has the keys.
public enum ChirpShortcut: String, CaseIterable, Sendable {
    case dictation, notes, openNotes, useRaw, pasteLast, openHistory

    /// What it does, as the recorder's "Already used for …" names it.
    public var owner: String {
        switch self {
        case .dictation: "dictation"
        case .notes: "Start/Stop Notes"
        case .openNotes: "Open Notes"
        case .useRaw: "Use raw"
        case .pasteLast: "Paste Last Dictation"
        case .openHistory: "Dictation History"
        }
    }

    public var defaultCombo: KeyCombo {
        switch self {
        case .dictation: .defaultDictation
        case .notes: .controlOptionN
        case .openNotes: .controlOptionShiftN
        case .useRaw: .controlOptionZ
        case .pasteLast: .controlOptionV
        case .openHistory: .controlOptionH
        }
    }

    /// The others with their current keys, for `HotKeyValidation.conflict` while this one is recorded.
    public func taken(_ current: (ChirpShortcut) -> KeyCombo) -> [(owner: String, combo: KeyCombo)] {
        Self.allCases.filter { $0 != self }.map { ($0.owner, current($0)) }
    }

    /// Why `combo` cannot be this shortcut because another one has it, or nil.
    public func conflict(_ combo: KeyCombo, current: (ChirpShortcut) -> KeyCombo) -> HotKeyValidation.Rejection? {
        HotKeyValidation.conflict(combo, with: taken(current))
    }
}

extension KeyCombo {
    /// "Use raw" default: puts the original words back for 5 s after a cleaned insertion.
    public static let controlOptionZ = KeyCombo.custom(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(controlKey | optionKey))
    /// "Paste Last Dictation" default: the newest dictation into the focused field again, from any app.
    public static let controlOptionV = KeyCombo.custom(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey))
    /// "Dictation History" default: opens the History window from any app.
    public static let controlOptionH = KeyCombo.custom(keyCode: UInt32(kVK_ANSI_H), modifiers: UInt32(controlKey | optionKey))

    /// The same keys, whether stored as a preset or as a recorded shortcut.
    public func sameKeys(_ other: KeyCombo) -> Bool { keyCode == other.keyCode && modifiers == other.modifiers }
}
#endif
