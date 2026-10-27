import Foundation
import Carbon.HIToolbox
import Testing
@testable import ChirpCore
@testable import ChirpUI

@Suite struct PreferencesTests {
    private func makeDefaults() -> (UserDefaults, String) {
        let name = "chirp-test-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    @Test func inputDeviceChoicePersistsAndClears() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(Preferences(defaults: defaults).inputDeviceUID == nil)
        Preferences(defaults: defaults).inputDeviceUID = "boya"
        #expect(Preferences(defaults: defaults).inputDeviceUID == "boya")
        Preferences(defaults: defaults).inputDeviceUID = nil
        #expect(Preferences(defaults: defaults).inputDeviceUID == nil)
    }

    @Test func cleanupToggleIsTheWireCorrectionFlag() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.startOptions() == StartOptions(client: "mac", correction: true))
        prefs.correction = false
        #expect(prefs.startOptions() == StartOptions(client: "mac", correction: false))
        prefs.correction = true
        #expect(ClientMessage.start(prefs.startOptions()).contains("\"correction\":true"))
    }

    @Test func rawAfterCleanupDefaultsOnAndPersistsOff() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(Preferences(defaults: defaults).showRawAfterCleanup)
        Preferences(defaults: defaults).showRawAfterCleanup = false
        #expect(!Preferences(defaults: defaults).showRawAfterCleanup)
    }

    @Test func existingPreferencesKeepTheirKeysAndDefaults() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.hotkey == .rightOption && prefs.serverURL == ServerConfig.defaultURL.absoluteString)
        defaults.set("control-shift-space", forKey: "hotkey")
        defaults.set(true, forKey: "correction")
        #expect(prefs.hotkey == .controlShiftSpace && prefs.correction)
    }
}

@Suite struct InputSelectionTests {
    let boya = AudioInput(uid: "boya", name: "BOYA CM40")
    let studio = AudioInput(uid: "studio", name: "Studio Display Microphone")

    @Test func followsTheSystemDefaultUnlessADeviceIsPicked() {
        #expect(InputSelection.resolve(chosen: nil, available: [boya, studio]) == nil)
        #expect(InputSelection.resolve(chosen: "studio", available: [boya, studio]) == studio)
    }

    @Test func aPickedDeviceThatWasUnpluggedFallsBackToTheDefault() {
        #expect(InputSelection.resolve(chosen: "studio", available: [boya]) == nil)
        #expect(InputSelection.resolve(chosen: "studio", available: []) == nil)
    }
}

@Suite struct MenuContentTests {
    private let boya = AudioInput(uid: "boya", name: "BOYA CM40")
    private let studio = AudioInput(uid: "studio", name: "Studio Display Microphone")
    private let local = Health(engine: "parakeet", ready: true, correction: "available", correctionLeavesMachine: false,
                               correctionProfiles: CorrectionProfile.builtIn)

    private func inputs(_ configure: (inout MenuInputs) -> Void = { _ in }) -> MenuInputs {
        var m = MenuInputs()
        m.inputs = [boya, studio]
        m.defaultInput = boya
        m.health = local
        configure(&m)
        return m
    }
    private func entry(_ m: MenuInputs, _ title: String) -> MenuEntry? { MenuContent.entries(m).first { $0.title == title } }
    private func entry(_ m: MenuInputs, _ action: MenuAction) -> MenuEntry? { MenuContent.entries(m).first { $0.action == action } }
    private func titles(_ m: MenuInputs) -> [String] { MenuContent.entries(m).filter { !$0.isSeparator }.map(\.title) }
    /// The rows with their separators, as one string per group.
    private func groups(_ m: MenuInputs) -> [[String]] {
        var out: [[String]] = [[]]
        for e in MenuContent.entries(m) {
            if e.isSeparator { if !out[out.count - 1].isEmpty { out.append([]) } } else { out[out.count - 1].append(e.title) }
        }
        return out
    }

    // MARK: the structure

    @Test func readyMenuHasTheTargetStructure() {
        #expect(groups(inputs()) == [["Start Dictation", "New Note"], ["Recent Dictations", "Dictation History…"], ["Recent Notes", "Notes Library…"], ["Private session", "Clean-up", "Microphone"],
                                      ["Settings…"], ["Quit Chirp"]])
        #expect(MenuContent.header(inputs()).title == "Chirp")
    }

    @Test func rowsAreSingleLineWithoutIconsOrSectionHeaders() {
        // MenuEntry has no subtitle, symbol or header kind any more: a row is a title plus a value or shortcut.
        for e in MenuContent.entries(inputs()) where !e.isSeparator {
            #expect(!e.title.isEmpty && !e.title.contains("\n"))
            #expect(e.value == nil || e.shortcut == nil)
        }
        // Under the header, around the history rows and the notes rows, around Settings and above Quit.
        #expect(MenuContent.entries(inputs()).filter(\.isSeparator).count == 6)
    }

    @Test func setOncePreferencesLiveOnlyInSettings() {
        let all = MenuContent.entries(inputs { $0.cleanupOn = true }).flatMap { [$0] + ($0.submenu ?? []) }
        for title in ["Hotkey", "Launch at Login", "Sounds", "Server", "About Chirp", "Copy Doctor Command"] {
            #expect(!all.contains { $0.title == title }, "\(title)")
        }
    }

    @Test func useRawIsItsOwnGroupUnderTheStartRows() {
        let m = inputs { $0.rawOfferOpen = true; $0.rawOfferKey = "⌃⌥Z" }
        #expect(groups(m) == [["Start Dictation", "New Note"], ["Recent Dictations", "Dictation History…"], ["Recent Notes", "Notes Library…"], ["Use Raw for Last Dictation"],
                              ["Private session", "Clean-up", "Microphone"], ["Settings…"], ["Quit Chirp"]])
    }

    // MARK: header and status

    @Test func headerStatusCoversEveryState() {
        func status(_ configure: (inout MenuInputs) -> Void) -> (String, MenuEntry.Tone) {
            let h = MenuContent.header(inputs(configure))
            return (h.status, h.tone)
        }
        #expect(status { _ in } == ("Ready · Right ⌥ Option", .normal))
        // The same word as the HUD and the Notes window.
        #expect(status { $0.state = .finalizing } == ("Finishing…", .active))
        #expect(status { $0.hotkey = .controlShiftSpace } == ("Ready · ⌃⇧Space", .normal))
        #expect(status { $0.paused = true } == ("Paused", .normal))
        #expect(status { $0.state = .listening } == ("Listening…", .active))
        #expect(status { $0.state = .connecting } == ("Connecting…", .active))
        #expect(status { $0.state = .correcting } == ("Polishing…", .active))
        #expect(status { $0.state = .error("boom") } == ("boom", .error))
        #expect(status { $0.health = nil; $0.healthError = "x" } == ("Server unreachable", .error))
        #expect(status { $0.health = nil } == ("Checking server…", .warning))
        #expect(status { $0.health = Health(ready: false) } == ("Loading model…", .warning))
        #expect(status { $0.debugRetention = true } == ("DEBUG: recordings kept", .error))
        #expect(status { $0.hotkeyRegistered = false }.1 == .warning)
        // What Chirp is doing wins over the server's state; the pause wins over everything.
        #expect(status { $0.state = .listening; $0.health = nil; $0.healthError = "x" } == ("Listening…", .active))
        #expect(status { $0.paused = true; $0.debugRetention = true } == ("Paused", .normal))
    }

    @Test func theSwitchIsOnExactlyWhileRunning() {
        #expect(MenuContent.header(inputs()).isOn)
        #expect(!MenuContent.header(inputs { $0.paused = true }).isOn)
    }

    @Test func headerReadsAsOneLabelForVoiceOver() {
        #expect(MenuContent.header(inputs()).accessibilityLabel == "Chirp, Ready · Right ⌥ Option")
        #expect(MenuContent.header(inputs { $0.paused = true }).accessibilityLabel == "Chirp, Paused")
    }

    // MARK: dictation rows

    @Test func startDictationShowsTheHotkeyAndTurnsIntoStop() {
        let idle = entry(inputs(), .toggleDictation)
        #expect(idle?.title == "Start Dictation" && idle?.shortcut == "Right ⌥ Option" && idle?.keyEquivalent == nil)
        #expect(entry(inputs { $0.hotkey = .controlShiftSpace }, .toggleDictation)?.shortcut == "⌃⇧Space")
        #expect(entry(inputs { $0.state = .listening }, .toggleDictation)?.title == "Stop Dictation")
        #expect(entry(inputs { $0.state = .error("x") }, .toggleDictation)?.title == "Start Dictation")
        // Nothing to start or stop while the final is on its way.
        #expect(entry(inputs { $0.state = .finalizing }, .toggleDictation) == nil)
        #expect(entry(inputs { $0.state = .inserting }, .toggleDictation) == nil)
    }

    @Test func pausedMenuCannotStartADictationAndShowsNoShortcut() throws {
        let row = try #require(entry(inputs { $0.paused = true }, "Start Dictation"))
        #expect(row.action == nil && row.shortcut == nil && !row.isEnabled)
        // A shortcut another app owns is not advertised either.
        #expect(try #require(entry(inputs { $0.hotkeyRegistered = false }, "Start Dictation")).shortcut == nil)
    }

    @Test func useRawAppearsOnlyDuringItsWindowWithItsShortcut() throws {
        #expect(entry(inputs(), .useRaw) == nil)
        let open = try #require(entry(inputs { $0.rawOfferOpen = true; $0.rawOfferKey = "⌃⌥Z" }, .useRaw))
        #expect(open.title == "Use Raw for Last Dictation" && open.shortcut == "⌃⌥Z")
        #expect(try #require(entry(inputs { $0.rawOfferOpen = true }, .useRaw)).shortcut == nil)
        #expect(groups(inputs { $0.rawOfferOpen = true })[3] == ["Use Raw for Last Dictation"])
    }

    // MARK: Clean-up

    @Test func cleanupValueIsTheDefaultStyleOrOff() throws {
        #expect(try #require(entry(inputs(), "Clean-up")).value == "Off")
        #expect(try #require(entry(inputs { $0.cleanupOn = true }, "Clean-up")).value == "Default")
        #expect(try #require(entry(inputs { $0.cleanupOn = true; $0.styleID = "email" }, "Clean-up")).value == "Email")
        // Unreachable: the style's built-in name, still shown.
        #expect(try #require(entry(inputs { $0.health = nil; $0.healthError = "x"; $0.cleanupOn = true; $0.styleID = "chat" }, "Clean-up")).value == "Chat")
    }

    @Test func cleanupSubmenuHasToggleStylesAndTheCleanupSettings() throws {
        let row = try #require(entry(inputs { $0.cleanupOn = true; $0.styleID = "email"; $0.showChanges = true }, "Clean-up"))
        let sub = try #require(row.submenu)
        // "Show Changes after Clean-up" is a set-once choice: it lives in Settings › Clean-up, not here.
        #expect(sub.filter { !$0.isSeparator }.map(\.title) == ["Clean up Text", "Default", "Chat", "Email", "Code", "Notes", "Custom",
                                                                "Clean-up Settings…"])
        #expect(sub.first?.action == .toggleCleanup && sub.first?.mark == .on)
        #expect(sub.filter { $0.mark == .on }.map(\.title) == ["Clean up Text", "Email"])
        #expect(sub.first { $0.title == "Chat" }?.action == .pickStyle("chat"))
        #expect(sub.last?.action == .editStyles)
    }

    @Test func cleanupSubmenuMarksNothingWhenOff() throws {
        let sub = try #require(entry(inputs(), "Clean-up")?.submenu)
        #expect(sub.first?.mark == .off)
        #expect(sub.first { $0.title == "Default" }?.mark == .on)   // the default style is still the one a later toggle uses
    }

    @Test func serverWithoutCleanupExplainsInsteadOfOfferingAToggle() throws {
        for on in [true, false] {
            let m = inputs { $0.health = Health(engine: "p", ready: true, correction: "off"); $0.cleanupOn = on }
            let row = try #require(entry(m, "Clean-up"))
            #expect(row.value == "Unavailable")
            let sub = try #require(row.submenu)
            #expect(sub.first?.title == "Clean-up is off on the server" && sub.first?.action == nil)
            #expect(!sub.contains { $0.action == .toggleCleanup })
            #expect(sub.last?.action == .editStyles)
        }
    }

    @Test func aServerThatListsNoStylesGetsNoStyleRows() throws {
        // An older server ignores styles, so there is nothing to pick; the toggle and Clean-up Settings… remain.
        let sub = try #require(entry(inputs { $0.health = Health(engine: "p", ready: true, correction: "available") }, "Clean-up")?.submenu)
        #expect(sub.filter { !$0.isSeparator }.map(\.title) == ["Clean up Text", "Clean-up Settings…"])
        // Before the first health check the built-in styles are offered, so the menu is not empty while it loads.
        let loading = try #require(entry(inputs { $0.health = nil }, "Clean-up")?.submenu)
        #expect(loading.contains { $0.action == .pickStyle("default") })
    }

    @Test func noMenuItemIsCheckedWhileDisabled() {
        let configs: [(inout MenuInputs) -> Void] = [
            { _ in }, { $0.cleanupOn = true }, { $0.cleanupOn = true; $0.showChanges = true },
            { $0.health = Health(correction: "off"); $0.cleanupOn = true }, { $0.health = nil; $0.cleanupOn = true },
            { $0.chosenInputUID = "studio" }, { $0.paused = true },
        ]
        for configure in configs {
            for top in MenuContent.entries(inputs(configure)) {
                for e in [top] + (top.submenu ?? []) where e.mark != .off {
                    #expect(e.action != nil, "\(e.title) is checked but has no action")
                }
            }
        }
    }

    // MARK: Microphone

    @Test func microphoneSubmenuListsEveryDeviceAndMarksTheEffectiveOne() throws {
        let following = try #require(entry(inputs(), "Microphone"))
        #expect(following.value == "BOYA CM40")
        let sub = try #require(following.submenu).filter { !$0.isSeparator }
        #expect(sub.map(\.title) == ["Follow System Default", "BOYA CM40", "Studio Display Microphone"])
        #expect(sub.map(\.mark) == [.on, .off, .off])
        #expect(sub.map(\.action) == [.pickInput(nil), .pickInput("boya"), .pickInput("studio")])

        let picked = try #require(entry(inputs { $0.chosenInputUID = "studio" }, "Microphone"))
        #expect(picked.value?.hasPrefix("Studio Display") == true && picked.value?.hasSuffix("…") == true)
        #expect(picked.fullValue == "Studio Display Microphone")
        #expect(try #require(picked.submenu).filter { $0.mark == .on }.map(\.title) == ["Studio Display Microphone"])
    }

    @Test func unpluggedPickedDeviceFallsBackToTheDefault() throws {
        let e = try #require(entry(inputs { $0.inputs = [boya]; $0.chosenInputUID = "studio" }, "Microphone"))
        #expect(e.value == "BOYA CM40")
        #expect(try #require(e.submenu).filter { $0.mark == .on }.map(\.title) == ["Follow System Default"])
    }

    @Test func noInputDeviceIsFlaggedAndHasNoPicker() throws {
        let e = try #require(entry(inputs { $0.inputs = []; $0.defaultInput = nil }, "Microphone"))
        #expect(e.value == "None" && e.tone == .warning && e.submenu == nil && !e.isEnabled)
    }

    // MARK: values truncate gracefully

    @Test func longValuesEndInAnEllipsisAndKeepTheirFullTextForVoiceOver() throws {
        let long = AudioInput(uid: "long", name: "Studio Display Microphone (Built-in, Aggregate)")
        let row = try #require(entry(inputs { $0.inputs = [long]; $0.chosenInputUID = "long" }, "Microphone"))
        let value = try #require(row.value)
        #expect(value.count <= MenuContent.valueLimit && value.hasSuffix("…") && value.hasPrefix("Studio Display"))
        #expect(row.fullValue == "Studio Display Microphone (Built-in, Aggregate)")
        #expect(row.accessibilityLabel == "Microphone, Studio Display Microphone (Built-in, Aggregate)")
        // The submenu keeps the whole name.
        #expect(row.submenu?.contains { $0.title == long.name } == true)
    }

    @Test func shortValuesAreUntouchedAndTruncationNeverCutsAGrapheme() {
        #expect(MenuContent.truncated("BOYA CM40") == "BOYA CM40")
        #expect(MenuContent.truncated(String(repeating: "a", count: MenuContent.valueLimit)) == String(repeating: "a", count: MenuContent.valueLimit))
        let emoji = MenuContent.truncated(String(repeating: "🎙️", count: 40))
        #expect(emoji.count == MenuContent.valueLimit && emoji.hasSuffix("…"))
        #expect(MenuContent.truncated("ab ", limit: 3) == "ab ")
        #expect(MenuContent.truncated("ab cdefg", limit: 4) == "ab…")   // no dangling space before the ellipsis
    }

    @Test func rowsKeepOnlyTheirTitleWhenThereIsNoValue() {
        #expect(entry(inputs { $0.micGranted = false }, "Set Up Chirp…")?.accessibilityLabel == "Set Up Chirp…")
        #expect(entry(inputs(), "Settings…")?.accessibilityLabel == "Settings…, ⌘,")
        #expect(entry(inputs(), "Start Dictation")?.accessibilityLabel == "Start Dictation, Right ⌥ Option")
    }

    // MARK: Set Up Chirp…, footer

    @Test func setUpChirpAppearsOnlyWhileSetupIsIncomplete() {
        #expect(entry(inputs(), .showSetup) == nil)
        #expect(entry(inputs { $0.micGranted = false }, .showSetup)?.title == "Set Up Chirp…")
        #expect(entry(inputs { $0.accessibilityGranted = false }, .showSetup) != nil)
        #expect(entry(inputs { $0.health = nil; $0.healthError = "x" }, .showSetup) != nil)
        // Still checking the server is not a reason to nag.
        #expect(entry(inputs { $0.health = nil }, .showSetup) == nil)
        #expect(MenuAction.showSetup.payload == nil)
    }

    @Test func setUpChirpSitsBetweenTheSeparatorAndSettings() {
        let m = inputs { $0.micGranted = false }
        #expect(groups(m)[4] == ["Set Up Chirp…", "Settings…"])
    }

    @Test func footerHasSettingsAndQuitWithTheirKeys() {
        let settings = entry(inputs(), .showSettings)
        #expect(settings?.keyEquivalent == "," && settings?.shortcut == "⌘,")
        #expect(entry(inputs(), .quit)?.keyEquivalent == "q" && entry(inputs(), .quit)?.shortcut == "⌘Q")
        #expect(titles(inputs()).suffix(2) == ["Settings…", "Quit Chirp"])
    }

    @Test func permissionsHaveNoRowsInTheMenu() {
        let m = inputs { $0.micGranted = false; $0.accessibilityGranted = false }
        #expect(!titles(m).contains { $0.contains("Allow") || $0.contains("Permission") })
    }

    // MARK: every state

    @Test func everyStateBuildsACoherentMenu() throws {
        let states: [(String, (inout MenuInputs) -> Void)] = [
            ("paused", { $0.paused = true; $0.hotkeyRegistered = false }),
            ("ready", { _ in }),
            ("listening", { $0.state = .listening }),
            ("unreachable", { $0.health = nil; $0.healthError = "x" }),
            ("debug", { $0.debugRetention = true }),
            ("use-raw", { $0.rawOfferOpen = true; $0.rawOfferKey = "⌃⌥Z" }),
            ("setup", { $0.micGranted = false; $0.accessibilityGranted = false }),
        ]
        for (name, configure) in states {
            let m = inputs(configure)
            let all = MenuContent.entries(m)
            // Every group has rows, none is empty or doubled up.
            #expect(zip(all, all.dropFirst()).allSatisfy { !($0.isSeparator && $1.isSeparator) }, "\(name): doubled separator")
            #expect(all.last?.isSeparator == false, "\(name): trailing separator")
            for e in all where !e.isSeparator { #expect(!e.title.isEmpty && (e.value ?? "").count <= MenuContent.valueLimit, "\(name): \(e.title)") }
            #expect(all.filter { $0.title == "Quit Chirp" }.count == 1)
        }
    }

    // MARK: Live Notes

    @Test func notesRowsSitUnderDictationWithTheirShortcut() throws {
        let new = try #require(entry(inputs(), .newNote))
        #expect(new.title == "New Note" && new.shortcut == "⌃⌥N")
        // The library window is always there, with ⌥⌘L as a real key equivalent; it never starts recording.
        #expect(groups(inputs())[0] == ["Start Dictation", "New Note"] && groups(inputs())[2] == ["Recent Notes", "Notes Library…"])
        let library = try #require(entry(inputs(), "Notes Library…"))
        #expect(library.action == .showNotes && library.shortcut == "⌥⌘L")
        #expect(library.keyEquivalent == "l" && library.keyEquivalentOption)
        #expect(entry(inputs { $0.notesHotkeyRegistered = false }, .newNote)?.shortcut == nil)
        // A recorded New Note shortcut is what the row shows.
        #expect(entry(inputs { $0.notesShortcut = "⌃⌥⌘M" }, .newNote)?.shortcut == "⌃⌥⌘M")
        #expect(entry(inputs { $0.paused = true }, "New Note")?.shortcut == nil)
    }

    @Test func notesAndDictationExcludeEachOther() {
        // Idle: both can start.
        #expect(entry(inputs(), "Start Dictation")?.action == .toggleDictation)
        #expect(entry(inputs(), "New Note")?.action == .newNote)
        // Dictating: Notes cannot start.
        #expect(entry(inputs { $0.state = .listening }, "New Note")?.isEnabled == false)
        #expect(entry(inputs { $0.state = .correcting }, "New Note")?.isEnabled == false)
        // Notes recording: Start Dictation and New Note are disabled and the live row offers Stop.
        let recording = inputs { $0.notesRecording = true; $0.notesElapsed = "01:05" }
        #expect(entry(recording, "Start Dictation")?.isEnabled == false && entry(recording, "New Note")?.isEnabled == false)
        #expect(entry(recording, .toggleNotes)?.title.hasSuffix("— Stop") == true)
        #expect(entry(recording, "Notes Library…") != nil)
        // Finishing: nothing starts until the last pass is done.
        let finishing = inputs { $0.notesFinishing = true }
        #expect(entry(finishing, "New Note")?.isEnabled == false && entry(finishing, "Start Dictation")?.isEnabled == false)
        // Paused: neither starts, and no shortcut is shown.
        let paused = inputs { $0.paused = true; $0.hotkeyRegistered = false; $0.notesHotkeyRegistered = false }
        #expect(entry(paused, "New Note")?.isEnabled == false && entry(paused, "New Note")?.shortcut == nil)
    }

    // MARK: recording row, Recent Notes

    @Test func recordingNoteIsTheFirstRowWithItsTitleAndTimer() throws {
        let m = inputs { $0.notesRecording = true; $0.notesElapsed = "03:12"; $0.notesTitle = "Standup" }
        let first = try #require(MenuContent.entries(m).first { !$0.isSeparator })
        #expect(first.title == "◉ Recording \"Standup\" 03:12 — Stop")
        #expect(first.action == .toggleNotes && first.tone == .active)
        // Not recording: no such row.
        #expect(!MenuContent.entries(inputs()).contains { $0.title.hasPrefix("◉") })
        // A long title is cut so the menu does not stretch; a blank one is named.
        let long = inputs { $0.notesRecording = true; $0.notesTitle = String(repeating: "w", count: 80) }
        #expect(try #require(MenuContent.entries(long).first { !$0.isSeparator }).title.count < 60)
        let blank = inputs { $0.notesRecording = true; $0.notesTitle = "  " }
        #expect(try #require(MenuContent.entries(blank).first { !$0.isSeparator }).title.contains("Untitled note"))
    }

    @Test func pausedAndFinishingNotesLeadTheMenuToo() throws {
        let paused = inputs { $0.notesPaused = true; $0.notesElapsed = "00:40"; $0.notesTitle = "Idea" }
        let row = try #require(MenuContent.entries(paused).first { !$0.isSeparator })
        #expect(row.title == "⏸ Paused \"Idea\" 00:40 — Resume" && row.action == .toggleNotes)
        let finishing = inputs { $0.notesFinishing = true; $0.notesElapsed = "02:00"; $0.notesTitle = "Idea" }
        #expect(try #require(MenuContent.entries(finishing).first { !$0.isSeparator }).action == nil)
    }

    @Test func recentNotesListsTheTopFiveWithRelativeDates() throws {
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let notes = (0..<8).map { RecentNote(id: "id\($0)", title: "Note \($0)", updatedAt: now.addingTimeInterval(-Double($0) * 7200)) }
        let row = try #require(entry(inputs { $0.recentNotes = notes; $0.now = now }, "Recent Notes"))
        let sub = try #require(row.submenu)
        #expect(sub.map(\.title) == ["Note 0", "Note 1", "Note 2", "Note 3", "Note 4"])
        #expect(sub.first?.action == .openNote("id0") && sub.first?.action?.payload == "id0")
        #expect(sub.allSatisfy { $0.value?.isEmpty == false })
        // Empty library: one dimmed line, nothing to open.
        let empty = try #require(entry(inputs(), "Recent Notes")?.submenu)
        #expect(empty.count == 1 && empty[0].title == "No notes yet" && !empty[0].isEnabled)
    }

    @Test func relativeDatesReadLikeSpeech() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_761_300_000)   // 2025-10-24 10:00 UTC
        func rel(_ back: TimeInterval) -> String { MenuContent.relativeDate(now.addingTimeInterval(-back), now: now, calendar: cal) }
        #expect(rel(10) == "Just now")
        #expect(rel(12 * 60) == "12 min ago")
        #expect(rel(3 * 3600) == "3 hr ago")
        #expect(rel(18 * 3600) == "Yesterday")
        #expect(rel(3 * 86400) == "Tue")
        #expect(rel(20 * 86400) == "Oct 4")
    }

    // MARK: status dot

    @Test func statusDotIsLilyMoonOrRecord() {
        #expect(MenuContent.header(inputs()).dot == .ready)
        #expect(MenuContent.header(inputs { $0.state = .listening }).dot == .ready)
        #expect(MenuContent.header(inputs { $0.health = Health(engine: "p", ready: false) }).dot == .loading)
        #expect(MenuContent.header(inputs { $0.health = nil }).dot == .loading)
        #expect(MenuContent.header(inputs { $0.health = nil; $0.healthError = "x" }).dot == .error)
        #expect(MenuContent.header(inputs { $0.state = .error("Mic busy") }).dot == .error)
        #expect(MenuContent.header(inputs { $0.paused = true }).dot == .paused)
    }

    @Test func headerShowsNotesElapsed() {
        let h = MenuContent.header(inputs { $0.notesRecording = true; $0.notesElapsed = "01:05" })
        #expect(h.status == "Notes · 01:05" && h.tone == .active)
        #expect(MenuContent.header(inputs { $0.notesFinishing = true }).status == "Notes · Finishing…")
        #expect(MenuContent.header(inputs { $0.notesRecording = true; $0.paused = true }).status == "Paused")
    }

    @Test func itemPayloadsCarryTheirChoice() {
        #expect(MenuAction.pickInput("boya").payload == "boya" && MenuAction.pickInput(nil).payload == nil)
        #expect(MenuAction.pickStyle("email").payload == "email" && MenuAction.openNote("n1").payload == "n1")
        #expect(MenuAction.quit.payload == nil && MenuAction.editStyles.payload == nil)
    }
}

@Suite struct StatusIconTests {
    private func icon(_ state: DictationState, reachable: Bool = true, debug: Bool = false, reduceMotion: Bool = false) -> StatusIcon {
        StatusIcon.of(state: state, serverReachable: reachable, debugRetention: debug, reduceMotion: reduceMotion)
    }

    @Test func glyphFollowsTheDictationState() {
        #expect(icon(.idle).glyph == .idle)
        for s in [DictationState.connecting, .listening, .finalizing, .inserting] { #expect(icon(s).glyph == .listening) }
        #expect(icon(.error("x")).glyph == .error)
    }

    @Test func dimmedOnlyWhileIdleAndTheServerIsUnreachable() {
        #expect(icon(.idle, reachable: false).dimmed)
        #expect(!icon(.idle).dimmed)
        #expect(!icon(.listening, reachable: false).dimmed)
        #expect(!icon(.error("x"), reachable: false).dimmed)
    }

    @Test func debugBadgeFollowsRetention() {
        #expect(icon(.idle, debug: true).debugBadge && !icon(.idle).debugBadge)
        #expect(icon(.listening, debug: true).debugBadge)
        #expect(icon(.idle, debug: true).accessibilityLabel == "Chirp, debug recordings kept")
    }

    @Test func wavesPulseOnlyWhileListeningAndNeverWithReduceMotion() {
        #expect(icon(.listening).animatesWaves && icon(.connecting).animatesWaves)
        #expect(!icon(.idle).animatesWaves && !icon(.error("x")).animatesWaves)
        #expect(!icon(.listening, reduceMotion: true).animatesWaves)
        #expect(StatusIcon.waveAlpha(phase: 0, reduceMotion: false) == 1)
        #expect(StatusIcon.waveAlpha(phase: 1, reduceMotion: false) < 0.5)
        #expect(StatusIcon.waveAlpha(phase: 2, reduceMotion: false) == 1)
        #expect((0..<6).allSatisfy { StatusIcon.waveAlpha(phase: $0, reduceMotion: true) == 1 })
    }

    @Test func pausedDimsTheIdleBirdAndSaysSo() {
        let paused = StatusIcon.of(state: .idle, serverReachable: true, debugRetention: false, paused: true)
        #expect(paused.glyph == .idle && paused.dimmed && paused.paused && !paused.animatesWaves)
        #expect(paused.accessibilityLabel == "Chirp — paused")
        #expect(!icon(.idle).paused && !icon(.idle).dimmed)
        // A debug badge still shows: the server keeps recordings whether or not Chirp is paused.
        #expect(StatusIcon.of(state: .idle, serverReachable: true, debugRetention: true, paused: true).debugBadge)
        // Paused wins over a leftover dictation state: the bird never pulses.
        #expect(!StatusIcon.of(state: .listening, serverReachable: true, debugRetention: false, paused: true).animatesWaves)
    }

    @Test func notesRecordingShowsThePulsingListeningGlyph() {
        let notes = StatusIcon.of(state: .idle, serverReachable: true, debugRetention: false, notesRecording: true)
        #expect(notes.glyph == .listening && notes.animatesWaves && !notes.dimmed)
        #expect(notes.accessibilityLabel == "Chirp — taking notes")
        #expect(!StatusIcon.of(state: .idle, serverReachable: true, debugRetention: false, reduceMotion: true, notesRecording: true).animatesWaves)
        #expect(StatusIcon.of(state: .idle, serverReachable: true, debugRetention: true, notesRecording: true).debugBadge)
        // The open mic shows even while the server is unreachable.
        #expect(StatusIcon.of(state: .idle, serverReachable: false, debugRetention: false, notesRecording: true).glyph == .listening)
    }

    @Test func accessibilityLabelSaysWhatIsWrong() {
        #expect(icon(.idle).accessibilityLabel == "Chirp")
        #expect(icon(.idle, reachable: false).accessibilityLabel == "Chirp — server unreachable")
        #expect(icon(.listening).accessibilityLabel == "Chirp — dictating")
    }
}

@Suite struct DoctorHelpTests {
    @Test func clipboardTextHasTheCommandsAndNoSecrets() {
        let text = DoctorHelp.clipboardText(serverURL: "http://127.0.0.1:7821")
        #expect(text.contains("chirp-server doctor --quick") && text.contains("chirp-server doctor\n"))
        #expect(text.contains("http://127.0.0.1:7821"))
        #expect(!text.lowercased().contains("token"))
    }

    @Test(arguments: ["installed", "checkout", "server"])
    func copiedDiagnosticsRunWithoutEditingPaths(location: String) throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("Chirp help \(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        let bin = root.appendingPathComponent(location == "installed" ? "bin" : "server/.venv/bin")
        try manager.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent("chirp-server")
        try "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$CHIRP_TEST_CALLS\"\n".write(to: executable, atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let calls = root.appendingPathComponent("calls")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-f", "-c", DoctorHelp.clipboardText(serverURL: "http://127.0.0.1:7821")]
        process.currentDirectoryURL = location == "server" ? root.appendingPathComponent("server") : root
        process.environment = [
            "PATH": location == "installed" ? "\(bin.path):/usr/bin:/bin" : "/usr/bin:/bin",
            "CHIRP_TEST_CALLS": calls.path,
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(try String(contentsOf: calls, encoding: .utf8) == "doctor --quick\ndoctor\n")
    }
}

@MainActor
@Suite struct PauseGateTests {
    /// A gate over a fake hotkey: counts registrations and says whether the shortcut is currently held.
    @MainActor private final class Fake {
        var registered = false
        var registerCalls = 0
        var unregisterCalls = 0
        var changes = 0
        var shortcutTaken = false
        lazy var gate = PauseGate(
            register: { [unowned self] in
                registerCalls += 1
                guard !shortcutTaken else { return false }
                registered = true
                return true
            },
            unregister: { [unowned self] in unregisterCalls += 1; registered = false },
            onChange: { [unowned self] in changes += 1 })
    }

    @Test func pauseUnregistersTheHotkeyAndResumeRegistersItAgain() {
        let fake = Fake()
        #expect(fake.gate.registerHotkey() && fake.registered && fake.gate.hotkeyRegistered && !fake.gate.isPaused)
        fake.gate.pause()
        #expect(!fake.registered && fake.gate.isPaused && !fake.gate.hotkeyRegistered)
        #expect(fake.gate.resume() && fake.registered && fake.gate.hotkeyRegistered && !fake.gate.isPaused)
    }

    @Test func nothingBringsTheHotkeyBackWhilePaused() {
        let fake = Fake()
        fake.gate.registerHotkey()
        fake.gate.pause()
        let calls = fake.registerCalls
        // The shortcut recorder stopping, a new shortcut and the app start all call registerHotkey().
        #expect(!fake.gate.registerHotkey() && !fake.registered)
        fake.gate.suspendHotkey()
        #expect(!fake.gate.registerHotkey() && !fake.registered && fake.registerCalls == calls)
    }

    @Test func pausingTwiceAndResumingTwiceAreHarmless() {
        let fake = Fake()
        fake.gate.registerHotkey()
        fake.gate.pause(); fake.gate.pause()
        #expect(fake.unregisterCalls == 1)
        fake.gate.resume()
        let calls = fake.registerCalls
        fake.gate.resume()
        #expect(fake.registerCalls == calls && fake.registered)
    }

    @Test func theSwitchMapsOnToRunning() {
        let fake = Fake()
        fake.gate.registerHotkey()
        fake.gate.setRunning(false)
        #expect(fake.gate.isPaused && !fake.registered)
        fake.gate.setRunning(true)
        #expect(!fake.gate.isPaused && fake.registered)
    }

    @Test func resumeReportsAShortcutAnotherAppOwns() {
        let fake = Fake()
        fake.gate.registerHotkey()
        fake.gate.pause()
        fake.shortcutTaken = true
        #expect(!fake.gate.resume())
        #expect(!fake.gate.isPaused && !fake.gate.hotkeyRegistered)
    }

    @Test func recorderSuspendsAndRestoresWhenRunning() {
        let fake = Fake()
        fake.gate.registerHotkey()
        fake.gate.suspendHotkey()
        #expect(!fake.registered && !fake.gate.hotkeyRegistered)
        #expect(fake.gate.registerHotkey() && fake.registered)
    }

    @Test func everyChangeIsAnnouncedSoTheIconFollows() {
        let fake = Fake()
        fake.gate.registerHotkey()
        let before = fake.changes
        fake.gate.pause()
        fake.gate.resume()
        #expect(fake.changes >= before + 2)
    }

    @Test func statusLineFollowsTheGate() {
        let fake = Fake()
        fake.gate.registerHotkey()
        func inputs() -> MenuInputs {
            var m = MenuInputs()
            m.health = Health(engine: "p", ready: true)
            m.paused = fake.gate.isPaused
            m.hotkeyRegistered = fake.gate.hotkeyRegistered
            return m
        }
        #expect(MenuContent.header(inputs()).status == "Ready · Right ⌥ Option" && MenuContent.header(inputs()).isOn)
        fake.gate.pause()
        #expect(MenuContent.header(inputs()).status == "Paused" && !MenuContent.header(inputs()).isOn)
        fake.gate.resume()
        #expect(MenuContent.header(inputs()).status == "Ready · Right ⌥ Option")
    }
}

/// Dictation history in the menu: the window on ⌥⌘H and the last three dictations, each with its actions.
@MainActor struct MenuHistoryTests {
    private func inputs(_ configure: (inout MenuInputs) -> Void = { _ in }) -> MenuInputs {
        var m = MenuInputs()
        m.health = Health(engine: "p", ready: true)
        m.now = Date(timeIntervalSince1970: 1_800_000_000)
        configure(&m)
        return m
    }
    private func entry(_ m: MenuInputs, _ title: String) -> MenuEntry? { MenuContent.entries(m).first { $0.title == title } }

    @Test func theHistoryWindowHasARealKeyEquivalent() throws {
        let row = try #require(entry(inputs(), "Dictation History…"))
        #expect(row.action == .showHistory && row.shortcut == "⌥⌘H" && row.keyEquivalent == "h" && row.keyEquivalentOption)
    }

    @Test func recentDictationsListsTheNewestThreeWithInsertCopyAndShow() throws {
        let m = inputs { m in
            m.recentDictations = (0..<5).map { RecentDictation(id: "id\($0)", preview: "Dictation number \($0) with a long tail of words after it",
                                                               date: m.now.addingTimeInterval(Double(-$0) * 600)) }
        }
        let recent = try #require(entry(m, "Recent Dictations")?.submenu)
        #expect(recent.count == 3)
        #expect(recent[0].title.hasSuffix("…") && recent[0].title.count <= 36)
        #expect(recent.map(\.value) == ["Just now", "10 min ago", "20 min ago"])
        #expect(recent[1].submenu?.map(\.action) == [.insertDictation("id1"), .copyDictation("id1"), .openDictation("id1")])
        #expect(MenuAction.insertDictation("id1").payload == "id1")
    }

    @Test func emptyOffAndBusyStates() throws {
        #expect(entry(inputs(), "Recent Dictations")?.submenu?.map(\.title) == ["No dictations yet"])
        #expect(entry(inputs { $0.historyEnabled = false }, "Recent Dictations")?.submenu?.map(\.title) == ["History is off"])
        // Insert Again waits while a dictation runs or Chirp is paused; Copy and Show still work.
        let busy = inputs { m in m.state = .listening; m.recentDictations = [RecentDictation(id: "a", preview: "hi", date: m.now)] }
        let actions = try #require(entry(busy, "Recent Dictations")?.submenu?.first?.submenu)
        #expect(actions.map(\.isEnabled) == [false, true, true])
    }
}
