import AVFoundation
import AppKit
import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

// End-to-end Live Notes without a microphone, a server or a window: the real `NotesSession`, `NotesRecorder`,
// `StreamSession`, `AudioCapture`, `ServerConfig` HTTP calls and an offscreen editor, against scripted sockets, a
// scripted notes endpoint and synthetic audio on a fake clock. Nothing here touches the network or the disk.

// MARK: scripted stream server

/// How one socket behaves, by the order its `start` arrived (0 for the first). Unscripted sockets answer `ready`
/// and, on `stop`, a final reading `ScriptedStreams.finalText(n)`.
struct SocketScript: Sendable {
    enum Start: Sendable {
        case ready
        /// An `error` message with this code instead of `ready`.
        case refuse(String)
        /// Never answers (the client's ready deadline runs out).
        case stall
    }
    enum Stop: Sendable {
        case final
        /// The connection drops instead of answering.
        case drop
        /// Never answers (the recorder's final timeout runs out).
        case stall
        case error(String)
    }
    var start: Start = .ready
    /// The connection drops once this many audio bytes arrived (a Wi-Fi blip mid-segment).
    var dropAfterBytes: Int?
    /// A partial after the first audio frame.
    var partial: String?
    var stop: Stop = .final
}

/// An in-memory `/v1/stream` server: each `makeSession` is a real `StreamSession` over a `ScriptedTransport`.
final class ScriptedStreams: @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [Int: SocketScript] = [:]
    private var connected: [ScriptedTransport] = []
    private var _bytes: [Int: Int] = [:]
    private var _down = false
    private var _attempts = 0
    private let sleep: @Sendable (Duration) async -> Void
    /// The final's text for socket `n`.
    let finalText: @Sendable (Int) -> String

    init(sleep: @escaping @Sendable (Duration) async -> Void,
         finalText: @escaping @Sendable (Int) -> String = { "Segment \($0)." }) {
        self.sleep = sleep
        self.finalText = finalText
    }

    func script(_ socket: Int, _ s: SocketScript) { lock.withLock { scripts[socket] = s } }
    /// While down, every new connection is refused (`Server unreachable`) and gets no socket number.
    var down: Bool {
        get { lock.withLock { _down } }
        set { lock.withLock { _down = newValue } }
    }
    /// Sockets that sent `start` (and got a number).
    var started: Int { lock.withLock { connected.count } }
    /// Connections tried, refused ones included.
    var attempts: Int { lock.withLock { _attempts } }
    var bytesBySocket: [Int: Int] { lock.withLock { _bytes } }
    var audioBytes: Int { lock.withLock { _bytes.values.reduce(0, +) } }

    func makeSession(_ options: StartOptions) -> StreamSession {
        StreamSession(transport: ScriptedTransport(server: self), options: options, sleep: sleep)
    }

    /// Drops every open connection now.
    func dropAll() {
        for t in lock.withLock({ connected }) { t.drop() }
    }

    fileprivate func connect(_ t: ScriptedTransport) -> (Int, SocketScript)? {
        lock.withLock {
            _attempts += 1
            guard !_down else { return nil }
            connected.append(t)
            let i = connected.count - 1
            return (i, scripts[i] ?? SocketScript())
        }
    }

    fileprivate func received(_ bytes: Int, socket: Int) { lock.withLock { _bytes[socket, default: 0] += bytes } }
}

/// One scripted connection. Messages to the client queue up until `receive` takes them.
final class ScriptedTransport: StreamTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let server: ScriptedStreams
    private var inbox: [URLSessionWebSocketTask.Message] = []
    private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    private var failure: Error?
    private var socket: (index: Int, script: SocketScript)?
    private var bytes = 0

    init(server: ScriptedStreams) { self.server = server }

    func resume() {}

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        if let failure = lock.withLock({ failure }) { throw failure }
        switch message {
        case .string(let s) where s.contains(#""type":"start""#):
            guard let (i, script) = server.connect(self) else {
                close(URLError(.cannotConnectToHost))
                throw URLError(.cannotConnectToHost)
            }
            lock.withLock { socket = (i, script) }
            switch script.start {
            case .ready: deliver(#"{"type":"ready","session":"s\#(i)","engine":"scripted","debug_retention":false}"#)
            case .refuse(let code): deliver(#"{"type":"error","code":"\#(code)","message":"scripted"}"#)
            case .stall: break
            }
        case .string(let s) where s.contains(#""type":"stop""#):
            guard let (i, script) = lock.withLock({ socket }) else { return }
            switch script.stop {
            case .final:
                let text = server.finalText(i)
                let json = try JSONSerialization.data(withJSONObject: ["type": "final", "text": text, "raw": text.lowercased(), "corrected": true])
                deliver(String(decoding: json, as: UTF8.self))
            case .drop: drop()
            case .stall: break
            case .error(let code): deliver(#"{"type":"error","code":"\#(code)","message":"scripted"}"#)
            }
        case .data(let d):
            guard let (i, script) = lock.withLock({ socket }) else { return }
            let (before, after) = lock.withLock { () -> (Int, Int) in defer { bytes += d.count }; return (bytes, bytes + d.count) }
            server.received(d.count, socket: i)
            if before == 0, let p = script.partial { deliver(#"{"type":"partial","seq":1,"text":"\#(p)","stable":""}"#) }
            if let limit = script.dropAfterBytes, before < limit, after >= limit { drop() }
        default: break
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        try await withCheckedThrowingContinuation { c in
            let ready = lock.withLock { () -> Result<URLSessionWebSocketTask.Message, Error>? in
                if !inbox.isEmpty { return .success(inbox.removeFirst()) }
                if let failure { return .failure(failure) }
                waiter = c
                return nil
            }
            if let ready { c.resume(with: ready) }
        }
    }

    func cancel(with code: URLSessionWebSocketTask.CloseCode) { close(URLError(.cancelled)) }

    /// The connection is lost (as a dropped Wi-Fi or a server restart looks to the client).
    func drop() { close(URLError(.networkConnectionLost)) }

    private func deliver(_ json: String) {
        let c = lock.withLock { () -> CheckedContinuation<URLSessionWebSocketTask.Message, Error>? in
            guard failure == nil else { return nil }
            if let w = waiter { waiter = nil; return w }
            inbox.append(.string(json))
            return nil
        }
        c?.resume(returning: .string(json))
    }

    private func close(_ error: Error) {
        let c = lock.withLock { () -> CheckedContinuation<URLSessionWebSocketTask.Message, Error>? in
            guard failure == nil else { return nil }
            failure = error
            defer { waiter = nil }
            return waiter
        }
        c?.resume(throwing: error)
    }
}

// MARK: scripted notes endpoint

/// One answer of the notes endpoint (`/v1/notes/structure` or `/reorganize`).
enum NotesAnswer: Sendable {
    /// 200 with this Markdown.
    case ok(String)
    /// 200, `structured: false` with `error: "rejected"` and this guard name.
    case rejected(String)
    /// The client's request times out.
    case timeout
    /// A non-200 status (503 busy, 404 missing, 409 correction off…).
    case status(Int)
}

/// The notes HTTP endpoints behind a `URLProtocol`: answers come from a queue (then a default: a `## Notes` section
/// with each transcript line as a bullet), and every request is kept. Each instance has its own session, so suites can run
/// side by side.
final class NotesHTTP: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var live: [String: NotesHTTP] = [:]

    private let lock = NSLock()
    private let id = UUID().uuidString
    private var structureQueue: [NotesAnswer] = []
    private var reorganizeQueue: [NotesAnswer] = []
    private var editQueue: [EditAnswer] = []
    private var _edit: [EditWire] = []
    private var _structure: [Wire] = []
    private var _reorganize: [Wire] = []
    private var held: [CheckedContinuation<Void, Never>] = []
    private var _hold = false
    let session: URLSession

    init() {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [NotesHTTPProtocol.self]
        c.httpAdditionalHeaders = ["X-Notes-Harness": id]
        session = URLSession(configuration: c)
        Self.lock.withLock { Self.live[id] = self }
    }

    deinit { Self.lock.withLock { _ = Self.live.removeValue(forKey: id) } }

    static func find(_ request: URLRequest) -> NotesHTTP? {
        guard let id = request.value(forHTTPHeaderField: "X-Notes-Harness") else { return nil }
        return lock.withLock { live[id] }
    }

    func answerStructure(_ answers: NotesAnswer...) { lock.withLock { structureQueue += answers } }
    func answerReorganize(_ answers: NotesAnswer...) { lock.withLock { reorganizeQueue += answers } }
    /// `/v1/notes/edit` answers, in order; with none queued an edit comes back unchanged.
    enum EditAnswer: Sendable {
        case ok(String)
        case unchanged
        case refused(String)
        case rejected(String)
        case preempted
        case status(Int)
    }
    struct EditWire: Decodable, Equatable {
        var notes: String
        var instruction: String
    }
    func answerEdit(_ answers: EditAnswer...) { lock.withLock { editQueue += answers } }
    var editRequests: [EditWire] { lock.withLock { _edit } }
    /// A request as it went over the wire: the transcript (structure) or the notes in scope (reorganize).
    struct Wire: Decodable, Equatable {
        var transcript: String?
        var notes: String?
        var outline: [String]
        var final: Bool
        var text: String { transcript ?? notes ?? "" }
    }
    var structureRequests: [Wire] { lock.withLock { _structure } }
    var reorganizeRequests: [Wire] { lock.withLock { _reorganize } }
    var calls: Int { lock.withLock { _structure.count + _reorganize.count + _edit.count } }
    /// While set, answers wait until `release()`.
    var hold: Bool {
        get { lock.withLock { _hold } }
        set { lock.withLock { _hold = newValue } }
    }
    var waiting: Int { lock.withLock { held.count } }

    func release() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            _hold = false
            defer { held.removeAll() }
            return held
        }
        for c in waiting { c.resume() }
    }

    func structure(_ config: ServerConfig) -> NotesRecorder.Structure {
        let session = self.session
        return { try await config.structureNotes($0, session: session) }
    }

    func reorganize(_ config: ServerConfig) -> NotesRecorder.Reorganize {
        let session = self.session
        return { try await config.reorganizeNotes($0, session: session) }
    }

    func edit(_ config: ServerConfig) -> NotesRecorder.Edit {
        let session = self.session
        return { try await config.editNotes($0, session: session) }
    }

    private func respondEdit(_ body: Data) async -> (Int, Data)? {
        guard let r = try? JSONDecoder().decode(EditWire.self, from: body) else { return (400, Data()) }
        let answer = lock.withLock { () -> EditAnswer in
            _edit.append(r)
            return editQueue.isEmpty ? .unchanged : editQueue.removeFirst()
        }
        if hold { await withCheckedContinuation { c in lock.withLock { if _hold { held.append(c) } else { c.resume() } } } }
        let json: [String: Any]
        switch answer {
        case .ok(let md): json = ["markdown": md, "edited": true, "changed": true]
        case .unchanged: json = ["markdown": r.notes, "edited": true, "changed": false]
        case .refused(let reason): json = ["edited": false, "changed": false, "error": "refused", "reason": reason]
        case .rejected(let reason): json = ["edited": false, "changed": false, "error": "rejected", "reason": reason]
        case .preempted: json = ["edited": false, "changed": false, "error": "preempted"]
        case .status(let code): return (code, Data())
        }
        return (200, (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
    }

    /// The status and body for one request (after any hold).
    fileprivate func respond(_ request: URLRequest, body: Data) async -> (Int, Data)? {
        if request.url?.path.hasSuffix("/edit") == true { return await respondEdit(body) }
        let reorganize = request.url?.path.hasSuffix("/reorganize") == true
        guard let r = try? JSONDecoder().decode(Wire.self, from: body) else { return (400, Data()) }
        let answer = lock.withLock { () -> NotesAnswer in
            if reorganize {
                _reorganize.append(r)
                return reorganizeQueue.isEmpty ? .ok(Self.bullets(r.text)) : reorganizeQueue.removeFirst()
            }
            _structure.append(r)
            return structureQueue.isEmpty ? .ok("## Notes\n" + Self.bullets(r.text)) : structureQueue.removeFirst()
        }
        if hold { await withCheckedContinuation { c in lock.withLock { if _hold { held.append(c) } else { c.resume() } } } }
        let json: [String: Any]
        switch answer {
        case .ok(let md): json = reorganize ? ["markdown": md, "reorganized": true, "changed": true] : ["markdown": md, "structured": true]
        case .rejected(let reason):
            json = reorganize ? ["reorganized": false, "error": "rejected", "reason": reason]
                : ["structured": false, "error": "rejected", "reason": reason]
        case .timeout: return nil
        case .status(let code): return (code, Data())
        }
        return (200, (try? JSONSerialization.data(withJSONObject: json)) ?? Data())
    }

    /// Each line as a bullet (headings and bullets stay as they are).
    static func bullets(_ text: String) -> String {
        text.split(separator: "\n").map { $0.hasPrefix("- ") || $0.hasPrefix("#") ? String($0) : "- \($0)" }.joined(separator: "\n")
    }
}

final class NotesHTTPProtocol: URLProtocol, @unchecked Sendable {
    private var loading: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { NotesHTTP.find(request) != nil }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        nonisolated(unsafe) let me = self
        loading = Task {
            let answer = await NotesHTTP.find(request)?.respond(request, body: body)
            guard !Task.isCancelled, let client = me.client else { return }
            guard let answer else { client.urlProtocol(me, didFailWithError: URLError(.timedOut)); return }
            let response = HTTPURLResponse(url: request.url!, statusCode: answer.0, httpVersion: nil, headerFields: nil)!
            client.urlProtocol(me, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(me, didLoad: answer.1)
            client.urlProtocolDidFinishLoading(me)
        }
    }

    override func stopLoading() { loading?.cancel() }

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

// MARK: synthetic audio

/// A capture engine that plays envelopes instead of a microphone: 50 ms buffers of speech (a tone well above the
/// segmenter's quiet level), pause (quiet, but not digital zero) or digital zero (a muted input). No hardware.
final class SyntheticEngine: CaptureEngine, @unchecked Sendable {
    enum Sound { case speech, pause, zero }

    private let lock = NSLock()
    private var _format: AVAudioFormat? = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
    private var block: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var onChange: (@Sendable () -> Void)?
    private var buffers: [String: AVAudioPCMBuffer] = [:]
    var startError: Error?
    private(set) var starts = 0
    /// The inputs `fallBack` moves to, in order (a lost device with none left waits for one).
    var fallbacks: [String] = []
    private(set) var inputName: String? = "USB Microphone"

    var inputFormat: AVAudioFormat? { lock.withLock { _format } }
    var isTapped: Bool { lock.withLock { block != nil } }

    func installTap(_ block: @escaping @Sendable (AVAudioPCMBuffer) -> Void) { lock.withLock { self.block = block } }
    func removeTap() { lock.withLock { block = nil } }
    func prepare() {}
    func start() throws {
        if let startError { throw startError }
        lock.withLock { starts += 1 }
    }
    func stop() {}
    func setConfigurationChangeHandler(_ handler: (@Sendable () -> Void)?) { lock.withLock { onChange = handler } }
    func fallBack() -> Bool {
        lock.withLock {
            guard !fallbacks.isEmpty else { return false }
            inputName = fallbacks.removeFirst()
            _format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
            buffers.removeAll()
            return true
        }
    }

    /// Plays `seconds` of `sound` through the tap, one `buffer`-long capture buffer at a time (50 ms, as a microphone
    /// delivers; the soak uses longer ones), on the caller's thread. The socket still gets 50 ms frames.
    func play(_ sound: Sound, seconds: Double, buffer length: Double = 0.05) {
        let n = Int((seconds / length).rounded())
        guard n > 0, let buffer = buffer(sound, length) else { return }
        for _ in 0..<n {
            guard let block = lock.withLock({ self.block }) else { return }
            block(buffer)
        }
    }

    /// The input device goes away; with `replacement` another one takes its place, else none is left.
    func changeDevice(replacement: Bool, name: String = "Studio Microphone") {
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            _format = replacement ? AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)! : nil
            inputName = replacement ? name : nil
            buffers.removeAll()
            return onChange
        }
        handler?()
    }

    private func buffer(_ sound: Sound, _ length: Double) -> AVAudioPCMBuffer? {
        lock.withLock {
            let key = "\(sound)-\(length)"
            if let b = buffers[key] { return b }
            guard let format = _format else { return nil }
            let n = AVAudioFrameCount((format.sampleRate * length).rounded())
            guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n) else { return nil }
            b.frameLength = n
            let samples = b.floatChannelData![0]
            for i in 0..<Int(n) {
                switch sound {
                case .speech: samples[i] = 0.3 * sinf(Float(i) * 0.12)
                case .pause: samples[i] = i % 2 == 0 ? 0.002 : -0.002
                case .zero: samples[i] = 0
                }
            }
            buffers[key] = b
            return b
        }
    }
}

// MARK: the harness

/// One Live Notes window's worth of app: a `NotesSession` with every system edge faked, and an offscreen editor
/// bound to its model the way the window binds it. Steps return the harness, so a test reads as a script:
/// `try await h.record().speak(20).pause(1).speak(20).stop()`.
@MainActor
final class NotesHarness {
    let clock = ManualClock()
    let streams: ScriptedStreams
    let http = NotesHTTP()
    let engine = SyntheticEngine()
    /// Where the session hears about system sleep and wake.
    let workspace = NotificationCenter()
    let store: SpeakerModelStore
    let prefs: Preferences
    let suite: String
    /// The recovery journal's directory: private to this harness unless it was handed one (a relaunch).
    let journalDirectory: URL
    private let ownsJournal: Bool
    let session: NotesSession
    let editor: NotesEditorCoordinator
    var health: Health?
    /// What the faked system edges saw: cues, announcements, beeps, the microphone prompt and the tick.
    let edges = Edges()
    /// Every status line the window showed, in order (repeats collapsed).
    private(set) var statuses: [String] = []
    /// How often the session published a change (each one is a SwiftUI update of the window).
    private(set) var syncs = 0
    /// How long each editor update that took a new document version ran (the append or reorganize replay and
    /// its restyle), seconds.
    private(set) var editorUpdates: [Double] = []
    private var editorVersion = -1

    @MainActor final class Edges {
        var micGranted = true
        /// While set, the microphone prompt waits for `answerMicrophone`.
        var holdMic = false
        private var micPrompt: CheckedContinuation<Bool, Never>?
        var micPromptWaiting: Bool { micPrompt != nil }
        var sounds: [SoundCue] = []
        var announcements: [String] = []
        var beeps = 0
        var settingsOpened = 0
        var callSettingsOpened = 0
        var tick: (@MainActor () -> Void)?

        func requestMicrophone() async -> Bool {
            guard holdMic else { return micGranted }
            return await withCheckedContinuation { micPrompt = $0 }
        }

        func answerMicrophone(_ granted: Bool) {
            holdMic = false
            micPrompt?.resume(returning: granted)
            micPrompt = nil
        }
    }

    static let defaultHealth = Health(correction: "available", notesStructure: true, notesCorrection: true)

    init(health: Health? = NotesHarness.defaultHealth, silence: TimeInterval = 1.5, speakers: SpeakerModelStore? = nil,
         voiceClient: VoiceLibraryClient = .unavailable, profiles: VoiceProfileStore? = nil,
         library: NotesLibrary? = nil, journalDirectory: URL? = nil, keptAudio: TimeInterval = NotesRecorder.maxKeptAudio,
         silencePause: TimeInterval = NotesCaptureSink.pauseAfter, callTap: SystemAudioTap? = nil,
         finalText: @escaping @Sendable (Int) -> String = { "Segment \($0)." }, storedTextSize: Double? = nil) {
        let clock = self.clock, edges = self.edges
        let streams = ScriptedStreams(sleep: { await clock.sleep($0) }, finalText: finalText)
        self.streams = streams
        store = speakers ?? FakeModelStore(downloaded: false)
        suite = "chirp-notes-harness-\(UUID().uuidString)"
        ownsJournal = journalDirectory == nil
        self.journalDirectory = journalDirectory ?? FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        prefs = Preferences(defaults: UserDefaults(suiteName: suite)!)
        prefs.serverURL = "http://127.0.0.1:9"   // never contacted: the sockets and HTTP are scripted
        prefs.correction = true
        prefs.soundsEnabled = true
        if let storedTextSize { prefs.notesTextSize = storedTextSize }
        // Labels are on by default; a harness without a speaker model turns them off (nothing to download).
        if speakers == nil { prefs.notesSpeakerLabels = false }
        self.health = health
        let config = ServerConfig(baseURL: URL(string: prefs.serverURL)!)
        var deps = NotesSessionDependencies(
            settings: prefs, engine: engine, makeSession: { streams.makeSession($0) },
            structure: http.structure(config), reorganize: http.reorganize(config), speakerStore: store,
            journalStore: NotesJournalStore(directory: self.journalDirectory))
        deps.library = library
        deps.edit = http.edit(config)
        deps.voiceClient = voiceClient
        if let profiles { deps.voiceProfileStore = profiles }
        deps.silenceGuard = { SilenceGuard(window: silence) }
        deps.workspaceNotifications = workspace
        deps.keptAudio = keptAudio
        deps.silencePause = silencePause
        deps.callTap = callTap
        deps.openCallAudioSettings = { edges.callSettingsOpened += 1 }
        deps.now = { clock.now }
        deps.sleep = { await clock.sleep($0) }
        deps.startTicker = { tick in edges.tick = tick; return { edges.tick = nil } }
        deps.requestMicrophone = { await edges.requestMicrophone() }
        deps.openMicrophoneSettings = { edges.settingsOpened += 1 }
        deps.play = { edges.sounds.append($0) }
        deps.beep = { edges.beeps += 1 }
        deps.announce = { edges.announcements.append($0) }
        session = NotesSession(deps)
        editor = NotesEditorCoordinator(model: session.model)
        editor.isFocused = { true }
        session.health = { [unowned self] in health }
        session.onChange = { [unowned self] in observe() }
        session.healthChanged()
    }

    deinit {
        removeTestDefaults(suite)
        if ownsJournal { try? FileManager.default.removeItem(at: journalDirectory) }
    }

    var model: NotesModel { session.model }
    var recorder: NotesRecorder { session.recorder }
    var document: NotesDocument { recorder.document }
    var status: String { model.statusText }
    /// What the user sees in the editor.
    var text: String { editor.textView.string }
    var transcript: [String] { document.segments.map { $0.isGap ? "⚠︎" : $0.text } }
    var gaps: Int { document.segments.filter(\.isGap).count }

    private func observe() {
        syncs += 1
        let version = model.document.version
        if version != editorVersion {
            editorVersion = version
            let start = ContinuousClock.now
            editor.update()
            editorUpdates.append((ContinuousClock.now - start).inSeconds)
        } else {
            editor.update()
        }
        let s = model.statusText
        if statuses.last != s { statuses.append(s) }
    }

    // MARK: steps

    /// Record (the window's button), then waits until the first socket is ready and the microphone is open.
    @discardableResult
    func record(waitForMic: Bool = true) async -> Self {
        session.toggle(fromHotkey: false)
        if waitForMic {
            // A speaker model loads first; an error (permission, the first socket) ends the wait too.
            await until("microphone open") {
                if case .error = self.model.state { return true }
                return self.engine.isTapped && self.recorder.state == .recording
            }
        }
        return self
    }

    @discardableResult
    func speak(_ seconds: Double) async -> Self { await play(.speech, seconds) }
    @discardableResult
    func pause(_ seconds: Double) async -> Self { await play(.pause, seconds) }
    /// Digital zeros, as a hardware mute delivers.
    @discardableResult
    func mute(_ seconds: Double) async -> Self { await play(.zero, seconds) }

    /// Plays audio a second at a time, letting the cuts it causes land (as they would between real capture buffers).
    private func play(_ sound: SyntheticEngine.Sound, _ seconds: Double) async -> Self {
        var left = seconds
        while left > 1e-9 {
            let chunk = min(1, left)
            engine.play(sound, seconds: chunk)
            left -= chunk
            await settle()
        }
        return self
    }

    /// Resume (a paused session), then waits until the microphone is open again.
    func resumeForTest() async {
        await session.resume()
        await until("microphone open") { self.engine.isTapped && self.recorder.state == .recording }
    }

    /// Stop (the window's button), then waits for Finishing to end.
    @discardableResult
    func stop() async -> Self {
        await session.stop()
        await settle()
        return self
    }

    /// Moves the fake clock (timeouts, the scheduler's timer, holds), then lets what woke up run.
    @discardableResult
    func advance(_ seconds: Double) async -> Self {
        clock.advance(seconds)
        await settle()
        return self
    }

    /// The once-a-second tick the window's elapsed time runs on.
    func fireTick() { edges.tick?() }

    /// Types at the end of the editor, as the user would (caret there first).
    @discardableResult
    func typeAtEnd(_ s: String) async -> Self {
        let end = (editor.textView.string as NSString).length
        editor.textView.setSelectedRange(NSRange(location: end, length: 0))
        editor.textView.insertText(s, replacementRange: NSRange(location: end, length: 0))
        await settle()
        return self
    }

    @discardableResult
    func undo() async -> Self {
        editor.textView.undoManager?.undo()
        await settle()
        return self
    }

    @discardableResult
    func redo() async -> Self {
        editor.textView.undoManager?.redo()
        await settle()
        return self
    }

    /// Lets queued tasks (socket events, passes, HTTP answers) run until the session is quiet for a moment.
    func settle() async {
        var quiet = 0
        var last = fingerprint
        for _ in 0..<400 where quiet < 3 {
            try? await Task.sleep(for: .milliseconds(2))
            let now = fingerprint
            quiet = now == last ? quiet + 1 : 0
            last = now
        }
        editor.update()
    }

    private var fingerprint: [Int] {
        [document.version, document.segments.count, streams.audioBytes, streams.attempts, http.calls,
         recorder.passInFlight ? 1 : 0, statuses.count, model.pendingChanges.count, recorder.finalizingCount]
    }

    /// Polls until `condition` holds for at most `seconds` of time this test got to run. In a full run another suite
    /// (the snapshot renderer) can hold the main actor for minutes; a gap between polls counts as one short poll, so
    /// starvation makes the wait longer instead of failing it.
    func until(_ what: String, within seconds: Double = 120, _ condition: () -> Bool) async {
        if !(await pollUntil(within: seconds, every: .milliseconds(5), condition)) { Issue.record("timed out waiting for \(what)") }
        editor.update()
    }

    // MARK: checks

    @discardableResult
    func expectStatus(_ s: String, sourceLocation: SourceLocation = #_sourceLocation) -> Self {
        #expect(status == s, sourceLocation: sourceLocation)
        return self
    }

    /// The editor shows exactly the document the recorder holds.
    @discardableResult
    func expectEditorInSync(sourceLocation: SourceLocation = #_sourceLocation) -> Self {
        editor.update()
        #expect(text == document.text, sourceLocation: sourceLocation)
        return self
    }
}

/// Removes a test's `UserDefaults(suiteName:)` domain and the empty plist that cfprefsd leaves behind in
/// ~/Library/Preferences after `removePersistentDomain`.
func removeTestDefaults(_ suite: String) {
    UserDefaults().removePersistentDomain(forName: suite)
    let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(suite).plist")
    try? FileManager.default.removeItem(at: file)
}

extension Duration {
    var inSeconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}

/// Polls `condition` until it holds (true) or `seconds` of time the caller got to run have passed (false). In a full
/// run another suite (the snapshot renderer) can hold the main actor for minutes; a gap between polls counts as one
/// short poll, so starvation makes the wait longer instead of failing it.
func pollUntil(within seconds: Double, every interval: Duration = .milliseconds(10),
               isolation: isolated (any Actor)? = #isolation, _ condition: () -> Bool) async -> Bool {
    var waited = 0.0, last = ContinuousClock.now
    while !condition() {
        if waited > seconds { return false }
        try? await Task.sleep(for: interval)
        let now = ContinuousClock.now
        waited += min((now - last).inSeconds, 0.05)
        last = now
    }
    return true
}
