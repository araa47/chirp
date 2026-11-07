import AVFoundation
import ChirpCore
import Foundation

/// What happened to Live Notes capture outside the app: another app or a call took the microphone, gave it back
/// (iOS says recording may resume), or capture could not continue.
enum NotesAudioEvent: Sendable, Equatable { case interrupted, resumable, lost }

/// Live Notes' own capture: 16 kHz PCM16 frames on the audio thread, until `stop`. Unlike a keyboard session, nothing
/// is armed between recordings: the microphone is open only while Live Notes records.
@MainActor
protocol NotesAudio: AnyObject {
    var isRunning: Bool { get }
    func start(frame: @escaping @Sendable (Data) -> Void, event: @escaping @Sendable (NotesAudioEvent) -> Void) throws
    func stop()
}

/// Converts capture buffers to protocol frames under a lock, on whatever thread delivers them.
final class NotesFrameSink: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: PCMConverter?
    private var frame: (@Sendable (Data) -> Void)?
    func open(format: AVAudioFormat, frame: @escaping @Sendable (Data) -> Void) throws {
        try lock.withLock {
            guard let converter = PCMConverter(from: format) else { throw SessionFailure.audio }
            self.converter = converter
            self.frame = frame
        }
    }
    func receive(_ buffer: AVAudioPCMBuffer) {
        let (frames, deliver) = lock.withLock { (converter?.frames(from: buffer) ?? [], frame) }
        guard let deliver else { return }
        for data in frames { deliver(data) }
    }
    func close() { lock.withLock { converter = nil; frame = nil } }
}

@MainActor
final class NotesMicrophone: NotesAudio {
    private let engine = AVAudioEngine()
    private let sink = NotesFrameSink()
    private var observers: [NSObjectProtocol] = []
    private var frame: (@Sendable (Data) -> Void)?
    private var event: (@Sendable (NotesAudioEvent) -> Void)?
    private(set) var isRunning = false

    func start(frame: @escaping @Sendable (Data) -> Void, event: @escaping @Sendable (NotesAudioEvent) -> Void) throws {
        guard !isRunning else { return }
        self.frame = frame; self.event = event
        do {
            let session = AVAudioSession.sharedInstance()
            // The dictation microphone's category, so a floating bubble (Picture in Picture) survives a recording.
            try session.setCategory(MicrophoneCapture.category, mode: MicrophoneCapture.mode, options: MicrophoneCapture.options)
            try session.setActive(true)
            try openEngine()
        } catch { stop(); throw SessionFailure.audio }
        isRunning = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [event] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            if type == .began { event(.interrupted); return }
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init) ?? []
            if options.contains(.shouldResume) { event(.resumable) }
        })
        // A new route (headset in or out) or a media-services reset changes the input: capture continues on the new one.
        for name in [Notification.Name.AVAudioEngineConfigurationChange, AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reopen() }
            })
        }
    }

    private func openEngine() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, let frame else { throw SessionFailure.audio }
        try sink.open(format: format, frame: frame)
        input.installTap(onBus: 0, bufferSize: 4096, format: format, block: Self.tap(sink))
        engine.prepare()
        try engine.start()
    }

    private func reopen() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        do { try openEngine() } catch { event?(.lost) }
    }

    /// The tap runs on AVAudioEngine's realtime thread, so it must not inherit this class's main-actor isolation.
    nonisolated static func tap(_ sink: NotesFrameSink) -> AVAudioNodeTapBlock {
        { buffer, _ in sink.receive(buffer) }
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        sink.close()
        if isRunning { engine.inputNode.removeTap(onBus: 0) }
        engine.stop()
        isRunning = false; frame = nil; event = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
