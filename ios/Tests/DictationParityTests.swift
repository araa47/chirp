import AVFoundation
import ChirpCore
import ChirpIOSCore
import Foundation
import Testing
@testable import ChirpIOS

/// #271 wave 3: learned terms at dictation start (A2-5) and Stop dictation "When I pause" (A2-14).
@Suite("Dictation parity", .serialized)
@MainActor
struct DictationParityTests {
    @MainActor struct Fixture {
        let model: SessionCoordinator
        let transport: SyntheticTransport
        let audio: SyntheticAudio
        let stores: AppServices
        let root: URL
        func clean() { model.endSession(); try? FileManager.default.removeItem(at: root) }
    }
    func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-unit-" + UUID().uuidString)
        let stores = try AppServices(root: root, secrets: MemorySecretStore())
        let credentials = try PairingLink.parse("chirp://pair?url=https%3A%2F%2Fsynthetic.test.ts.net%2Fchirp&token=synthetic-only")
        try await stores.pairing.verifyAndSave(credentials, health: { _ in Health(engine: "synthetic", ready: true) })
        FlakyHTTP.failure = nil
        let http = URLSessionConfiguration.ephemeral; http.protocolClasses = [FlakyHTTP.self]
        let transport = SyntheticTransport(), audio = SyntheticAudio()
        let model = SessionCoordinator(services: stores, audio: audio, http: URLSession(configuration: http),
            makeStream: { _, options, _ in StreamSession(transport: transport, options: options) },
            requestPermission: { true }, permissionGranted: { true }, activityBegin: { _ in }, activityActive: { true },
            activityUpdate: { _, _ in }, activityEnd: {}, copyText: { _ in }, appActive: { true }, production: false)
        return Fixture(model: model, transport: transport, audio: audio, stores: stores, root: root)
    }
    func eventually(_ check: () -> Bool) async throws {
        for _ in 0..<600 {
            if check() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(check(), "Expected synthetic event to complete within three seconds")
    }
    func startMessage(_ f: Fixture) throws -> [String: Any] {
        let text = try #require(f.transport.sent.lazy.compactMap { if case .string(let v) = $0, v.contains(#""type":"start""#) { v } else { nil } }.first)
        return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    @Test func learnedTermsGoWithTheStartAndRespellTheFinal() async throws {
        let f = try await fixture(); defer { f.clean() }
        try f.stores.history.setEnabled(true)
        try f.stores.learned.learn(inserted: "ask get hub", edited: "ask GitHub", said: nil, explicit: true)
        try await f.model.begin()
        f.transport.push(#"{"type":"ready","session":"synthetic","debug_retention":false}"#)
        try await eventually { f.model.phase == .listening }
        let learned = try #require(try startMessage(f)["learned"] as? [String: Any])
        let terms = try #require(learned["terms"] as? [[String: Any]])
        #expect(terms.first?["term"] as? String == "GitHub" && learned["style"] == nil)
        f.model.stopDictation()
        f.transport.push(#"{"type":"final","text":"open get hub now","raw":"open get hub now"}"#)
        try await eventually { f.model.phase == .finished }
        #expect(f.model.text == "open GitHub now")
    }

    @Test func nothingLearnedIsSentInAPrivateSessionOrWithLearningOff() async throws {
        let f = try await fixture(); defer { f.clean() }
        try f.stores.history.setEnabled(true)
        try f.stores.learned.learn(inserted: "ask get hub", edited: "ask GitHub", said: nil, explicit: true)
        f.model.preferences.learnFromEdits = false; f.model.savePreferences()
        try await f.model.begin()
        try await eventually { !f.transport.sent.isEmpty }
        #expect(try startMessage(f)["learned"] == nil)
    }

    @Test func stopOnPauseIsOffUnlessChosenAndNeverForHoldToTalk() async throws {
        let f = try await fixture(); defer { f.clean() }
        try await f.model.begin()
        #expect(f.audio.autoStops.last?.silence == nil)
        f.model.cancelDictation()
        f.model.preferences.stopOnPause = true; f.model.preferences.pauseSeconds = 1.5; f.model.savePreferences()
        try await f.model.begin()
        #expect(f.audio.autoStops.last?.silence == 1.5)
        f.model.cancelDictation()
        try await f.model.begin(autoStop: false)
        #expect(f.audio.autoStops.last?.silence == nil)
    }

    @Test func keepListeningHasNoPauseAndNoTenMinuteTimer() async throws {
        let off = try await fixture(); defer { off.clean() }
        off.model.preferences.stopOnPause = true; off.model.preferences.pauseSeconds = 1.5; off.model.savePreferences()
        try await off.model.begin()
        #expect(off.audio.autoStops.last?.silence == 1.5 && off.model.limitsUtterance && !off.model.keepListening)
        // A second fixture: a fixture's streams share one synthetic transport, so a second dictation would miss its `ready`.
        let f = try await fixture(); defer { f.clean() }
        f.model.preferences.stopOnPause = true; f.model.preferences.pauseSeconds = 1.5
        f.model.preferences.continuousListening = true; f.model.savePreferences()
        try await f.model.begin()
        #expect(f.audio.autoStops.last?.silence == nil && !f.model.limitsUtterance && f.model.keepListening)
        f.transport.push(#"{"type":"ready","session":"synthetic","debug_retention":false}"#)
        try await eventually { f.model.phase == .listening }
        // Only Stop ends it.
        f.model.stopDictation()
        try await eventually { f.audio.finishCount == 1 }
        f.transport.push(#"{"type":"final","text":"Still here.","raw":"Still here."}"#)
        try await eventually { f.model.phase == .finished }
        #expect(f.model.text == "Still here.")
    }

    @Test func aPauseStopsTheDictationLikeTappingStop() async throws {
        let f = try await fixture(); defer { f.clean() }
        f.model.preferences.stopOnPause = true; f.model.savePreferences()
        try await f.model.begin()
        f.transport.push(#"{"type":"ready","session":"synthetic","debug_retention":false}"#)
        try await eventually { f.model.phase == .listening }
        try #require(f.audio.autoStops.last).fire()
        try await eventually { f.audio.finishCount == 1 }
        try await eventually { f.transport.sent.contains { if case .string(let v) = $0 { v == ClientMessage.stop } else { false } } }
        f.transport.push(#"{"type":"final","text":"Paused here.","raw":"Paused here."}"#)
        try await eventually { f.model.phase == .finished }
        #expect(f.model.text == "Paused here." && f.model.armed)
    }
}

@Suite("Stop on pause in the capture sink")
struct CaptureSinkAutoStopTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func add() { lock.withLock { value += 1 } }
    }
    func buffer(_ amplitude: Float, seconds: Double) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let samples = AVAudioFrameCount(16_000 * seconds)
        let value = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: samples))
        value.frameLength = samples
        if let data = value.floatChannelData?[0] { for i in 0..<Int(samples) { data[i] = amplitude * sin(2 * .pi * 220 * Float(i) / 16_000) } }
        return value
    }

    @Test func firesOnceAfterSpeechThenSilenceAndCarriesOverCuts() async throws {
        let session = StreamSession(transport: SyntheticTransport(), options: StartOptions())
        let next = StreamSession(transport: SyntheticTransport(), options: StartOptions())
        let sink = CaptureSink(), stops = Counter()
        sink.configure(format: try buffer(0, seconds: 0.1).format)
        await session.open(); await next.open()
        try sink.begin(session, onFailure: {}, onLimit: {}, autoStop: 1, onAutoStop: { stops.add() }); sink.ready()
        sink.receive(try buffer(0.001, seconds: 0.5)) // the room
        sink.receive(try buffer(0.2, seconds: 0.5)) // speech
        sink.cut(to: next); sink.ready()
        sink.receive(try buffer(0.001, seconds: 0.6))
        #expect(stops.count == 0)
        sink.receive(try buffer(0.001, seconds: 0.9))
        #expect(stops.count == 1)
        sink.receive(try buffer(0.001, seconds: 2))
        #expect(stops.count == 1)
        sink.discard(); await session.close(); await next.close()
    }

    @Test func neverBeforeSpeechUntilTheNoSpeechTimeout() async throws {
        let session = StreamSession(transport: SyntheticTransport(), options: StartOptions())
        let sink = CaptureSink(), stops = Counter()
        sink.configure(format: try buffer(0, seconds: 0.1).format)
        await session.open()
        try sink.begin(session, onFailure: {}, onLimit: {}, autoStop: 1, onAutoStop: { stops.add() }); sink.ready()
        sink.receive(try buffer(0.001, seconds: 9))
        #expect(stops.count == 0)
        sink.receive(try buffer(0.001, seconds: 1.5))
        #expect(stops.count == 1)
        sink.discard(); await session.close()
    }

    /// "Keep listening until I stop" (#381): no pause detector, and segments keep handing over past ten minutes of
    /// audio, mostly silent, without a limit, a failure or a stop.
    @Test func keepListeningRollsPastTenMinutesOfMostlySilentAudio() async throws {
        func stream() async -> StreamSession {
            var limits = StreamLimits(); limits.maxQueuedBytes = 40_000_000
            let session = StreamSession(transport: SyntheticTransport(), options: StartOptions(), limits: limits)
            await session.open()
            return session
        }
        let sink = CaptureSink(), stops = Counter(), limits = Counter(), failures = Counter(), cuts = Counter()
        sink.configure(format: try buffer(0, seconds: 0.1).format)
        var sessions = [await stream()]
        try sink.begin(sessions[0], onFailure: { failures.add() }, onLimit: { limits.add() }, onCut: { cuts.add() },
                       autoStop: nil, onAutoStop: { stops.add() }); sink.ready()
        let speech = try buffer(0.2, seconds: 1), quiet = try buffer(0.001, seconds: 1), silent = try buffer(0, seconds: 1)
        for second in 0..<660 {
            sink.receive(second < 2 ? speech : second < 300 ? silent : quiet)
            if cuts.count == sessions.count {        // the coordinator's rollOver: the next segment takes over
                sessions.append(await stream()); sink.cut(to: sessions.last!); sink.ready()
            }
            await Task.yield()
        }
        #expect(stops.count == 0 && limits.count == 0 && failures.count == 0)
        #expect(sessions.count >= 8)                   // 660 s in segments of at most 90 s
        sink.discard(); for session in sessions { await session.close() }
    }

    @Test func offWithoutASilence() async throws {
        let session = StreamSession(transport: SyntheticTransport(), options: StartOptions())
        let sink = CaptureSink(), stops = Counter()
        sink.configure(format: try buffer(0, seconds: 0.1).format)
        await session.open()
        try sink.begin(session, onFailure: {}, onLimit: {}, onAutoStop: { stops.add() }); sink.ready()
        sink.receive(try buffer(0.2, seconds: 0.5))
        sink.receive(try buffer(0, seconds: 12))
        #expect(stops.count == 0)
        sink.discard(); await session.close()
    }
}
