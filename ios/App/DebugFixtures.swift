#if DEBUG
import AVFoundation
import ChirpCore
import ChirpIOSCore
import Foundation
import SwiftUI
import UIKit

/// Synthetic transport/audio. Not compiled into Release. No microphone or network access.
final class SyntheticHTTP: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        // `--chirp-external-cleanup` makes clean-up leave the computer, so the consent dialog can be exercised.
        let leaves = ProcessInfo.processInfo.arguments.contains("--chirp-external-cleanup")
        let health = #"{"ok":true,"ready":true,"engine":"synthetic","debug_retention":false,"correction":"available","correction_leaves_machine":\#(leaves),"# + (leaves ? #""correction_host":"synthetic.example","# : "") + #""device":"Synthetic test device"}"#
        let profiles = #"{"profiles":[{"id":"default","name":"Default","description":"Synthetic test style","rewrites":false,"prompt":"Keep all words.","max_prompt_chars":4000}]}"#
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type":"application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data((url.path.hasSuffix("profiles") ? profiles : health).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class SyntheticTransport: StreamTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let incoming: AsyncStream<URLSessionWebSocketTask.Message>
    private let continuation: AsyncStream<URLSessionWebSocketTask.Message>.Continuation
    private var iterator: AsyncStream<URLSessionWebSocketTask.Message>.Iterator
    private var sentValues: [URLSessionWebSocketTask.Message] = []
    let automatic: Bool
    /// The start message asked for speaker labels (`speakers.session`): the final then carries two people's turns.
    private var labelling = false
    /// The start message was a re-transcribe (`start.retranscribe`): `ready` names an engine, there are no partials, and
    /// the final carries word timings. `--chirp-retranscribe-hold` keeps every re-transcribe final after the first one
    /// back, so the progress banner can be captured.
    private var retranscribing = false
    static let holdRetranscribe = ProcessInfo.processInfo.arguments.contains("--chirp-retranscribe-hold")
    private static let finals = NSLock()
    nonisolated(unsafe) private static var retranscribeFinals = 0
    private let voiceMatches: @Sendable () -> [ServerVoiceMatch]
    init(automatic: Bool = false, voiceMatches: @escaping @Sendable () -> [ServerVoiceMatch] = { [] }) {
        self.voiceMatches = voiceMatches
        self.automatic = automatic
        let (input, output) = AsyncStream.makeStream(of: URLSessionWebSocketTask.Message.self)
        incoming = input; continuation = output; iterator = input.makeAsyncIterator()
    }
    var sent: [URLSessionWebSocketTask.Message] { lock.withLock { sentValues } }
    func resume() {}
    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        lock.withLock { sentValues.append(message) }
        guard automatic, case .string(let text) = message else { return }
        if text.contains(#""type":"start""#) {
            lock.withLock { labelling = text.contains(#""speakers":{"session":""#); retranscribing = text.contains(#""retranscribe":true"#) }
            if lock.withLock({ retranscribing }) {
                push(#"{"type":"ready","session":"synthetic","engine":"parakeet-mlx:tdt-0.6b-v3","debug_retention":false}"#)
                return
            }
            push(#"{"type":"ready","session":"synthetic","debug_retention":false}"#)
            push(#"{"type":"partial","seq":1,"text":"synthetic words","stable":"","words":[{"text":"synthetic","start":0,"end":0.2,"stable":false}]}"#)
        } else if text.contains(#""type":"stop""#), lock.withLock({ retranscribing }) {
            let n = Self.finals.withLock { Self.retranscribeFinals += 1; return Self.retranscribeFinals }
            if Self.holdRetranscribe, n > 1 { return }
            if lock.withLock({ () -> Bool in held = holding; return held }) { return }
            pushRetranscribeFinal()
        } else if text.contains(#""type":"stop""#) {
            push(#"{"type":"correcting","seq":2,"raw":"synthetic words","profile":"default"}"#)
            if lock.withLock({ labelling }) {
                let value = #"{"type":"final","text":"Synthetic words. Second voice.","raw":"synthetic words second voice","corrected":true,"speakers":{"generation":"synthetic-generation","turns":[{"speaker":0,"start":0,"text":"Synthetic words.","raw":"synthetic words"},{"speaker":1,"start":1,"text":"Second voice.","raw":"second voice"}]}}"#
                var body = (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String: Any] ?? [:]
                var speakers = body["speakers"] as? [String: Any] ?? [:]
                let matches = voiceMatches()
                if !matches.isEmpty { speakers["matches"] = matches.map { ["speaker": $0.speaker, "voice": $0.voice, "name": $0.name] as [String: Any] } }
                body["speakers"] = speakers
                if let data = try? JSONSerialization.data(withJSONObject: body), let json = String(data: data, encoding: .utf8) { push(json) }
            } else {
                push(#"{"type":"final","text":"Synthetic words.","raw":"synthetic words","corrected":true}"#)
            }
        }
    }
    func receive() async throws -> URLSessionWebSocketTask.Message {
        // StreamSession has exactly one receiver. Keep the iterator local across suspension for Swift 6.
        var current = lock.withLock { iterator }
        guard let next = await current.next() else { throw URLError(.cancelled) }
        lock.withLock { iterator = current }
        return next
    }
    func cancel(with code: URLSessionWebSocketTask.CloseCode) { continuation.finish() }
    func push(_ value: String) { continuation.yield(.string(value)) }
    /// Tests: a re-transcribe final waits until `releaseFinal()` (or never comes).
    var holdsFinal: Bool {
        get { lock.withLock { holding } }
        set { lock.withLock { holding = newValue } }
    }
    private var holding = false
    private var held = false
    func releaseFinal() {
        if lock.withLock({ () -> Bool in defer { held = false }; return held }) { pushRetranscribeFinal() }
    }
    private func pushRetranscribeFinal() {
        push(#"{"type":"final","text":"Synthetic words again.","raw":"synthetic words again","corrected":true,"words":[{"text":"synthetic","start":0,"end":0.4},{"text":"words","start":0.4,"end":0.8},{"text":"again","start":0.8,"end":1.2}]}"#)
    }
    /// The socket fails: the next receive throws, as when the connection drops mid-utterance.
    func drop() { continuation.finish() }
}

@MainActor
final class SyntheticAudio: SessionAudio {
    private(set) var armed = false
    private(set) var finishCount = 0
    private(set) var limits: [@Sendable () -> Void] = []
    private(set) var failures: [@Sendable () -> Void] = []
    private var stream: StreamSession?
    func arm(onInterruption: @escaping @Sendable () -> Void) throws { armed = true }
    private(set) var cuts: [@Sendable () -> Void] = []
    /// Each dictation's stop-on-pause silence (nil: only Stop) and its callback, as the sink would fire it.
    private(set) var autoStops: [(silence: TimeInterval?, fire: @Sendable () -> Void)] = []
    func begin(stream: StreamSession, onFailure: @escaping @Sendable () -> Void, onLimit: @escaping @Sendable () -> Void,
               onCut: @escaping @Sendable () -> Void, autoStop: TimeInterval?, onAutoStop: @escaping @Sendable () -> Void) throws {
        self.stream = stream; limits.append(onLimit); failures.append(onFailure); cuts.append(onCut)
        autoStops.append((autoStop, onAutoStop))
    }
    func cut(to stream: StreamSession) { self.stream = stream }
    func ready() { stream?.sendAudio(Data(count: 1600)) }
    func finish() { finishCount += 1; stream?.sendAudio(Data(count: 640)) }
    func discard() { stream = nil }
    func disarm() { armed = false; stream = nil }
}

extension SessionCoordinator {
    static func synthetic(sharedKeyboard: Bool = false) -> SessionCoordinator {
        do {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-synthetic-" + UUID().uuidString)
            let services = try sharedKeyboard ? AppServices.production() : AppServices(root: root, secrets: MemorySecretStore())
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SyntheticHTTP.self]
            return SessionCoordinator(services: services, audio: SyntheticAudio(), http: URLSession(configuration: config),
                makeStream: { _, options, _ in StreamSession(transport: SyntheticTransport(automatic: true), options: options) },
                requestPermission: { true }, permissionGranted: { true }, activityBegin: { _ in }, activityActive: { true },
                activityUpdate: { _, _ in }, activityEnd: {}, production: sharedKeyboard)
        } catch {
            let model = SessionCoordinator(audio: SyntheticAudio(), production: false)
            model.show(error)
            return model
        }
    }
}

/// UI tests pick whether first-run onboarding shows: `--chirp-onboarding` shows it, `--chirp-skip-onboarding`
/// starts as if it was finished. Without either flag the stored state decides, as in Release.
enum OnboardingTestMode {
    static func apply() {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--chirp-onboarding") { UserDefaults.standard.set(false, forKey: Onboarding.doneKey) }
        if args.contains("--chirp-skip-onboarding") { UserDefaults.standard.set(true, forKey: Onboarding.doneKey) }
        if args.contains("--chirp-setup-card") { UserDefaults.standard.set(false, forKey: "chirp.setupCard.dismissed") }
    }
}

/// Simulator-only speech source for end-to-end runs against a real local server: `--chirp-sim-audio <file>`
/// plays an audio file (from the app's data container) through the real `CaptureSink` at real-time pace
/// for each utterance, then silence until stop. The simulator's microphone input can hang in AudioToolbox
/// (RPC timeout abort), so instead of arming it, looping silent output keeps the app running in the
/// background during the session as the armed microphone does on a device.
@MainActor
final class SimulatorFileAudio: SessionAudio {
    private let url: URL
    private let keepAlive = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sink = CaptureSink()
    private var feeder: Task<Void, Never>?
    init(url: URL) { self.url = url }
    static func fromArguments() -> SimulatorFileAudio? {
        #if targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--chirp-sim-audio"), i + 1 < args.count else { return nil }
        let path = args[i + 1]
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path)
            : FileManager.default.temporaryDirectory.appendingPathComponent(path)
        return SimulatorFileAudio(url: url)
        #else
        return nil
        #endif
    }
    func arm(onInterruption: @escaping @Sendable () -> Void) throws {
        guard let file = try? AVAudioFile(forReading: url) else { throw SessionFailure.audio }
        sink.configure(format: file.processingFormat)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: .mixWithOthers)
            try AVAudioSession.sharedInstance().setActive(true)
            let format = keepAlive.mainMixerNode.outputFormat(forBus: 0)
            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) else { throw SessionFailure.audio }
            silence.frameLength = silence.frameCapacity
            keepAlive.attach(player)
            keepAlive.connect(player, to: keepAlive.mainMixerNode, format: format)
            player.scheduleBuffer(silence, at: nil, options: .loops)
            try keepAlive.start()
            player.play()
        } catch { disarm(); throw SessionFailure.audio }
    }
    func begin(stream: StreamSession, onFailure: @escaping @Sendable () -> Void, onLimit: @escaping @Sendable () -> Void,
               onCut: @escaping @Sendable () -> Void, autoStop: TimeInterval?, onAutoStop: @escaping @Sendable () -> Void) throws {
        try sink.begin(stream, onFailure: onFailure, onLimit: onLimit, onCut: onCut, autoStop: autoStop, onAutoStop: onAutoStop)
        feeder?.cancel()
        feeder = Task.detached { [url, sink] in
            guard let file = try? AVAudioFile(forReading: url) else { return }
            let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
            while !Task.isCancelled {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return }
                if (try? file.read(into: buffer, frameCount: chunk)) == nil || buffer.frameLength == 0 {
                    buffer.frameLength = chunk // silence after the file ends
                    for c in 0..<Int(buffer.format.channelCount) { buffer.floatChannelData?[c].update(repeating: 0, count: Int(chunk)) }
                }
                sink.receive(buffer)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
    func cut(to stream: StreamSession) { sink.cut(to: stream) }
    func ready() { sink.ready() }
    func finish() { feeder?.cancel(); feeder = nil; sink.finish() }
    func discard() { feeder?.cancel(); feeder = nil; sink.discard() }
    func disarm() {
        discard(); player.stop(); keepAlive.stop()
        if player.engine != nil { keepAlive.detach(player) }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// The shared-store fixture can only be selected on a simulator with both arguments.
enum KeyboardTestMode {
    static var enabled: Bool {
        #if targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        return args.contains("--chirp-ui-test") && args.contains("--chirp-keyboard-host")
        #else
        return false
        #endif
    }
}

struct KeyboardTestHost: View {
    @ObservedObject var model: SessionCoordinator
    @State private var setup = "Preparing synthetic shared session"
    @State private var secure = false
    @State private var password = ""
    @State private var sends = 0
    private var args: [String] { ProcessInfo.processInfo.arguments }
    var body: some View {
        VStack {
            Text(setup).accessibilityIdentifier("chirp.host.setup")
            Text(model.phase.rawValue).accessibilityIdentifier("chirp.host.phase")
            LiveKeyboardHost().frame(maxWidth: .infinity, maxHeight: .infinity)
            if args.contains("--chirp-keyboard-host-send") {
                SendFieldHost(sends: $sends).frame(height: 44)
                Text("Returns: \(sends)").accessibilityIdentifier("chirp.host.sends")
            }
            // On screen only on demand: while any secure field is visible, iOS offers no third-party keyboard.
            Toggle("Password field", isOn: $secure).accessibilityIdentifier("chirp.host.secure.toggle")
            if secure {
                SecureField("Password", text: $password).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("chirp.host.secure")
            }
            Button("End fixture session") { model.endSession() }
                .accessibilityIdentifier("chirp.host.end")
        }.padding()
            .task {
                if let i = args.firstIndex(of: "--chirp-auto-enter"), i + 1 < args.count {
                    model.preferences.autoEnter = args[i + 1]; model.savePreferences()
                }
                #if targetEnvironment(simulator)
                // Screenshot runs: a sample Live Activity for the lock screen and Dynamic Island (Debug, simulator only).
                if let i = args.firstIndex(of: "--chirp-activity-preview"), i + 1 < args.count { ChirpLiveActivity.preview(args[i + 1]) }
                #endif
                await model.pair(link: "chirp://pair?url=https%3A%2F%2Fsynthetic.test.ts.net%2Fchirp&token=synthetic-only")
                guard model.paired else {
                    setup = "Simulator shared App Group/Keychain unavailable: " + model.notice
                    return
                }
                do {
                    try await model.armSession()
                    setup = "Synthetic shared session armed"
                } catch {
                    setup = "Simulator shared session could not arm: " + error.localizedDescription
                }
            }
    }
}

/// UIKit editor hosts the installed extension; updateUIView never replaces its text.
struct LiveKeyboardHost: UIViewRepresentable {
    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = .preferredFont(forTextStyle: .title2)
        view.accessibilityIdentifier = "chirp.host.text"
        view.text = ProcessInfo.processInfo.arguments.contains("--chirp-keyboard-host-empty") ? "" : "Host prefix. "
        // Dictation tests want the host's text untouched; the typing test asks for a prose field with suggestions.
        if !ProcessInfo.processInfo.arguments.contains("--chirp-keyboard-host-prose") {
            view.autocorrectionType = .no
            view.spellCheckingType = .no
        }
        view.selectedRange = NSRange(location: view.text.utf16.count, length: 0)
        // Screenshot runs: show the keyboard without a tap (the system keeps the last-used keyboard).
        if ProcessInfo.processInfo.arguments.contains("--chirp-keyboard-host-focus") {
            DispatchQueue.main.async { view.becomeFirstResponder() }
        }
        return view
    }
    func updateUIView(_ view: UITextView, context: Context) {}
}

/// A single-line field whose Return key is Send, counting the Returns the host receives (auto-Enter fixture).
struct SendFieldHost: UIViewRepresentable {
    @Binding var sends: Int
    func makeCoordinator() -> Delegate { Delegate(sends: $sends) }
    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.returnKeyType = .send
        field.borderStyle = .roundedRect
        field.autocorrectionType = .no
        field.accessibilityIdentifier = "chirp.host.send"
        field.delegate = context.coordinator
        return field
    }
    func updateUIView(_ view: UITextField, context: Context) {}
    final class Delegate: NSObject, UITextFieldDelegate {
        var sends: Binding<Int>
        init(sends: Binding<Int>) { self.sends = sends }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool { sends.wrappedValue += 1; return false }
    }
}
#endif
