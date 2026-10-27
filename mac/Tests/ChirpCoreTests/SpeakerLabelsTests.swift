import Foundation
import Testing
@testable import ChirpCore

/// A model store with no model behind it: it records every load, can hold one until released, and can fail.
final class FakeModelStore: SpeakerModelStore, @unchecked Sendable {
    private let lock = NSLock()
    private var _downloaded: Bool
    private var _files: Bool
    private var _loads: [Bool] = []
    private var _removes = 0
    private var held: CheckedContinuation<Void, Never>?
    var hold = false
    var fail = false
    /// Delays the start of each load, as a busy machine delays the background download task.
    var startDelay: Duration = .zero

    init(downloaded: Bool) {
        _downloaded = downloaded
        _files = downloaded
    }

    var sizeText: String { "106 MB" }
    /// Every load so far: true for a download (the network), false for an offline load.
    var loads: [Bool] { lock.withLock { _loads } }
    var removes: Int { lock.withLock { _removes } }
    func setDownloaded(_ on: Bool, files: Bool? = nil) { lock.withLock { _downloaded = on; _files = files ?? on } }
    func isDownloaded() -> Bool { lock.withLock { _downloaded } }
    func hasFiles() -> Bool { lock.withLock { _files } }
    func remove() throws { lock.withLock { _removes += 1; _downloaded = false; _files = false } }

    func load(download: Bool, progress: @escaping @Sendable (Double) -> Void) async throws -> any SpeakerDiarizerFactory {
        if startDelay > .zero { try? await Task.sleep(for: startDelay) }
        let shouldHold = lock.withLock { () -> Bool in
            _loads.append(download)
            if download { _files = true }
            return hold
        }
        if shouldHold { await withCheckedContinuation { c in lock.withLock { held = c } } }
        try Task.checkCancellation()
        if fail { throw CocoaError(.fileReadCorruptFile) }
        lock.withLock { if download { _downloaded = true } }
        return FakeFactory()
    }

    func release() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { held = nil }; hold = false; return held }
        c?.resume()
    }
}

final class FakeFactory: SpeakerDiarizerFactory, @unchecked Sendable {
    func makeDiarizer() -> SpeakerDiarizing { FakeDiarizer(script: []) }
}

@MainActor
@Suite struct SpeakerLabelsTests {
    /// `enabled` is the effective preference (unset reads as on); `box.preference` is what the user's own choices stored.
    private func labels(_ store: FakeModelStore, enabled: Bool = true) -> (SpeakerLabels, Box) {
        let box = Box()
        let l = SpeakerLabels(store: store, enabled: enabled, onPreference: { box.preference = $0 })
        l.onReady = { box.ready += 1 }
        return (l, box)
    }

    final class Box { var preference: Bool?; var ready = 0 }

    private func settle(_ condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(2)) }
    }

    // MARK: a missing or failed model is a model state, never a preference

    @Test func launchWithTheModelGoneKeepsLabelsOnAndStoresNothing() {
        let store = FakeModelStore(downloaded: false)
        let (l, box) = labels(store)
        #expect(l.enabled && box.preference == nil && l.model == .notDownloaded && store.loads.isEmpty && !l.needsLoad)
    }

    @Test func recordWithTheModelGoneDownloadsInTheBackgroundAndRecordingGoesOn() async {
        let store = FakeModelStore(downloaded: true)
        let (l, box) = labels(store)
        store.setDownloaded(false)          // removed from disk after launch
        store.hold = true
        #expect(await l.prepare() == nil)   // returns at once: Record starts without labels
        await settle { l.model.isDownloading && store.loads == [true] }
        #expect(l.enabled && l.model.isDownloading && box.preference == nil)
        store.release()
        await settle { l.model == .ready }
        #expect(store.loads == [true] && l.enabled && box.preference == nil && box.ready == 1)
        // Labels apply from now on: the next diarizer comes from the loaded model without another load.
        #expect(l.readyDiarizer() != nil && store.loads == [true])
    }

    @Test func ensureModelStartsOneDownloadAndNeverRepeatsAfterAFailure() async {
        let store = FakeModelStore(downloaded: false)
        store.fail = true
        let (l, box) = labels(store)
        l.ensureModel()
        l.ensureModel()
        await settle { l.model.isFailure }
        #expect(l.model == .failed("the download failed") && store.loads == [true] && l.enabled && box.preference == nil && box.ready == 0)
        l.ensureModel()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(store.loads == [true])      // only Retry tries again
        store.fail = false
        l.retry()
        await settle { l.model == .ready }
        #expect(store.loads == [true, true] && l.enabled && box.preference == nil && box.ready == 1)
    }

    @Test func nothingDownloadsWhileLabelsAreOff() async {
        let store = FakeModelStore(downloaded: false)
        let (l, box) = labels(store, enabled: false)
        l.ensureModel()
        #expect(await l.prepare() == nil)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(store.loads.isEmpty && !l.enabled && box.preference == nil)
    }

    @Test func recordLoadsOfflineOnly() async {
        let store = FakeModelStore(downloaded: true)
        let (l, _) = labels(store)
        #expect(l.needsLoad)
        #expect(await l.prepare() != nil)
        #expect(store.loads == [false])
        // The same document keeps its diarizer; New frees it, and the next Record loads (offline) again.
        let first = l.diarizer
        #expect(await l.prepare() === first)
        l.reset()
        #expect(l.diarizer == nil && l.needsLoad)
        _ = await l.prepare()
        #expect(store.loads == [false, false])
    }

    @Test func turningOnFetchesAMissingModelWithoutAskingAndStoresTheChoice() async {
        let store = FakeModelStore(downloaded: false)
        let (l, box) = labels(store, enabled: false)
        l.setEnabled(true, documentHasLabels: false)
        await settle { l.model == .ready }
        #expect(store.loads == [true] && l.enabled && box.preference == true && box.ready == 1)
        // Already loaded: Record makes the diarizer without another load.
        #expect(l.readyDiarizer() != nil && store.loads == [true])
    }

    @Test func aDamagedModelFailsOfflineAndOnlyRetryRepairsIt() async {
        let store = FakeModelStore(downloaded: true)
        store.fail = true
        let (l, box) = labels(store)
        #expect(await l.prepare() == nil)
        #expect(store.loads == [false] && l.model == .failed("the model did not load") && l.enabled && box.preference == nil)
        #expect(!l.needsLoad)               // Record goes on without labels
        store.fail = false
        l.retry()
        await settle { l.model == .ready }
        #expect(store.removes == 1 && store.loads == [false, true] && l.enabled && box.preference == nil)
    }

    // MARK: Turn off

    @Test func turnOffCancelsADownloadAndStoresAnExplicitOff() async {
        let store = FakeModelStore(downloaded: false)
        store.hold = true
        let (l, box) = labels(store)
        l.ensureModel()
        await settle { l.model.isDownloading && store.loads == [true] }
        l.setEnabled(false, documentHasLabels: false)
        store.release()
        await settle { !l.isLoading }
        #expect(!l.enabled && box.preference == false && l.model == .notDownloaded && l.readyDiarizer() == nil && box.ready == 0)
    }

    @Test func turnOffAfterAFailedDownloadClearsTheFailure() async {
        let store = FakeModelStore(downloaded: false)
        store.fail = true
        let (l, box) = labels(store)
        l.ensureModel()
        await settle { l.model.isFailure }
        l.setEnabled(false, documentHasLabels: false)
        #expect(!l.enabled && box.preference == false && l.model == .notDownloaded)
    }

    @Test func removeIsRefusedWhileLoadingAndCoversPartialDownloads() async {
        let store = FakeModelStore(downloaded: true)
        store.hold = true
        let (l, box) = labels(store)
        let prepared = Task { await l.prepare() }
        await settle { l.isLoading }
        #expect(!l.canRemove && !l.remove() && store.removes == 0)
        store.release()
        _ = await prepared.value
        // A partial download (files but no complete model) can be removed too. Remove is the user's own choice, so
        // it stores an explicit off and the model does not come straight back at the next Record.
        store.setDownloaded(false, files: true)
        #expect(l.canRemove && l.remove())
        #expect(store.removes == 1 && !l.enabled && box.preference == false && l.diarizer == nil)
    }

    @Test func switchingOffFreesTheModelUnlessTheDocumentHasLabels() async {
        let store = FakeModelStore(downloaded: true)
        let (l, _) = labels(store)
        _ = await l.prepare()
        l.setEnabled(false, documentHasLabels: true)
        #expect(l.diarizer != nil)             // kept: on again keeps Person N
        l.setEnabled(true, documentHasLabels: true)
        #expect(l.readyDiarizer() != nil && store.loads == [false])
        l.setEnabled(false, documentHasLabels: false)
        #expect(l.diarizer == nil && !l.needsLoad)
        l.setEnabled(true, documentHasLabels: false)
        #expect(l.needsLoad)
    }
}

@Suite struct SpeakerLabelsPreferenceTests {
    private func prefs(_ body: (UserDefaults) -> Void = { _ in }) -> (Preferences, UserDefaults, () -> Void) {
        let name = "chirp-labels-pref-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        body(defaults)
        return (Preferences(defaults: defaults), defaults, { removeTestDefaults(name) })
    }

    @Test func unsetIsOnAndStoresNothing() {
        let (p, defaults, done) = prefs()
        defer { done() }
        #expect(p.notesSpeakerLabels && p.notesSpeakerLabelsChoice == nil)
        #expect(!p.migrateSpeakerLabelsDefault())
        #expect(p.notesSpeakerLabels && defaults.object(forKey: "notesSpeakerLabels") == nil)
    }

    @Test func anExplicitOffStaysOffAcrossTheMigration() {
        let (p, defaults, done) = prefs()
        defer { done() }
        p.notesSpeakerLabels = false
        #expect(!p.migrateSpeakerLabelsDefault())
        #expect(!Preferences(defaults: defaults).notesSpeakerLabels)
    }

    @Test func aLegacyFalseIsClearedOnceAndALegacyTrueIsKept() {
        let (off, offDefaults, doneOff) = prefs { $0.set(false, forKey: "notesSpeakerLabels") }
        defer { doneOff() }
        #expect(!off.notesSpeakerLabels)                       // before the migration it reads as the user's off
        #expect(off.migrateSpeakerLabelsDefault())
        #expect(off.notesSpeakerLabels && offDefaults.object(forKey: "notesSpeakerLabels") == nil)
        // From then on a stored false is the user's own and survives every later launch.
        off.notesSpeakerLabels = false
        #expect(!off.migrateSpeakerLabelsDefault() && !off.notesSpeakerLabels)

        let (on, _, doneOn) = prefs { $0.set(true, forKey: "notesSpeakerLabels") }
        defer { doneOn() }
        #expect(!on.migrateSpeakerLabelsDefault() && on.notesSpeakerLabelsChoice == true)
    }
}
