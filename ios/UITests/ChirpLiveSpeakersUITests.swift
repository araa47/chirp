import XCTest

/// Live Notes speaker labels end to end against a real local chirp-server and its real WeSpeaker model
/// (`ios/scripts/simulator-e2e.sh`, `e2e-all.sh --only speakers`): two synthetic voices (macOS `say`, Samantha then
/// Daniel, looped like a meeting) through `--chirp-sim-audio` and the rolling `/v1/stream` sockets. Labels are on by
/// default: it never touches the switch, waits for the server's own automatic model download to reach "ready" (no
/// consent alert), then requires exactly two people in the transcript, a rename from a chip that lands on every segment, and the replay of a labelled kept-audio segment.
/// Skipped unless the runner passes CHIRP_LIVE_LINK and CHIRP_LIVE_SPEAKERS_AUDIO. Reads state and counts, never text.
final class ChirpLiveSpeakersUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard env["CHIRP_LIVE_LINK"]?.isEmpty == false, env["CHIRP_LIVE_SPEAKERS_AUDIO"]?.isEmpty == false else {
            throw XCTSkip("Live server run only: set TEST_RUNNER_CHIRP_LIVE_LINK and TEST_RUNNER_CHIRP_LIVE_SPEAKERS_AUDIO.")
        }
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor func screenshot(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways
        add(shot)
    }

    /// The people the transcript shows now, one label per chip.
    @MainActor func chips(_ app: XCUIApplication) -> [String] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chirp.notes.speaker.chip.'")).allElementsBoundByIndex.map(\.label)
    }

    /// Each live method starts with an empty server library so test order never changes the expected chips.
    @MainActor private func resetSavedVoicesInSettings(_ app: XCUIApplication) {
        let open = ChirpNotesUITests.element("chirp.notes.voices.open", in: app)
        for _ in 0..<6 where !open.isHittable { app.swipeUp() }
        XCTAssertTrue(open.isHittable); open.tap()
        let enabled = ChirpNotesUITests.element("chirp.notes.voices.enabled", in: app)
        XCTAssertTrue(enabled.waitForExistence(timeout: 15))
        if enabled.value as? String != "1" { ChirpNotesUITests.flip(enabled) }
        let forget = app.buttons["chirp.notes.voices.forgetAll"]
        if forget.exists { forget.tap(); app.buttons["Forget"].firstMatch.tap() }
        XCTAssertTrue(ChirpNotesUITests.element("chirp.notes.voices.empty", in: app).waitForExistence(timeout: 15))
        app.tapBack()
    }

    /// The Notes settings form builds only the rows on screen, and kept audio from earlier notes adds rows above the
    /// speaker section: scroll the sheet until the element is in the tree.
    @MainActor private func scrollSheet(to element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !element.exists { app.swipeUp(velocity: .slow) }
    }

    @MainActor func testTwoVoicesAreTwoPeopleRenamedEverywhereWithReplay() {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchArguments = ["--chirp-sim-audio", env["CHIRP_LIVE_SPEAKERS_AUDIO"]!, "--chirp-skip-onboarding"]
        app.launch()
        app.openConnection()
        app.endChirpSession()
        let field = app.pairingLinkField()
        field.tap(); field.typeText(env["CHIRP_LIVE_LINK"]!)
        app.buttons["chirp.pair.submit"].tap()
        XCTAssertTrue(ChirpNotesUITests.element("chirp.connection.banner", in: app).waitForExistence(timeout: 15))

        ChirpNotesUITests.openNotes(app)
        app.buttons["chirp.notes.menu"].tap()
        app.buttons["chirp.notes.settings"].tap()
        let keepAudio = ChirpNotesUITests.element("chirp.notes.keepAudio", in: app)
        XCTAssertTrue(keepAudio.waitForExistence(timeout: 5))
        if keepAudio.value as? String != "1" { ChirpNotesUITests.flipInSheet(keepAudio, in: app) }

        // Labels are on by default and the Mac has no speaker model yet: no switch to flip and no consent. The phone
        // asks the Mac for its one pinned download itself; Settings follows it until the model is ready.
        let toggle = ChirpNotesUITests.element("chirp.notes.speakers.setting", in: app)
        scrollSheet(to: toggle, in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10)); XCTAssertEqual(toggle.value as? String, "1", "Labels must be on by default")
        XCTAssertFalse(app.alerts.firstMatch.exists, "The download starts without a prompt")
        screenshot("Speakers on by default on the live server", app)
        let model = ChirpNotesUITests.element("chirp.notes.speakers.model", in: app)
        scrollSheet(to: model, in: app)
        XCTAssertTrue(ChirpNotesUITests.waitFor(model, "label == 'Speaker model on your computer: ready'", timeout: 240),
                      "The automatic download never made the model ready: \(model.exists ? model.label : "no status")")
        screenshot("Speakers model ready on the live server", app)
        resetSavedVoicesInSettings(app)
        app.buttons["Done"].tap()

        let record = app.buttons["chirp.notes.record"]
        XCTAssertTrue(ChirpNotesUITests.waitFor(record, "isEnabled == true", timeout: 10))
        record.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "OK"] where springboard.alerts.buttons[label].waitForExistence(timeout: 1) { springboard.alerts.buttons[label].tap() }
        let status = ChirpNotesUITests.element("chirp.notes.status", in: app)
        XCTAssertTrue(ChirpNotesUITests.waitFor(status, "label == 'Recording'", timeout: 20), status.label)
        // The asset plays once at real-time pace (about 40 s), then silence.
        sleep(50)
        app.buttons["chirp.notes.stop"].tap()
        XCTAssertTrue(ChirpNotesUITests.waitFor(status, "label == 'Stopped'", timeout: 90), status.label)

        app.buttons["chirp.notes.transcript.open"].tap()
        let transcript = ChirpNotesUITests.element("chirp.notes.transcript", in: app)
        XCTAssertTrue(transcript.waitForExistence(timeout: 10))
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chirp.notes.speaker.chip.'")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 30), "No speaker chip in the transcript")
        let people = Set(chips(app))
        XCTAssertEqual(people, ["Person 1", "Person 2"], "Two voices must be exactly two people: \(people)")
        screenshot("Speakers two people from the live server", app)

        // Rename Person 2 from a chip: the new name replaces it on every segment.
        let two = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chirp.notes.speaker.chip.' AND label == 'Person 2'")).firstMatch
        two.tap()
        app.buttons["chirp.notes.speaker.rename"].tap()
        let name = app.textFields["chirp.notes.speaker.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Maya")
        app.buttons["chirp.notes.speaker.confirm"].tap()
        XCTAssertTrue(ChirpNotesUITests.waitFor(first, "label == 'Person 1' OR label == 'Maya'", timeout: 10))
        XCTAssertEqual(Set(chips(app)), ["Person 1", "Maya"], "The rename must reach every segment")
        if app.alerts["Remembering voices"].waitForExistence(timeout: 2) { app.alerts.buttons["OK"].tap() }
        screenshot("Speakers renamed on the live server", app)

        // Kept audio still replays per segment in a labelled transcript.
        let play = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chirp.notes.play.'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10), "No kept audio to replay in the labelled transcript")
        play.tap()
        XCTAssertTrue(ChirpNotesUITests.waitFor(play, "label == 'Stop replay'", timeout: 10))
    }
    /// A fresh note session proves that the voice lives on the throwaway server, rather than in the first note's roster.
    @MainActor func testNamingRemembersAndRecognisesInANewNote() throws {
        let env = ProcessInfo.processInfo.environment
        guard let audio = env["CHIRP_LIVE_VOICES_AUDIO"], let duration = env["CHIRP_LIVE_VOICES_DURATION"].flatMap(Double.init) else {
            throw XCTSkip("Two-note live run needs the longer saved-voices fixture")
        }
        let app = XCUIApplication()
        app.launchArguments = ["--chirp-sim-audio", audio, "--chirp-skip-onboarding"]
        app.launch(); app.openConnection(); app.endChirpSession()
        let field = app.pairingLinkField(); field.tap(); field.typeText(env["CHIRP_LIVE_LINK"]!)
        app.buttons["chirp.pair.submit"].tap()
        XCTAssertTrue(ChirpNotesUITests.element("chirp.connection.banner", in: app).waitForExistence(timeout: 15))
        ChirpNotesUITests.openNotes(app)
        app.buttons["chirp.notes.menu"].tap(); app.buttons["chirp.notes.settings"].tap()
        let model = ChirpNotesUITests.element("chirp.notes.speakers.model", in: app)
        scrollSheet(to: model, in: app)
        XCTAssertTrue(ChirpNotesUITests.waitFor(model, "label == 'Speaker model on your computer: ready'", timeout: 240))
        resetSavedVoicesInSettings(app)
        app.buttons["Done"].firstMatch.tap()

        // Note one: at least 20 s per synthetic person, then name Person 1 through the new sheet.
        let record = app.buttons["chirp.notes.record"].firstMatch
        XCTAssertTrue(ChirpNotesUITests.waitFor(record, "isEnabled == true", timeout: 15)); record.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "OK"] where springboard.alerts.buttons[label].waitForExistence(timeout: 1) { springboard.alerts.buttons[label].tap() }
        let status = ChirpNotesUITests.element("chirp.notes.status", in: app)
        XCTAssertTrue(ChirpNotesUITests.waitFor(status, "label == 'Recording'", timeout: 20))
        sleep(UInt32(duration.rounded(.up) + 4))
        app.buttons["chirp.notes.stop"].tap()
        XCTAssertTrue(ChirpNotesUITests.waitFor(status, "label == 'Stopped'", timeout: 90))
        app.buttons["chirp.notes.speakers.name.open"].tap()
        let name = app.textFields["chirp.notes.speakers.name.1"]
        XCTAssertTrue(name.waitForExistence(timeout: 10)); name.tap(); name.typeText("Samantha")
        app.buttons["chirp.notes.speakers.name.done"].tap()
        if app.alerts["Remembering voices"].waitForExistence(timeout: 10) { app.alerts.buttons["OK"].tap() }

        // The server's saved list must contain the enrolled synthetic voice before the next session starts.
        app.buttons["chirp.notes.more"].tap(); app.buttons["chirp.notes.note.settings"].tap()
        let saved = ChirpNotesUITests.element("chirp.notes.voices.open", in: app)
        for _ in 0..<6 where !saved.isHittable { app.swipeUp() }
        XCTAssertTrue(saved.isHittable); saved.tap()
        XCTAssertTrue(app.staticTexts["Samantha"].waitForExistence(timeout: 20))
        screenshot("Saved voice on the throwaway server", app)
        app.tapBack()
        app.buttons["Done"].firstMatch.tap()
        if UIDevice.current.userInterfaceIdiom != .pad { app.tapBack() }

        // Note two: a new server speaker session, with no manual naming.
        let newRecord = app.buttons["chirp.notes.record"].firstMatch
        XCTAssertTrue(newRecord.waitForExistence(timeout: 10)); newRecord.tap()
        XCTAssertTrue(ChirpNotesUITests.waitFor(status, "label == 'Recording'", timeout: 20))
        sleep(UInt32(duration.rounded(.up) + 4))
        app.buttons["chirp.notes.stop"].tap()
        XCTAssertTrue(ChirpNotesUITests.waitFor(status, "label == 'Stopped'", timeout: 90))
        app.buttons["chirp.notes.transcript.open"].tap()
        let recognised = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chirp.notes.speaker.chip.' AND label == 'Samantha' AND value == 'Recognised'")).firstMatch
        XCTAssertTrue(recognised.waitForExistence(timeout: 30), "The saved voice must be automatically named and marked recognised in note two")
        screenshot("Saved voice recognised in a new note", app)
        recognised.tap(); app.buttons["chirp.notes.speaker.not"].tap()
        XCTAssertFalse(recognised.exists)
    }

}
