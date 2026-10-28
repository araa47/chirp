import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// A fake clock: sleeps park on continuations the test resumes. The sleep runs off the main actor, so the list is locked.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var parked: [(Duration, CheckedContinuation<Void, Never>)] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    var sleepers: [(Duration, CheckedContinuation<Void, Never>)] { lock.withLock { parked } }
    var requested: [Duration] { sleepers.map(\.0) }
    var sleep: @Sendable (Duration) async -> Void {
        { [self] d in await withCheckedContinuation { c in park { parked.append((d, c)) } } }
    }
    /// Suspends until `n` sleeps have parked. It never spins: under load a `Task.yield()` loop starves the pool (#315).
    func waitForSleepers(_ n: Int) async { await withCheckedContinuation { c in park { waiters.append((n, c)) } } }
    /// Runs `change` under the lock, then wakes every waiter whose count has parked.
    private func park(_ change: () -> Void) {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            change()
            let ready = waiters.filter { $0.0 <= parked.count }.map(\.1)
            waiters.removeAll { $0.0 <= parked.count }
            return ready
        }
        for c in ready { c.resume() }
    }
    func fireAll() { let s = lock.withLock { let s = parked; parked = []; return s }; for (_, c) in s { c.resume() } }
}

@MainActor
private final class Rig {
    let clock = FakeClock()
    var registered: [KeyCombo] = []
    var unregistered = 0
    var used = 0
    var changes = 0
    var registerResult = true
    var press: (() -> Void)?
    lazy var offer = RawOffer(
        sleep: clock.sleep,
        register: { [self] combo, take in registered.append(combo); press = take; return registerResult },
        unregister: { [self] in unregistered += 1; press = nil },
        use: { [self] in used += 1 },
        onChange: { [self] in changes += 1 })
}

@MainActor
@Suite struct RawOfferTests {
    @Test func opensForFiveSecondsWithCtrlOptZ() async {
        let r = Rig()
        r.offer.open(avoiding: .controlOptionSpace)
        #expect(r.offer.isOpen && r.offer.hotkeyActive)
        #expect(r.registered == [RawOffer.combo] && RawOffer.combo.title == "⌃⌥Z")
        await r.clock.waitForSleepers(1)
        #expect(r.clock.requested == [.seconds(5)])
        r.clock.fireAll()
        #expect(await pollUntil(within: 60) { !r.offer.isOpen })
        #expect(!r.offer.hotkeyActive && r.unregistered == 1 && r.used == 0)
    }

    @Test func theHotkeyTakesTheOfferOnceAndReleasesItself() async {
        let r = Rig()
        r.offer.open()
        let press = r.press
        press?()
        #expect(r.used == 1 && !r.offer.isOpen && r.unregistered == 1)
        press?()                               // a second press does nothing
        r.offer.take()
        #expect(r.used == 1)
    }

    @Test func theMenuItemTakesItToo() {
        let r = Rig()
        r.offer.open()
        r.offer.take()
        #expect(r.used == 1 && !r.offer.isOpen)
    }

    @Test func aConflictingHotkeyFallsBackToMenuOnly() {
        let r = Rig()
        r.registerResult = false                       // another app owns ⌃⌥Z
        r.offer.open(avoiding: .controlOptionSpace)
        #expect(r.offer.isOpen && !r.offer.hotkeyActive && r.unregistered == 0)
        r.offer.take()
        #expect(r.used == 1)
    }

    @Test func itIsNotRegisteredWhenItIsTheDictationHotkey() {
        let r = Rig()
        r.offer.open(avoiding: RawOffer.combo)
        #expect(r.offer.isOpen && !r.offer.hotkeyActive && r.registered.isEmpty)
    }

    @Test func aNewDictationClosesItAndAStaleTimerCannotCloseTheNextWindow() async {
        let r = Rig()
        r.offer.open()
        await r.clock.waitForSleepers(1)
        r.offer.close()
        #expect(!r.offer.isOpen && r.unregistered == 1)
        r.offer.open()
        await r.clock.waitForSleepers(2)
        r.clock.sleepers[0].1.resume()                 // the first window's timer fires late
        for _ in 0..<20 { await Task.yield() }
        #expect(r.offer.isOpen && r.offer.hotkeyActive)
        r.clock.sleepers[1].1.resume()
        #expect(await pollUntil(within: 60) { !r.offer.isOpen })
    }

    @Test func reopeningReplacesTheRegistration() async {
        let r = Rig()
        r.offer.open()
        r.offer.open()
        #expect(r.registered.count == 2 && r.unregistered == 1 && r.offer.hotkeyActive)
    }

    @Test func listensForChanges() {
        let r = Rig()
        r.offer.open()
        r.offer.close()
        r.offer.close()                                // already closed: no change
        #expect(r.changes == 2)
    }
}

@Suite struct RawOfferUITests {
    @Test func theMenuOffersUseRawOnlyDuringTheWindow() {
        var m = MenuInputs()
        m.cleanupOn = true
        #expect(!MenuContent.entries(m).contains { $0.action == .useRaw })
        m.rawOfferOpen = true
        m.rawOfferKey = "⌃⌥Z"
        let entry = MenuContent.entries(m).first { $0.action == .useRaw }
        #expect(entry?.title == "Use Raw for Last Dictation" && entry?.shortcut == "⌃⌥Z")
        m.rawOfferKey = nil
        #expect(MenuContent.entries(m).first { $0.action == .useRaw }?.shortcut == nil)
    }

    @Test func theBirdShowsATinyCleanedMarkOnlyWhileIdleAndOffering() {
        let on = StatusIcon.of(state: .idle, serverReachable: true, debugRetention: false, rawOfferOpen: true)
        #expect(on.cleanedBadge && on.accessibilityLabel.contains("Use raw available"))
        #expect(!StatusIcon.of(state: .idle, serverReachable: true, debugRetention: false).cleanedBadge)
        #expect(!StatusIcon.of(state: .listening, serverReachable: true, debugRetention: false, rawOfferOpen: true).cleanedBadge)
    }

    @Test func showChangesDefaultsOffAndPersists() throws {
        let suite = "chirp-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let p = Preferences(defaults: defaults)
        #expect(!p.showChangesAfterCleanup)
        p.showChangesAfterCleanup = true
        #expect(Preferences(defaults: defaults).showChangesAfterCleanup)
    }
}

@MainActor
@Suite struct ShowChangesSettingTests {
    @Test func theSettingsCheckboxFollowsTheState() {
        var s = SettingsState()
        #expect(SettingsForm(s).showChanges.state == .off && SettingsForm(s).showChanges.title == "Show changes after clean-up")
        s.showChanges = true
        #expect(SettingsForm(s).showChanges.state == .on)
    }
}
