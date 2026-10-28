import AppKit
import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// The Settings window is a fixed 720 × 520 (its minimum and maximum size are the same): every page must fit its width with
/// the longest values a user can bring (device and file names, folders, bundle IDs, errors) and scroll vertically.
@MainActor @Suite struct SettingsWindowSizeTests {
    /// The long values of the #332 review renders (`Snapshots.longValueSettings`).
    static func longForm() -> SettingsForm {
        let form = SettingsForm(Snapshots.longValueSettings)
        Snapshots.fillLongValues(form)
        return form
    }

    /// Lays `shell` out at the window's one size and checks `page`: as wide as the scroll view (no sideways scrolling), every
    /// visible view inside it, and every label that truncates readable in full from its tooltip.
    func expectFits(_ name: String, _ shell: SettingsShell, _ page: NSView) {
        shell.frame = NSRect(origin: .zero, size: SettingsShell.size)
        shell.layoutSubtreeIfNeeded()
        #expect(page.frame.width == page.enclosingScrollView?.contentView.bounds.width, "\(name): \(page.frame)")
        func walk(_ view: NSView) {
            for sub in view.subviews where !sub.isHidden {
                // A label's frame reaches 2 pt past its text on each side.
                let r = sub.convert(sub.bounds, to: page).insetBy(dx: sub is NSTextField ? 2.5 : 0.5, dy: 0)
                if sub.isDescendant(of: page), sub.bounds.width > 5 {
                    #expect(r.minX >= 0 && r.maxX <= page.bounds.width, "\(name): \(type(of: sub)) at \(r) leaves the page")
                }
                if let label = sub as? NSTextField, !label.isEditable, label.cell?.wraps != true, !label.stringValue.isEmpty,
                   let width = label.cell?.cellSize.width, width > label.bounds.width + 1 {
                    #expect(label.toolTip == label.stringValue, "\(name): “\(label.stringValue)” is cut short with no tooltip")
                }
                walk(sub)
            }
        }
        walk(shell)
    }

    @Test func everyPageFitsTheFixedWindowWithLongValues() {
        for tab in SettingsTab.allCases {
            let form = Self.longForm()
            expectFits(tab.title, SettingsShell(form: form, selected: tab, flat: true), form.view(for: tab))
        }
    }

    @Test func savedVoicesFitsTheFixedWindowWithALongName() throws {
        let form = Self.longForm()
        form.voicesView.showsTitle = false
        form.voicesView.fitSettingsPage()
        form.voicesView.apply(Snapshots.longValueSettings.voices, locale: Locale(identifier: "en_US"), timeZone: TimeZone(secondsFromGMT: 0)!)
        let shell = SettingsShell(form: form, selected: .notes, flat: true)
        shell.showDetail(content: form.voicesView, title: "Saved voices", back: SettingsTab.notes.title)
        expectFits("Saved voices", shell, try #require(shell.allDescendants(of: NSScrollView.self).first?.documentView))
    }

    @Test func longPagesScrollInsideTheWindow() throws {
        let form = Self.longForm()
        let shell = SettingsShell(form: form, selected: .notes, flat: true)
        shell.frame = NSRect(origin: .zero, size: SettingsShell.size)
        shell.layoutSubtreeIfNeeded()
        let page = form.view(for: .notes)
        let scroll = try #require(page.enclosingScrollView)
        #expect(scroll.hasVerticalScroller && !scroll.hasHorizontalScroller)
        // The scroll view runs to the window's bottom edge and the page is taller than it.
        #expect(scroll.convert(scroll.bounds, to: shell).maxY == SettingsShell.size.height)
        #expect(page.frame.height > scroll.contentView.bounds.height)
    }

    @Test func cutShortValuesShowInFullAsATooltip() {
        let form = Self.longForm()
        let labels = SettingsTab.allCases.flatMap { form.view(for: $0).allDescendants(of: NSTextField.self) }
        for text in ["A really long custom start sound file name that goes on.m4a · 1.20 s",
                     "A really long custom stop sound file name that goes on and on.m4a · 0.20 s",
                     "/Volumes/Shared Drive/Work/Meetings/2026/Quarterly planning notes and minutes for the whole team",
                     "Maximiliana’s Samsung Galaxy Z Fold 7 Enterprise Edition (work profile)"] {
            #expect(labels.first { $0.stringValue == text }?.toolTip == text, "\(text)")
        }
        // No file chosen: nothing to reveal.
        form.setCustomSounds(start: nil, stop: nil)
        #expect(labels.first { $0.stringValue == "None (uses Chirp)" }?.toolTip == nil)
    }
}
