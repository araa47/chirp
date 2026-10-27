import Foundation

/// The dictation microphone between hotkey-down and the socket. It opens the moment a dictation starts and never waits
/// for the start cue: the cue's window is zeroed in what is sent instead (`excludeCue`), so sounds on or off, the first
/// sample is captured at the same time.
///
/// Frames captured before a dictation attaches its sink stay here, in memory only, bounded to `preRollLimit` (the
/// oldest are dropped first). `attach` sends them first, in order; `close` without a sink drops them unsent.
public final class DictationMic: @unchecked Sendable {
    /// At most this much audio is held before a sink is attached.
    public static let preRollLimit: TimeInterval = 1
    /// A frame that arrives this much later than its samples' time means the input heard nothing for a while (a route
    /// change stopped it, or it was slow to start): longer than a capture buffer (2048 samples at 8 kHz) plus latency.
    static let gapTolerance: TimeInterval = 0.35

    private let capture: AudioCapture
    private let now: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var held: [(position: Int, frame: Data)] = []
    private var heldBytes = 0
    private var sink: (@Sendable (Data, Bool) -> Void)?
    private var onFailure: (@Sendable () -> Void)?
    /// Samples captured since the microphone opened, including any dropped from the pre-roll.
    private var samples = 0
    /// Samples' worth of time the input heard nothing since it opened (`gapTolerance`): a sample's time is `anchor` plus
    /// its offset plus this, so the cue is zeroed where it was heard.
    private var lost = 0
    /// The uptime of sample 0, and of the first frame's arrival.
    private var anchor: TimeInterval?
    private var firstFrame: TimeInterval?
    /// The start cue, in uptime: what the microphone hears in it is zeroed.
    private var cue: (start: TimeInterval, end: TimeInterval)?

    public init(capture: AudioCapture, now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.capture = capture
        self.now = now
    }

    public var isOpen: Bool { capture.isRunning }
    /// When the microphone opened (its first sample), and when the first frame arrived; nil until then.
    public var openedAt: TimeInterval? { lock.withLock { anchor } }
    public var firstFrameAt: TimeInterval? { lock.withLock { firstFrame } }

    /// Opens the microphone into the pre-roll. Does nothing when it is already open.
    public func open() throws {
        guard !isOpen else { return }
        lock.withLock {
            held = []; heldBytes = 0; samples = 0; lost = 0; anchor = nil; firstFrame = nil; sink = nil; onFailure = nil
        }
        try capture.start(onFailure: { [weak self] in
            guard let self else { return }
            let failure = self.lock.withLock { self.onFailure }
            self.close()
            failure?()
        }) { [weak self] frame in self?.receive(frame) }
        // Sample 0 was captured as the input started, which is when `start` returns (unless a frame came first).
        let t = now()
        lock.withLock { if anchor == nil { anchor = t } }
    }

    /// Zeroes the `length` seconds that follow `start` (uptime) in what is sent: the start cue, so it is never
    /// transcribed. Speech inside that window is lost with it; everything around it is kept.
    public func excludeCue(at start: TimeInterval, length: TimeInterval) {
        lock.withLock { cue = length > 0 ? (start, start + length) : nil }
    }

    /// Hands every frame to `sink` from now on, after the pre-roll (in order). `sink` gets each frame and whether all
    /// of it was zeroed for the cue. `onFailure` runs when the input stops and cannot be rebuilt.
    public func attach(onFailure: (@Sendable () -> Void)? = nil, _ sink: @escaping @Sendable (Data, Bool) -> Void) {
        lock.withLock {
            self.onFailure = onFailure
            for (position, frame) in held {
                let (out, muted) = mute(frame, at: position)
                sink(out, muted)
            }
            held = []; heldBytes = 0
            self.sink = sink
        }
    }

    /// Stops the microphone. With a sink, the trailing frame goes to it; without one, the pre-roll is dropped unsent.
    public func close() {
        capture.stop()
        lock.withLock { held = []; heldBytes = 0; sink = nil; onFailure = nil; cue = nil }
    }

    // On the audio thread. The sink runs under the lock, so a frame never overtakes the pre-roll being flushed.
    private func receive(_ frame: Data) {
        let t = now()
        lock.withLock {
            let rate = PCMConverter.sampleRate
            let offset = samples
            samples += frame.count / 2
            if firstFrame == nil { firstFrame = t }
            if anchor == nil { anchor = t - Double(frame.count / 2) / rate }
            // Late by more than a buffer: the input stopped or started late. This frame ends as it arrives.
            if let anchor {
                let late = t - (anchor + Double(samples + lost) / rate)
                if late > Self.gapTolerance { lost += Int((late * rate).rounded()) }
            }
            let position = offset + lost
            guard let sink else {
                held.append((position, frame))
                heldBytes += frame.count
                let limit = Int(Self.preRollLimit * PCMConverter.sampleRate) * 2
                while heldBytes > limit, !held.isEmpty { heldBytes -= held.removeFirst().frame.count }
                return
            }
            let (out, muted) = mute(frame, at: position)
            sink(out, muted)
        }
    }

    /// `frame` (starting `position` samples after `anchor`) with the cue's samples zeroed, and whether all of it was.
    private func mute(_ frame: Data, at position: Int) -> (Data, Bool) {
        let count = frame.count / 2
        guard let cue, let anchor, count > 0 else { return (frame, false) }
        let rate = PCMConverter.sampleRate
        let from = max(0, Int(((cue.start - anchor) * rate).rounded(.down)) - position)
        let to = min(count, Int(((cue.end - anchor) * rate).rounded(.up)) - position)
        guard from < to else { return (frame, false) }
        // A copy from index 0: capture frames can be slices with a nonzero startIndex.
        var out = frame.withUnsafeBytes { Data($0) }
        out.resetBytes(in: (from * 2)..<(to * 2))
        return (out, from == 0 && to == count)
    }
}
