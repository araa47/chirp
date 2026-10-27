import AppKit
import SwiftUI
import Carbon.HIToolbox
import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

// MARK: hotkey validation

@Suite struct HotKeyValidationTests {
    private func reject(_ key: Int, _ mods: Int) -> HotKeyValidation.Rejection? {
        if case .failure(let why) = HotKeyValidation.validate(keyCode: UInt32(key), modifiers: UInt32(mods)) { return why }
        return nil
    }

    /// Carbon never delivers ⌥-only shortcuts since macOS 15, so they are accepted and matched from the event tap.
    @Test func optionOnlyCombinationsGoThroughTheEventTap() throws {
        for mods in [optionKey, optionKey | shiftKey] {
            let combo = try HotKeyValidation.validate(keyCode: UInt32(kVK_Space), modifiers: UInt32(mods)).get()
            #expect(combo.needsEventTap && !combo.isModifierOnly)
        }
        #expect(!KeyCombo.controlOptionSpace.needsEventTap)
        #expect(KeyCombo.option.needsEventTap && KeyCombo.rightOption.needsEventTap)
    }

    @Test func aModifierOnItsOwnIsAShortcut() throws {
        let option = try HotKeyValidation.validate(keyCode: KeyCombo.anyModifierKey, modifiers: UInt32(optionKey)).get()
        #expect(option == .option && option.isModifierOnly)   // recording ⌥ alone picks the preset
        let right = try HotKeyValidation.validate(keyCode: UInt32(kVK_RightOption), modifiers: 0).get()
        #expect(right == .rightOption && right.modifiers == UInt32(optionKey))
        let rightCommand = try HotKeyValidation.validate(keyCode: UInt32(kVK_RightCommand), modifiers: 0).get()
        #expect(rightCommand.isCustom && rightCommand.title == "Right ⌘ Command")
        let fn = try HotKeyValidation.validate(keyCode: UInt32(kVK_Function), modifiers: 0).get()
        #expect(fn.modifiers == ModifierKeys.fn && fn.title == "fn")
        let pair = try HotKeyValidation.validate(keyCode: KeyCombo.anyModifierKey, modifiers: UInt32(controlKey | optionKey)).get()
        #expect(pair.title == "⌃⌥")
        #expect(reject(Int(KeyCombo.anyModifierKey), shiftKey) == .shiftAlone)
        #expect(reject(kVK_RightShift, 0) == .shiftAlone)
        #expect(reject(Int(KeyCombo.anyModifierKey), 0) == .noModifier)
        #expect(KeyCombo.resolve(id: pair.id) == pair)
        #expect(KeyCombo.resolve(id: KeyCombo.rightOption.id) == .rightOption)
    }

    @Test func controlSpaceAloneBelongsToRaycast() {
        #expect(reject(kVK_Space, controlKey) == .controlSpace)
        #expect(HotKeyValidation.Rejection.controlSpace.reason.contains("Raycast"))
        // The same chord with another modifier or another key is fine.
        #expect(reject(kVK_Space, controlKey | optionKey) == nil)
        #expect(reject(kVK_ANSI_R, controlKey) == nil)
    }

    @Test func aKeyNeedsAModifierThatCanFire() {
        #expect(reject(kVK_ANSI_R, 0) == .noModifier)
        #expect(reject(kVK_Space, 0) == .noModifier)
        #expect(reject(kVK_ANSI_R, shiftKey) == .shiftOnly)
        // F-keys type nothing, so they work alone or with ⇧.
        #expect(reject(kVK_F5, 0) == nil)
        #expect(reject(kVK_F13, shiftKey) == nil)
    }

    @Test func escapeAndSystemShortcutsAreRefused() {
        #expect(reject(kVK_Escape, controlKey | optionKey) == .escape)
        #expect(reject(kVK_Escape, 0) == .escape)
        #expect(reject(kVK_Space, cmdKey) == .reserved("Spotlight"))
        #expect(reject(kVK_Tab, cmdKey) == .reserved("the app switcher"))
        #expect(reject(kVK_ANSI_Q, cmdKey) == .reserved("Quit"))
    }

    @Test func everyRejectionExplainsItselfInOneSentence() {
        let all: [HotKeyValidation.Rejection] = [.noModifier, .shiftOnly, .shiftAlone, .controlSpace, .reserved("Spotlight"), .escape]
        for why in all { #expect(why.reason.count > 20 && why.reason.hasSuffix(".")) }
        #expect(Set(all.map(\.reason)).count == all.count)
    }

    @Test func combinationsThatCanFireAreAccepted() throws {
        for (key, mods) in [(kVK_ANSI_R, controlKey | optionKey), (kVK_Space, optionKey | cmdKey), (kVK_F5, controlKey),
                            (kVK_ANSI_D, controlKey | optionKey | shiftKey | cmdKey), (kVK_Space, controlKey | cmdKey | shiftKey)] {
            let combo = try HotKeyValidation.validate(keyCode: UInt32(key), modifiers: UInt32(mods)).get()
            #expect(combo.keyCode == UInt32(key) && combo.modifiers == UInt32(mods) && combo.isCustom)
        }
    }

    @Test func bitsOtherThanTheFourModifiersAreIgnored() throws {
        let capsLock = UInt32(alphaLock)
        let combo = try HotKeyValidation.validate(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey) | capsLock).get()
        #expect(combo.modifiers == UInt32(controlKey))
        // ⌃ plus caps lock is still ⌃ alone.
        #expect(reject(kVK_Space, controlKey | Int(capsLock)) == .controlSpace)
    }

    @Test func titlesListModifiersInMacOrder() {
        #expect(KeyCombo.custom(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | controlKey | optionKey | shiftKey)).title == "⌃⌥⇧⌘R")
        #expect(KeyCombo.custom(keyCode: UInt32(kVK_Space), modifiers: UInt32(controlKey | cmdKey)).title == "⌃⌘Space")
        #expect(KeyCombo.custom(keyCode: UInt32(kVK_F5), modifiers: UInt32(controlKey)).title == "⌃F5")
        #expect(KeyNames.name(for: 0xFE) == "Key 254")
    }

    @Test func idsRoundTripAndAnInvalidStoredIdFallsBack() {
        let combo = KeyCombo.custom(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey))
        #expect(KeyCombo.resolve(id: combo.id) == combo)
        #expect(KeyCombo.resolve(id: "control-shift-space") == .controlShiftSpace)
        #expect(KeyCombo.resolve(id: nil) == .rightOption)
        // Hand-edited or stale defaults that can never fire, or that are malformed, use the default.
        #expect(KeyCombo.resolve(id: "custom:\(kVK_Space):\(shiftKey)") == .rightOption)
        #expect(KeyCombo.resolve(id: "custom:\(kVK_Space):\(controlKey)") == .rightOption)
        #expect(KeyCombo.resolve(id: "custom:abc") == .rightOption)
        #expect(KeyCombo.resolve(id: "custom:1:2:3") == .rightOption)
    }

    @Test func preferencesPersistACustomHotkeyAndSoundsDefaultOff() throws {
        let suite = "chirp-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.soundsEnabled == false && prefs.didOnboard == false)
        let combo = KeyCombo.custom(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | cmdKey))
        prefs.hotkey = combo
        prefs.soundsEnabled = true
        #expect(Preferences(defaults: defaults).hotkey == combo && Preferences(defaults: defaults).soundsEnabled)
        defaults.set("custom:\(kVK_Space):\(shiftKey)", forKey: "hotkey")
        #expect(prefs.hotkey == .rightOption)
    }
}

// MARK: recorder

@MainActor
@Suite struct HotkeyRecorderTests {
    @Test func mapsAppKitModifiersToCarbon() {
        #expect(HotkeyRecording.carbonModifiers([.control, .option]) == UInt32(controlKey | optionKey))
        #expect(HotkeyRecording.carbonModifiers([.command, .shift, .capsLock, .function]) == UInt32(cmdKey | shiftKey))
        #expect(HotkeyRecording.carbonModifiers([]) == 0)
    }

    @Test func keyPressesBecomeOutcomes() {
        #expect(HotkeyRecording.outcome(keyCode: UInt16(kVK_Escape), flags: []) == .cancelled)
        #expect(HotkeyRecording.outcome(keyCode: UInt16(kVK_Space), flags: [.option])
                == .accepted(.custom(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))))
        #expect(HotkeyRecording.outcome(keyCode: UInt16(kVK_ANSI_R), flags: [.shift]) == .rejected(.shiftOnly))
        #expect(HotkeyRecording.outcome(keyCode: UInt16(kVK_Space), flags: [.control]) == .rejected(.controlSpace))
        #expect(HotkeyRecording.outcome(keyCode: UInt16(kVK_Escape), flags: [.control, .option]) == .rejected(.escape))
        #expect(HotkeyRecording.outcome(keyCode: UInt16(kVK_ANSI_R), flags: [.control, .option])
                == .accepted(.custom(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey))))
    }

    @Test func aRefusedCombinationKeepsRecordingAndShowsWhy() {
        let recorder = HotkeyRecorder()
        var changes: [Bool] = []
        var captured: [KeyCombo] = []
        recorder.onRecordingChanged = { changes.append($0) }
        recorder.onCapture = { captured.append($0) }
        recorder.start()
        #expect(recorder.isRecording && changes == [true])
        recorder.apply(.rejected(.shiftAlone))
        #expect(recorder.isRecording && recorder.status == .rejected(.shiftAlone) && captured.isEmpty)
        recorder.apply(.accepted(.custom(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey))))
        #expect(!recorder.isRecording && changes == [true, false] && captured.count == 1 && recorder.title == "Record Shortcut…")
    }

    @Test func escapeLeavesTheShortcutAlone() {
        let recorder = HotkeyRecorder()
        var captured = 0
        recorder.onCapture = { _ in captured += 1 }
        recorder.start()
        recorder.apply(.cancelled)
        #expect(!recorder.isRecording && captured == 0)
        recorder.stop()   // idempotent
    }

    @Test func settingsShowsTheReasonUnderTheHotkey() {
        let form = SettingsForm(SettingsState())
        #expect(form.hotkeyHelp.stringValue.hasPrefix("Only on its own"))   // the default is Right ⌥
        form.fillHotkeyMenu(selecting: .controlOptionSpace)
        #expect(form.hotkeyHelp.stringValue.hasPrefix("Any key combination"))
        form.recorder.start()
        form.recorder.apply(.rejected(.shiftAlone))
        #expect(form.hotkeyHelp.stringValue == HotKeyValidation.Rejection.shiftAlone.reason)
        #expect(form.hotkeyHelp.textColor == .systemRed)
        form.recorder.stop()
        #expect(form.hotkeyHelp.textColor == .secondaryLabelColor)
    }

    @Test func settingsListsACustomHotkeyAndSelectsIt() {
        var s = SettingsState()
        let custom = KeyCombo.custom(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | cmdKey))
        s.hotkey = custom
        s.soundsEnabled = true
        let form = SettingsForm(s)
        #expect(form.hotkey.itemTitles == KeyCombo.presets.map(\.title) + ["⌃⌘R (custom)"])
        #expect(form.hotkey.selectedItem?.representedObject as? String == custom.id)
        #expect(form.sounds.state == .on)
        form.fillHotkeyMenu(selecting: .controlShiftSpace)
        #expect(form.hotkey.itemTitles == KeyCombo.presets.map(\.title) && form.hotkey.titleOfSelectedItem == "⌃⇧Space")
    }

    @Test func fnSetupAppearsForRecordedAndRestoredFnAndHidesForOtherShortcuts() {
        // The recorder stores an any-side modifier; older custom shortcuts can store the physical Fn key.
        let recorded = HotkeyRecording.modifierOnlyOutcome(modifiers: ModifierKeys.fn, lastKey: UInt16(kVK_Function))
        guard case .accepted(let fn) = recorded else { Issue.record("Fn was not accepted"); return }
        for combo in [fn, .custom(keyCode: UInt32(kVK_Function), modifiers: ModifierKeys.fn)] {
            var state = SettingsState()
            state.hotkey = KeyCombo.resolve(id: combo.id)
            let form = SettingsForm(state)
            #expect(!form.keyboardSettingsButton.isHiddenOrHasHiddenAncestor)
            #expect(form.fnKeyHelp.stringValue.contains("Do Nothing"))
            let fnHeight = form.fittingSize(for: .dictation).height

            form.recorder.start()
            form.recorder.apply(.rejected(.shiftAlone))
            #expect(form.hotkeyHelp.stringValue == HotKeyValidation.Rejection.shiftAlone.reason)
            form.recorder.stop()

            for other in [KeyCombo.rightOption, .controlOptionSpace, .option,
                          .custom(keyCode: KeyCombo.anyModifierKey, modifiers: ModifierKeys.fn | UInt32(cmdKey))] {
                form.fillHotkeyMenu(selecting: other)
                #expect(form.keyboardSettingsButton.isHiddenOrHasHiddenAncestor)
                #expect(form.fittingSize(for: .dictation).height < fnHeight)
            }
            form.fillHotkeyMenu(selecting: fn)
            #expect(!form.keyboardSettingsButton.isHiddenOrHasHiddenAncestor)
        }
    }
}

// MARK: sounds

@Suite struct SoundCueTests {
    @Test func startsWhenADictationBeginsAndStopsWhenCaptureEnds() {
        #expect(SoundCue.cue(from: .idle, to: .connecting, enabled: true) == .start)
        #expect(SoundCue.cue(from: .error("x"), to: .connecting, enabled: true) == .start)
        #expect(SoundCue.cue(from: .listening, to: .finalizing, enabled: true) == .stop)
        #expect(SoundCue.cue(from: .connecting, to: .finalizing, enabled: true) == .stop)
    }

    @Test func staysSilentOtherwise() {
        #expect(SoundCue.cue(from: .idle, to: .connecting, enabled: false) == nil)
        #expect(SoundCue.cue(from: .connecting, to: .listening, enabled: true) == nil)
        #expect(SoundCue.cue(from: .finalizing, to: .inserting, enabled: true) == nil)
        #expect(SoundCue.cue(from: .inserting, to: .idle, enabled: true) == nil)
        #expect(SoundCue.cue(from: .listening, to: .error("x"), enabled: true) == nil)
        #expect(SoundCue.cue(from: .listening, to: .idle, enabled: true) == nil)   // Esc cancels
        #expect(SoundCue.cue(from: .idle, to: .idle, enabled: true) == nil)
    }

    @Test func usesStockSystemSounds() {
        for cue in [SoundCue.start, .stop] {
            #expect(FileManager.default.fileExists(atPath: "/System/Library/Sounds/\(cue.systemSoundName).aiff"))
        }
        #expect(SoundCue.start.systemSoundName != SoundCue.stop.systemSoundName)
    }
}

// MARK: waveform and HUD model

@MainActor
@Suite struct WaveformTests {
    @Test func normalizeMapsDecibelsToBarHeight() {
        #expect(LevelHistory.normalize(rms: 0) == 0)
        #expect(LevelHistory.normalize(rms: 0.001) == 0)           // -60 dBFS: room noise
        #expect(LevelHistory.normalize(rms: 1) == 1)
        let quiet = LevelHistory.normalize(rms: 0.01), speech = LevelHistory.normalize(rms: 0.1)
        #expect(quiet > 0 && speech > quiet && speech < 1)
        #expect(abs(speech - (20 * log10(Float(0.1)) + 50) / 36) < 0.0001)
    }

    @Test func historyScrollsKeepsItsLengthAndFallsSmoothly() {
        var h = LevelHistory()
        #expect(h.samples.count == LevelHistory.capacity && h.samples.allSatisfy { $0 == 0 })
        h.push(rms: 0.2)
        let peak = LevelHistory.normalize(rms: 0.2)
        #expect(h.samples.last == peak)
        h.push(rms: 0)
        let fall = h.samples.last ?? 0
        #expect(fall > 0 && fall < peak)                           // decays, does not drop to zero at once
        for _ in 0..<100 { h.push(rms: 0.1) }
        #expect(h.samples.count == LevelHistory.capacity)
        #expect(h.samples.allSatisfy { abs($0 - LevelHistory.normalize(rms: 0.1)) < 0.0001 })
        h.clear()
        #expect(h.samples.allSatisfy { $0 == 0 })
    }

    @Test func modelPushesAndResets() {
        let m = HUDModel()
        m.pushLevel(0.3)
        m.status = HUDStatus.listening; m.indicator = .warning; m.cleaned = true
        #expect(m.levels.samples.last ?? 0 > 0)
        m.reset()
        #expect(m.levels.samples.allSatisfy { $0 == 0 } && m.indicator == .waveform && !m.cleaned && m.status.isEmpty)
    }

    @Test func statusWordingIsConcise() {
        #expect([HUDStatus.connecting, HUDStatus.listening, HUDStatus.finishing, HUDStatus.inserting]
                == ["Connecting…", "Listening…", "Finishing…", "Inserting…"])
        let plain = FinalResult(text: "hi")
        #expect(OutcomePresentation.of(.copied, final: plain).status == "Copied — ⌘V")
        #expect(OutcomePresentation.of(.copied, final: plain).indicator == .clipboard)
        #expect(OutcomePresentation.of(.inserted(.ax), final: plain).indicator == .success)
    }

    @Test func contrastAndMotionVariantsLayOutLikeTheDefault() {
        func size(_ configure: (HUDModel) -> Void) -> CGSize {
            let m = HUDModel()
            m.flatSurface = true
            m.status = HUDStatus.listening
            m.stable = "hello there"
            configure(m)
            return NSHostingViewSize.of(HUDView(model: m))
        }
        let base = size { _ in }
        // The HUD is a fixed full-length panel, whatever the indicator's width.
        #expect(base.height > 40 && base.width == HUDViewMetrics.width)
        #expect(size { $0.reduceMotion = true } == base)
        #expect(size { $0.increaseContrast = true } == base)
    }

    @Test func theHUDKeepsAFixedWidthAndWrapsInsteadOfGrowing() {
        func size(_ text: String, words: Bool = false) -> CGSize {
            let m = HUDModel()
            m.flatSurface = true
            m.wordWaveform = words
            m.status = HUDStatus.listening
            m.stable = text
            return NSHostingViewSize.of(HUDView(model: m))
        }
        let none = size(""), short = size("hello"), medium = size("please move the standup to three thirty")
        let long = size(String(repeating: "and then we should check the rollout plan ", count: 8))
        #expect(none.height <= 48)                                  // one line
        // Never jumps sideways: 472 pt for every text, with or without the word waveform.
        #expect([none, short, medium, long].allSatisfy { $0.width == HUDViewMetrics.width })
        #expect(size("hello", words: true).width == HUDViewMetrics.wordWaveformWidth)
        #expect(long.height > medium.height && medium.height > short.height - 0.5)   // wraps instead
        // A long dictation stops growing at the transcript viewport (five lines and a faded one), plus the status row.
        let huge = size(String(repeating: "word ", count: 400))
        let cap = 2 * HUDViewMetrics.verticalPadding + 20 + 8 + HUDViewMetrics.transcriptMaxHeight(wordWaveform: false)
        #expect(abs(huge.height - cap) < 1 && size(String(repeating: "word ", count: 300)).height == huge.height)
    }
}

/// The ideal size of a SwiftUI view, as the HUD panel measures it.
@MainActor
enum NSHostingViewSize {
    static func of<V: SwiftUI.View>(_ view: V) -> CGSize {
        let host = NSHostingView(rootView: view)
        return host.fittingSize
    }
}

// MARK: first-run flow

@Suite struct OnboardingFlowTests {
    private func checks(mic: MicrophoneAccess = .granted, ax: Bool = true, server: ServerCheck = .ready(engine: "e")) -> OnboardingChecks {
        var c = OnboardingChecks()
        c.microphone = mic; c.accessibility = ax; c.server = server
        return c
    }

    @Test func walksWelcomeMicAccessibilityServerTryIt() {
        var flow = OnboardingFlow()
        var done = 0
        var seen = [flow.step]
        while !flow.advance(markDone: { done += 1 }) { seen.append(flow.step) }
        #expect(seen == [.welcome, .microphone, .accessibility, .server, .tryIt])
        #expect(done == 1)
    }

    @Test func completionIsPersistedOnlyWhenTheLastStepIsFinished() {
        var flow = OnboardingFlow()
        var done = 0
        for _ in 0..<4 { flow.advance(markDone: { done += 1 }) }
        #expect(flow.isLast && done == 0)       // the window closes here: nothing was recorded
        flow.advance(markDone: { done += 1 })
        #expect(done == 1)
    }

    @Test func theStoredFlagIsSetThroughMarkDoneOnly() throws {
        let suite = "chirp-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        var flow = OnboardingFlow()
        for _ in 0..<4 { flow.advance(markDone: { prefs.didOnboard = true }) }
        #expect(!prefs.didOnboard)
        flow.advance(markDone: { prefs.didOnboard = true })
        #expect(prefs.didOnboard)
    }

    @Test func backStopsAtWelcomeAndRestartResets() {
        var flow = OnboardingFlow()
        flow.back()
        #expect(flow.isFirst)
        flow.advance(markDone: {}); flow.advance(markDone: {})
        flow.heardHotkey = true
        flow.back()
        #expect(flow.step == .microphone)
        flow.restart()
        #expect(flow.isFirst && !flow.heardHotkey)
    }

    @Test func eachStepIsSatisfiedByItsLiveState() {
        var flow = OnboardingFlow()
        #expect(flow.isSatisfied(.welcome, checks(mic: .denied, ax: false, server: .noToken)))
        #expect(flow.isSatisfied(.microphone, checks()) && !flow.isSatisfied(.microphone, checks(mic: .notAsked)))
        #expect(!flow.isSatisfied(.microphone, checks(mic: .denied)))
        #expect(flow.isSatisfied(.accessibility, checks()) && !flow.isSatisfied(.accessibility, checks(ax: false)))
        #expect(flow.isSatisfied(.server, checks()))
        for bad in [ServerCheck.checking, .loadingModel, .noToken, .unreachable(host: "h")] {
            #expect(!flow.isSatisfied(.server, checks(server: bad)))
        }
        #expect(!flow.isSatisfied(.tryIt, checks()))
        flow.heardHotkey = true
        #expect(flow.isSatisfied(.tryIt, checks()))
    }

    @Test func primaryButtonSaysSkipUntilTheStepIsDone() {
        var flow = OnboardingFlow()
        #expect(flow.primaryTitle(checks()) == "Get Started")
        flow.advance(markDone: {})
        #expect(flow.primaryTitle(checks(mic: .notAsked)) == "Skip for now")
        #expect(flow.primaryTitle(checks()) == "Continue")
        for _ in 0..<3 { flow.advance(markDone: {}) }
        #expect(flow.primaryTitle(checks()) == "Skip")
        flow.heardHotkey = true
        #expect(flow.primaryTitle(checks()) == "Done")
    }

    @Test func serverCheckPrefersAReachableServer() {
        let up = Health(engine: "parakeet", ready: true)
        #expect(ServerCheck.of(tokenPresent: true, health: up, healthError: nil, host: "h") == .ready(engine: "parakeet"))
        #expect(ServerCheck.of(tokenPresent: false, health: up, healthError: nil, host: "h") == .ready(engine: "parakeet"))
        #expect(ServerCheck.of(tokenPresent: true, health: Health(ready: false), healthError: nil, host: "h") == .loadingModel)
        #expect(ServerCheck.of(tokenPresent: false, health: nil, healthError: "x", host: "h") == .noToken)
        #expect(ServerCheck.of(tokenPresent: true, health: nil, healthError: "x", host: "127.0.0.1") == .unreachable(host: "127.0.0.1"))
        #expect(ServerCheck.of(tokenPresent: true, health: nil, healthError: nil, host: "h") == .checking)
    }

    @Test func everyFixableStatusHasAFixButton() {
        #expect(OnboardingStatus.of(.welcome, checks()) == nil && OnboardingStatus.of(.tryIt, checks()) == nil)
        #expect(OnboardingStatus.of(.microphone, checks())?.fixTitle == nil)
        #expect(OnboardingStatus.of(.microphone, checks(mic: .notAsked))?.fixTitle == "Allow…")
        #expect(OnboardingStatus.of(.microphone, checks(mic: .denied))?.fixTitle == "Open Settings…")
        #expect(OnboardingStatus.of(.accessibility, checks(ax: false))?.fixTitle == "Allow…")
        #expect(OnboardingStatus.of(.server, checks(server: .unreachable(host: "h")))?.text == "Can’t reach h")
        #expect(OnboardingStatus.of(.server, checks(server: .noToken))?.fixTitle == "Copy Fix Command")
        #expect(OnboardingStatus.of(.server, checks(server: .loadingModel))?.fixTitle == nil)
        #expect(OnboardingStatus.of(.server, checks())?.tone == .ok)
    }
}

@MainActor
@Suite struct OnboardingViewTests {
    @Test func showsTheStepAndItsFixButton() {
        let view = OnboardingView(icon: nil)
        var c = OnboardingChecks()
        c.microphone = .denied
        view.apply(OnboardingState(step: .microphone, checks: c))
        #expect(view.primary.title == "Skip for now" && !view.fix.isHidden && view.fix.title == "Open Settings…")
        #expect(!view.back.isHidden)
        c.microphone = .granted
        view.apply(OnboardingState(step: .microphone, checks: c))
        #expect(view.primary.title == "Continue" && view.fix.isHidden)
        view.apply(OnboardingState(step: .welcome))
        #expect(view.back.isHidden && view.primary.title == "Get Started")
    }

    @Test func tryItShowsAWaitingThenASuccessState() {
        let view = OnboardingView(icon: nil)
        func status() -> String? {
            func find(_ v: NSView) -> String? {
                if let f = v as? NSTextField, f.accessibilityIdentifier() == "try-it-status" { return f.stringValue }
                for s in v.subviews { if let r = find(s) { return r } }
                return nil
            }
            return find(view)
        }
        view.apply(OnboardingState(step: .tryIt))
        #expect(status() == "Waiting for Right ⌥ Option…" && view.primary.title == "Skip")
        view.apply(OnboardingState(step: .tryIt, heardHotkey: true))
        #expect(status() == "It works — Chirp heard Right ⌥ Option" && view.primary.title == "Done")
        // The dictation target survives step changes (it is one field, not rebuilt text).
        view.tryField.stringValue = "hello"
        view.apply(OnboardingState(step: .tryIt, heardHotkey: true))
        #expect(view.tryField.stringValue == "hello")
    }

    @Test func hasAFixedSizeOnEveryStep() {
        let view = OnboardingView(icon: nil)
        for step in OnboardingStep.allCases {
            view.apply(OnboardingState(step: step))
            #expect(view.fittingSize == OnboardingView.size)
        }
    }
}

// MARK: About

@Suite struct AboutInfoTests {
    @Test func versionLine() {
        #expect(AboutInfo(version: "0.1.0", build: "1").line == "Version 0.1.0 (1)")
        #expect(AboutInfo(version: "0.1.0", build: nil).line == "Version 0.1.0")
        #expect(AboutInfo(version: "0.1.0", build: "0.1.0").line == "Version 0.1.0")
        #expect(AboutInfo(version: nil, build: "7").line == "Development build")
        #expect(AboutInfo(infoDictionary: nil).line == "Development build")
        #expect(AboutInfo(infoDictionary: ["CFBundleShortVersionString": "0.3.1", "CFBundleVersion": "12"]).line == "Version 0.3.1 (12)")
    }
}

@MainActor
@Suite struct AboutViewTests {
    @Test func showsIconNameAndVersion() {
        let icon = ChirpBrand.glyph() ?? NSImage(systemSymbolName: "bird.fill", accessibilityDescription: nil)
        let view = AboutView(icon: icon, info: AboutInfo(version: "0.1.0", build: "1"))
        func texts(_ v: NSView) -> [String] {
            (v as? NSTextField).map { [$0.stringValue] } ?? v.subviews.flatMap(texts)
        }
        func images(_ v: NSView) -> [NSImageView] { (v as? NSImageView).map { [$0] } ?? v.subviews.flatMap(images) }
        #expect(texts(view).contains("Chirp") && texts(view).contains("Version 0.1.0 (1)"))
        #expect(images(view).count == 1 && images(view)[0].image === icon)
        #expect(view.fittingSize.width == 320)
    }
}
