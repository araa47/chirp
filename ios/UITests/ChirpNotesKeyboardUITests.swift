import XCTest

/// The Notes menu's keys and the dictation key on the Notes tab, with a hardware keyboard (synthetic capture and
/// server responses). ⌘N, ⌃⌥N, ⌘⇧R and ⌘⇧P are real key presses; Right ⌥ comes from the Debug seam, which feeds the
/// same matcher a real press does (XCUITest cannot press Right ⌥ on its own).
final class ChirpNotesKeyboardUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    override func tearDown() async throws { await MainActor.run { XCUIApplication().terminate() } }

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

    @MainActor func element(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    @MainActor func waitFor(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 10) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)], timeout: timeout) == .completed
    }

    @MainActor func screenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways
        add(shot)
    }

    @MainActor func seam(_ name: String) {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName("dev.chirp.ios.debug.hwkey.\(name)" as CFString), nil, nil, true)
        Thread.sleep(forTimeInterval: 0.4)
    }

    /// A press and release of the dictation key (Right ⌥, hold to talk): held past the 0.2 s arm delay.
    @MainActor func pressDictationKey() {
        seam("down"); Thread.sleep(forTimeInterval: 0.3); seam("up")
    }

    @MainActor func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--chirp-ui-test", "--chirp-skip-onboarding", "--chirp-hwkey-seam", "--chirp-hardware-keyboard",
                               "--chirp-notes-library-id", UUID().uuidString]
        app.launch()
        // The simulator attaches its hardware keyboard on the first synthesized key, which is lost.
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1.5)
        return app
    }

    /// ⌘N from another tab opens Notes with a blank note whose editor has the keyboard; ⌃⌥N from another tab records a
    /// new note; ⌘⇧P pauses and resumes; ⌘⇧R stops, and records into the note on screen.
    @MainActor func testNotesMenuKeysFromAnyTab() throws {
        let app = launch()
        app.selectChirpTab("History")
        app.typeKey("n", modifierFlags: .command)
        let editor = app.textViews["chirp.notes.editor"]
        guard editor.waitForExistence(timeout: 5) else {
            throw XCTSkip("Synthesized hardware key events do not reach the app: no hardware keyboard is connected to this simulator.")
        }
        XCTAssertTrue(waitFor(editor, "hasKeyboardFocus == true", timeout: 5), "⌘N's blank note must take the keyboard")
        editor.typeText("Typed on the hardware keyboard")
        XCTAssertTrue(waitFor(editor, "value CONTAINS 'Typed on the hardware keyboard'"))
        screenshot("⌘N from History: blank note, typing")

        app.selectChirpTab("Dictate")
        app.typeKey("n", modifierFlags: [.control, .option])
        let status = element("chirp.notes.status", app)
        XCTAssertTrue(waitFor(status, "label == 'Recording'"), "⌃⌥N did not start a new recording note from Dictate")
        XCTAssertTrue(waitFor(element("chirp.notes.partial", app), "label == 'synthetic words'"))
        app.typeKey("p", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitFor(status, "label BEGINSWITH 'Paused'"), "⌘⇧P did not pause")
        app.selectChirpTab("Settings")
        app.typeKey("p", modifierFlags: [.command, .shift])
        app.selectChirpTab("Notes")
        XCTAssertTrue(waitFor(status, "label == 'Recording'"), "⌘⇧P from Settings did not resume")
        app.typeKey("r", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitFor(status, "label == 'Stopped'"), "⌘⇧R did not stop")
        screenshot("⌃⌥N note stopped by ⌘⇧R")
        app.typeKey("r", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitFor(status, "label == 'Recording'"), "⌘⇧R did not record into the note on screen")
        XCTAssertTrue(app.buttons["chirp.notes.stop"].exists)
        app.typeKey("r", modifierFlags: [.command, .shift])
        XCTAssertTrue(waitFor(status, "label == 'Stopped'"))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == 'Continue recording'")).firstMatch.waitForExistence(timeout: 5),
                      "The note recorded twice must offer Continue recording")
    }

    /// On the Notes tab the dictation key drives Notes, as in the Mac's Notes window: a press records, the next pauses
    /// and the next resumes. With a field focused and nothing recording it still dictates into the field.
    @MainActor func testDictationKeyDrivesNotesOnTheNotesTab() throws {
        let app = launch()
        app.selectChirpTab("Notes")
        XCTAssertTrue(element("chirp.notes.library", app).waitForExistence(timeout: 10))
        pressDictationKey()
        let status = element("chirp.notes.status", app)
        XCTAssertTrue(waitFor(status, "label == 'Recording'"), "The dictation key on Notes did not record")
        XCTAssertFalse(app.staticTexts["sessionStatus"].exists, "The key must not open Dictate on the Notes tab")
        pressDictationKey()
        XCTAssertTrue(waitFor(status, "label BEGINSWITH 'Paused'"), "A second press did not pause")
        pressDictationKey()
        XCTAssertTrue(waitFor(status, "label == 'Recording'"), "A third press did not resume")
        screenshot("Dictation key: recording on Notes")
        app.buttons["chirp.notes.stop"].tap()
        XCTAssertTrue(waitFor(status, "label == 'Stopped'"))

        // Away from Notes the key dictates as before.
        app.selectChirpTab("History")
        pressDictationKey()
        XCTAssertTrue(app.staticTexts["sessionStatus"].waitForExistence(timeout: 5), "Away from Notes the key must open Dictate")
        app.endChirpSession()
    }
}
