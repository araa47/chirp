import XCTest

/// The hardware-keyboard dictation shortcut (#259) on the synthetic transport. XCUITest's held modifiers arrive as real
/// `UIPress`es (the `testRealKeys…` tests), but it can only hold the left ones and cannot press Right ⌥ on its own, so
/// the default shortcut's down/up come from the Debug seam (`--chirp-hwkey-seam`), which feeds the same matcher a
/// real press does. Matching rules are unit-tested.
final class ChirpHardwareShortcutUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// Every failure carries the screen and the tree it happened on.
    override func record(_ issue: XCTIssue) {
        var issue = issue
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Failure screen"; shot.lifetime = .keepAlways
        issue.add(shot)
        let tree = XCTAttachment(string: XCUIApplication().debugDescription)
        tree.name = "Failure hierarchy"; tree.lifetime = .keepAlways
        issue.add(tree)
        super.record(issue)
    }

    @MainActor func waitFor(_ element: XCUIElement, _ format: String, _ args: Any..., timeout: TimeInterval = 8) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, argumentArray: args), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor func screenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways
        add(shot)
    }

    /// Presses or lets go through the Debug seam: a Darwin notification the app turns into a key press.
    @MainActor func seam(_ name: String, _ app: XCUIApplication) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName("dev.chirp.ios.debug.hwkey.\(name)" as CFString), nil, nil, true)
        Thread.sleep(forTimeInterval: 0.3)
    }

    @MainActor func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--chirp-ui-test", "--chirp-skip-onboarding", "--chirp-hwkey-seam", "--chirp-hardware-keyboard"] + extra
        app.launch()
        return app
    }

    /// No field has focus: holding Right ⌥ opens Dictate and listens; letting go finishes there. Esc cancels.
    @MainActor func testHoldRightOptionDictatesOnDictate() {
        let app = launch()
        app.pair(link: XCUIApplication.syntheticPairingLink)
        app.selectChirpTab("History")
        seam("down", app)
        let status = app.staticTexts["sessionStatus"], transcript = app.staticTexts["transcript"]
        XCTAssertTrue(waitFor(status, "label == 'Listening…'"), "Holding Right ⌥ did not start dictation on Dictate")
        XCTAssertTrue(waitFor(transcript, "label == 'synthetic words'"))
        // The keys hint is under the mic at regular width (iPad) only; a phone has no room for it.
        if app.windows.firstMatch.horizontalSizeClass == .regular {
            XCTAssertTrue(app.staticTexts["chirp.dictation.shortcutsHint"].label.hasPrefix("Hold Right ⌥ Option"))
        } else {
            XCTAssertFalse(app.staticTexts["chirp.dictation.shortcutsHint"].exists)
        }
        screenshot("Shortcut listening on Dictate")
        seam("up", app)
        XCTAssertTrue(waitFor(transcript, "label == 'Synthetic words.'"), "Letting go did not finish")
        XCTAssertTrue(waitFor(status, "label == 'Finished'"))

        seam("down", app)
        XCTAssertTrue(waitFor(status, "label == 'Listening…'"))
        seam("escape", app)
        XCTAssertTrue(waitFor(status, "label == 'Ready'"), "Esc did not cancel")
        seam("up", app)
        XCTAssertTrue(waitFor(status, "label == 'Ready'"), "Letting go after Esc must not start or finish anything")
        app.endChirpSession()
    }

    /// A focused field: the listening bar shows while held, and letting go types the text at the caret.
    @MainActor func testHoldRightOptionInsertsIntoFocusedField() {
        let app = launch(["--chirp-keyboard-host", "--chirp-keyboard-host-focus"])
        XCTAssertTrue(app.staticTexts["chirp.host.setup"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitFor(app.staticTexts["chirp.host.setup"], "label == 'Synthetic shared session armed'", timeout: 15))
        let text = app.textViews["chirp.host.text"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        text.tap()
        seam("down", app)
        let bar = app.descendants(matching: .any)["chirp.hwkey.listening"]
        XCTAssertTrue(bar.waitForExistence(timeout: 8), "The listening bar did not show over the field")
        screenshot("Shortcut listening over a field")
        seam("up", app)
        XCTAssertTrue(waitFor(text, "value == 'Host prefix. Synthetic words.'", timeout: 10),
                      "Expected the final at the caret, got \(text.value ?? "nil")")
        XCTAssertFalse(bar.exists)
        app.buttons["chirp.host.end"].tap()
    }

    /// Settings → Dictation → Keyboard shortcut: record Right ⌘, switch to toggle, then Off; light and dark screenshots.
    @MainActor func testSettingsRecorderModeAndOff() {
        let app = launch()
        app.openDictation()
        let link = app.buttons["chirp.settings.hardwareShortcut"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        if !link.isHittable { app.swipeUp() }
        link.tap()
        let record = app.buttons["chirp.hwkey.record"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        XCTAssertEqual(record.label, "Right ⌥ Option")
        record.tap()
        XCTAssertTrue(waitFor(record, "label == 'Press the keys…'"))
        screenshot("Recorder waiting for keys")
        seam("rightCommand", app)
        XCTAssertTrue(waitFor(record, "label == 'Right ⌘ Command'"), "The recorder did not take Right ⌘")
        XCTAssertTrue(app.buttons["chirp.hwkey.reset"].exists)

        let toggle = app.buttons["Press to start and stop"]
        if toggle.waitForExistence(timeout: 3) { toggle.tap() } else {
            app.buttons["chirp.hwkey.mode"].tap()
            app.buttons["Press to start and stop"].firstMatch.tap()
        }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Press Right ⌘ Command to dictate.'")).firstMatch
            .waitForExistence(timeout: 5))
        app.buttons["chirp.hwkey.reset"].tap()
        XCTAssertTrue(waitFor(record, "label == 'Right ⌥ Option'"))

        let enabled = app.switches["chirp.hwkey.enabled"]
        enabled.switches.firstMatch.exists ? enabled.switches.firstMatch.tap() : enabled.tap()
        XCTAssertTrue(waitFor(enabled, "value == '0'"))
        XCTAssertFalse(record.exists)
        XCTAssertTrue(app.staticTexts["Off"].waitForExistence(timeout: 5), "The switch row does not say Off")
    }

    /// Set up a dictation key: Dictate offers it once with a hardware keyboard; the sheet's live check sees Toggle start
    /// (no session needed) and stop, and the test field takes the text. Closing the offer hides it for good.
    @MainActor func testDictationKeySetup() {
        let name = ProcessInfo.processInfo.environment["CHIRP_HWKEY_APPEARANCE"] ?? "light"
        let app = launch(["--chirp-dictation-key-offer"])
        app.pair(link: XCUIApplication.syntheticPairingLink)
        app.selectChirpTab("Dictate")
        let offer = app.buttons["chirp.dictationKey.offer.open"]
        XCTAssertTrue(offer.waitForExistence(timeout: 5), "Dictate did not offer a dictation key with a hardware keyboard")
        screenshot("Dictation key offer on Dictate, \(name)")
        offer.tap()
        let status = app.descendants(matching: .any)["chirp.dictationKey.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["chirp.dictationKey.shortcuts"].exists && app.buttons["chirp.dictationKey.settings"].exists)
        sleep(1)
        screenshot("Set up a dictation key, \(name)")
        seam("toggle", app)
        XCTAssertTrue(waitFor(status, "label BEGINSWITH 'Your key works.'"), "Toggle without a session did not start: \(status.label)")
        seam("toggle", app)
        XCTAssertTrue(waitFor(status, "label == 'Copied. Press ⌘V in the field below.'", timeout: 10), "Toggle did not stop and copy: \(status.label)")
        let field = app.descendants(matching: .any)["chirp.dictationKey.field"]
        field.tap()
        field.typeText("Synthetic words.")
        XCTAssertTrue(waitFor(status, "label == 'All set. Your key works in any app.'"))
        screenshot("Dictation key works, \(name)")
        app.buttons["chirp.dictationKey.done"].tap()
        XCTAssertFalse(app.buttons["chirp.dictationKey.offer.open"].waitForExistence(timeout: 2), "The offer stays after the key worked")
        app.endChirpSession()
    }

    /// Closing the offer hides it for good; Settings → Dictation → Keyboard shortcut still opens the setup.
    @MainActor func testDictationKeyOfferDismissAndSettingsEntry() {
        let app = launch(["--chirp-dictation-key-offer"])
        app.pair(link: XCUIApplication.syntheticPairingLink)
        app.selectChirpTab("Dictate")
        let dismiss = app.buttons["chirp.dictationKey.offer.dismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
        dismiss.tap()
        XCTAssertFalse(app.buttons["chirp.dictationKey.offer.open"].waitForExistence(timeout: 2))
        app.openDictation()
        let link = app.buttons["chirp.settings.hardwareShortcut"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        if !link.isHittable { app.swipeUp() }
        link.tap()
        let setup = app.buttons["chirp.hwkey.setupKey"]
        XCTAssertTrue(setup.waitForExistence(timeout: 5))
        if !setup.isHittable { app.swipeUp() }
        setup.tap()
        XCTAssertTrue(app.descendants(matching: .any)["chirp.dictationKey.status"].waitForExistence(timeout: 5))
        app.buttons["chirp.dictationKey.done"].tap()
        app.selectChirpTab("Dictate")
        XCTAssertFalse(app.buttons["chirp.dictationKey.offer.open"].exists, "A closed offer came back")
    }

    /// The floating bubble: Dictate shows it (starting a session), it stays up over the Home Screen as a Picture in
    /// Picture window, and Hide closes it. Its play/pause button belongs to the system's PiP window, which UI tests
    /// can't press; its toggle is the same `perform(.toggle)` the other tests cover.
    @MainActor func testFloatingBubbleShowsOverOtherApps() {
        let name = ProcessInfo.processInfo.environment["CHIRP_HWKEY_APPEARANCE"] ?? "light"
        let app = launch()
        app.pair(link: XCUIApplication.syntheticPairingLink)
        app.selectChirpTab("Dictate")
        let toggle = app.buttons["chirp.bubble.toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "Dictate has no floating bubble control")
        toggle.tap()
        XCTAssertTrue(waitFor(toggle, "label == 'Hide floating mic'", timeout: 15),
                      "The bubble did not start: \(app.staticTexts["chirp.bubble.failure"].exists ? app.staticTexts["chirp.bubble.failure"].label : toggle.label)")
        XCTAssertTrue(waitFor(app.staticTexts["sessionStatus"], "label == 'Ready'"), "Showing the bubble starts a session")
        XCUIDevice.shared.press(.home)
        sleep(7) // the system's controls fade: the resting pill
        screenshot("Floating mic over the Home Screen, \(name)")
        // Record from the window, as a person would: tap it for the system's button, press it; again to stop.
        let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let window = sb.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'PIP-SBInteractionPassThroughView'")).firstMatch
        let press = { () -> Bool in
            let button = sb.buttons.matching(NSPredicate(format: "label ==[c] 'Stop' OR label ==[c] 'Pause' OR label ==[c] 'Play'")).firstMatch
            if !button.exists, window.exists { window.tap(); sleep(1) }
            let labels = sb.buttons.allElementsBoundByIndex.filter { $0.frame.intersects(window.frame) }.map { "\($0.identifier)|\($0.label)" }
            print("CHIRP-PIP buttons over the window: \(labels)")
            guard button.waitForExistence(timeout: 3) else { return false }
            button.tap(); return true
        }
        if press() {
            sleep(7)
            screenshot("Floating mic listening, \(name)")
            XCTAssertTrue(press(), "No system button to stop with")
            sleep(5)
            screenshot("Floating mic after stop, \(name)")
        }
        app.activate()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        if toggle.label == "Hide floating mic" { toggle.tap() }
        XCTAssertTrue(waitFor(toggle, "label == 'Floating mic'", timeout: 10), "Hide did not close the bubble")
        app.endChirpSession()
    }

    /// How big iPadOS makes the floating mic's window for each content shape (it picks the size; the app picks the shape).
    @MainActor func testFloatingMicWindowSizes() throws {
        guard ProcessInfo.processInfo.environment["CHIRP_BUBBLE_SIZES"] == "1" else {
            throw XCTSkip("Measurement run only: set TEST_RUNNER_CHIRP_BUBBLE_SIZES=1 (about 3 minutes).")
        }
        for size in ["320x320", "480x240", "600x200", "640x160", "720x120", "200x400"] {
            let app = launch(["--chirp-bubble-size", size])
            app.pair(link: XCUIApplication.syntheticPairingLink)
            app.selectChirpTab("Dictate")
            let toggle = app.buttons["chirp.bubble.toggle"]
            guard toggle.waitForExistence(timeout: 5) else { continue }
            toggle.tap()
            if !waitFor(toggle, "label == 'Hide floating mic'", timeout: 6) { toggle.tap(); _ = waitFor(toggle, "label == 'Hide floating mic'", timeout: 10) }
            XCUIDevice.shared.press(.home); sleep(3)
            let sb = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let window = sb.descendants(matching: .any).matching(NSPredicate(format: "identifier == 'PIP-SBInteractionPassThroughView'")).firstMatch
            print("CHIRP-SIZE content=\(size) window=\(window.exists ? NSCoder.string(for: window.frame) : "none")")
            screenshot("Floating mic \(size)")
            app.activate()
            if toggle.waitForExistence(timeout: 5), toggle.label == "Hide floating mic" { toggle.tap(); sleep(1) }
            app.endChirpSession()
            app.terminate()
        }
    }

    /// iPad evidence: the settings page and Dictate listening to a held Right ⌥. Run once per appearance with the
    /// simulator set beforehand (`simctl ui UUID appearance dark` plus `TEST_RUNNER_CHIRP_HWKEY_APPEARANCE=dark`), so
    /// no crossfade is captured.
    @MainActor func testScreenshots() {
        let name = ProcessInfo.processInfo.environment["CHIRP_HWKEY_APPEARANCE"] ?? "light"
        let app = launch()
        app.pair(link: XCUIApplication.syntheticPairingLink)
        app.openDictation()
        let link = app.buttons["chirp.settings.hardwareShortcut"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        if !link.isHittable { app.swipeUp() }
        link.tap()
        XCTAssertTrue(app.buttons["chirp.hwkey.record"].waitForExistence(timeout: 5))
        sleep(1)
        screenshot("Keyboard shortcut settings, \(name)")
        app.selectChirpTab("History")
        seam("down", app)
        XCTAssertTrue(waitFor(app.staticTexts["transcript"], "label == 'synthetic words'"))
        screenshot("Holding Right ⌥ on Dictate, \(name)")
        seam("up", app)
        XCTAssertTrue(waitFor(app.staticTexts["transcript"], "label == 'Synthetic words.'"))
        app.endChirpSession()
    }

    // MARK: Real key events

    /// Settings → Dictation → Keyboard shortcut, with the recorder listening.
    @MainActor func openRecorder(_ app: XCUIApplication) -> XCUIElement {
        app.openDictation()
        let link = app.buttons["chirp.settings.hardwareShortcut"]
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        if !link.isHittable { app.swipeUp() }
        link.tap()
        let record = app.buttons["chirp.hwkey.record"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        record.tap()
        XCTAssertTrue(waitFor(record, "label == 'Press the keys…'"))
        return record
    }

    /// Synthesized keys reach the app as `UIPress`es once the simulator has a keyboard; the first one after launch
    /// can be lost while it connects, so press ⇧ once and check that a real ⌥ press is seen at all.
    @MainActor func requireKeyEvents(_ record: XCUIElement) throws {
        var seen = false
        for _ in 0..<3 where !seen {
            Thread.sleep(forTimeInterval: 1.5)
            XCUIElement.perform(withKeyModifiers: .option) { Thread.sleep(forTimeInterval: 0.3) }
            seen = waitFor(record, "label == 'Left ⌥ Option'", timeout: 3)
        }
        guard seen else {
            throw XCTSkip("Synthesized hardware key events do not reach the app on this simulator.")
        }
    }

    /// The simulator attaches its hardware keyboard on the first synthesized `typeKey` (a held modifier alone does
    /// not), which is lost, and needs a moment after. Esc right after launch has nothing to cancel.
    @MainActor func attachKeyboard(_ app: XCUIApplication) {
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1.5)
    }

    /// Real presses: the recorder takes ⌥ on its own (XCUITest presses the left one), and as a press-to-start-and-stop
    /// key a clean ⌥ tap starts and the next one finishes; ⌥← is a chord and never starts one. XCUITest cannot hold a
    /// modifier for a set time, so hold timing is covered by the seam test and the unit tests.
    @MainActor func testRealKeysRecordAndTapOption() throws {
        let app = launch()
        attachKeyboard(app)
        app.pair(link: XCUIApplication.syntheticPairingLink)
        let record = openRecorder(app)
        try requireKeyEvents(record)
        selectMode("Press to start and stop", app)
        app.selectChirpTab("History")
        let status = app.staticTexts["sessionStatus"], transcript = app.staticTexts["transcript"]
        XCUIElement.perform(withKeyModifiers: .option) { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertTrue(waitFor(status, "label == 'Listening…'"), "A ⌥ tap did not start dictation")
        XCTAssertTrue(waitFor(transcript, "label == 'synthetic words'"))
        XCUIElement.perform(withKeyModifiers: .option) { Thread.sleep(forTimeInterval: 0.1) }
        XCTAssertTrue(waitFor(transcript, "label == 'Synthetic words.'"), "A second ⌥ tap did not finish")
        app.typeKey(XCUIKeyboardKey.leftArrow.rawValue, modifierFlags: .option)
        sleep(1)
        XCTAssertTrue(waitFor(status, "label == 'Finished'"), "⌥← must not start dictation")
        app.endChirpSession()
    }

    @MainActor func selectMode(_ title: String, _ app: XCUIApplication) {
        let chip = app.buttons[title]
        XCTAssertTrue(chip.waitForExistence(timeout: 5), "No \(title) chip")
        chip.tap()
    }

    /// Real presses: ⌥Space recorded and set to press-to-start-and-stop; each ⌥Space toggles, and plain Space is not it.
    @MainActor func testRealKeysOptionSpaceToggle() throws {
        let app = launch()
        attachKeyboard(app)
        app.pair(link: XCUIApplication.syntheticPairingLink)
        let record = openRecorder(app)
        try requireKeyEvents(record)
        record.tap()
        XCTAssertTrue(waitFor(record, "label == 'Press the keys…'"))
        app.typeKey(" ", modifierFlags: .option)
        XCTAssertTrue(waitFor(record, "label == '⌥Space'"), "The recorder did not take ⌥Space")
        selectMode("Press to start and stop", app)
        app.selectChirpTab("History")
        let status = app.staticTexts["sessionStatus"], transcript = app.staticTexts["transcript"]
        app.typeKey(" ", modifierFlags: .option)
        XCTAssertTrue(waitFor(status, "label == 'Listening…'"), "⌥Space did not start dictation")
        XCTAssertTrue(waitFor(transcript, "label == 'synthetic words'"))
        app.typeKey(" ", modifierFlags: .option)
        XCTAssertTrue(waitFor(transcript, "label == 'Synthetic words.'"), "⌥Space again did not finish")
        app.endChirpSession()
    }
}
