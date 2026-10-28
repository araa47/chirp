import Foundation
import Testing
@testable import ChirpCore

// Re-transcribe a note from its kept audio (#287 M): the decoder, the word → turn re-attribution, apply / restore,
// and the runner against an in-memory `/v1/stream` server. Nothing touches the network.

// MARK: a scripted re-transcribe server

/// What one socket answers, in the order the sockets started.
private enum Reply: Sendable {
    case final(text: String, raw: String? = nil, words: [(String, Double, Double)]? = nil, correcting: Bool = false)
    case refuse(String)
    case errorAtStop(String)
    /// Never answers `stop` (the final's deadline runs out).
    case stall
}

private final class RetranscribeServer: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [Reply]
    private var _starts: [[String: Any]] = []
    private var _stops: [[String: Any]] = []
    private var _audio: [Int] = []
    private var _cancels = 0
    let engine: String

    init(_ replies: [Reply], engine: String = "parakeet-mlx:parakeet-v3") {
        self.replies = replies
        self.engine = engine
    }

    var starts: [[String: Any]] { lock.withLock { _starts } }
    var stops: [[String: Any]] { lock.withLock { _stops } }
    var audioBytes: [Int] { lock.withLock { _audio } }
    var cancels: Int { lock.withLock { _cancels } }

    func makeSession(_ options: StartOptions) -> StreamSession {
        StreamSession(transport: Transport(server: self), options: options)
    }

    fileprivate func start(_ json: [String: Any]) -> (Int, Reply) {
        lock.withLock {
            _starts.append(json)
            _audio.append(0)
            let i = _starts.count - 1
            return (i, replies.isEmpty ? .final(text: "Text \(i).") : replies.removeFirst())
        }
    }

    fileprivate func stop(_ json: [String: Any]) { lock.withLock { _stops.append(json) } }
    fileprivate func audio(_ bytes: Int, socket: Int) { lock.withLock { _audio[socket] += bytes } }
    fileprivate func cancelled() { lock.withLock { _cancels += 1 } }

    final class Transport: StreamTransport, @unchecked Sendable {
        private let lock = NSLock()
        private let server: RetranscribeServer
        private var inbox: [URLSessionWebSocketTask.Message] = []
        private var waiter: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
        private var failure: Error?
        private var socket: (Int, Reply)?

        init(server: RetranscribeServer) { self.server = server }

        func resume() {}

        func send(_ message: URLSessionWebSocketTask.Message) async throws {
            if let failure = lock.withLock({ failure }) { throw failure }
            switch message {
            case .string(let s):
                let json = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] ?? [:]
                switch json["type"] as? String {
                case "start":
                    let (i, reply) = server.start(json)
                    lock.withLock { socket = (i, reply) }
                    if case .refuse(let code) = reply { deliver(["type": "error", "code": code, "message": "scripted"]); return }
                    deliver(["type": "ready", "session": "s\(i)", "engine": server.engine, "debug_retention": false])
                case "stop":
                    server.stop(json)
                    guard let (_, reply) = lock.withLock({ socket }) else { return }
                    switch reply {
                    case .final(let text, let raw, let words, let correcting):
                        let raw = raw ?? text
                        if correcting { deliver(["type": "correcting", "seq": 1, "raw": raw, "profile": "live_notes"]) }
                        var final: [String: Any] = ["type": "final", "text": text, "raw": raw, "corrected": text != raw,
                                                    "engine": server.engine]
                        if let words { final["words"] = words.map { ["text": $0.0, "start": $0.1, "end": $0.2] } }
                        deliver(final)
                    case .errorAtStop(let code): deliver(["type": "error", "code": code, "message": "scripted"])
                    case .stall, .refuse: break
                    }
                case "cancel":
                    server.cancelled()
                default: break
                }
            case .data(let d):
                if let (i, _) = lock.withLock({ socket }) { server.audio(d.count, socket: i) }
            @unknown default: break
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

        func cancel(with code: URLSessionWebSocketTask.CloseCode) {
            let c = lock.withLock { () -> CheckedContinuation<URLSessionWebSocketTask.Message, Error>? in
                guard failure == nil else { return nil }
                failure = URLError(.cancelled)
                defer { waiter = nil }
                return waiter
            }
            c?.resume(throwing: URLError(.cancelled))
        }

        private func deliver(_ object: [String: Any]) {
            let json = String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
            let c = lock.withLock { () -> CheckedContinuation<URLSessionWebSocketTask.Message, Error>? in
                guard failure == nil else { return nil }
                if let w = waiter { waiter = nil; return w }
                inbox.append(.string(json))
                return nil
            }
            c?.resume(returning: .string(json))
        }
    }
}

/// How many times the re-transcribe deadline has been armed. The stalled-final test times out the first clip only.
private final class ArmCount: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}

/// Records the waits asked for; returns at once.
private final class Waits: @unchecked Sendable {
    private let lock = NSLock()
    private var _seconds: [Double] = []
    var seconds: [Double] { lock.withLock { _seconds } }
    func wait(_ d: Duration) async {
        let c = d.components
        lock.withLock { _seconds.append(Double(c.seconds) + Double(c.attoseconds) / 1e18) }
    }
}

private let notesHealth = Health(notesCorrection: true, notesContext: true, notesRetranscribe: true)
private let notesOptions = StartOptions(client: "mac", correction: true, correctionProfile: CorrectionProfile.liveNotesID)

/// One second of 16 kHz PCM16 per clip, whatever it is.
private let silentClip: @Sendable (NotesRetranscribeClip) async throws -> Data = { Data(count: Int($0.duration * 32000)) }

private func clip(_ segment: Int, offset: TimeInterval = 0, duration: TimeInterval = 1, previous: String? = nil) -> NotesRetranscribeClip {
    NotesRetranscribeClip(segment: segment, offset: offset, duration: duration, previousText: previous)
}

/// A labelled note: segment 0 has Person 1 then Person 2 (the second turn reassigned by hand), segment 1 one person,
/// and segment 2 a gap. Every segment reads "WRONG TEXT".
private func labelledNote() -> NotesDocument {
    var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 1_800_000_000))
    var s0 = NotesSegment(id: 0, offset: 10, raw: "wrong text wrong text", text: "WRONG TEXT WRONG TEXT")
    s0.end = 14
    d.append(s0)
    d.attachSpeakers([SpeakerAttribution.Turn(slot: 0, start: 10, text: "WRONG TEXT"),
                      SpeakerAttribution.Turn(slot: 1, start: 12, text: "WRONG TEXT")], toSegment: 0)
    var s1 = NotesSegment(id: 1, offset: 14, raw: "wrong text", text: "WRONG TEXT")
    s1.end = 16
    s1.pauseBefore = 0.3
    d.append(s1)
    d.attachSpeakers([SpeakerAttribution.Turn(slot: 0, start: 14, text: "WRONG TEXT")], toSegment: 1)
    d.append(.gap(id: 2, offset: 16, reason: "server offline"))
    d.renameSpeaker(1, to: "Maya")
    d.reassignTurns([SpeakerTurnRef(segment: 0, index: 1)], to: 1)
    return d
}

@Suite(.serialized) struct NotesRetranscribeTests {
    // MARK: decoder

    @Test func keptAudioDecodesBackToTheSamePCM() throws {
        let rate = 16_000.0
        // Two seconds of a voice-like mix: 220 Hz with harmonics, swelling in amplitude.
        let samples: [Int16] = (0..<32_000).map { i in
            let t = Double(i) / rate
            let envelope = 0.3 + 0.2 * sin(2 * .pi * 1.5 * t)
            let v = envelope * (sin(2 * .pi * 220 * t) + 0.5 * sin(2 * .pi * 440 * t) + 0.25 * sin(2 * .pi * 660 * t)) / 1.75
            return Int16(max(-1, min(1, v)) * 30_000)
        }
        let pcm = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-decode-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("audio", isDirectory: true).appendingPathComponent("0.m4a")
        // Frames as capture delivers them (100 ms each).
        let frames = stride(from: 0, to: pcm.count, by: 3200).map { pcm[$0..<min($0 + 3200, pcm.count)] }.map { Data($0) }
        _ = try NotesAudioEncoder.write(frames, sampleRate: rate, to: url)

        let fromFile = try NotesAudioDecoder.decode(contentsOf: url)
        let fromMemory = try NotesAudioDecoder.decode(try Data(contentsOf: url))
        #expect(fromFile == fromMemory)
        let decoded = fromMemory.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        // Within one AAC frame (1024 samples) of the original length.
        #expect(abs(decoded.count - samples.count) <= 1024)
        // The waveform survives: strong correlation with the original at (near) zero lag.
        func correlation(lag: Int) -> Double {
            var xy = 0.0, xx = 0.0, yy = 0.0
            for i in 2000..<(min(samples.count, decoded.count) - 2000) {
                let x = Double(samples[i]), y = Double(decoded[i + lag])
                xy += x * y; xx += x * x; yy += y * y
            }
            return xy / sqrt(xx * yy)
        }
        let best = (-64...64).map(correlation).max() ?? 0
        #expect(best > 0.9)
    }

    @Test func aSealedClipDecodesFromMemoryAndGarbageFails() throws {
        #expect(throws: NotesAudioDecoder.Failure.self) { try NotesAudioDecoder.decode(Data()) }
        #expect(throws: NotesAudioDecoder.Failure.self) { try NotesAudioDecoder.decode(Data("not audio".utf8)) }
    }

    // MARK: re-attribution

    @Test func newWordsGoToTheTurnHoldingTheirMidpoint() {
        let turns = [SpeakerTurn(person: 1, start: 10, text: "old a"), SpeakerTurn(person: 2, start: 12, text: "old b", manual: true)]
        // Clip starts at 9.5 (a hard cut's overlap): words are clip-relative.
        let words = [WordTiming(text: "we", start: 0.5, end: 0.8), WordTiming(text: "ship", start: 0.9, end: 1.3),
                     WordTiming(text: "friday", start: 1.4, end: 2.0), WordTiming(text: "sounds", start: 2.7, end: 3.0),
                     WordTiming(text: "good", start: 3.1, end: 3.4)]
        let out = NotesRetranscription.reattribute(turns, words: words, raw: "we ship friday sounds good",
                                                   text: "We ship Friday. Sounds good!", clipOffset: 9.5, end: 14)
        #expect(out.count == 2)
        #expect(out.map(\.person) == [1, 2] && out[1].manual && !out[0].manual)
        #expect(out[0].text == "We ship Friday." && out[0].raw == "we ship friday")
        #expect(out[1].text == "Sounds good!" && out[1].raw == "sounds good")
        #expect(out.map(\.start) == [10, 12])
    }

    @Test func aWordOutsideEveryTurnGoesToTheNearestAndATurnMayEndUpEmpty() {
        let turns = [SpeakerTurn(person: 1, start: 10, text: "a"), SpeakerTurn(person: 2, start: 11, text: "b"),
                     SpeakerTurn(person: 1, start: 13, text: "c")]
        // Everything lands in the first and last turns; a word before the first turn's start goes to it.
        let words = [WordTiming(text: "early", start: 0, end: 0.2), WordTiming(text: "late", start: 4.5, end: 4.8)]
        let out = NotesRetranscription.reattribute(turns, words: words, raw: "early late", text: "Early late.",
                                                   clipOffset: 9, end: 14)
        #expect(out.map(\.text) == ["Early", "", "late."])
        #expect(out.map(\.person) == [1, 2, 1])
    }

    @Test func withoutWordTimingsOneTurnTakesAllAndSeveralSplitByDuration() {
        let one = NotesRetranscription.reattribute([SpeakerTurn(person: 3, start: 5, text: "x", manual: true)], words: nil,
                                                   raw: "a b c", text: "A b c.", clipOffset: 5, end: 9)
        #expect(one.map(\.text) == ["A b c."] && one[0].manual && !one[0].approximate)

        let turns = [SpeakerTurn(person: 1, start: 0, text: "x"), SpeakerTurn(person: 2, start: 3, text: "y")]
        let out = NotesRetranscription.reattribute(turns, words: nil, raw: "one two three four", text: "One two three four.",
                                                   clipOffset: 0, end: 4)
        #expect(out.map(\.text) == ["One two three", "four."])
        #expect(out.allSatisfy(\.approximate) && out.map(\.person) == [1, 2])
    }

    @Test func emptyTurnsAreSkippedInTheTranscriptButKeepTheirIndex() {
        var d = labelledNote()
        d.applyRetranscription([NotesRetranscribedSegment(
            segment: 0, raw: "hello there", text: "Hello there.",
            words: [WordTiming(text: "hello", start: 0.1, end: 0.4), WordTiming(text: "there", start: 0.5, end: 0.9)],
            clipOffset: 10)])
        #expect(d.segments[0].turns?.count == 2)
        #expect(d.segments[0].turns?[1].text == "" && d.segments[0].turns?[1].manual == true)
        // Maya's first turn, then segment 1 (Maya too, without a break): turn 0.1 is not shown.
        let first = d.transcriptParagraphs[0]
        #expect(first.parts.map(\.id) == ["0.0", "1.0"] && first.text() == "Hello there. WRONG TEXT")
        #expect(d.labelledText(d.segments[0]) == "Maya: Hello there.")
    }

    // MARK: apply and restore

    @Test func applyKeepsTimingAndPeopleAndRestoreRoundTrips() throws {
        let original = labelledNote()
        var d = original
        let results = [
            NotesRetranscribedSegment(segment: 0, raw: "we ship friday sounds good", text: "We ship Friday. Sounds good.",
                                      words: [WordTiming(text: "we", start: 0.2, end: 0.4), WordTiming(text: "ship", start: 0.5, end: 0.9),
                                              WordTiming(text: "friday", start: 1.0, end: 1.6), WordTiming(text: "sounds", start: 2.3, end: 2.7),
                                              WordTiming(text: "good", start: 2.8, end: 3.1)],
                                      clipOffset: 10, engine: "parakeet-mlx:parakeet-v3"),
            NotesRetranscribedSegment(segment: 2, raw: "the gap is back", text: "The gap is back.", clipOffset: 16,
                                      engine: "parakeet-mlx:parakeet-v3"),
        ]
        let updated = d.applyRetranscription(results, at: Date(timeIntervalSince1970: 1_800_000_100))
        #expect(updated == 2)
        #expect(d.segments[0].text == "We ship Friday. Sounds good." && d.segments[0].engine == "parakeet-mlx:parakeet-v3")
        #expect(d.segments[0].turns?.map(\.text) == ["We ship Friday.", "Sounds good."])
        #expect(d.segments[0].turns?.map(\.person) == original.segments[0].turns?.map(\.person))
        #expect(d.segments[0].turns?[1].manual == true)
        #expect(d.segments.map(\.offset) == original.segments.map(\.offset) && d.segments.map(\.end) == original.segments.map(\.end))
        #expect(d.segments[1] == original.segments[1])
        #expect(!d.segments[2].isGap && d.segments[2].text == "The gap is back.")
        #expect(d.roster == original.roster && d.text == original.text)
        #expect(d.previousTranscript?.segments.map(\.id) == [0, 2] && d.previousTranscript?.engine == nil)
        #expect(d.transcribedWith == NotesSpeechModel.mixed)
        #expect(d.transcriptMarkdown().contains("Maya") && !d.transcriptMarkdown().contains("WRONG TEXT WRONG TEXT"))

        let applied = d
        let undone = d.restorePreviousTranscript()
        #expect(undone && d.segments == original.segments)
        let redone = d.restorePreviousTranscript()
        #expect(redone && d.segments == applied.segments)

        // Through the journal, as after a relaunch.
        let back = try JSONDecoder().decode(NotesJournalRecord.self, from: JSONEncoder().encode(NotesJournalRecord(document: d, elapsed: 20)))
        var restored = back.document
        #expect(restored.previousTranscript == d.previousTranscript && restored.segments == d.segments)
        let again = restored.restorePreviousTranscript()
        #expect(again && restored.segments == original.segments)
    }

    @Test func aReassignmentMadeAfterTheRunSurvivesRestore() {
        var d = labelledNote()
        d.applyRetranscription([NotesRetranscribedSegment(segment: 1, raw: "fine", text: "Fine.", clipOffset: 14)])
        d.reassignTurns([SpeakerTurnRef(segment: 1, index: 0)], to: 2)
        d.restorePreviousTranscript()
        #expect(d.segments[1].text == "WRONG TEXT" && d.segments[1].turns?[0].person == 2)
    }

    @Test func emptyOrUnknownResultsChangeNothing() {
        var d = labelledNote()
        let before = d
        let changed = d.applyRetranscription([NotesRetranscribedSegment(segment: 0, raw: "", text: "  "),
                                              NotesRetranscribedSegment(segment: 9, raw: "x", text: "x")])
        let restored = d.restorePreviousTranscript()
        #expect(changed == 0 && d == before && !restored)
    }

    @Test func oldNotesDecodeWithoutTheNewFields() throws {
        var d = labelledNote()
        d.livePartial = ""
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(NotesJournalRecord(document: d, elapsed: 3))) as! [String: Any]
        var document = json["document"] as! [String: Any]
        document.removeValue(forKey: "previousTranscript")
        document["segments"] = (document["segments"] as! [[String: Any]]).map { var s = $0; s.removeValue(forKey: "engine"); return s }
        json["document"] = document
        let record = try JSONDecoder().decode(NotesJournalRecord.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(record.schema == 2 && record.document.previousTranscript == nil)
        #expect(record.document.segments.allSatisfy { $0.engine == nil } && record.document.transcribedWith == nil)
    }

    @Test func modelNamesReadForPeople() {
        #expect(NotesSpeechModel.displayName("parakeet-mlx:tdt-0.6b-v2") == "Parakeet v2 (MLX)")
        #expect(NotesSpeechModel.displayName("parakeet-mlx:parakeet-v3") == "Parakeet v3 (MLX)")
        #expect(NotesSpeechModel.displayName("parakeet-onnx:tdt-0.6b-v2-int8") == "Parakeet v2 (ONNX)")
        #expect(NotesSpeechModel.displayName("sensevoice-small:fp32-cpu:auto") == "SenseVoice Small")
        #expect(NotesSpeechModel.displayName(nil) == "unknown")
        #expect(NotesSpeechModel.displayName(NotesSpeechModel.mixed) == "mixed models")
    }

    @Test func aRebuildIsOneUndoableChangeTheSnapshotsKeep() {
        var d = labelledNote()
        d.userEdit(NSRange(location: 0, length: 0), "My own notes")
        let before = d.text
        let change = d.replaceBody(with: "## Plan\n- Ship Friday", fallbackBlocks: [])
        #expect(change?.kind == .rebuild && d.text == "## Plan\n- Ship Friday" && d.tailStart == d.text.utf16.count)
        #expect(d.nextStructureRequest() == nil)
        var snapshots = NotesSnapshots()
        snapshots.record([change!], from: before, result: d.text, at: Date())
        #expect(snapshots.latest?.before == before && snapshots.latest?.rebuild == true)
    }

    // MARK: clips

    @Test func clipsCarryTheHardCutOverlapAndTheTextBefore() {
        var d = labelledNote()
        d.ensureMetadata()
        d.libraryMetadata?.audio = [
            NotesAudioReference(id: 0, offset: 10, duration: 4, sampleRate: 16_000, bytes: 1),
            // Starts 0.8 s before clip 0 ends: a hard cut.
            NotesAudioReference(id: 1, offset: 13.2, duration: 2.8, sampleRate: 16_000, bytes: 1),
        ]
        let clips = NotesRetranscriber.clips(for: d)
        #expect(clips.map(\.segment) == [0, 1])
        #expect(clips[0].leading == 0 && abs(clips[0].trailing - 0.8) < 0.001)
        #expect(abs(clips[1].leading - 0.8) < 0.001 && clips[1].trailing == 0)
        #expect(clips[0].previousText == nil && clips[1].previousText == "WRONG TEXT WRONG TEXT")
        let one = NotesRetranscriber.clips(for: d, only: 1)
        #expect(one.count == 1 && abs(one[0].leading - 0.8) < 0.001)
    }

    // MARK: the runner

    @Test func clipsGoInOrderWithTheFlagAndTheNewTextAsContext() async {
        let server = RetranscribeServer([.final(text: "First segment."), .final(text: "Second one.", correcting: true)])
        let runner = NotesRetranscriber(makeSession: server.makeSession, options: notesOptions, health: notesHealth,
                                        audio: silentClip)
        let result = await runner.run([clip(0), clip(1, offset: 1, previous: "OLD TEXT")])
        #expect(result.end == .finished && result.failed == 0)
        #expect(result.segments.map(\.text) == ["First segment.", "Second one."])
        #expect(result.segments.allSatisfy { $0.engine == "parakeet-mlx:parakeet-v3" })
        #expect(server.starts.count == 2)
        #expect(server.starts.allSatisfy { $0["retranscribe"] as? Bool == true && $0["word_timings"] as? Bool == true })
        #expect(server.starts.allSatisfy { $0["correction_profile"] as? String == "live_notes" && $0["speakers"] == nil })
        #expect(server.stops[0]["context"] == nil)
        #expect(server.stops[1]["context"] as? String == "First segment.")
        #expect(server.audioBytes == [32_000, 32_000])
        #expect(result.logLine == "notes retranscribe segments=2 audio_ms=2000 updated=2 failed=0 code=none")
    }

    @Test func aBusyServerIsRetriedWithBackoff() async {
        let server = RetranscribeServer([.refuse("busy"), .refuse("busy"), .refuse("busy"), .final(text: "Done.")])
        let waits = Waits()
        let runner = NotesRetranscriber(makeSession: server.makeSession, options: notesOptions, health: notesHealth,
                                        audio: silentClip, wait: waits.wait)
        let result = await runner.run([clip(0)])
        #expect(result.end == .finished && result.segments.map(\.text) == ["Done."])
        #expect(waits.seconds == [2, 4, 8])
    }

    @Test func aServerBusyThroughEveryRetryStopsTheRunWithWhatIsDone() async {
        let server = RetranscribeServer([.final(text: "Kept.")] + Array(repeating: .refuse("busy"), count: 11))
        let waits = Waits()
        let runner = NotesRetranscriber(makeSession: server.makeSession, options: notesOptions, health: notesHealth,
                                        audio: silentClip, wait: waits.wait)
        let result = await runner.run([clip(0), clip(1)])
        #expect(result.end == .stopped(code: "busy") && result.segments.map(\.text) == ["Kept."])
        #expect(waits.seconds == [2, 4, 8, 16, 30, 30, 30, 30, 30, 30])
    }

    @Test func aFailedClipKeepsItsOldTextAndAuthStopsEverything() async {
        let server = RetranscribeServer([.errorAtStop("engine"), .final(text: "Fine."), .final(text: "")])
        let runner = NotesRetranscriber(makeSession: server.makeSession, options: notesOptions, health: notesHealth,
                                        audio: { c in if c.segment == 3 { throw NotesAudioDecoder.Failure.empty }; return Data(count: 3200) })
        let result = await runner.run([clip(0), clip(1), clip(2), clip(3)])
        #expect(result.end == .finished && result.failed == 3 && result.segments.map(\.segment) == [1])

        let refused = RetranscribeServer([.final(text: "One."), .refuse("auth")])
        let auth = await NotesRetranscriber(makeSession: refused.makeSession, options: notesOptions, health: notesHealth,
                                            audio: silentClip).run([clip(0), clip(1), clip(2)])
        #expect(auth.end == .auth && refused.starts.count == 2)
    }

    @Test func aStalledFinalTimesOutAndTheClipKeepsItsText() async {
        let server = RetranscribeServer([.stall, .final(text: "Next.")])
        // The stalled clip never answers stop, so that deadline runs out at once. The next clip's final is already
        // on the socket when its deadline is armed; cancelling there too drops the final before it is emitted.
        // Waiting (the attempt cancels this sleep once the final lands) keeps the two apart.
        let arms = ArmCount()
        let runner = NotesRetranscriber(makeSession: server.makeSession, options: notesOptions, health: notesHealth,
                                        audio: silentClip, deadline: { _ in
            if arms.next() == 1 { return }
            try? await Task.sleep(for: .seconds(30))
        })
        let result = await runner.run([clip(0), clip(1)])
        #expect(result.failed == 1 && result.code == "timeout" && result.segments.map(\.segment) == [1])
    }

    @Test func cancelStopsTheInFlightClipAndDropsEverything() async {
        let server = RetranscribeServer([.final(text: "One."), .stall])
        let runner = NotesRetranscriber(makeSession: server.makeSession, options: notesOptions, health: notesHealth,
                                        audio: silentClip)
        let task = Task { await runner.run([clip(0), clip(1), clip(2)]) }
        #expect(await pollUntil(within: 60) { server.stops.count >= 2 })
        task.cancel()
        let result = await task.value
        #expect(result.end == .cancelled && result.segments.isEmpty)
        #expect(server.starts.count == 2)
    }

    @Test func noContextWithoutTheServerOrCleanUp() async {
        let server = RetranscribeServer([])
        let health = Health(notesCorrection: true, notesContext: false, notesRetranscribe: true)
        _ = await NotesRetranscriber(makeSession: server.makeSession, options: notesOptions, health: health, audio: silentClip)
            .run([clip(0), clip(1, previous: "Before.")])
        let off = RetranscribeServer([])
        _ = await NotesRetranscriber(makeSession: off.makeSession, options: StartOptions(client: "mac", correction: false,
                                                                                         correctionProfile: CorrectionProfile.liveNotesID),
                                     health: notesHealth, audio: silentClip).run([clip(1, previous: "Before.")])
        #expect((server.stops + off.stops).allSatisfy { $0["context"] == nil })
    }

    @Test func overlapIsTrimmedLikeLive() async {
        // Clip 1 starts 1 s before clip 0 ended: its first word was heard by clip 0 too.
        let server = RetranscribeServer([.final(text: "And then we left.", raw: "then and then we left",
                                                words: [("then", 0.1, 0.4), ("and", 1.1, 1.3), ("then", 1.4, 1.6),
                                                        ("we", 1.7, 1.9), ("left", 2.0, 2.4)])])
        let runner = NotesRetranscriber(makeSession: server.makeSession, options: notesOptions, health: notesHealth,
                                        audio: { _ in Data(count: 3 * 32_000) })
        var c = clip(1, offset: 9, duration: 3, previous: "We talked about it then")
        c.leading = 1
        let result = await runner.run([c])
        #expect(result.segments.first?.raw == "and then we left")
    }
}
