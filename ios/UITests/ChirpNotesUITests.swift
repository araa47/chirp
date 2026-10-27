import XCTest

/// The Notes library through the real sealed store, with synthetic capture and server responses.
final class ChirpNotesUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    override func tearDown() async throws { await MainActor.run { XCUIApplication().terminate() } }

    @MainActor static func openNotes(_ app: XCUIApplication) {
        app.selectChirpTab("Notes")
    }
    @MainActor static func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    @MainActor static func waitFor(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 15) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)], timeout: timeout) == .completed
    }
    @MainActor static func flip(_ toggle: XCUIElement) {
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
    }
    /// Flips a switch in the Notes settings sheet. On iPad that sheet is shorter and narrower than the form: a row near
    /// the end exists but sits below the sheet until it is scrolled into view, and a tap outside the sheet dismisses it.
    /// So scroll until the row is hittable, then aim from the sheet's own Done button.
    @MainActor static func flipInSheet(_ toggle: XCUIElement, in app: XCUIApplication) {
        var scrolls = 0
        while !toggle.isHittable, scrolls < 6 { app.swipeUp(velocity: .slow); scrolls += 1 }
        let done = app.buttons["Done"].firstMatch
        guard done.exists, toggle.frame.height > 0 else { return flip(toggle) }
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: done.frame.maxX - 36, dy: toggle.frame.midY)).tap()
    }
    /// Both appearances in one test invocation; no separate simulator configuration or app relaunch is needed.
    @MainActor func screenshot(_ name: String, _ app: XCUIApplication) {
        let original = XCUIDevice.shared.appearance
        defer { XCUIDevice.shared.appearance = original }
        let fixed = ProcessInfo.processInfo.environment["CHIRP_NOTES_APPEARANCE"]
        let appearances: [XCUIDevice.Appearance] = fixed == "dark" ? [.dark] : fixed == "light" ? [.light] : [.light, .dark]
        for appearance in appearances {
            if fixed == nil, XCUIDevice.shared.appearance != appearance {
                XCUIDevice.shared.appearance = appearance
                // Give every window (sheets, the iPad inspector) a moment to redraw in the new appearance.
                _ = XCTWaiter.wait(for: [XCTestExpectation(description: "appearance")], timeout: 1)
            }
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = name + (appearance == .dark ? "-dark" : "-light")
            shot.lifetime = .keepAlways
            add(shot)
        }
    }
    @MainActor private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--chirp-ui-test", "--chirp-skip-onboarding", "--chirp-notes-library-id", UUID().uuidString] + extra
        if let appearance = ProcessInfo.processInfo.environment["CHIRP_NOTES_APPEARANCE"] {
            app.launchArguments += ["-AppleInterfaceStyle", appearance == "dark" ? "Dark" : "Light"]
        }
        app.launch(); Self.openNotes(app)
        XCTAssertTrue(Self.element("chirp.notes.library", in: app).waitForExistence(timeout: 10))
        return app
    }
    @MainActor private func backToLibrary(_ app: XCUIApplication) {
        if UIDevice.current.userInterfaceIdiom != .pad {
            let back = app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(back.waitForExistence(timeout: 5)); back.tap()
        }
    }
    @MainActor private func menu(_ app: XCUIApplication, action: String) {
        app.buttons["chirp.notes.more"].tap()
        let button = app.buttons[action]
        XCTAssertTrue(button.waitForExistence(timeout: 5)); button.tap()
    }

    /// One XCTest case keeps all scenarios in one runner session, avoiding repeated simulator teardown stalls.
    @MainActor func testNotesLibraryBatch() {
        recordPauseResumeStopTranscriptAndExport()
        libraryReadingSearchTasksAndInspector()
        notesSettingsAndRotation()
        accessibilityLibraryAndDock()
    }

    /// Refresh only the captures where a library snippet is visible, in one bounded run per device.
    @MainActor func testLibrarySnippetScreenshots() {
        let original = XCUIDevice.shared.appearance
        defer { XCUIDevice.shared.appearance = original }
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        if pad { XCUIDevice.shared.orientation = .landscapeLeft }
        let fixed = ProcessInfo.processInfo.environment["CHIRP_NOTES_APPEARANCE"]
        let appearances: [XCUIDevice.Appearance] = fixed == "dark" ? [.dark] : fixed == "light" ? [.light] : [.light, .dark]
        for appearance in appearances {
            let app = launch(["--chirp-notes-gallery"])
            if fixed == nil { XCUIDevice.shared.appearance = appearance }
            func capture(_ name: String) {
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                shot.name = name + (appearance == .dark ? "-dark" : "-light")
                shot.lifetime = .keepAlways
                add(shot)
            }
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chirp.notes.row.' AND label CONTAINS 'Lantern kickoff'")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            XCTAssertTrue(row.label.contains("Agenda · Review the launch plan · Share the design brief"))
            XCTAssertFalse(row.label.contains("Lantern kickoff Agenda"))
            capture("notes-library-groups")
            row.tap()
            XCTAssertTrue(app.buttons["chirp.notes.title"].waitForExistence(timeout: 5))
            if pad {
                capture("notes-reading")
                app.buttons["chirp.notes.transcript.open"].tap()
                let play = app.buttons["chirp.notes.play.0"]
                XCTAssertTrue(play.waitForExistence(timeout: 5))
                play.tap()
                XCTAssertTrue(Self.waitFor(play, "label == 'Stop replay'", timeout: 5))
                XCTAssertTrue(Self.waitFor(play, "label == 'Play segment'"), "Replay completion returns to the main actor")
                if appearance == .light { capture("notes-transcript-audio") }
                Self.flip(Self.element("chirp.notes.raw", in: app))
                capture("notes-transcript")
            } else {
                menu(app, action: "Delete")
                app.buttons["chirp.notes.menu"].tap(); app.buttons["chirp.notes.deleted.menu"].tap()
                XCTAssertTrue(app.buttons["Restore"].waitForExistence(timeout: 5))
                capture("notes-recently-deleted")
            }
            app.terminate()
        }
    }

    /// Re-transcribe from kept audio (#287 I) on the synthetic server: the consent sheet, progress, the finish toast with
    /// Undo, Restore previous transcript, gap rows' Try again, the debug-recordings warning, an older server, and AX5.
    @MainActor func testRetranscribeSheetBannerAndToast() {
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        func open(_ extra: [String]) -> XCUIApplication {
            let app = launch(["--chirp-notes-gallery", "--chirp-retranscribe-gallery"] + extra)
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chirp.notes.row.' AND label CONTAINS 'Lantern kickoff'")).firstMatch
            XCTAssertTrue(Self.element("chirp.notes.library", in: app).waitForExistence(timeout: 10))
            var scrolls = 0
            // At AX5 the newest note can sit below the fold, under the floating Record dock: nudge it above the dock.
            func clear() -> Bool {
                guard row.waitForExistence(timeout: 2), row.isHittable else { return false }
                let record = app.buttons["chirp.notes.record"].firstMatch
                let top = record.exists ? record.frame.minY - 8 : app.windows.firstMatch.frame.maxY
                return row.frame.minY + row.frame.height * 0.2 < top
            }
            let list = Self.element("chirp.notes.library", in: app)
            while !clear(), scrolls < 8 {
                list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6)).press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
                scrolls += 1
            }
            row.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
            XCTAssertTrue(app.buttons["chirp.notes.title"].waitForExistence(timeout: 5))
            return app
        }
        func sheet(_ app: XCUIApplication) {
            app.buttons["chirp.notes.more"].tap()
            // At AX5 the menu is taller than the screen and scrolls.
            let item = app.buttons["Re-transcribe…"]
            var scrolls = 0
            while !(item.waitForExistence(timeout: 2) && item.isHittable), scrolls < 4 {
                // Swipe on the menu itself (an iPad popover closes on a swipe outside it).
                let inMenu = ["chirp.notes.note.settings", "chirp.notes.speakers.toggle", "chirp.notes.save", "chirp.notes.copy"]
                    .map { app.buttons[$0] }.first { $0.exists && $0.isHittable }
                inMenu?.swipeUp(velocity: .slow)
                scrolls += 1
            }
            item.tap()
            XCTAssertTrue(Self.element("chirp.notes.retranscribe.title", in: app).waitForExistence(timeout: 10))
        }
        /// Nothing in the sheet runs past the screen's edge (A2-2).
        func fits(_ app: XCUIApplication) {
            let width = app.windows.firstMatch.frame.maxX
            for text in app.staticTexts.allElementsBoundByIndex where text.exists && text.frame.width > 0 {
                XCTAssertLessThanOrEqual(text.frame.maxX, width + 1, "“\(text.label)” runs off the screen")
            }
        }

        // The sheet, then a run that applies at once: "Transcript updated · Undo", and Undo puts the old text back.
        var app = open([])
        sheet(app)
        let body = Self.element("chirp.notes.retranscribe.body", in: app)
        XCTAssertTrue(body.label.contains("(3 s, 2 clips) to Chirp on your computer"), body.label)
        XCTAssertTrue(app.staticTexts["Speech model: Parakeet v3 (MLX)."].exists)
        XCTAssertTrue(app.staticTexts["This note was transcribed with: unknown."].exists)
        screenshot("notes-retranscribe-sheet", app)
        app.buttons["chirp.notes.retranscribe.send"].tap()
        let toast = Self.element("chirp.notes.retranscribe.toast", in: app)
        XCTAssertTrue(Self.waitFor(toast, "label == 'Transcript updated'"))
        screenshot("notes-retranscribe-updated", app)
        app.buttons["chirp.notes.transcript.open"].tap()
        let transcript = Self.element("chirp.notes.transcript", in: app)
        XCTAssertTrue(transcript.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Synthetic words again.'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(Self.waitFor(Self.element("chirp.notes.transcribedWith", in: app), "label == 'Transcribed with Parakeet v3 (MLX)'"))
        if !pad { app.buttons["Done"].firstMatch.tap() }
        // Undo while the toast is up (it moves into the iPad inspector, so wait until it settles), else the menu.
        let undo = app.buttons["chirp.notes.retranscribe.undo"]
        if undo.waitForExistence(timeout: 3), Self.waitFor(undo, "isHittable == true", timeout: 3) { undo.tap() }
        if !Self.waitFor(toast, "label == 'Previous transcript restored'", timeout: 3) { menu(app, action: "Restore previous transcript") }
        XCTAssertTrue(Self.waitFor(toast, "label == 'Previous transcript restored'"))
        app.terminate()

        // Progress: the second clip's final is held back, so the banner stays; Cancel changes nothing.
        app = open(["--chirp-retranscribe-hold"])
        sheet(app)
        app.buttons["chirp.notes.retranscribe.send"].tap()
        let status = Self.element("chirp.notes.retranscribe.status", in: app)
        XCTAssertTrue(Self.waitFor(status, "label BEGINSWITH 'Re-transcribing · 1 of 2'"), status.label)
        let continueRecording = app.buttons.matching(identifier: "chirp.notes.record").matching(NSPredicate(format: "label == 'Continue recording'")).firstMatch
        XCTAssertFalse(continueRecording.exists, "Continue recording waits for the run")
        screenshot("notes-retranscribe-progress", app)
        if pad {
            app.buttons["chirp.notes.transcript.open"].tap()
            XCTAssertTrue(Self.element("chirp.notes.retranscribe.banner", in: app).waitForExistence(timeout: 5))
            screenshot("notes-retranscribe-progress-inspector", app)
        }
        app.buttons["chirp.notes.retranscribe.stop"].firstMatch.tap()
        XCTAssertTrue(Self.waitFor(toast, "label == 'Cancelled. Nothing changed.'"))
        app.terminate()

        // A gap that kept its audio offers Try again: one clip, same consent.
        app = open([])
        app.buttons["chirp.notes.transcript.open"].tap()
        let tryAgain = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chirp.notes.retranscribe.try.'")).firstMatch
        XCTAssertTrue(tryAgain.waitForExistence(timeout: 5))
        tryAgain.tap()
        XCTAssertTrue(Self.waitFor(Self.element("chirp.notes.retranscribe.body", in: app), "label BEGINSWITH 'Send this 0:01 clip to your computer'"))
        app.buttons["chirp.notes.retranscribe.cancel"].tap()
        app.terminate()

        // The server keeps debug recordings: the red warning and "Re-transcribe anyway".
        app = open(["--chirp-retranscribe-debug"])
        sheet(app)
        XCTAssertTrue(Self.element("chirp.notes.retranscribe.debug", in: app).exists)
        XCTAssertEqual(app.buttons["chirp.notes.retranscribe.send"].label, "Re-transcribe anyway")
        screenshot("notes-retranscribe-warning", app)
        app.terminate()

        // An older server: the update line and no send button.
        app = open(["--chirp-retranscribe-old-server"])
        sheet(app)
        XCTAssertTrue(Self.element("chirp.notes.retranscribe.update", in: app).exists)
        XCTAssertFalse(app.buttons["chirp.notes.retranscribe.send"].exists)
        app.terminate()

        // AX5: the sheet and the banner wrap instead of running off the screen.
        app = open(["--chirp-retranscribe-hold", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        sheet(app)
        fits(app)
        screenshot("notes-retranscribe-sheet-ax5", app)
        let send = app.buttons["chirp.notes.retranscribe.send"]
        var scrolls = 0
        while !send.isHittable, scrolls < 8 { app.swipeUp(velocity: .slow); scrolls += 1 }
        send.tap()
        XCTAssertTrue(Self.waitFor(status, "label BEGINSWITH 'Re-transcribing · 1 of 2'"), status.label)
        fits(app)
        screenshot("notes-retranscribe-progress-ax5", app)
        app.terminate()

        // Settings: the switch sits under Keep audio with notes and hides every entry point.
        app = open([])
        menu(app, action: "Notes settings")
        let allow = Self.element("chirp.notes.allowRetranscribe", in: app)
        var settingScrolls = 0
        while !allow.isHittable, settingScrolls < 6 { app.swipeUp(velocity: .slow); settingScrolls += 1 }
        XCTAssertEqual(allow.value as? String, "1")
        Self.flipInSheet(allow, in: app)
        XCTAssertTrue(Self.waitFor(allow, "value == '0'", timeout: 5))
        app.buttons["Done"].firstMatch.tap()
        app.buttons["chirp.notes.more"].tap()
        XCTAssertFalse(app.buttons["Re-transcribe…"].waitForExistence(timeout: 2))
    }

    @MainActor private func recordPauseResumeStopTranscriptAndExport() {
        let app = launch()
        screenshot("notes-empty", app)
        app.buttons["chirp.notes.record"].firstMatch.tap()
        let status = Self.element("chirp.notes.status", in: app)
        XCTAssertTrue(Self.waitFor(status, "label == 'Recording'"))
        XCTAssertTrue(Self.waitFor(Self.element("chirp.notes.partial", in: app), "label == 'synthetic words'"))
        screenshot("notes-recording", app)
        backToLibrary(app)
        XCTAssertTrue(app.buttons["chirp.notes.recordingRow"].waitForExistence(timeout: 5))
        screenshot("notes-library-recording", app)
        app.buttons["chirp.notes.recordingRow"].tap()
        app.buttons["chirp.notes.pause"].tap()
        XCTAssertTrue(Self.waitFor(status, "label BEGINSWITH 'Paused'"))
        // Labels are on by default, so the synthetic note reads "Person 1: Synthetic words.".
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Synthetic words.'")).firstMatch.waitForExistence(timeout: 15))
        app.buttons["chirp.notes.pause"].tap()
        XCTAssertTrue(Self.waitFor(status, "label == 'Recording'"))
        app.buttons["chirp.notes.stop"].tap()
        XCTAssertTrue(Self.waitFor(status, "label == 'Stopped'"))
        screenshot("notes-stopped", app)
        app.buttons["chirp.notes.edit"].tap()
        let editor = app.textViews["chirp.notes.editor"]
        XCTAssertTrue(Self.waitFor(editor, "value CONTAINS 'Synthetic words.'"))
        screenshot("notes-edit", app)
        app.buttons["chirp.notes.edit"].tap()
        app.buttons["chirp.notes.transcript.open"].tap()
        let transcript = Self.element("chirp.notes.transcript", in: app)
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        Self.flip(Self.element("chirp.notes.raw", in: app))
        XCTAssertTrue(transcript.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'synthetic words'")).firstMatch.waitForExistence(timeout: 5))
        screenshot("notes-transcript", app)
        if UIDevice.current.userInterfaceIdiom != .pad { app.buttons["Done"].tap() }
        else { app.buttons["chirp.notes.transcript.open"].tap() }
        menu(app, action: "chirp.notes.copy")
        XCTAssertTrue(Self.waitFor(Self.element("chirp.notes.notice", in: app), "label CONTAINS 'Copied notes'"))
        backToLibrary(app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chirp.notes.row.'")).firstMatch.waitForExistence(timeout: 5))
        screenshot("notes-library-after-recording", app)
        app.terminate(); app.launch(); Self.openNotes(app)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chirp.notes.row.'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "The sealed note survives relaunch")
        row.tap()
        XCTAssertTrue(app.buttons["chirp.notes.title"].waitForExistence(timeout: 5))
        menu(app, action: "Delete")
        let undo = app.buttons["chirp.notes.delete.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5)); undo.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap(); menu(app, action: "Delete")
        app.buttons["chirp.notes.menu"].tap(); app.buttons["chirp.notes.deleted.menu"].tap()
        XCTAssertTrue(app.buttons["Restore"].waitForExistence(timeout: 5))
        screenshot("notes-recently-deleted", app)
        app.buttons["Restore"].tap()
        XCTAssertTrue(app.staticTexts["Nothing in Recently Deleted"].waitForExistence(timeout: 5))
    }

    @MainActor private func notesSettingsAndRotation() {
        let app = launch()
        app.buttons["chirp.notes.menu"].tap(); app.buttons["chirp.notes.settings"].tap()
        let saver = Self.element("chirp.notes.batterySaver", in: app)
        XCTAssertTrue(saver.waitForExistence(timeout: 5)); XCTAssertEqual(saver.value as? String, "1")
        XCTAssertEqual(Self.element("chirp.notes.keepNotes", in: app).value as? String, "1")
        XCTAssertEqual(Self.element("chirp.notes.keepAudio", in: app).value as? String, "0")
        XCTAssertTrue(app.buttons["Never"].exists)
        screenshot("notes-settings", app)
        app.buttons["Done"].tap()
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["chirp.notes.record"].firstMatch.waitForExistence(timeout: 5))
        screenshot("notes-library-landscape", app)
    }

    /// Reading, tasks, rename, local search and the inspector, with both appearances captured in this run.
    @MainActor private func libraryReadingSearchTasksAndInspector() {
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        let app = launch(["--chirp-notes-gallery"])
        XCTAssertTrue(app.staticTexts["Lantern kickoff"].waitForExistence(timeout: 10))
        screenshot("notes-library-groups", app)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chirp.notes.row.' AND label CONTAINS 'Lantern kickoff'")).firstMatch
        XCTAssertTrue(row.exists); row.tap()
        XCTAssertTrue(app.staticTexts["Decision:"].exists || app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Keep the launch in March'")).firstMatch.waitForExistence(timeout: 5))
        screenshot("notes-reading", app)
        let task = Self.element("chirp.notes.preview", in: app).buttons.matching(NSPredicate(format: "label CONTAINS 'Send the updated proposal'")).firstMatch
        if task.exists { task.tap(); XCTAssertEqual(task.value as? String, "Checked") }
        app.buttons["chirp.notes.transcript.open"].tap()
        XCTAssertTrue(app.buttons["chirp.notes.play.0"].waitForExistence(timeout: 5))
        app.buttons["chirp.notes.play.0"].tap()
        screenshot("notes-transcript-audio", app)
        if UIDevice.current.userInterfaceIdiom != .pad { app.buttons["Done"].tap() }
        else { app.buttons["chirp.notes.transcript.open"].tap() }
        app.buttons["chirp.notes.edit"].tap(); screenshot("notes-reading-edit", app)
        app.buttons["chirp.notes.edit"].tap()
        app.buttons["chirp.notes.title"].tap()
        let title = app.textFields["chirp.notes.title.editor"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (title.value as? String)?.count ?? 32) + "Launch notes")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.buttons["chirp.notes.title"].waitForExistence(timeout: 5))
        backToLibrary(app)
        // The docked field is the library's only search (no toolbar magnifier, #271 2.6).
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.tap()
        var prefix = ""
        for character in "March" {
            search.typeText(String(character)); prefix.append(character)
            XCTAssertTrue(Self.waitFor(search, "value == '\(prefix)'", timeout: 3))
        }
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chirp.notes.row.' AND label CONTAINS 'March'")).firstMatch.waitForExistence(timeout: 5))
        search.typeText("\n")
        screenshot("notes-search", app)
    }

    @MainActor private func accessibilityLibraryAndDock() {
        let app = launch(["--chirp-notes-gallery", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        screenshot("notes-library-ax5", app)
        app.buttons["chirp.notes.record"].firstMatch.tap()
        XCTAssertTrue(app.buttons["chirp.notes.stop"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["chirp.notes.pause"].isHittable)
        screenshot("notes-dock-ax5", app)
        app.buttons["chirp.notes.stop"].tap()
    }

    /// Label speakers (#201) with the synthetic server: the switch in Settings → Notes, two chips in the transcript,
    /// then rename (with the notes replaced), merge and separate from a chip's menu.
    @MainActor func testSpeakerChipsRenameMergeAndSeparate() {
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        let app = launch(["--chirp-notes-gallery", "--chirp-speakers-gallery"])
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chirp.notes.row.' AND label CONTAINS 'Lantern kickoff'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        app.buttons["chirp.notes.transcript.open"].tap()
        let one = app.buttons["chirp.notes.speaker.chip.0.0"], two = app.buttons["chirp.notes.speaker.chip.0.1"]
        XCTAssertTrue(one.waitForExistence(timeout: 5))
        XCTAssertEqual(one.label, "Person 1"); XCTAssertEqual(two.label, "Maya")
        screenshot("notes-speakers-transcript", app)

        // Rename Person 1 → Theo, replacing the notes' "Person 1" too.
        one.tap()
        app.buttons["chirp.notes.speaker.rename"].tap()
        let name = app.textFields["chirp.notes.speaker.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Theo")
        XCTAssertTrue(Self.element("chirp.notes.speaker.replace", in: app).waitForExistence(timeout: 5))
        screenshot("notes-speakers-rename", app)
        app.buttons["chirp.notes.speaker.confirm"].tap()
        XCTAssertTrue(Self.waitFor(one, "label == 'Theo'", timeout: 5))

        // Merge Maya into Theo, then separate her again.
        two.tap()
        app.buttons["chirp.notes.speaker.merge"].tap()
        app.buttons["Theo"].firstMatch.tap()
        XCTAssertTrue(Self.waitFor(two, "label == 'Theo'", timeout: 5))
        screenshot("notes-speakers-merged", app)
        two.tap()
        app.buttons["chirp.notes.speaker.separate"].tap()
        XCTAssertTrue(Self.waitFor(two, "label == 'Maya'", timeout: 5))

        if UIDevice.current.userInterfaceIdiom != .pad { app.buttons["Done"].tap() }
        else { app.buttons["chirp.notes.transcript.open"].tap() }
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Theo'")).firstMatch.waitForExistence(timeout: 5),
                      "the rename replaced the name in the notes")
    }

    /// "This turn is" (A2-10): one of Person 1's turns goes to Maya, then to a new person; their other turns stay, and the
    /// choice is sealed in the note (it survives a relaunch).
    @MainActor func testThisTurnIsReassignsOneTurn() {
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        if pad { XCUIDevice.shared.orientation = .landscapeLeft }
        let app = launch(["--chirp-notes-gallery", "--chirp-speakers-gallery"])
        func openTranscript() {
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chirp.notes.row.' AND label CONTAINS 'Lantern kickoff'")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
            app.buttons["chirp.notes.transcript.open"].tap()
        }
        openTranscript()
        // Segment 1 reads Person 1, Maya, Person 1.
        let first = app.buttons["chirp.notes.speaker.chip.1.0"], last = app.buttons["chirp.notes.speaker.chip.1.2"]
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        XCTAssertEqual(last.label, "Person 1")
        // A submenu's items lose their accessibility identifiers, and the chips behind the menu share their labels: find
        // the choice by label inside the menu's collection view.
        func reassign(_ person: String, screenshot name: String? = nil) {
            if !last.isHittable { Self.element("chirp.notes.transcript", in: app).swipeUp(velocity: .slow) }
            last.tap()
            let submenu = app.buttons["chirp.notes.speaker.reassign"]
            XCTAssertTrue(submenu.waitForExistence(timeout: 5)); submenu.tap()
            let choice = app.collectionViews.buttons[person].firstMatch
            XCTAssertTrue(choice.waitForExistence(timeout: 5), "This turn is → \(person)")
            if let name { screenshot(name, app) }
            choice.tap()
        }
        reassign("Maya", screenshot: "notes-speakers-this-turn")
        XCTAssertTrue(Self.waitFor(last, "label == 'Maya'", timeout: 5))
        XCTAssertEqual(first.label, "Person 1", "Person 1's other turns stay theirs")
        reassign("New person")
        XCTAssertTrue(Self.waitFor(last, "label == 'Person 3'", timeout: 5))
        XCTAssertEqual(first.label, "Person 1")
        screenshot("notes-speakers-new-person", app)

        app.terminate(); app.launch(); Self.openNotes(app)
        openTranscript()
        XCTAssertTrue(Self.waitFor(last, "label == 'Person 3'", timeout: 10), "the reassignment is kept in the sealed note")
        XCTAssertEqual(first.label, "Person 1")
    }

    /// New note (A2-7): a blank note opens ready to type with no recording, is "Untitled note" until typed in, and a note
    /// that is recording keeps recording.
    @MainActor func testNewNoteTypesWithoutStoppingARecording() {
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        let app = launch()
        let new = app.buttons["chirp.notes.new"]
        XCTAssertTrue(new.waitForExistence(timeout: 10))
        XCTAssertEqual(new.label, "New note")
        new.tap()
        let editor = app.textViews["chirp.notes.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5), "New note opens the editor")
        XCTAssertEqual(app.buttons["chirp.notes.title"].label, "Rename Untitled note")
        XCTAssertFalse(app.buttons["chirp.notes.stop"].exists, "nothing records")
        // New note opens ready to type; `hasKeyboardFocus` is readable only through a predicate.
        if !Self.waitFor(editor, "hasKeyboardFocus == true", timeout: 3) { editor.tap() }
        editor.typeText("Groceries\nBread and figs")
        screenshot("notes-new-note", app)
        app.buttons["chirp.notes.edit"].tap()
        XCTAssertTrue(Self.waitFor(app.buttons["chirp.notes.title"], "label == 'Rename Groceries'", timeout: 5))
        backToLibrary(app)
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chirp.notes.row.' AND label CONTAINS 'Groceries'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "the typed note is kept")

        // While one note records, New note opens beside it.
        XCTAssertTrue(Self.waitFor(app.buttons["chirp.notes.record"].firstMatch, "isEnabled == true", timeout: 20))
        app.buttons["chirp.notes.record"].firstMatch.tap()
        XCTAssertTrue(Self.waitFor(Self.element("chirp.notes.status", in: app), "label == 'Recording'"))
        backToLibrary(app)
        XCTAssertTrue(app.buttons["chirp.notes.recordingRow"].waitForExistence(timeout: 5))
        new.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["chirp.notes.jumpRecording"].waitForExistence(timeout: 5), "the recording goes on")
        if pad { XCTAssertTrue(app.buttons["chirp.notes.recordingRow"].exists) }
        app.buttons["chirp.notes.jumpRecording"].tap()
        XCTAssertTrue(app.buttons["chirp.notes.stop"].waitForExistence(timeout: 5))
        app.buttons["chirp.notes.stop"].tap()
        XCTAssertTrue(Self.waitFor(Self.element("chirp.notes.status", in: app), "label == 'Stopped'", timeout: 20))
    }

    /// Edit by voice (A2-4): hold the Command button, say the change, let go: the edit applies with Edited · Undo, and
    /// Undo puts the notes back. A quick tap latches it (Tap to send, with Cancel); an older server has no button.
    @MainActor func testEditByVoiceHoldLatchAndUndo() {
        func openLantern(_ app: XCUIApplication) {
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chirp.notes.row.' AND label CONTAINS 'Lantern kickoff'")).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        }
        let app = launch(["--chirp-notes-gallery"])
        openLantern(app)
        let command = app.buttons["chirp.notes.voiceEdit.button"]
        XCTAssertTrue(command.waitForExistence(timeout: 10), "the paired computer edits notes")
        XCTAssertEqual(command.label, "Edit notes by voice. Hold, say the change, let go.")
        let edited = Self.element("chirp.notes.preview", in: app).staticTexts.matching(NSPredicate(format: "label CONTAINS 'Edited by voice'")).firstMatch
        XCTAssertFalse(edited.exists)

        // Hold, say it, let go: the synthetic computer hears "Synthetic words." and adds it as a bullet.
        command.press(forDuration: 1.5)
        let undo = app.buttons["chirp.notes.voiceEdit.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 10), "Edited · Undo after the edit applied")
        XCTAssertTrue(edited.waitForExistence(timeout: 5))
        screenshot("notes-voice-edited", app)
        undo.tap()
        XCTAssertTrue(Self.waitFor(edited, "exists == false", timeout: 5), "Undo puts the notes back")
        XCTAssertFalse(undo.exists)

        // A quick tap latches it: what it hears shows with Cancel, and the next tap sends.
        command.tap()
        let cancel = app.buttons["chirp.notes.voiceEdit.cancel"]
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        XCTAssertTrue(Self.waitFor(command, "label == 'Send the spoken edit'", timeout: 5))
        XCTAssertTrue(Self.waitFor(Self.element("chirp.notes.voiceEdit.heard", in: app), "label CONTAINS 'synthetic words'", timeout: 5))
        screenshot("notes-voice-edit-listening", app)
        cancel.tap()
        XCTAssertTrue(Self.waitFor(cancel, "exists == false", timeout: 5))
        XCTAssertFalse(edited.exists, "a cancelled command edits nothing")
        command.tap()
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        command.tap()
        XCTAssertTrue(undo.waitForExistence(timeout: 10), "the second tap sends it")
        XCTAssertTrue(edited.exists)
        app.terminate()

        let older = launch(["--chirp-notes-gallery", "--chirp-no-notes-edit"])
        openLantern(older)
        XCTAssertTrue(older.buttons["chirp.notes.more"].waitForExistence(timeout: 10))
        XCTAssertFalse(older.buttons["chirp.notes.voiceEdit.button"].exists, "an older server has no Edit by voice")
    }

    /// Labels are on by default: no switch to flip and no consent (the synthetic Mac has the model), the chips follow, and
    /// Turn off in Settings is the one explicit choice.
    @MainActor func testLabelSpeakersAreOnByDefaultAndSettingsTurnsThemOff() {
        let app = launch()
        // Paired (the synthetic Mac answers health) before Settings is read: otherwise the Mac's model is unknown.
        XCTAssertTrue(Self.waitFor(app.buttons["chirp.notes.record"].firstMatch, "isEnabled == true", timeout: 20))
        app.buttons["chirp.notes.menu"].tap(); app.buttons["chirp.notes.settings"].tap()
        let toggle = Self.element("chirp.notes.speakers.setting", in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); XCTAssertEqual(toggle.value as? String, "1")
        let model = Self.element("chirp.notes.speakers.model", in: app)
        XCTAssertTrue(Self.waitFor(model, "label == 'Speaker model on your computer: ready'", timeout: 10))
        XCTAssertFalse(app.alerts.firstMatch.exists, "Labels on by default never ask")
        screenshot("notes-settings-speakers-sheet", app)
        app.buttons["Done"].tap()
        app.buttons["chirp.notes.record"].firstMatch.tap()
        XCTAssertTrue(Self.waitFor(Self.element("chirp.notes.status", in: app), "label == 'Recording'"))
        app.buttons["chirp.notes.stop"].tap()
        XCTAssertTrue(Self.waitFor(Self.element("chirp.notes.status", in: app), "label == 'Stopped'"))
        app.buttons["chirp.notes.transcript.open"].tap()
        XCTAssertTrue(app.buttons["chirp.notes.speaker.chip.0.0"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons["chirp.notes.speaker.chip.0.1"].label, "Person 2")
        if UIDevice.current.userInterfaceIdiom != .pad { app.buttons["Done"].tap() }
        else { app.buttons["chirp.notes.transcript.open"].tap() }

        // Turn off is the user's own choice: the switch reads off.
        // The note's own ⋯ menu (the library's is not on screen on an iPhone).
        XCTAssertTrue(app.buttons["chirp.notes.more"].waitForExistence(timeout: 10))
        app.buttons["chirp.notes.more"].tap(); app.buttons["chirp.notes.note.settings"].tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        Self.flipInSheet(toggle, in: app)
        XCTAssertTrue(Self.waitFor(toggle, "value == '0'", timeout: 10))
        screenshot("notes-settings-speakers", app)
    }
    @MainActor func testNameSpeakersSheetCancelNameMergeAndReopen() {
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        let app = launch(["--chirp-notes-gallery", "--chirp-speakers-gallery"])
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chirp.notes.row.' AND label CONTAINS 'Lantern kickoff'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        let open = app.buttons["chirp.notes.speakers.name.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        screenshot("notes-speakers-name-line", app)
        open.tap()
        let name = app.textFields["chirp.notes.speakers.name.1"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        screenshot("notes-speakers-name-sheet", app)
        name.tap(); name.typeText("Theo")
        XCTAssertTrue(Self.element("chirp.notes.speakers.replace", in: app).exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 5)); open.tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Person 1")
        name.tap(); name.typeText("Theo")
        app.buttons["chirp.notes.speakers.name.done"].tap()
        XCTAssertFalse(open.exists)
        app.buttons["chirp.notes.transcript.open"].tap()
        let one = app.buttons["chirp.notes.speaker.chip.0.0"]
        XCTAssertTrue(Self.waitFor(one, "label == 'Theo'", timeout: 10))
        app.buttons["chirp.notes.speakers.name.header"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        app.buttons["chirp.notes.speakers.same.2"].tap()
        let merge = app.buttons["chirp.notes.speakers.merge.into.1"].firstMatch
        XCTAssertTrue(merge.waitForExistence(timeout: 5)); merge.tap()
        XCTAssertTrue(Self.waitFor(app.textFields["chirp.notes.speakers.name.2"], "exists == false", timeout: 5))
        app.buttons["chirp.notes.speakers.name.done"].tap()
        XCTAssertTrue(Self.waitFor(app.buttons["chirp.notes.speaker.chip.0.1"], "label == 'Theo'", timeout: 5))
    }

    @MainActor func testNameSpeakersEvidence() {
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        let app = launch(["--chirp-notes-gallery", "--chirp-speakers-gallery"])
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chirp.notes.row.' AND label CONTAINS 'Lantern kickoff'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        let open = app.buttons["chirp.notes.speakers.name.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        screenshot("notes-speakers-name-line", app)
        open.tap()
        let name = app.textFields["chirp.notes.speakers.name.1"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.tap(); name.typeText("Theo\n")
        screenshot("notes-speakers-name-sheet", app)
    }

    @MainActor func testSavedVoicesRecognitionAndManagement() {
        let app = launch(["--chirp-voices-gallery"])
        XCTAssertTrue(Self.waitFor(app.buttons["chirp.notes.record"].firstMatch, "isEnabled == true", timeout: 20))
        app.buttons["chirp.notes.record"].firstMatch.tap()
        XCTAssertTrue(app.buttons["chirp.notes.stop"].waitForExistence(timeout: 10))
        app.buttons["chirp.notes.stop"].tap()
        XCTAssertTrue(Self.waitFor(Self.element("chirp.notes.status", in: app), "label == 'Stopped'", timeout: 20))
        app.buttons["chirp.notes.transcript.open"].tap()
        let first = app.buttons["chirp.notes.speaker.chip.0.0"]
        XCTAssertTrue(Self.waitFor(first, "label == 'Maya'", timeout: 10))
        XCTAssertEqual(first.value as? String, "Recognised")
        screenshot("notes-voices-recognised", app)
        first.tap(); app.buttons["chirp.notes.speaker.not"].tap()
        XCTAssertTrue(Self.waitFor(first, "label == 'Person 1'", timeout: 10))
        if UIDevice.current.userInterfaceIdiom == .pad { app.buttons["chirp.notes.transcript.open"].tap() }
        else { app.buttons["Done"].firstMatch.tap() }
        app.selectChirpTab("Settings")
        let category = Self.element("chirp.settings.notes", in: app)
        XCTAssertTrue(category.waitForExistence(timeout: 10)); category.tap()
        let open = Self.element("chirp.notes.voices.open", in: app)
        for _ in 0..<5 where !open.isHittable { app.swipeUp() }
        XCTAssertTrue(open.isHittable); open.tap()
        let toggle = Self.element("chirp.notes.voices.enabled", in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 10)); XCTAssertEqual(toggle.value as? String, "1")
        screenshot("notes-saved-voices", app)
        let menu = app.buttons["chirp.notes.voices.menu.0123456789abcdef"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5)); menu.tap()
        app.buttons["Rename…"].firstMatch.tap()
        let name = app.alerts.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "Theo")
        app.alerts.buttons["Rename"].tap()
        XCTAssertTrue(app.staticTexts["Theo"].waitForExistence(timeout: 5))
        Self.flip(toggle)
        app.buttons["Keep voices"].firstMatch.tap()
        XCTAssertTrue(Self.waitFor(toggle, "value == '0'", timeout: 5))
        XCTAssertTrue(app.staticTexts["Theo"].exists)
        Self.flip(toggle)
        XCTAssertTrue(Self.waitFor(toggle, "value == '1'", timeout: 5))
        menu.tap(); app.buttons["Forget…"].firstMatch.tap()
        app.buttons["Forget"].firstMatch.tap()
        XCTAssertTrue(Self.element("chirp.notes.voices.empty", in: app).waitForExistence(timeout: 5))
    }

    @MainActor func testSavedVoicesEvidence() {
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
        let app = launch(["--chirp-notes-gallery", "--chirp-speakers-gallery", "--chirp-voices-gallery"])
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'chirp.notes.row.' AND label CONTAINS 'Lantern kickoff'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        let open = app.buttons["chirp.notes.speakers.name.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10)); open.tap()
        XCTAssertTrue(app.textFields["chirp.notes.speakers.name.1"].waitForExistence(timeout: 10))
        XCTAssertTrue(Self.element("chirp.notes.speakers.remember.1", in: app).exists)
        screenshot("notes-speakers-remember-sheet", app)
        app.buttons["Cancel"].tap()
        app.selectChirpTab("Settings")
        let category = Self.element("chirp.settings.notes", in: app)
        XCTAssertTrue(category.waitForExistence(timeout: 10)); category.tap()
        let saved = Self.element("chirp.notes.voices.open", in: app)
        for _ in 0..<5 where !saved.isHittable { app.swipeUp() }
        XCTAssertTrue(saved.isHittable); saved.tap()
        XCTAssertTrue(Self.element("chirp.notes.voices.enabled", in: app).waitForExistence(timeout: 10))
        screenshot("notes-saved-voices", app)
    }

}
