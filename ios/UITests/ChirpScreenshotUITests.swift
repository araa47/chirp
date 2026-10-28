import XCTest

/// The README/PR screenshots of the Pond shell (#192), as `keepAlways` attachments: onboarding, Dictate idle,
/// listening and finished (and finished on its side, on iPhone), the session capsule, Notes with the setup card and, on
/// iPad, the sidebar states.
/// Synthetic text only. Runs only with `TEST_RUNNER_CHIRP_SCREENSHOTS=1`; set the appearance and text size with
/// `simctl ui` first. `TEST_RUNNER_CHIRP_SCREENSHOT_ARGS` adds launch arguments (`--chirp-reduce-motion`).
final class ChirpScreenshotUITests: XCTestCase {
    private var extra: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = true
        let env = ProcessInfo.processInfo.environment
        guard env["CHIRP_SCREENSHOTS"] == "1" else { throw XCTSkip("Screenshot run only: set TEST_RUNNER_CHIRP_SCREENSHOTS=1.") }
        extra = (env["CHIRP_SCREENSHOT_ARGS"] ?? "").split(separator: " ").map(String.init)
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor func shot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func waitFor(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 5) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)], timeout: timeout) == .completed
    }

    @MainActor func testCaptureShell() {
        let app = XCUIApplication()
        app.launchArguments = ["--chirp-ui-test", "--chirp-onboarding", "--chirp-setup-card", "--chirp-hardware-keyboard"] + extra
        app.launch()
        let next = app.buttons["chirp.onboarding.next"], skip = app.buttons["chirp.onboarding.skip"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        shot("onboarding-1-welcome", app)
        next.tap()
        XCTAssertTrue(app.buttons["chirp.pair.scan"].waitForExistence(timeout: 5))
        shot("onboarding-2-pair", app)
        let field = app.pairingLinkField()
        field.tap()
        field.typeText(XCUIApplication.syntheticPairingLink + "\n")
        XCTAssertTrue(app.descendants(matching: .any)["chirp.pair.connected"].waitForExistence(timeout: 5))
        shot("onboarding-2-pair-connected", app)
        next.tap()
        XCTAssertTrue(app.staticTexts["Allow the microphone"].waitForExistence(timeout: 5))
        shot("onboarding-3-microphone", app)
        skip.tap()
        XCTAssertTrue(app.staticTexts["Turn on Chirp Keyboard"].waitForExistence(timeout: 5))
        shot("onboarding-4-keyboard", app)
        skip.tap()

        XCTAssertTrue(app.buttons["chirp.notes.record"].waitForExistence(timeout: 5))
        shot("notes-setup-card", app)

        app.selectChirpTab("Dictate")
        let status = app.staticTexts["sessionStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        shot("dictate-idle", app)
        app.buttons["chirp.dictation.start"].tap()
        XCTAssertTrue(waitFor(app.staticTexts["transcript"], "label == 'synthetic words'"))
        sleep(1)
        shot("dictate-listening", app)
        app.buttons["chirp.dictation.stop"].tap()
        XCTAssertTrue(app.buttons["chirp.dictation.raw"].waitForExistence(timeout: 5))
        shot("dictate-finished", app)
        if UIDevice.current.userInterfaceIdiom == .phone {
            // On its side the phone keeps the results row beside the mic (#238).
            XCUIDevice.shared.orientation = .landscapeLeft
            sleep(2)
            shot("dictate-finished-landscape", app)
            XCUIDevice.shared.orientation = .portrait
            sleep(1)
        }
        app.selectChirpTab("History")
        XCTAssertTrue(app.buttons["chirp.session.end"].waitForExistence(timeout: 5))
        shot("session-capsule", app)
        app.selectChirpTab("Dictate")
        app.endChirpSession()
        XCTAssertTrue(waitFor(status, "label == 'Microphone off'"))

        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        shot("ipad-sidebar-dictate", app)
        // Collapse the sidebar: the system's toggle sits in the navigation bar.
        let toggle = app.buttons.matching(NSPredicate(format: "label IN {'Hide Sidebar', 'Sidebar', 'Toggle Sidebar'} OR identifier == 'ToggleSidebar'")).firstMatch
        if toggle.waitForExistence(timeout: 3) {
            toggle.tap()
            sleep(1)
            shot("ipad-sidebar-collapsed", app)
            let show = app.buttons.matching(NSPredicate(format: "label IN {'Show Sidebar', 'Sidebar', 'Toggle Sidebar'} OR identifier == 'ToggleSidebar'")).firstMatch
            if show.exists { show.tap() }
        } else {
            XCTFail("No sidebar toggle found:\n\(app.debugDescription)")
        }
        XCUIDevice.shared.orientation = .portrait
    }
}
