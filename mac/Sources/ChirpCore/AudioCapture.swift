import AVFoundation
import Foundation

public enum CaptureError: Error { case noInputDevice, converter }

/// The microphone engine behind `AudioCapture`, so start-up failures can be tested without hardware or TCC.
public protocol CaptureEngine: AnyObject {
    /// The input's native format; nil when there is no input device (a 0 Hz or 0-channel format).
    var inputFormat: AVAudioFormat? { get }
    /// Resume an unchanged input without replacing its tap, refreshing `inputName`. False requests a full rebuild.
    func resumeAfterConfigurationChange() -> Bool
    /// Refresh stale graph formats before the input format is read. Preserve a valid graph.
    func resetForCapture()
    func installTap(_ block: @escaping @Sendable (AVAudioPCMBuffer) -> Void)
    func removeTap()
    func prepare()
    func start() throws
    func stop()
    /// Called when the default input changes (e.g. the USB mic is unplugged) and the engine has stopped.
    /// nil removes the handler.
    func setConfigurationChangeHandler(_ handler: (@Sendable () -> Void)?)
    /// The input in use, for "Switched to …" (nil when not known).
    var inputName: String? { get }
    /// The input could not be opened: use the next one to try (the system default, then the built-in microphone).
    /// False when nothing is left to try.
    func fallBack() -> Bool
}

extension CaptureEngine {
    public func resumeAfterConfigurationChange() -> Bool { false }
    public func resetForCapture() {}
    public var inputName: String? { nil }
    public func fallBack() -> Bool { false }
}

/// What happened to the input under a capture that keeps going (Live Notes).
public enum CaptureInputEvent: Equatable, Sendable {
    /// The input went away and capture went on with another one (its name, when known).
    case switched(String?)
    /// No input could be opened: capture waits, and goes on by itself when an input appears (`switched`).
    case lost
}

/// Microphone → 16 kHz mono PCM16 frames. The engine is kept between dictations (so it is ready), but the input is
/// stopped when idle so the mic indicator goes off. Every failure unwinds what was installed, so a retry starts clean.
public final class AudioCapture: @unchecked Sendable {
    private let engine: CaptureEngine
    private let lock = NSLock()
    private var converter: PCMConverter?
    private var onFrame: (@Sendable (Data) -> Void)?
    private var onFailure: (@Sendable () -> Void)?
    /// Set for a capture that survives losing its input: rebuilds fall back, then wait for an input.
    private var onInput: (@Sendable (CaptureInputEvent) -> Void)?
    /// No input could be opened; the next configuration change tries again.
    private var waiting = false
    /// Tracked on its own: a failed start leaves a tap installed while `onFrame` is already cleared.
    private var tapInstalled = false

    public init(engine: CaptureEngine) { self.engine = engine }

    public var isRunning: Bool { lock.withLock { onFrame != nil } }

    /// Starts capturing. `onFailure` runs when the engine cannot be rebuilt after an input-device change; with
    /// `onInput` it never does: the rebuild falls back to other inputs, then waits for one (and reports each step).
    public func start(onInput: (@Sendable (CaptureInputEvent) -> Void)? = nil, onFailure: (@Sendable () -> Void)? = nil,
                      onFrame: @escaping @Sendable (Data) -> Void) throws {
        if isRunning { stop() }
        lock.withLock { self.onFrame = onFrame; self.onFailure = onFailure; self.onInput = onInput; waiting = false }
        do { try install() } catch {
            unwind()
            throw error
        }
        engine.setConfigurationChangeHandler { [weak self] in self?.rebuild() }
    }

    private func install() throws {
        engine.resetForCapture()
        guard let format = engine.inputFormat else { throw CaptureError.noInputDevice }
        guard let converter = PCMConverter(from: format) else { throw CaptureError.converter }
        lock.withLock { self.converter = converter; tapInstalled = true }
        engine.installTap { [weak self] buffer in
            guard let self else { return }
            let (conv, sink) = self.lock.withLock { (self.converter, self.onFrame) }
            guard let conv, let sink else { return }
            for frame in conv.frames(from: buffer) { sink(frame) }
        }
        engine.prepare()
        try engine.start()
    }

    /// The default input changed: rebuild on the new device, or give up cleanly (or, with `onInput`, fall back to
    /// the next input and then wait for one).
    private func rebuild() {
        guard isRunning else { return }
        let before = engine.inputName
        // Output-route changes (common when Bluetooth enters hands-free mode) stop
        // AVAudioEngine even if the input format is unchanged. Preserve the tap and
        // converter rather than tearing down the headset and negotiating again.
        // A resume can land on another input of the same format (the default changed):
        // it is reported like a rebuild.
        if !engine.resumeAfterConfigurationChange() {
            removeTapIfInstalled()
            do { try install() } catch {
                let (failure, input, wasWaiting) = lock.withLock { (onFailure, onInput, waiting) }
                guard let input else {
                    unwind()
                    failure?()
                    return
                }
                guard fallBack() else {
                    removeTapIfInstalled()
                    engine.stop()
                    lock.withLock { converter = nil; waiting = true }
                    if !wasWaiting { input(.lost) }
                    return
                }
            }
        }
        let (input, wasWaiting) = lock.withLock { () -> ((@Sendable (CaptureInputEvent) -> Void)?, Bool) in
            defer { waiting = false }
            return (onInput, waiting)
        }
        let name = engine.inputName
        if wasWaiting || name != before { input?(.switched(name)) }
    }

    /// Tries the engine's fallback inputs in turn; true once one runs.
    private func fallBack() -> Bool {
        while engine.fallBack() {
            removeTapIfInstalled()
            if (try? install()) != nil { return true }
        }
        return false
    }

    private func removeTapIfInstalled() {
        let installed = lock.withLock { () -> Bool in defer { tapInstalled = false }; return tapInstalled }
        if installed { engine.removeTap() }
    }

    /// Undoes a partial start: tap, engine, converter and callbacks. Safe to call in any state.
    private func unwind() {
        engine.setConfigurationChangeHandler(nil)
        removeTapIfInstalled()
        engine.stop()
        lock.withLock { converter = nil; onFrame = nil; onFailure = nil; onInput = nil; waiting = false }
        engine.prepare()
    }

    /// Stops the input and delivers any trailing partial frame, padded to at least 20 ms. Idempotent.
    public func stop() {
        let (conv, sink, idle) = lock.withLock { (converter, onFrame, onFrame == nil && !tapInstalled) }
        if idle { return }
        unwind()
        if var tail = conv?.flush(), let sink {
            if tail.count < 640 { tail.append(Data(count: 640 - tail.count)) }
            sink(tail)
        }
    }
}
