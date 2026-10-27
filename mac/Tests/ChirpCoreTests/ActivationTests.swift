import AppKit
import Carbon.HIToolbox
import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

/// `CGEventFlags` as the tap sees them: device-independent masks plus each side's device bit.
private enum Flags {
    static let leftOption: UInt64 = 0x80000 | 0x20
    static let rightOption: UInt64 = 0x80000 | 0x40
    static let leftCommand: UInt64 = 0x100000 | 0x8
    static let leftControl: UInt64 = 0x40000 | 0x1
    static let fn: UInt64 = 0x800000
}

// MARK: matching the tap's events

@Suite struct ShortcutMatcherTests {
    @Test func optionAloneIsPressedAndReleasedWithoutSwallowingAnything() {
        var m = ShortcutMatcher(combo: .option)
        let down = m.flagsChanged(keyCode: UInt16(kVK_Option), cgFlags: Flags.leftOption)
        #expect(down.action == .down && !down.swallow)
        let up = m.flagsChanged(keyCode: UInt16(kVK_Option), cgFlags: 0)
        #expect(up.action == .up && !up.swallow)
        // Either side works.
        #expect(m.flagsChanged(keyCode: UInt16(kVK_RightOption), cgFlags: Flags.rightOption).action == .down)
    }

    @Test func anotherKeyWhileHeldIsAChordAndNothingMoreFiresUntilReleased() {
        var m = ShortcutMatcher(combo: .option)
        _ = m.flagsChanged(keyCode: UInt16(kVK_Option), cgFlags: Flags.leftOption)
        let arrow = m.keyDown(keyCode: UInt16(kVK_LeftArrow), cgFlags: Flags.leftOption, isRepeat: false)
        #expect(arrow.action == .chord && !arrow.swallow)   // ⌥← still moves by word
        #expect(m.keyDown(keyCode: UInt16(kVK_LeftArrow), cgFlags: Flags.leftOption, isRepeat: true).action == nil)
        #expect(m.flagsChanged(keyCode: UInt16(kVK_Option), cgFlags: 0).action == nil)
        // The next clean press works again.
        #expect(m.flagsChanged(keyCode: UInt16(kVK_Option), cgFlags: Flags.leftOption).action == .down)
    }

    @Test func anotherModifierOrAClickIsAChord() {
        var m = ShortcutMatcher(combo: .option)
        _ = m.flagsChanged(keyCode: UInt16(kVK_Option), cgFlags: Flags.leftOption)
        #expect(m.flagsChanged(keyCode: UInt16(kVK_Command), cgFlags: Flags.leftOption | Flags.leftCommand).action == .chord)
        #expect(m.flagsChanged(keyCode: UInt16(kVK_Command), cgFlags: Flags.leftOption).action == nil)
        #expect(m.flagsChanged(keyCode: UInt16(kVK_Option), cgFlags: 0).action == nil)

        _ = m.flagsChanged(keyCode: UInt16(kVK_Option), cgFlags: Flags.leftOption)
        #expect(m.mouseDown().action == .chord)
    }

    /// ⌘ held, then ⌥, then ⌘ let go: ⌥ is now held alone, but it was never pressed alone.
    @Test func releasingAnotherModifierIsNotAPress() {
        var m = ShortcutMatcher(combo: .option)
        #expect(m.flagsChanged(keyCode: UInt16(kVK_Command), cgFlags: Flags.leftCommand).action == nil)
        #expect(m.flagsChanged(keyCode: UInt16(kVK_Option), cgFlags: Flags.leftCommand | Flags.leftOption).action == nil)
        #expect(m.flagsChanged(keyCode: UInt16(kVK_Command), cgFlags: Flags.leftOption).action == nil)
        #expect(m.flagsChanged(keyCode: UInt16(kVK_Option), cgFlags: 0).action == nil)
    }

    @Test func rightOptionIgnoresTheLeftOne() {
        var m = ShortcutMatcher(combo: .rightOption)
        #expect(m.flagsChanged(keyCode: UInt16(kVK_Option), cgFlags: Flags.leftOption).action == nil)
        #expect(m.flagsChanged(keyCode: UInt16(kVK_Option), cgFlags: 0).action == nil)
        #expect(m.flagsChanged(keyCode: UInt16(kVK_RightOption), cgFlags: Flags.rightOption).action == .down)
        #expect(m.flagsChanged(keyCode: UInt16(kVK_RightOption), cgFlags: 0).action == .up)
    }

    /// The default dictation key: pressed alone it fires, with any other key or modifier it is a chord, and the left ⌥
    /// (é, ü, ⌥-shortcuts in other apps) is never seen as it, nor swallowed.
    @Test func rightOptionAloneFiresAndEverythingElseIsAChordOrIgnored() {
        var m = ShortcutMatcher(combo: .defaultDictation)
        #expect(m.flagsChanged(keyCode: UInt16(kVK_RightOption), cgFlags: Flags.rightOption).action == .down)
        let key = m.keyDown(keyCode: UInt16(kVK_ANSI_E), cgFlags: Flags.rightOption, isRepeat: false)
        #expect(key.action == .chord && !key.swallow)   // Right ⌥ + E types é for the app, dictation drops
        #expect(m.flagsChanged(keyCode: UInt16(kVK_RightOption), cgFlags: 0).action == nil)

        // The left ⌥ on its own, with a key, then released: no event for dictation, and the key reaches the app.
        #expect(m.flagsChanged(keyCode: UInt16(kVK_Option), cgFlags: Flags.leftOption).action == nil)
        let typed = m.keyDown(keyCode: UInt16(kVK_ANSI_E), cgFlags: Flags.leftOption, isRepeat: false)
        #expect(typed.action == nil && !typed.swallow)
        #expect(m.flagsChanged(keyCode: UInt16(kVK_Option), cgFlags: 0).action == nil)

        // Both ⌥ held: the right one was not pressed alone.
        #expect(m.flagsChanged(keyCode: UInt16(kVK_Option), cgFlags: Flags.leftOption).action == nil)
        #expect(m.flagsChanged(keyCode: UInt16(kVK_RightOption), cgFlags: Flags.leftOption | Flags.rightOption).action == nil)
        #expect(m.flagsChanged(keyCode: UInt16(kVK_Option), cgFlags: Flags.rightOption).action == nil)
        #expect(m.flagsChanged(keyCode: UInt16(kVK_RightOption), cgFlags: 0).action == nil)

        // ⌘ then Right ⌥ is a chord; a click with it held is one too.
        #expect(m.flagsChanged(keyCode: UInt16(kVK_Command), cgFlags: Flags.leftCommand).action == nil)
        #expect(m.flagsChanged(keyCode: UInt16(kVK_RightOption), cgFlags: Flags.leftCommand | Flags.rightOption).action == nil)
        #expect(m.flagsChanged(keyCode: UInt16(kVK_RightOption), cgFlags: Flags.leftCommand).action == nil)
        _ = m.flagsChanged(keyCode: UInt16(kVK_Command), cgFlags: 0)
        #expect(m.flagsChanged(keyCode: UInt16(kVK_RightOption), cgFlags: Flags.rightOption).action == .down)
        #expect(m.mouseDown().action == .chord)
        _ = m.flagsChanged(keyCode: UInt16(kVK_RightOption), cgFlags: 0)

        // The left ⌥ joining a held Right ⌥ is a chord, not a release.
        #expect(m.flagsChanged(keyCode: UInt16(kVK_RightOption), cgFlags: Flags.rightOption).action == .down)
        #expect(m.flagsChanged(keyCode: UInt16(kVK_Option), cgFlags: Flags.leftOption | Flags.rightOption).action == .chord)
    }

    /// The center routes the tap's events to the handlers: a hold and release, then a chord.
    @MainActor @Test func theCenterDeliversRightOptionHoldAndChord() {
        var log: [String] = []
        let center = HotKeyCenter.shared
        center.addTapForTesting(id: 9100, combo: .defaultDictation, onDown: { log.append("down") }, onUp: { log.append("up") },
                                onChord: { log.append("chord") })
        defer { center.unregister(id: 9100) }
        for handler in center.route(.flagsChanged(keyCode: UInt16(kVK_RightOption), cgFlags: Flags.rightOption)).handlers { handler() }
        for handler in center.route(.flagsChanged(keyCode: UInt16(kVK_RightOption), cgFlags: 0)).handlers { handler() }
        #expect(log == ["down", "up"])
        for handler in center.route(.flagsChanged(keyCode: UInt16(kVK_RightOption), cgFlags: Flags.rightOption)).handlers { handler() }
        let chord = center.route(.keyDown(keyCode: UInt16(kVK_LeftArrow), cgFlags: Flags.rightOption, isRepeat: false))
        for handler in chord.handlers { handler() }
        #expect(!chord.swallow && log == ["down", "up", "down", "chord"])
    }

    @Test func fnAloneAndModifierPairs() throws {
        var fn = ShortcutMatcher(combo: try HotKeyValidation.validate(keyCode: UInt32(kVK_Function), modifiers: 0).get())
        #expect(fn.flagsChanged(keyCode: UInt16(kVK_Function), cgFlags: Flags.fn).action == .down)
        #expect(fn.flagsChanged(keyCode: UInt16(kVK_Function), cgFlags: 0).action == .up)

        let pair = try HotKeyValidation.validate(keyCode: KeyCombo.anyModifierKey, modifiers: UInt32(controlKey | optionKey)).get()
        var m = ShortcutMatcher(combo: pair)
        #expect(m.flagsChanged(keyCode: UInt16(kVK_Control), cgFlags: Flags.leftControl).action == nil)
        #expect(m.flagsChanged(keyCode: UInt16(kVK_Option), cgFlags: Flags.leftControl | Flags.leftOption).action == .down)
        #expect(m.flagsChanged(keyCode: UInt16(kVK_Option), cgFlags: Flags.leftControl).action == .up)
    }

    /// ⌥Space, which Carbon never delivers on macOS 15: matched and swallowed so the app types no non-breaking space.
    @Test func optionSpaceIsSwallowedIncludingRepeatsAndRelease() {
        var m = ShortcutMatcher(combo: .custom(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)))
        let down = m.keyDown(keyCode: UInt16(kVK_Space), cgFlags: Flags.leftOption, isRepeat: false)
        #expect(down.action == .down && down.swallow)
        let repeated = m.keyDown(keyCode: UInt16(kVK_Space), cgFlags: Flags.leftOption, isRepeat: true)
        #expect(repeated.action == nil && repeated.swallow)
        let up = m.keyUp(keyCode: UInt16(kVK_Space))
        #expect(up.action == .up && up.swallow)
        // Plain Space and ⌥⌘Space are left alone.
        #expect(m.keyDown(keyCode: UInt16(kVK_Space), cgFlags: 0, isRepeat: false) == .init(action: nil))
        #expect(m.keyDown(keyCode: UInt16(kVK_Space), cgFlags: Flags.leftOption | Flags.leftCommand, isRepeat: false) == .init(action: nil))
        #expect(m.keyUp(keyCode: UInt16(kVK_Space)) == .init(action: nil))
        // fn on a laptop's key events does not change the match.
        #expect(m.keyDown(keyCode: UInt16(kVK_Space), cgFlags: Flags.leftOption | Flags.fn, isRepeat: false).action == .down)
    }
}

@MainActor
@Suite struct HotKeyCenterTapTests {
    @Test func routeRunsTheMatchingHandlers() {
        var log: [String] = []
        let center = HotKeyCenter.shared
        center.addTapForTesting(id: 9101, combo: .option, onDown: { log.append("down") }, onUp: { log.append("up") },
                                onChord: { log.append("chord") })
        defer { center.unregister(id: 9101) }
        func run(_ e: HotKeyCenter.TapEvent) -> Bool {
            let (swallow, handlers) = center.route(e)
            handlers.forEach { $0() }
            return swallow
        }
        #expect(!run(.flagsChanged(keyCode: UInt16(kVK_Option), cgFlags: Flags.leftOption)))
        #expect(!run(.flagsChanged(keyCode: UInt16(kVK_Option), cgFlags: 0)))
        _ = run(.flagsChanged(keyCode: UInt16(kVK_Option), cgFlags: Flags.leftOption))
        _ = run(.keyDown(keyCode: UInt16(kVK_ANSI_E), cgFlags: Flags.leftOption, isRepeat: false))
        _ = run(.flagsChanged(keyCode: UInt16(kVK_Option), cgFlags: 0))
        #expect(log == ["down", "up", "down", "chord"])
        center.unregister(id: 9101)
        _ = run(.flagsChanged(keyCode: UInt16(kVK_Option), cgFlags: Flags.leftOption))
        #expect(log.count == 4)
    }
}

// MARK: presses → machine events

@Suite struct HotkeyGestureTests {
    @Test func keyShortcutsPassStraightThrough() {
        var g = HotkeyGesture(mode: .holdToTalk, modifierOnly: false)
        #expect(!g.needsArmTimer)
        #expect(g.down(at: 1) == [.hotkeyDown(at: 1)])
        #expect(g.up(at: 2) == [.hotkeyUp(at: 2)])
        #expect(g.chord() == [.hotkeyChord])
    }

    @Test func holdingAModifierStartsOnlyAfterTheArmDelay() {
        var g = HotkeyGesture(mode: .holdToTalk, modifierOnly: true)
        #expect(g.needsArmTimer)
        #expect(g.down(at: 1) == [])
        #expect(g.armDue(pressedAt: 1, at: 1.2) == [.hotkeyDown(at: 1.2)])
        #expect(g.armDue(pressedAt: 1, at: 1.3) == [])          // once
        #expect(g.up(at: 3) == [.hotkeyUp(at: 3)])
    }

    @Test func aQuickModifierTapOrChordInHoldModeNeverStarts() {
        var g = HotkeyGesture(mode: .holdToTalk, modifierOnly: true)
        _ = g.down(at: 1)
        #expect(g.up(at: 1.1) == [])
        #expect(g.armDue(pressedAt: 1, at: 1.2) == [])          // the timer of a press already let go
        _ = g.down(at: 2)
        #expect(g.chord() == [])
        #expect(g.armDue(pressedAt: 2, at: 2.2) == [])
        // A chord after arming drops the dictation.
        _ = g.down(at: 3)
        _ = g.armDue(pressedAt: 3, at: 3.2)
        #expect(g.chord() == [.hotkeyChord])
    }

    @Test func autoStopToggleOnACleanModifierTap() {
        var g = HotkeyGesture(mode: .autoStop, modifierOnly: true)
        #expect(!g.needsArmTimer)
        #expect(g.down(at: 1) == [])
        #expect(g.up(at: 1.2) == [.hotkeyDown(at: 1.2), .hotkeyUp(at: 1.2)])
        // Held too long, or used with another key: not a tap.
        _ = g.down(at: 2)
        #expect(g.up(at: 2 + HotkeyGesture.tapLimit + 0.1) == [])
        _ = g.down(at: 4)
        #expect(g.chord() == [])
        #expect(g.up(at: 4.1) == [])
    }

    /// Through the machine: tap ⌥ to start, tap again to stop.
    @Test func optionTapsDriveAnAutoStopDictation() {
        var g = HotkeyGesture(mode: .autoStop, modifierOnly: true)
        var m = DictationMachine(mode: .autoStop)
        _ = g.down(at: 0)
        for e in g.up(at: 0.1) { m.handle(e) }
        #expect(m.state == .connecting)
        m.handle(.serverReady)
        _ = g.down(at: 3)
        var effects: [DictationEffect] = []
        for e in g.up(at: 3.1) { effects += m.handle(e) }
        #expect(effects == [.finalize] && m.state == .finalizing)
    }
}

/// Right ⌥ (one physical modifier key) in auto-stop: hold to talk, or tap to toggle hands-free.
@Suite struct HoldOrTapGestureTests {
    private func gesture() -> HotkeyGesture { HotkeyGesture(mode: .autoStop, modifierOnly: true, singleKey: true) }

    @Test func onlyASingleKeyInAutoStopHoldsToTalk() {
        #expect(gesture().holdOrTap && gesture().needsArmTimer)
        #expect(!HotkeyGesture(mode: .autoStop, modifierOnly: true).holdOrTap)                       // ⌥ either side: tap only
        #expect(!HotkeyGesture(mode: .autoStop, modifierOnly: false, singleKey: true).holdOrTap)     // a key shortcut
        #expect(!HotkeyGesture(mode: .holdToTalk, modifierOnly: true, singleKey: true).holdOrTap)    // already hold-only
    }

    @Test func onlyASingleModifierKeyOpensTheMicrophoneOnThePress() {
        #expect(gesture().opensMicOnPress)
        #expect(HotkeyGesture(mode: .holdToTalk, modifierOnly: true, singleKey: true).opensMicOnPress)
        #expect(!HotkeyGesture(mode: .autoStop, modifierOnly: true).opensMicOnPress)       // ⌥ either side types é
        #expect(!HotkeyGesture(mode: .holdToTalk, modifierOnly: true).opensMicOnPress)
        #expect(!HotkeyGesture(mode: .autoStop, modifierOnly: false, singleKey: true).opensMicOnPress)   // ⌃⌥Space starts at once
        #expect(!HotkeyGesture(mode: .holdToTalk).opensMicOnPress)
    }

    @Test func aQuickTapStartsOnReleaseAndStaysOn() {
        var g = gesture()
        #expect(g.down(at: 1) == [])
        #expect(g.up(at: 1.1) == [.hotkeyDown(at: 1.1), .hotkeyUp(at: 1.1)])
        #expect(g.armDue(pressedAt: 1, at: 1.2) == [])   // the timer of a press already let go
    }

    @Test func aHoldStartsAfterTheArmDelayAndEndsOnRelease() {
        var g = gesture()
        _ = g.down(at: 1)
        #expect(g.armDue(pressedAt: 1, at: 1.2) == [.hotkeyDown(at: 1.2)])
        #expect(g.up(at: 4) == [.holdEnd])
    }

    @Test func aTapHeldPastTheArmDelayStillLeavesItRunning() {
        var g = gesture()
        _ = g.down(at: 1)
        _ = g.armDue(pressedAt: 1, at: 1.2)
        #expect(g.up(at: 1.4) == [.hotkeyUp(at: 1.4)])   // not `.holdEnd`: a slow tap is still a tap
    }

    @Test func aChordNeverStartsAndAChordWhileHeldDropsTheDictation() {
        var g = gesture()
        _ = g.down(at: 1)
        #expect(g.chord() == [])                          // Right ⌥ + a key before the arm delay: nothing started
        #expect(g.armDue(pressedAt: 1, at: 1.2) == [])
        #expect(g.up(at: 1.3) == [])
        _ = g.down(at: 2)
        _ = g.armDue(pressedAt: 2, at: 2.2)
        #expect(g.chord() == [.hotkeyChord])
        #expect(g.up(at: 2.6) == [])
    }

    private func run(_ events: [DictationEvent], _ m: inout DictationMachine) -> [DictationEffect] {
        var effects: [DictationEffect] = []
        for e in events { effects += m.handle(e) }
        return effects
    }

    /// Through the machine: a hold records for as long as it is down.
    @Test func holdingTalksAndLettingGoFinishes() {
        var g = gesture()
        var m = DictationMachine(mode: .autoStop)
        _ = g.down(at: 0)
        #expect(run(g.armDue(pressedAt: 0, at: 0.2), &m) == [.start])
        m.handle(.serverReady)
        #expect(m.state == .listening)
        #expect(run(g.up(at: 5), &m) == [.finalize] && m.state == .finalizing)
    }

    /// Tap to start, talk hands-free, tap again to stop.
    @Test func tappingTogglesHandsFree() {
        var g = gesture()
        var m = DictationMachine(mode: .autoStop)
        _ = g.down(at: 0)
        #expect(run(g.up(at: 0.1), &m) == [.start])
        m.handle(.serverReady)
        _ = g.down(at: 6)
        #expect(run(g.up(at: 6.1), &m) == [.finalize] && m.state == .finalizing)
    }

    /// A tap that outlasts the arm delay starts on the timer, stays running after the release, and the next tap stops it.
    @Test func aSlowTapStartsHandsFreeAndTheNextPressStops() {
        var g = gesture()
        var m = DictationMachine(mode: .autoStop)
        _ = g.down(at: 0)
        #expect(run(g.armDue(pressedAt: 0, at: 0.2), &m) == [.start])
        #expect(run(g.up(at: 0.4), &m) == [] && m.state == .connecting)
        m.handle(.serverReady)
        _ = g.down(at: 3)
        #expect(run(g.up(at: 3.1), &m) == [.finalize])
    }

    /// Holding the key to stop a hands-free dictation must not start another one on release.
    @Test func holdingToStopDoesNotRestart() {
        var g = gesture()
        var m = DictationMachine(mode: .autoStop)
        m.handle(.toggle)
        m.handle(.serverReady)
        _ = g.down(at: 10)
        #expect(run(g.armDue(pressedAt: 10, at: 10.2), &m) == [.finalize])
        for e in [DictationEvent.finalReceived, .insertionFinished] { m.handle(e) }
        #expect(m.state == .idle)
        #expect(run(g.up(at: 12), &m) == [] && m.state == .idle)
    }

    @Test func aChordAfterHoldingDropsTheDictation() {
        var g = gesture()
        var m = DictationMachine(mode: .autoStop)
        _ = g.down(at: 0)
        _ = run(g.armDue(pressedAt: 0, at: 0.2), &m)
        m.handle(.serverReady)
        #expect(run(g.chord(), &m) == [.cancel] && m.state == .idle)
    }

    /// The release of a hold means nothing once the dictation ended another way (a failure, Esc).
    @Test func aReleaseAfterEscapeIsIgnored() {
        var g = gesture()
        var m = DictationMachine(mode: .autoStop)
        _ = g.down(at: 0)
        _ = run(g.armDue(pressedAt: 0, at: 0.2), &m)
        m.handle(.escape)
        #expect(run(g.up(at: 2), &m) == [] && m.state == .idle)
    }
}

// MARK: auto-stop

@Suite struct AutoStopDetectorTests {
    private func feed(_ d: inout AutoStopDetector, rms: Float, from start: TimeInterval, to end: TimeInterval) -> TimeInterval? {
        var t = start
        while t < end {
            if d.feed(Level(peak: rms, rms: rms), at: t) { return t }
            t += 0.05
        }
        return nil
    }

    @Test func stopsAfterThePauseThatFollowsSpeech() {
        var d = AutoStopDetector(silence: 2)
        #expect(feed(&d, rms: 0.002, from: 0, to: 0.5) == nil)      // room noise
        #expect(feed(&d, rms: 0.08, from: 0.5, to: 3) == nil)       // talking
        let fired = feed(&d, rms: 0.002, from: 3, to: 8)
        #expect(fired != nil && abs(fired! - 5) < 0.11)
        let again = d.feed(Level(peak: 0, rms: 0), at: 9)
        #expect(!again)                                               // once
    }

    @Test func shortPausesBetweenWordsDoNotStop() {
        var d = AutoStopDetector(silence: 1.5)
        var t: TimeInterval = 0
        for _ in 0..<10 {
            #expect(feed(&d, rms: 0.06, from: t, to: t + 0.8) == nil)
            #expect(feed(&d, rms: 0.003, from: t + 0.8, to: t + 1.6) == nil)
            t += 1.6
        }
    }

    @Test func steadyNoiseIsNotSpeechAndNeverSpeakingTimesOut() {
        var d = AutoStopDetector(silence: 1)
        let fired = feed(&d, rms: 0.006, from: 0, to: 20)
        #expect(fired != nil && abs(fired! - AutoStopDetector.noSpeechTimeout) < 0.11)
    }

    @Test func preferencesKeepTheModeAndPause() throws {
        let suite = "chirp-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.activationMode == .autoStop && prefs.autoStopSilence == AutoStopDetector.defaultSilence)
        prefs.activationMode = .holdToTalk
        prefs.autoStopSilence = 3
        let again = Preferences(defaults: defaults)
        #expect(again.activationMode == .holdToTalk && again.autoStopSilence == 3)
        defaults.set("bogus", forKey: "activationMode")
        prefs.autoStopSilence = .infinity
        #expect(prefs.activationMode == .autoStop && prefs.autoStopSilence == AutoStopDetector.defaultSilence)
        prefs.hotkey = .option
        #expect(Preferences(defaults: defaults).hotkey == .option)
    }
}

// MARK: recorder and Settings

@MainActor
@Suite struct ModifierRecordingTests {
    @Test func aModifierLetGoAloneIsRecorded() {
        #expect(HotkeyRecording.modifierOnlyOutcome(modifiers: UInt32(optionKey), lastKey: UInt16(kVK_Option)) == .accepted(.option))
        #expect(HotkeyRecording.modifierOnlyOutcome(modifiers: UInt32(optionKey), lastKey: UInt16(kVK_RightOption)) == .accepted(.rightOption))
        #expect(HotkeyRecording.modifierOnlyOutcome(modifiers: UInt32(shiftKey), lastKey: UInt16(kVK_Shift)) == .rejected(.shiftAlone))
        let pair = HotkeyRecording.modifierOnlyOutcome(modifiers: UInt32(controlKey | optionKey), lastKey: UInt16(kVK_RightOption))
        #expect(pair == .accepted(.custom(keyCode: KeyCombo.anyModifierKey, modifiers: UInt32(controlKey | optionKey))))
        #expect(HotkeyRecording.modifierOnlyFlags([.function]) == ModifierKeys.fn)
    }

    @Test func settingsShowsTheModeAndItsPause() {
        var s = SettingsState()
        s.hotkey = .option
        s.activationMode = .holdToTalk
        s.autoStopSilence = 3
        let form = SettingsForm(s)
        #expect(form.mode.itemTitles == ["Auto-stop", "Hold to talk"])
        #expect(form.mode.titleOfSelectedItem == "Hold to talk" && !form.silence.isEnabled)
        #expect(form.silence.selectedItem?.representedObject as? Double == 3)
        #expect(form.hotkey.titleOfSelectedItem == "⌥ Option")
        #expect(form.hotkeyHelp.stringValue.contains("⌥←"))
        form.showMode(.autoStop, silence: 1.4)
        #expect(form.silence.isEnabled && form.silence.selectedItem?.representedObject as? Double == 1.5)
    }

    @Test func theMenuSaysWhenTheHotkeyWaitsForAccessibility() {
        var m = MenuInputs()
        m.health = Health(engine: "parakeet", ready: true)
        m.hotkey = .option
        m.activationMode = .holdToTalk
        #expect(MenuContent.statusLine(m).text == "Ready · hold ⌥ Option")
        m.hotkeyRegistered = false
        m.accessibilityGranted = false
        #expect(MenuContent.statusLine(m).text == "Ready · hotkey needs Accessibility")
        m.hotkey = .controlOptionSpace
        #expect(MenuContent.statusLine(m).text == "Ready · shortcut in use elsewhere")
    }
}
