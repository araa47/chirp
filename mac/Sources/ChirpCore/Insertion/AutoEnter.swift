import Foundation

/// "Press Return after inserting" (Settings → Dictation). Off by default.
public enum AutoEnter: String, CaseIterable, Sendable {
    case off, always, chatApps

    public var title: String {
        switch self {
        case .off: "Off"
        case .always: "Always"
        case .chatApps: "In chat apps only"
        }
    }

    /// The style whose per-app rules mark an app as a chat app.
    public static let chatProfile = "chat"

    /// Whether a Return follows this insertion. Pure, so it is unit-tested. Only text that landed counts (an AX or paste
    /// insertion, or a paste the app read into a field Chirp cannot read back): never a clipboard copy, an unverified
    /// write, a paste nobody read or that left a readable field unchanged (the Return would send an empty message), or a
    /// refused secure field. `skipped` is the modifier held at stop. `bundleID` is the app that would receive the key.
    public func shouldSend(after outcome: InsertionOutcome, bundleID: String?, rules: [AppStyleRule], skipped: Bool) -> Bool {
        guard !skipped, outcome.probablyInserted else { return false }
        switch self {
        case .off: return false
        case .always: return true
        case .chatApps:
            guard let bundleID else { return false }
            return rules.first { $0.bundleID == bundleID }?.profile == Self.chatProfile
        }
    }
}

/// The system calls `AutoEnterSender` depends on, injectable so it runs in tests.
@MainActor
public struct AutoEnterEnvironment {
    public var secureInputEnabled: () -> Bool
    public var frontmostBundleID: () -> String?
    /// Posts one Return key press with no modifiers. False if the event could not be created.
    public var postReturn: () -> Bool
    public var sleep: (Duration) async -> Void

    public init(secureInputEnabled: @escaping () -> Bool, frontmostBundleID: @escaping () -> String?,
                postReturn: @escaping () -> Bool, sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.secureInputEnabled = secureInputEnabled
        self.frontmostBundleID = frontmostBundleID
        self.postReturn = postReturn
        self.sleep = sleep
    }
}

/// Posts the Return after a successful insertion.
@MainActor
public final class AutoEnterSender {
    /// A pasted insertion is still being read by the app when `insert` returns; the Return waits behind it.
    public static let settleDelay: Duration = .milliseconds(120)

    private let env: AutoEnterEnvironment

    public init(env: AutoEnterEnvironment) { self.env = env }

    /// Sends Return when `mode` says so for `outcome`; true if one was posted. The frontmost app and the secure-input
    /// state are read again after the settle delay, since the Return goes to whatever has focus by then.
    public func send(after outcome: InsertionOutcome, mode: AutoEnter, rules: [AppStyleRule], skipped: Bool) async -> Bool {
        guard mode != .off, mode.shouldSend(after: outcome, bundleID: env.frontmostBundleID(), rules: rules, skipped: skipped) else { return false }
        await env.sleep(Self.settleDelay)
        guard !env.secureInputEnabled(),
              mode.shouldSend(after: outcome, bundleID: env.frontmostBundleID(), rules: rules, skipped: skipped) else { return false }
        return env.postReturn()
    }
}
