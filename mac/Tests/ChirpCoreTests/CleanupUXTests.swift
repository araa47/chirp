import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

private func prefs() throws -> (Preferences, () -> Void) {
    let suite = "chirp-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    return (Preferences(defaults: defaults), { defaults.removePersistentDomain(forName: suite) })
}

private func object(_ json: String) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

// MARK: protocol

@Suite struct CorrectingProtocolTests {
    @Test func decodesCorrecting() throws {
        let m = try ServerMessage.decode(Data(#"{"type":"correcting","seq":4,"raw":"move the standup","profile":"email"}"#.utf8))
        #expect(m == .correcting(seq: 4, raw: "move the standup", profile: "email"))
    }

    @Test func correctingWithoutAProfileIsTheDefault() throws {
        let m = try ServerMessage.decode(Data(#"{"type":"correcting","raw":"hi"}"#.utf8))
        #expect(m == .correcting(seq: 0, raw: "hi", profile: "default"))
    }

    @Test func finalStillDecodesAfterCorrecting() throws {
        let m = try ServerMessage.decode(Data(#"{"type":"final","text":"Hi.","raw":"hi","corrected":true,"profile":"email"}"#.utf8))
        #expect(m == .final(FinalResult(text: "Hi.", raw: "hi", corrected: true)))
    }

    @Test func startCarriesTheProfile() throws {
        let plain = try object(ClientMessage.start(StartOptions(correction: true)))
        #expect(plain["correction_profile"] as? String == "default")
        #expect(plain["correction_instructions"] == nil)
        let chat = try object(ClientMessage.start(StartOptions(correction: true, correctionProfile: "chat",
                                                               correctionInstructions: "ignored")))
        #expect(chat["correction_profile"] as? String == "chat")
        #expect(chat["correction_instructions"] == nil)          // only for custom
    }

    @Test func customInstructionsAreSentAndClamped() throws {
        let long = String(repeating: "é", count: 2500)
        let sent = try object(ClientMessage.start(StartOptions(correction: true, correctionProfile: "custom", correctionInstructions: long)))
        #expect((sent["correction_instructions"] as? String)?.count == 2000)
        let empty = try object(ClientMessage.start(StartOptions(correction: true, correctionProfile: "custom", correctionInstructions: "")))
        #expect(empty["correction_instructions"] == nil)
    }

    @Test func healthListsProfiles() throws {
        let json = #"{"ok":true,"correction":"available","correction_profiles":[{"id":"default","name":"Default","description":"d","rewrites":false},{"id":"notes","name":"Notes","description":"n","rewrites":true}]}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let h = try decoder.decode(Health.self, from: Data(json.utf8))
        #expect(h.correctionProfiles?.map(\.id) == ["default", "notes"])
        #expect(h.correctionProfiles?.last?.rewrites == true)
        // custom is always offered, once, last
        #expect(CorrectionProfile.offered(by: h).map(\.id) == ["default", "notes", "custom"])
        let old = try decoder.decode(Health.self, from: Data(#"{"ok":true}"#.utf8))
        #expect(old.correctionProfiles == nil)
        #expect(CorrectionProfile.offered(by: old).map(\.id) == CorrectionProfile.builtIn.map(\.id))
    }
}

// MARK: state machine

@Suite struct CorrectingMachineTests {
    private func finalizing() -> DictationMachine {
        var m = DictationMachine()
        m.handle(.hotkeyDown(at: 0)); m.handle(.hotkeyUp(at: 0.1)); m.handle(.serverReady)
        m.handle(.hotkeyDown(at: 3))
        return m
    }

    @Test func correctingThenFinalInserts() {
        var m = finalizing()
        #expect(m.handle(.correctingReceived) == [])
        #expect(m.state == .correcting)
        #expect(m.state.isActive)
        #expect(m.handle(.finalReceived) == [.insert])
        #expect(m.state == .inserting)
        m.handle(.insertionFinished)
        #expect(m.state == .idle)
    }

    @Test func finalWithoutCorrectingStillWorks() {
        var m = finalizing()
        #expect(m.handle(.finalReceived) == [.insert])
        #expect(m.state == .inserting)
    }

    @Test func aTimeoutWhilePolishingInsertsTheRaw() {
        var m = finalizing()
        m.handle(.correctingReceived)
        #expect(m.handle(.correctionFailed) == [.insert])
        #expect(m.state == .inserting)
    }

    @Test func escapeDuringPolishingCancelsAndInsertsNothing() {
        var m = finalizing()
        m.handle(.correctingReceived)
        #expect(m.handle(.escape) == [.cancel])
        #expect(m.state == .idle)
        // a late final or timeout after the cancel does nothing
        #expect(m.handle(.finalReceived) == [])
        #expect(m.handle(.correctionFailed) == [])
        #expect(m.state == .idle)
    }

    @Test func aHardFailureWhilePolishingAborts() {
        var m = finalizing()
        m.handle(.correctingReceived)
        #expect(m.handle(.failed("boom")) == [.abort("boom")])
        #expect(m.state == .error("boom"))
    }

    @Test func pressesWhilePolishingAreIgnored() {
        var m = finalizing()
        m.handle(.correctingReceived)
        #expect(m.handle(.hotkeyDown(at: 9)) == [])
        #expect(m.handle(.hotkeyUp(at: 9.1)) == [])
        #expect(m.state == .correcting)
    }

    @Test func correctingIsOnlyAcceptedWhileFinalizing() {
        var m = DictationMachine()
        #expect(m.handle(.correctingReceived) == [])
        #expect(m.state == .idle)
        m.handle(.hotkeyDown(at: 0))
        #expect(m.handle(.correctingReceived) == [])
        #expect(m.state == .connecting)
    }

    @Test func menuAndIconTreatPolishingAsActive() {
        #expect(StatusIcon.of(state: .correcting, serverReachable: true, debugRetention: false).glyph == .listening)
        var inputs = MenuInputs()
        inputs.state = .correcting
        #expect(MenuContent.header(inputs).status == "Polishing…")
        #expect(SoundCue.cue(from: .finalizing, to: .correcting, enabled: true) == nil)
        #expect(SoundCue.cue(from: .correcting, to: .inserting, enabled: true) == nil)
    }
}

// MARK: styles and preferences

@Suite struct CleanupStyleTests {
    @Test func defaultsMapTheDocumentedApps() throws {
        let (p, done) = try prefs(); defer { done() }
        func style(_ id: String) -> String { p.cleanupStyle(frontmostBundleID: id).profile }
        for id in ["com.tinyspeck.slackmacgap", "com.apple.MobileSMS", "com.hnc.Discord", "net.whatsapp.WhatsApp"] { #expect(style(id) == "chat", "\(id)") }
        for id in ["com.apple.mail", "com.microsoft.Outlook", "com.superhuman.electron"] { #expect(style(id) == "email", "\(id)") }
        for id in ["com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "com.microsoft.VSCode",
                   "com.todesktop.230313mzl4w4u92", "com.apple.dt.Xcode", "dev.zed.Zed"] { #expect(style(id) == "code", "\(id)") }
        for id in ["com.apple.Notes", "md.obsidian", "notion.id"] { #expect(style(id) == "notes", "\(id)") }
        #expect(style("com.apple.TextEdit") == "default")
        #expect(p.cleanupStyle(frontmostBundleID: nil).profile == "default")
    }

    @Test func theDefaultStyleAppliesToUnmappedApps() throws {
        let (p, done) = try prefs(); defer { done() }
        p.correctionProfile = "email"
        #expect(p.cleanupStyle(frontmostBundleID: "com.apple.TextEdit").profile == "email")
        #expect(p.cleanupStyle(frontmostBundleID: "com.tinyspeck.slackmacgap").profile == "chat")   // the app rule wins
    }

    @Test func rowsCanBeAddedChangedAndRemoved() throws {
        let (p, done) = try prefs(); defer { done() }
        var rules = p.appStyles
        #expect(rules == AppStyleRule.defaults)
        rules.removeAll { $0.bundleID == "com.apple.Notes" }
        rules.append(AppStyleRule(bundleID: "com.apple.TextEdit", profile: "email"))
        rules[0].profile = "code"
        p.appStyles = rules
        #expect(p.appStyles == rules)
        #expect(p.cleanupStyle(frontmostBundleID: "com.apple.Notes").profile == "default")
        #expect(p.cleanupStyle(frontmostBundleID: "com.apple.TextEdit").profile == "email")
        #expect(p.cleanupStyle(frontmostBundleID: rules[0].bundleID).profile == "code")
        p.appStyles = []                                    // an emptied list stays empty, not back to the defaults
        #expect(p.appStyles.isEmpty)
        #expect(p.cleanupStyle(frontmostBundleID: "com.tinyspeck.slackmacgap").profile == "default")
    }

    @Test func duplicateAndEmptyBundleIDsAreDropped() throws {
        let (p, done) = try prefs(); defer { done() }
        p.appStyles = [AppStyleRule(bundleID: "a", profile: "chat"), AppStyleRule(bundleID: "a", profile: "code"),
                       AppStyleRule(bundleID: "", profile: "chat")]
        #expect(p.appStyles == [AppStyleRule(bundleID: "a", profile: "chat")])
    }

    @Test func customSendsItsPromptAndNeedsOne() throws {
        let (p, done) = try prefs(); defer { done() }
        p.correction = true
        p.correctionProfile = "custom"
        #expect(p.startOptions().correctionProfile == "default")       // no prompt yet: the default style
        p.correctionPrompts = ["custom": "  keep it short  "]
        let o = p.startOptions()
        #expect(o.correctionProfile == "custom" && o.correctionInstructions == "keep it short" && o.correctionPrompt == "keep it short")
        // the custom prompt is not sent for another style
        p.correctionProfile = "email"
        #expect(p.startOptions().correctionInstructions == nil && p.startOptions().correctionPrompt == nil)
        #expect(p.startOptions(frontmostBundleID: "com.tinyspeck.slackmacgap").correctionProfile == "chat")
    }

    @Test func aStyleTheServerDoesNotListFallsBackToDefault() throws {
        let (p, done) = try prefs(); defer { done() }
        let list = [CorrectionProfile(id: "default", name: "Default"), CorrectionProfile(id: "chat", name: "Chat")]
        #expect(p.cleanupStyle(frontmostBundleID: "com.apple.mail", available: list).profile == "default")   // email not offered
        #expect(p.cleanupStyle(frontmostBundleID: "com.tinyspeck.slackmacgap", available: list).profile == "chat")
    }

    @Test func rawFirstDefaultsOff() throws {
        let (p, done) = try prefs(); defer { done() }
        #expect(p.insertRawFirst == false)
        p.insertRawFirst = true
        #expect(p.insertRawFirst)
    }

    @Test func cleanupSubmenuListsTheServersProfilesPlusCustom() {
        var m = MenuInputs()
        m.cleanupOn = true
        m.styleID = "email"
        m.health = Health(correction: "available", correctionLeavesMachine: false, correctionProfiles: CorrectionProfile.builtIn)
        let cleanup = MenuContent.entries(m).first { $0.title == "Clean-up" }
        #expect(cleanup?.value == "Email")
        let styles = cleanup?.submenu?.compactMap { e -> String? in if case .pickStyle = e.action { e.title } else { nil } }
        #expect(styles == ["Default", "Chat", "Email", "Code", "Notes", "Custom"])
        #expect(cleanup?.submenu?.first { $0.title == "Email" }?.mark == .on)
        #expect(cleanup?.submenu?.first { $0.title == "Custom" }?.action == .pickStyle("custom"))
        // a server that lists none has no style rows
        m.health = Health(correction: "available", correctionLeavesMachine: false)
        #expect(MenuContent.entries(m).first { $0.title == "Clean-up" }?.submenu?.contains { $0.action == .pickStyle("email") } == false)
        // clean-up off: the value says Off, the styles stay pickable
        m.health = Health(correction: "available", correctionProfiles: CorrectionProfile.builtIn)
        m.cleanupOn = false
        let off = MenuContent.entries(m).first { $0.title == "Clean-up" }
        #expect(off?.value == "Off" && off?.submenu?.contains { $0.action == .pickStyle("chat") } == true)
    }
}

// MARK: diff and HUD

@Suite struct WordDiffTests {
    @Test func marksRemovedChangedAndAddedWords() throws {
        let s = try #require(WordDiff.segments(raw: "move the standup to three thirty and uh let everyone know",
                                               cleaned: "Move the standup to 3:30 and let everyone know."))
        #expect(s.first == .init(.changed, "Move"))
        #expect(s.last == .init(.changed, "know."))
        #expect(s.contains(.init(.removed, "uh")))
        let at = try #require(s.firstIndex(of: .init(.removed, "three")))
        #expect(s[at + 1] == .init(.removed, "thirty") && s[at + 2] == .init(.added, "3:30"))
        #expect(WordDiff.cleanedText(s) == "Move the standup to 3:30 and let everyone know.")
    }

    @Test func nothingToShowForIdenticalOrTooLongText() {
        #expect(WordDiff.segments(raw: "same words", cleaned: "same words") == nil)
        let big = Array(repeating: "word", count: 400).joined(separator: " ")
        #expect(WordDiff.segments(raw: big, cleaned: big + " more") == nil)
    }

    @Test func outcomeNotesAKeptOriginal() {
        let timedOut = FinalResult(text: "raw text", corrected: false, correctionError: "timeout")
        let p = OutcomePresentation.of(.inserted(.ax), final: timedOut)
        #expect(p.keptOriginal && !p.cleaned && !p.showUseRaw)
        let ok = OutcomePresentation.of(.inserted(.ax), final: FinalResult(text: "Raw.", raw: "raw", corrected: true))
        #expect(!ok.keptOriginal && ok.cleaned)
        #expect(!OutcomePresentation.of(.inserted(.ax), final: FinalResult(text: "x")).keptOriginal)
    }

    @MainActor @Test func hudShowsRawPolishingThenSettlesOnCleaned() async {
        let m = HUDModel()
        m.reduceMotion = true
        m.beginPolishing(raw: "move the standup", style: "Email")
        #expect(m.polishing && m.stable == "move the standup" && m.status == "Polishing…" && m.styleName == "Email")
        #expect(m.indicator == .sparkle)
        let started = ContinuousClock.now
        await m.playChangeHighlight(raw: "move the standup", cleaned: "Move the standup.")
        #expect(ContinuousClock.now - started >= .milliseconds(700))     // the highlight shows for about 0.8 s
        #expect(m.diff == nil && !m.polishing && m.stable == "Move the standup.")
        m.reset()
        #expect(m.styleName == nil && !m.keptOriginal)
    }
}

// MARK: replace after insert

@MainActor
@Suite struct ReplaceInsertedTests {
    @Test func swapsTheRawForTheCleanedTextInPlace() async {
        let sys = FakeSystem(), board = FakePasteboard()
        let inserter = sys.inserter(board: board)
        #expect(canReplace(inserter, sys))
        #expect(await inserter.insert("raw words", undoRaw: "raw words", undoWindow: TextInserter.swapWindow) == .inserted(.ax))
        #expect(await inserter.replaceInserted(with: "Raw words."))
        #expect(sys.calls.last == "axReplace:3,5:raw words→Raw words.")
        #expect(board.text == "user clipboard")                    // never touches the pasteboard
        // the swap becomes the insertion, so Use raw can still put the original back
        #expect(inserter.canUseRaw)
        #expect(await inserter.useRaw() == .inserted(.ax))
        #expect(sys.calls.last == "axReplace:3,10:Raw words.→raw words")
    }

    @Test func leavesTheRawWhenTheRangeNoLongerMatches() async {
        let sys = FakeSystem(), board = FakePasteboard()
        let inserter = sys.inserter(board: board)
        _ = await inserter.insert("raw", undoRaw: "raw", undoWindow: TextInserter.swapWindow)
        sys.axReplaceResult = false
        #expect(await inserter.replaceInserted(with: "Raw.") == false)
        #expect(board.text == "user clipboard")                    // nothing copied as a fallback
        #expect(!inserter.canUseRaw)
    }

    @Test func leavesTheRawWhenTheTargetChangedOrIsSecure() async {
        for change in [{ (s: FakeSystem) in s.bundle = "com.other.App" }, { (s: FakeSystem) in s.secure = true }] {
            let sys = FakeSystem(), board = FakePasteboard()
            let inserter = sys.inserter(board: board)
            _ = await inserter.insert("raw", undoRaw: "raw", undoWindow: TextInserter.swapWindow)
            change(sys)
            #expect(await inserter.replaceInserted(with: "Raw.") == false)
            #expect(!sys.calls.contains { $0.hasPrefix("axReplace") })
        }
    }

    @Test func aPastedOrUnverifiedInsertionIsNeverReplaced() async {
        let sys = FakeSystem(), board = FakePasteboard()
        sys.ax = .notAttempted
        sys.field = ""
        let inserter = sys.inserter(board: board)
        #expect(await inserter.insert("raw", undoRaw: "raw", undoWindow: TextInserter.swapWindow) == .inserted(.paste))
        #expect(await inserter.replaceInserted(with: "Raw.") == false)
        #expect(!sys.calls.contains { $0.hasPrefix("axReplace") })
        sys.ax = .verified(nil)                                    // landed, but the range is unknown
        _ = await inserter.insert("raw", undoRaw: "raw", undoWindow: TextInserter.swapWindow)
        #expect(await inserter.replaceInserted(with: "Raw.") == false)
    }

    @Test func nothingToReplaceWithoutAnInsertion() async {
        let sys = FakeSystem()
        #expect(await sys.inserter(board: FakePasteboard()).replaceInserted(with: "x") == false)
    }

    @Test func rawFirstOnlyWhereAXIsTriedFirst() {
        let sys = FakeSystem()
        let inserter = sys.inserter(board: FakePasteboard())
        #expect(inserter.canReplaceInPlace())
        sys.bundle = "com.tinyspeck.slackmacgap"                   // paste-first (Electron)
        #expect(!inserter.canReplaceInPlace())
        sys.bundle = "com.apple.TextEdit"; sys.trusted = false
        #expect(!inserter.canReplaceInPlace())
        sys.trusted = true; sys.secure = true
        #expect(!inserter.canReplaceInPlace())
    }

    private func canReplace(_ i: TextInserter, _ s: FakeSystem) -> Bool { i.canReplaceInPlace() }
}
