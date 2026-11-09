import Foundation
import Testing
import ChirpCore
@testable import ChirpIOSCore

private func temporaryRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var value = true
    var open: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

struct LearnedStoreTests {
    @Test func aTermSeenTwiceBecomesActiveAndGoesInThePayload() throws {
        let store = try IOSLearnedStore(root: temporaryRoot(), secrets: MemorySecretStore(), permitted: { true })
        #expect(try store.learn(inserted: "deploy on cooper netties", edited: "deploy on Kubernetes", said: nil).isEmpty)
        #expect(try store.all().first?.state == .learning)
        #expect(try store.payload().isEmpty)
        let activated = try store.learn(inserted: "scale cooper netties", edited: "scale Kubernetes", said: nil)
        #expect(activated.map(\.correction) == [.term(heard: "cooper netties", term: "Kubernetes")])
        #expect(try store.payload().terms == [.init(term: "Kubernetes", heard: ["cooper netties"])])
    }

    @Test func teachChirpIsActiveAtOnceAndUndoStaysOff() throws {
        let store = try IOSLearnedStore(root: temporaryRoot(), secrets: MemorySecretStore(), permitted: { true })
        let taught = try store.learn(inserted: "ask get hub", edited: "ask GitHub", said: "ask get hub", explicit: true)
        #expect(taught.count == 1 && taught.first?.state == .active)
        let id = try #require(taught.first?.id)
        try store.set(id, state: .off)
        #expect(try store.learn(inserted: "ask get hub", edited: "ask GitHub", said: nil, explicit: true).isEmpty)
        #expect(try store.all().first?.state == .off)
        #expect(try store.payload().isEmpty)
        try store.delete(id)
        #expect(try store.all().isEmpty)
    }

    @Test func styleIsNeverLearnedWithoutAnApp() throws {
        let store = try IOSLearnedStore(root: temporaryRoot(), secrets: MemorySecretStore(), permitted: { true })
        #expect(try store.learn(inserted: "Sounds good.", edited: "sounds good", said: nil, explicit: true).isEmpty)
        #expect(try store.all().isEmpty)
    }

    @Test func nothingIsWrittenOrSentWhileNotPermitted() throws {
        let gate = Gate()
        let store = try IOSLearnedStore(root: temporaryRoot(), secrets: MemorySecretStore(), permitted: { gate.open })
        try store.learn(inserted: "ask get hub", edited: "ask GitHub", said: nil, explicit: true)
        gate.open = false
        #expect(try store.payload().isEmpty)
        #expect(try store.learn(inserted: "use type script", edited: "use TypeScript", said: nil, explicit: true).isEmpty)
        #expect(try store.all().count == 1)
    }

    @Test func itemsAreSealedAndShareTheDiskAcrossInstances() throws {
        let root = try temporaryRoot(), secrets = MemorySecretStore()
        let app = try IOSLearnedStore(root: root, secrets: secrets, permitted: { true })
        let keyboard = try IOSLearnedStore(root: root, secrets: secrets, permitted: { true })
        try keyboard.learn(inserted: "ask get hub", edited: "ask GitHub", said: nil)
        try app.learn(inserted: "ask get hub", edited: "ask GitHub", said: nil)
        #expect(try keyboard.all().first?.state == .active)
        let bytes = try Data(contentsOf: root.appendingPathComponent("learned/learned.sealed"))
        #expect(bytes.range(of: Data("GitHub".utf8)) == nil)
    }

    @Test func aLostKeyDropsTheUnreadableFile() throws {
        let root = try temporaryRoot(), secrets = MemorySecretStore()
        let store = try IOSLearnedStore(root: root, secrets: secrets, permitted: { true })
        try store.learn(inserted: "ask get hub", edited: "ask GitHub", said: nil, explicit: true)
        try secrets.delete(account: IOSLearnedStore.keyAccount)
        #expect(try store.all().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("learned/learned.sealed").path))
    }

    @Test func productionGateNeedsHistoryLearningAndNoPrivateSession() throws {
        let root = try temporaryRoot(), secrets = MemorySecretStore()
        let store = try IOSLearnedStore(root: root, secrets: secrets)
        #expect(!store.allowed) // history starts off
        try HistoryStore(root: root, secrets: secrets).setEnabled(true)
        #expect(store.allowed)
        let preferences = try PreferenceStore(root: root)
        var prefs = try preferences.load()
        prefs.privacyMode = true; try preferences.save(prefs)
        #expect(!store.allowed)
        prefs.privacyMode = false; prefs.learnFromEdits = false; try preferences.save(prefs)
        #expect(!store.allowed)
    }
}

struct LearningWatchTests {
    private let doc = UUID()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aFixInsideTheDictationIsTheEdit() throws {
        var watch = try #require(LearningWatch(documentID: doc, before: "Hi. I use cooper netties", after: " daily",
                                               inserted: "I use cooper netties", said: "i use cooper netties", now: now))
        watch.observe(documentID: doc, before: "Hi. I use Kubernetes", after: " daily")
        #expect(watch.edited == "I use Kubernetes")
        // The caret moved into the span: still the same field.
        watch.observe(documentID: doc, before: "Hi. I use Kube", after: "rnetes daily")
        #expect(watch.edited == "I use Kubernetes")
    }

    @Test func changesOutsideTheSpanTeachNothing() throws {
        var watch = try #require(LearningWatch(documentID: doc, before: "Hi. I use cooper netties", after: "",
                                               inserted: "I use cooper netties", said: "", now: now))
        #expect(watch.edited == nil)
        watch.observe(documentID: doc, before: "Hello. I use Kubernetes", after: "")
        #expect(watch.edited == nil)
        watch.observe(documentID: doc, before: "Hi. I use cooper netties and more", after: "")
        #expect(watch.edited == nil) // only typed on
        watch.observe(documentID: doc, before: "", after: "")
        #expect(watch.edited == nil) // field emptied (sent)
    }

    @Test func anotherFieldIsIgnored() throws {
        var watch = try #require(LearningWatch(documentID: doc, before: "cooper netties", after: "",
                                               inserted: "cooper netties", said: "", now: now))
        watch.observe(documentID: UUID(), before: "Kubernetes", after: "")
        #expect(watch.edited == nil)
    }

    @Test func aShiftedHostWindowTeachesNothing() throws {
        let earlier = String(repeating: "x", count: 300)
        var watch = try #require(LearningWatch(documentID: doc, before: earlier + " I use cooper netties", after: "",
                                               inserted: "I use cooper netties", said: "", now: now))
        // The host shows a fixed-length window: a shorter fix pulls earlier text into view, which differs.
        watch.observe(documentID: doc, before: "yyyy" + String(earlier.dropFirst(2)) + " I use Kubernetes", after: "")
        #expect(watch.edited == nil)
    }

    @Test func blankOrMisplacedInsertionsAreNotWatched() {
        #expect(LearningWatch(documentID: doc, before: "abc", after: "", inserted: "  ", said: "", now: now) == nil)
        #expect(LearningWatch(documentID: doc, before: "abc", after: "", inserted: "xyz", said: "", now: now) == nil)
    }
}

struct StopOnPausePreferenceTests {
    @Test func offByDefaultAndSnappedToOfferedLengths() throws {
        var prefs = IOSPreferences()
        #expect(prefs.autoStopSilence == nil && prefs.learning)
        prefs.stopOnPause = true
        #expect(prefs.autoStopSilence == AutoStopDetector.defaultSilence)
        prefs.pauseSeconds = 2.9
        #expect(prefs.autoStopSilence == 3)
        prefs.pauseSeconds = .infinity
        #expect(prefs.autoStopSilence == AutoStopDetector.defaultSilence)
        let old = try JSONDecoder().decode(IOSPreferences.self, from: JSONEncoder().encode(IOSPreferences()))
        #expect(old.stopOnPause == nil && old.learnFromEdits == nil)
    }

    @Test func keepListeningIsOffByDefaultRoundTripsAndOverridesThePause() throws {
        var prefs = IOSPreferences()
        #expect(!prefs.continuousListening)
        // A file from before the setting decodes with it off.
        let older = try JSONDecoder().decode(IOSPreferences.self, from: Data(#"{"stopOnPause":true}"#.utf8))
        #expect(!older.continuousListening && older.autoStopSilence == AutoStopDetector.defaultSilence)
        prefs.stopOnPause = true; prefs.pauseSeconds = 3
        prefs.continuousListening = true
        #expect(prefs.autoStopSilence == nil)
        let data = try JSONEncoder().encode(prefs)
        #expect(String(decoding: data, as: UTF8.self).contains(#""continuousListening":true"#))
        let back = try JSONDecoder().decode(IOSPreferences.self, from: data)
        #expect(back == prefs && back.continuousListening && back.autoStopSilence == nil && back.pauseLength == 3)
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PreferenceStore(root: root)
        try store.save(prefs)
        #expect(try PreferenceStore(root: root).load().continuousListening)
    }
}
