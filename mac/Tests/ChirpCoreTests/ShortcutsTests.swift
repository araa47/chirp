import AppKit
import Carbon.HIToolbox
import Testing
@testable import ChirpCore
@testable import ChirpUI

@Suite struct ChirpShortcutTests {
    private func combo(_ key: Int, _ modifiers: Int) throws -> KeyCombo {
        try HotKeyValidation.validate(keyCode: UInt32(key), modifiers: UInt32(modifiers)).get()
    }

    @Test func theDefaultsAreValidDistinctCarbonHotKeys() throws {
        let defaults = ChirpShortcut.allCases.map(\.defaultCombo)
        #expect(defaults.map(\.title) == ["Right ⌥ Option", "⌃⌥N", "⌃⌥⇧N", "⌃⌥Z", "⌃⌥V", "⌃⌥H"])
        for (i, d) in defaults.enumerated() {
            // Only dictation's Right ⌥ needs Accessibility (the event tap); the others are Carbon hot keys.
            #expect(d.needsEventTap == (ChirpShortcut.allCases[i] == .dictation), "\(d.title)")
            #expect(try combo(Int(d.keyCode), Int(d.modifiers)).sameKeys(d))
            #expect(defaults.enumerated().allSatisfy { $0.offset == i || !$0.element.sameKeys(d) })
            #expect(ChirpShortcut.allCases[i].conflict(d) { $0.defaultCombo } == nil)
        }
    }

    @Test(arguments: ChirpShortcut.allCases)
    func eachRefusesEveryOtherShortcutByNameButNotItsOwnKeys(shortcut: ChirpShortcut) {
        for other in ChirpShortcut.allCases where other != shortcut {
            #expect(shortcut.conflict(other.defaultCombo) { $0.defaultCombo } == .inUse(other.owner))
        }
        #expect(shortcut.conflict(shortcut.defaultCombo) { $0.defaultCombo } == nil)
        #expect(shortcut.taken { $0.defaultCombo }.count == ChirpShortcut.allCases.count - 1)
    }

    @Test func aRecordedShortcutIsComparedByKeysWithTheCurrentOnes() throws {
        // Start/Stop Notes moved to ⌃⌥⌘N: ⌃⌥N is free again, and ⌃⌥⌘N is now refused for the others.
        let moved = try combo(kVK_ANSI_N, controlKey | optionKey | cmdKey)
        let current: (ChirpShortcut) -> KeyCombo = { $0 == .notes ? moved : $0.defaultCombo }
        #expect(ChirpShortcut.openNotes.conflict(.controlOptionN, current: current) == nil)
        #expect(ChirpShortcut.openNotes.conflict(moved, current: current) == .inUse("Start/Stop Notes"))
        #expect(ChirpShortcut.dictation.conflict(moved, current: current) == .inUse("Start/Stop Notes"))
        // ⌃⌥Z recorded by hand is the same keys as the Use raw default.
        let z = try combo(kVK_ANSI_Z, controlKey | optionKey)
        #expect(ChirpShortcut.notes.conflict(z) { $0.defaultCombo } == .inUse("Use raw") && z.sameKeys(.controlOptionZ))
    }

    @Test func preferencesKeepEachShortcutAndFallBack() throws {
        let suite = "chirp-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        for s in ChirpShortcut.allCases { #expect(prefs[shortcut: s].sameKeys(s.defaultCombo), "\(s)") }
        let m = try combo(kVK_ANSI_M, controlKey | optionKey), u = try combo(kVK_ANSI_U, controlKey | optionKey | cmdKey)
        prefs[shortcut: .notes] = m
        prefs.useRawHotkey = u
        let again = Preferences(defaults: defaults)
        #expect(again.notesHotkey == m && again[shortcut: .useRaw] == u && again.openNotesHotkey == .controlOptionShiftN)
        defaults.set("custom:\(kVK_ANSI_N):0", forKey: "notesHotkey")   // a key that cannot fire
        defaults.set("bogus", forKey: "useRawHotkey")
        #expect(prefs.notesHotkey == .controlOptionN && prefs.useRawHotkey.sameKeys(.controlOptionZ))
    }

    @MainActor @Test func useRawRegistersTheConfiguredKeysUnlessTheyAreTheDictationHotkey() throws {
        let u = try combo(kVK_ANSI_U, controlKey | optionKey | cmdKey)
        var registered: [KeyCombo] = []
        let offer = RawOffer(sleep: { _ in }, hotkey: { u }, register: { combo, _ in registered.append(combo); return true },
                             unregister: {}, use: {})
        offer.open(avoiding: .defaultDictation)
        #expect(registered == [u] && offer.hotkeyActive)
        offer.close()
        // The dictation hotkey has the same keys (stored as a recorded shortcut): the menu is the only way.
        offer.open(avoiding: .custom(keyCode: u.keyCode, modifiers: u.modifiers))
        #expect(registered == [u] && !offer.hotkeyActive && offer.isOpen)
    }

    @Test func notesWordingNamesTheCurrentShortcut() {
        #expect(NotesStatus.empty() == "Press Record or ⌃⌥N to start taking notes.")
        #expect(NotesStatus.empty(key: "⌃⌥⌘M").contains("⌃⌥⌘M") && NotesStatus.placeholder(key: "⌃⌥⌘M").contains("(⌃⌥⌘M)"))
    }
}

@MainActor
@Suite struct ShortcutsTabTests {
    @Test func theDictationPageHoldsEveryShortcutAndOtherPagesNone() {
        let form = SettingsForm(SettingsState())
        func contains(_ tab: SettingsTab, _ view: NSView) -> Bool { view.isDescendant(of: form.view(for: tab)) }
        for view in [form.hotkey, form.recorder, form.notesShortcut.view, form.openNotes.view, form.useRawShortcut.view,
                     form.pasteLastShortcut.view, form.openHistoryShortcut.view] {
            #expect(contains(.dictation, view))
            #expect(!contains(.general, view) && !contains(.notes, view) && !contains(.cleanup, view))
        }
        #expect(contains(.general, form.alwaysInDock))
        #expect(SettingsTab.allCases.firstIndex(of: .dictation) == 1 && SettingsTab.dictation.title == "Dictation")
        #expect(ChirpShortcut.allCases.compactMap { form.controls(for: $0)?.shortcut } == [.notes, .openNotes, .useRaw, .pasteLast, .openHistory])
    }

    @Test func eachRowShowsItsKeysWithResetOnlyAwayFromTheDefault() throws {
        var s = SettingsState()
        let form = SettingsForm(s)
        for c in [form.notesShortcut, form.openNotes, form.useRawShortcut] {
            #expect(c.shownTitle == c.shortcut.defaultCombo.title && !c.reset.isEnabled, "\(c.shortcut)")
            #expect(!c.helpText.isEmpty)
        }
        s.notesHotkey = try HotKeyValidation.validate(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(controlKey | optionKey)).get()
        s.useRawHotkey = .custom(keyCode: UInt32(kVK_ANSI_Z), modifiers: UInt32(controlKey | optionKey))   // the default's keys
        form.apply(s, full: true)
        #expect(form.notesShortcut.shownTitle == "⌃⌥M" && form.notesShortcut.reset.isEnabled)
        #expect(!form.useRawShortcut.reset.isEnabled)
        // Clean-up's Undo help names the Use raw keys.
        s.useRawHotkey = .custom(keyCode: UInt32(kVK_ANSI_U), modifiers: UInt32(controlKey | optionKey | cmdKey))
        form.apply(s, full: true)
        let undo = try #require(form.view(for: .cleanup).allDescendants(of: SettingsRow.self).first { $0.allDescendants(of: NSButton.self).contains(form.offerRaw) }?
            .allDescendants(of: NSTextField.self).last)
        #expect(undo.stringValue.contains("⌃⌥⌘U"))
    }

    @Test(arguments: [ChirpShortcut.notes, .openNotes, .useRaw, .pasteLast, .openHistory])
    func theRecorderRefusesAnotherShortcutsKeysAndKeepsListening(shortcut: ChirpShortcut) throws {
        let form = SettingsForm(SettingsState())
        let c = try #require(form.controls(for: shortcut))
        var captured: KeyCombo?
        c.recorder.conflict = { shortcut.conflict($0) { $0.defaultCombo } }
        c.recorder.onCapture = { captured = $0 }
        c.recorder.start()
        c.recorder.apply(.accepted(.defaultDictation))
        #expect(c.recorder.status == .rejected(.inUse("dictation")) && c.recorder.isRecording && captured == nil)
        #expect(c.helpText == HotKeyValidation.Rejection.inUse("dictation").reason)
        let free = try HotKeyValidation.validate(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(controlKey | optionKey)).get()
        c.recorder.apply(.accepted(free))
        #expect(captured == free && !c.recorder.isRecording)
        c.refuse(.inUse("Open Notes"))
        #expect(c.helpText.contains("Open Notes"))
    }

    @Test func aDictationPresetAnotherShortcutHasIsDisabled() {
        var s = SettingsState()
        s.notesHotkey = .controlShiftSpace
        let form = SettingsForm(s)
        let item = form.hotkey.itemArray.first { $0.title == KeyCombo.controlShiftSpace.title }
        #expect(item?.isEnabled == false && item?.toolTip == HotKeyValidation.Rejection.inUse("Start/Stop Notes").reason)
        #expect(form.hotkey.itemArray.filter { !$0.isEnabled }.count == 1 && form.hotkey.selectedItem?.isEnabled == true)
    }
}
