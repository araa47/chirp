import XCTest

/// Getting around the app shell (#192): four tabs (Notes · Dictate · History · Settings) as a tab bar on
/// iPhone and a sidebar or top tab bar on iPad; Connection and Styles live in the Settings tab.
extension XCUIApplication {
    static let syntheticPairingLink = "chirp://pair?url=https%3A%2F%2Fsynthetic.test.ts.net%2Fchirp&token=synthetic-only"

    /// Selects a tab by title, wherever the system put it. App controls are excluded by their `chirp.` identifiers
    /// (the Dictate mic button is also labelled "Dictate").
    @MainActor func selectChirpTab(_ title: String, file: StaticString = #filePath, line: UInt = #line) {
        let symbols = ["Notes": "note.text", "Dictate": "mic", "History": "clock.arrow.circlepath", "Settings": "gearshape"]
        let tabBar = tabBars.buttons[title]
        if tabBar.exists { tabBar.tap(); return }
        let notApp = NSPredicate(format: "(label == %@ OR identifier == %@) AND NOT (identifier BEGINSWITH 'chirp.')", title, symbols[title] ?? title)
        for query in [buttons.matching(notApp), cells.matching(notApp)] {
            let element = query.firstMatch
            if element.waitForExistence(timeout: 2), element.isHittable { element.tap(); return }
        }
        XCTFail("No \(title) tab", file: file, line: line)
    }

    /// iPad: the tab sidebar can be open over the content (the chip and the Notes list sit under it). A tap on the
    /// dimmed content closes it; a no-op when the control is already reachable.
    @MainActor func dismissSidebarOverlay(covering control: XCUIElement) {
        guard control.exists, !control.isHittable else { return }
        coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        _ = control.waitForExistence(timeout: 2)
    }

    /// The system Back button of a pushed page, wherever the system draws it. iOS 27.1 on a compact iPhone screen (the
    /// iPhone Duo's cover screen) puts it in a floating toolbar with no navigation bar at all (#329), so it is found by
    /// the system's `BackButton` identifier, else as the navigation bar's first button.
    @MainActor var backButton: XCUIElement {
        let system = buttons["BackButton"].firstMatch
        return system.exists ? system : navigationBars.buttons.element(boundBy: 0)
    }

    /// Taps Back on a pushed page once it appears.
    @MainActor func tapBack(timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !backButton.exists, Date() < deadline { _ = buttons["BackButton"].firstMatch.waitForExistence(timeout: 0.5) }
        let back = backButton
        XCTAssertTrue(back.exists, "No Back button", file: file, line: line)
        if back.exists { back.tap() }
    }

    /// Settings → a category row, from any tab.
    @MainActor func openSettingsPage(_ id: String) {
        selectChirpTab("Settings")
        let back = navigationBars.buttons["Settings"]
        if back.exists { back.tap() }
        let link = buttons[id]
        XCTAssertTrue(link.waitForExistence(timeout: 5), "No \(id) in Settings")
        link.tap()
    }

    @MainActor func openConnection() { openSettingsPage("chirp.settings.connection") }
    /// Settings → Dictation (Styles, clean-up, spoken commands and Press Return live there).
    @MainActor func openDictation() { openSettingsPage("chirp.settings.dictation") }

    /// The pairing link field, revealed by Connection's pairing page and "Paste link instead".
    @MainActor func pairingLinkField() -> XCUIElement {
        let field = secureTextFields["pairingLink"]
        if !field.exists {
            let change = buttons["chirp.pair.change"]
            if change.waitForExistence(timeout: 5) { change.tap() }
            let paste = buttons["chirp.pair.paste"]
            if paste.waitForExistence(timeout: 5) { paste.tap() }
        }
        XCTAssertTrue(field.waitForExistence(timeout: 5), "No pairing link field")
        return field
    }

    /// Settings → Connection → Pair computer → paste a link → Connect. A success pops back to Connection,
    /// whose status banner is the saved-pairing marker.
    @MainActor func pair(link: String, timeout: TimeInterval = 5) {
        openConnection()
        let field = pairingLinkField()
        field.tap()
        field.typeText(link)
        buttons["chirp.pair.submit"].tap()
        XCTAssertTrue(descendants(matching: .any).matching(identifier: "chirp.connection.banner").firstMatch.waitForExistence(timeout: timeout), "Pairing did not save")
    }

    /// End an armed session from whichever tab is showing (each tab carries its own capsule).
    @MainActor func endChirpSession() {
        buttons.matching(identifier: "chirp.session.end").allElementsBoundByIndex.first { $0.isHittable }?.tap()
    }
}
