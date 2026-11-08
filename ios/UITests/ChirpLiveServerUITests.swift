import XCTest

/// End to end against a real local chirp-server (see `ios/scripts/simulator-e2e.sh`), with spoken audio from
/// `--chirp-sim-audio`. Skipped unless the runner passes CHIRP_LIVE_LINK and CHIRP_LIVE_AUDIO.
final class ChirpLiveServerUITests: XCTestCase {
    private var link = ""
    private var audio = ""

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let link = env["CHIRP_LIVE_LINK"], !link.isEmpty, let audio = env["CHIRP_LIVE_AUDIO"], !audio.isEmpty else {
            throw XCTSkip("Live server run only: set TEST_RUNNER_CHIRP_LIVE_LINK and TEST_RUNNER_CHIRP_LIVE_AUDIO.")
        }
        self.link = link; self.audio = audio
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor func launch(audio file: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--chirp-sim-audio", file ?? audio, "--chirp-skip-onboarding"]
        app.launch()
        return app
    }

    @MainActor func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor func waitFor(_ element: XCUIElement, _ format: String, _ args: Any..., timeout: TimeInterval = 20) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, argumentArray: args), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor func allowSystemAlert() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "Open", "OK"] where springboard.alerts.buttons[label].waitForExistence(timeout: 1) {
            springboard.alerts.buttons[label].tap()
        }
    }

    @MainActor func screenshot(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways
        add(shot)
    }

    /// Forget, paste the secret link, verify against the live server, save. Success pops back to
    /// Connection, whose banner names the host.
    @MainActor func pair(_ app: XCUIApplication) {
        app.openConnection()
        endSession(app)
        forgetPairing(app)
        let field = app.pairingLinkField()
        field.tap()
        field.typeText(link)
        app.buttons["chirp.pair.submit"].tap()
        let banner = app.descendants(matching: .any).matching(identifier: "chirp.connection.banner").firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 15), "Live server pairing failed")
        // The banner is a container (its title and detail are separate texts, each read by VoiceOver), so look inside it.
        let host = banner.staticTexts.matching(NSPredicate(format: "label CONTAINS '127.0.0.1'")).firstMatch
        XCTAssertTrue(host.waitForExistence(timeout: 5), "The banner must name the paired host")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Chirp simulator'")).firstMatch.exists,
                      "The per-device pairing name must show")
    }

    /// Forget pairing asks first; confirming clears the pairing (the banner and its group disappear).
    @MainActor func forgetPairing(_ app: XCUIApplication) {
        // The Form builds only visible rows: below the fold the button is not in the tree yet.
        let forget = app.buttons["chirp.pair.forget"]
        guard forget.waitForExistence(timeout: 2) else { return }
        for _ in 0..<4 where !(forget.exists && forget.isHittable) { app.swipeUp() }
        guard forget.exists else { XCTFail("Forget pairing is not reachable"); return }
        forget.tap()
        XCTAssertTrue(app.buttons["Forget"].waitForExistence(timeout: 3), "No Forget confirmation")
        app.buttons["Forget"].tap()
        XCTAssertTrue(waitFor(forget, "exists == false", timeout: 5), "Forget pairing did not clear it")
    }

    /// The QR's secret link opened by iOS: the system asks "Open in Chirp?" before Chirp verifies and saves.
    @MainActor func pairByDeepLink(_ app: XCUIApplication) throws {
        app.openConnection()
        endSession(app)
        forgetPairing(app)
        let banner = app.descendants(matching: .any).matching(identifier: "chirp.connection.banner").firstMatch
        XCTAssertFalse(banner.waitForExistence(timeout: 2))
        XCUIDevice.shared.system.open(try XCTUnwrap(URL(string: link)))
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Open"]
        if open.waitForExistence(timeout: 5) { open.tap() }
        XCTAssertTrue(banner.waitForExistence(timeout: 15), "Deep-link pairing failed")
    }

    /// The first words survive: speech that starts the moment dictation does (buffered until the server is ready), and
    /// speech that starts after "Listening…" (as when a person waits for it), both keep "Chirp test one". On the
    /// operator's iPad the opening words of a dictation went missing once; this pins where they could be lost.
    @MainActor func testLiveFirstWordsSurvive() throws {
        let env = ProcessInfo.processInfo.environment
        guard let early = env["CHIRP_LIVE_FIRST_AUDIO"], let late = env["CHIRP_LIVE_FIRST_LATE_AUDIO"] else {
            throw XCTSkip("First-words run only: set TEST_RUNNER_CHIRP_LIVE_FIRST_AUDIO and TEST_RUNNER_CHIRP_LIVE_FIRST_LATE_AUDIO.")
        }
        for (file, name) in [(early, "speech from the start"), (late, "speech after Listening")] {
            let app = launch(audio: file)
            pair(app)
            app.selectChirpTab("Dictate")
            app.buttons["chirp.dictation.start"].tap()
            allowSystemAlert()
            let stop = app.buttons["chirp.dictation.stop"]
            XCTAssertTrue(stop.waitForExistence(timeout: 15))
            let transcript = app.staticTexts["transcript"]
            XCTAssertTrue(waitFor(transcript, "label CONTAINS[c] 'lazy dog'", timeout: 30), "\(name): the sentence never finished")
            stop.tap()
            XCTAssertTrue(waitFor(app.staticTexts["sessionStatus"], "label == 'Finished'", timeout: 30))
            print("CHIRP-FIRST \(name): \(transcript.label)")
            // The opening sentence ("Chirp test one", which the model may write "… test 1" or hear "Chirp" as another word)
            // must come before "quick": that is what was missing on the iPad.
            let heard = transcript.label.lowercased()
            let opening = heard.range(of: "quick").map { String(heard[..<$0.lowerBound]) } ?? ""
            XCTAssertTrue(opening.contains("test"), "\(name): first words lost: \(transcript.label)")
            screenshot("First words, \(name)", app)
            endSession(app)
            app.terminate()
        }
    }

    @MainActor func testLivePairDictateCleanupRawHistoryAndEnd() {
        let app = launch()
        pair(app)
        screenshot("Paired with local server", app)

        app.openDictation()
        XCTAssertTrue(app.staticTexts["Clean-up runs on your computer."].waitForExistence(timeout: 5))
        let cleanup = element("chirp.cleanup.enabled", in: app)
        XCTAssertTrue(cleanup.waitForExistence(timeout: 5))
        if cleanup.value as? String != "1" {
            cleanup.switches.firstMatch.exists ? cleanup.switches.firstMatch.tap() : cleanup.tap()
            let enable = app.buttons["Enable for this destination"]
            XCTAssertTrue(enable.waitForExistence(timeout: 5))
            enable.tap()
        }
        XCTAssertTrue(waitFor(cleanup, "value == '1'", timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "chirp.styles.row.default").firstMatch.waitForExistence(timeout: 10), "Server styles did not load")

        // History's settings moved out of the list: the ⋯ menu deep-links to Settings → Privacy & history.
        app.selectChirpTab("History")
        app.buttons["chirp.history.menu"].tap()
        app.buttons["History settings"].tap()
        let history = element("chirp.history.enabled", in: app)
        XCTAssertTrue(history.waitForExistence(timeout: 5))
        // The row is one element: its centre is the label, so aim at the switch at its trailing edge.
        if history.value as? String != "1" { ChirpNotesUITests.flip(history) }
        XCTAssertTrue(waitFor(history, "value == '1'", timeout: 5))

        app.selectChirpTab("Dictate")
        app.buttons["chirp.dictation.start"].tap()
        allowSystemAlert()
        let stop = app.buttons["chirp.dictation.stop"]
        XCTAssertTrue(stop.waitForExistence(timeout: 15))
        let transcript = app.staticTexts["transcript"]
        XCTAssertTrue(waitFor(transcript, "label CONTAINS[c] 'design group'"), "Live partials never covered the whole sentence")
        screenshot("Live partial", app)
        stop.tap()
        let raw = app.buttons["chirp.dictation.raw"]
        XCTAssertTrue(raw.waitForExistence(timeout: 20), "Clean-up did not change the text: \(transcript.label)")
        XCTAssertTrue(transcript.label.localizedCaseInsensitiveContains("Tuesday"))
        XCTAssertFalse(transcript.label.localizedCaseInsensitiveContains("um,"), transcript.label)
        // "Cleaned." became "Polished." in the copy pass (#271 W9); accept both so the order the two land in doesn't matter.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label IN {'Cleaned. Copy or share when ready.', 'Polished. Copy or share when ready.'}")).firstMatch.exists)
        screenshot("Cleaned final", app)
        raw.tap()
        XCTAssertTrue(waitFor(transcript, "label CONTAINS[c] 'um,'", timeout: 3), transcript.label)
        XCTAssertTrue(app.staticTexts["Finished"].exists)

        app.selectChirpTab("History")
        let entry = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'design group'")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "History did not record the final")
        screenshot("History entry", app)

        endSession(app)
        app.selectChirpTab("Dictate")
        XCTAssertTrue(app.staticTexts["Microphone off"].waitForExistence(timeout: 5))
        XCTAssertFalse(transcript.exists)
    }

    @MainActor func dump(_ name: String, _ app: XCUIApplication) {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name; tree.lifetime = .keepAlways
        add(tree)
    }

    /// Each tab carries its own session bar; only the visible one is hittable.
    @MainActor func endSession(_ app: XCUIApplication) {
        let bar = app.buttons.matching(identifier: "chirp.session.end").allElementsBoundByIndex.first { $0.isHittable }
        bar?.tap()
    }

    /// Chirp owns the session; the real extension dictates into another app through the encrypted mailbox.
    @MainActor func testLiveKeyboardDictationInMessages() throws {
        let app = launch()
        try pairByDeepLink(app)
        try enableKeyboardInSettings()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let start = app.buttons["Start keyboard session"]
        for _ in 0..<3 where !start.waitForExistence(timeout: 3) { app.selectChirpTab("Dictate") }
        start.tap()
        allowSystemAlert()
        XCTAssertTrue(app.staticTexts["Ready"].waitForExistence(timeout: 15))

        let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
        messages.launch()
        defer { app.activate(); endSession(app); app.terminate(); messages.terminate() }
        // The simulator ships sample conversations; a draft in one is never sent.
        let conversation = messages.cells.firstMatch
        guard conversation.waitForExistence(timeout: 10) else { dump("Messages without conversations", messages); throw XCTSkip("Messages shows no conversation") }
        conversation.tap()
        let field = messages.descendants(matching: .any).matching(identifier: "messageBodyField").firstMatch
        guard field.waitForExistence(timeout: 10) else { dump("Messages compose", messages); throw XCTSkip("Messages exposes no message body field") }
        field.tap()
        // Typed first with Apple's keyboard: the dictation then continues a sentence, so "So" lands lower-case.
        // A previous test may have left Chirp Keyboard up; its globe key moves to the next (Apple's) keyboard.
        // On Face ID iPhones iOS draws its own globe below a custom keyboard ("Next keyboard").
        let globe = messages.buttons.matching(NSPredicate(format: "identifier == 'Next keyboard' OR label == 'Next keyboard' OR identifier == 'chirp.keyboard.globe'")).firstMatch
        // A letters keyboard: Emoji also has a space key, but a "letters" button and no globe.
        let letters = messages.buttons["letters"]
        func lettersUp() -> Bool { messages.keys["space"].waitForExistence(timeout: 3) && !letters.exists }
        for _ in 0..<4 where !lettersUp() {
            if letters.exists { letters.tap() } else if globe.exists { globe.tap() } else { break }
        }
        XCTAssertTrue(lettersUp(), "Apple's keyboard is needed to type the prefix")
        field.typeText("We met and ")
        let typed = field.value as? String ?? ""
        XCTAssertTrue(typed.hasSuffix("We met and "), typed)
        try selectChirpKeyboard(in: messages)
        let primary = messages.buttons["chirp.keyboard.primary"]
        guard chirpKeyboard(in: messages).waitForExistence(timeout: 10) else { dump("Messages keyboard", messages); XCTFail("Chirp Keyboard did not appear in Messages"); return }
        // Idle is the suggestion row with the small mic: no status text, the mic says what it does.
        XCTAssertTrue(waitFor(primary, "label == 'Start dictation'", timeout: 10), primary.label)
        screenshot("Keyboard armed in Messages", messages)
        primary.tap()
        XCTAssertTrue(waitFor(field, "value CONTAINS[c] 'design group'"), "Partial never reached Messages: \(String(describing: field.value))")
        screenshot("Keyboard partial in Messages", messages)
        primary.tap()
        XCTAssertTrue(waitFor(field, "value ENDSWITH 'design group.'"), String(describing: field.value))
        let expectedStart = typed + "so, um, schedule"
        XCTAssertTrue((field.value as? String ?? "").hasPrefix(expectedStart), "Mid-sentence casing: \(String(describing: field.value))")
        screenshot("Keyboard final in Messages", messages)
        // The final's row (Use raw, Undo) gives way to the idle row after a few seconds; ⋯ is there again then.
        let options = messages.buttons["chirp.keyboard.options"]
        XCTAssertTrue(options.waitForExistence(timeout: 15))
        options.tap()
        messages.buttons["chirp.keyboard.end"].tap()
        // No session any more: one compact message and "Open Chirp".
        let status = messages.staticTexts["chirp.keyboard.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(waitFor(status, "label != 'Ready'", timeout: 10), status.label)
    }

    /// Runs Chirp's App Shortcut from Spotlight, as a hardware-keyboard user would with ⌘Space or a Full
    /// Keyboard Access command: Toggle starts in the armed session without opening Chirp, Toggle again
    /// stops and copies, and ⌘V pastes the final into Messages.
    @MainActor func testLiveToggleShortcutFromSpotlightThenPaste() throws {
        let app = launch()
        pair(app)
        app.selectChirpTab("Dictate")
        app.buttons["Start keyboard session"].tap()
        allowSystemAlert()
        XCTAssertTrue(app.staticTexts["Ready"].waitForExistence(timeout: 15))
        let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
        defer { app.activate(); endSession(app); app.terminate(); messages.terminate() }

        try runToggleFromSpotlight(expecting: "Recording")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let activity = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'dictating' OR label CONTAINS[c] 'Chirp'")).firstMatch
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Home screen while toggled dictation runs"; shot.lifetime = .keepAlways
        add(shot)
        let activityEvidence = XCTAttachment(string: activity.exists ? activity.debugDescription : springboard.debugDescription)
        activityEvidence.name = "Live Activity element"; activityEvidence.lifetime = .keepAlways
        add(activityEvidence)
        XCTAssertFalse(app.state == .runningForeground, "Toggle must not bring Chirp forward in an armed session")
        sleep(7) // the synthetic sentence is about 5 s
        try runToggleFromSpotlight(expecting: "Copied")

        messages.launch()
        let conversation = messages.cells.firstMatch
        XCTAssertTrue(conversation.waitForExistence(timeout: 10))
        conversation.tap()
        let field = messages.descendants(matching: .any).matching(identifier: "messageBodyField").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        messages.typeKey("v", modifierFlags: .command)
        let allow = springboard.buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 2) { allow.tap() }
        XCTAssertTrue(waitFor(field, "value CONTAINS[c] 'design group'", timeout: 10), String(describing: field.value))
        screenshot("Toggle final pasted into Messages", messages)
    }

    @MainActor func runToggleFromSpotlight(expecting dialog: String) throws {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCUIDevice.shared.press(.home)
        let pill = springboard.descendants(matching: .any).matching(identifier: "spotlight-pill").firstMatch
        if pill.waitForExistence(timeout: 3) { pill.tap() } else {
            // iPad has no Search pill: Spotlight opens with a downward swipe from mid-screen.
            springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
                .press(forDuration: 0.05, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)))
        }
        let search = springboard.descendants(matching: .any).matching(NSPredicate(format: "(elementType == %d OR elementType == %d) AND hasKeyboardFocus == true", XCUIElement.ElementType.searchField.rawValue, XCUIElement.ElementType.textField.rawValue)).firstMatch
        guard search.waitForExistence(timeout: 5) else { dump("Spotlight", springboard); throw XCTSkip("Spotlight search did not open") }
        search.typeText("Toggle dictation")
        let action = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'Toggle dictation' OR label CONTAINS[c] 'Toggle Chirp dictation'")).firstMatch
        guard action.waitForExistence(timeout: 10) else { dump("Spotlight results", springboard); XCTFail("Spotlight shows no Chirp Toggle action"); return }
        action.tap()
        let result = springboard.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH[c] %@", dialog)).firstMatch
        if !result.waitForExistence(timeout: 15) { dump("Toggle result", springboard) }
        XCTAssertTrue(result.exists, "Toggle dialog did not say \(dialog)")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Toggle from Spotlight: \(dialog)"; shot.lifetime = .keepAlways
        add(shot)
        XCUIDevice.shared.press(.home)
    }

    /// An armed session shows Chirp's Live Activity on the lock screen with only its content-free phase.
    @MainActor func testLiveActivityOnLockScreen() throws {
        let app = launch()
        pair(app)
        app.selectChirpTab("Dictate")
        app.buttons["Start keyboard session"].tap()
        allowSystemAlert()
        XCTAssertTrue(app.staticTexts["Ready"].waitForExistence(timeout: 15))
        defer { app.activate(); endSession(app); app.terminate() }
        let lock = NSSelectorFromString("pressLockButton")
        guard XCUIDevice.shared.responds(to: lock) else { throw XCTSkip("This XCTest cannot lock the simulator") }
        XCUIDevice.shared.perform(lock)
        sleep(2)
        XCUIDevice.shared.press(.home) // wakes the display onto the lock screen without unlocking
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let phase = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Microphone active · idle audio discarded'")).firstMatch
        let found = phase.waitForExistence(timeout: 10)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Lock screen Live Activity"; shot.lifetime = .keepAlways
        add(shot)
        if !found { dump("Lock screen", springboard) }
        XCUIDevice.shared.press(.home)
        springboard.swipeUp()
        XCTAssertTrue(found, "Lock screen shows no Chirp Live Activity")
        XCTAssertFalse(springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] 'design group'")).firstMatch.exists)
    }

    /// Past one segment: about 50 s of speech, a pause where the microphone moves to a second utterance, then a
    /// closing sentence. The real keyboard lands both segments in order, joined by one space, with no repeats.
    @MainActor func testLiveLongDictationInMessages() throws {
        guard let long = ProcessInfo.processInfo.environment["CHIRP_LIVE_LONG_AUDIO"], !long.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_CHIRP_LIVE_LONG_AUDIO (ios/scripts/simulator-e2e.sh does).")
        }
        let app = launch(audio: long)
        pair(app)
        try enableKeyboardInSettings()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        let start = app.buttons["Start keyboard session"]
        for _ in 0..<3 where !start.waitForExistence(timeout: 3) { app.selectChirpTab("Dictate") }
        start.tap()
        allowSystemAlert()
        XCTAssertTrue(app.staticTexts["Ready"].waitForExistence(timeout: 15))
        let messages = XCUIApplication(bundleIdentifier: "com.apple.MobileSMS")
        messages.launch()
        defer { app.activate(); endSession(app); app.terminate(); messages.terminate() }
        let conversation = messages.cells.firstMatch
        XCTAssertTrue(conversation.waitForExistence(timeout: 10))
        conversation.tap()
        let field = messages.descendants(matching: .any).matching(identifier: "messageBodyField").firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        try selectChirpKeyboard(in: messages)
        let primary = messages.buttons["chirp.keyboard.primary"]
        XCTAssertTrue(primary.waitForExistence(timeout: 10))
        primary.tap()
        XCTAssertTrue(waitFor(field, "value CONTAINS[c] 'Friday afternoon'", timeout: 90),
                      "The second segment never reached Messages: \(String(describing: field.value))")
        screenshot("Long dictation, second segment live", messages)
        primary.tap()
        // The final's row (Finished · Use raw · Undo) lasts a few seconds, then the mic is back.
        XCTAssertTrue(waitFor(primary, "label == 'Start dictation'", timeout: 30))
        let value = field.value as? String ?? ""
        XCTAssertTrue(value.hasPrefix("Here is the plan"), value)
        XCTAssertTrue(value.contains("progress. Finally"), "Segments must join with exactly one space: \(value)")
        XCTAssertEqual(value.components(separatedBy: "Here is the plan").count, 2, "No segment may repeat: \(value)")
        screenshot("Long dictation final in Messages", messages)
    }
}
