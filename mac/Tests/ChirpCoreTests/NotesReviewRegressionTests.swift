import AppKit
import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// Review regressions for feat/notes-edit (issue #17): editor.
@MainActor
@Suite struct NotesReviewRegressionTests {
    /// Spec rule 2: AI changes are held while marked text exists. A reorganize is never held (and its `version` check
    /// cannot see an uncommitted composition), so it replays mid-composition: NSTextView drops the composition and
    /// the caret lands at the end of the document, where the next keystroke claims the AI tail.
    @Test func aReorganizeDuringIMECompositionKeepsTheCompositionAndCaret() throws {
        let h = NotesEditorTests.Harness(typed: "## Budget\n- keep the vendor contract\n\n## Hiring\n- no new headcount\n\n## Budget\n- review in May\n")
        let tv = h.editor.textView
        let at = (h.text as NSString).range(of: "no new").location
        tv.setSelectedRange(NSRange(location: at, length: 0))
        tv.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: at, length: 0))
        try #require(tv.hasMarkedText())
        try #require(h.reorganize("## Budget\n- keep the vendor contract\n- review in May\n\n## Hiring\n- no new headcount") != nil)
        #expect(tv.hasMarkedText())                                  // fails: the composition is gone
        #expect(tv.selectedRange().location < h.text.utf16.count)    // fails: caret at the very end
    }

    /// The same for an append replayed while composing (the Stop path applies a held append and `freezeAll`, and
    /// `schedule()` can publish `freezeOverflow()`, whatever the composing state).
    @Test func anAppendDuringIMECompositionKeepsTheComposition() throws {
        let h = NotesEditorTests.Harness(typed: "my own line\n", segments: ["a"])
        let tv = h.editor.textView
        tv.setSelectedRange(NSRange(location: 2, length: 0))
        tv.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: 2, length: 0))
        try #require(tv.hasMarkedText())
        try #require(h.append("- a") != nil)
        #expect(tv.hasMarkedText())                                  // fails: the composition is gone
    }

    /// The common "type my own notes at the bottom while recording" flow: an append lands after the caret (which
    /// correctly stays put, at `tailStart`), and the user's very next keystroke, on their own line, is an insertion
    /// at `tailStart` with a non-empty tail, so it claims the whole AI tail. The AI never gets to grow its block.
    @Test func typingOnOnesOwnLastLineDoesNotClaimTheAITail() throws {
        let h = NotesEditorTests.Harness(typed: "my own line", segments: ["a"])
        h.editor.textView.setSelectedRange(NSRange(location: 11, length: 0))
        try #require(h.append("## Plan\n- a") != nil)
        #expect(h.editor.textView.selectedRange() == NSRange(location: 11, length: 0))
        h.type("!")                                                  // "my own line!"
        #expect(h.text.hasPrefix("my own line!\n\n## Plan"))
        #expect(!h.model.document.tail.isEmpty)                      // fails: tail claimed
    }
}

import SwiftUI

@MainActor
@Suite struct NotesReviewTabSwitchTests {
    /// Opening another note beside a recording builds that note's editor; coming back builds the recorder's again. The
    /// browsed editor must never take the recorder's sink, and the recorder's new editor must own it once it is back:
    /// otherwise every later AI change is dropped (only a full `load()` resync would bring it back: caret, scroll and
    /// undo reset).
    @Test func browsingAnotherNoteKeepsTheRecordersEditorSink() async throws {
        let model = NotesModel()
        model.document = NotesDocument(text: "## Mine\n- a line")   // not blank: the editor, not the empty state
        let library = NotesLibraryModel()
        let host = NSHostingView(rootView: NotesView(model: model, library: library))
        host.frame = NSRect(x: 0, y: 0, width: 1100, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        func settle() async {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(150))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        await settle()
        #expect(model.onPendingChanges != nil)
        let other = NotesModel()
        other.document = NotesDocument(text: "## Other\n- a note")
        library.browsed = other
        await settle()
        #expect(model.onPendingChanges == nil && other.onPendingChanges != nil)   // the browsed note's editor
        library.browsed = nil
        await settle()
        func editors(_ v: NSView) -> [NotesTextView] { (v as? NotesTextView).map { [$0] } ?? v.subviews.flatMap(editors) }
        #expect(editors(window.contentView!).count == 1)
        #expect(model.onPendingChanges != nil)
        var d = model.document
        d.userEdit(NSRange(location: 0, length: 0), "typed")
        model.document = d
        await settle()
        #expect(editors(window.contentView!).first?.string.hasPrefix("typed") == true)
    }

    /// New Note on the empty state: the art gives way to the blank note's editor, and that editor (created after the
    /// request) becomes the window's first responder, so typing goes straight into the note.
    @Test func newNoteOnTheEmptyStateFocusesTheEditorThatReplacesTheArt() async throws {
        let model = NotesModel()
        let library = NotesLibraryModel()
        let host = NSHostingView(rootView: NotesView(model: model, library: library))
        host.frame = NSRect(x: 0, y: 0, width: 1100, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        func settle() async {
            window.contentView?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(150))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        func editors(_ v: NSView) -> [NotesTextView] { (v as? NotesTextView).map { [$0] } ?? v.subviews.flatMap(editors) }
        await settle()
        #expect(library.isEmpty && model.showsEmptyState && editors(window.contentView!).isEmpty)
        // What NotesSession.newNote() does to the recorder's model.
        model.composing = true
        model.focusOnAppear = true
        model.focusRequest += 1
        await settle()
        let editor = try #require(editors(window.contentView!).first)
        #expect(window.firstResponder === editor)
        #expect(!model.focusOnAppear)
    }
}
