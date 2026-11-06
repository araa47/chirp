import ChirpCore
import Foundation
import Testing
@testable import ChirpIOSCore

private let a = 0x04, e = 0x08, d = 0x07, left = 0x50, f5 = 0x3E
private typealias Mods = HardwareShortcut.Modifiers

struct HardwareShortcutMatcherTests {
    @Test func rightOptionAloneIsDownAndUpAndNeverSwallowed() {
        var m = HardwareShortcutMatcher(shortcut: .standard)
        #expect(m.began(key: HIDKey.rightOption, modifiers: .option) == .init(action: .down))
        #expect(m.ended(key: HIDKey.rightOption) == .init(action: .up))
    }

    @Test func anotherKeyDuringTheHoldIsAChordAndNothingMoreFires() {
        var m = HardwareShortcutMatcher(shortcut: .standard)
        _ = m.began(key: HIDKey.rightOption, modifiers: .option)
        // ⌥← or ⌥E: the user is typing, not dictating. The key itself still reaches the field.
        #expect(m.began(key: left, modifiers: .option) == .init(action: .chord))
        #expect(m.ended(key: left) == .none)
        #expect(m.began(key: e, modifiers: .option) == .none)
        #expect(m.ended(key: e) == .none)
        #expect(m.ended(key: HIDKey.rightOption) == .none)
        // Let go: the next clean press counts again.
        #expect(m.began(key: HIDKey.rightOption, modifiers: .option) == .init(action: .down))
    }

    @Test func rightOptionWithLeftOptionOrAnotherModifierHeldIsNotAlone() {
        var m = HardwareShortcutMatcher(shortcut: .standard)
        _ = m.began(key: HIDKey.leftOption, modifiers: .option)
        #expect(m.began(key: HIDKey.rightOption, modifiers: .option) == .none)
        _ = m.ended(key: HIDKey.leftOption)
        #expect(m.ended(key: HIDKey.rightOption) == .none)

        _ = m.began(key: HIDKey.leftCommand, modifiers: .command)
        #expect(m.began(key: HIDKey.rightOption, modifiers: [.command, .option]) == .none)
        _ = m.ended(key: HIDKey.leftCommand)
        _ = m.ended(key: HIDKey.rightOption)
        #expect(m.began(key: HIDKey.rightOption, modifiers: .option) == .init(action: .down))
    }

    @Test func aLetterHeldWhileRightOptionGoesDownIsNotAlone() {
        var m = HardwareShortcutMatcher(shortcut: .standard)
        _ = m.began(key: a, modifiers: [])
        #expect(m.began(key: HIDKey.rightOption, modifiers: .option) == .none)
    }

    @Test func leftOptionNeverTriggersRightOption() {
        var m = HardwareShortcutMatcher(shortcut: .standard)
        #expect(m.began(key: HIDKey.leftOption, modifiers: .option) == .none)
        #expect(m.ended(key: HIDKey.leftOption) == .none)
    }

    @Test func keyShortcutNeedsExactlyItsModifiersAndIsSwallowed() {
        let shortcut = HardwareShortcut(key: HIDKey.space, modifiers: .option)
        var m = HardwareShortcutMatcher(shortcut: shortcut)
        #expect(m.began(key: HIDKey.leftOption, modifiers: .option) == .none)
        #expect(m.began(key: HIDKey.space, modifiers: [.option, .shift]) == .none)
        #expect(m.ended(key: HIDKey.space) == .none)
        #expect(m.began(key: HIDKey.space, modifiers: [.option, .init(rawValue: 1 << 16)]) == .init(action: .down, swallow: true),
                "Caps lock is ignored")
        #expect(m.began(key: HIDKey.space, modifiers: .option) == .init(action: nil, swallow: true), "A repeat is swallowed")
        // Letting go of ⌥ first still ends the press on the key's release.
        #expect(m.ended(key: HIDKey.leftOption) == .none)
        #expect(m.ended(key: HIDKey.space) == .init(action: .up, swallow: true))
        #expect(m.began(key: HIDKey.space, modifiers: []) == .none, "Plain Space types")
    }

    @Test func aLostReleaseOfAnotherModifierHealsOnTheNextPress() {
        var m = HardwareShortcutMatcher(shortcut: .standard)
        _ = m.began(key: HIDKey.leftShift, modifiers: .shift)
        // ⇧'s release never arrived; the next press reports no ⇧ held, so Right ⌥ is alone again.
        #expect(m.began(key: HIDKey.rightOption, modifiers: .option) == .init(action: .down))
        var r = HardwareShortcutRecorder()
        _ = r.began(key: HIDKey.leftShift, modifiers: .shift)
        _ = r.began(key: HIDKey.leftOption, modifiers: .option)
        #expect(r.ended(key: HIDKey.leftOption) == .recorded(HardwareShortcut(key: HIDKey.leftOption)))
    }

    @Test func resetEndsAPressUnderWay() {
        var m = HardwareShortcutMatcher(shortcut: .standard)
        _ = m.began(key: HIDKey.rightOption, modifiers: .option)
        #expect(m.reset() == .init(action: .up))
        #expect(m.reset() == .none)
        #expect(m.began(key: HIDKey.rightOption, modifiers: .option) == .init(action: .down), "Nothing stays held")
    }
}

struct HardwareShortcutGestureTests {
    @Test func holdWithAModifierStartsOnlyAfterTheArmDelay() {
        var g = HardwareShortcutGesture(shortcut: .standard)
        #expect(g.needsArmTimer)
        #expect(g.handle(.down, at: 10) == [])
        #expect(g.armDue(pressedAt: 10, at: 10 + HotkeyGesture.armDelay) == [.start])
        #expect(g.handle(.up, at: 12) == [.stop])
    }

    @Test func holdQuickTapOrChordBeforeTheDelayNeverStarts() {
        var g = HardwareShortcutGesture(shortcut: .standard)
        _ = g.handle(.down, at: 10)
        #expect(g.handle(.up, at: 10.1) == [])
        #expect(g.armDue(pressedAt: 10, at: 10.2) == [], "The timer of a press already let go does nothing")
        _ = g.handle(.down, at: 20)
        #expect(g.handle(.chord, at: 20.1) == [])
        #expect(g.armDue(pressedAt: 20, at: 20.2) == [])
    }

    @Test func holdChordAfterStartingCancels() {
        var g = HardwareShortcutGesture(shortcut: .standard)
        _ = g.handle(.down, at: 10)
        _ = g.armDue(pressedAt: 10, at: 10.2)
        #expect(g.handle(.chord, at: 11) == [.cancel])
        #expect(g.handle(.up, at: 11.5) == [])
    }

    @Test func holdWithAKeyShortcutStartsAtOnce() {
        var g = HardwareShortcutGesture(shortcut: HardwareShortcut(key: HIDKey.space, modifiers: .option))
        #expect(!g.needsArmTimer)
        #expect(g.handle(.down, at: 1) == [.start])
        #expect(g.handle(.up, at: 3) == [.stop])
    }

    @Test func toggleWithAModifierIsACleanTap() {
        var g = HardwareShortcutGesture(shortcut: HardwareShortcut.standard.with(mode: .toggle))
        #expect(!g.needsArmTimer)
        #expect(g.handle(.down, at: 1) == [])
        #expect(g.handle(.up, at: 1.2) == [.toggle])
        _ = g.handle(.down, at: 5)
        #expect(g.handle(.up, at: 5 + HotkeyGesture.tapLimit + 0.1) == [], "A long hold is ⌥ held for something else")
        _ = g.handle(.down, at: 9)
        #expect(g.handle(.chord, at: 9.1) == [])
        #expect(g.handle(.up, at: 9.2) == [])
    }

    @Test func toggleWithAKeyShortcutTogglesOnPress() {
        var g = HardwareShortcutGesture(shortcut: HardwareShortcut(key: d, modifiers: [.control, .option], mode: .toggle))
        #expect(g.handle(.down, at: 1) == [.toggle])
        #expect(g.handle(.up, at: 1.1) == [])
    }
}

struct HardwareShortcutValidationTests {
    private func reason(_ key: Int, _ mods: Mods) -> HardwareShortcutValidation.Rejection? {
        if case .failure(let r) = HardwareShortcutValidation.validate(key: key, modifiers: mods) { return r }
        return nil
    }

    @Test func modifierKeysAloneAreAllowedExceptShift() throws {
        for key in [HIDKey.rightOption, HIDKey.leftOption, HIDKey.rightCommand, HIDKey.rightControl] {
            #expect(reason(key, []) == nil)
        }
        #expect(reason(HIDKey.rightShift, []) == .shiftAlone)
        #expect(reason(HIDKey.leftShift, .shift) == .shiftAlone)
        // Recording a modifier key keeps only that key, whatever flags came with it.
        #expect(try HardwareShortcutValidation.validate(key: HIDKey.rightOption, modifiers: [.option, .command]).get()
                == HardwareShortcut(key: HIDKey.rightOption))
    }

    @Test func typingKeysNeedARealModifier() {
        #expect(reason(a, []) == .noModifier)
        #expect(reason(HIDKey.space, []) == .noModifier)
        #expect(reason(a, .shift) == .shiftOnly)
        #expect(reason(HIDKey.escape, .command) == .escape)
        #expect(reason(f5, []) == nil, "Function keys do not type")
        #expect(reason(HIDKey.space, .option) == nil)
        #expect(reason(d, [.control, .option]) == nil)
    }

    @Test func systemAndChirpShortcutsAreRefusedByName() {
        #expect(reason(HIDKey.space, .command) == .reserved("Spotlight"))
        #expect(reason(HIDKey.space, .control) == .reserved("switching keyboard languages"))
        #expect(reason(0x28, .command) == .inUse("Start Dictation"))
        #expect(reason(0x37, .command) == .inUse("Cancel Dictation"))
        #expect(reason(0x1F, .command) == .inUse("Dictate"))
        #expect(reason(e, [.command, .shift]) == .inUse("Edit by voice"))
        #expect(reason(0x1D, [.control, .option]) == .inUse("Use Raw Transcript"))
        #expect(reason(0x0E, [.command, .shift]) == .inUse("the keyboard session"))
        #expect(reason(0x11, [.control, .option]) == .inUse("New note and record"))
        let bindings = HardwareShortcutValidation.chirpShortcuts.map { "\($0.key)-\($0.modifiers.rawValue)" }
        #expect(Set(bindings).count == bindings.count, "two Chirp shortcuts share keys")
        for rejection in [HardwareShortcutValidation.Rejection.noModifier, .shiftOnly, .shiftAlone, .escape, .reserved("x"), .inUse("y")] {
            #expect(!rejection.reason.isEmpty)
        }
    }

    @Test func titlesAndResolve() {
        #expect(HardwareShortcut.standard.title == "Right ⌥ Option")
        #expect(HardwareShortcut(key: HIDKey.space, modifiers: .option).title == "⌥Space")
        #expect(HardwareShortcut(key: d, modifiers: [.command, .control, .option]).title == "⌃⌥⌘D")
        #expect(HardwareShortcut.standard.instruction == "Hold Right ⌥ Option to dictate. Let go to insert.")
        #expect(HardwareShortcut.resolve(nil) == .standard)
        // A stored shortcut that can never fire (edited by hand) falls back to Right ⌥ but keeps the mode and switch.
        let bad = HardwareShortcut(key: a, modifiers: [], mode: .toggle, enabled: false)
        #expect(HardwareShortcut.resolve(bad) == HardwareShortcut(key: HIDKey.rightOption, mode: .toggle, enabled: false))
        let good = HardwareShortcut(key: HIDKey.space, modifiers: .option, mode: .toggle)
        #expect(HardwareShortcut.resolve(good) == good)
        #expect(HIDKey.character(HIDKey.space) == " ")
        #expect(HIDKey.character(d) == "d")
        #expect(HIDKey.character(HIDKey.rightOption) == nil)
    }

    @Test func preferencesKeepTheShortcutAndOldFilesStillDecode() throws {
        var prefs = IOSPreferences()
        prefs.hardwareShortcut = HardwareShortcut(key: HIDKey.space, modifiers: .option, mode: .toggle)
        let data = try JSONEncoder().encode(prefs)
        #expect(try JSONDecoder().decode(IOSPreferences.self, from: data) == prefs)
        let old = try JSONDecoder().decode(IOSPreferences.self, from: Data(#"{"correction":false,"styleID":"default","prompts":{},"sessionDuration":"fiveMinutes","privacyMode":false}"#.utf8))
        #expect(old.hardwareShortcut == nil)
        #expect(HardwareShortcut.resolve(old.hardwareShortcut) == .standard)
    }
}

struct HardwareShortcutRecorderTests {
    @Test func aModifierAloneRecordsOnRelease() {
        var r = HardwareShortcutRecorder()
        #expect(r.began(key: HIDKey.rightCommand, modifiers: .command) == nil)
        #expect(r.ended(key: HIDKey.rightCommand) == .recorded(HardwareShortcut(key: HIDKey.rightCommand)))
    }

    @Test func aModifierThenAKeyRecordsTheCombination() {
        var r = HardwareShortcutRecorder()
        _ = r.began(key: HIDKey.rightOption, modifiers: .option)
        #expect(r.began(key: HIDKey.space, modifiers: .option) == .recorded(HardwareShortcut(key: HIDKey.space, modifiers: .option)))
        #expect(r.ended(key: HIDKey.rightOption) == nil, "Letting go of ⌥ afterwards records nothing more")
    }

    @Test func rejectionsAndEscape() {
        var r = HardwareShortcutRecorder()
        #expect(r.began(key: a, modifiers: []) == .rejected(.noModifier))
        _ = r.ended(key: a)
        _ = r.began(key: HIDKey.leftShift, modifiers: .shift)
        #expect(r.ended(key: HIDKey.leftShift) == .rejected(.shiftAlone))
        #expect(r.began(key: HIDKey.escape, modifiers: []) == .cancelled)
    }
}
