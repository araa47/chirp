import XCTest

/// The Settings tree and History redesign (#194): seven category rows with live summaries, push on
/// iPhone and the two-pane split on iPad, Styles under Dictation, the confirmations, and the History
/// tab's day groups, detail sheet and swipe-delete with Undo. Synthetic only; live-server flows stay
/// in ChirpLiveServerUITests.
final class ChirpSettingsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    /// Terminating the app at the end avoids Xcode's multi-minute post-test diagnostics collection.
    private var launched: XCUIApplication?
    override func tearDown() {
        launched?.terminate()
        super.tearDown()
    }

    @MainActor func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--chirp-ui-test", "--chirp-skip-onboarding"] + extra
        app.launch()
        launched = app
        return app
    }

    @MainActor func pairedApp() -> XCUIApplication {
        let app = launch()
        app.pair(link: XCUIApplication.syntheticPairingLink)
        return app
    }

    @MainActor func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor func waitFor(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 5) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)], timeout: timeout) == .completed
    }

    @MainActor func screenshot(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways
        add(shot)
    }

    /// What each category page shows when it is open (its most stable identifier).
    private static let pages: [(row: String, marker: String, title: String)] = [
        ("chirp.settings.connection", "chirp.pair.change", "Connection"),
        ("chirp.settings.session", "chirp.settings.permissions", "Microphone session"),
        ("chirp.settings.dictation", "chirp.cleanup.enabled", "Dictation"),
        ("chirp.settings.keyboard", "chirp.keyboard.status", "Keyboard"),
        ("chirp.settings.notes", "chirp.notes.structure", "Notes settings"),
        ("chirp.settings.privacy", "chirp.history.enabled", "Privacy & history"),
        ("chirp.settings.about", "chirp.diagnostics.timings", "About"),
    ]

    /// Current Notes bindings and the configured hardware dictation key are discoverable together.
    @MainActor func testNotesAndHardwareKeyboardShortcuts() {
        let appearance = ProcessInfo.processInfo.environment["CHIRP_SHORTCUTS_APPEARANCE"] ?? "light"
        let app = launch()
        app.openSettingsPage("chirp.settings.keyboard")
        let link = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Keyboard shortcuts'")).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        if !link.isHittable { app.swipeUp() }
        link.tap()
        XCTAssertTrue(app.navigationBars["Keyboard shortcuts"].waitForExistence(timeout: 5))

        func row(_ title: String, _ keys: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", title, keys)).firstMatch
        }
        for (title, keys) in [("New note", "⌘N"), ("Record / Stop note", "⇧⌘R"),
                              ("Pause / Resume note", "⇧⌘P"), ("Search notes", "⌘F"),
                              ("Show or hide transcript", "⌥⌘T")] {
            XCTAssertTrue(row(title, keys).waitForExistence(timeout: 5), "Missing shortcut: \(title) \(keys)")
        }
        screenshot("notes-keyboard-shortcuts-\(appearance)", app)

        let hardware = row("Hold to dictate", "Right ⌥ Option")
        for _ in 0..<3 where !hardware.isHittable { app.swipeUp() }
        XCTAssertTrue(hardware.waitForExistence(timeout: 5))
        XCTAssertTrue(hardware.isHittable)
        XCTAssertTrue(row("Start or stop dictation", "⌘↩").exists)
        screenshot("dictation-keyboard-shortcuts-\(appearance)", app)
    }

    /// All seven categories are there with a live summary, each opens its page, and iPhone pushes back.
    @MainActor func testSevenCategoriesOpenTheirPages() {
        let app = pairedApp()
        app.selectChirpTab("Settings")
        for (row, marker, title) in Self.pages {
            XCTAssertTrue(app.buttons[row].waitForExistence(timeout: 5), "No \(row) category row")
            app.buttons[row].tap()
            XCTAssertTrue(element(marker, in: app).waitForExistence(timeout: 5), "\(title) page did not open")
            let back = app.navigationBars.buttons["Settings"]
            if back.exists { back.tap() } // iPhone: Back returns to the categories
        }
        // Live summaries: connected host, the app version, history off.
        XCTAssertTrue(waitFor(app.buttons["chirp.settings.connection"], "label CONTAINS 'Connected'"))
        XCTAssertTrue(waitFor(app.buttons["chirp.settings.about"], "label CONTAINS 'Chirp'"))
        XCTAssertTrue(waitFor(app.buttons["chirp.settings.privacy"], "label CONTAINS 'History off'"))
        screenshot("settings-tree", app)
    }

    /// iPad keeps the category summaries beside the open page; iPhone pushes the page over the list.
    @MainActor func testTwoPaneOnIPadPushOnIPhone() {
        let app = pairedApp()
        app.selectChirpTab("Settings")
        let rows = app.buttons["chirp.settings.dictation"]
        XCTAssertTrue(rows.waitForExistence(timeout: 5))
        rows.tap()
        XCTAssertTrue(element("chirp.cleanup.enabled", in: app).waitForExistence(timeout: 5))
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(app.buttons["chirp.settings.connection"].exists, "The category list stays beside the detail")
        } else {
            XCTAssertTrue(app.navigationBars["Dictation"].waitForExistence(timeout: 3), "iPhone pushes the page")
        }
    }

    /// iPad: a pushed page (Change pairing) does not stay over the next category the list selects.
    @MainActor func testPickingACategoryClosesAPushedPageOnIPad() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "The list is covered by the pushed page on iPhone.")
        let app = pairedApp()
        app.selectChirpTab("Settings")
        app.buttons["chirp.settings.connection"].tap()
        XCTAssertTrue(app.buttons["chirp.pair.change"].waitForExistence(timeout: 5))
        app.buttons["chirp.pair.change"].tap()
        XCTAssertTrue(app.buttons["chirp.pair.scan"].waitForExistence(timeout: 5))
        app.buttons["chirp.settings.dictation"].tap()
        XCTAssertTrue(element("chirp.cleanup.enabled", in: app).waitForExistence(timeout: 5), "Dictation did not replace Change pairing")
        XCTAssertFalse(app.buttons["chirp.pair.scan"].exists)
    }

    /// Spoken commands toggles and keeps its value.
    @MainActor func testSpokenCommandsToggles() {
        let app = pairedApp()
        app.openDictation()
        let commands = element("chirp.settings.spokenCommands", in: app)
        XCTAssertTrue(commands.waitForExistence(timeout: 5))
        if commands.value as? String != "1" {
            commands.switches.firstMatch.exists ? commands.switches.firstMatch.tap() : commands.tap()
        }
        XCTAssertTrue(waitFor(commands, "value == '1'"))
        commands.switches.firstMatch.exists ? commands.switches.firstMatch.tap() : commands.tap()
        XCTAssertTrue(waitFor(commands, "value == '0'"))
    }

    /// Clean-up that leaves the computer takes the consent dialog; a cancelled dialog leaves it off.
    /// (Local clean-up is on by default and needs no dialog: see testDictationStyleShowsRawAndCurrentStyle.)
    @MainActor func testCleanupConsent() {
        let app = launch(["--chirp-external-cleanup"])
        app.pair(link: XCUIApplication.syntheticPairingLink)
        app.openDictation()
        let cleanup = element("chirp.cleanup.enabled", in: app)
        XCTAssertTrue(cleanup.waitForExistence(timeout: 5))
        if cleanup.value as? String == "1" { cleanup.tap() }
        XCTAssertTrue(waitFor(cleanup, "value == '0'"))
        cleanup.switches.firstMatch.exists ? cleanup.switches.firstMatch.tap() : cleanup.tap()
        let enable = app.buttons["Enable for this destination"]
        XCTAssertTrue(enable.waitForExistence(timeout: 5), "No consent dialog")
        dismissDialog(app)
        XCTAssertTrue(waitFor(cleanup, "value == '0'"), "A cancelled consent leaves clean-up off")
        cleanup.switches.firstMatch.exists ? cleanup.switches.firstMatch.tap() : cleanup.tap()
        XCTAssertTrue(enable.waitForExistence(timeout: 5))
        enable.tap()
        XCTAssertTrue(waitFor(cleanup, "value == '1'"))
        screenshot("settings-dictation-cleanup", app)
    }

    /// Styles live under Dictation: selecting one moves the checkmark, and the prompt editor opens.
    @MainActor func testStyleSelectionAndPromptEditor() {
        let app = pairedApp()
        app.openDictation()
        let row = app.descendants(matching: .any).matching(identifier: "chirp.styles.row.default").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "Server styles did not load")
        app.buttons["chirp.styles.pick.default"].tap()
        app.buttons["chirp.styles.edit.default"].tap()
        XCTAssertTrue(app.buttons["chirp.styles.reset"].waitForExistence(timeout: 5), "Prompt editor did not open")
        XCTAssertTrue(app.buttons["Selected"].waitForExistence(timeout: 3), "The tapped style did not become selected")
        screenshot("settings-dictation-styles", app)
        screenshot("settings-prompt-editor", app)
    }

    /// History on → dictate → day-grouped row → detail sheet → delete → Undo → delete again.
    @MainActor func testHistoryRowDetailDeleteUndo() {
        let app = pairedApp()
        // History settings moved out of the list: the ⋯ menu deep-links to Settings → Privacy & history.
        app.selectChirpTab("History")
        XCTAssertTrue(app.staticTexts["History is off"].waitForExistence(timeout: 5))
        app.buttons["chirp.history.menu"].tap()
        app.buttons["History settings"].tap()
        let toggle = element("chirp.history.enabled", in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "The ⋯ menu did not reach Privacy & history")
        toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        XCTAssertTrue(waitFor(toggle, "value == '1'"))

        app.selectChirpTab("Dictate")
        app.buttons["chirp.dictation.start"].tap()
        XCTAssertTrue(app.buttons["chirp.dictation.stop"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitFor(app.staticTexts["transcript"], "label == 'synthetic words'"))
        app.buttons["chirp.dictation.stop"].tap()
        XCTAssertTrue(app.staticTexts["Finished"].waitForExistence(timeout: 5))

        app.selectChirpTab("History")
        let entry = app.staticTexts["Synthetic words."]
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "History did not record the dictation")
        XCTAssertTrue(app.staticTexts["Today"].exists, "Entries group by day")
        screenshot("history-list", app)

        entry.tap()
        XCTAssertTrue(app.staticTexts["Before clean-up"].waitForExistence(timeout: 5), "No detail sheet")
        screenshot("history-detail", app)
        app.buttons["Close"].tap()

        entry.tap()
        let delete = app.buttons["chirp.history.delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let undo = app.buttons["chirp.history.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5), "No Undo toast")
        undo.tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "Undo did not restore the row")

        entry.firstMatch.swipeLeft()
        // Full-swipe deletes at once; a half swipe leaves the Delete button to tap.
        let swiped = app.buttons["Delete"].firstMatch
        if swiped.waitForExistence(timeout: 2) { swiped.tap() }
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        XCTAssertTrue(waitFor(entry, "exists == 0", timeout: 8), "The deferred delete never landed")
        XCTAssertTrue(app.staticTexts["Nothing yet"].waitForExistence(timeout: 5))
        screenshot("history-empty", app)
    }

    /// Stop dictation "When I pause" with its lengths (#271 A2-14), and Learning (A2-5): the footer says what iOS
    /// learns, Learned starts empty, and Teach Chirp in History puts a term there at once.
    @MainActor func testStopOnPauseLearningAndTeachChirp() {
        let app = pairedApp()
        app.openDictation()
        let pause = app.buttons["When I pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 5), "No Stop dictation choice")
        for _ in 0..<4 where !pause.isHittable { app.swipeUp() }
        pause.tap()
        let three = app.buttons["3 s"]
        XCTAssertTrue(three.waitForExistence(timeout: 3), "No pause lengths")
        three.tap()
        XCTAssertTrue(waitFor(three, "selected == 1"))
        screenshot("settings-dictation-stop", app)
        let footer = element("chirp.settings.learnFooter", in: app)
        XCTAssertTrue(footer.waitForExistence(timeout: 5), "No Learning footer")
        for _ in 0..<6 where !footer.isHittable { app.swipeUp() }
        XCTAssertTrue((footer.label as NSString).contains("no per-app style"))
        screenshot("settings-dictation-learning", app)
        element("chirp.settings.learned", in: app).tap()
        XCTAssertTrue(element("chirp.learned.empty", in: app).waitForExistence(timeout: 5), "Learned is not empty at first")
        screenshot("settings-learned-empty", app)

        openCategory("chirp.settings.privacy", app)
        let history = element("chirp.history.enabled", in: app)
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        if history.value as? String != "1" { history.switches.firstMatch.exists ? history.switches.firstMatch.tap() : history.tap() }
        XCTAssertTrue(waitFor(history, "value == '1'"))
        app.selectChirpTab("Dictate")
        app.buttons["chirp.dictation.start"].tap()
        XCTAssertTrue(app.buttons["chirp.dictation.stop"].waitForExistence(timeout: 5))
        app.buttons["chirp.dictation.stop"].tap()
        XCTAssertTrue(app.staticTexts["Finished"].waitForExistence(timeout: 5))
        app.selectChirpTab("History")
        let entry = app.staticTexts["Synthetic words."]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        let teach = app.buttons["chirp.history.teach"]
        XCTAssertTrue(teach.waitForExistence(timeout: 5), "No Teach Chirp in the detail sheet")
        teach.tap()
        let text = element("chirp.teach.text", in: app)
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        // Below the last line puts the caret at the end: "Synthetic words." becomes "Synthetic GitHub."
        text.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.9)).tap()
        text.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + "GitHub.")
        screenshot("history-teach", app)
        app.buttons["chirp.teach.commit"].tap()
        XCTAssertTrue(app.staticTexts["Learned: GitHub"].waitForExistence(timeout: 5), "Teach Chirp learned nothing")

        app.selectChirpTab("Settings")
        openCategory("chirp.settings.dictation", app)
        let learned = element("chirp.settings.learned", in: app)
        XCTAssertTrue(learned.waitForExistence(timeout: 5))
        for _ in 0..<6 where !learned.isHittable { app.swipeUp() }
        learned.tap()
        XCTAssertTrue(app.staticTexts["GitHub"].waitForExistence(timeout: 5), "The taught term is not in Learned")
        XCTAssertTrue(app.staticTexts["In use"].exists)
        screenshot("settings-learned", app)
    }

    /// Search matches the saved text and the original transcript.
    @MainActor func testHistorySearch() {
        let app = pairedApp()
        app.selectChirpTab("History")
        XCTAssertTrue(app.staticTexts["History is off"].waitForExistence(timeout: 5))
        app.buttons["chirp.history.turnOn"].tap()
        XCTAssertTrue(app.staticTexts["Nothing yet"].waitForExistence(timeout: 5))

        app.selectChirpTab("Dictate")
        app.buttons["chirp.dictation.start"].tap()
        _ = app.buttons["chirp.dictation.stop"].waitForExistence(timeout: 5)
        app.buttons["chirp.dictation.stop"].tap()
        XCTAssertTrue(app.staticTexts["Finished"].waitForExistence(timeout: 5))

        app.selectChirpTab("History")
        XCTAssertTrue(app.staticTexts["Synthetic words."].waitForExistence(timeout: 5))
        // iPad portrait collapses the search field into a Search button in the navigation bar (iPhone shows the field).
        let search = app.searchFields.firstMatch
        let collapsed = app.navigationBars["Dictation history"].buttons["Search"]
        if !search.waitForExistence(timeout: 3) {
            app.dismissSidebarOverlay(covering: collapsed)
            XCTAssertTrue(collapsed.waitForExistence(timeout: 5), "No History search field or Search button")
            collapsed.tap()
        }
        XCTAssertTrue(search.waitForExistence(timeout: 5), "Search did not open")
        search.tap()
        search.typeText("synthetic")
        XCTAssertTrue(app.staticTexts["Synthetic words."].exists, "Saved text matches")
        search.typeText("zzz")
        XCTAssertTrue(app.staticTexts["No matches"].waitForExistence(timeout: 5), "The original text is not matched")
    }

    /// Forget pairing asks first; Cancel leaves the connection page unchanged.
    @MainActor func testForgetPairingConfirmationCancel() {
        let app = pairedApp()
        app.openConnection()
        let forget = app.buttons["chirp.pair.forget"]
        XCTAssertTrue(forget.waitForExistence(timeout: 5))
        forget.tap()
        XCTAssertTrue(app.buttons["Forget"].waitForExistence(timeout: 5), "No Forget confirmation")
        dismissDialog(app)
        XCTAssertTrue(element("chirp.connection.banner", in: app).waitForExistence(timeout: 5), "Cancelling must keep the pairing")
        screenshot("settings-connection", app)
    }

    /// Off fences new dictations while keeping the old ones accessible; Delete history works while off.
    @MainActor func testTurningHistoryOffIsConfirmed() {
        let app = pairedApp()
        app.openSettingsPage("chirp.settings.privacy")
        let toggle = element("chirp.history.enabled", in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        XCTAssertTrue(waitFor(toggle, "value == '1'"))
        app.selectChirpTab("Dictate")
        app.buttons["chirp.dictation.start"].tap()
        XCTAssertTrue(app.buttons["chirp.dictation.stop"].waitForExistence(timeout: 5))
        app.buttons["chirp.dictation.stop"].tap()
        XCTAssertTrue(app.staticTexts["Finished"].waitForExistence(timeout: 5))
        app.openSettingsPage("chirp.settings.privacy")
        for (appearance, name) in [(XCUIDevice.Appearance.light, "light"), (.dark, "dark")] {
            XCUIDevice.shared.appearance = appearance
            screenshot("history-settings-" + name, app)
        }
        toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        XCTAssertTrue(app.buttons["Turn Off and Delete"].waitForExistence(timeout: 5))
        dismissDialog(app)
        XCTAssertTrue(waitFor(toggle, "value == '1'"), "Cancelling keeps history on")
        toggle.switches.firstMatch.exists ? toggle.switches.firstMatch.tap() : toggle.tap()
        for (appearance, name) in [(XCUIDevice.Appearance.light, "light"), (.dark, "dark")] {
            XCUIDevice.shared.appearance = appearance
            screenshot("history-turn-off-" + name, app)
        }
        app.buttons["Turn Off, Keep History"].tap()
        XCTAssertTrue(waitFor(toggle, "value == '0'"))
        app.selectChirpTab("History")
        XCTAssertTrue(app.staticTexts["Synthetic words."].waitForExistence(timeout: 5), "Retained dictations remain readable")
        screenshot("history-retained-while-off", app)
        app.openSettingsPage("chirp.settings.privacy")
        let delete = app.buttons["chirp.history.clear"]
        if !delete.isHittable { app.swipeUp() }
        delete.tap()
        app.buttons["Delete History"].tap()
        XCTAssertTrue(waitFor(toggle, "value == '0'"), "Deletion keeps the switch off")
        app.selectChirpTab("History")
        XCTAssertTrue(app.staticTexts["History is off"].waitForExistence(timeout: 5))
        XCUIDevice.shared.appearance = .light
    }

    /// At the largest accessibility text size the Settings home and Dictation pages must not run past either
    /// screen edge (#271 A2-2): every row, switch and chip stays inside the window. Also the AX5 captures.
    @MainActor func testSettingsStayInsideTheScreenAtAX5() {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        app.pair(link: XCUIApplication.syntheticPairingLink)
        app.selectChirpTab("Settings")
        let window = app.windows.firstMatch.frame
        func assertInside(_ ids: [String], _ page: String) {
            for id in ids {
                let item = element(id, in: app)
                XCTAssertTrue(item.waitForExistence(timeout: 5), "\(page): no \(id)")
                let frame = item.frame
                XCTAssertGreaterThanOrEqual(frame.minX, window.minX - 0.5, "\(page): \(id) runs past the left edge")
                XCTAssertLessThanOrEqual(frame.maxX, window.maxX + 0.5, "\(page): \(id) runs past the right edge")
            }
        }
        _ = element("chirp.settings.dictation", in: app).waitForExistence(timeout: 5)
        assertInside(["chirp.settings.connection", "chirp.settings.dictation"], "Settings home")
        screenshot("settings-home-ax5", app)
        openCategory("chirp.settings.dictation", app)
        assertInside(["chirp.cleanup.enabled", "chirp.styles.row.default", "chirp.settings.spokenCommands", "chirp.settings.autoEnter"], "Dictation")
        screenshot("settings-dictation-ax5", app)
    }

    /// The Settings/History screenshots for the README and the PR (#194): every page, light or dark as
    /// `simctl ui` set the device. Synthetic content only. Runs only with CHIRP_SCREENSHOTS=1.
    @MainActor func testCaptureSettingsTour() throws {
        guard ProcessInfo.processInfo.environment["CHIRP_SCREENSHOTS"] == "1" else {
            throw XCTSkip("Screenshot run only: set TEST_RUNNER_CHIRP_SCREENSHOTS=1.")
        }
        let app = launch(["--chirp-hardware-keyboard"])
        app.pair(link: XCUIApplication.syntheticPairingLink)
        app.selectChirpTab("Settings")
        shot("settings-home", app)
        openCategory("chirp.settings.connection", app)
        _ = element("chirp.connection.banner", in: app).waitForExistence(timeout: 5)
        shot("settings-connection-connected", app)
        let change = app.buttons["chirp.pair.change"]
        change.tap()
        _ = app.buttons["chirp.pair.scan"].waitForExistence(timeout: 5)
        shot("settings-change-pairing", app)
        openCategory("chirp.settings.session", app)
        _ = element("chirp.settings.permissions", in: app).waitForExistence(timeout: 5)
        shot("settings-session", app)
        openCategory("chirp.settings.dictation", app)
        _ = element("chirp.cleanup.enabled", in: app).waitForExistence(timeout: 5)
        let cleanup = element("chirp.cleanup.enabled", in: app)
        if cleanup.value as? String != "1" {
            cleanup.switches.firstMatch.exists ? cleanup.switches.firstMatch.tap() : cleanup.tap()
            let enable = app.buttons["Enable for this destination"]
            if enable.waitForExistence(timeout: 3) { enable.tap() }
        }
        _ = waitFor(cleanup, "value == '1'")
        shot("settings-dictation", app)
        app.buttons["chirp.styles.edit.default"].tap()
        _ = app.buttons["chirp.styles.reset"].waitForExistence(timeout: 5)
        shot("settings-prompt-editor", app)
        openCategory("chirp.settings.keyboard", app)
        _ = element("chirp.keyboard.status", in: app).waitForExistence(timeout: 5)
        shot("settings-keyboard", app)
        app.buttons["chirp.keyboard.way.onScreen"].tap()
        _ = app.staticTexts["On screen"].waitForExistence(timeout: 3)
        shot("settings-ways-to-dictate", app)
        app.buttons["Close"].tap()
        openCategory("chirp.settings.notes", app)
        _ = element("chirp.notes.structure", in: app).waitForExistence(timeout: 5)
        shot("settings-notes", app)
        openCategory("chirp.settings.privacy", app)
        _ = element("chirp.history.enabled", in: app).waitForExistence(timeout: 5)
        shot("settings-privacy", app)
        openCategory("chirp.settings.about", app)
        _ = element("chirp.diagnostics.timings", in: app).waitForExistence(timeout: 5)
        shot("settings-about", app)

        // History: off, then on with one dictated entry, its detail sheet, and the ⋯ menu's path.
        app.selectChirpTab("History")
        XCTAssertTrue(app.staticTexts["History is off"].waitForExistence(timeout: 5))
        shot("history-off", app)
        app.buttons["chirp.history.turnOn"].tap()
        XCTAssertTrue(app.staticTexts["Nothing yet"].waitForExistence(timeout: 5))
        shot("history-empty", app)
        app.selectChirpTab("Dictate")
        app.buttons["chirp.dictation.start"].tap()
        _ = app.buttons["chirp.dictation.stop"].waitForExistence(timeout: 5)
        app.buttons["chirp.dictation.stop"].tap()
        _ = app.staticTexts["Finished"].waitForExistence(timeout: 5)
        app.selectChirpTab("History")
        XCTAssertTrue(app.staticTexts["Synthetic words."].waitForExistence(timeout: 5))
        shot("history-list", app)
        let row = app.staticTexts["Synthetic words."]
        // At the largest text sizes the row starts under the mic bar and tab bar: scroll it clear first.
        for _ in 0..<3 where !row.isHittable { app.swipeUp() }
        row.tap()
        // The sheet's Close button, not a row inside it: at the largest text sizes the lists are lazy.
        XCTAssertTrue(app.buttons["Close"].waitForExistence(timeout: 5))
        shot("history-detail", app)
        app.buttons["Close"].tap()
        app.buttons["chirp.history.menu"].tap()
        shot("history-menu", app)
    }

    /// Pushed pages (iPhone) go back one level per tap; the two-pane iPad always shows the rows.
    @MainActor private func openCategory(_ row: String, _ app: XCUIApplication) {
        for _ in 0..<4 where !app.buttons[row].exists {
            let back = app.navigationBars.buttons["BackButton"]
            guard back.exists else { break }
            back.tap()
        }
        XCTAssertTrue(app.buttons[row].waitForExistence(timeout: 5), "No \(row) category row")
        app.buttons[row].tap()
    }

    /// iOS 26 renders confirmationDialog as a compact popover with no cancel button; cancelling is
    /// tapping the outside dismiss region.
    @MainActor private func dismissDialog(_ app: XCUIApplication) {
        let dismiss = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'dismiss popup' OR identifier == 'PopoverDismissRegion'")).firstMatch
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5), "No dismiss region around the dialog")
        dismiss.tap()
    }

    @MainActor private func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
