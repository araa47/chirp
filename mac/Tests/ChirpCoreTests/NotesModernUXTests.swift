import AppKit
import SwiftUI
import Testing
@testable import ChirpCore
@testable import ChirpUI

@MainActor @Suite(.serialized) struct NotesModernUXTests {
    private func settle(_ window: NSWindow) {
        for _ in 0..<4 { window.layoutIfNeeded(); window.contentView?.superview?.layoutSubtreeIfNeeded() }
    }
    private func editors(_ view: NSView) -> [NotesTextView] {
        (view as? NotesTextView).map { [$0] } ?? view.subviews.flatMap(editors)
    }
    private func accessibilityTree(_ root: NSObject) -> [NSObject] {
        var visited = Set<ObjectIdentifier>()
        func walk(_ node: NSObject) -> [NSObject] {
            guard visited.insert(ObjectIdentifier(node)).inserted else { return [] }
            let children = node.responds(to: NSSelectorFromString("accessibilityChildren"))
                ? node.value(forKey: "accessibilityChildren") as? [Any] ?? [] : []
            return [node] + NSAccessibility.unignoredChildren(from: children).compactMap { $0 as? NSObject }.flatMap(walk)
        }
        return walk(root)
    }
    private func close(_ window: NSWindow) { window.contentViewController = nil; window.toolbar = nil; window.close() }

    @Test func textSizeChangesPreserveDocumentSelectionAndUndo() throws {
        let h = NotesEditorTests.Harness(typed: "## 日本語 👋\n- [ ] Tell **Maya**\nKeep this caret")
        let view = h.editor.textView
        let index = (h.text as NSString).range(of: "caret").location
        view.setSelectedRange(NSRange(location: index, length: 5))
        h.type("selection")
        let text = h.text
        let selection = NSRange(location: (text as NSString).range(of: "selection").location + 2, length: 3)
        view.setSelectedRange(selection)
        let beforeFont = try #require(view.textStorage?.attribute(.font, at: selection.location, effectiveRange: nil) as? NSFont)
        for _ in 0..<8 { h.model.perform(.biggerText); h.editor.update() }
        #expect(h.model.textSize.factor == 2)
        #expect(view.string == text && h.model.document.text == text)
        #expect(view.selectedRange() == selection)
        #expect(view.accessibilityValue() == text)
        #expect(view.accessibilitySelectedTextRange() == selection)
        let afterFont = try #require(view.textStorage?.attribute(.font, at: selection.location, effectiveRange: nil) as? NSFont)
        #expect(abs(afterFont.pointSize - beforeFont.pointSize * 2) < 0.1)
        #expect(h.editor.undo.canUndo)
        h.editor.undo.undo()
        #expect(h.text.contains("Keep this caret") && h.text == h.model.document.text)
        h.editor.undo.redo()
        #expect(h.text == text)
        h.model.perform(.actualSize); h.editor.update()
        #expect(h.model.textSize.factor == 1 && view.string == text)
        #expect(NotesModel().textSize.factor == 1)
    }

    @Test func standardAXTaskActionEditsSameDocumentAndUndoes() throws {
        let h = NotesEditorTests.Harness(typed: "## 日本語 👋\n- [ ] Tell **Maya**\n- [x] Book room")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = h.editor.scrollView
        defer { close(window) }
        h.editor.scrollView.frame = window.contentLayoutRect
        h.editor.textView.setFrameSize(NSSize(width: 600, height: 600))
        h.editor.textView.textLayoutManager?.ensureLayout(for: h.editor.textView.textLayoutManager!.documentRange)
        let view = h.editor.textView
        let selected = NSRange(location: (h.text as NSString).range(of: "room").location, length: 4)
        view.setSelectedRange(selected)
        let tasks = accessibilityTree(window).compactMap { $0 as? NotesTaskAccessibilityElement }
        #expect(view.accessibilityLabel() == "Notes editor")
        #expect(tasks.count == 2)
        let task = try #require(tasks.first)
        #expect(task.accessibilityRole() == .checkBox)
        #expect(task.isAccessibilityElement())
        #expect(task.accessibilityLabel() == "Tell Maya")
        #expect((task.accessibilityValue() as? NSNumber)?.boolValue == false)
        #expect(task.accessibilityFrame().width > 0)
        #expect(task.isAccessibilitySelectorAllowed(#selector(NotesTaskAccessibilityElement.accessibilityPerformPress)))
        let before = h.text
        #expect(task.accessibilityPerformPress())
        #expect(h.text == h.model.document.text && h.text.contains("- [x] Tell **Maya**"))
        #expect(view.selectedRange() == selected)
        #expect(h.reported.last?.2 == .toggleTask)
        #expect((task.accessibilityValue() as? NSNumber)?.boolValue == true)
        h.editor.undo.undo()
        #expect(h.text == before && view.accessibilityValue() == before)
        print("AX Notes editor: role=\(String(describing: view.accessibilityRole())) native UTF16=\(before.utf16.count) selection=\(view.accessibilitySelectedTextRange()); task role=\(String(describing: task.accessibilityRole())) label=\(task.accessibilityLabel() ?? "") AXPress=true document toggle=true undo=true frame=\(task.accessibilityFrame())")
        let oldID = h.model.document.id
        var other = NotesDocument()
        other.userEdit(NSRange(location: 0, length: 0), before)
        h.model.document = other
        h.editor.update()
        #expect(h.model.document.id != oldID && h.text == before)
        #expect(!task.accessibilityPerformPress(), "A stale node must refuse another document even with identical text")
        let fresh = try #require(accessibilityTree(window).compactMap { $0 as? NotesTaskAccessibilityElement }.first)
        #expect(fresh.accessibilityPerformPress())
        h.editor.undo.undo()
        h.type("prefix\n", at: 0)
        #expect(!fresh.accessibilityPerformPress(), "An old accessibility node cannot toggle another line after offsets move")
    }

    /// The formatted reader shows the note without syntax, and its checkboxes edit the same document through the
    /// editor's own toggle: one ⌘Z in the editor puts the box back.
    @Test func formattedReaderTogglesTasksThroughTheEditorWithUndo() throws {
        let typed = "## Plan 👋\n- Budget **check-in**\n  - [ ] Tell **Maya**\n- [x] Book room\nPlain line"
        let h = NotesEditorTests.Harness(typed: typed)
        let lines = NotesFormattedReader.lines(h.text)
        #expect(lines.count == 5)
        #expect(lines[0] == .heading("Plan 👋"))
        #expect(lines[1] == .bullet("Budget **check-in**", indent: 0))
        #expect(lines[4] == .text("Plain line"))
        guard case .task("Tell **Maya**", false, 1, let toggle) = lines[2], case .task("Book room", true, 0, _) = lines[3] else {
            Issue.record("tasks: \(lines)"); return
        }
        let caret = NSRange(location: 3, length: 0)
        h.editor.textView.setSelectedRange(caret)
        #expect(h.model.toggleAccessibleTask(toggle))
        #expect(h.text == h.model.document.text && h.text.contains("  - [x] Tell **Maya**") && h.text.contains("- [x] Book room"))
        #expect(NotesFormattedReader.lines(h.text)[2] == .task("Tell **Maya**", checked: true, indent: 1, toggle: toggle))
        h.editor.undo.undo()
        #expect(h.text == typed)
        h.editor.detach()
        #expect(!h.model.toggleAccessibleTask(toggle), "No editor, no edit")
        let library = NotesLibraryModel()
        library.selection = .recentlyDeleted
        #expect(NotesCommand.items(for: h.model, library: library, windowIsKey: true).first { $0.command == .readFormattedNote }?.enabled == false)
    }

    @Test func deletingNowRequiresAnExplicitConfirmationAndCancelPreservesAudio() {
        let library = NotesLibraryModel()
        let id = UUID()
        let entry = NotesLibraryEntry(id: id, title: "Kept interview", createdAt: Date(), updatedAt: Date(), deletedAt: Date(), audioBytes: 1024)
        library.deleted = [entry]
        var purged: [UUID] = []
        library.onPurge = { id in purged.append(id); library.deleted.removeAll { $0.id == id } }
        library.requestPurge(id)
        #expect(library.confirmingPurge?.id == id && purged.isEmpty)
        library.resolvePurge(confirm: false)
        #expect(library.deleted.first?.id == id && library.deleted.first?.audioBytes == 1024 && purged.isEmpty)
        library.requestPurge(id)
        library.resolvePurge(confirm: true)
        #expect(purged == [id] && library.deleted.isEmpty && library.confirmingPurge == nil)
        library.resolvePurge(confirm: true)
        #expect(purged == [id])
    }

    /// The alert's Delete Permanently purges the presented note whether SwiftUI resets `isPresented` (dropping the
    /// request) before or after the button's action, and never a note that is no longer in Recently Deleted.
    @Test func deletePermanentlyPurgesThePresentedNoteWhicheverWayTheAlertCloses() throws {
        let library = NotesLibraryModel()
        let first = NotesLibraryEntry(id: UUID(), title: "One", createdAt: Date(), updatedAt: Date(), deletedAt: Date(), audioBytes: 1)
        let second = NotesLibraryEntry(id: UUID(), title: "Two", createdAt: Date(), updatedAt: Date(), deletedAt: Date(), audioBytes: 1)
        library.deleted = [first, second]
        var purged: [UUID] = []
        library.onPurge = { id in purged.append(id); library.deleted.removeAll { $0.id == id } }
        // Binding reset first: the request is gone when the action runs.
        library.requestPurge(first.id)
        let presented = try #require(library.confirmingPurge)
        library.resolvePurge(confirm: false)
        NotesView.purgeConfirmed(presented, in: library)
        #expect(purged == [first.id] && library.confirmingPurge == nil)
        // Action first, then the binding reset: one purge, and the reset is harmless.
        library.requestPurge(second.id)
        NotesView.purgeConfirmed(try #require(library.confirmingPurge), in: library)
        library.resolvePurge(confirm: false)
        #expect(purged == [first.id, second.id] && library.deleted.isEmpty && library.confirmingPurge == nil)
        // A stale presentation purges nothing.
        NotesView.purgeConfirmed(first, in: library)
        #expect(purged == [first.id, second.id])
    }

    /// Review evidence, not a check: `CHIRP_MODERN_UX_RENDER=<dir> mac/scripts/test.sh --filter renderOwnedReviewMatrix`.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CHIRP_MODERN_UX_RENDER"] != nil))
    func renderOwnedReviewMatrix() throws {
        let output = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["CHIRP_MODERN_UX_RENDER"]))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let canonical = ["notes-recording", "notes-library", "notes-paused", "notes-empty", "notes-no-results", "notes-deleted", "hud-listening", "history-detail"]
        let only = ProcessInfo.processInfo.environment["CHIRP_MODERN_UX_ONLY"]
        let scenes = Snapshots.allScenarios.filter { canonical.contains($0.name) } + Snapshots.modernUXScenarios
        for scene in scenes where only.map({ scene.name.contains($0) }) ?? true {
            for appearance in Snapshots.appearances {
                let png = try #require(Snapshots.png(scene, appearance: appearance.appearance), "Failed to render \(scene.name)")
                try png.write(to: output.appendingPathComponent("\(scene.name)-\(appearance.name).png"))
            }
        }
    }

    /// Renders real metadata text through SwiftUI on the surfaces it sits on and measures the drawn pixels: the
    /// muted ink and the selected row's ink, in both appearances. A full block in the string
    /// gives a solid run of ink, so anti-aliasing cannot flatter or understate the colour.
    @Test func metadataInkMeasuresAtLeastFourAndAHalfToOneWhereItIsDrawn() throws {
        func luminance(_ c: NSColor) -> Double {
            func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
        }
        func measured(_ ink: Color, on background: Color, _ appearance: NSAppearance.Name) throws -> Double {
            let view = NSHostingView(rootView: Text("Yesterday · 12 min █").pondFont(.meta).foregroundStyle(ink)
                .padding(12).background(background).environment(\.chirpTextScale, 1))
            view.appearance = NSAppearance(named: appearance)
            view.frame = NSRect(origin: .zero, size: view.fittingSize)
            view.layoutSubtreeIfNeeded()
            let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: rep)
            let srgb = { (x: Int, y: Int) in rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)! }
            let bg = luminance(srgb(1, 1))
            var best = 1.0
            for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
                let l = luminance(srgb(x, y))
                best = max(best, (max(l, bg) + 0.05) / (min(l, bg) + 0.05))
            } }
            return best
        }
        let raised = Color.chirp.surfaceRaised, page = Color.chirp.surface, pill = Color.chirp.koiContainer
        let cases: [(String, Color, Color, NSAppearance.Name)] = [
            ("meta on the editor, light", NotesInk.secondary, page, .aqua),
            ("meta on the editor, dark", NotesInk.secondary, page, .darkAqua),
            ("meta on the sidebar, light", RowInk(selected: false, scheme: .light).meta, raised, .aqua),
            ("meta on the sidebar, dark", RowInk(selected: false, scheme: .dark).meta, raised, .darkAqua),
            ("meta on the selected row, light", RowInk(selected: true, scheme: .light).meta, pill, .aqua),
            ("meta on the selected row, dark", RowInk(selected: true, scheme: .dark).meta, pill, .darkAqua),
            ("snippet on the selected row, dark", RowInk(selected: true, scheme: .dark).snippet, pill, .darkAqua),
        ]
        var report: [String] = []
        for (name, ink, background, appearance) in cases {
            let ratio = try measured(ink, on: background, appearance)
            report.append("\(name) \(String(format: "%.2f", ratio)):1")
            #expect(ratio >= 4.5, "\(name): \(ratio)")
        }
        // AppKit cannot build the high-contrast appearances offscreen (they resolve to plain Aqua), and the host's
        // accessibility settings are not ours to flip, so Increase Contrast is checked on the colour it selects.
        for dark in [false, true] {
            let boosted = NotesInk.mutedInk(dark: dark, increaseContrast: true)
            let surface = dark ? ChirpColor.Pond.surfaceRaised.dark : ChirpColor.Pond.surfaceRaised.light
            func l(_ c: ChirpColor.RGB) -> Double { luminance(NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)) }
            let ratio = (max(l(boosted), l(surface)) + 0.05) / (min(l(boosted), l(surface)) + 0.05)
            #expect(ratio >= 7, "Increase Contrast \(dark ? "dark" : "light"): \(ratio)")
            report.append("Increase Contrast \(dark ? "dark" : "light") (colour) \(String(format: "%.2f", ratio)):1")
        }
        print("UX contrast " + report.joined(separator: "; "))
    }

    /// The minimum window cannot fit sidebar + note + transcript column (the baseline measured a 159 pt line of text),
    /// so narrow windows put the same transcript under the note. Each window opens at its size, as the app's does.
    @Test func transcriptKeepsUsefulNoteMeasureAcrossWindowSizes() throws {
        for (width, large) in [(760.0, false), (900, false), (1120, false), (760, true), (1120, true)] {
            let model = NotesModel()
            model.document = Snapshots.demoNotes()
            let library = NotesLibraryModel()
            library.selection = .note(model.document.id)
            library.showsInspector = true
            if large { (0..<5).forEach { _ in library.textSize.increase() } }
            let window = Snapshots.notesWindow(model, library, size: CGSize(width: width, height: 460))
            defer { close(window) }
            settle(window)
            let editor = try #require(window.contentView.flatMap { editors($0).first })
            let measure = editor.frame.width - 2 * editor.textContainerInset.width
            let compact = NotesViewMetrics.compactTranscript(windowWidth: width)
            #expect(library.transcriptBelow == compact)
            #expect(measure >= 320, "Window \(width): text measure \(measure)")
            #expect(editor.visibleRect.height >= 120, "Window \(width): the note keeps room to write")
            if compact {
                #expect(library.compactTranscriptSize.width >= measure && library.compactTranscriptSize.height >= 160,
                        "Window \(width): the transcript is shown under the note")
            } else {
                // The transcript column takes at least its minimum width beside the sidebar and the note.
                #expect(editor.frame.width <= width - NotesViewMetrics.sidebar.min - NotesViewMetrics.inspector.min,
                        "Window \(width): the transcript column is shown (editor \(editor.frame.width))")
            }
            print("UX geometry window=\(width) text=\(Int(library.textSize.factor * 100))% editor=\(editor.frame.width) measure=\(measure) visible=\(editor.visibleRect.height) transcript=\(compact ? "below \(library.compactTranscriptSize)" : "column")")
        }
    }

    /// Resizing moves the transcript between the column and the panel under the note and never forgets the user's
    /// choice. (An offscreen window never finishes the inspector column's own show/hide transition, on the base commit
    /// too, so this checks the presentation state and the panel; the column geometry is checked above.)
    @Test func resizingMovesTheTranscriptAndKeepsThePreference() throws {
        let model = NotesModel()
        model.document = Snapshots.demoNotes()
        let library = NotesLibraryModel()
        library.selection = .note(model.document.id)
        library.showsInspector = true
        let window = Snapshots.notesWindow(model, library, size: NotesViewMetrics.defaultSize)
        defer { close(window) }
        for width in [1120.0, 760, 1120, 900] {
            library.compactTranscriptSize = .zero
            window.setContentSize(CGSize(width: width, height: 460))
            settle(window)
            let compact = NotesViewMetrics.compactTranscript(windowWidth: width)
            #expect(library.transcriptBelow == compact, "Window \(width)")
            #expect(library.showsInspector, "Window \(width): resizing keeps the user's choice")
            #expect((library.compactTranscriptSize.height > 0) == compact, "Window \(width): panel \(library.compactTranscriptSize)")
        }
        library.setInspector(false)
        settle(window)
        #expect(!library.showsInspector)
    }
}
