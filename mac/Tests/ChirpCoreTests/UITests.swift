import AppKit
import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

@Suite struct OutcomePresentationTests {
    @Test func eachOutcomeHasItsWording() {
        let plain = FinalResult(text: "hello")
        #expect(OutcomePresentation.of(.inserted(.ax), final: plain) == .init(status: "Inserted", linger: 0))
        #expect(OutcomePresentation.of(.inserted(.paste), final: plain).status == "Inserted")
        #expect(OutcomePresentation.of(.copied, final: plain) == .init(status: "Copied — ⌘V", indicator: .clipboard, linger: 3))
        #expect(OutcomePresentation.of(.insertedUnverified, final: plain).status == "Inserted? ⌘V if empty")
        let secure = OutcomePresentation.of(.refusedSecure, final: plain)
        #expect(secure.isError && secure.status == "Secure field — not inserted" && secure.indicator == .warning)
    }

    @Test func aCleanedInsertionFadesTheHUDAtOnceAndOffersRawElsewhere() {
        let corrected = FinalResult(text: "Hello.", raw: "hello", corrected: true)
        let unchanged = FinalResult(text: "hello", raw: "hello", corrected: true)
        let p = OutcomePresentation.of(.inserted(.ax), final: corrected)
        #expect(p.linger == 0 && !p.showUseRaw && p.offersRawOutsideHUD && p.cleaned)
        let none = OutcomePresentation.of(.inserted(.ax), final: unchanged)
        #expect(!none.showUseRaw && !none.offersRawOutsideHUD)
        #expect(!OutcomePresentation.of(.copied, final: corrected).showUseRaw)
        #expect(!OutcomePresentation.of(.copied, final: corrected).offersRawOutsideHUD)
        #expect(!OutcomePresentation.of(.inserted(.ax), final: corrected, offerRaw: false).offersRawOutsideHUD)
    }

    @Test func showChangesRestoresTheOverlayWithItsUseRawButton() {
        let corrected = FinalResult(text: "Hello.", raw: "hello", corrected: true)
        let on = OutcomePresentation.of(.inserted(.ax), final: corrected, showChanges: true)
        #expect(on.cleaned && on.showUseRaw && on.linger == 5 && !on.offersRawOutsideHUD)
        let off = OutcomePresentation.of(.inserted(.ax), final: corrected, offerRaw: false, showChanges: true)
        #expect(off.cleaned && !off.showUseRaw && off.linger == 1.8)
        #expect(!OutcomePresentation.of(.inserted(.ax), final: FinalResult(text: "hello")).cleaned)
        #expect(!OutcomePresentation.of(.refusedSecure, final: corrected).cleaned)
    }

    @Test func aSuccessfulInsertionNeverLingers() {
        let finals = [FinalResult(text: "hello"),                                          // clean-up off
                      FinalResult(text: "hello", raw: "hello", corrected: true),            // clean-up changed nothing
                      FinalResult(text: "Hello.", raw: "hello", corrected: true)]           // cleaned
        for final in finals {
            for method in [InsertionMethod.ax, .paste] {
                #expect(OutcomePresentation.of(.inserted(method), final: final).linger == 0)
            }
        }
        // Show changes keeps the HUD only when there are changes to show.
        #expect(OutcomePresentation.of(.inserted(.ax), final: finals[0], showChanges: true).linger == 0)
        #expect(OutcomePresentation.of(.inserted(.ax), final: finals[1], showChanges: true).linger == 0)
        #expect(OutcomePresentation.of(.inserted(.ax), final: finals[2], showChanges: true).linger > 0)
        // Where the user has to act or be told something, the HUD stays.
        for outcome in [InsertionOutcome.copied, .insertedUnverified, .refusedSecure] {
            #expect(OutcomePresentation.of(outcome, final: finals[0]).linger > 0)
        }
    }

    @Test func theKeptOriginalNoteIsBrief() {
        let kept = FinalResult(text: "hello", corrected: false, correctionError: "timeout")
        #expect(OutcomePresentation.of(.inserted(.ax), final: kept).linger <= 1)
        #expect(OutcomePresentation.of(.inserted(.ax), final: kept, showChanges: true).linger <= 1)
        #expect(OutcomePresentation.of(.inserted(.ax), final: kept).keptOriginal)
    }
}

@Suite struct HUDTextTests {
    @Test func shortTextIsUntouched() {
        let r = HUDText.tail(stable: "hello ", unstable: "world")
        #expect(r.stable == "hello " && r.unstable == "world")
    }

    @Test func longTextKeepsTheNewestWordsAtAWordBoundary() {
        let words = (1...80).map { "w\($0)" }.joined(separator: " ")
        let r = HUDText.tail(stable: words + " ", unstable: "last")
        let shown = r.stable + r.unstable
        #expect(shown.hasPrefix("…w"))
        #expect(shown.hasSuffix(" w80 last"))
        #expect(shown.count <= 200 + 1)
        #expect(!shown.dropFirst().hasPrefix("w") || shown.dropFirst().first == "w")
        #expect(r.unstable == "last")
    }

    @Test func cutInsideTheUnstableTailKeepsOnlyUnstable() {
        let unstable = (1...60).map { "word\($0)" }.joined(separator: " ")
        let r = HUDText.tail(stable: "old ", unstable: unstable)
        #expect(r.stable.isEmpty)
        #expect(r.unstable.hasPrefix("…word"))
        #expect(r.unstable.hasSuffix("word60"))
    }

    @Test func aSingleLongTokenIsStillCut() {
        let r = HUDText.tail(stable: "", unstable: String(repeating: "x", count: 500))
        #expect(r.unstable.count == 201 || r.unstable.count == 200)
        #expect(r.unstable.hasPrefix("x") || r.unstable.hasPrefix("…"))
    }
}

@Suite struct HUDColorsTests {
    private func luminance(_ c: HUDColors.RGB) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }
    private func contrast(_ a: HUDColors.RGB, _ b: HUDColors.RGB) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    // The material composited over a mid-tone desktop, measured from the light and dark snapshots.
    private let lightMaterial: HUDColors.RGB = (0.78, 0.80, 0.85)
    private let darkMaterial: HUDColors.RGB = (0.27, 0.29, 0.35)
    // The flat stand-ins used for Increase Contrast and the snapshots.
    @Test func textIsReadableOnTheFlatSurfaces() {
        #expect(contrast(HUDColors.errorLight, HUDColors.surfaceLight) >= 4.5)
        #expect(contrast(HUDColors.errorDark, HUDColors.surfaceDark) >= 4.5)
        #expect(contrast(HUDColors.actionLight, HUDColors.surfaceLight) >= 4.5)
        #expect(contrast(HUDColors.actionDark, HUDColors.surfaceDark) >= 4.5)
    }

    @Test func errorTextMeetsWCAGAANormalText() {
        #expect(contrast(HUDColors.errorLight, lightMaterial) >= 4.5)
        #expect(contrast(HUDColors.errorDark, darkMaterial) >= 4.5)
    }

    @Test func useRawChipMeetsWCAGAA() {
        // The chip is koiContainer with onKoiContainer text: its own solid fill, so it is readable over any material.
        typealias Pond = ChirpColor.Pond
        #expect(contrast(Pond.onKoiContainer.light, Pond.koiContainer.light) >= 4.5)
        #expect(contrast(Pond.onKoiContainer.dark, Pond.koiContainer.dark) >= 4.5)
        // The koi tint of the word waveform's bars and revised words is graphics, not body text: 3:1 over the material.
        #expect(contrast(HUDColors.actionLight, lightMaterial) >= 3)
        #expect(contrast(HUDColors.actionDark, darkMaterial) >= 3)
    }

    @Test func hudIsAFixedFullLengthPanel() {
        // 472 pt is the full length the capsule reached before the Pond restyle (a 440 pt text column); the 360 pt panel
        // wrapped a sentence after a few words and read as cut short. Both modes share it now.
        #expect(HUDViewMetrics.width == 472 && HUDViewMetrics.wordWaveformWidth == 472)
        #expect(HUDViewMetrics.width(wordWaveform: false) == 472 && HUDViewMetrics.width(wordWaveform: true) == 472)
        #expect(HUDViewMetrics.contentWidth(wordWaveform: false) == 440)
        // Half the 44 pt one-line height: a one-line HUD is a capsule again.
        #expect(HUDViewMetrics.corner == 22 && HUDViewMetrics.transcriptLines == 5)
    }

    @Test func debugBadgeKeepsWhiteTextReadable() {
        #expect(contrast((1, 1, 1), HUDColors.badgeRGB) >= 4.5)
    }
}

@MainActor
@Suite struct SettingsFormTests {
    @Test func appliesPermissionAndTokenState() {
        var s = SettingsState()
        s.micGranted = false; s.tokenPresent = false; s.launch = .unavailable
        let form = SettingsForm(s)
        #expect(!form.micButton.isHidden && form.accessibilityButton.isHidden)
        #expect(!form.launch.isEnabled && form.launch.state == .off)
        #expect(form.serverURL.stringValue == ServerConfig.defaultURL.absoluteString)
    }

    @Test func fixButtonsShowOnlyForWhatIsMissing() {
        var s = SettingsState()
        let form = SettingsForm(s)
        #expect(form.micButton.isHidden && form.accessibilityButton.isHidden)
        s.accessibilityGranted = false
        form.apply(s)
        #expect(form.micButton.isHidden && !form.accessibilityButton.isHidden)
        #expect(form.micButton.accessibilityLabel() == "Fix Microphone access" && form.accessibilityButton.accessibilityLabel() == "Fix Accessibility access")
    }

    @Test func launchCheckboxShowsTheRealState() {
        var s = SettingsState()
        s.launch = .on
        let form = SettingsForm(s)
        #expect(form.launch.state == .on && form.launch.isEnabled && !form.launch.allowsMixedState)
        s.launch = .off
        form.apply(s, full: true)
        #expect(form.launch.state == .off)
    }

    @Test func periodicRefreshNeverOverwritesTypingOrTheLoginItemError() {
        let form = SettingsForm(SettingsState())
        form.serverURL.stringValue = "http://typing"
        form.setLaunchError("Operation not permitted")
        var s = SettingsState()
        s.micGranted = false; s.serverURL = "http://other"
        form.apply(s)
        #expect(form.serverURL.stringValue == "http://typing")
        #expect(form.launchHelp.stringValue == "Couldn’t change it: Operation not permitted")
        #expect(!form.micButton.isHidden)
        form.apply(s, full: true)
        #expect(form.serverURL.stringValue == "http://other")
        #expect(form.launchHelp.textColor == .secondaryLabelColor)
    }

    // MARK: tabs

    @Test func hasTheSidebarPagesWithAboutInTheFooter() {
        #expect(SettingsTab.sidebar.map(\.title) == ["General", "Dictation", "History & privacy", "Clean-up", "Notes", "Devices", "Advanced"])
        #expect(SettingsTab.allCases.last == .about && !SettingsTab.sidebar.contains(.about))
        #expect(SettingsTab.allCases.allSatisfy { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: nil) != nil })
    }

    @Test func eachControlLivesOnItsOwnPage() {
        let form = SettingsForm(SettingsState())
        func has(_ control: NSView, _ tab: SettingsTab) -> Bool { control.isDescendant(of: form.view(for: tab)) }
        #expect(has(form.launch, .general) && has(form.setupButton, .general) && has(form.micButton, .general) && has(form.accessibilityButton, .general))
        // Dictation holds every shortcut, how a dictation stops, the microphone and the sounds.
        #expect(has(form.hotkey, .dictation) && has(form.recorder, .dictation) && has(form.notesShortcut.view, .dictation) && has(form.useRawShortcut.view, .dictation))
        #expect(has(form.mode, .dictation) && has(form.silence, .dictation))
        #expect(has(form.microphone, .dictation) && has(form.wordWaveform, .dictation) && has(form.autoEnter, .dictation))
        #expect(has(form.sounds, .dictation) && has(form.soundPack, .dictation) && has(form.volume, .dictation) && has(form.chooseStart, .dictation))
        #expect(has(form.cleanupEnabled, .cleanup) && has(form.style, .cleanup) && has(form.prompts.view, .cleanup))
        #expect(has(form.appStyles.view, .cleanup) && has(form.showChanges, .cleanup) && has(form.insertRawFirst, .cleanup))
        #expect(has(form.removeSpeakerModel, .notes) && has(form.notesButton, .notes) && has(form.savedVoicesButton, .notes))
        // Notes: retention, Recently Deleted, kept audio, the export folder and the smart-notes defaults.
        #expect(has(form.notesRetention, .notes) && has(form.emptyDeleted, .notes) && has(form.keepAudio, .notes) && has(form.deleteAudio, .notes))
        #expect(has(form.chooseExport, .notes) && has(form.structureNotes, .notes) && has(form.autoReorganize, .notes))
        // History & privacy: the phones' Privacy & history group, gathered on one Mac page.
        #expect(has(form.privateSession, .privacy) && has(form.historyEnabled, .privacy) && has(form.historyRetention, .privacy))
        #expect(has(form.historyApps.view, .privacy) && has(form.learnFromEdits, .privacy) && has(form.showLearned, .privacy))
        #expect(!has(form.historyEnabled, .dictation) && !has(form.privateSession, .dictation) && !has(form.learnFromEdits, .dictation))
        // Advanced: the server URL, token, models and Doctor.
        #expect(has(form.serverURL, .advanced) && has(form.doctorButton, .advanced) && has(form.modelsButton, .advanced) && has(form.keepLoaded, .advanced))
        #expect(has(form.pairButton, .devices) && has(form.devicesView, .devices) && has(form.rotateButton, .devices) && has(form.about, .about))
        // and on no other
        for control in [form.launch, form.hotkey, form.sounds, form.cleanupEnabled, form.removeSpeakerModel, form.serverURL, form.keepLoaded,
                        form.pairButton, form.devicesView, form.rotateButton, form.micButton, form.about, form.keepAudio, form.notesRetention,
                        form.historyEnabled, form.privateSession, form.learnFromEdits, form.savedVoicesButton] {
            #expect(SettingsTab.allCases.filter { has(control, $0) }.count == 1)
        }
    }

    @Test func cleanupTabCarriesEveryCleanupOption() {
        var s = SettingsState()
        s.cleanupEnabled = true; s.showChanges = true; s.offerRaw = false
        let form = SettingsForm(s)
        #expect(form.cleanupEnabled.state == .on && form.showChanges.state == .on && form.offerRaw.state == .off)
        s.cleanupAvailable = false; s.cleanupDetail = "The server has clean-up turned off; see the README to enable it."
        form.apply(s)
        #expect(!form.cleanupEnabled.isEnabled)
    }

    @Test func cleanupDetailSaysWhereTheTextGoes() {
        #expect(SettingsForm.cleanupDetail(health: Health(correction: "available", correctionLeavesMachine: false)).text.hasPrefix("Runs on this Mac"))
        #expect(SettingsForm.cleanupDetail(health: Health(correction: "available", correctionLeavesMachine: true, correctionHost: "llm.example.com")).text
                == "Sends the text to llm.example.com to tidy it.")
        let off = SettingsForm.cleanupDetail(health: Health(correction: "off"))
        #expect(!off.available && off.text.contains("turned off"))
        #expect(SettingsForm.cleanupDetail(health: nil).available)
    }

    @Test func everyPageSharesOneWidthThatFillsTheDetailColumn() {
        let form = SettingsForm(SettingsState())
        let sizes = SettingsTab.allCases.map { form.fittingSize(for: $0) }
        // One width, so switching pages never moves the sidebar; it is the window's 520 pt detail column.
        #expect(Set(sizes.map(\.width)).count == 1 && sizes[0].width == SettingsShell.size.width - SettingsShell.sidebarWidth)
        #expect(SettingsTab.allCases.allSatisfy { form.view(for: $0).fittingSize.width == sizes[0].width })
        // Only the long pages scroll; the General page fits the fixed 520 pt window.
        let heights = Dictionary(uniqueKeysWithValues: zip(SettingsTab.allCases, sizes.map(\.height)))
        #expect(heights[.general]! < SettingsShell.size.height, "\(heights)")
        #expect(heights[.cleanup]! > SettingsShell.size.height && heights[.cleanup]! > heights[.general]! * 1.5, "\(heights)")
    }

    @Test func pagesSitInsideTheirMargin() {
        let form = SettingsForm(SettingsState())
        for tab in SettingsTab.allCases {
            let view = form.view(for: tab)
            let size = form.fittingSize(for: tab)
            let body = view.subviews[0]
            view.setFrameSize(size)
            view.layoutSubtreeIfNeeded()
            #expect(abs(body.frame.minY - 20) < 0.5 && abs(size.height - body.frame.maxY - 20) < 0.5, "\(tab.title)")
            if tab != .about { #expect(abs(body.frame.minX - 20) < 0.5 && abs(size.width - body.frame.maxX - 20) < 0.5, "\(tab.title)") }
        }
    }

    @Test func pagesAreGroupedCardsWithATitle() throws {
        let form = SettingsForm(SettingsState())
        let page = try #require(form.view(for: .dictation).subviews[0] as? NSStackView)
        #expect(page.arrangedSubviews.first is SettingsPageTitle)
        let sections = page.arrangedSubviews.dropFirst()
        #expect(sections.count == 3)   // Shortcuts, Dictating, Sounds
        let privacy = try #require(form.view(for: .privacy).subviews[0] as? NSStackView)
        let privacySections = privacy.arrangedSubviews.dropFirst()
        #expect(privacySections.count == 4)   // Privacy, Dictation history, Learn from my edits, What Chirp keeps
        #expect(privacy.allDescendants(of: NSTextField.self).contains { $0.stringValue == SettingsForm.privacyKeeps })
        #expect(sections.allSatisfy { ($0 as? NSStackView)?.arrangedSubviews.contains { $0 is SettingsCard } == true })
    }

    @Test func hiddenRowsLeaveNoGap() {
        var s = SettingsState()
        s.soundPack = .default
        let form = SettingsForm(s)
        let rows = form.view(for: .dictation).allDescendants(of: SettingsRow.self)
        #expect(rows.filter(\.isHidden).count == 3)   // the fn help row and the two custom sound rows
        s.soundPack = .custom
        form.apply(s, full: true)
        #expect(form.view(for: .dictation).allDescendants(of: SettingsRow.self).filter(\.isHidden).count == 1)
    }

    @Test func notesPageShowsTheLibrarySettingsAsStored() {
        var s = SettingsState()
        s.notesRetention = .ninetyDays; s.notesKeepAudio = true; s.notesAudioBytes = 48_300_000; s.recentlyDeletedCount = 3
        s.exportFolder = NSHomeDirectory() + "/Documents/Notes"; s.structureNotes = true; s.autoReorganize = false
        let form = SettingsForm(s)
        #expect(form.notesRetention.selectedItem?.representedObject as? String == NotesRetention.ninetyDays.rawValue)
        #expect(form.keepAudio.state == .on && form.deleteAudio.isEnabled && form.emptyDeleted.isEnabled)
        #expect(form.structureNotes.state == .on && form.autoReorganize.state == .off && form.resetExport.isEnabled)
        #expect(form.notesRetention.itemTitles == ["Never", "1 year", "90 days", "30 days"])
        // Nothing to delete: the buttons say so.
        s.notesAudioBytes = 0; s.recentlyDeletedCount = 0
        form.apply(s)
        #expect(!form.deleteAudio.isEnabled && !form.emptyDeleted.isEnabled)
    }

    @Test func sidebarSearchMatchesTitlesAndKeywords() {
        #expect(SettingsShell.pages(matching: "") == SettingsTab.allCases)
        #expect(SettingsShell.pages(matching: "token").contains(.advanced) && SettingsShell.pages(matching: "token").contains(.devices))
        #expect(SettingsShell.pages(matching: "Retention") == [.privacy, .notes])
        #expect(SettingsShell.pages(matching: "private session") == [.privacy])
        #expect(SettingsShell.pages(matching: "history") == [.privacy])
        #expect(SettingsShell.pages(matching: "login") == [.general])
        #expect(SettingsShell.pages(matching: "zzz").isEmpty)
    }

    @Test func permissionProblemsBadgeGeneral() {
        #expect(SettingsShell.permissionProblems(micGranted: true, accessibilityGranted: true) == 0)
        #expect(SettingsShell.permissionProblems(micGranted: false, accessibilityGranted: true) == 1)
        #expect(SettingsShell.permissionProblems(micGranted: false, accessibilityGranted: false) == 2)
    }

    @Test func shellSelectsAPageAndFollowsASearch() {
        let shell = SettingsShell(form: SettingsForm(SettingsState()), flat: true)
        #expect(shell.selected == .general && shell.fittingSize == SettingsShell.size)
        var heard: [SettingsTab] = []
        shell.onSelect = { heard.append($0) }
        shell.show(.notes)
        #expect(shell.selected == .notes && heard == [.notes])
        // A search the open page does not match moves to the first page that does.
        shell.setSearch("doctor")
        #expect(shell.selected == .advanced)
        shell.setSearch("")
        #expect(shell.selected == .advanced)
        shell.show(.notes)
        shell.showDetail(content: shell.form.voicesView, title: "Saved voices", back: "Notes")
        #expect(shell.isShowingDetail && shell.selected == .notes)
        #expect(shell.form.voicesView.isDescendant(of: shell))
        #expect(shell.openPageHeight > 120)
        #expect(shell.form.savedVoicesButton.accessibilityLabel() == "Saved voices")
        shell.popDetail()
        #expect(!shell.isShowingDetail && shell.selected == .notes)
        shell.showDetail(content: shell.form.voicesView, title: "Saved voices", back: "Notes")
        shell.show(.dictation)
        #expect(!shell.isShowingDetail && shell.selected == .dictation)
    }

    @Test func microphonePickerFollowsTheMenuRules() {
        let boya = AudioInput(uid: "boya", name: "BOYA CM40"), studio = AudioInput(uid: "studio", name: "Studio")
        var s = SettingsState()
        s.inputs = [boya, studio, AudioInput(uid: "studio2", name: "Studio")]; s.defaultInput = boya
        let form = SettingsForm(s)
        #expect(form.microphone.itemArray.filter { !$0.isSeparatorItem }.map(\.title) == ["Follow System Default (BOYA CM40)", "BOYA CM40", "Studio", "Studio"])
        #expect(form.microphone.indexOfSelectedItem == 0)
        s.chosenInputUID = "studio2"
        form.apply(s)
        #expect(form.microphone.selectedItem?.representedObject as? String == "studio2")
        // Unplugged: shows the default, as the menu does.
        s.inputs = [boya]
        form.apply(s)
        #expect(form.microphone.indexOfSelectedItem == 0 && form.microphone.numberOfItems == 3)
        s.inputs = []; s.defaultInput = nil
        form.apply(s)
        #expect(!form.microphone.isEnabled)
    }

    @Test func speakerModelShowsItsStateAndRemoveOnlyWhileDownloaded() {
        var s = SettingsState()
        let form = SettingsForm(s)
        #expect(form.removeSpeakerModel.isHidden)
        s.speakerModelDownloaded = true
        form.apply(s)
        #expect(!form.removeSpeakerModel.isHidden && form.removeSpeakerModel.accessibilityLabel() == "Remove the speaker model")
    }

    @Test(arguments: [(SettingsTab.general, "Set up Chirp"), (.dictation, "Dictation"), (.privacy, "Keep for"), (.cleanup, "Style"), (.notes, "Delete notes older than"),
                      (.advanced, "Server URL"), (.devices, "Pair a phone")])
    func rowTitlesShareALeftEdgeAndTheirControlsATrailingEdge(tab: SettingsTab, title: String) throws {
        let form = SettingsForm(SettingsState())
        let view = form.view(for: tab)
        view.setFrameSize(form.fittingSize(for: tab))
        view.layoutSubtreeIfNeeded()
        let rows = view.allDescendants(of: SettingsRow.self).filter { $0.title != nil && !$0.isHidden }
        #expect(rows.contains { $0.title == title }, "\(tab.title): \(rows.compactMap(\.title))")
        // Titles start at the card's text inset, in every row.
        let titles = rows.compactMap { row in row.allDescendants(of: NSTextField.self).first { $0.stringValue == row.title } }
        let edges = titles.map { view.convert($0.bounds, from: $0).minX }
        #expect(edges.allSatisfy { abs($0 - edges[0]) < 0.5 }, "\(tab.title)")
        // Nothing pokes out of the page's right margin.
        for control in view.allDescendants(of: NSControl.self) where !control.isHiddenOrHasHiddenAncestor && !(control is SettingsPageTitle) {
            #expect(view.convert(control.bounds, from: control).maxX <= view.bounds.width - 19.5, "\(tab.title): \(control)")
        }
    }

    @Test func helpTextUsesTheSecondaryLabelColour() {
        let form = SettingsForm(SettingsState())
        #expect(form.launchHelp.textColor == .secondaryLabelColor)
        #expect(form.launchHelp.font?.pointSize == NSFont.smallSystemFontSize)
    }

    @Test func theShellControllerHoldsTheFixedWindowAndEveryPage() throws {
        let form = SettingsForm(SettingsState())
        let controller = SettingsTabs.makeController(form: form)
        _ = controller.view
        #expect(controller.preferredContentSize == SettingsShell.size && SettingsShell.size == NSSize(width: 720, height: 520))
        var shown: [SettingsTab] = []
        controller.onAppear = { shown.append($0) }
        for tab in SettingsTab.allCases { controller.shell.show(tab) }
        #expect(shown == SettingsTab.allCases)
        #expect(controller.shell.selected == .about)
    }

    @Test func aWindowAroundTheShellOpensWithoutAFocusedOrSelectedField() throws {
        let form = SettingsForm(SettingsState())
        let controller = SettingsTabs.makeController(form: form)
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.setContentSize(SettingsShell.size)
        #expect(!(window.firstResponder is NSText))
        #expect(window.contentViewController === controller && window.contentView?.frame.size == SettingsShell.size)
        controller.shell.show(.advanced)
        window.makeFirstResponder(form.view(for: .advanced))
        #expect(!(window.firstResponder is NSText) && form.serverURL.currentEditor() == nil)
    }

    @Test func customSoundRowsRevealWithoutResizingTheWindow() throws {
        let form = SettingsForm(SettingsState())
        let controller = SettingsTabs.makeController(form: form)
        _ = controller.view
        let before = form.fittingSize(for: .dictation).height
        form.showPack(.custom)
        let custom = form.fittingSize(for: .dictation).height
        #expect(custom > before)
        form.showPack(.chirp)
        #expect(form.fittingSize(for: .dictation).height == before, "\(before) → \(custom)")
        #expect(controller.preferredContentSize == SettingsShell.size)
    }
}

// MARK: menu views

@MainActor
@Suite struct MenuViewTests {
    private func row(_ title: String, value: String? = nil, shortcut: String? = nil, submenu: Bool = false,
                     action: MenuAction? = .showSettings) -> MenuRowView {
        MenuRowView(entry: MenuEntry(title: title, value: value, shortcut: shortcut, action: action,
                                     submenu: submenu ? [MenuEntry(title: "x", action: .showSettings)] : nil))
    }

    @Test func rowsAreTwentyFourPointsHighAndAtLeastTheMenuMinimumWide() {
        let r = row("Clean-up", value: "Default", submenu: true)
        #expect(r.frame.height == MenuMetrics.rowHeight && r.frame.width >= MenuMetrics.minimumWidth)
        #expect(r.intrinsicContentSize.height == 24)
    }

    @Test func aRowNeedsRoomForItsTitleItsWholeValueAndTheChevron() {
        let plain = row("Settings…")
        let value = row("Microphone", value: "BOYA CM40", submenu: true)
        let long = row("Microphone", value: "Studio Display Microphone (Built-in…", submenu: true)
        #expect(value.fittingWidth >= plain.fittingWidth)
        #expect(long.fittingWidth > value.fittingWidth)
        #expect(value.fittingWidth >= MenuMetrics.minimumWidth)
    }

    @Test func rowsAreMenuItemsForVoiceOverWithTheFullLabel() {
        let r = MenuRowView(entry: MenuEntry(title: "Microphone", value: "Studio Display Micro…", fullValue: "Studio Display Microphone (USB)",
                                             submenu: [MenuEntry(title: "x", action: .showSettings)]))
        #expect(r.isAccessibilityElement() && r.accessibilityRole() == .menuItem)
        #expect(r.accessibilityLabel() == "Microphone, Studio Display Microphone (USB)")
        #expect(r.accessibilityHelp() == "Opens a submenu")
        let disabled = row("Start Dictation", shortcut: "⌃⌥Space", action: nil)
        #expect(!disabled.isAccessibilityEnabled() && disabled.accessibilityLabel() == "Start Dictation, ⌃⌥Space")
    }

    @Test func headerShowsTheSwitchAndAnnouncesItsChanges() {
        var seen: [Bool] = []
        let on = MenuHeaderView(header: MenuContent.header(MenuInputs()))
        on.onToggle = { seen.append($0) }
        #expect(on.toggle.state == .on && on.frame.height == MenuHeaderView.height)
        on.toggle.state = .off
        on.toggle.performClick(nil)   // flips it back on and sends the action
        #expect(seen.count == 1)
        var paused = MenuInputs()
        paused.paused = true
        #expect(MenuHeaderView(header: MenuContent.header(paused)).toggle.state == .off)
    }

    @Test func headerIsOneGroupForVoiceOverAndTheSwitchIsLabelled() {
        let view = MenuHeaderView(header: MenuContent.header(MenuInputs()))
        #expect(view.accessibilityLabel() == "Chirp, Checking server…")
        #expect(view.toggle.accessibilityLabel() == "Chirp")
        #expect(view.toggle.accessibilityHelp()?.contains("Turns dictation on or off") == true)
    }
}

@MainActor
@Suite struct SnapshotTests {
    private func render(_ names: [String]? = nil) throws -> (URL, [URL]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-snap-\(UUID().uuidString)")
        let scenarios = names.map { names in Snapshots.allScenarios.filter { names.contains($0.name) } }
        return (dir, try Snapshots.render(to: dir, scenarios: scenarios))
    }

    @Test func rendersEveryStateInLightAndDarkAsNonBlankPNGs() throws {
        let (dir, files) = try render()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(files.count == Snapshots.allScenarios.count * 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == files.count)
        let names = Set(files.map(\.lastPathComponent))
        for state in ["listening", "listening-multiline", "listening-contrast", "listening-reduce-motion", "finalizing", "inserted", "copied", "unverified-ax", "secure-field",
                      "no-mic-signal", "debug-badge", "correction-use-raw", "cleaned-no-raw-button"] {
            #expect(names.contains("hud-\(state)-light.png") && names.contains("hud-\(state)-dark.png"))
        }
        #expect(names.contains("settings-general-ready-dark.png") && names.contains("menu-ready-light.png") && names.contains("menu-microphone-submenu-dark.png"))
        for tab in SettingsTab.allCases { #expect(names.contains { $0.hasPrefix("settings-\(tab.rawValue)-") }, "no snapshot for the \(tab.title) tab") }
        for state in ["paused", "listening", "unreachable", "debug", "use-raw", "permissions-missing", "long-names"] {
            #expect(names.contains("menu-\(state)-light.png") && names.contains("menu-\(state)-dark.png"))
        }
        for name in ["onboarding-welcome", "onboarding-try-it-success", "onboarding-microphone-blocked", "settings-about-ready", "settings-dictation-shortcuts-custom"] {
            #expect(names.contains("\(name)-light.png") && names.contains("\(name)-dark.png"))
        }
        for url in files {
            let data = try Data(contentsOf: url)
            // The welcome window carries the pond artwork, a photographic image: it is the one PNG that needs the larger bound.
            #expect(data.count < 550_000, "\(url.lastPathComponent) is too big to commit")
            let rep = try #require(NSBitmapImageRep(data: data))
            #expect(rep.pixelsWide > 100 && rep.pixelsHigh > 50)
            // Not a flat fill: some pixel differs from the corner.
            let corner = rep.colorAt(x: 0, y: 0)
            var differs = false
            for x in stride(from: 0, to: rep.pixelsWide, by: 7) where !differs {
                for y in stride(from: 0, to: rep.pixelsHigh, by: 7) where rep.colorAt(x: x, y: y) != corner { differs = true; break }
            }
            #expect(differs, "\(url.lastPathComponent) is blank")
        }
    }

    @Test func lightAndDarkAreDifferentImages() throws {
        let names = ["hud-listening", "settings-general-ready", "menu-ready"]
        let (dir, _) = try render(names)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in names {
            let light = try Data(contentsOf: dir.appendingPathComponent("\(name)-light.png"))
            let dark = try Data(contentsOf: dir.appendingPathComponent("\(name)-dark.png"))
            #expect(light != dark)
        }
    }

    @Test func multilineHUDIsTallerThanASingleLineOne() throws {
        let (dir, _) = try render(["hud-listening-multiline", "hud-listening-no-text"])
        defer { try? FileManager.default.removeItem(at: dir) }
        func height(_ n: String) throws -> Int {
            try #require(NSBitmapImageRep(data: Data(contentsOf: dir.appendingPathComponent(n)))).pixelsHigh
        }
        #expect(try height("hud-listening-multiline-light.png") > height("hud-listening-no-text-light.png"))
        // The HUD never grows beyond its 4-line cap, however much is dictated.
        #expect(try height("hud-listening-multiline-light.png") < 400)
    }

    @Test func theCommittedSetIsCuratedAndSmall() throws {
        let names = Snapshots.committedNames
        let all = Set(Snapshots.allScenarios.map(\.name))
        #expect(names.allSatisfy { all.contains($0) } && Set(names).count == names.count)
        // 56 states (including dictation parity and the HUD's long-dictation viewport): every Settings page, the 720 × 520
        // windows, the Notes window states and History.
        #expect(names.count * 2 <= 112)
        // The menu in light and dark, one per Settings tab, setup, the key HUD states and the Notes window.
        #expect(["notes-empty", "notes-library", "notes-recording", "notes-search", "notes-no-results", "notes-deleted",
                 "notes-continued", "notes-inspector-playing", "notes-review-sheet"].allSatisfy(names.contains))
        #expect(names.contains("menu-ready") && names.contains("onboarding-welcome") && names.contains { $0.hasPrefix("hud-") })
        for tab in SettingsTab.allCases { #expect(names.contains { $0.hasPrefix("settings-\(tab.rawValue)-") }, "\(tab.title)") }
        #expect(Snapshots.committedScenarios.map(\.name) == names)
    }

    @Test func theCommittedFilesAreExactlyTheCuratedSetUnderTwentyMegabytes() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/screenshots/mac")
        guard FileManager.default.fileExists(atPath: dir.path) else { return }   // not a full checkout
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".png") }.sorted()
        let expected = Snapshots.committedNames.flatMap { ["\($0)-dark.png", "\($0)-light.png"] }.sorted()
        #expect(files == expected, "docs/screenshots/mac is out of date: run mac/scripts/snapshots.sh")
        let total = try files.reduce(0) { $0 + (try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent($1).path)[.size] as? Int ?? 0) }
        // Full-height Settings captures include Speakers and Saved voices.
        #expect(total < 20_000_000, "\(total) bytes")
    }

    @Test func curatedRenderingWritesOnlyTheCommittedNames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-curated-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = try Snapshots.render(to: dir, scenarios: Snapshots.committedScenarios)
        #expect(Set(files.map(\.lastPathComponent)) == Set(Snapshots.committedNames.flatMap { ["\($0)-dark.png", "\($0)-light.png"] }))
    }

    @Test func theMenuSnapshotsUseTheRealRowsSoHighlightAndValuesRender() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-menu-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try Snapshots.render(to: dir, scenarios: Snapshots.menuScenarios.filter { ["menu-ready", "menu-hover"].contains($0.name) })
        let ready = try Data(contentsOf: dir.appendingPathComponent("menu-ready-light.png"))
        let hover = try Data(contentsOf: dir.appendingPathComponent("menu-hover-light.png"))
        #expect(ready != hover)   // the hover scenario draws a selected row
    }

    // MARK: the Notes window's Pond surfaces

    /// Renders one scenario's PNG under an appearance. `NSBitmapImageRep.colorAt` reads top-down.
    private func rep(_ name: String, _ appearance: NSAppearance.Name) throws -> NSBitmapImageRep {
        let scenario = try #require(Snapshots.allScenarios.first { $0.name == name })
        let data = try #require(Snapshots.png(scenario, appearance: appearance))
        return try #require(NSBitmapImageRep(data: data))
    }

    /// The committed PNG of `name` (rendered by `scripts/snapshots.sh` in the app process, where the sidebar's
    /// List material behaves as on screen — the test runner's plainer AppKit draws it differently). nil when this
    /// is not a full checkout.
    private func committed(_ name: String) throws -> NSBitmapImageRep? {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("docs/screenshots/mac")
        let url = dir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSBitmapImageRep(data: data)
    }

    /// How many 8-px samples in a horizontal band sit within `tolerance` of `rgb` per channel.
    private func samples(_ rep: NSBitmapImageRep, x0: Int, x1: Int, near rgb: (Int, Int, Int), tolerance: Int = 14) -> Int {
        var count = 0
        for x in stride(from: x0, to: min(x1, rep.pixelsWide), by: 8) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 8) {
                if let c = rep.colorAt(x: x, y: y),
                   abs(Int(c.redComponent * 255) - rgb.0) <= tolerance,
                   abs(Int(c.greenComponent * 255) - rgb.1) <= tolerance,
                   abs(Int(c.blueComponent * 255) - rgb.2) <= tolerance {
                    count += 1
                }
            }
        }
        return count
    }

    @Test func theBundledSettingsCheckboxesUseTheKoiAccentInLightMode() throws {
        guard let general = try committed("settings-general-ready-light.png"),
              let voices = try committed("settings-saved-voices-ready-light.png") else { return }
        // These bands contain the checked boxes and exclude the sidebar icons. Native cells shade the asset hue.
        #expect(samples(general, x0: 460, x1: 500, near: (194, 90, 25)) > 1)
        // Saved voices is a detail page: the checkbox sits in the detail column, past the sidebar.
        #expect(samples(voices, x0: 420, x1: 520, near: (194, 90, 25)) > 1)
    }

    @Test func theNotesSidebarSitsOnPondWithAKoiSelectedRow() throws {
        guard let dark = try committed("notes-recording-dark.png"), let light = try committed("notes-recording-light.png") else { return }
        // The sidebar column is Pond `surfaceRaised` (not the grey system material) beside the `surface` editor.
        #expect(samples(dark, x0: 40, x1: 500, near: (26, 38, 64)) > 400)
        #expect(samples(dark, x0: 1100, x1: 2000, near: (18, 28, 48)) > 4000)
        // Selection uses the canonical koi container in both appearances.
        #expect(samples(dark, x0: 40, x1: 500, near: (92, 34, 7)) > 60)
        #expect(samples(light, x0: 40, x1: 500, near: (236, 239, 245)) > 400)
        // The pale koi container.
        #expect(samples(light, x0: 40, x1: 500, near: (255, 228, 212)) > 60)
    }

    @Test func theEmptyStateDiscIsARaisedPondSurfaceNotTheMuddyContainer() throws {
        guard let dark = try committed("notes-empty-dark.png"), let light = try committed("notes-empty-light.png") else { return }
        // In dark the glyph disc is `surfaceRaised` on the `surface` page; the koi container read as a muddy
        // brown block at this size.
        #expect(samples(dark, x0: 1000, x1: 1600, near: (26, 38, 64)) > 100)
        #expect(samples(dark, x0: 1000, x1: 1600, near: (92, 34, 7), tolerance: 10) == 0)
        // In light it keeps the pale koi disc.
        #expect(samples(light, x0: 1000, x1: 1600, near: (255, 228, 212)) > 100)
    }

    @Test func theHearingStripWashStaysSubtleInDark() throws {
        let dark = try rep("notes-recording-live", .darkAqua)
        // 10% koi over the surface — a quiet warm wash, not the 35% koi container that read muddy.
        #expect(samples(dark, x0: 1100, x1: 2000, near: (42, 38, 51), tolerance: 7) > 60)
        #expect(samples(dark, x0: 1100, x1: 2000, near: (44, 31, 34), tolerance: 6) < 10)
    }
}

extension NSView {
    func allDescendants<T: NSView>(of type: T.Type) -> [T] {
        subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + $0.allDescendants(of: type) }
    }
}
