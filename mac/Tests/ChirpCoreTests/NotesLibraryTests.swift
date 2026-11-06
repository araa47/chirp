import AVFoundation
import CryptoKit
import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

private final class LibraryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_000_000)
    var now: Date { lock.withLock { date } }
    func advance(days: Double) { lock.withLock { date += days * 86400 } }
}

private func libraryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("chirp-library-\(UUID().uuidString)", isDirectory: true)
}

@Suite(.serialized) struct NotesLibraryTests {
    @Test func snippetsSeparateBlocksWithoutRepeatingTheTitle() {
        let text = "## Launch sync\nThe first release goes to ten partners.\n- [ ] Draft the invite\n- [x] **Book** a review!"
        var document = NotesDocument(text: text)
        #expect(document.snippet() == "The first release goes to ten partners. · Draft the invite · Book a review!")
        document.rename("Launch sync")
        #expect(document.snippet() == "The first release goes to ten partners. · Draft the invite · Book a review!")
        document.rename("A different title")
        #expect(document.snippet() == "Launch sync · The first release goes to ten partners. · Draft the invite · Book a review!")

        var named = NotesDocument(text: "### **LAUNCH SYNC**\n- A long table by the window\n\n1. Find a reading lamp\n> Keep snake_case and a mid-line - dash.")
        named.rename("Launch sync")
        #expect(named.snippet() == "A long table by the window · Find a reading lamp · Keep snake_case and a mid-line - dash.")
        #expect(NotesDocument(text: "A title\nA sentence.\nAnother sentence?").snippet() == "A sentence. · Another sentence?")
        #expect(NotesDocument(text: "## Only a title").snippet().isEmpty)

        var spoken = NotesDocument()
        spoken.append(NotesSegment(id: 0, offset: 0, raw: "only the transcript so far"))
        #expect(spoken.snippet() == "only the transcript so far")
        let long = NotesDocument(text: "## Title\n" + String(repeating: "🪷", count: 300)).snippet()
        #expect(long.count == 240 && long.allSatisfy { $0 == "🪷" })
    }

    @Test func legacyIndexRebuildsSnippetsFromTheKeptDocument() async throws {
        let dir = libraryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NotesLibraryStore(directory: dir)
        let document = NotesDocument(text: "## Launch sync\nThe first release goes to ten partners.\n- [ ] Draft the invite")
        try await store.write(NotesJournalRecord(document: document, elapsed: 12))
        let updatedAt = try await store.record(document.id).document.updatedAt
        let index = dir.appendingPathComponent("index.json")
        var old = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [[String: Any]])
        old[0].removeValue(forKey: "snippetFormat")
        old[0]["snippet"] = "## Launch sync The first release goes to ten partners. - [ ] Draft the invite"
        try JSONSerialization.data(withJSONObject: old).write(to: index)

        let reopened = NotesLibraryStore(directory: dir)
        let entry = try #require(try await reopened.list().first)
        #expect(entry.snippet == "The first release goes to ten partners. · Draft the invite")
        #expect(try await reopened.record(document.id).document.text == document.text)
        #expect(entry.updatedAt == updatedAt)
    }

    /// A short note an older build listed as "_(nothing yet)_" is listed by its words after the update, without an edit.
    @Test func aPlaceholderTitleInTheIndexIsDerivedAgain() async throws {
        let dir = libraryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NotesLibraryStore(directory: dir)
        var document = NotesDocument(text: "_(nothing yet)_")
        document.append(NotesSegment(id: 0, offset: 0, raw: "Hello, one, two, three.", text: "Hello, one, two, three."))
        try await store.write(NotesJournalRecord(document: document, elapsed: 3))
        let index = dir.appendingPathComponent("index.json")
        var old = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [[String: Any]])
        old[0]["title"] = NotesMarkdown.placeholder
        try JSONSerialization.data(withJSONObject: old).write(to: index)
        // The index is newer than the note, so only the placeholder title marks the row stale.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)],
                                              ofItemAtPath: dir.appendingPathComponent(document.id.uuidString).appendingPathComponent("note.json").path)

        let entry = try #require(try await NotesLibraryStore(directory: dir).list().first)
        #expect(entry.title == "Hello, one, two, three")
    }

    @Test func optionalCodecSealsIndexRecordsRecoveryAndAudio() async throws {
        let dir = libraryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256)
        let codec = NotesJournalCodec(seal: { try AES.GCM.seal($0, using: key).combined! },
                                      open: { try AES.GCM.open(AES.GCM.SealedBox(combined: $0), using: key) })
        let store = NotesLibraryStore(directory: dir, codec: codec)
        var d = NotesDocument(text: "## Confidential sentinel")
        d.append(NotesSegment(id: 0, offset: 0, raw: "Private speech"))
        var record = NotesJournalRecord(document: d, elapsed: 2); record.recording = true
        try await store.write(record)
        try await store.keepAudio(d.id, segment: 0, frames: [Data(count: 64_000)], offset: 0, sampleRate: 16_000)
        for file in [dir.appendingPathComponent("index.json"), store.noteDirectory(d.id).appendingPathComponent("note.json")] {
            let bytes = try Data(contentsOf: file)
            #expect((try? JSONSerialization.jsonObject(with: bytes)) == nil)
            #expect(!String(decoding: bytes, as: UTF8.self).contains("Confidential"))
        }
        let opened = NotesLibraryStore(directory: dir, codec: codec)
        #expect(try await opened.list().first?.recovered == true)
        #expect(try await opened.record(d.id).document.text == d.text)
        #expect(try await opened.search("Private speech").count == 1)
        let audio = try await opened.audioData(d.id, segment: 0)
        #expect(try AVAudioPlayer(data: audio).duration > 0)
        #expect((try? AVAudioPlayer(contentsOf: store.audioURL(d.id, segment: 0))) == nil)
        try await opened.trash(d.id); try await opened.restore(d.id)
        #expect(try await opened.list().count == 1)
        try await opened.deleteAudio(d.id)
        #expect(try await opened.totalAudioBytes() == 0)
    }

    private final class CodecAvailability: @unchecked Sendable {
        private let lock = NSLock()
        private var available = true
        func set(_ value: Bool) { lock.withLock { available = value } }
        func check() throws { try lock.withLock { if !available { throw CocoaError(.fileWriteNoPermission) } } }
    }

    @Test func sealedIndexFailureRetriesFromDiskAfterStorageBecomesAvailable() async throws {
        let dir = libraryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = SymmetricKey(size: .bits256), availability = CodecAvailability()
        let codec = NotesJournalCodec(seal: {
            try availability.check()
            return try AES.GCM.seal($0, using: key).combined!
        }, open: { try AES.GCM.open(AES.GCM.SealedBox(combined: $0), using: key) })
        let writer = NotesLibraryStore(directory: dir, codec: codec)
        let first = NotesJournalRecord(document: NotesDocument(text: "Already kept"), elapsed: 0)
        try await writer.write(first)
        let retrying = NotesLibraryStore(directory: dir, codec: codec)
        availability.set(false)
        await #expect(throws: CocoaError.self) { try await retrying.list() }
        availability.set(true)
        let second = NotesJournalRecord(document: NotesDocument(text: "Kept while reader waited"), elapsed: 0)
        try await writer.write(second)
        #expect(Set(try await retrying.list().map(\.id)) == [first.document.id, second.document.id])
    }

    @Test func schemaOneMigratesOnceAndUnknownSchemasRemainUntouched() async throws {
        let root = libraryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recovery = NotesJournalStore(directory: root.appendingPathComponent("Recovery"))
        let document = NotesDocument(text: "## Original\n- [ ] Ship")
        var old = NotesJournalRecord(document: document, elapsed: 42, writtenAt: Date(timeIntervalSince1970: 100))
        old.schema = 1
        try recovery.write(old)
        let future = recovery.directory.appendingPathComponent("\(UUID()).json")
        let futureData = Data(#"{"schema":999,"new":true}"#.utf8)
        try futureData.write(to: future)
        let store = NotesLibraryStore(directory: root.appendingPathComponent("Notes"))
        try await store.migrate(from: recovery)
        #expect(try await store.list().count == 1)
        #expect(try await store.record(document.id).schema == 2)
        #expect(try await store.record(document.id).recovered == true)
        #expect(try await store.record(document.id).document.updatedAt == old.writtenAt)
        try await store.rename(document.id, title: "Renamed")
        try recovery.write(old) // a crash after import but before removing the old source
        try await store.migrate(from: recovery)
        #expect(try await store.list().map(\.title) == ["Renamed"])
        #expect(try Data(contentsOf: future) == futureData)
        #expect(recovery.recoverable().isEmpty)
    }

    @Test func aFutureDestinationPreservesItsRecoverySourceAndOtherNotesStillMigrate() async throws {
        let root = libraryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recovery = NotesJournalStore(directory: root.appendingPathComponent("Recovery"))
        let blocked = NotesJournalRecord(document: NotesDocument(text: "Keep source"), elapsed: 2)
        let good = NotesJournalRecord(document: NotesDocument(text: "Migrate this"), elapsed: 3)
        try recovery.write(blocked); try recovery.write(good)
        let store = NotesLibraryStore(directory: root.appendingPathComponent("Notes"))
        let futureFile = store.noteDirectory(blocked.document.id).appendingPathComponent("note.json")
        let futureData = Data(#"{"schema":999}"#.utf8)
        try NotesAtomicFile.write(futureData, to: futureFile)
        try await store.migrate(from: recovery)
        #expect(try await store.list().map(\.id) == [good.document.id])
        #expect(recovery.recoverable().map(\.document.id) == [blocked.document.id])
        #expect(try Data(contentsOf: futureFile) == futureData)
        var unsupported = NotesJournalRecord(document: NotesDocument(text: "Future input"), elapsed: 1)
        unsupported.schema = 999
        await #expect(throws: NotesLibraryError.self) { try await store.write(unsupported) }
        #expect(!FileManager.default.fileExists(atPath: store.noteDirectory(unsupported.document.id).path))
    }

    @Test func overOneHundredNotesReloadWithIndexAndOwnerOnlyFiles() async throws {
        let dir = libraryDirectory(), clock = LibraryClock()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NotesLibraryStore(directory: dir, now: { clock.now })
        var ids: [UUID] = []
        for i in 0..<105 {
            let d = NotesDocument(text: "## Note \(i)\n- [ ] Task\n- [x] Finished")
            ids.append(d.id)
            try await store.write(NotesJournalRecord(document: d, elapsed: Double(i)))
            clock.advance(days: 0.01)
        }
        let reloaded = NotesLibraryStore(directory: dir)
        let list = try await reloaded.list()
        #expect(list.map(\.id) == ids.reversed())
        #expect(list.allSatisfy { $0.openTodos == 1 })
        let index = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("index.json"))) as! [[String: Any]]
        #expect(index.count == 105 && index.allSatisfy { $0["hasAudio"] as? Bool == false })
        for url in [dir, dir.appendingPathComponent(ids[0].uuidString), dir.appendingPathComponent("index.json"), dir.appendingPathComponent(ids[0].uuidString + "/note.json")] {
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
            #expect(mode == (url.pathExtension == "json" ? 0o600 : 0o700))
        }
    }

    @Test func trashRestoreAndThirtyDayPurgeUseDeletionTime() async throws {
        let dir = libraryDirectory(), clock = LibraryClock()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NotesLibraryStore(directory: dir, now: { clock.now })
        let r = NotesJournalRecord(document: NotesDocument(text: "Keep me"), elapsed: 4)
        try await store.write(r)
        try await store.trash(r.document.id)
        clock.advance(days: 29.99)
        try await store.maintain(retention: .never)
        #expect(try await store.list(deleted: true).count == 1)
        try await store.restore(r.document.id)
        #expect(try await store.list().count == 1)
        try await store.trash(r.document.id)
        clock.advance(days: 30)
        try await store.maintain(retention: .never)
        #expect(try await store.list(deleted: true).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.noteDirectory(r.document.id).path))
        await #expect(throws: NotesLibraryError.self) { try await store.write(r) }
    }

    @Test(arguments: [NotesRetention.thirtyDays, .ninetyDays, .oneYear])
    func retentionTrashesOnlyOldStoppedNotes(_ retention: NotesRetention) async throws {
        let dir = libraryDirectory(), clock = LibraryClock()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NotesLibraryStore(directory: dir, now: { clock.now })
        let old = NotesJournalRecord(document: NotesDocument(text: "Old"), elapsed: 1)
        var active = NotesJournalRecord(document: NotesDocument(text: "Recording"), elapsed: 2)
        active.recording = true
        try await store.write(old); try await store.write(active)
        clock.advance(days: Double(retention.days!) + 1)
        try await store.maintain(retention: .never)
        #expect(try await store.list().count == 2)
        try await store.maintain(retention: retention)
        #expect(try await store.list().map(\.id) == [active.document.id])
        #expect(try await store.list(deleted: true).map(\.id) == [old.document.id])
        await #expect(throws: NotesLibraryError.self) { try await store.trash(active.document.id) }
    }

    @Test func searchMatchesTitleBodyAndBothTranscriptFormsWithHighlights() async throws {
        let dir = libraryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NotesLibraryStore(directory: dir)
        var d = NotesDocument(text: "## Café plan\n- [ ] Buy tea")
        d.append(NotesSegment(id: 0, offset: 0, raw: "raw words", text: "Corrected words"))
        try await store.write(NotesJournalRecord(document: d, elapsed: 2))
        try await store.rename(d.id, title: "Release")
        for query in ["release", "CAFE", "buy tea", "raw words", "corrected words"] {
            let results = try await store.search(query)
            #expect(results.count == 1 && !results[0].matches.isEmpty)
        }
        #expect(try await store.search("missing").isEmpty)
        try await store.trash(d.id)
        #expect(try await store.search("release").isEmpty)
    }

    @Test func userTitleWinsAndCaptureInvalidatesOldAIRequests() throws {
        var d = NotesDocument(text: "First line\n## Heading\n- [ ] Task\n- [x] Done")
        #expect(d.title == "Heading" && d.openTodoCount() == 1)
        d.rename("My title")
        d.append(NotesSegment(id: 0, offset: 0, raw: "Planning Friday"))
        let request = try #require(d.nextStructureRequest())
        let generation = d.windowGeneration
        d.beginCapture(offset: 12)
        #expect(d.sessions.last?.offset == 12 && d.sessions.last?.firstSegment == 1)
        #expect(d.windowGeneration > generation)
        #expect(d.apply(NotesStructureResponse(markdown: "## Other", structured: true), for: request) == nil)
        #expect(d.title == "My title")
        var other = NotesDocument(text: "Other note")
        #expect(other.apply(NotesStructureResponse(markdown: "Wrong note", structured: true), for: request) == nil)
    }

    @Test func audioIsAACMonoWithMetadataAndExplicitDeletionKeepsText() async throws {
        let dir = libraryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NotesLibraryStore(directory: dir)
        var d = NotesDocument(text: "Audio note")
        d.append(NotesSegment(id: 0, offset: 40, raw: "Speech"))
        try await store.write(NotesJournalRecord(document: d, elapsed: 42))
        let pcm = Data(repeating: 0, count: 64_000)
        try await store.keepAudio(d.id, segment: 0, frames: [pcm], offset: 40, sampleRate: 16_000)
        let url = store.audioURL(d.id, segment: 0)
        let audioFile = try AVAudioFile(forReading: url)
        #expect(audioFile.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC)
        #expect(audioFile.fileFormat.channelCount == 1)
        let ref = try #require(await store.record(d.id).document.audio.first)
        #expect(ref.offset == 40 && ref.duration == 2 && ref.sampleRate == 16_000 && ref.bytes > 0)
        #expect(try await store.totalAudioBytes() == ref.bytes)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
        // A text write captured before the encoder finished must retain the audio metadata.
        try await store.write(NotesJournalRecord(document: d, elapsed: 42))
        #expect(try await store.record(d.id).document.audio.count == 1)
        try await store.deleteAudio(d.id)
        #expect(try await store.record(d.id).document.text == "Audio note")
        #expect(try await store.totalAudioBytes() == 0)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try await store.keepAudio(d.id, segment: 0, frames: [pcm], offset: 40, sampleRate: 16_000)
        try await store.trash(d.id); try await store.purge(d.id)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func unknownLibrarySchemasAreNeverOverwrittenAndAnInterruptedIndexWriteIsRebuilt() async throws {
        let dir = libraryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NotesLibraryStore(directory: dir)
        let d = NotesDocument(text: "Future")
        let r = NotesJournalRecord(document: d, elapsed: 1)
        try await store.write(r)
        let future = store.noteDirectory(d.id).appendingPathComponent("note.json")
        let futureData = Data(#"{"schema":999}"#.utf8)
        try futureData.write(to: future)
        await #expect(throws: NotesLibraryError.self) { try await store.write(r) }
        await #expect(throws: NotesLibraryError.self) { try await store.purge(d.id) }
        #expect(try Data(contentsOf: future) == futureData)
        let recovered = NotesDocument(text: "Record written before the index rename")
        let recordFile = store.noteDirectory(recovered.id).appendingPathComponent("note.json")
        try NotesAtomicFile.write(JSONEncoder().encode(NotesJournalRecord(document: recovered, elapsed: 10)), to: recordFile)
        let relaunched = NotesLibraryStore(directory: dir)
        #expect(try await relaunched.list().map(\.id) == [recovered.id])
    }

    @Test func staleTextWritesPreserveRenameAndBrowsingDoesNotChangeModifiedTime() async throws {
        let dir = libraryDirectory(), clock = LibraryClock()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NotesLibraryStore(directory: dir, now: { clock.now })
        let r = NotesJournalRecord(document: NotesDocument(text: "Original"), elapsed: 4)
        try await store.write(r)
        let modified = try await store.record(r.document.id).document.updatedAt
        clock.advance(days: 1)
        try await store.write(r)
        #expect(try await store.record(r.document.id).document.updatedAt == modified)
        try await store.rename(r.document.id, title: "Chosen title")
        try await store.write(r)
        #expect(try await store.record(r.document.id).document.title == "Chosen title")
        try await store.trash(r.document.id)
        await #expect(throws: NotesLibraryError.self) { try await store.write(r) }
        #expect(try await store.list().isEmpty)
    }

    @Test func crashMarksRecordingRecoveredAndKeepsStoppedNotesOrdinary() async throws {
        let dir = libraryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NotesLibraryStore(directory: dir)
        var r = NotesJournalRecord(document: NotesDocument(text: "Interrupted"), elapsed: 20)
        r.recording = true
        try await store.write(r)
        let stopped = NotesJournalRecord(document: NotesDocument(text: "Stopped"), elapsed: 4)
        try await store.write(stopped)
        let relaunched = NotesLibraryStore(directory: dir)
        let list = try await relaunched.list()
        #expect(list.first(where: { $0.id == r.document.id })?.recovered == true)
        #expect(list.first(where: { $0.id == stopped.document.id })?.recovered == false)
        #expect(try await relaunched.record(r.document.id).recording == false)
    }

    @Test @MainActor func libraryJournalKeepsCleanExportedAndReplacedNotes() async throws {
        let dir = libraryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = NotesLibrary(store: NotesLibraryStore(directory: dir))
        let journal = NotesJournal(store: NotesJournalStore(directory: dir.appendingPathComponent("Recovery")), library: library)
        var d = NotesDocument(text: "Saved automatically")
        journal.update(d, elapsed: 10, urgent: true)
        await journal.settle()
        d.markSaved()
        journal.update(d, elapsed: 10, urgent: true)
        journal.discard() // legacy quit callers must preserve the library too
        journal.update(NotesDocument(), elapsed: 0)
        await journal.settle()
        #expect(library.notes.map(\.id) == [d.id])
        #expect(try await library.record(d.id).document.text == d.text)
    }

    @Test @MainActor func blankStoppedNoteIsNotKeptAndPreferencesDefaultSafely() async throws {
        let dir = libraryDirectory(), suite = "chirp-library-prefs-\(UUID())"
        defer { try? FileManager.default.removeItem(at: dir); UserDefaults.standard.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: UserDefaults(suiteName: suite)!)
        #expect(prefs.notesRetention == .never && !prefs.notesKeepAudio)
        prefs.notesRetention = .ninetyDays; prefs.notesKeepAudio = true
        #expect(prefs.notesRetention == .ninetyDays && prefs.notesKeepAudio)
        let library = NotesLibrary(store: NotesLibraryStore(directory: dir))
        let journal = NotesJournal(library: library)
        let blank = NotesDocument()
        journal.update(blank, elapsed: 0, recording: true)
        await journal.settle()
        #expect(library.notes.count == 1)
        journal.update(blank, elapsed: 0, urgent: true, recording: false)
        await journal.settle()
        #expect(library.notes.isEmpty)
    }
}

@MainActor @Suite(.serialized) struct NotesLibrarySessionTests {
    @Test func continueRecordingKeepsOffsetsAndAudioOptInIsIndependentOfDeletion() async throws {
        let dir = libraryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = NotesLibrary(store: NotesLibraryStore(directory: dir))
        let h = NotesHarness(library: library)
        h.prefs.notesKeepAudio = true
        await h.record(); await h.speak(2); await h.stop()
        await h.session.journal.settle()
        let id = h.document.id, elapsed = h.recorder.elapsed
        #expect(try await library.record(id).document.audio.count == 1)
        h.session.reset()
        try await h.session.continueRecording(id, focus: false)
        await h.until("continued capture") { h.engine.isTapped }
        await h.speak(1); await h.stop()
        await h.session.journal.settle()
        #expect(h.document.id == id && h.document.sessions.count == 2)
        #expect(h.document.sessions[1].offset == elapsed)
        #expect(h.document.segments.last!.offset >= elapsed)
        #expect(h.recorder.elapsed > elapsed)
        #expect(try await library.segmentAudio(id).count == 2)
        h.prefs.notesKeepAudio = false
        await h.record(); await h.speak(1); await h.stop()
        await h.session.journal.settle()
        #expect(try await library.record(id).document.audio.count == 2)
        #expect(library.notes.count == 1)
        h.session.reset()
        await h.record(); await h.speak(1); await h.stop()
        await h.session.journal.settle()
        #expect(library.notes.count == 2)
        try await library.deleteAudio(id)
        #expect(try await library.record(id).document.audio.isEmpty)
    }
    @Test func lateOrganizeCannotChangeAnotherLoadedNote() async throws {
        let dir = libraryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = NotesLibrary(store: NotesLibraryStore(directory: dir))
        let h = NotesHarness(health: Health(correction: "available", notesStructure: true, notesReorganize: true), library: library,
            finalText: { _ in "We reviewed the budget for the next quarter and agreed that Priya will send the updated vendor contract on Thursday." })
        await h.record(); await h.speak(2); await h.stop()
        await h.session.journal.settle()
        let firstID = h.document.id
        let second = NotesDocument(text: "## Second note\n- Keep these words exactly as written.")
        try await library.write(NotesJournalRecord(document: second, elapsed: 0))
        h.http.hold = true
        h.recorder.reorganizeNow()
        await h.until("organize waits", within: 5) { h.http.waiting > 0 }
        try await h.session.openNote(second.id)
        h.http.release()
        await h.settle()
        await h.session.journal.settle()
        #expect(h.document.id == second.id && h.document.text == second.text)
        #expect(try await library.record(firstID).document.id == firstID)
    }

    @Test func updatedExportStaysAssociatedWithItsNoteAfterOpeningAgain() async throws {
        let dir = libraryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = NotesLibrary(store: NotesLibraryStore(directory: dir))
        let h = NotesHarness(library: library)
        await h.record(); await h.speak(1); await h.stop()
        let id = h.document.id, file = dir.appendingPathComponent("export.md")
        try h.document.exportMarkdown().write(to: file, atomically: true, encoding: .utf8)
        h.session.didSave(to: file, keep: true)
        await h.session.journal.settle()
        h.session.reset()
        try await h.session.openNote(id)
        #expect(h.session.journal.savedFile == file && h.session.journal.keepStatus.isSaving)
        h.recorder.userEdit(NSRange(location: h.text.utf16.count, length: 0), "\n- New task")
        h.session.journal.flush()
        await h.session.journal.settle()
        #expect(try String(contentsOf: file, encoding: .utf8).contains("New task"))
        #expect(try await library.record(id).document.text.contains("New task"))
        #expect(library.notes.count == 1 && h.model.exportTitle == "Export Markdown…")
    }

}

/// The title a note gets from its text when it has no heading and no chosen title (#201: a speaker-labelled paragraph
/// was the whole title).
@Suite struct DerivedTitleTests {
    private func title(_ text: String, segment: String? = nil, build: (inout NotesDocument) -> Void = { _ in }) -> String {
        var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 0), text: text)
        if let segment { d.append(NotesSegment(id: 0, offset: 0, raw: segment, text: segment)) }
        build(&d)
        return d.title
    }

    @Test func listMarkersAndASpeakerLabelComeOffAndItStopsAtTheFirstSentence() {
        #expect(title("- Person 1: We should ship the new onboarding flow on Friday. Person 2: That sounds good.")
                == "We should ship the new onboarding flow on Friday")
        #expect(title("* Send the proposal") == "Send the proposal")
        #expect(title("1. Book the room. Then call") == "Book the room")
        #expect(title("- [ ] Send the proposal by Friday") == "Send the proposal by Friday")
        #expect(title("> Question? Who leads") == "Question")
    }

    @Test func aRenamedPersonsLabelComesOffToo() {
        let t = title("- Maya: That sounds good to me. Person 1: ok") { d in
            d.append(NotesSegment(id: 0, offset: 0, raw: "x", text: "x"))
            d.attachServerTurns([ServerTurn(speaker: 0, start: 0, text: "x")], generation: "g", toSegment: 0)
            d.renameSpeaker(1, to: "Maya")
        }
        #expect(t == "That sounds good to me")
        // A colon that is not a known speaker stays: "Agenda: review" is the user's own line.
        #expect(title("Agenda: review the plan") == "Agenda: review the plan")
    }

    @Test func aLongTitleIsCutOnAWordBoundaryWithAnEllipsis() {
        let t = title("- Person 1: We should ship the new onboarding flow on Friday, and I will write the announcement tonight.")
        #expect(t == "We should ship the new onboarding flow on Friday, and I will…")
        #expect(t.count <= NotesDocument.derivedTitleLength + 1)
        let words = title(String(repeating: "word ", count: 40))
        #expect(words.hasSuffix("…") && words.count <= NotesDocument.derivedTitleLength + 1 && !words.contains("wor…"))
        // One long unbroken token is cut where it is.
        #expect(title(String(repeating: "a", count: 100)).count == NotesDocument.derivedTitleLength + 1)
    }

    @Test func aShortTitleIsLeftAlone() {
        #expect(title("Call the dentist") == "Call the dentist")
        #expect(title("Call the dentist\nthen the bank") == "Call the dentist")
    }

    @Test func nothingLeftFallsBackToTheNextLineThenTheSegmentThenTheDate() {
        #expect(title("- \n---\n- Person 1:\nReal first line") == "Real first line")
        #expect(title("", segment: "Person 1: hello there. Bye") == "hello there")
        #expect(title("- Person 1:").hasPrefix("Note, "))
        #expect(title("").hasPrefix("Note, "))
    }

    /// A short recording the passes found nothing in kept "_(nothing yet)_" as its title (and the window's).
    @Test func thePlaceholderAndTheNotStructuredNoticeAreNeverTheTitle() {
        #expect(title("_(nothing yet)_", segment: "Hello, one, two, three.") == "Hello, one, two, three")
        #expect(title("\(NotesDocument.fallbackHeader)\n\nwe ship friday") == "we ship friday")
        #expect(title("_(nothing yet)_").hasPrefix("Note, "))
        var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 0), text: "_(nothing yet)_\n\n- Ship Friday")
        d.append(NotesSegment(id: 0, offset: 0, raw: "x", text: "x"))
        #expect(d.title == "Ship Friday" && !d.snippet().contains("nothing yet"))
    }

    @Test func aHeadingAndAChosenTitleAreUnchanged() {
        #expect(title("intro\n## The Heading\nbody") == "The Heading")
        var d = NotesDocument(text: "- Person 1: long text here")
        d.rename("My title")
        #expect(d.title == "My title")
    }
}
