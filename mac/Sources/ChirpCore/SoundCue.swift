import Foundation

/// The optional start/stop sounds: two short, quiet system sounds, never custom audio.
public enum SoundCue: Equatable, Sendable {
    case start, stop

    /// Names of sounds in /System/Library/Sounds (loaded with `NSSound(named:)`).
    public var systemSoundName: String {
        switch self {
        case .start: "Tink"
        case .stop: "Pop"
        }
    }

    /// The cue a state change plays, if any. Start sounds at the beginning of a dictation, as the microphone opens
    /// (dictation zeroes the cue's window in what it sends); stop when capture ends. Errors, cancels and insertion
    /// stay silent.
    public static func cue(from old: DictationState, to new: DictationState, enabled: Bool) -> SoundCue? {
        guard enabled, old != new else { return nil }
        switch (old, new) {
        case (.idle, .connecting), (.error, .connecting): return .start
        case (.connecting, .finalizing), (.listening, .finalizing): return .stop
        default: return nil
        }
    }
}
