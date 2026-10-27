import Foundation

/// Turns the hotkey's raw presses into `DictationMachine` events for the chosen mode. A key shortcut passes straight
/// through. A modifier on its own (⌥) is also part of every ⌥← and ⌥-click, so it only counts when used alone: in
/// hold-to-talk it starts once it has been held alone for `armDelay`, and in auto-stop a quick clean tap toggles.
/// A modifier bound to one physical key (Right ⌥) does both in auto-stop: a tap starts a hands-free dictation that
/// ends on a pause or the next tap, while holding it past `tapLimit` talks like hold-to-talk, and letting go finishes.
public struct HotkeyGesture: Sendable {
    /// Hold-to-talk with a modifier: how long it must be held alone before the dictation starts.
    public static let armDelay: TimeInterval = 0.2
    /// Auto-stop with a modifier: a longer press is someone holding ⌥ for something else.
    public static let tapLimit: TimeInterval = 0.5

    public let mode: ActivationMode
    public let modifierOnly: Bool
    /// Auto-stop with one side's modifier: the dictation starts once held alone, and a long hold ends on release.
    public let holdOrTap: Bool
    /// The shortcut is one physical modifier key (Right ⌥), in either mode: its dictation starts up to `armDelay` (or a
    /// tap) after the press, so the owner opens the microphone on the press itself and keeps that audio in memory until
    /// the dictation starts, or drops it unsent when the press turns out to be a chord or an early release. Never for a
    /// modifier on both sides (⌥), which types special characters all day.
    public let opensMicOnPress: Bool
    private var pressedAt: TimeInterval?
    /// Hold-to-talk with a modifier: the delayed press has reached the machine.
    private var armed = false

    /// `singleKey`: the shortcut is one physical modifier key (`KeyCombo.isSingleModifierKey`), so the other side's key,
    /// which types special characters, never reaches it.
    public init(mode: ActivationMode = .autoStop, modifierOnly: Bool = false, singleKey: Bool = false) {
        self.mode = mode
        self.modifierOnly = modifierOnly
        holdOrTap = modifierOnly && singleKey && mode == .autoStop
        opensMicOnPress = modifierOnly && singleKey
    }

    /// The owner calls `armDue(pressedAt:at:)` `armDelay` after a press.
    public var needsArmTimer: Bool { modifierOnly && (mode == .holdToTalk || holdOrTap) }

    public mutating func down(at t: TimeInterval) -> [DictationEvent] {
        guard modifierOnly else { return [.hotkeyDown(at: t)] }
        pressedAt = t
        armed = false
        return []
    }

    /// The arm timer for the press at `pressedAt` fired: still held alone, so the dictation starts now.
    public mutating func armDue(pressedAt start: TimeInterval, at t: TimeInterval) -> [DictationEvent] {
        guard needsArmTimer, pressedAt == start, !armed else { return [] }
        armed = true
        return [.hotkeyDown(at: t)]
    }

    public mutating func up(at t: TimeInterval) -> [DictationEvent] {
        guard modifierOnly else { return [.hotkeyUp(at: t)] }
        defer { pressedAt = nil; armed = false }
        guard let start = pressedAt else { return [] }
        switch mode {
        case .holdToTalk: return armed ? [.hotkeyUp(at: t)] : []
        case .autoStop:
            if holdOrTap, armed {
                // A tap leaves the dictation running (the release only ends the press); a longer hold finishes it.
                return t - start <= Self.tapLimit ? [.hotkeyUp(at: t)] : [.holdEnd]
            }
            return t - start <= Self.tapLimit ? [.hotkeyDown(at: t), .hotkeyUp(at: t)] : []
        }
    }

    public mutating func chord() -> [DictationEvent] {
        defer { pressedAt = nil; armed = false }
        guard modifierOnly else { return [.hotkeyChord] }
        return armed ? [.hotkeyChord] : []
    }
}

/// Auto-stop: fires once when the speaker has been quiet for `silence` seconds after speaking, or has not spoken
/// within `noSpeechTimeout`. Speech is judged against the room's own noise floor, which follows the quietest
/// frames at once and rises only slowly, so steady background noise never counts as talking.
public struct AutoStopDetector: Sendable {
    public static let defaultSilence: TimeInterval = 2
    /// The pauses offered in Settings, in seconds.
    public static let silenceChoices: [TimeInterval] = [1, 1.5, 2, 3, 5]
    public static let noSpeechTimeout: TimeInterval = 10
    /// Below this RMS (about −40 dBFS) nothing is speech, however quiet the room.
    static let minimumSpeech: Float = 0.01
    /// Speech is this many times the noise floor.
    static let speechRatio: Float = 3

    public let silence: TimeInterval
    private var floor: Float?
    private var startedAt: TimeInterval?
    private var lastSpeech: TimeInterval?
    private var fired = false

    public init(silence: TimeInterval = AutoStopDetector.defaultSilence) { self.silence = silence }

    public mutating func feed(_ level: Level, at time: TimeInterval) -> Bool {
        guard !fired else { return false }
        let rms = level.rms
        let start = startedAt ?? time
        startedAt = start
        let current = floor ?? rms
        floor = rms < current ? rms : current + (rms - current) * 0.002
        if rms >= max(Self.minimumSpeech, current * Self.speechRatio) { lastSpeech = time }
        if let lastSpeech {
            if time - lastSpeech >= silence { fired = true }
        } else if time - start >= Self.noSpeechTimeout {
            fired = true
        }
        return fired
    }
}
