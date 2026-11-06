import XCTest

/// Rotation mid-dictation, the app's Dictation menu shortcuts, and the Settings path where iPadOS lets a
/// key run Chirp's Toggle action from other apps. Synthetic transport; no server.
final class ChirpHardwareKeyboardUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    override func tearDown() { XCUIDevice.shared.orientation = .portrait }

    @MainActor func waitFor(_ element: XCUIElement, _ format: String, _ args: Any..., timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, argumentArray: args), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    @MainActor func screenshot(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor func pairedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--chirp-ui-test", "--chirp-skip-onboarding"]
        app.launch()
        app.pair(link: XCUIApplication.syntheticPairingLink)
        app.selectChirpTab("Dictate")
        return app
    }

    /// Rotating while listening keeps the utterance, its live text and the controls; it finishes normally.
    @MainActor func testRotationDuringDictationKeepsUtterance() {
        let app = pairedApp()
        let status = app.staticTexts["sessionStatus"], transcript = app.staticTexts["transcript"]
        app.buttons["chirp.dictation.start"].tap()
        XCTAssertTrue(waitFor(transcript, "label == 'synthetic words'"))
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait, .landscapeRight] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(waitFor(status, "label == 'Listening…'"), "Rotation to \(orientation.rawValue) must not end the utterance")
            XCTAssertEqual(transcript.label, "synthetic words")
            XCTAssertTrue(app.buttons["chirp.dictation.stop"].isHittable)
        }
        screenshot("Listening in landscape", app)
        app.buttons["chirp.dictation.stop"].tap()
        XCTAssertTrue(waitFor(transcript, "label == 'Synthetic words.'"))
        // A phone on its side once had the mic over the results row, so the tap below hit nothing (#238);
        // isHittable still said yes, so check the frames instead.
        let raw = app.buttons["chirp.dictation.raw"], mic = app.buttons["chirp.dictation.start"]
        XCTAssertTrue(raw.exists && mic.exists)
        XCTAssertFalse(raw.frame.intersects(mic.frame), "The mic must not cover Use raw: \(raw.frame) vs \(mic.frame)")
        raw.tap()
        XCTAssertTrue(waitFor(transcript, "label == 'synthetic words'"))
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitFor(status, "label == 'Finished'"))
        // An armed session keeps the app from going idle, which stalls tear-down until the test times out.
        app.endChirpSession()
        XCTAssertTrue(app.staticTexts["Microphone off"].waitForExistence(timeout: 5))
    }

    /// ⌘. cancels, ⌃⌥Z uses raw, ⌘⇧C copies, ⌘⇧E ends, ⌘⇧K arms, ⌘1–⌘4 switch tabs, then ⌘Return starts and stops.
    /// Needs the simulator's hardware keyboard, which attaches on the first synthesized key (that key is lost).
    /// XCUITest's synthesized Return and Esc never reach the app on the iPad simulator (⌘ and letter keys do, logged at
    /// `UIApplication.sendEvent`), so ⌘Return is checked last and skips with that reason; check it on a device.
    @MainActor func testDictationMenuShortcuts() throws {
        let app = pairedApp()
        app.typeKey(".", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1.5)
        let status = app.staticTexts["sessionStatus"], transcript = app.staticTexts["transcript"]
        let start = app.buttons["chirp.dictation.start"], stop = app.buttons["chirp.dictation.stop"]
        start.tap()
        XCTAssertTrue(waitFor(status, "label == 'Listening…'"))
        app.typeKey(".", modifierFlags: .command)
        guard waitFor(status, "label == 'Ready'", timeout: 3) else {
            throw XCTSkip("Synthesized hardware key events do not reach the app: no hardware keyboard is connected to this simulator.")
        }
        start.tap()
        XCTAssertTrue(waitFor(transcript, "label == 'synthetic words'"))
        stop.tap()
        XCTAssertTrue(waitFor(transcript, "label == 'Synthetic words.'"))
        app.typeKey("z", modifierFlags: [.control, .option])
        XCTAssertTrue(waitFor(transcript, "label == 'synthetic words'"), "⌃⌥Z did not use raw")
        app.typeKey("c", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitFor(app.staticTexts["sessionNotice"], "label == 'Copied.'"), "⌘⇧C did not copy")
        app.typeKey("e", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitFor(status, "label == 'Microphone off'"), "⌘⇧E did not end the session")
        app.typeKey("k", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitFor(status, "label == 'Ready'"), "⌘⇧K did not arm")
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.buttons["chirp.notes.record"].waitForExistence(timeout: 3), "⌘1 did not open Notes")
        app.typeKey("3", modifierFlags: .command)
        XCTAssertTrue(app.navigationBars["Dictation history"].waitForExistence(timeout: 3), "⌘3 did not open History")
        app.typeKey("2", modifierFlags: .command)
        XCTAssertTrue(waitFor(status, "label == 'Ready'"), "⌘2 did not open Dictate")
        app.typeKey(.return, modifierFlags: .command)
        guard waitFor(status, "label == 'Listening…'") else {
            app.endChirpSession()
            throw XCTSkip("⌘Return: XCUITest's synthesized Return does not reach the app on this simulator; check it with a real keyboard.")
        }
        app.typeKey(.return, modifierFlags: .command)
        XCTAssertTrue(waitFor(transcript, "label == 'Synthetic words.'"), "⌘Return did not stop dictation")
        app.endChirpSession()
    }

    /// The README and in-app help send iPad users to Full Keyboard Access → Commands to give their Toggle
    /// shortcut a key. iOS lists Shortcuts-app shortcuts there once one exists; this checks the path.
    @MainActor func testFullKeyboardAccessCommandsPath() throws {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.terminate()
        settings.launch()
        defer { settings.terminate() }
        try tapSettings("Accessibility", in: settings)
        let keyboards = ["Keyboards & Typing", "Keyboards"].map { settingsItem($0, in: settings) }.first { $0.waitForExistence(timeout: 3) }
        guard let keyboards else { throw XCTSkip("Accessibility has no Keyboards row on this OS") }
        let keyboardsLabel = keyboards.label
        keyboards.tap()
        try tapSettings("Full Keyboard Access", in: settings)
        try tapSettings("Commands", in: settings)
        let hint = settings.descendants(matching: .any).matching(NSPredicate(format: "label == 'Tap any command to customize its keyboard shortcut.'")).firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 5), "Commands page did not open")
        let path = XCTAttachment(string: "Accessibility → \(keyboardsLabel) → Full Keyboard Access → Commands")
        path.name = "Verified Settings path"; path.lifetime = .keepAlways
        add(path)
        print("CHIRP-FKA-PATH Accessibility → \(keyboardsLabel) → Full Keyboard Access → Commands")
    }
}
