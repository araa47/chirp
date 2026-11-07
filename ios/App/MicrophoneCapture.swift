import AVFoundation
import ChirpCore
import ChirpIOSCore
import Foundation

/// The coordinator is the sole owner; the tap uses a locked sink without an unbounded task queue.
@MainActor
protocol SessionAudio: AnyObject {
    func arm(onInterruption: @escaping @Sendable () -> Void) throws
    /// `autoStop`: Stop dictation "When I pause", the silence that ends it (nil: only Stop does), calling `onAutoStop` once.
    func begin(stream: StreamSession, onFailure: @escaping @Sendable () -> Void, onLimit: @escaping @Sendable () -> Void,
               onCut: @escaping @Sendable () -> Void, autoStop: TimeInterval?, onAutoStop: @escaping @Sendable () -> Void) throws
    /// Long dictation: moves capture to the next segment's stream, buffering until it is ready.
    func cut(to stream: StreamSession)
    func ready()
    func finish()
    func discard()
    func disarm()
}

enum SessionFailure: Error, LocalizedError, Equatable {
    case setup, permission, audio, connection, expired, cancelled, timeout, noResult, storage, notesRecording
    /// A start (or setup step) is already under way; the second request does not queue behind it.
    case busy
    /// A classified reachability failure; its message names the likely cause.
    case mac(ConnectionIssue)
    var errorDescription: String? {
        switch self {
        case .mac(let issue): issue.message
        case .setup: "Open Chirp to pair your computer and start a session."
        case .busy: "Chirp is still starting the last dictation. Try again in a moment."
        case .permission: "Open Chirp and allow microphone access in Settings."
        case .audio: "Microphone unavailable. Open Chirp to start again."
        case .connection: "Connection failed. Check Tailscale and your computer."
        case .expired: "Session ended. Open Chirp to start again."
        case .cancelled: "Dictation cancelled."
        case .timeout: "Chirp server took too long. Try again."
        case .noResult: "Didn't catch that."
        case .storage: "Protected storage unavailable. Unlock and reopen Chirp."
        case .notesRecording: "Live Notes is recording. Stop it in Live Notes to dictate."
        }
    }
}

@MainActor
final class MicrophoneCapture: SessionAudio {
    private let engine = AVAudioEngine()
    private let sink = CaptureSink()
    private var tapped = false
    private var observer: NSObjectProtocol?

    func arm(onInterruption: @escaping @Sendable () -> Void) throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [.allowBluetoothHFP])
            try session.setActive(true)
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw SessionFailure.audio }
            sink.configure(format: format)
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(sink))
            tapped = true
            engine.prepare()
            try engine.start()
            // Register after startup so startup configuration notifications cannot end the new session.
            observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
                object: engine, queue: .main) { _ in onInterruption() }
        } catch {
            disarm()
            throw SessionFailure.audio
        }
    }

    /// AVAudioEngine calls taps on its realtime thread. A closure written inside this @MainActor class
    /// would inherit main-actor isolation, and Swift 6's runtime isolation check traps on that thread.
    nonisolated static func tap(_ sink: CaptureSink) -> AVAudioNodeTapBlock {
        { buffer, _ in sink.receive(buffer) }
    }

    func begin(stream: StreamSession, onFailure: @escaping @Sendable () -> Void, onLimit: @escaping @Sendable () -> Void,
               onCut: @escaping @Sendable () -> Void, autoStop: TimeInterval?, onAutoStop: @escaping @Sendable () -> Void) throws {
        try sink.begin(stream, onFailure: onFailure, onLimit: onLimit, onCut: onCut, autoStop: autoStop, onAutoStop: onAutoStop)
    }
    func cut(to stream: StreamSession) { sink.cut(to: stream) }
    func ready() { sink.ready() }
    func finish() { sink.finish() }
    func discard() { sink.discard() }
    func disarm() {
        if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        sink.discard()
        if tapped { engine.inputNode.removeTap(onBus: 0); tapped = false }
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

final class CaptureSink: @unchecked Sendable {
    private let lock = NSLock()
    private var format: AVAudioFormat?
    private var converter: PCMConverter?
    private var stream: StreamSession?
    private var pending: [Data] = []
    private var pendingBytes = 0
    private var isReady = false
    private var ending = false
    private var failed = false
    private var failure: (@Sendable () -> Void)?
    private var limit: (@Sendable () -> Void)?
    private var cutHandler: (@Sendable () -> Void)?
    private var segmenter = DictationSegmenter()
    private var cutRequested = false
    /// Stop on pause: judged on the whole dictation's audio (it carries over segment cuts), in audio time.
    private var autoStop: AutoStopDetector?
    private var autoStopHandler: (@Sendable () -> Void)?
    private var heard: TimeInterval = 0
    private var reachedLimit = false
    private var queuedBytes = 0
    // Five seconds: room for a long dictation's next socket to become ready (Android's buffer).
    private let maxPreReadyBytes = 5 * 32_000
    // Reserve 200ms for flush below StreamSession's hard 120s byte limit.
    private let maxCaptureBytes = 1198 * 3_200

    func configure(format: AVAudioFormat) {
        lock.withLock { self.format = format }
    }
    func begin(_ stream: StreamSession, onFailure: @escaping @Sendable () -> Void, onLimit: @escaping @Sendable () -> Void,
               onCut: (@Sendable () -> Void)? = nil, autoStop silence: TimeInterval? = nil,
               onAutoStop: (@Sendable () -> Void)? = nil) throws {
        try lock.withLock {
            guard let format, let converter = PCMConverter(from: format) else { throw SessionFailure.audio }
            self.converter = converter
            self.stream = stream
            failure = onFailure; limit = onLimit; cutHandler = onCut
            pending.removeAll(); pendingBytes = 0; isReady = false; ending = false; failed = false
            reachedLimit = false; queuedBytes = 0; segmenter.reset(); cutRequested = false
            autoStop = silence.map { AutoStopDetector(silence: $0) }; autoStopHandler = onAutoStop; heard = 0
        }
    }
    func receive(_ buffer: AVAudioPCMBuffer) {
        let (notify, pause) = lock.withLock { () -> ((@Sendable () -> Void)?, (@Sendable () -> Void)?) in
            // Armed idle capture is immediately discarded: no conversion, buffering, file or network writes.
            guard stream != nil, !ending, !failed, !reachedLimit, let converter else { return (nil, nil) }
            var cut = false, paused = false
            for frame in converter.frames(from: buffer) {
                enqueue(frame)
                guard cutHandler != nil || autoStop != nil else { continue }
                let rms = DictationSegmenter.rms(pcm16: frame), duration = Double(frame.count) / 32_000
                if cutHandler != nil, !cutRequested, segmenter.feed(rms: rms, duration: duration) {
                    cutRequested = true; cut = true
                }
                heard += duration
                if autoStop?.feed(Level(peak: rms, rms: rms), at: heard) == true { paused = true }
            }
            var pause: (@Sendable () -> Void)?
            if paused { pause = autoStopHandler; autoStopHandler = nil }
            return (failed ? failure : reachedLimit ? limit : cut ? cutHandler : nil, pause)
        }
        notify?()
        pause?()
    }
    /// Every frame goes to exactly one segment, in order; the new stream's frames wait until it is ready.
    func cut(to next: StreamSession) {
        lock.withLock {
            guard stream != nil, !ending, !failed else { return }
            stream = next; isReady = false; pending.removeAll(); pendingBytes = 0
            queuedBytes = 0; reachedLimit = false; segmenter.reset(); cutRequested = false
        }
    }
    private func enqueue(_ data: Data, flushing: Bool = false) {
        guard !failed, flushing || !reachedLimit else { return }
        let available = (flushing ? 120 * 32_000 : maxCaptureBytes) - queuedBytes
        let data = Data(data.prefix(available))
        guard !data.isEmpty else { return }
        queuedBytes += data.count
        if queuedBytes >= maxCaptureBytes { reachedLimit = true }
        if isReady {
            if stream?.sendAudio(data) != true { failed = true }
        } else if pendingBytes + data.count <= maxPreReadyBytes {
            pending.append(data); pendingBytes += data.count
        } else { failed = true; pending.removeAll(); pendingBytes = 0 }
    }
    func ready() {
        let notify = lock.withLock { () -> (@Sendable () -> Void)? in
            guard !isReady, !failed else { return failed ? failure : nil }
            isReady = true
            for data in pending where !failed { if stream?.sendAudio(data) != true { failed = true } }
            pending.removeAll(); pendingBytes = 0
            return failed ? failure : nil
        }
        notify?()
    }
    func finish() {
        let notify = lock.withLock { () -> (@Sendable () -> Void)? in
            guard !ending else { return nil }
            ending = true
            if var tail = converter?.flush() {
                if tail.count < 640 { tail.append(Data(count: 640 - tail.count)) }
                enqueue(tail, flushing: true)
            }
            converter = nil
            return failed ? failure : nil
        }
        notify?()
    }
    func discard() {
        lock.withLock {
            stream = nil; converter = nil; pending.removeAll(); pendingBytes = 0
            isReady = false; ending = true; reachedLimit = false; queuedBytes = 0
            failure = nil; limit = nil; cutHandler = nil; cutRequested = false
            autoStop = nil; autoStopHandler = nil; heard = 0
        }
    }
}
