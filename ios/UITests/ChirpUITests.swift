import XCTest

final class ChirpUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor func launch(_ extra: [String] = ["--chirp-skip-onboarding"]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--chirp-ui-test"] + extra
        app.launch()
        return app
    }

    @MainActor func pairedApp() -> XCUIApplication {
        let app = launch()
        app.pair(link: XCUIApplication.syntheticPairingLink)
        return app
    }

    @MainActor func waitFor(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 5) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)], timeout: timeout) == .completed
    }

    @MainActor func screenshot(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways
        add(shot)
    }

    /// Four tabs, Notes first, no "More" and no Notes toolbar button; Pair computer and Styles are no longer tabs.
    @MainActor func testShellHasFourTabsStartingOnNotes() {
        let app = launch()
        XCTAssertTrue(app.buttons["chirp.notes.record"].waitForExistence(timeout: 5), "Notes is the start tab")
        XCTAssertFalse(app.buttons["chirp.notes.open"].exists, "No Notes toolbar workaround")
        XCTAssertTrue(app.buttons["chirp.connection.chip"].exists)
        XCTAssertEqual(app.buttons["chirp.connection.chip"].label, "Connection: Not paired. Open connection settings")
        if app.tabBars.firstMatch.exists {
            for title in ["Notes", "Dictate", "History", "Settings"] { XCTAssertTrue(app.tabBars.buttons[title].exists, title) }
            for gone in ["More", "Pair computer", "Styles"] { XCTAssertFalse(app.tabBars.buttons[gone].exists, gone) }
        }
        screenshot("Notes with the setup card", app)
        app.dismissSidebarOverlay(covering: app.buttons["chirp.connection.chip"])
        app.buttons["chirp.connection.chip"].tap()
        // The chip deep-links to Settings → Connection; pairing itself sits behind Pair Mac (#194).
        XCTAssertTrue(app.buttons["chirp.pair.change"].waitForExistence(timeout: 5), "The chip opens Settings → Connection")
        app.selectChirpTab("Dictate")
        XCTAssertTrue(app.staticTexts["sessionStatus"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["sessionStatus"].label, "Microphone off")
        XCTAssertFalse(app.buttons["chirp.dictation.start"].isEnabled, "Dictate needs a paired computer")
        XCTAssertTrue(app.buttons["chirp.pair.open"].exists, "One banner names the missing pairing")
        screenshot("Dictate unpaired", app)
    }

    /// First launch shows onboarding; Skip for now walks through to Notes with the setup card.
    @MainActor func testOnboardingSkipLandsOnNotesWithSetupCard() {
        let app = launch(["--chirp-onboarding", "--chirp-setup-card"])
        let next = app.buttons["chirp.onboarding.next"], skip = app.buttons["chirp.onboarding.skip"]
        XCTAssertTrue(next.waitForExistence(timeout: 5), "First launch shows onboarding")
        XCTAssertEqual(next.label, "Get started")
        screenshot("Onboarding 1 welcome", app)
        next.tap()
        XCTAssertTrue(app.buttons["chirp.pair.scan"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Pair your computer"].exists)
        XCTAssertTrue(app.staticTexts["On your computer, open Chirp → Settings → Devices → Pair a Phone, or run chirp-server pair on your server."].exists)
        XCTAssertTrue(app.buttons["About pairing"].exists)
        screenshot("Onboarding 2 pair", app)
        app.buttons["chirp.pair.paste"].tap()
        XCTAssertTrue(app.secureTextFields["pairingLink"].waitForExistence(timeout: 5))
        skip.tap()
        XCTAssertTrue(app.staticTexts["Allow the microphone"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["What Chirp keeps"].exists)
        screenshot("Onboarding 3 microphone", app)
        skip.tap()
        XCTAssertTrue(app.staticTexts["Turn on Chirp Keyboard"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["About the keyboard"].exists)
        screenshot("Onboarding 4 keyboard", app)
        skip.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chirp.setup"].waitForExistence(timeout: 5), "Skip lands on Notes with the setup card")
        XCTAssertTrue(app.buttons["chirp.notes.record"].exists)
        XCTAssertEqual(app.buttons["chirp.setup.fix"].label, "Pair computer")
        screenshot("Notes setup card after Skip", app)
        // Finished onboarding stays finished.
        app.terminate()
        let again = launch([])
        XCTAssertTrue(again.buttons["chirp.notes.record"].waitForExistence(timeout: 5))
        XCTAssertFalse(again.buttons["chirp.onboarding.next"].exists, "Onboarding never comes back by itself")
    }

    /// Pairing from onboarding saves on submit (no second "save" tap) and moves on to the microphone page.
    @MainActor func testOnboardingPairsWithoutASecondTap() {
        let app = launch(["--chirp-onboarding"])
        app.buttons["chirp.onboarding.next"].tap()
        let field = app.pairingLinkField()
        field.tap()
        field.typeText(XCUIApplication.syntheticPairingLink + "\n")
        XCTAssertTrue(app.descendants(matching: .any)["chirp.pair.connected"].waitForExistence(timeout: 5), "Submit verifies and saves")
        XCTAssertEqual(app.buttons["chirp.onboarding.next"].label, "Continue")
        screenshot("Onboarding 2 pair connected", app)
        app.buttons["chirp.onboarding.next"].tap()
        XCTAssertTrue(app.staticTexts["Allow the microphone"].waitForExistence(timeout: 5))
    }

    @MainActor func testSyntheticPairDictateRawAndEnd() {
        let app = pairedApp()
        app.selectChirpTab("Dictate")
        XCTAssertEqual(app.buttons["chirp.connection.chip"].label, "Connection: Computer. Open connection settings")
        screenshot("Dictate idle", app)
        app.buttons["chirp.dictation.start"].tap()
        XCTAssertTrue(app.buttons["chirp.dictation.stop"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitFor(app.staticTexts["transcript"], "label == 'synthetic words'"))
        screenshot("Dictate listening", app)
        app.buttons["chirp.dictation.stop"].tap()
        XCTAssertTrue(app.buttons["chirp.dictation.raw"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["transcript"].label, "Synthetic words.")
        XCTAssertEqual(app.staticTexts["sessionStatus"].label, "Finished")
        XCTAssertTrue(app.buttons["chirp.dictation.raw"].label.hasPrefix("Use raw"))
        XCTAssertTrue(app.buttons["chirp.session.end"].exists, "The session capsule shows while armed")
        screenshot("Dictate finished", app)
        app.buttons["chirp.dictation.raw"].tap()
        XCTAssertEqual(app.staticTexts["transcript"].label, "synthetic words")
        // Regression: the armed session bar covered iOS 27's tab bar, so a tab tap ended the session.
        app.selectChirpTab("History")
        XCTAssertTrue(app.staticTexts["History is off"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["chirp.session.end"].exists, "Switching tabs must not end the session")
        screenshot("Session capsule", app)
        app.selectChirpTab("Dictate")
        XCTAssertTrue(app.staticTexts["Finished"].exists)
        app.endChirpSession()
        XCTAssertTrue(app.staticTexts["Microphone off"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["transcript"].exists)
    }

    /// The finished text can be edited, then Save as note makes a new note with it and shows it (#271 A2-8).
    @MainActor func testDictateEditAndSaveAsNote() {
        let app = pairedApp()
        app.selectChirpTab("Dictate")
        app.buttons["chirp.dictation.start"].tap()
        XCTAssertTrue(waitFor(app.staticTexts["transcript"], "label == 'synthetic words'"))
        app.buttons["chirp.dictation.stop"].tap()
        XCTAssertTrue(waitFor(app.staticTexts["transcript"], "label == 'Synthetic words.'"))
        app.buttons["chirp.dictation.edit"].tap()
        let editor = app.textViews["chirp.dictation.editor"].exists ? app.textViews["chirp.dictation.editor"] : app.textFields["chirp.dictation.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.typeText(" Edited here.")
        screenshot("Dictate editing", app)
        app.buttons["chirp.dictation.edit"].tap()
        XCTAssertTrue(waitFor(app.staticTexts["transcript"], "label == 'Synthetic words. Edited here.'"))
        app.buttons["chirp.dictation.saveNote"].tap()
        let preview = app.descendants(matching: .any).matching(identifier: "chirp.notes.preview").firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10), "Save as note opens the new note")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Edited here.'")).firstMatch.waitForExistence(timeout: 5))
        screenshot("Dictate saved as note", app)
        app.endChirpSession()
    }

    @MainActor func testDictationStyleShowsRawAndCurrentStyle() {
        let app = pairedApp()
        defer { app.terminate(); XCUIDevice.shared.appearance = .light }
        app.openSettingsPage("chirp.settings.dictation")
        for (appearance, name) in [(XCUIDevice.Appearance.light, "light"), (.dark, "dark")] {
            XCUIDevice.shared.appearance = appearance
            screenshot("cleanup-settings-" + name, app)
        }
        app.selectChirpTab("Dictate")
        let style = app.buttons["chirp.dictation.style"]
        XCTAssertTrue(style.waitForExistence(timeout: 5))
        XCTAssertEqual(style.value as? String, "Default")
        for (appearance, name) in [(XCUIDevice.Appearance.light, "light"), (.dark, "dark")] {
            XCUIDevice.shared.appearance = appearance
            screenshot("dictate-style-default-" + name, app)
        }
        style.tap(); app.buttons["Raw"].tap()
        XCTAssertEqual(style.value as? String, "Raw")
        style.tap(); app.buttons["Default"].tap()
        XCTAssertEqual(style.value as? String, "Default")
        XCTAssertFalse(app.buttons["Enable for this destination"].exists, "Local clean-up needs no consent dialog")
    }

    @MainActor func testHistoryOffAndAdaptiveOrientation() {
        let app = pairedApp()
        app.selectChirpTab("History")
        // The off state is the History tab's own screen now; the settings live behind the ⋯ menu.
        XCTAssertTrue(app.staticTexts["History is off"].waitForExistence(timeout: 5))
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.staticTexts["History is off"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .portrait
        app.selectChirpTab("Settings")
        let back = app.navigationBars.buttons["Settings"]
        if back.exists { back.tap() }
        XCTAssertTrue(app.buttons["chirp.settings.session"].waitForExistence(timeout: 5))
    }
}
