import Foundation

public enum AXInsertAttempt: Sendable, Equatable {
    /// The AX write was never made (no focused element, not settable, unreadable field, or the call failed),
    /// so falling back to paste cannot duplicate text.
    case notAttempted
    /// The write was accepted and read back. `range` (UTF-16 units) is where the text landed, if known.
    case verified(NSRange?)
    /// The write was accepted but the readback never changed: the app may still apply it.
    case unverified
}

/// The system calls insertion depends on, injectable so the strategy runs in tests.
@MainActor
public struct InsertionEnvironment {
    public var secureInputEnabled: () -> Bool
    public var axTrusted: () -> Bool
    public var frontmostBundleID: () -> String?
    /// Sets the focused element's selected text and verifies the value changed.
    public var axInsert: (String) async -> AXInsertAttempt
    /// Reselects `range` in the focused element if it still holds `expected` there, then replaces it. False otherwise.
    public var axReplace: (NSRange, String, String) async -> Bool
    /// Posts ⌘V. Returns false if the event could not be created.
    public var postPaste: () -> Bool
    /// A fingerprint of the focused field (its length and selection, or its text), or nil when it cannot be read (no
    /// Accessibility, a secure field, Chromium and Electron web fields). A paste is confirmed when it changes.
    public var focusedFieldState: () -> String?
    /// Timers: the clipboard restore and the Use raw window.
    public var sleep: (Duration) async -> Void
    /// The short polls of the check after ⌘V (`sleep` unless given), kept apart so a fake clock for the timers does
    /// not have to step through them.
    public var checkSleep: (Duration) async -> Void

    public init(secureInputEnabled: @escaping () -> Bool, axTrusted: @escaping () -> Bool,
                frontmostBundleID: @escaping () -> String?,
                axInsert: @escaping (String) async -> AXInsertAttempt,
                axReplace: @escaping (NSRange, String, String) async -> Bool,
                postPaste: @escaping () -> Bool,
                focusedFieldState: @escaping () -> String? = { nil },
                sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                checkSleep: ((Duration) async -> Void)? = nil) {
        self.secureInputEnabled = secureInputEnabled
        self.axTrusted = axTrusted
        self.frontmostBundleID = frontmostBundleID
        self.axInsert = axInsert
        self.axReplace = axReplace
        self.postPaste = postPaste
        self.focusedFieldState = focusedFieldState
        self.sleep = sleep
        self.checkSleep = checkSleep ?? sleep
    }
}

/// AX insert → paste (checked, then the pasteboard restored; left on it when the paste can't be confirmed) → copy-only.
@MainActor
public final class TextInserter {
    /// Slow apps can take a while to read the pasteboard after ⌘V. The change-count guard protects user copies.
    public static let restoreDelay: Duration = .milliseconds(600)
    /// After ⌘V the field (or the pasteboard read) is checked this often, at most `pasteChecks` times (about 600 ms).
    public static let pasteCheckInterval: Duration = .milliseconds(40)
    public static let pasteChecks = 15
    /// How long "Use raw" stays possible; matches the HUD's linger for it.
    public static let undoWindow: Duration = .seconds(5)
    /// How long a raw insertion waits for its cleaned replacement (longer than the client's clean-up timeout).
    public static let swapWindow: Duration = .seconds(20)

    /// What "Use raw" needs, and nothing more: kept only while the affordance is on screen.
    private struct Undo {
        enum Kind { case ax(NSRange?, String), other }
        var kind: Kind
        /// The app that was frontmost at insertion; the replacement is bound to it.
        var bundleID: String?
        var raw: String
    }

    /// One clipboard-restore transaction: the user's original clipboard and the change count of the last
    /// transient write of ours. Successive pastes share it, so the original is never lost to an overlap.
    private struct Restore {
        var saved: [PasteboardItem]
        var owned: Int
    }

    private let env: InsertionEnvironment
    private let pasteboard: PasteboardClient
    private var restoreTask: Task<Void, Never>?
    private var restore: Restore?
    private var restoreGeneration = 0
    private var undo: Undo?
    private var undoExpiry: Task<Void, Never>?
    private var undoGeneration = 0
    /// Where the last insertion landed (UTF-16) when it was a verified AX write that reported its range; nil otherwise.
    /// Learn from my edits watches that span.
    public private(set) var lastAXRange: NSRange?

    public init(env: InsertionEnvironment, pasteboard: PasteboardClient) {
        self.env = env
        self.pasteboard = pasteboard
    }

    /// Inserts `text`. When `undoRaw` is given, "Use raw" stays available for `undoWindow`, then everything about
    /// this insertion (including the raw transcript) is forgotten.
    public func insert(_ text: String, undoRaw: String? = nil, undoWindow: Duration = TextInserter.undoWindow) async -> InsertionOutcome {
        forgetUndo()
        lastAXRange = nil
        let bundle = env.frontmostBundleID()
        func remember(_ kind: Undo.Kind) {
            guard let undoRaw else { return }
            undo = Undo(kind: kind, bundleID: bundle, raw: undoRaw)
            armExpiry(after: undoWindow)
        }
        let plan = InsertionPolicy.plan(secureInput: env.secureInputEnabled(), axTrusted: env.axTrusted(), bundleID: bundle)
        guard case .try_(let methods) = plan else { return .refusedSecure }
        for method in methods {
            switch method {
            case .ax:
                switch await env.axInsert(text) {
                case .verified(let range):
                    lastAXRange = range
                    remember(.ax(range, text))
                    return .inserted(.ax)
                case .unverified:
                    // Never paste after an attempted AX write: if it lands late we would insert twice.
                    _ = pasteboard.write(text: text, transient: true)
                    remember(.other)
                    return .insertedUnverified
                case .notAttempted:
                    continue
                }
            case .paste:
                guard let outcome = await pasteViaPasteboard(text, app: bundle) else { continue }
                if outcome.probablyInserted { remember(.other) }
                return outcome
            case .copy:
                _ = pasteboard.write(text: text, transient: false)
                remember(.other)
                return .copied
            }
        }
        return .copied
    }

    /// Replaces what the previous `insert` put in the field with its raw transcript ("Use raw"); nil when there is
    /// nothing to replace (never offered, expired, cancelled or already used).
    ///
    /// Secure input is checked before any side effect. An AX insertion is replaced in place only while the same app
    /// is frontmost and the exact inserted range still holds the inserted text. A pasted insertion can't be verified,
    /// so Chirp never posts a blind ⌘Z: the raw text is copied for a manual ⌘V instead, as it is whenever the target changed.
    public func useRaw() async -> InsertionOutcome? {
        guard let undo else { return nil }
        forgetUndo()
        if env.secureInputEnabled() { return .refusedSecure }
        if case .ax(let range?, let text) = undo.kind, env.frontmostBundleID() == undo.bundleID,
           await env.axReplace(range, text, undo.raw) {
            return .inserted(.ax)
        }
        _ = pasteboard.write(text: undo.raw, transient: false)
        return .copied
    }

    /// True when the next insertion would try an AX write first, the only kind that can later be replaced in place.
    /// Paste-first apps (terminals, Chromium and Electron) are not, so "insert raw first" waits for the cleaned text there.
    public func canReplaceInPlace() -> Bool {
        let plan = InsertionPolicy.plan(secureInput: env.secureInputEnabled(), axTrusted: env.axTrusted(),
                                        bundleID: env.frontmostBundleID())
        if case .try_(let methods) = plan { return methods.first == .ax }
        return false
    }

    /// Swaps the text the previous `insert(_:undoRaw:undoWindow:)` put in the field for `text`, in place. Only for a
    /// verified AX insertion whose app is still frontmost and whose range still holds exactly what was inserted;
    /// otherwise false and nothing changes (the pasteboard is never touched: the original stays in the field).
    /// On success the replacement becomes the insertion, so "Use raw" can put the original back for `undoWindow`.
    public func replaceInserted(with text: String, undoWindow: Duration = TextInserter.undoWindow) async -> Bool {
        guard let undo, case .ax(let range?, let inserted) = undo.kind else { forgetUndo(); return false }
        forgetUndo()
        lastAXRange = nil
        guard !env.secureInputEnabled(), env.frontmostBundleID() == undo.bundleID,
              await env.axReplace(range, inserted, text) else { return false }
        lastAXRange = NSRange(location: range.location, length: text.utf16.count)
        self.undo = Undo(kind: .ax(NSRange(location: range.location, length: text.utf16.count), text),
                         bundleID: undo.bundleID, raw: undo.raw)
        armExpiry(after: undoWindow)
        return true
    }

    /// Drops the raw-replacement state (expiry, cancel, new dictation).
    public func forgetUndo() {
        undo = nil
        undoExpiry?.cancel()
        undoExpiry = nil
        undoGeneration += 1
    }

    public var canUseRaw: Bool { undo != nil }

    private func armExpiry(after window: Duration) {
        let generation = undoGeneration
        undoExpiry = Task { [env] in
            await env.sleep(window)
            guard !Task.isCancelled else { return }
            self.expireUndo(ifGeneration: generation)
        }
    }

    private func expireUndo(ifGeneration generation: Int) {
        if generation == undoGeneration { forgetUndo() }
    }

    /// Pastes `text` with ⌘V and checks that it arrived: the focused field changed (when it can be read), or at least
    /// an app read the pasteboard. A confirmed paste puts the user's clipboard back after `restoreDelay`; an unconfirmed
    /// one leaves the text on the clipboard as a normal copy so ⌘V gets it. nil when ⌘V could not be posted.
    /// The log says what happened (never the text): the app at insertion and at ⌘V, the change counts, when the
    /// pasteboard was read and what the check found.
    private func pasteViaPasteboard(_ text: String, app: String?) async -> InsertionOutcome? {
        restoreTask?.cancel()
        restoreGeneration += 1
        let before = env.focusedFieldState()
        let countBefore = pasteboard.changeCount
        // Still inside a restore window and the clipboard still holds our transient text: keep the user's original.
        let saved: [PasteboardItem]
        if let r = restore, countBefore == r.owned { saved = r.saved } else { saved = pasteboard.snapshot() }
        let ours = pasteboard.writeTracked(text: text)
        restore = Restore(saved: saved, owned: ours)
        let frontAtPaste = env.frontmostBundleID()
        let posted = ProcessInfo.processInfo.systemUptime
        guard env.postPaste() else {
            pasteboard.restore(saved)
            restore = nil
            return nil
        }
        let generation = restoreGeneration
        var changed = false
        // Nothing to observe (an unreadable field and a pasteboard that can't tell reads): no point waiting.
        let checks = before != nil || pasteboard.tracksReads ? Self.pasteChecks : 0
        for _ in 0..<checks {
            await env.checkSleep(Self.pasteCheckInterval)
            if let before, let now = env.focusedFieldState(), now != before { changed = true; break }
            // An unreadable field: the read is all there is to wait for.
            if before == nil, pasteboard.trackedReadUptime != nil { break }
        }
        let read = pasteboard.trackedReadUptime
        let readNote = !pasteboard.tracksReads ? "untracked" : read.map { $0 < posted ? "early" : String(Int((($0 - posted) * 1000).rounded())) } ?? "none"
        let outcome: InsertionOutcome
        if changed {
            outcome = .inserted(.paste)
        } else if before != nil, env.focusedFieldState() != nil {
            outcome = .pasteUnconfirmed(.unchanged)
        } else if pasteboard.tracksReads, read == nil {
            outcome = .pasteUnconfirmed(.notRead)
        } else {
            outcome = .pasteUnconfirmed(.unreadable)
        }
        var clipboard: String
        if case .inserted = outcome, generation == restoreGeneration {
            clipboard = "restore"
            // Give a slow app time to finish reading, then put the user's clipboard back,
            // but only if nobody else has written to it in the meantime. A newer paste supersedes this task.
            restoreTask = Task { [pasteboard, env] in
                await env.sleep(Self.restoreDelay)
                self.finishRestore(generation: generation, pasteboard: pasteboard)
            }
        } else if generation == restoreGeneration, pasteboard.changeCount == ours {
            // Unconfirmed: the text stays where ⌘V finds it, as a normal copy that outlives Chirp. The user's clipboard
            // is not put back.
            restore = nil
            _ = pasteboard.write(text: text, transient: false)
            clipboard = "kept"
        } else if generation == restoreGeneration {
            restore = nil
            clipboard = "user_copied"
        } else {
            clipboard = "superseded"   // a newer paste owns the restore now
        }
        let waited = Int(((ProcessInfo.processInfo.systemUptime - posted) * 1000).rounded())
        chirpLog.info("paste app=\(app ?? "-", privacy: .public) front_at_v=\(frontAtPaste ?? "-", privacy: .public) cc_before=\(countBefore, privacy: .public) cc_ours=\(ours, privacy: .public) read_ms=\(readNote, privacy: .public) field=\(before == nil ? "unreadable" : changed ? "changed" : "unchanged", privacy: .public) wait_ms=\(waited, privacy: .public) outcome=\(outcome.logName, privacy: .public) clipboard=\(clipboard, privacy: .public)")
        return outcome
    }

    private func finishRestore(generation: Int, pasteboard: PasteboardClient) {
        guard generation == restoreGeneration, let r = restore else { return }
        restore = nil
        let ours = pasteboard.changeCount == r.owned
        if ours { pasteboard.restore(r.saved) }
        chirpLog.info("paste restore=\(ours ? "done" : "skipped_user_copied", privacy: .public)")
    }

    /// Wait for a pending pasteboard restore (tests and shutdown).
    public func settle() async { await restoreTask?.value }
}
