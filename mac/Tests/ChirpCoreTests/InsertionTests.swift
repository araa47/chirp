import Foundation
import Testing
@testable import ChirpCore

@MainActor
final class FakePasteboard: PasteboardClient {
    var changeCount = 1
    var items: [PasteboardItem] = [["public.utf8-plain-text": Data("user clipboard".utf8)]]
    var lastWriteTransient: Bool?
    func snapshot() -> [PasteboardItem] { items }
    func write(text: String, transient: Bool) -> Int {
        items = [["public.utf8-plain-text": Data(text.utf8)]]
        lastWriteTransient = transient
        changeCount += 1
        return changeCount
    }
    func restore(_ saved: [PasteboardItem]) { items = saved; changeCount += 1 }
    var text: String? { items.first?["public.utf8-plain-text"].flatMap { String(data: $0, encoding: .utf8) } }
}

/// Scriptable stand-in for the system calls; records what was invoked.
@MainActor
final class FakeSystem {
    var secure = false, trusted = true, bundle: String? = "com.apple.TextEdit"
    var ax: AXInsertAttempt = .verified(NSRange(location: 3, length: 5))
    var axReplaceResult = true
    var pasteResult = true
    var calls: [String] = []

    func inserter(board: FakePasteboard) -> TextInserter {
        TextInserter(env: InsertionEnvironment(
            secureInputEnabled: { self.secure }, axTrusted: { self.trusted }, frontmostBundleID: { self.bundle },
            axInsert: { _ in self.calls.append("ax"); return self.ax },
            axReplace: { range, expected, new in self.calls.append("axReplace:\(range.location),\(range.length):\(expected)→\(new)"); return self.axReplaceResult },
            postPaste: { self.calls.append("paste"); return self.pasteResult },
            // The restore delay is instant, but the undo window must not elapse mid-test (cancelled by forgetUndo).
            sleep: { d in if d >= .seconds(1) { try? await Task.sleep(for: d) } }), pasteboard: board)
    }
}

@MainActor
@Suite struct InsertionTests {
    // MARK: policy

    @Test func policyOrder() {
        #expect(InsertionPolicy.plan(secureInput: true, axTrusted: true, bundleID: nil) == .refuseSecure)
        #expect(InsertionPolicy.plan(secureInput: false, axTrusted: false, bundleID: "com.apple.TextEdit") == .try_([.copy]))
        #expect(InsertionPolicy.plan(secureInput: false, axTrusted: true, bundleID: "com.apple.TextEdit") == .try_([.ax, .paste, .copy]))
        #expect(InsertionPolicy.plan(secureInput: false, axTrusted: true, bundleID: nil) == .try_([.ax, .paste, .copy]))
        for id in ["com.apple.Terminal", "com.google.Chrome", "com.tinyspeck.slackmacgap", "com.microsoft.VSCode", "com.hnc.Discord", "notion.id"] {
            #expect(InsertionPolicy.plan(secureInput: false, axTrusted: true, bundleID: id) == .try_([.paste, .copy]), "\(id)")
        }
    }

    @Test(arguments: ["com.openai.codex", "com.citrolabs.ego.lite"])
    func webBackedEditorsPasteWithoutAttemptingAnAXWrite(bundleID: String) async {
        let sys = FakeSystem(), board = FakePasteboard()
        sys.bundle = bundleID
        // These fields may accept AXSelectedText without applying it. Once attempted,
        // the late-write safety rule correctly prevents an automatic paste fallback.
        sys.ax = .unverified
        let inserter = sys.inserter(board: board)
        #expect(await inserter.insert("dictated text") == .inserted(.paste))
        #expect(sys.calls == ["paste"])
        #expect(board.text == "dictated text")
        await inserter.settle()
        #expect(board.text == "user clipboard")
    }

    @Test(arguments: ["com.openai.codex", "com.citrolabs.ego.lite"])
    func webBackedEditorsKeepSecureInputAndPermissionFallbacks(bundleID: String) async {
        let sys = FakeSystem(), board = FakePasteboard()
        sys.bundle = bundleID
        sys.trusted = false
        #expect(await sys.inserter(board: board).insert("dictated text") == .copied)
        #expect(sys.calls.isEmpty)
        sys.trusted = true
        sys.secure = true
        #expect(await sys.inserter(board: board).insert("private") == .refusedSecure)
        #expect(sys.calls.isEmpty && board.text == "dictated text")
    }

    // MARK: AX

    @Test func verifiedAXLeavesPasteboardAlone() async {
        let sys = FakeSystem(), board = FakePasteboard()
        #expect(await sys.inserter(board: board).insert("hello") == .inserted(.ax))
        #expect(sys.calls == ["ax"])
        #expect(board.text == "user clipboard")
    }

    /// An app that applies the AX write late: the set succeeded but the readback never changed in time.
    @Test func lateAXWriteIsNeverFollowedByPaste() async {
        let sys = FakeSystem(), board = FakePasteboard()
        sys.ax = .unverified
        let inserter = sys.inserter(board: board)
        #expect(await inserter.insert("hello") == .insertedUnverified)
        #expect(sys.calls == ["ax"])                    // no ⌘V, so no duplicate when the write lands late
        #expect(board.text == "hello")                  // left on the pasteboard for a manual ⌘V
        #expect(board.lastWriteTransient == true)
        await inserter.settle()
        #expect(board.text == "hello")                  // and not restored away
    }

    @Test func fallsBackToPasteOnlyWhenAXWasNotAttempted() async {
        let sys = FakeSystem(), board = FakePasteboard()
        sys.ax = .notAttempted
        let inserter = sys.inserter(board: board)
        #expect(await inserter.insert("hello") == .inserted(.paste))
        #expect(sys.calls == ["ax", "paste"])
        #expect(board.lastWriteTransient == true)
        await inserter.settle()
        #expect(board.text == "user clipboard")
    }

    // MARK: paste and clipboard restore

    @Test func doesNotRestoreIfClipboardChangedMeanwhile() async {
        let sys = FakeSystem(), board = FakePasteboard()
        sys.bundle = "com.apple.Terminal"
        let inserter = sys.inserter(board: board)
        _ = await inserter.insert("hello")
        #expect(sys.calls == ["paste"])                 // terminals skip AX
        board.items = [["public.utf8-plain-text": Data("user copied something new".utf8)]]
        board.changeCount += 1                          // the user copied during the restore window
        await inserter.settle()
        #expect(board.text == "user copied something new")
    }

    @Test func pasteFailureRestoresAndCopies() async {
        let sys = FakeSystem(), board = FakePasteboard()
        sys.ax = .notAttempted; sys.pasteResult = false
        #expect(await sys.inserter(board: board).insert("hello") == .copied)
        #expect(board.text == "hello")
        #expect(board.lastWriteTransient == false)      // copy-only stays on the clipboard for ⌘V
    }

    @Test func untrustedCopiesOnly() async {
        let sys = FakeSystem(), board = FakePasteboard()
        sys.trusted = false
        #expect(await sys.inserter(board: board).insert("hello") == .copied)
        #expect(sys.calls.isEmpty)
    }

    @Test func secureInputRefusesAndTouchesNothing() async {
        let sys = FakeSystem(), board = FakePasteboard()
        sys.secure = true
        #expect(await sys.inserter(board: board).insert("hello") == .refusedSecure)
        #expect(sys.calls.isEmpty)
        #expect(board.text == "user clipboard")
    }

    // MARK: Use raw

    @Test func useRawReplacesTheExactAXRangeWithoutUndo() async {
        let sys = FakeSystem(), board = FakePasteboard()
        let inserter = sys.inserter(board: board)
        _ = await inserter.insert("Hello, world.", undoRaw: "hello world")
        #expect(await inserter.useRaw() == .inserted(.ax))
        #expect(sys.calls == ["ax", "axReplace:3,5:Hello, world.→hello world"])
    }

    @Test func useRawCopiesWhenTheFieldChanged() async {
        let sys = FakeSystem(), board = FakePasteboard()
        sys.axReplaceResult = false
        let inserter = sys.inserter(board: board)
        _ = await inserter.insert("Hello, world.", undoRaw: "hello world")
        #expect(await inserter.useRaw() == .copied)
        #expect(board.text == "hello world")
    }

    /// A paste can't be verified, so there is no blind ⌘Z: the raw text is copied for a manual ⌘V.
    @Test func useRawAfterPasteCopiesRawWithoutUndoOrPaste() async {
        let sys = FakeSystem(), board = FakePasteboard()
        sys.bundle = "com.apple.Terminal"
        let inserter = sys.inserter(board: board)
        _ = await inserter.insert("Hello, world.", undoRaw: "hello world")
        #expect(await inserter.useRaw() == .copied)
        #expect(sys.calls == ["paste"])
        await inserter.settle()
        #expect(board.text == "hello world")
        #expect(board.lastWriteTransient == false)
    }

    @Test func useRawNeverActsOnAnotherApp() async {
        let sys = FakeSystem(), board = FakePasteboard()
        let inserter = sys.inserter(board: board)
        _ = await inserter.insert("Hello, world.", undoRaw: "hello world")
        sys.bundle = "com.apple.mail"
        #expect(await inserter.useRaw() == .copied)
        #expect(sys.calls == ["ax"])                    // no axReplace in the other app's field
        #expect(board.text == "hello world")
    }

    @Test func useRawRefusesInSecureInputBeforeAnySideEffect() async {
        let sys = FakeSystem(), board = FakePasteboard()
        let inserter = sys.inserter(board: board)
        _ = await inserter.insert("Hello, world.", undoRaw: "hello world")
        sys.secure = true
        #expect(await inserter.useRaw() == .refusedSecure)
        #expect(sys.calls == ["ax"])
        #expect(board.text == "user clipboard")
        #expect(await inserter.useRaw() == nil)         // and it is spent
    }

    @Test func useRawWithNothingToReplaceDoesNothing() async {
        let sys = FakeSystem(), board = FakePasteboard()
        let inserter = sys.inserter(board: board)
        #expect(await inserter.useRaw() == nil)
        _ = await inserter.insert("plain")             // no correction, so no raw is kept
        #expect(!inserter.canUseRaw)
        #expect(await inserter.useRaw() == nil)
        #expect(board.text == "user clipboard")
    }
}
