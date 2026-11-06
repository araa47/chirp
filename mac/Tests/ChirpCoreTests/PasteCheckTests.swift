import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// After ⌘V Chirp checks that the text arrived. When it can't confirm it, the text stays on the clipboard (a normal
/// copy) instead of being swapped back for the user's clipboard, so a paste a web page dropped is one ⌘V away.
@MainActor
@Suite struct PasteCheckTests {
    static let ego = "com.citrolabs.ego.lite"

    @Test func aReadableFieldThatChangesConfirmsThePasteAndRestoresTheClipboard() async {
        let sys = FakeSystem(), board = FakePasteboard()
        sys.bundle = "com.apple.Terminal"
        sys.field = "$ "
        board.tracksReads = true
        let inserter = sys.inserter(board: board)
        #expect(await inserter.insert("ls -la") == .inserted(.paste))
        #expect(sys.field == "$ ls -la")
        await inserter.settle()
        #expect(board.text == "user clipboard")
    }

    @Test func aReadableFieldThatStaysTheSameKeepsTheTextOnTheClipboard() async {
        let sys = FakeSystem(), board = FakePasteboard()
        sys.bundle = "com.apple.Terminal"
        sys.field = "$ "
        sys.pasteLands = false
        board.tracksReads = true
        let inserter = sys.inserter(board: board)
        #expect(await inserter.insert("ls -la") == .pasteUnconfirmed(.unchanged))
        await inserter.settle()
        #expect(board.text == "ls -la")
        #expect(board.lastWriteTransient == false)      // a normal copy: it outlives Chirp and shows in clipboard managers
    }

    /// The 2026-11-06 report: ego (Chromium) read the clipboard on ⌘V, but its web page never asked for the text, so
    /// nothing was inserted, and 600 ms later Chirp swapped the user's old clipboard back. Now the text stays.
    @Test func aChromiumPasteThatAWebPageDroppedStaysOnTheClipboard() async {
        let sys = FakeSystem(), board = FakePasteboard()
        sys.bundle = Self.ego
        sys.field = nil                                 // Chromium web fields can't be read back
        sys.pasteLands = false
        board.tracksReads = true
        let inserter = sys.inserter(board: board)
        #expect(await inserter.insert("ship it tonight") == .pasteUnconfirmed(.unreadable))
        await inserter.settle()
        #expect(board.text == "ship it tonight")
        #expect(board.lastWriteTransient == false)
    }

    @Test func aPasteNobodyReadIsLikelyFailed() async {
        let sys = FakeSystem(), board = FakePasteboard()
        sys.bundle = Self.ego
        sys.appReadsPaste = false
        board.tracksReads = true
        let inserter = sys.inserter(board: board)
        let outcome = await inserter.insert("ship it tonight")
        #expect(outcome == .pasteUnconfirmed(.notRead))
        #expect(PasteDoubt.notRead.likelyFailed && PasteDoubt.unchanged.likelyFailed && !PasteDoubt.unreadable.likelyFailed)
        #expect(!outcome.probablyInserted && outcome.leftOnClipboard)
        await inserter.settle()
        #expect(board.text == "ship it tonight")
    }

    @Test func aCopyMadeDuringTheCheckIsNeverOverwritten() async {
        let sys = FakeSystem(), board = FakePasteboard()
        sys.bundle = Self.ego
        sys.pasteLands = false
        board.tracksReads = true
        var copied = false
        let inserter = TextInserter(env: InsertionEnvironment(
            secureInputEnabled: { false }, axTrusted: { true }, frontmostBundleID: { Self.ego },
            axInsert: { _ in .notAttempted }, axReplace: { _, _, _ in false },
            postPaste: { true }, focusedFieldState: { nil },
            sleep: { _ in
                // The user copies something while Chirp waits for the paste.
                if !copied { copied = true; _ = board.write(text: "user copied this", transient: false) }
            }), pasteboard: board)
        #expect(await inserter.insert("ship it tonight") == .pasteUnconfirmed(.notRead))
        await inserter.settle()
        #expect(board.text == "user copied this")
    }

    @Test func aReadableFieldIsCheckedAtMostAboutSixHundredMilliseconds() {
        let total = TextInserter.pasteCheckInterval * TextInserter.pasteChecks
        #expect(total <= .milliseconds(700) && total >= .milliseconds(400))
    }

    @Test func useRawIsOfferedOnlyWhenThePasteProbablyLanded() async {
        let sys = FakeSystem(), board = FakePasteboard()
        sys.bundle = Self.ego
        board.tracksReads = true
        let inserter = sys.inserter(board: board)
        _ = await inserter.insert("Ship it tonight.", undoRaw: "ship it tonight")
        #expect(inserter.canUseRaw)
        sys.appReadsPaste = false
        _ = await inserter.insert("Ship it tonight.", undoRaw: "ship it tonight")
        #expect(!inserter.canUseRaw)
    }

    @Test func returnFollowsOnlyAPasteThatProbablyLanded() {
        let rules: [AppStyleRule] = []
        #expect(AutoEnter.always.shouldSend(after: .pasteUnconfirmed(.unreadable), bundleID: Self.ego, rules: rules, skipped: false))
        #expect(!AutoEnter.always.shouldSend(after: .pasteUnconfirmed(.notRead), bundleID: Self.ego, rules: rules, skipped: false))
        #expect(!AutoEnter.always.shouldSend(after: .pasteUnconfirmed(.unchanged), bundleID: Self.ego, rules: rules, skipped: false))
    }

    @Test func everyUnconfirmedPasteIsKeptInHistoryAndWatchedForEdits() {
        for doubt in [PasteDoubt.unreadable, .notRead, .unchanged] {
            #expect(HistoryPolicy.shouldRecord(enabled: true, outcome: .pasteUnconfirmed(doubt), secureField: false,
                                               bundleID: Self.ego, excluded: [], text: "hello"))
            #expect(LearnWatchPlan.plan(learningEnabled: true, historyEnabled: true, isPrivate: false, excluded: false,
                                        secureField: false, outcome: .pasteUnconfirmed(doubt), axRange: nil) == .find)
        }
    }
}

/// The menu's first rows: the newest dictation with Paste Again and Copy, one click each.
@Suite struct LastDictationMenuTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    func inputs(_ configure: (inout MenuInputs) -> Void = { _ in }) -> MenuInputs {
        var m = MenuInputs()
        m.now = Self.now
        m.health = Health(engine: "parakeet", ready: true)
        m.lastDictation = LastDictation(preview: "Ship the fix tonight and tell the team in the release channel",
                                        date: Self.now.addingTimeInterval(-120), historyID: "abc")
        m.pasteLastShortcut = "⌃⌥V"
        configure(&m)
        return m
    }

    @Test func theNewestDictationLeadsTheMenuWithPasteAgainAndCopy() {
        let rows = MenuContent.entries(inputs()).filter { !$0.isSeparator }
        #expect(rows[0].title.hasPrefix("“Ship the fix") && rows[0].title.hasSuffix("…”"))
        #expect(rows[0].action == .openDictation("abc"))
        #expect(rows[1].title == "Paste Again" && rows[1].shortcut == "⌃⌥V" && rows[1].action == .pasteLast)
        #expect(rows[2].title == "Copy" && rows[2].action == .copyLast)
        #expect(rows[3].title == "Start Dictation")
    }

    @Test func pasteAgainWaitsWhileDictatingOrPausedAndNothingShowsBeforeTheFirstDictation() {
        let busy = MenuContent.entries(inputs { $0.state = .listening }).first { $0.title == "Paste Again" }
        #expect(busy?.action == nil)
        let paused = MenuContent.entries(inputs { $0.paused = true }).first { $0.title == "Paste Again" }
        #expect(paused?.action == nil && paused?.shortcut == nil)
        #expect(!MenuContent.entries(inputs { $0.lastDictation = nil }).contains { $0.title == "Paste Again" })
        // With history off the preview opens nothing, but Paste Again and Copy still work.
        let off = MenuContent.entries(inputs { $0.lastDictation?.historyID = nil; $0.historyEnabled = false })
        #expect(off.first { !$0.isSeparator }?.action == nil)
        #expect(off.first { $0.title == "Copy" }?.action == .copyLast)
    }

    @Test func dictationHistoryShowsItsGlobalShortcut() {
        let rows = MenuContent.entries(inputs { $0.historyShortcut = "⌃⌥H" })
        let history = rows.first { $0.title == "Dictation History…" }
        #expect(history?.shortcut == "⌃⌥H" && history?.keyEquivalent == nil)
        let fallback = MenuContent.entries(inputs()).first { $0.title == "Dictation History…" }
        #expect(fallback?.shortcut == "⌥⌘H" && fallback?.keyEquivalent == "h")
    }

    @Test func theNewShortcutsHaveDefaultsThatValidateAndDoNotCollide() {
        #expect(ChirpShortcut.pasteLast.defaultCombo.title == "⌃⌥V")
        #expect(ChirpShortcut.openHistory.defaultCombo.title == "⌃⌥H")
        for s in [ChirpShortcut.pasteLast, .openHistory] {
            #expect(s.conflict(s.defaultCombo) { $0.defaultCombo } == nil)
        }
    }
}

#if os(macOS)
import AppKit

/// The real `NSPasteboard` read tracking, on a private named pasteboard (never the user's clipboard).
@MainActor
@Suite struct SystemPasteboardReadTrackingTests {
    @Test func aTrackedWriteKnowsWhenAnAppReadsItAndPastesTheSameText() throws {
        let board = NSPasteboard(name: .init("dev.chirp.tests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let pasteboard = SystemPasteboard(board: board)
        #expect(pasteboard.tracksReads)
        let count = pasteboard.writeTracked(text: "ship it tonight")
        #expect(count == board.changeCount)
        #expect(pasteboard.trackedReadUptime == nil)    // nobody asked yet
        // Clipboard managers look at the types first: that is not a read.
        #expect(board.types?.contains(.init(PasteboardMarkers.transient)) == true)
        #expect(pasteboard.trackedReadUptime == nil)
        let before = ProcessInfo.processInfo.systemUptime
        #expect(board.string(forType: .string) == "ship it tonight")
        let read = try #require(pasteboard.trackedReadUptime)
        #expect(read >= before)
        // A plain write afterwards (an unconfirmed paste kept as a normal copy) has no promise behind it.
        _ = pasteboard.write(text: "ship it tonight", transient: false)
        #expect(board.string(forType: .string) == "ship it tonight")
        #expect(board.types?.contains(.init(PasteboardMarkers.transient)) == false)
    }
}
#endif
