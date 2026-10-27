#if DEBUG
import AVFoundation
import ChirpCore
import ChirpIOSCore
import Foundation

/// Synthetic capture: quiet 50 ms frames at real-time pace. Not compiled into Release.
@MainActor
final class SyntheticNotesAudio: NotesAudio {
    private var feeder: Task<Void, Never>?
    private(set) var starts = 0
    private(set) var event: (@Sendable (NotesAudioEvent) -> Void)?
    var isRunning: Bool { feeder != nil }
    var fails = false
    func start(frame: @escaping @Sendable (Data) -> Void, event: @escaping @Sendable (NotesAudioEvent) -> Void) throws {
        guard !fails else { throw SessionFailure.audio }
        starts += 1
        self.event = event
        feeder?.cancel()
        feeder = Task.detached {
            var samples = [Int16](repeating: 0, count: PCMConverter.frameBytes / 2)
            for i in samples.indices { samples[i] = Int16(i % 2 == 0 ? 600 : -600) }
            let data = samples.withUnsafeBytes { Data($0) }
            while !Task.isCancelled {
                frame(data)
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
    func stop() { feeder?.cancel(); feeder = nil }
}

/// Simulator-only speech for Live Notes against a real local server (`--chirp-sim-audio <file>`, see
/// `SimulatorFileAudio`): the file once at real-time pace, then silence until Pause or Stop. Silent looping playback
/// keeps the app running in the background, as the microphone does on a device.
@MainActor
final class SimulatorNotesAudio: NotesAudio {
    private let url: URL
    private let keepAlive = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var feeder: Task<Void, Never>?
    var isRunning: Bool { feeder != nil }
    init(url: URL) { self.url = url }
    static func fromArguments() -> SimulatorNotesAudio? {
        #if targetEnvironment(simulator)
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "--chirp-sim-audio"), i + 1 < args.count else { return nil }
        let path = args[i + 1]
        return SimulatorNotesAudio(url: path.hasPrefix("/") ? URL(fileURLWithPath: path) : FileManager.default.temporaryDirectory.appendingPathComponent(path))
        #else
        return nil
        #endif
    }
    func start(frame: @escaping @Sendable (Data) -> Void, event: @escaping @Sendable (NotesAudioEvent) -> Void) throws {
        guard feeder == nil, let file = try? AVAudioFile(forReading: url), PCMConverter(from: file.processingFormat) != nil else { throw SessionFailure.audio }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: .mixWithOthers)
            try AVAudioSession.sharedInstance().setActive(true)
            let format = keepAlive.mainMixerNode.outputFormat(forBus: 0)
            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) else { throw SessionFailure.audio }
            silence.frameLength = silence.frameCapacity
            if player.engine == nil { keepAlive.attach(player) }
            keepAlive.connect(player, to: keepAlive.mainMixerNode, format: format)
            player.scheduleBuffer(silence, at: nil, options: .loops)
            try keepAlive.start()
            player.play()
        } catch { stop(); throw SessionFailure.audio }
        feeder = Task.detached { [url] in
            guard let file = try? AVAudioFile(forReading: url), let converter = PCMConverter(from: file.processingFormat) else { return }
            let chunk = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
            let silence = Data(count: PCMConverter.frameBytes)
            var ended = false
            while !Task.isCancelled {
                if !ended, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk),
                   (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0 {
                    for data in converter.frames(from: buffer) { frame(data) }
                } else {
                    ended = true
                    frame(silence); frame(silence)
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
    func stop() {
        feeder?.cancel(); feeder = nil
        player.stop(); keepAlive.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

extension LiveNotesController {
    /// The health of a current Mac server with clean-up on this Mac and every notes endpoint.
    static let syntheticHealth = Health(engine: "parakeet-mlx:tdt-0.6b-v3", ready: true, correction: "available", correctionLeavesMachine: false,
                                        notesStructure: true, notesCorrection: true, notesReorganize: true, notesContext: true,
                                        notesEdit: true, notesSpeakers: true, speakersModel: SpeakersModel(state: .ready, sizeBytes: 26_530_309),
                                        speechModel: "parakeet-v3", notesRetranscribe: true)

    /// UI-test controller: synthetic sockets (ready and a partial on start, a final on stop), a structuring stand-in that
    /// bullets the transcript, quiet synthetic capture and a throwaway encrypted store.
    static func synthetic(coordinator: SessionCoordinator) -> LiveNotesController {
        let args = ProcessInfo.processInfo.arguments
        let suite = args.firstIndex(of: "--chirp-notes-library-id").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-notes-ui-" + (suite ?? UUID().uuidString))
        let secrets: any SecretStore = suite == nil ? MemorySecretStore() : KeychainSecretStore()
        let store = try? NotesStore(root: root, secrets: secrets)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SyntheticHTTP.self]
        let voices = SyntheticVoiceLibrary()
        let withVoices = args.contains("--chirp-voices-gallery")
        let deps = Dependencies(
            server: { ServerConfig(baseURL: URL(string: "https://synthetic.test.ts.net/chirp")!, token: "synthetic-only") },
            correctionAllowed: { _ in true },
            otherCaptureActive: { [weak coordinator] in coordinator?.armed ?? false },
            http: URLSession(configuration: config),
            fetchHealth: { _, _ in
                var health = syntheticHealth
                if withVoices { health.speakerVoices = true }
                // Re-transcribe sheet states: an older server, and one that keeps debug recordings.
                if args.contains("--chirp-retranscribe-old-server") { health.notesRetranscribe = nil }
                if args.contains("--chirp-retranscribe-debug") { health.debugRetention = true }
                // An older server without Edit by voice, so the Command button is not offered.
                if args.contains("--chirp-no-notes-edit") { health.notesEdit = nil }
                return health
            },
            makeStream: { _, options, _ in StreamSession(transport: SyntheticTransport(automatic: true, voiceMatches: { withVoices ? voices.matches : [] }), options: options) },
            structure: { _, _, request, _ in syntheticStructure(request) },
            reorganize: { _, _, request, _ in syntheticReorganize(request) },
            editNotes: { _, _, request, _ in syntheticEdit(request) },
            fetchVoices: { _, _ in voices.value },
            voiceAction: { _, _, action in voices.perform(action) },
            audio: SyntheticNotesAudio(), requestPermission: { true }, activity: .none,
            store: store)
        return LiveNotesController(deps)
    }

    nonisolated static func syntheticStructure(_ request: NotesStructureRequest) -> NotesStructureResponse {
        let lines = request.transcript.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return NotesStructureResponse(markdown: "## Synthetic notes\n" + lines.map { "- " + $0 }.joined(separator: "\n"), structured: true)
    }

    /// Organize: sorts the bullets (headings first), so a change is visible and Undo can put it back.
    nonisolated static func syntheticReorganize(_ request: NotesReorganizeRequest) -> NotesReorganizeResponse {
        let lines = request.notes.components(separatedBy: "\n").filter { !$0.isEmpty }
        let organized = (lines.filter { !$0.hasPrefix("- ") } + lines.filter { $0.hasPrefix("- ") }.sorted()).joined(separator: "\n")
        return NotesReorganizeResponse(markdown: organized, reorganized: true, changed: organized != request.notes)
    }

    /// Edit by voice: the instruction becomes one bullet at the end, so the edit is visible and Undo can put it back.
    nonisolated static func syntheticEdit(_ request: NotesEditRequest) -> NotesEditResponse {
        NotesEditResponse(markdown: request.notes + "\n\n- Edited by voice: “\(request.instruction)”", edited: true, changed: true)
    }
    /// `--chirp-speakers-gallery`: the first note's transcript with two people (one renamed), as the server's labels
    /// would leave it, and notes that name "Person 1", so the rename sheet has something to offer.
    private static func labelGallerySegments(_ document: inout NotesDocument) {
        func turns(_ pairs: [(Int, Double, String)]) -> [ServerTurn] { pairs.map { ServerTurn(speaker: $0.0, start: $0.1, text: $0.2) } }
        document.attachServerTurns(turns([(0, 0, "Keep the launch in March."), (1, 4, "Send the proposal by Friday.")]),
                                   generation: "gallery", toSegment: 0)
        document.append(NotesSegment(id: 1, offset: 40, raw: "who will lead the beta maya can lead the beta i will send the notes",
                                     text: "Who will lead the beta? Maya can lead the beta. I will send the notes."))
        document.attachServerTurns(turns([(0, 0, "Who will lead the beta?"), (1, 3, "Maya can lead the beta."), (0, 6, "I will send the notes.")]),
                                   generation: "gallery", toSegment: 1)
        document.renameSpeaker(2, to: "Maya")
        document.userEdit(NSRange(location: document.text.utf16.count, length: 0), "\n\n- [ ] **Person 1** to send the notes")
    }

    /// `--chirp-retranscribe-seed <meeting.wav> <sentence.wav>` (the live re-transcribe e2e, #287 §6): two notes whose
    /// kept audio is real speech, sealed and AAC-encoded like a recording's, and whose transcript reads "WRONG TEXT", so
    /// whatever comes back is obviously from the audio. "Retranscribe meeting" has two people over two contiguous clips,
    /// Person 2 named Maya and one turn reassigned to her by hand; "Retranscribe gap" is one gap that kept its audio.
    /// Earlier copies are deleted first, so runs do not pile up.
    func seedRetranscribe(_ paths: [String]) async throws {
        // Once per launch: the library also reloads when the app comes back to the front.
        guard let library, paths.count == 2, !Self.retranscribeSeeded else { return }
        Self.retranscribeSeeded = true
        let titles = ["Retranscribe meeting", "Retranscribe gap"]
        for entry in try await library.store.list() + library.store.list(deleted: true) where titles.contains(entry.title) {
            try? await library.store.purge(entry.id)
        }
        let meeting = try Self.pcm(paths[0]), sentence = try Self.pcm(paths[1])
        let bytesPerSecond = Int(PCMConverter.sampleRate) * 2
        let cut = min(meeting.count / 2, 20 * bytesPerSecond) / 2 * 2
        let clips = [meeting.prefix(cut), meeting.dropFirst(cut)].map { Data($0) }
        let split = Double(cut) / Double(bytesPerSecond)
        func turns(_ pairs: [(Int, Double)]) -> [ServerTurn] { pairs.map { ServerTurn(speaker: $0.0, start: $0.1, text: "WRONG TEXT") } }

        var first = NotesDocument(startedAt: Date().addingTimeInterval(-600))
        var a = NotesSegment(id: 0, offset: 0, raw: "wrong text", text: "WRONG TEXT")
        a.end = split
        first.append(a)
        var b = NotesSegment(id: 1, offset: split, raw: "wrong text", text: "WRONG TEXT")
        b.pauseBefore = 0
        b.end = Double(meeting.count) / Double(bytesPerSecond)
        first.append(b)
        first.attachServerTurns(turns([(0, 0), (1, 7)]), generation: "seed", toSegment: 0)
        first.attachServerTurns(turns([(0, 0), (1, 6)]), generation: "seed", toSegment: 1)
        first.renameSpeaker(2, to: "Maya")
        first.reassignTurns([SpeakerTurnRef(segment: 1, index: 0)], to: 2)
        try await library.write(NotesJournalRecord(document: first, elapsed: b.end ?? 0, writtenAt: Date()))
        try await library.rename(first.id, title: titles[0])
        for (i, clip) in clips.enumerated() {
            try await library.keepAudio(first.id, segment: i, frames: [clip], offset: i == 0 ? 0 : split, sampleRate: PCMConverter.sampleRate)
        }

        var second = NotesDocument(startedAt: Date().addingTimeInterval(-300))
        second.append(NotesSegment(id: 0, offset: 0, raw: "", text: "", failure: "engine"))
        try await library.write(NotesJournalRecord(document: second, elapsed: Double(sentence.count) / Double(bytesPerSecond), writtenAt: Date()))
        try await library.rename(second.id, title: titles[1])
        try await library.keepAudio(second.id, segment: 0, frames: [sentence], offset: 0, sampleRate: PCMConverter.sampleRate)
    }

    private static var retranscribeSeeded = false

    /// A speech file as 16 kHz mono PCM16.
    nonisolated static func pcm(_ path: String) throws -> Data {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        guard let converter = PCMConverter(from: file.processingFormat),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw SessionFailure.audio
        }
        try file.read(into: buffer)
        return converter.frames(from: buffer).reduce(into: Data()) { $0.append($1) }
    }

    /// Synthetic documents for reproducible screenshots; the real sealed store and library are still exercised.
    func seedLibrary() async throws {
        guard let library, try await library.store.list().isEmpty else { return }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-notes-gallery-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = try NotesStore(root: root, secrets: MemorySecretStore())
        let samples: [(Int, String, TimeInterval)] = [
            (0, "## Lantern kickoff\n\n### Agenda\n- Review the launch plan\n- [x] Share the design brief\n\n### Next steps\n- [ ] Send the updated proposal by Friday\n- [ ] Book the next design review\n\n> **Decision:** Keep the launch in March.\n\n> **Question:** Who will lead the beta?", 192),
            (1, "## Design review\n\nWalk through the new onboarding flow and leave room for questions.\n- [ ] Share the revised sketches", 360),
            (5, "## Weekend ideas\n\nA walk by the lake, a good book, and a little time to think.", 75),
            (18, "## Garden plans\n\n- Plant herbs by the kitchen window\n- [ ] Pick up potting soil", 120),
            (50, "## Reading list\n\nA few things to come back to this autumn.", 0)
        ]
        for (days, text, elapsed) in samples {
            let date = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
            var document = NotesDocument(startedAt: date, text: text)
            document.append(NotesSegment(id: 0, offset: 12, raw: "We will keep the launch in March and send the proposal by Friday.", text: "Keep the launch in March. Send the proposal by Friday."))
            if days == 0, ProcessInfo.processInfo.arguments.contains("--chirp-speakers-gallery") { Self.labelGallerySegments(&document) }
            // `--chirp-retranscribe-gallery`: a gap ("audio not transcribed") that kept its audio, for Try again.
            let gap = days == 0 && ProcessInfo.processInfo.arguments.contains("--chirp-retranscribe-gallery") ? document.segments.count : nil
            if let gap { document.append(NotesSegment(id: gap, offset: 40 + Double(gap) * 30, raw: "", text: "", failure: "engine")) }
            var record = NotesJournalRecord(document: document, elapsed: elapsed, writtenAt: date)
            record.recovered = days == 1
            try seed.journalStore.write(record)
            try await library.store.migrate(from: seed.journalStore)
            var migrated = try await library.store.record(document.id)
            migrated.recovered = days == 1
            try await library.store.write(migrated)
            if days == 0 {
                try await library.store.keepAudio(document.id, segment: 0, frames: [Data(count: 64_000)], offset: 12, sampleRate: 16_000)
                if let gap {
                    try await library.store.keepAudio(document.id, segment: gap, frames: [Data(count: 32_000)], offset: 40 + Double(gap) * 30, sampleRate: 16_000)
                }
            }
        }
    }

}

/// In-memory stand-in, enabled only by the explicit saved-voice UI fixture flag.
private final class SyntheticVoiceLibrary: @unchecked Sendable {
    private let lock = NSLock()
    private var library = SavedVoices(enabled: true, model: "synthetic", voices: [SavedVoice(id: "0123456789abcdef", name: "Maya", seconds: 46,
                              created: Date(timeIntervalSince1970: 1_760_000_000), updated: Date(timeIntervalSince1970: 1_760_500_000))])
    var value: SavedVoices { lock.withLock { library } }
    var matches: [ServerVoiceMatch] { lock.withLock {
        library.enabled ? library.voices.prefix(1).map { ServerVoiceMatch(speaker: 0, voice: $0.id, name: $0.name) } : []
    } }
    func perform(_ action: VoiceLibraryAction) -> SavedVoices { lock.withLock {
        library.voice = nil
        switch action {
        case .remember(let name, _, let id):
            let voice = SavedVoice(id: id ?? "fedcba9876543210", name: name, seconds: 30, created: Date(), updated: Date())
            library.voices.removeAll { $0.id == voice.id }; library.voices.append(voice); library.voice = voice
        case .rename(let id, let name):
            if let i = library.voices.firstIndex(where: { $0.id == id }) { library.voices[i].name = name }
        case .forget(let id): library.voices.removeAll { $0.id == id }
        case .forgetAll: library.voices = []
        case .enable: library.enabled = true
        case .disable(let forget): library.enabled = false; if forget { library.voices = [] }
        case .importVoice: break
        }
        return library
    } }
}
#endif
