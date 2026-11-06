import Foundation
import Testing
@testable import ChirpCore

@MainActor
final class FakeKeys {
    var secure = false, bundle: String? = "com.tinyspeck.slackmacgap", posted = 0, postResult = true
    var order: [String] = []
    func sender() -> AutoEnterSender {
        AutoEnterSender(env: AutoEnterEnvironment(
            secureInputEnabled: { self.secure }, frontmostBundleID: { self.bundle },
            postReturn: { self.posted += 1; self.order.append("return"); return self.postResult },
            sleep: { _ in self.order.append("wait") }))
    }
}

@MainActor
@Suite struct AutoEnterTests {
    let rules = AppStyleRule.defaults

    @Test func offByDefaultAndStored() {
        let suite = UserDefaults(suiteName: "autoenter-\(UUID())")!
        #expect(Preferences(defaults: suite).autoEnter == .off)
        Preferences(defaults: suite).autoEnter = .chatApps
        #expect(Preferences(defaults: suite).autoEnter == .chatApps)
        suite.set("bogus", forKey: "autoEnter")
        #expect(Preferences(defaults: suite).autoEnter == .off)
    }

    @Test func offNeverSends() async {
        let keys = FakeKeys()
        #expect(await keys.sender().send(after: .inserted(.ax), mode: .off, rules: rules, skipped: false) == false)
        #expect(keys.posted == 0)
    }

    @Test func alwaysSendsAfterAXAndPaste() async {
        for method in [InsertionMethod.ax, .paste] {
            let keys = FakeKeys()
            keys.bundle = "com.apple.TextEdit"
            #expect(await keys.sender().send(after: .inserted(method), mode: .always, rules: rules, skipped: false))
            #expect(keys.order == ["wait", "return"], "Return waits for the paste to land")
        }
    }

    @Test func neverAfterAFailedOrCopiedInsertion() async {
        for outcome in [InsertionOutcome.copied, .insertedUnverified, .refusedSecure, .pasteUnconfirmed(.notRead), .pasteUnconfirmed(.unchanged)] {
            let keys = FakeKeys()
            #expect(await keys.sender().send(after: outcome, mode: .always, rules: rules, skipped: false) == false)
            #expect(keys.posted == 0, "\(outcome)")
        }
    }

    @Test func chatAppsOnlyUsesTheChatRules() async {
        let keys = FakeKeys()
        let sender = keys.sender()
        #expect(await sender.send(after: .inserted(.paste), mode: .chatApps, rules: rules, skipped: false))
        for id in ["com.apple.mail", "com.apple.Terminal", "com.apple.TextEdit"] {
            keys.bundle = id
            #expect(await sender.send(after: .inserted(.ax), mode: .chatApps, rules: rules, skipped: false) == false, "\(id)")
        }
        keys.bundle = nil
        #expect(await sender.send(after: .inserted(.ax), mode: .chatApps, rules: rules, skipped: false) == false)
        #expect(keys.posted == 1)
    }

    @Test func chatAppsFollowTheEditedMapping() async {
        let keys = FakeKeys()
        keys.bundle = "com.apple.TextEdit"
        let edited = rules + [AppStyleRule(bundleID: "com.apple.TextEdit", profile: "chat")]
        #expect(await keys.sender().send(after: .inserted(.ax), mode: .chatApps, rules: edited, skipped: false))
        keys.bundle = "com.tinyspeck.slackmacgap"
        let none = rules.filter { $0.profile != "chat" }
        #expect(await keys.sender().send(after: .inserted(.ax), mode: .chatApps, rules: none, skipped: false) == false)
    }

    @Test func heldModifierSkipsEvenForAlways() async {
        let keys = FakeKeys()
        #expect(await keys.sender().send(after: .inserted(.ax), mode: .always, rules: rules, skipped: true) == false)
        #expect(keys.posted == 0)
    }

    @Test func secureInputOrAChangedAppAfterTheWaitStopsIt() async {
        let secure = FakeKeys()
        secure.secure = true
        #expect(await secure.sender().send(after: .inserted(.ax), mode: .always, rules: rules, skipped: false) == false)
        #expect(secure.posted == 0)

        let moved = FakeKeys()
        let sender = AutoEnterSender(env: AutoEnterEnvironment(
            secureInputEnabled: { false }, frontmostBundleID: { moved.bundle },
            postReturn: { moved.posted += 1; return true }, sleep: { _ in moved.bundle = "com.apple.mail" }))
        #expect(await sender.send(after: .inserted(.ax), mode: .chatApps, rules: rules, skipped: false) == false)
        #expect(moved.posted == 0)
    }

    @Test func aFailedPostReportsFalse() async {
        let keys = FakeKeys()
        keys.postResult = false
        #expect(await keys.sender().send(after: .inserted(.ax), mode: .always, rules: rules, skipped: false) == false)
    }
}
