import Foundation

/// The Mac dictation's audio-thread end: forwards each frame to the socket in order, measures its level and runs the
/// detectors that can end a dictation on their own. The clock is the audio itself (50 ms per frame), so tests drive it
/// with frames.
///
/// - Auto-stop's pause (`AutoStopDetector`, auto-stop mode only) calls `onAutoStop`.
/// - Digital silence (`SilenceGuard`: a muted device or a denied microphone) calls `onSilence`.
/// - The ten-minute ceiling calls `onLimit`.
///
/// "Keep listening until I stop" (`continuous`) turns off the pause and the ceiling, and the silence guard fires only
/// before the microphone has carried any signal: after that, digital silence is a pause.
public final class DictationCaptureSink: @unchecked Sendable {
    /// Total capture ceiling; the rolling session cuts segments below the protocol limit.
    public static let limitSeconds = RollingDictationSegmenter.maxTotal

    private let send: @Sendable (Data) -> Void
    private let onLevel: @Sendable (Level, TimeInterval) -> Void
    private let onSilence: @Sendable () -> Void
    private let onAutoStop: @Sendable () -> Void
    private let onLimit: @Sendable () -> Void
    private let lock = NSLock()
    private let limit: TimeInterval?
    private var limitSent = false
    private var guardState: SilenceGuard
    private var autoStop: AutoStopDetector?
    private var clock: TimeInterval = 0

    public init(mode: ActivationMode, continuous: Bool, autoStopSilence: TimeInterval, send: @escaping @Sendable (Data) -> Void,
                onLevel: @escaping @Sendable (Level, TimeInterval) -> Void, onSilence: @escaping @Sendable () -> Void,
                onAutoStop: @escaping @Sendable () -> Void = {}, onLimit: @escaping @Sendable () -> Void = {}) {
        self.send = send
        self.onLevel = onLevel
        self.onSilence = onSilence
        self.onAutoStop = onAutoStop
        self.onLimit = onLimit
        autoStop = mode == .autoStop && !continuous ? AutoStopDetector(silence: autoStopSilence) : nil
        guardState = SilenceGuard(onlyBeforeSignal: continuous)
        limit = continuous ? nil : Self.limitSeconds
    }

    /// `muted`: the frame was zeroed for the start cue. It is sent and counted, but the silence and auto-stop
    /// detectors do not hear it (as before, when the microphone opened after the cue).
    public func handle(_ frame: Data, muted: Bool = false) {
        send(frame)
        let level = muted ? .zero : Level(pcm16: frame)
        let (silent, paused, limited, elapsed) = lock.withLock { () -> (Bool, Bool, Bool, TimeInterval) in
            clock += Double(frame.count / 2) / PCMConverter.sampleRate
            let limited = !limitSent && limit.map { clock >= $0 } == true
            if limited { limitSent = true }
            guard !muted else { return (false, false, limited, clock) }
            return (guardState.feed(level, at: clock), autoStop?.feed(level, at: clock) ?? false, limited, clock)
        }
        onLevel(level, elapsed)
        if silent { onSilence() }
        if paused { onAutoStop() }
        if limited { onLimit() }
    }

    /// The HUD's clock: "2:01 / 10:00", or just "2:01" (then "1:02:03") when there is no ceiling.
    public static func durationLabel(_ seconds: TimeInterval, continuous: Bool) -> String {
        guard continuous else {
            let total = min(Int(seconds), Int(limitSeconds))
            return String(format: "%d:%02d / 10:00", total / 60, total % 60)
        }
        let total = max(0, Int(seconds))
        let (h, m, s) = (total / 3600, total % 3600 / 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
