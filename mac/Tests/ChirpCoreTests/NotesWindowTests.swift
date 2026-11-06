import AppKit
import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// The Live Notes window around the note (#157): the library list's groups and wording, live preview, the block-level
/// Organize review, and the library actions through a whole session.
@MainActor
@Suite struct NotesWindowTextTests {
    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// 2026-10-20 14:03 UTC, a Tuesday.
    private let now = Date(timeIntervalSince1970: 1_792_504_980)

    private func entry(_ hoursAgo: Double, _ title: String = "n") -> NotesLibraryEntry {
        NotesLibraryEntry(id: UUID(), title: title, createdAt: now, updatedAt: now.addingTimeInterval(-hoursAgo * 3600))
    }

    @Test func notesGroupByAgeThenMonthNewestFirst() {
        let list = [entry(1, "a"), entry(30, "b"), entry(24 * 5, "c"), entry(24 * 20, "d"), entry(24 * 60, "e"), entry(24 * 400, "f"), entry(0.1, "g")]
        let groups = NotesLibraryText.groups(list, now: now, calendar: utc)
        #expect(groups.map(\.title) == ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "August", "September 2025"])
        #expect(groups[0].entries.map(\.title) == ["g", "a"])
    }

    @Test func rowTimesReadLikeAMailList() {
        #expect(NotesLibraryText.relative(now.addingTimeInterval(-3600), now: now, calendar: utc) == "1:03 PM")
        #expect(NotesLibraryText.relative(now.addingTimeInterval(-86400), now: now, calendar: utc) == "Yesterday")
        #expect(NotesLibraryText.relative(now.addingTimeInterval(-3 * 86400), now: now, calendar: utc) == "Saturday")
        #expect(NotesLibraryText.relative(now.addingTimeInterval(-20 * 86400), now: now, calendar: utc) == "Sep 30")
        #expect(NotesLibraryText.relative(now.addingTimeInterval(-400 * 86400), now: now, calendar: utc) == "Sep 15, 2025")
        #expect(NotesLibraryText.duration(0) == nil && NotesLibraryText.duration(45) == "45 s")
        #expect(NotesLibraryText.duration(12 * 60) == "12 min" && NotesLibraryText.duration(3900) == "1 h 05 min")
        #expect(NotesLibraryText.continued(now, timeZone: TimeZone(identifier: "UTC")!) == "Continued · Oct 20, 2:03 PM")
    }

    @Test func snippetsReadWithoutTheirMarkdown() {
        let raw = "## Agenda - Lantern kickoff - [x] Share the doc with **Maya** - [ ] Book _the_ review 1. First"
        #expect(NotesLibraryText.plain(raw) == "Agenda · Lantern kickoff · Share the doc with Maya · Book the review · First")
        #expect(NotesLibraryText.plain("Plain words stay - as they are") == "Plain words stay · as they are")
        #expect(NotesLibraryText.plain("snake_case_name stays") == "snake_case_name stays")
    }

    @Test func theShortcutBecomesKeycaps() {
        #expect(KeycapRow.keys("⌃⌥N") == ["⌃", "⌥", "N"])
        #expect(KeycapRow.keys("⌃⌥Space") == ["⌃", "⌥", "Space"])
        #expect(KeycapRow.keys("Right ⌥ Option") == ["Right ⌥ Option"])
    }

    @Test func theRecordingNoteIsPinnedAndAPendingNoteIsListed() {
        let library = NotesLibraryModel()
        library.now = { now }
        library.calendar = utc
        let a = entry(1, "a"), recording = entry(0.2, "rec")
        library.notes = [recording, a]
        library.recordingID = recording.id
        #expect(library.groups().flatMap(\.entries).map(\.title) == ["a"])
        #expect(!library.canTrash(recording.id) && library.canTrash(a.id) && !library.canTrash(nil))
        let pending = entry(0, "new")
        #expect(library.groups(pending: pending).flatMap(\.entries).map(\.title) == ["new", "a"])
        #expect(!library.isEmpty)
        library.notes = []
        library.recordingID = nil
        #expect(library.isEmpty)
    }

    @Test func renameCommitsOnlyAChangedTitle() {
        let library = NotesLibraryModel()
        let a = entry(1, "Weekly sync")
        library.notes = [a]
        var renamed: [String] = []
        library.onRename = { _, title in renamed.append(title) }
        library.beginRename(a.id)
        #expect(library.renaming == a.id && library.renameText == "Weekly sync")
        library.commitRename()
        library.beginRename(a.id)
        library.renameText = "  Planning  "
        library.commitRename()
        #expect(renamed == ["Planning"] && library.renaming == nil)
    }

    @Test func aNewerToastRestartsItsTimer() {
        let library = NotesLibraryModel()
        let id = UUID()
        library.showToast(NotesLibraryText.deleted, undo: id)
        let first = library.toast!.serial
        library.showToast(NotesLibraryText.deleted, undo: id)
        #expect(library.toast!.serial == first + 1 && library.toast!.undo == id)
    }

    // MARK: Organize review

    @Test func theReviewComparesBlocksAndPairsReplacements() {
        let before = "## Plan\n- Ship Friday\n- Ask Theo\n\n## Budget\n- Keep the vendor"
        let after = "## Plan\n- Ship on **Friday**\n- Ask Theo\n\n## Budget\n- Keep the vendor\n- [ ] Send the contract"
        let rows = NotesBlockDiff.rows(before: before, after: after)
        #expect(rows.map(\.kind) == [.same, .changed, .same, .same, .same, .added])
        #expect(rows[1].before == "- Ship Friday" && rows[1].after == "- Ship on **Friday**")
        #expect(NotesBlockDiff.summary(rows) == "1 changed · 1 added")
        #expect(NotesBlockDiff.summary(NotesBlockDiff.rows(before: "a", after: "a")) == "No changes")
        let removed = NotesBlockDiff.rows(before: "a\nb\nc", after: "a\nc")
        #expect(removed.map(\.kind) == [.same, .removed, .same] && removed[1].before == "b" && removed[1].after == nil)
    }

    @Test func longUnchangedRunsFold() {
        let before = (1...10).map { "- line \($0)" }.joined(separator: "\n")
        let after = before.replacingOccurrences(of: "- line 6", with: "- line six")
        let folded = NotesBlockDiff.folded(NotesBlockDiff.rows(before: before, after: after))
        // ⋯ 4 unchanged, line 5, the change, line 7, ⋯ 3 unchanged.
        #expect(folded.count == 5)
        #expect(folded.first?.before == nil && folded.first?.after == "4" && folded.last?.after == "3")
        #expect(folded[2].kind == .changed)
    }

    // MARK: live preview

    private func styled(_ text: String, hide: Bool, raw: NSRange?) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        NotesEditorStyle.restyle(storage, hide: hide, raw: raw)
        return storage
    }

    private func isHidden(_ storage: NSTextStorage, _ at: Int) -> Bool {
        ((storage.attribute(.font, at: at, effectiveRange: nil) as? NSFont)?.pointSize ?? 99) < 1
    }

    private func isClear(_ storage: NSTextStorage, _ at: Int) -> Bool {
        (storage.attribute(.foregroundColor, at: at, effectiveRange: nil) as? NSColor) == .clear
    }

    @Test func livePreviewHidesSyntaxExceptOnTheCaretLine() {
        let text = "## Plan\n- Ship **Friday**\n- [ ] Ask Theo"
        let hidden = styled(text, hide: true, raw: nil)
        #expect(isHidden(hidden, 0) && isHidden(hidden, 1) && isHidden(hidden, 2))   // "## " goes, space too
        #expect(!isHidden(hidden, 3))                                                 // "Plan" stays
        let bold = (text as NSString).range(of: "**").location
        #expect(isHidden(hidden, bold) && isClear(hidden, 8))                         // ** shrinks, the dash is drawn over
        let box = (text as NSString).range(of: "[ ]").location
        #expect(isClear(hidden, box) && isHidden(hidden, box - 2))                    // a task loses its "- " entirely
        // The caret on the second line shows that line's Markdown, and only that line's.
        let caret = styled(text, hide: true, raw: NSRange(location: 8, length: 18))
        #expect(isHidden(caret, 0) && !isHidden(caret, bold) && !isClear(caret, 8))
        // Show Markdown: every character shows.
        let raw = styled(text, hide: false, raw: nil)
        #expect((0..<raw.length).allSatisfy { !isHidden(raw, $0) && !isClear(raw, $0) })
        #expect(raw.string == text && hidden.string == text)                         // attributes only, never the text
    }

    @Test func calloutsAndMarksAreDecorated() {
        let text = "- **Decision:** keep it\n- **Question:** who owns QA?\n- plain\n  - nested\n- [x] done"
        let items = NotesEditorDecorations.items(text, hide: true, raw: nil)
        #expect(items.map(\.kind) == [.decision, .question, .bullet(nested: false), .bullet(nested: true), .task(checked: true)])
        #expect(items.allSatisfy { $0.concealed })
        // On the caret's line the dash shows itself; a callout keeps its tint.
        let caret = NotesEditorDecorations.items(text, hide: true, raw: NSRange(location: 0, length: 24))
        #expect(caret.first?.kind == .decision && caret.first?.concealed == false)
        #expect(NotesEditorDecorations.items(text, hide: false, raw: nil).map(\.kind) == [.decision, .question, .task(checked: true)])
        // The two labels keep their own colours (dynamic colours with one name would merge into one run).
        let storage = NSTextStorage(string: text)
        NotesEditorStyle.restyle(storage, hide: true)
        let decision = storage.attribute(.foregroundColor, at: (text as NSString).range(of: "Decision").location, effectiveRange: nil) as? NSColor
        let question = storage.attribute(.foregroundColor, at: (text as NSString).range(of: "Question").location, effectiveRange: nil) as? NSColor
        #expect(decision != nil && question != nil && decision != question)
    }
}

private func libraryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("chirp-window-\(UUID().uuidString)", isDirectory: true)
}

/// The library actions through a whole session: browsing beside a recording, Delete with Undo, Continue and its
/// "Stop current and continue here", New Note and search.
@MainActor @Suite(.serialized) struct NotesWindowSessionTests {
    @Test func browsingAnotherNoteNeverStopsTheRecordingAndItsEditsAreKept() async throws {
        let dir = libraryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = NotesLibrary(store: NotesLibraryStore(directory: dir))
        let other = NotesDocument(text: "## Other note\n- a line")
        try await library.write(NotesJournalRecord(document: other, elapsed: 0))
        let h = NotesHarness(library: library)
        let w = h.session.window
        await h.record(); await h.speak(1)
        let recordingID = h.document.id
        await h.until("listed") { w.recordingID == recordingID }
        w.select(.note(other.id))
        await h.until("browsed") { w.browsed?.document.id == other.id }
        #expect(h.recorder.state.isCapturing && h.document.id == recordingID)
        #expect(h.session.displayedModel.document.id == other.id)
        // Typing in the browsed note goes to the library; the recorder's note is untouched.
        let browsed = try #require(w.browsed)
        browsed.onUserEdit(NSRange(location: browsed.document.text.utf16.count, length: 0), "\n- typed beside", .user)
        w.select(.note(recordingID))
        await h.until("back on the recording") { w.browsed == nil }
        var saved = false
        for _ in 0..<100 where !saved {
            saved = (try? await library.record(other.id).document.text.contains("typed beside")) == true
            if !saved { try? await Task.sleep(for: .milliseconds(100)) }
        }
        #expect(saved)
        #expect(!h.document.text.contains("typed beside") && h.recorder.state.isCapturing)
        // The recording note can't be deleted.
        h.session.trash(recordingID)
        #expect(library.recentlyDeleted.isEmpty)
        await h.stop()
    }

    /// With no notes the window shows the empty-state art, not an editor: New Note must bring up the blank note's
    /// editor and focus it when it appears (it used to only bump a focus request nobody was listening to).
    @Test func newNoteOnTheEmptyStateShowsTheEditorAndFocusesItWhenItAppears() async throws {
        let dir = libraryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let h = NotesHarness(library: NotesLibrary(store: NotesLibraryStore(directory: dir)))
        #expect(h.session.window.isEmpty && h.model.showsEmptyState)
        let before = h.model.focusRequest
        h.session.newNote()
        #expect(!h.model.showsEmptyState && h.model.composing)
        #expect(h.model.focusOnAppear && h.model.focusRequest == before + 1)
        // A recorded note hides the art on its own; reset (the next New, a delete) clears the flag.
        await h.record(); await h.speak(1); await h.stop()
        #expect(!h.model.showsEmptyState)
        h.session.reset()
        #expect(!h.model.composing)
    }

    @Test func deleteMovesToRecentlyDeletedAndUndoBringsItBack() async throws {
        let dir = libraryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = NotesLibrary(store: NotesLibraryStore(directory: dir))
        let h = NotesHarness(library: library)
        let w = h.session.window
        await h.record(); await h.speak(1); await h.stop()
        await h.session.journal.settle()
        let id = h.document.id
        await h.until("listed") { w.notes.map(\.id) == [id] }
        h.session.trash(id)
        // The library's `deleted` list updates before trash's task has reset the recorder and shown the toast;
        // wait for all of it (reading them in that gap raced in a full run).
        await h.until("deleted") { w.deleted.map(\.id) == [id] && w.notes.isEmpty && w.toast?.undo == id && h.document.id != id }
        #expect(w.notes.isEmpty && w.toast?.undo == id && w.toast?.text == NotesLibraryText.deleted)
        #expect(h.document.id != id)                                  // the recorder moved on to a blank note
        w.onRestore(id)
        // Wait for the whole postcondition: the library reload lands in `notes` before restore's own task has
        // cleared the toast and moved the selection (reading them in that gap raced in a full run).
        await h.until("restored") { w.notes.map(\.id) == [id] && w.deleted.isEmpty && w.toast == nil && w.selection == .note(id) }
        #expect(w.deleted.isEmpty && w.toast == nil && w.selection == .note(id))
        await h.until("open again") { h.document.id == id }
    }

    @Test func continueBesideARecordingAsksThenSwitchesAndLeavesADivider() async throws {
        let dir = libraryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = NotesLibrary(store: NotesLibraryStore(directory: dir))
        let h = NotesHarness(library: library)
        let w = h.session.window
        await h.record(); await h.speak(1); await h.stop()
        await h.session.journal.settle()
        let first = h.document.id
        h.session.newNote()
        #expect(h.document.id != first && w.selection == .note(h.document.id))
        await h.record(); await h.speak(1)
        let second = h.document.id
        h.session.continueHere(first)
        #expect(w.confirmingSwitch == first && h.document.id == second)   // asks; nothing stopped yet
        w.confirmingSwitch = nil
        await h.session.stopAndContinue(first)
        await h.until("continuing", within: 10) { h.document.id == first && h.engine.isTapped }
        #expect(h.document.sessions.count == 2 && w.recordingID == first)
        await h.speak(1); await h.stop()
        await h.session.journal.settle()
        #expect(try await library.record(second).document.segments.count >= 1)
    }

    @Test func searchFindsTheTranscriptAndClearsWithTheField() async throws {
        let dir = libraryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let library = NotesLibrary(store: NotesLibraryStore(directory: dir))
        try await library.write(NotesJournalRecord(document: NotesDocument(text: "## Lantern\n- the beta starts in April"), elapsed: 0))
        try await library.write(NotesJournalRecord(document: NotesDocument(text: "## Groceries\n- lemons"), elapsed: 0))
        let h = NotesHarness(library: library)
        let w = h.session.window
        w.query = "BETA"
        await h.until("results") { w.results?.count == 1 }
        #expect(w.results?.first?.matches.isEmpty == false)
        w.query = "kangaroo"
        await h.until("no results") { w.results?.isEmpty == true }
        w.query = ""
        #expect(w.results == nil)
    }
}
