import XCTest

/// Live Notes end to end against a real local chirp-server (`ios/scripts/simulator-e2e.sh`): spoken audio from
/// `--chirp-sim-audio`, real segments over `/v1/stream`, clean-up and `/v1/notes/structure` through the local
/// stand-in. Skipped unless the runner passes CHIRP_LIVE_LINK and CHIRP_LIVE_AUDIO.
final class ChirpLiveNotesUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard env["CHIRP_LIVE_LINK"]?.isEmpty == false, env["CHIRP_LIVE_AUDIO"]?.isEmpty == false else {
            throw XCTSkip("Live server run only: set TEST_RUNNER_CHIRP_LIVE_LINK and TEST_RUNNER_CHIRP_LIVE_AUDIO.")
        }
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor func screenshot(_ name: String, _ app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways
        add(shot)
    }

    /// Pair through Settings → Connection like the dictation live test.
    @MainActor func pair(_ app: XCUIApplication) {
        let env = ProcessInfo.processInfo.environment
        app.openConnection()
        app.endChirpSession()
        if app.buttons["chirp.pair.forget"].waitForExistence(timeout: 2) {
            app.buttons["chirp.pair.forget"].tap()
            if app.buttons["Forget"].waitForExistence(timeout: 3) { app.buttons["Forget"].tap() }
        }
        let field = app.pairingLinkField()
        field.tap(); field.typeText(env["CHIRP_LIVE_LINK"]!)
        app.buttons["chirp.pair.submit"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "chirp.connection.banner").firstMatch.waitForExistence(timeout: 15))
    }

    /// Re-transcribe from kept audio against the real server (#287 I): two seeded notes whose kept clips are real `say`
    /// speech (sealed AAC, decoded in memory) and whose transcript reads "WRONG TEXT". The meeting note comes back with
    /// the fixture's words, keeps Maya and the turn reassigned to her, and Undo puts "WRONG TEXT" back; the gap note's
    /// Try again fills in its one clip. simulator-e2e.sh checks the server log and device activity afterwards.
    @MainActor func testLiveRetranscribeTwoNotes() throws {
        let env = ProcessInfo.processInfo.environment
        guard let meeting = env["CHIRP_LIVE_SPEAKERS_AUDIO"], !meeting.isEmpty else { throw XCTSkip("Needs TEST_RUNNER_CHIRP_LIVE_SPEAKERS_AUDIO.") }
        let app = XCUIApplication()
        app.launchArguments = ["--chirp-skip-onboarding", "--chirp-retranscribe-seed", meeting, env["CHIRP_LIVE_AUDIO"]!]
        app.launch()
        pair(app)
        ChirpNotesUITests.openNotes(app)
        func open(_ title: String) {
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chirp.notes.row.' AND label BEGINSWITH %@", title)).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 15), title)
            row.tap()
            XCTAssertTrue(ChirpNotesUITests.waitFor(app.buttons["chirp.notes.title"], "label CONTAINS '\(title)'", timeout: 10))
        }
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        func closeTranscript() { if !pad { app.buttons["Done"].firstMatch.tap() } }
        let transcript = ChirpNotesUITests.element("chirp.notes.transcript", in: app)
        // The iPad inspector stays open across actions; the button toggles it.
        func openTranscript() { if !transcript.exists { app.buttons["chirp.notes.transcript.open"].tap() } }
        func transcriptSays(_ words: String, timeout: TimeInterval = 10) -> Bool {
            transcript.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", words)).firstMatch.waitForExistence(timeout: timeout)
        }
        let toast = ChirpNotesUITests.element("chirp.notes.retranscribe.toast", in: app)

        // The meeting: the whole note, with the consent sheet naming the live model.
        open("Retranscribe meeting")
        app.buttons["chirp.notes.more"].tap()
        XCTAssertTrue(app.buttons["Re-transcribe…"].waitForExistence(timeout: 5))
        app.buttons["Re-transcribe…"].tap()
        let body = ChirpNotesUITests.element("chirp.notes.retranscribe.body", in: app)
        XCTAssertTrue(body.waitForExistence(timeout: 15))
        XCTAssertTrue(body.label.contains("2 clips) to Chirp on your computer"), body.label)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Speech model: Parakeet'")).firstMatch.exists)
        screenshot("Re-transcribe sheet against the live server", app)
        app.buttons["chirp.notes.retranscribe.send"].tap()
        XCTAssertTrue(ChirpNotesUITests.waitFor(toast, "label == 'Transcript updated'", timeout: 180), toast.label)
        openTranscript()
        XCTAssertTrue(transcriptSays("onboarding"), "The fixture's words came back from the audio")
        XCTAssertTrue(transcriptSays("release notes"))
        XCTAssertFalse(transcript.staticTexts.matching(NSPredicate(format: "label CONTAINS 'WRONG TEXT'")).firstMatch.exists)
        // Maya, and the turn reassigned to her by hand, survive: the speakers were never relabelled.
        let reassigned = app.buttons["chirp.notes.speaker.chip.1.0"]
        XCTAssertTrue(reassigned.waitForExistence(timeout: 5))
        XCTAssertEqual(reassigned.label, "Maya")
        XCTAssertTrue(ChirpNotesUITests.waitFor(ChirpNotesUITests.element("chirp.notes.transcribedWith", in: app), "label BEGINSWITH 'Transcribed with Parakeet'"))
        screenshot("Re-transcribed transcript from the live server", app)
        closeTranscript()
        // Undo (or, once the toast has gone, Restore previous transcript) brings the old words back.
        if app.buttons["chirp.notes.retranscribe.undo"].exists { app.buttons["chirp.notes.retranscribe.undo"].tap() }
        else { app.buttons["chirp.notes.more"].tap(); app.buttons["Restore previous transcript"].tap() }
        XCTAssertTrue(ChirpNotesUITests.waitFor(toast, "label == 'Previous transcript restored'"))
        openTranscript()
        XCTAssertTrue(transcriptSays("WRONG TEXT"))
        XCTAssertEqual(app.buttons["chirp.notes.speaker.chip.1.0"].label, "Maya")
        closeTranscript()
        if !pad { app.tapBack() }

        // The gap: Try again sends its one clip.
        open("Retranscribe gap")
        openTranscript()
        let tryAgain = app.buttons["chirp.notes.retranscribe.try.0"]
        XCTAssertTrue(tryAgain.waitForExistence(timeout: 10))
        tryAgain.tap()
        XCTAssertTrue(ChirpNotesUITests.waitFor(body, "label BEGINSWITH 'Send this 0:0'"), body.label)
        app.buttons["chirp.notes.retranscribe.send"].tap()
        XCTAssertTrue(transcriptSays("Tuesday", timeout: 120), "The gap's clip was transcribed")
        XCTAssertFalse(tryAgain.exists)
        screenshot("Gap transcribed again from the live server", app)
    }

    @MainActor func testLiveNotesRecordStructureStop() {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchArguments = ["--chirp-sim-audio", env["CHIRP_LIVE_AUDIO"]!, "--chirp-skip-onboarding"]
        app.launch()
        pair(app)
        // Clean-up on, so segments are cleaned and Show raw has something to show (pairing again turned it off).
        app.openDictation()
        let cleanup = ChirpNotesUITests.element("chirp.cleanup.enabled", in: app)
        XCTAssertTrue(cleanup.waitForExistence(timeout: 5))
        if cleanup.value as? String != "1" {
            cleanup.switches.firstMatch.exists ? cleanup.switches.firstMatch.tap() : cleanup.tap()
            let enable = app.buttons["Enable for this destination"]
            if enable.waitForExistence(timeout: 3) { enable.tap() }
        }
        XCTAssertTrue(ChirpNotesUITests.waitFor(cleanup, "value == '1'", timeout: 5))

        ChirpNotesUITests.openNotes(app)
        app.buttons["chirp.notes.menu"].tap()
        app.buttons["chirp.notes.settings"].tap()
        let keepAudio = ChirpNotesUITests.element("chirp.notes.keepAudio", in: app)
        XCTAssertTrue(keepAudio.waitForExistence(timeout: 5))
        if keepAudio.value as? String != "1" { ChirpNotesUITests.flip(keepAudio) }
        app.buttons["Done"].tap()
        let record = app.buttons["chirp.notes.record"]
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        XCTAssertTrue(ChirpNotesUITests.waitFor(record, "isEnabled == true", timeout: 10))
        record.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "OK"] where springboard.alerts.buttons[label].waitForExistence(timeout: 1) { springboard.alerts.buttons[label].tap() }
        let status = ChirpNotesUITests.element("chirp.notes.status", in: app)
        XCTAssertTrue(ChirpNotesUITests.waitFor(status, "label == 'Recording'", timeout: 20), status.label)
        let partial = ChirpNotesUITests.element("chirp.notes.partial", in: app)
        XCTAssertTrue(ChirpNotesUITests.waitFor(partial, "label CONTAINS[c] 'design group'", timeout: 30), "Live partial never covered the sentence")
        screenshot("Live Notes live partial", app)

        app.buttons["chirp.notes.stop"].tap()
        XCTAssertTrue(ChirpNotesUITests.waitFor(status, "label == 'Stopped'", timeout: 60), status.label)
        let preview = ChirpNotesUITests.element("chirp.notes.preview", in: app)
        XCTAssertTrue(preview.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'design group'")).firstMatch.waitForExistence(timeout: 10))
        screenshot("Notes reading from the live server", app)
        app.buttons["chirp.notes.edit"].tap()
        let editor = app.textViews["chirp.notes.editor"]
        XCTAssertTrue(ChirpNotesUITests.waitFor(editor, "value CONTAINS[c] 'design group'", timeout: 10))
        let markdown = editor.value as? String ?? ""
        XCTAssertTrue(markdown.hasPrefix("- "), "The live server stand-in structures a bullet")
        XCTAssertFalse(markdown.localizedCaseInsensitiveContains("um,"))
        app.buttons["chirp.notes.edit"].tap()
        app.buttons["chirp.notes.transcript.open"].tap()
        let transcript = ChirpNotesUITests.element("chirp.notes.transcript", in: app)
        XCTAssertTrue(transcript.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'Tuesday'")).firstMatch.waitForExistence(timeout: 5))
        ChirpNotesUITests.flip(ChirpNotesUITests.element("chirp.notes.raw", in: app))
        XCTAssertTrue(transcript.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'um,'")).firstMatch.waitForExistence(timeout: 5),
                      "Show raw shows the transcript before clean-up")
        screenshot("Notes raw transcript from the live server", app)
        let play = app.buttons["chirp.notes.play.0"]
        XCTAssertTrue(play.waitForExistence(timeout: 10), "Opted-in speech audio survives Stop")
        play.tap()
        XCTAssertTrue(ChirpNotesUITests.waitFor(play, "label == 'Stop replay'", timeout: 5))
        screenshot("Notes kept audio replay from the live server", app)
    }
}
