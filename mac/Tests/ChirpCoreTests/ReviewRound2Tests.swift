import Foundation
import Testing
@testable import ChirpCore

/// R2-02, R2-03 and R2-05 from docs/review/round2.md. Only injected fakes: no AX, pasteboard, microphone or socket.
@MainActor
@Suite struct ReviewRound2Tests {
    /// An inserter whose sleeps park on continuations the test resumes: a fake clock.
    @MainActor final class Clock {
        var sleepers: [CheckedContinuation<Void, Never>] = [] {
            didSet {
                let ready = waiters.filter { $0.0 <= sleepers.count }
                waiters.removeAll { $0.0 <= sleepers.count }
                for (_, c) in ready { c.resume() }
            }
        }
        private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
        /// Suspends until `n` sleeps have parked, without spinning on the main actor (#315).
        func waitForSleepers(_ n: Int) async {
            guard sleepers.count < n else { return }
            await withCheckedContinuation { waiters.append((n, $0)) }
        }
        func fireAll() {
            let pending = sleepers
            sleepers.removeAll()
            for s in pending { s.resume() }
        }
    }

    private func inserter(_ clock: Clock, board: FakePasteboard, bundle: String? = "com.apple.Terminal",
                          ax: AXInsertAttempt = .notAttempted, calls: @escaping (String) -> Void = { _ in }) -> TextInserter {
        TextInserter(env: InsertionEnvironment(
            secureInputEnabled: { false }, axTrusted: { true }, frontmostBundleID: { bundle },
            axInsert: { _ in ax }, axReplace: { _, _, _ in calls("axReplace"); return true },
            postPaste: { calls("paste"); return true },
            sleep: { _ in await withCheckedContinuation { clock.sleepers.append($0) } }
        ), pasteboard: board)
    }

    // MARK: R2-03

    @Test func overlappingPastesPreserveOriginalClipboard() async {
        let board = FakePasteboard(), clock = Clock()
        let inserter = inserter(clock, board: board)
        _ = await inserter.insert("synthetic first")
        _ = await inserter.insert("synthetic second")
        // Both restore tasks must reach the barrier before either is resumed.
        await clock.waitForSleepers(2)
        clock.fireAll()
        await inserter.settle()
        #expect(board.text == "user clipboard")
    }

    @Test func aUserCopyBetweenPastesStartsANewTransaction() async {
        let board = FakePasteboard(), clock = Clock()
        let inserter = inserter(clock, board: board)
        _ = await inserter.insert("synthetic first")
        board.items = [["public.utf8-plain-text": Data("copied meanwhile".utf8)]]
        board.changeCount += 1
        _ = await inserter.insert("synthetic second")
        await clock.waitForSleepers(2)
        clock.fireAll()
        await inserter.settle()
        #expect(board.text == "copied meanwhile")      // never rolled back to the stale original
    }

    @Test func aSupersededRestoreDoesNothingEvenIfItResumesLast() async {
        let board = FakePasteboard(), clock = Clock()
        let inserter = inserter(clock, board: board)
        _ = await inserter.insert("synthetic first")
        _ = await inserter.insert("synthetic second")
        await clock.waitForSleepers(2)
        let first = clock.sleepers[0], second = clock.sleepers[1]
        clock.sleepers.removeAll()
        second.resume()
        await inserter.settle()
        #expect(board.text == "user clipboard")
        first.resume()
        await Task.yield()
        #expect(board.text == "user clipboard")
    }

    // MARK: R2-02

    @Test func useRawDoesNotUndoInAnotherApplication() async {
        var calls: [String] = []
        let board = FakePasteboard()
        var bundle = "com.apple.Terminal"
        let inserter = TextInserter(env: InsertionEnvironment(
            secureInputEnabled: { false }, axTrusted: { true }, frontmostBundleID: { bundle },
            axInsert: { _ in .notAttempted }, axReplace: { _, _, _ in calls.append("axReplace"); return true },
            postPaste: { calls.append("paste"); return true },
            sleep: { d in if d >= .seconds(1) { try? await Task.sleep(for: d) } }), pasteboard: board)
        _ = await inserter.insert("Synthetic corrected.", undoRaw: "synthetic raw")
        await inserter.settle()
        bundle = "com.apple.TextEdit"
        calls.removeAll()
        _ = await inserter.useRaw()
        #expect(calls.isEmpty)
    }

    @Test func useRawDoesNotUndoInSecureInput() async {
        let system = FakeSystem(), board = FakePasteboard()
        system.bundle = "com.apple.Terminal"
        let inserter = system.inserter(board: board)
        _ = await inserter.insert("Synthetic corrected.", undoRaw: "synthetic raw")
        await inserter.settle()
        system.secure = true
        system.calls.removeAll()
        #expect(await inserter.useRaw() == .refusedSecure)
        #expect(system.calls.isEmpty)
    }

    // MARK: R2-05

    @Test func rawTranscriptIsForgottenWhenTheUndoWindowExpires() async {
        let board = FakePasteboard(), clock = Clock()
        var calls: [String] = []
        let inserter = inserter(clock, board: board, bundle: "com.apple.TextEdit",
                                ax: .verified(NSRange(location: 0, length: 4)), calls: { calls.append($0) })
        _ = await inserter.insert("Synthetic corrected.", undoRaw: "synthetic raw", undoWindow: .seconds(5))
        #expect(inserter.canUseRaw)
        await clock.waitForSleepers(1)
        clock.fireAll()                                  // the five seconds elapse
        #expect(await pollUntil(within: 60) { !inserter.canUseRaw })
        #expect(await inserter.useRaw() == nil)
        #expect(calls.isEmpty && board.text == "user clipboard")
    }

    @Test func newInsertionAndCancelForgetTheEarlierRaw() async {
        let board = FakePasteboard(), clock = Clock()
        let inserter = inserter(clock, board: board, bundle: "com.apple.TextEdit", ax: .verified(NSRange(location: 0, length: 4)))
        _ = await inserter.insert("one", undoRaw: "raw one")
        _ = await inserter.insert("two")                 // a new dictation without a correction
        #expect(!inserter.canUseRaw)
        _ = await inserter.insert("three", undoRaw: "raw three")
        inserter.forgetUndo()                            // a cancelled or new dictation
        #expect(await inserter.useRaw() == nil)
        // The stale expiry of an earlier insertion must not clear a newer one.
        _ = await inserter.insert("four", undoRaw: "raw four")
        await clock.waitForSleepers(3)
        let stale = clock.sleepers.removeFirst()
        stale.resume()
        await Task.yield(); await Task.yield()
        #expect(inserter.canUseRaw)
        clock.fireAll()
    }

    @Test func insertionWithoutACorrectionKeepsNothing() async {
        let system = FakeSystem(), board = FakePasteboard()
        let inserter = system.inserter(board: board)
        _ = await inserter.insert("Synthetic.")
        #expect(!inserter.canUseRaw)
    }
}
