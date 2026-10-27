import Foundation
import Testing
import ChirpCore
@testable import ChirpIOSCore

private func temporaryRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value += seconds } }
}

struct PairingTests {
    @Test func validPairingPreservesBasePathAndKeepsTokenOutOfURLs() throws {
        let c = try PairingLink.parse("chirp://pair?url=https%3A%2F%2Fmac.tail123.ts.net%2Fchirp&token=synthetic")
        #expect(c.config.healthURL.absoluteString == "https://mac.tail123.ts.net/chirp/v1/health")
        #expect(c.config.streamURL.absoluteString == "wss://mac.tail123.ts.net/chirp/v1/stream")
        #expect(!c.description.contains("synthetic"))
        #expect(c.config.authorized(URLRequest(url: c.config.healthURL)).value(forHTTPHeaderField: "Authorization") == "Bearer synthetic")
    }
    @Test(arguments: [
        "chirp://pair?url=https://mac.tail.ts.net&token=a&token=b",
        "chirp://pair?url=https://mac.tail.ts.net&token=a&secret=b",
        "chirp://pair/?url=https://mac.tail.ts.net&token=a",
        "chirp://pair?url=https://mac.tail.ts.net&token=",
        "chirp://pair?url=https://mac.tail.ts.net&token=a%0D%0Ab",
        "chirp://other?url=https://mac.tail.ts.net&token=a",
        "chirp://user@pair?url=https://mac.tail.ts.net&token=a",
        "chirp://pair?url=https://mac.tail.ts.net&token=a#bad"
    ]) func invalidPairing(_ value: String) { #expect(throws: (any Error).self) { try PairingLink.parse(value) } }
    @Test(arguments: ["http://mac.tail.ts.net", "https://example.com", "https://ts.net", "https://evilts.net",
        "https://mac.ts.net.evil.com", "https://u:p@mac.ts.net", "https://mac.ts.net?q=x", "https://mac.ts.net#x",
        "https://mac.ts.net/../x", "https://mac.ts.net/%2e%2e", "https://mac..ts.net", "https://-mac.ts.net",
        "https://mac.ts.net./chirp", "https://mac.ts.net:0", "https://mac.ts.net\\@evil.com"])
    func invalidBase(_ value: String) { #expect(throws: (any Error).self) { try PairingLink.validateBaseURL(value) } }
    @Test func simulatorLoopbackIsExactAndNeverAcceptedOutsideTheSimulator() throws {
        #expect(PairingLink.simulatorLoopbackURL("http://127.0.0.1:7899")?.absoluteString == "http://127.0.0.1:7899")
        #expect(PairingLink.simulatorLoopbackURL("http://127.0.0.1:7899/")?.absoluteString == "http://127.0.0.1:7899")
        for bad in ["http://127.0.0.1", "http://127.0.0.1:80", "https://127.0.0.1:7899", "http://localhost:7899",
                    "http://127.0.0.2:7899", "http://127.0.0.1:7899/chirp", "http://u@127.0.0.1:7899",
                    "http://127.0.0.1:7899?x=1", "http://127.0.0.1:7899#x", "http://127.0.0.1:07899", "http://[::1]:7899"] {
            #expect(PairingLink.simulatorLoopbackURL(bad) == nil, "\(bad)")
        }
        // The package tests run on macOS, where only tailnet HTTPS pairs.
        #expect(throws: CoreError.invalidURL) { try PairingLink.validateBaseURL("http://127.0.0.1:7899") }
    }
    @Test func authenticatedHealthRequiredAndSecretsStayInKeychain() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let secrets = MemorySecretStore(); let store = try PairingStore(root: root, secrets: secrets)
        let credentials = try PairingCredentials(baseURL: URL(string: "https://mac.tail.ts.net/chirp")!, token: "synthetic-token-sentinel")
        await #expect(throws: CoreError.unauthorized) { try await store.verifyAndSave(credentials) { _ in Health() } }
        #expect(try store.load() == nil)
        try await store.verifyAndSave(credentials) { _ in Health(engine: "fake", ready: true) }
        #expect(try store.load() == credentials.config)
        for file in try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("pairing"), includingPropertiesForKeys: nil) {
            #expect(!(try Data(contentsOf: file)).contains(Data("synthetic-token-sentinel".utf8)))
        }
        try store.clear(); #expect(try store.load() == nil)
    }
    @Test func clearFencesLateHealth() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try PairingStore(root: root, secrets: MemorySecretStore())
        let credentials = try PairingCredentials(baseURL: URL(string: "https://mac.ts.net")!, token: "fake")
        await #expect(throws: CoreError.staleGeneration) {
            try await store.verifyAndSave(credentials) { _ in try store.clear(); return Health(engine: "fake", ready: true) }
        }
        #expect(try store.load() == nil)
    }
    @Test func ephemeralNetworkPolicyRejectsAllRedirects() throws {
        let session = SafeHTTPSession.make(); defer { session.invalidateAndCancel() }
        #expect(session.configuration.urlCache == nil)
        #expect(session.configuration.httpCookieStorage == nil)
        #expect(session.configuration.urlCredentialStorage == nil)
        #expect(!SafeHTTPSession.allowsRedirect(from: URL(string: "https://a.ts.net")!, to: URL(string: "https://b.ts.net")!))
    }
}

struct DefaultsMigrationTests {
    @Test func correctionDefaultsOnlyWhenUnsetAndKeepsExplicitChoices() throws {
        let local = Health(correction: "available", correctionLeavesMachine: false)
        let external = Health(correction: "available", correctionLeavesMachine: true, correctionHost: "cleanup.example")
        let decoder = JSONDecoder()
        let unset = try decoder.decode(IOSPreferences.self, from: Data("{}".utf8))
        #expect(unset.permitsCorrection(health: local))
        #expect(!unset.permitsCorrection(health: external))
        #expect(!unset.permitsCorrection(health: Health(correction: "available")))
        for choice in [true, false] {
            let old = Data("{\"correction\":\(choice),\"styleID\":\"chat\",\"prompts\":{},\"sessionDuration\":\"fiveMinutes\",\"privacyMode\":false,\"consentHost\":\"cleanup.example\"}".utf8)
            let saved = try decoder.decode(IOSPreferences.self, from: old)
            #expect(saved.correction == choice && saved.styleID == "chat")
            #expect(saved.permitsCorrection(health: local) == choice)
            #expect(saved.permitsCorrection(health: external) == choice)
            #expect(try decoder.decode(IOSPreferences.self, from: JSONEncoder().encode(saved)) == saved)
        }
    }
}

struct HistoryTests {
    @Test func unsetHistorySettingsUseDefaultsAndExplicitChoicesSurvive() throws {
        let decoder = JSONDecoder()
        let defaults = try decoder.decode(HistorySettings.self, from: Data("{}".utf8))
        #expect(!defaults.enabled && defaults.retention == .week)
        for enabled in [true, false] {
            for retention in HistoryRetention.allCases {
                let data = Data("{\"enabled\":\(enabled),\"retention\":\"\(retention.rawValue)\"}".utf8)
                let settings = try decoder.decode(HistorySettings.self, from: data)
                #expect(settings.enabled == enabled && settings.retention == retention)
                #expect(try decoder.decode(HistorySettings.self, from: JSONEncoder().encode(settings)) == settings)
            }
        }
    }
    @Test func switchingOffKeepsReadableHistoryAndKeyUntilExpiryOrExplicitDeletion() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(), secrets = MemorySecretStore()
        let store = try HistoryStore(root: root, secrets: secrets, now: clock.now)
        try store.setEnabled(true); try store.setRetention(.day)
        let entry = try #require(try store.record(text: "fixture"))
        let key = try secrets.read(account: HistoryStore.keyAccount)
        try store.setEnabled(false)
        let reopened = try HistoryStore(root: root, secrets: secrets, now: clock.now)
        #expect(!(try reopened.settings().enabled))
        #expect(try reopened.entries().map(\.id) == [entry.id])
        #expect(try secrets.read(account: HistoryStore.keyAccount) == key)
        #expect(try reopened.record(text: "late completion") == nil)
        clock.advance(86_401)
        #expect(try reopened.entries().isEmpty)
        try reopened.clear()
        #expect(!(try reopened.settings().enabled))
        #expect(try secrets.read(account: HistoryStore.keyAccount) == nil)
    }
    @Test func deleteRetainedEntryWhileOffAndShortenRetention() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock()
        let store = try HistoryStore(root: root, secrets: MemorySecretStore(), now: clock.now)
        try store.setEnabled(true)
        let entry = try #require(try store.record(text: "old fixture"))
        clock.advance(172_800)
        let newer = try #require(try store.record(text: "new fixture"))
        try store.setEnabled(false)
        try store.delete(id: newer.id)
        #expect(try store.entries().map(\.id) == [entry.id])
        try store.setRetention(.day)
        #expect(try store.entries().isEmpty)
    }
    @Test func defaultOffCiphertextAndExplicitDeleteKey() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let secrets = MemorySecretStore(); let history = try HistoryStore(root: root, secrets: secrets)
        #expect(!(try history.settings().enabled)); #expect(try history.record(text: "ignored") == nil)
        #expect(try secrets.read(account: HistoryStore.keyAccount) == nil)
        try history.setEnabled(true)
        try history.record(text: "transcript-sentinel", raw: "raw-sentinel", corrected: true)
        let file = root.appendingPathComponent("history/entries.sealed")
        let bytes = try Data(contentsOf: file)
        #expect(!bytes.contains(Data("transcript-sentinel".utf8))); #expect(!bytes.contains(Data("raw-sentinel".utf8)))
        #expect(try history.entries().first?.raw == "raw-sentinel")
        #expect(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        try history.setEnabled(false, deleteHistory: true)
        #expect(!FileManager.default.fileExists(atPath: file.path)); #expect(try secrets.read(account: HistoryStore.keyAccount) == nil)
        #expect(try history.record(text: "racing completion") == nil)
    }
    @Test func capRetentionSearchAndDeletion() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(); let history = try HistoryStore(root: root, secrets: MemorySecretStore(), now: clock.now)
        try history.setEnabled(true)
        for n in 0..<205 { try history.record(text: "entry \(n)"); clock.advance(1) }
        #expect(try history.entries().count == 200)
        #expect(try history.entries().first?.text == "entry 204")
        let id = try #require(history.entries().first?.id); try history.delete(id: id)
        #expect(try history.entries().count == 199)
        try history.setRetention(.day); clock.advance(86_401); #expect(try history.entries().isEmpty)
        #expect(try history.record(text: " \n") == nil)
        try history.record(text: "new"); try history.clear(); #expect(try history.entries().isEmpty)
    }
    @Test func tamperAndMissingKeyFailClosed() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let secrets = MemorySecretStore(); let history = try HistoryStore(root: root, secrets: secrets)
        try history.setEnabled(true); try history.record(text: "secret")
        let file = root.appendingPathComponent("history/entries.sealed")
        var data = try Data(contentsOf: file); data[data.count - 1] ^= 1; try data.write(to: file)
        #expect(throws: CoreError.corrupt) { try history.entries() }
        try history.clear(); try history.record(text: "secret")
        try secrets.delete(account: HistoryStore.keyAccount)
        #expect(throws: CoreError.corrupt) { try history.entries() }
        try history.setEnabled(false, deleteHistory: true); #expect(try history.entries().isEmpty)
    }
    @Test func rawUpdateIsAtomicAndTamperFailsClosed() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let history = try HistoryStore(root: root, secrets: MemorySecretStore())
        try history.setEnabled(true)
        let entry = try #require(try history.record(text: "cleaned", raw: "raw sentinel", corrected: true))
        let updated = try #require(try history.useRaw(id: entry.id))
        #expect(updated.id == entry.id && updated.createdAt == entry.createdAt)
        #expect(updated.text == "raw sentinel" && updated.raw == "raw sentinel" && !updated.corrected)
        #expect(try history.entries().count == 1)
        #expect(try history.useRaw(id: UUID()) == nil)
        let file = root.appendingPathComponent("history/entries.sealed")
        var data = try Data(contentsOf: file); data[data.count - 1] ^= 1; try data.write(to: file)
        #expect(throws: CoreError.corrupt) { try history.useRaw(id: entry.id) }
    }
    @Test func disableRacingRawUpdateCannotRecreateCiphertextOrKey() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let secrets = MemorySecretStore()
        let history = try HistoryStore(root: root, secrets: secrets)
        let another = try HistoryStore(root: root, secrets: secrets)
        try history.setEnabled(true)
        let entry = try #require(try history.record(text: "cleaned", raw: "raw", corrected: true))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<30 { group.addTask { _ = try? another.useRaw(id: entry.id) } }
            group.addTask { try? history.setEnabled(false, deleteHistory: true) }
        }
        #expect(try history.useRaw(id: entry.id) == nil)
        #expect(try history.entries().isEmpty)
        #expect(try secrets.read(account: HistoryStore.keyAccount) == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("history/entries.sealed").path))
    }
    @Test func concurrentDisableAndWritersCannotResurrectData() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let secrets = MemorySecretStore()
        let first = try HistoryStore(root: root, secrets: secrets), second = try HistoryStore(root: root, secrets: secrets)
        try first.setEnabled(true)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<30 { group.addTask { _ = try? second.record(text: "racing") } }
            group.addTask { try? first.setEnabled(false, deleteHistory: true) }
        }
        #expect(try first.entries().isEmpty)
        #expect(try secrets.read(account: HistoryStore.keyAccount) == nil)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("history/entries.sealed").path))
    }
}

struct BridgeTests {
    @Test func longDictationSegmentsOpenOnlyAfterTheFinalAndInOrder() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(), secrets = MemorySecretStore(), generation = UUID(), utterance = UUID()
        let app = try SharedBridge(root: root, secrets: secrets, role: .app, now: clock.now)
        try app.publish(BridgeState(generation: generation, phase: .listening, utteranceID: utterance, leaseUntil: clock.now() + 8))
        var sequence = 0
        func result(_ kind: BridgeResultKind, segment: Int?) -> BridgeResult {
            sequence += 1
            return BridgeResult(generation: generation, utteranceID: utterance, kind: kind, text: "x", sequence: sequence,
                                createdAt: clock.now(), expiresAt: clock.now() + 10, segment: segment)
        }
        try app.publish(result(.partial, segment: nil))
        #expect(throws: CoreError.invalidState) { try app.publish(result(.partial, segment: 1)) }
        try app.publish(result(.final, segment: nil))
        #expect(throws: CoreError.invalidState) { try app.publish(result(.raw, segment: 1)) }
        #expect(throws: CoreError.invalidState) { try app.publish(result(.partial, segment: 2)) }
        try app.publish(result(.partial, segment: 1))
        #expect(throws: CoreError.invalidState) { try app.publish(result(.partial, segment: nil)) }
        try app.publish(result(.final, segment: 1))
        try app.publish(result(.raw, segment: 1))
    }
    @Test func encryptedConsumeReplayOrderingAndOwnership() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(), secrets = MemorySecretStore(), generation = UUID(), utterance = UUID()
        let app = try SharedBridge(root: root, secrets: secrets, role: .app, now: clock.now)
        let keyboard = try SharedBridge(root: root, secrets: secrets, role: .keyboard, now: clock.now)
        try app.publish(BridgeState(generation: generation, phase: .armed, leaseUntil: clock.now() + 8))
        let start = BridgeCommand(generation: generation, utteranceID: utterance, action: .start, createdAt: clock.now(), expiresAt: clock.now() + 10)
        try keyboard.send(start); #expect(try app.takeCommands(generation: generation) == [start])
        #expect(throws: CoreError.replay) { try keyboard.send(start) }
        try app.publish(BridgeState(generation: generation, phase: .listening, utteranceID: utterance, leaseUntil: clock.now() + 8))
        let partial = BridgeResult(generation: generation, utteranceID: utterance, kind: .partial, text: "sentinel-transcript", sequence: 1, createdAt: clock.now(), expiresAt: clock.now() + 10)
        try app.publish(partial)
        let data = try Data(contentsOf: root.appendingPathComponent("bridge/mailbox.sealed"))
        #expect(!data.contains(Data("sentinel-transcript".utf8)))
        #expect(try keyboard.takeResults(generation: generation, utteranceID: utterance) == [partial])
        #expect(try keyboard.takeResults(generation: generation, utteranceID: utterance).isEmpty)
        #expect(throws: CoreError.replay) { try app.publish(partial) }
        #expect(throws: CoreError.foreignUtterance) { try keyboard.takeResults(generation: generation, utteranceID: UUID()) }
        #expect(throws: CoreError.unauthorized) { try keyboard.publish(partial) }
        let final = BridgeResult(generation: generation, utteranceID: utterance, kind: .final, text: "final", sequence: 2, createdAt: clock.now(), expiresAt: clock.now() + 10)
        try app.publish(final)
        var repeated = final; repeated.id = UUID(); repeated.sequence = 3
        #expect(throws: CoreError.invalidState) { try app.publish(repeated) }
        var raw = repeated; raw.kind = .raw; raw.text = "raw"; try app.publish(raw)
        #expect(try keyboard.takeResults(generation: generation, utteranceID: utterance).map(\.kind) == [.final, .raw])
        try app.endSession(); #expect(try keyboard.state() == nil)
        #expect(throws: CoreError.staleGeneration) { try app.publish(BridgeState(generation: generation, phase: .armed, leaseUntil: clock.now() + 8)) }
    }
    @Test func expiryLeaseAndGenerationFence() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(), secrets = MemorySecretStore(), generation = UUID(), utterance = UUID()
        let app = try SharedBridge(root: root, secrets: secrets, role: .app, now: clock.now)
        let keyboard = try SharedBridge(root: root, secrets: secrets, role: .keyboard, now: clock.now)
        try app.publish(BridgeState(generation: generation, phase: .listening, utteranceID: utterance, leaseUntil: clock.now() + 8))
        try app.publish(BridgeResult(generation: generation, utteranceID: utterance, kind: .partial, text: "expires", createdAt: clock.now(), expiresAt: clock.now() + 2))
        clock.advance(3); #expect(try keyboard.takeResults(generation: generation, utteranceID: utterance).isEmpty)
        clock.advance(6); #expect(try keyboard.state() == nil)
        #expect(throws: CoreError.staleGeneration) { try app.publish(BridgeState(generation: generation, phase: .armed, leaseUntil: clock.now() + 8)) }
        let next = UUID(); try app.publish(BridgeState(generation: next, phase: .armed, leaseUntil: clock.now() + 8))
        #expect(throws: CoreError.staleGeneration) { try keyboard.send(BridgeCommand(generation: generation, action: .end, createdAt: clock.now(), expiresAt: clock.now() + 5)) }
        #expect(try keyboard.state()?.generation == next)
    }
    @Test func queueBoundAndConcurrentWriters() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(), secrets = MemorySecretStore(), generation = UUID()
        let app = try SharedBridge(root: root, secrets: secrets, role: .app, now: clock.now)
        try app.publish(BridgeState(generation: generation, phase: .armed, leaseUntil: clock.now() + 15))
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask {
                    let writer = try SharedBridge(root: root, secrets: secrets, role: .keyboard, now: clock.now)
                    try writer.send(BridgeCommand(generation: generation, action: .privacy(true), createdAt: clock.now(), expiresAt: clock.now() + 10))
                }
            }
            try await group.waitForAll()
        }
        let writer = try SharedBridge(root: root, secrets: secrets, role: .keyboard, now: clock.now)
        #expect(throws: CoreError.queueFull) { try writer.send(BridgeCommand(generation: generation, action: .end, createdAt: clock.now(), expiresAt: clock.now() + 10)) }
        #expect(try app.takeCommands(generation: generation).count == 64)
    }
    @Test func readOnlyReconciliationDoesNotWriteButRejectedExpiredWritePrunes() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(), secrets = MemorySecretStore(), generation = UUID()
        let app = try SharedBridge(root: root, secrets: secrets, role: .app, now: clock.now)
        let keyboard = try SharedBridge(root: root, secrets: secrets, role: .keyboard, now: clock.now)
        try app.publish(BridgeState(generation: generation, phase: .armed, leaseUntil: clock.now() + 8))
        let file = root.appendingPathComponent("bridge/mailbox.sealed")
        let before = try Data(contentsOf: file)
        _ = try keyboard.state(); _ = try keyboard.state()
        #expect(try Data(contentsOf: file) == before)
        clock.advance(9)
        #expect(throws: CoreError.staleGeneration) {
            try keyboard.send(BridgeCommand(generation: generation, action: .end,
                createdAt: clock.now(), expiresAt: clock.now() + 5))
        }
        #expect(try Data(contentsOf: file) != before)
        #expect(try keyboard.state() == nil)
    }
    @Test func tamperOversizeTTLAndRoleFailClosed() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(), secrets = MemorySecretStore(), generation = UUID(), utterance = UUID()
        let app = try SharedBridge(root: root, secrets: secrets, role: .app, now: clock.now)
        #expect(throws: CoreError.invalidState) { try app.publish(BridgeState(generation: generation, phase: .armed, leaseUntil: clock.now() + 16)) }
        try app.publish(BridgeState(generation: generation, phase: .listening, utteranceID: utterance, leaseUntil: clock.now() + 8))
        #expect(throws: CoreError.oversized) { try app.publish(BridgeResult(generation: generation, utteranceID: utterance, kind: .final, text: String(repeating: "a", count: 65_537), createdAt: clock.now(), expiresAt: clock.now() + 10)) }
        #expect(throws: CoreError.expired) { try app.publish(BridgeResult(generation: generation, utteranceID: utterance, kind: .final, text: "a", createdAt: clock.now(), expiresAt: clock.now() + 121)) }
        let file = root.appendingPathComponent("bridge/mailbox.sealed")
        var data = try Data(contentsOf: file); data[data.count - 1] ^= 1; try data.write(to: file)
        #expect(throws: CoreError.corrupt) { try app.state() }
    }
}

struct PreferenceAndDiagnosticTests {
    @Test func defaultsConsentAndPersistence() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try PreferenceStore(root: root); var preferences = try store.load()
        #expect(preferences.correction); #expect(preferences.sessionDuration == .fiveMinutes)
        preferences.correction = true
        let external = Health(correction: "available", correctionLeavesMachine: true, correctionHost: "llm.example")
        #expect(!preferences.permitsCorrection(health: external))
        preferences.consentHost = "llm.example"; #expect(preferences.permitsCorrection(health: external))
        #expect(!preferences.permitsCorrection(health: Health(correction: "available", correctionLeavesMachine: true, correctionHost: "changed.example")))
        #expect(!preferences.permitsCorrection(health: Health(correction: "available")))
        try store.save(preferences); #expect(try store.load() == preferences)
    }
    @Test func diagnosticsCanOnlyExportAllowlistedContent() throws {
        #expect(DiagnosticCode.server("secret server exception transcript") == .unknown)
        let bytes = try DiagnosticExport.data(events: [DiagnosticEvent(phase: .failed, code: .unknown, durationMilliseconds: -1)])
        let string = String(decoding: bytes, as: UTF8.self)
        #expect(!string.contains("secret")); #expect(string.contains("failed"))
        #expect(!string.contains("token")); #expect(!string.contains("url"))
    }
}

struct DarwinSignalTests {
    @Test func observationCanCancelDuringConcurrentWake() async {
        let signal = DarwinSignal(name: "dev.chirp.tests." + UUID().uuidString)
        let probe = WakeProbe()
        let (events, continuation) = AsyncStream.makeStream(of: Bool.self)
        let observation = signal.observe { probe.increment(); continuation.yield(true) }
        let timeout = Task { try? await Task.sleep(for: .seconds(2)); continuation.finish() }
        signal.post()
        let delivered = await events.first(where: { $0 })
        timeout.cancel()
        #expect(delivered == true)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 { group.addTask { signal.post() } }
            group.addTask { observation.cancel(); observation.cancel() }
        }
        signal.post()
        // Queued OS callbacks retain their Swift closure; cancellation never leaves an unsafe observer pointer.
        #expect(probe.count >= 1)
    }
}
private final class WakeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

struct KeyboardSetupTests {
    @Test func markerStartsEmptyAndStoresOnlyATimestamp() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try KeyboardSetupStore(root: root)
        #expect(try store.fullAccessSeenAt() == nil)
        let seen = Date(timeIntervalSince1970: 1_800_000_000)
        try store.recordFullAccess(now: seen)
        #expect(try KeyboardSetupStore(root: root).fullAccessSeenAt() == seen)
        let saved = try Data(contentsOf: root.appendingPathComponent("keyboard/setup.json"))
        let keys = try #require(JSONSerialization.jsonObject(with: saved) as? [String: Any]).keys
        #expect(Array(keys) == ["fullAccessSeenAt"])
    }
}

struct OperationDeadlineTests {
    private func health(_ fields: String) throws -> Health {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Health.self, from: Data((#"{"ok":true"# + fields + "}").utf8))
    }

    @Test func advertisedCPUAndOverrideBudgetsIncludeBoundedTransportMargin() throws {
        let h = try health(#", "operation_deadlines":{"dictation":30,"notes_correction":45,"notes_structure":90,"notes_reorganize":120,"notes_edit":180.25,"future":1}"#)
        #expect(h.operationTimeout(.dictation, fallback: 12) == 35)
        #expect(h.operationTimeout(.notesCorrection, fallback: 25) == 50)
        #expect(h.operationTimeout(.notesStructure, fallback: 35) == 95)
        #expect(h.operationTimeout(.notesReorganize, fallback: 50) == 125)
        #expect(h.operationTimeout(.notesEdit, fallback: 50) == 185.25)
    }

    @Test(arguments: ["", #", "operation_deadlines":null"#, #", "operation_deadlines":[]"#,
                      #", "operation_deadlines":{"dictation":0,"notes_structure":-1,"notes_reorganize":"120","notes_edit":true}"#])
    func oldOrInvalidServerUsesLegacyTimeouts(_ fields: String) throws {
        let h = try health(fields)
        #expect(h.operationTimeout(.dictation, fallback: 12) == 12)
        #expect(h.operationTimeout(.notesCorrection, fallback: 25) == 25)
        #expect(h.operationTimeout(.notesStructure, fallback: 35) == 35)
        #expect(h.operationTimeout(.notesReorganize, fallback: 50) == 50)
        #expect(h.operationTimeout(.notesEdit, fallback: 50) == 50)
    }

    @Test func partialAdvertisementFallsBackIndependently() throws {
        let h = try health(#", "operation_deadlines":{"dictation":"bad","notes_structure":135,"notes_edit":1e100}"#)
        #expect(h.operationTimeout(.dictation, fallback: 12) == 12)
        #expect(h.operationTimeout(.notesStructure, fallback: 35) == 140)
        #expect(h.operationTimeout(.notesEdit, fallback: 50) == 50)
    }
}
