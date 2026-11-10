import AppKit
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// The Notes window keeps its full-size title bar over the sidebar (the sidebar colour runs under the traffic lights),
/// but the library list must never draw there: scrolled rows used to show through behind the traffic lights and the
/// toolbar buttons, and under Recently Deleted.
@MainActor
@Suite struct NotesSidebarChromeTests {
    private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    @Test(arguments: [CGSize(width: 1000, height: 620), NotesViewMetrics.minimumSize])
    func scrolledRowsStayBelowTheTitleBarAndSearchField(size: CGSize) throws {
        let window = try #require(Snapshots.notes("chrome", size: size) { _, _ in }.window?())
        defer { window.contentViewController = nil; window.toolbar = nil; window.close() }
        let frame = try #require(window.contentView?.superview)
        for _ in 0..<4 { window.layoutIfNeeded(); frame.layoutSubtreeIfNeeded() }
        let list = try #require(views(NSScrollView.self, in: frame).first { $0.documentView is NSTableView })
        let height = frame.bounds.height

        // Scroll so rows sit where the title bar and the search field are.
        list.contentView.scroll(to: NSPoint(x: 0, y: 150 - list.contentInsets.top))
        list.reflectScrolledClipView(list.contentView)
        for _ in 0..<2 { window.layoutIfNeeded(); frame.layoutSubtreeIfNeeded() }

        // What of the list can draw, in window coordinates (bottom-up): every clipping ancestor counts.
        let shown = list.convert(list.visibleRect, to: nil)
        #expect(shown.height > 200, "the list still shows rows: \(shown)")
        // Below the title bar's content inset (the toolbar row and the sidebar's search field), however tall it lays out.
        #expect(shown.maxY <= height - list.contentInsets.top + 0.5, "list reaches under the title bar: \(shown)")
        #expect(shown.maxY <= window.contentLayoutRect.maxY + 0.5)
        let search = try #require(views(NSSearchField.self, in: frame).first)
        #expect(shown.maxY <= search.convert(search.bounds, to: nil).minY + 0.5, "list reaches under the search field: \(shown)")
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let b = try #require(window.standardWindowButton(button))
            #expect(!shown.intersects(b.convert(b.bounds, to: nil)), "list under the traffic lights: \(shown)")
        }
        // And above Recently Deleted.
        #expect(shown.minY >= list.contentInsets.bottom - 0.5, "list reaches under Recently Deleted: \(shown)")

        // The rows themselves: none draws any part of itself above the list's visible top.
        let rows = views(NSTableRowView.self, in: list)
        #expect(!rows.isEmpty)
        for row in rows where !row.visibleRect.isEmpty {
            #expect(row.convert(row.visibleRect, to: nil).maxY <= shown.maxY + 0.5)
        }
    }
}
