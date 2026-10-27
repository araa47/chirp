import AppKit
import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// Issue #207: speaker labels at parity with Android (#191) in the redesigned window: one set of fix-ups for whichever
/// note is on screen (a note opened beside a recording included), and Label speakers in Settings › Notes.
@MainActor
@Suite struct SpeakerEditingTests {
    /// Two people over two segments, and notes that name Person 2 twice.
    private func document() -> NotesDocument {
        var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 0),
                              text: "## Plan\n- [ ] **Person 2** to send the spec\n- Person 1 agreed with Person 2.\n")
        d.append(NotesSegment(id: 0, offset: 0, raw: "we ship friday ok", text: "We ship Friday. OK."))
        d.attachSpeakers([.init(slot: 0, start: 0, text: "We ship Friday."), .init(slot: 1, start: 2, text: "OK.")], toSegment: 0)
        d.append(NotesSegment(id: 1, offset: 10, raw: "i send the spec", text: "I send the spec."))
        d.attachSpeakers([.init(slot: 1, start: 10, text: "I send the spec.")], toSegment: 1)
        return d
    }

    /// Runs `edit` on `d` as a window would, collecting the notes changes it passed on.
    private func apply(_ edit: SpeakerEdit, to d: inout NotesDocument, banner: SpeakerBanner.Kind? = nil,
                       changes: inout [NotesTextChange]) -> SpeakerBanner.Kind? {
        var doc = d, out: [NotesTextChange] = []
        let result = SpeakerEditing.apply(edit, banner: banner, document: { doc }) { body in out += body(&doc) }
        d = doc
        changes += out
        return result
    }

    @Test func aRenameReachesEveryTurnAndOffersTheNotes() throws {
        var d = document(), changes: [NotesTextChange] = []
        let banner = apply(.rename(2, to: "Maya"), to: &d, changes: &changes)
        #expect(banner == .offerReplace(old: "Person 2", new: "Maya", count: 2) && changes.isEmpty)
        #expect(d.transcriptLines() == ["**[00:00:00] Person 1:** We ship Friday.", "**[00:00:02] Maya:** OK.",
                                        "**[00:00:10] Maya:** I send the spec."])
        #expect(try #require(d.nextStructureRequest()).transcript == "Person 1: We ship Friday.\nMaya: OK.\nMaya: I send the spec.")
        #expect(d.exportMarkdown().contains("**[00:00:02] Maya:** OK."))
        // Replace in notes: both mentions, one change each for the editor; Undo puts them back.
        let replaced = apply(.replaceInNotes, to: &d, banner: banner, changes: &changes)
        guard case .replaced(let r) = replaced else { Issue.record("not replaced"); return }
        #expect(changes.count == 2 && d.text.contains("**Maya** to send") && d.text.contains("agreed with Maya."))
        #expect(apply(.undo, to: &d, banner: replaced, changes: &changes) == nil)
        #expect(changes.count == 2 + r.inverse.count && d.nameCount("Person 2") == 2)
    }

    @Test func mergeAndSeparateGoThroughTheSameEdits() {
        var d = document(), changes: [NotesTextChange] = []
        let merged = apply(.merge(2, into: 1), to: &d, changes: &changes)
        #expect(merged == .merged(person: 2, name: "Person 2", into: "Person 1") && d.speakerCount == 1)
        #expect(apply(.undo, to: &d, banner: merged, changes: &changes) == nil && d.speakerCount == 2)
        _ = apply(.merge(2, into: 1), to: &d, changes: &changes)
        _ = apply(.separate(2), to: &d, changes: &changes)
        #expect(d.speakerCount == 2 && changes.isEmpty)
        // A rename that changes nothing, or of someone the notes never name, offers nothing.
        #expect(apply(.rename(1, to: "Person 1"), to: &d, changes: &changes) == nil)
        #expect(apply(.dismiss, to: &d, banner: merged, changes: &changes) == nil)
    }
}

private func libraryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("chirp-speakers-\(UUID().uuidString)", isDirectory: true)
}

@MainActor @Suite(.serialized) struct SpeakerParitySessionTests {
    /// A finished two-person note in the library.
    private func storedNote() -> NotesDocument {
        var d = NotesDocument(text: "## Plan\n- [ ] **Person 2** to send the spec\n")
        d.append(NotesSegment(id: 0, offset: 0, raw: "we ship friday ok", text: "We ship Friday. OK."))
        d.attachSpeakers([.init(slot: 0, start: 0, text: "We ship Friday."), .init(slot: 1, start: 2, text: "OK.")], toSegment: 0)
        return d
    }

    @Test func aNoteOpenedBesideARecordingRenamesItsSpeakersAndSavesThem() async throws {
        let dir = libraryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = NotesLibrary(store: NotesLibraryStore(directory: dir))
        let other = storedNote()
        try await library.write(NotesJournalRecord(document: other, elapsed: 3))
        let h = NotesHarness(library: library)
        let w = h.session.window
        await h.record(); await h.speak(1)
        w.select(.note(other.id))
        await h.until("browsed") { w.browsed?.document.id == other.id }
        let browsed = try #require(w.browsed)
        // Before #207 its chip menu did nothing: only the recorder's model had a speaker edit behind it.
        browsed.onSpeakerEdit(.rename(2, to: "Maya"))
        #expect(browsed.document.roster.displayName(2) == "Maya")
        #expect(browsed.visibleSpeakerBanner?.kind == .offerReplace(old: "Person 2", new: "Maya", count: 1))
        browsed.onSpeakerEdit(.replaceInNotes)
        #expect(browsed.document.text.contains("**Maya** to send"))
        browsed.onSpeakerEdit(.merge(1, into: 2))
        #expect(browsed.document.speakerCount == 1)
        #expect(h.document.roster.people.isEmpty && h.model.visibleSpeakerBanner == nil)   // the recording is untouched
        var stored: NotesDocument?
        for _ in 0..<100 {
            stored = try? await library.record(other.id).document
            if stored?.speakerCount == 1 { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        #expect(stored?.roster.displayName(1) == "Maya" && stored?.text.contains("**Maya** to send") == true)
        #expect(stored?.transcriptLines() == ["**[00:00:00] Maya:** We ship Friday. OK."])
        #expect(h.recorder.state.isCapturing)
        await h.stop()
    }

    @Test func turningLabelsOnFetchesTheModelWithoutAskingAndStoresTheChoice() async throws {
        let store = FakeModelStore(downloaded: false)
        let suite = "chirp-speaker-parity-\(UUID().uuidString)"
        defer { removeTestDefaults(suite) }
        let prefs = Preferences(defaults: UserDefaults(suiteName: suite)!)
        let labels = SpeakerLabels(store: store, enabled: prefs.notesSpeakerLabels, onPreference: { prefs.notesSpeakerLabels = $0 })
        #expect(labels.enabled && prefs.notesSpeakerLabelsChoice == nil)    // on by default, nothing stored
        labels.setEnabled(false, documentHasLabels: false)
        #expect(!labels.enabled && prefs.notesSpeakerLabelsChoice == false && store.loads.isEmpty)
        labels.setEnabled(true, documentHasLabels: false)
        for _ in 0..<500 where labels.model != .ready { try? await Task.sleep(for: .milliseconds(2)) }
        #expect(store.loads == [true] && labels.model == .ready && prefs.notesSpeakerLabels)
    }

    @Test func theSessionRefusesTheSwitchWhileRecording() async throws {
        let h = NotesHarness(speakers: FakeModelStore(downloaded: true))
        #expect(h.session.speakers.enabled)
        await h.record()
        h.session.setSpeakerLabels(false)
        #expect(h.session.speakers.enabled && h.edges.beeps == 1)
        await h.stop()
        h.session.setSpeakerLabels(false)
        #expect(!h.session.speakers.enabled && !h.prefs.notesSpeakerLabels)
        h.session.setSpeakerLabels(true)
        #expect(h.session.speakers.enabled && h.prefs.notesSpeakerLabels && h.model.speakerLabels)
    }
}

/// Labels on by default (#247, item 1a): a missing model downloads in the background, never behind a prompt, and
/// Record never waits for it.
@MainActor
@Suite struct SpeakerDefaultOnTests {
    /// A slow-starting download (a busy CI runner) must not change the outcome.
    @Test(arguments: [Duration.zero, .milliseconds(300)])
    func recordingWithTheModelMissingStartsAtOnceDownloadsAndJoinsLabelsWhenReady(downloadStartDelay: Duration) async throws {
        let store = FakeModelStore(downloaded: false)
        store.hold = true
        store.startDelay = downloadStartDelay
        let h = NotesHarness(speakers: store)
        #expect(h.session.speakers.enabled && h.prefs.notesSpeakerLabelsChoice == nil)   // on by default, nothing stored
        await h.record()
        #expect(h.recorder.state == .recording)                 // not held up by the download
        // The download starts on its own task (#314): wait for it to reach the store rather than race it.
        await h.until("speaker model download started") { store.loads == [true] && h.session.speakers.model.isDownloading }
        let notice = try #require(h.model.speakerModelNotice)
        #expect(notice.text == "Getting the speaker model ready (106 MB, once)… 0%" && !notice.failed)
        #expect(h.model.speakerStatus == nil && h.prefs.notesSpeakerLabelsChoice == nil)
        #expect(h.recorder.speakers == nil)
        store.release()
        await h.until("speaker model ready") { h.session.speakers.model == .ready }
        await h.settle()
        #expect(h.recorder.speakers != nil)                     // joined mid-recording: later audio is labelled
        #expect(h.model.speakerModelNotice == nil && h.prefs.notesSpeakerLabelsChoice == nil)
        await h.stop()
    }

    @Test func aFailedDownloadShowsRetryAndKeepsLabelsOn() async throws {
        let store = FakeModelStore(downloaded: false)
        store.fail = true
        let h = NotesHarness(speakers: store)
        await h.record()
        await h.until("download failed") { h.session.speakers.model.isFailure }
        await h.settle()
        let notice = try #require(h.model.speakerModelNotice)
        #expect(notice.failed && notice.text == "Couldn’t download the speaker model.")
        #expect(h.model.speakerLabels && h.prefs.notesSpeakerLabelsChoice == nil && h.recorder.state == .recording)
        store.fail = false
        h.model.onSpeakerRetry()
        await h.until("speaker model ready") { h.session.speakers.model == .ready }
        #expect(h.model.speakerModelNotice == nil && store.loads == [true, true])
        await h.stop()
    }

    @Test func turnOffOnTheStatusLineCancelsTheDownloadEvenWhileRecording() async throws {
        let store = FakeModelStore(downloaded: false)
        store.hold = true
        let h = NotesHarness(speakers: store)
        await h.record()
        #expect(h.model.speakerModelNotice != nil)
        h.model.onSpeakerLabelsToggle(false)
        store.release()
        await h.settle()
        #expect(h.edges.beeps == 0 && !h.session.speakers.enabled && h.prefs.notesSpeakerLabelsChoice == false)
        #expect(h.model.speakerModelNotice == nil && h.session.speakers.model == .notDownloaded)
        #expect(h.recorder.speakers == nil && h.recorder.state == .recording)
        await h.stop()
        // Off stays off: the next Record neither downloads nor labels.
        await h.record()
        #expect(store.loads == [true])
        await h.stop()
    }
}

@MainActor
@Suite struct SpeakerSettingsTests {
    @Test func labelSpeakersSitsInSettingsNotesAndLocksWhileRecording() {
        var s = SettingsState()
        s.speakerLabels = true
        let form = SettingsForm(s, icon: nil, onNotices: {})
        #expect(form.labelSpeakers.state == .on && form.labelSpeakers.isEnabled)
        s.speakerLabels = false
        s.speakerLabelsLocked = true
        form.apply(s)
        #expect(form.labelSpeakers.state == .off && !form.labelSpeakers.isEnabled && form.labelSpeakers.toolTip != nil)
        #expect(SettingsTab.notes.keywords.contains("speakers"))
    }

    @Test func theSpeakerScreenshotsAreCommitted() {
        let names = Set(Snapshots.committedScenarios.map(\.name))
        #expect(names.isSuperset(of: ["notes-transcript-speakers", "notes-transcript-speakers-renamed",
                                       "notes-speaker-model-downloading", "notes-speaker-model-failed"]))
        // The whole Settings › Notes page with the switch, for review (the committed set keeps one Notes page).
        #expect(Snapshots.allScenarios.contains { $0.name == "settings-notes-speakers" })
    }
}
