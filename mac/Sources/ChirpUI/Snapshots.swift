import AppKit
import ImageIO
import Carbon.HIToolbox
import ChirpCore
import SwiftUI

/// Offscreen rendering of every HUD state, the Settings, setup and About windows and the menu-bar menu, for UI review without
/// launching the app. It draws views into bitmaps only: no window is shown, and it never touches the microphone,
/// Accessibility, the pasteboard, the system settings store or any TCC-gated API. All inputs are synthetic.
@MainActor
public enum Snapshots {
    public struct Scenario {
        public let name: String
        let make: () -> NSView
        /// A whole window instead (the Notes window: its toolbar, sidebar and inspector are window chrome).
        var window: (() -> NSWindow)?

        init(name: String, make: @escaping () -> NSView) {
            self.name = name
            self.make = make
        }

        init(name: String, window: @escaping () -> NSWindow) {
            self.name = name
            make = { NSView() }
            self.window = window
        }
    }

    public static let appearances: [(name: String, appearance: NSAppearance.Name)] = [
        ("light", .aqua), ("dark", .darkAqua),
    ]

    // MARK: HUD

    private static let sentence = "Please move the standup to three thirty and let everyone know"

    /// The brand glyph (the operator-approved template PNG in `Assets/`), About and onboarding's hero.
    static let appIcon: NSImage? = ChirpBrand.glyph()

    static func hud(_ name: String, _ configure: @escaping (HUDModel) -> Void) -> Scenario {
        Scenario(name: "hud-\(name)") {
            let model = HUDModel()
            // No window to blur through offscreen, so the HUD draws its flat stand-in for the material.
            model.flatSurface = true
            model.duration = "0:24 / 10:00"
            configure(model)
            return NSHostingView(rootView: SnapshotBackdrop { HUDView(model: model) })
        }
    }

    private static let rawSentence = "move the standup to three thirty and uh let everyone know"
    /// About 600 characters: five times the 120 the HUD used to keep.
    static let longDictation = "Okay so for the planning doc, first we need to move the standup to three thirty on Thursday because the design review runs long, then check the rollout plan with the whole team before the release review, and remind the designers about the icon sizes for the settings page, we still need the dark variants and the notification badge, and the onboarding copy needs one more pass from marketing, after that book the big room for Friday afternoon, order lunch for twelve people, ask finance whether the new laptops are approved, and make sure the on-call rota covers the long weekend"

    // MARK: word waveform demo data

    /// Word timings at a natural pace with a few pauses, and levels shaped like speech inside each word (near silence
    /// between them): deterministic, so the committed PNGs are reproducible.
    static func demoWords(_ text: String, pauseAfter: Set<Int> = [], stableBefore: Int = 0) -> [WordTiming] {
        var t = 0.25
        return text.split(separator: " ").enumerated().map { i, word in
            let length = 0.12 + 0.045 * Double(word.count)
            let timing = WordTiming(text: String(word), start: t, end: t + length, stable: i < stableBefore)
            t += length + (pauseAfter.contains(i) ? 0.75 : 0.09)
            return timing
        }
    }

    static func demoLevels(for words: [WordTiming], peak: Float = 0.9) -> UtteranceLevels {
        let frames = Int(((words.last?.end ?? 0) + 0.3) / UtteranceLevels.frameDuration)
        var samples = [Float](repeating: 0, count: frames)
        for (w, word) in words.enumerated() {
            let first = Int(word.start / UtteranceLevels.frameDuration), last = Int(word.end / UtteranceLevels.frameDuration)
            for f in first...max(first, last) where f < frames {
                let x = Double(f - first) / Double(max(1, last - first))          // 0...1 across the word
                let envelope = sin(x * .pi) * (0.65 + 0.35 * sin(Double(f) * 1.7 + Double(w)))
                samples[f] = Float(max(0.08, envelope)) * peak
            }
        }
        for f in samples.indices where samples[f] == 0 { samples[f] = 0.03 + 0.02 * Float(abs(sin(Double(f) * 0.9))) }
        return UtteranceLevels(samples: samples)
    }

    static func wordWave(_ name: String, _ text: String, pauseAfter: Set<Int> = [], stableBefore: Int = 0,
                         _ configure: @escaping (HUDModel) -> Void = { _ in }) -> Scenario {
        hud("wordwave-\(name)") { m in
            m.wordWaveform = true
            m.status = HUDStatus.listening
            m.levels = .demo(peak: 0.8)
            m.pulsePhase = 0.25
            let words = demoWords(text, pauseAfter: pauseAfter, stableBefore: stableBefore)
            m.utterance = demoLevels(for: words)
            m.showWords(text: text, words: words)
            configure(m)
        }
    }

    public static var wordWaveScenarios: [Scenario] {
        let short = "Please move the standup to three thirty and let everyone know"
        let long = "Please move the standup to three thirty and let everyone know, then check the rollout plan with the whole team before the release review, and remind the designers about the icon sizes, we still need the dark variants and the notification badge, and finally book the room"
        return [
            wordWave("listening", short, pauseAfter: [4], stableBefore: 6),
            wordWave("listening-start", "so the first", stableBefore: 0),
            wordWave("long", long, pauseAfter: [11, 23, 34], stableBefore: 40),
            wordWave("polishing", rawSentence, pauseAfter: [5]) { $0.beginPolishing(raw: rawSentence, style: "Email", words: nil); $0.shimmerPhase = 0.45 },
            wordWave("revised", short, pauseAfter: [4], stableBefore: 3) { m in
                var words = demoWords(short, pauseAfter: [4], stableBefore: 3)
                words[6].text = "and then"; words[7].text = "let"
                m.showWords(text: words.map(\.text).joined(separator: " "), words: words)
            },
            wordWave("finished", short, pauseAfter: [4]) { m in
                m.finishWords(text: short, words: demoWords(short, pauseAfter: [4]))
                m.status = HUDStatus.inserting
            },
            wordWave("reduce-motion", short, pauseAfter: [4], stableBefore: 6) { $0.reduceMotion = true },
            wordWave("contrast", short, pauseAfter: [4], stableBefore: 6) { $0.increaseContrast = true },
            wordWave("multiline-polishing", long, pauseAfter: [11, 23, 34]) { $0.beginPolishing(raw: long, style: "Notes", words: nil); $0.shimmerPhase = 0.6 },
        ]
    }
    private static let cleanedSentence = "Move the standup to 3:30 and let everyone know."

    private static func final(corrected: Bool = false) -> FinalResult {
        corrected ? FinalResult(text: "Move the standup to 3:30.", raw: "move the standup to three thirty", corrected: true)
                  : FinalResult(text: "Move the standup to 3:30.")
    }

    private static func applyOutcome(_ outcome: InsertionOutcome, final: FinalResult, offerRaw: Bool = true, to m: HUDModel) {
        let p = OutcomePresentation.of(outcome, final: final, offerRaw: offerRaw)
        m.status = p.status; m.indicator = p.indicator; m.isError = p.isError; m.showUseRaw = p.showUseRaw; m.cleaned = p.cleaned
        m.keptOriginal = p.keptOriginal
    }

    /// The Pond Ripple at review size (the HUD glyph is 20 pt): driven at a few levels, plus the
    /// Reduce Motion ring whose stroke follows the level.
    public static var rippleScenarios: [Scenario] {
        func ripple(_ name: String, _ make: @escaping () -> Ripple) -> Scenario {
            Scenario(name: "ripple-\(name)") { NSHostingView(rootView: SnapshotBackdrop { make() }) }
        }
        return [
            ripple("silent") { Ripple(level: 0, phase: 0.15, side: 120) },
            ripple("speech") { Ripple(level: 0.7, phase: 0.4, side: 120) },
            ripple("peak") { Ripple(level: 1, phase: 0.8, side: 120) },
            ripple("static") { Ripple(level: 0.7, reduceMotion: true, side: 120) },
        ]
    }

    public static var hudScenarios: [Scenario] {
        let (stable, tail) = splitPartial(text: sentence + " about the release", stable: sentence)
        let long = Array(repeating: "and then we should also check the rollout plan with the whole team", count: 5).joined(separator: ", ")
        return [
            hud("rolling") { $0.status = HUDStatus.listening; $0.duration = "2:01 / 10:00"; $0.stable = sentence; $0.levels = .demo(peak: 0.8) },
            hud("private") { $0.status = HUDStatus.listening; $0.privateSession = true; $0.duration = "0:24 / 10:00"; $0.stable = sentence; $0.levels = .demo(peak: 0.6) },
            hud("duration-limit") { $0.status = HUDStatus.finishing; $0.duration = "10:00 / 10:00"; $0.stable = sentence },
            hud("connecting") { $0.status = HUDStatus.connecting },
            hud("listening") { $0.status = HUDStatus.listening; $0.levels = .demo(peak: 0.8); $0.pulsePhase = 0.4; $0.stable = stable; $0.unstable = tail },
            hud("listening-no-text") { $0.status = HUDStatus.listening; $0.levels = .demo(peak: 0.45); $0.pulsePhase = 0.4 },
            hud("listening-unstable-only") { $0.status = HUDStatus.listening; $0.levels = .demo(peak: 1); $0.pulsePhase = 0.4; $0.unstable = "so the first words are" },
            // A long dictation: the viewport keeps the newest lines and fades the earlier ones at the top edge.
            hud("long-dictation") {
                $0.status = HUDStatus.listening; $0.duration = "1:12 / 10:00"; $0.levels = .demo(peak: 0.7); $0.pulsePhase = 0.4
                $0.stable = longDictation; $0.unstable = " and send the notes to everyone"
            },
            hud("listening-multiline") { $0.status = HUDStatus.listening; $0.levels = .demo(peak: 0.7); $0.pulsePhase = 0.6; $0.stable = long; $0.unstable = " and finally" },
            hud("listening-reduce-motion") { $0.status = HUDStatus.listening; $0.reduceMotion = true; $0.levels = .demo(peak: 0.6); $0.stable = stable; $0.unstable = tail },
            hud("listening-contrast") {
                $0.status = HUDStatus.listening; $0.levels = .demo(peak: 0.8); $0.pulsePhase = 0.4; $0.increaseContrast = true
                $0.stable = stable; $0.unstable = tail
            },
            // The clean-up transition, in order: listening → finishing → polishing → changes → inserted.
            hud("flow-1-listening") {
                $0.status = HUDStatus.listening; $0.levels = .demo(peak: 0.8); $0.styleName = "Email"
                $0.stable = rawSentence; $0.unstable = ""
            },
            hud("flow-2-polishing") {
                $0.beginPolishing(raw: rawSentence, style: "Email"); $0.shimmerPhase = 0.45
            },
            hud("flow-3-diff") {
                $0.status = HUDStatus.polished; $0.indicator = .sparkle; $0.styleName = "Email"
                $0.diff = WordDiff.segments(raw: rawSentence, cleaned: cleanedSentence)
            },
            hud("flow-4-diff-fading") {
                $0.status = HUDStatus.polished; $0.indicator = .sparkle; $0.styleName = "Email"
                $0.diff = WordDiff.segments(raw: rawSentence, cleaned: cleanedSentence); $0.diffFade = 0.6
            },
            hud("flow-5-inserted") {
                applyOutcome(.inserted(.ax), final: FinalResult(text: cleanedSentence, raw: rawSentence, corrected: true), to: $0)
                $0.styleName = "Email"; $0.stable = cleanedSentence; $0.onUseRaw = {}
            },
            hud("polishing-reduce-motion") {
                $0.reduceMotion = true; $0.beginPolishing(raw: rawSentence, style: "Chat")
            },
            hud("polishing-multiline") {
                $0.beginPolishing(raw: long, style: "Notes"); $0.shimmerPhase = 0.6
            },
            hud("polishing-contrast") {
                $0.increaseContrast = true; $0.beginPolishing(raw: rawSentence, style: "Code"); $0.shimmerPhase = 0.3
            },
            hud("diff-reduce-motion") {
                $0.reduceMotion = true; $0.status = HUDStatus.polished; $0.indicator = .sparkle; $0.styleName = "Chat"
                $0.diff = WordDiff.segments(raw: rawSentence, cleaned: cleanedSentence)
            },
            hud("kept-original") {
                applyOutcome(.inserted(.ax), final: FinalResult(text: rawSentence, corrected: false, correctionError: "timeout"), to: $0)
                $0.styleName = "Email"; $0.stable = rawSentence
            },
            hud("finalizing") { $0.status = HUDStatus.finishing; $0.stable = sentence; $0.unstable = " about the release" },
            hud("inserted") { applyOutcome(.inserted(.ax), final: final(), to: $0) },
            hud("inserted-paste") { applyOutcome(.inserted(.paste), final: final(), to: $0) },
            hud("correction-use-raw") {
                applyOutcome(.inserted(.ax), final: final(corrected: true), to: $0)
                $0.onUseRaw = {}
            },
            hud("cleaned-no-raw-button") { applyOutcome(.inserted(.ax), final: final(corrected: true), offerRaw: false, to: $0) },
            hud("copied") { applyOutcome(.copied, final: final(), to: $0) },
            hud("unverified-ax") { applyOutcome(.insertedUnverified, final: final(), to: $0) },
            hud("secure-field") { applyOutcome(.refusedSecure, final: final(), to: $0) },
            hud("no-mic-signal") { $0.status = "No microphone signal"; $0.isError = true; $0.indicator = .warning },
            hud("error-long") {
                $0.status = "Server rejected the token (check ~/.config/chirp/token) — then restart dictation"
                $0.isError = true; $0.indicator = .warning
            },
            hud("debug-badge") { $0.status = HUDStatus.listening; $0.levels = .demo(peak: 0.5); $0.debugRetention = true; $0.stable = stable },
            hud("debug-use-raw") {
                applyOutcome(.inserted(.ax), final: final(corrected: true), to: $0)
                $0.debugRetention = true
            },
        ]
    }

    // MARK: Settings and menu

    /// The server's styles with prompt text, as `GET /v1/correction/profiles` would return them.
    static let samplePrompts: [CorrectionProfile] = CorrectionProfile.builtIn.map { p in
        var p = p
        switch p.id {
        case "default": p.prompt = "Fix punctuation, capitalisation and obvious slips. Keep the speaker’s words and order."
        case "chat": p.prompt = "Casual messages: lowercase is fine and a short message needs no final period."
        case "email": p.prompt = "Polished, complete sentences with proper punctuation. Add nothing the speaker did not say."
        case "code": p.prompt = "Keep identifiers, symbols and casing exactly as spoken. Do not expand abbreviations."
        case "notes": p.prompt = "Turn spoken lists into short lines or bullets. Keep every item."
        default: break
        }
        return p
    }

    public static var settingsScenarios: [Scenario] {
        /// A Settings page with enough height to show every section, including Speakers and Saved voices.
        func form(_ name: String, _ tab: SettingsTab, _ configure: (inout SettingsState) -> Void = { _ in }) -> Scenario {
            var state = SettingsState()
            state.launch = .on; state.serverStatus = "parakeet-mlx:tdt-0.6b-v2"
            state.inputs = [boya, studio]; state.defaultInput = boya
            state.about = AboutInfo(version: "0.1.0", build: "1")
            configure(&state)
            return Scenario(name: "settings-\(tab.rawValue)-\(name)") {
                settingsWindow(state, tab)
            }
        }
        let styled: (inout SettingsState) -> Void = {
            $0.cleanupEnabled = true
            $0.catalog = StyleCatalog(profiles: samplePrompts, source: .live)
            $0.cleanupDetail = "Runs on this Mac: tidies punctuation and wording before the text is inserted."
            $0.keepLoaded = KeepLoadedState(settings: CleanupModelSettings(keepLoaded: true, loaded: true, model: "qwen3-4b", memoryMB: 2662),
                                            availability: .available)
        }
        /// Settings → Devices with a fixed clock and zone, so the snapshot never changes with the day it is drawn.
        func devicesForm(_ name: String, _ phase: DevicesPhase, revoking: String? = nil, problem: String? = nil,
                         activity: ActivityPhase = .hidden, keepProblem: String? = nil) -> Scenario {
            Scenario(name: "settings-devices-\(name)") {
                var state = SettingsState()
                state.about = AboutInfo(version: "0.1.0", build: "1")
                return settingsWindow(state, .devices) { form in
                    form.devicesView.apply(phase, revoking: revoking, problem: problem, activity: activity, keepProblem: keepProblem,
                                           now: sampleNow, locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)
                }
            }
        }
        let warmOff = CleanupModelSettings(keepLoaded: false, model: "qwen3-4b", memoryMB: 2662, memoryEstimated: true)
        return [
            devicesForm("ready", .loaded(samplePhones)),
            devicesForm("revoking", .loaded(samplePhones), revoking: "9f3a1c52"),
            devicesForm("empty", .loaded([])),
            devicesForm("unavailable", .unavailable(DevicesError.outdated.message)),
            devicesForm("revoke-failed", .loaded(samplePhones), problem: DevicesError.failed.message),
            devicesForm("remote", .remote("studio.example-tailnet.ts.net")),
            devicesForm("activity", .loaded(samplePhones), activity: .shown(sampleActivity())),
            devicesForm("refused", .loaded(samplePhones), activity: .shown(sampleActivity(refused: true))),
            devicesForm("activity-off", .loaded(samplePhones), activity: .shown(DeviceActivity(started: sampleNow, keep: false))),
            devicesForm("activity-outdated", .loaded(samplePhones), activity: .outdated),
            Scenario(name: "device-activity-sheet") {
                let view = DeviceActivityView()
                view.apply(sampleActivity(refused: true), now: sampleNow, locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)
                return view
            },
            form("ready", .general) { _ in },
            form("login-unavailable", .general) { $0.launch = .unavailable },
            form("missing", .general) { $0.micGranted = false; $0.accessibilityGranted = false },
            form("shortcuts-custom", .dictation) {
                $0.hotkey = .custom(keyCode: 0x0F, modifiers: UInt32(controlKey | optionKey | cmdKey))   // ⌃⌥⌘R
                $0.notesHotkey = .custom(keyCode: 0x2E, modifiers: UInt32(controlKey | optionKey))       // ⌃⌥M
            },
            form("shortcuts-fn", .dictation) { $0.hotkey = .custom(keyCode: KeyCombo.anyModifierKey, modifiers: ModifierKeys.fn) },
            Scenario(name: "settings-dictation-shortcuts-rejected") {
                var state = SettingsState()
                state.inputs = [boya, studio]; state.defaultInput = boya
                return settingsWindow(state, .dictation) { form in
                    // As if ⇧ had just been pressed and let go in the recorder, and ⌃⌥Space typed for New Note (set
                    // directly: no event monitor offscreen).
                    form.recorder.apply(.rejected(.shiftAlone))
                    form.notesShortcut.refuse(.inUse("dictation"))
                }
            },
            form("ready", .dictation) { _ in },
            form("private", .privacy) {
                $0.privateSession = true
                $0.historyCount = 12
                $0.learnedSummary = "2 in use"
            },
            form("option-hold", .dictation) { $0.hotkey = .option; $0.activationMode = .holdToTalk },
            form("picked-microphone", .dictation) { $0.chosenInputUID = "studio" },
            form("sounds", .dictation) { $0.soundsEnabled = true; $0.soundPack = .chirp; $0.soundVolume = 0.6 },
            form("sounds-custom", .dictation) {
                $0.soundsEnabled = true; $0.soundPack = .custom; $0.soundVolume = 0.4
                $0.customStart = CustomSound(fileName: "custom-start-1a2b3c4d.m4a", displayName: "Doorbell chime.m4a", duration: 1.2)
                $0.customStop = CustomSound(fileName: "custom-stop-5e6f7a8b.wav", displayName: "soft-tap.wav", duration: 0.18)
            },
            form("default", .cleanup) { styled(&$0); $0.editingStyle = "default" },
            form("custom", .cleanup) {
                styled(&$0)
                $0.cleanupStyle = "custom"; $0.insertRawFirst = true; $0.editingStyle = "custom"
                $0.stylePrompts = ["custom": "Write like a short, friendly note to a teammate. Keep product names exactly as spoken and never add facts I did not say."]
                $0.appStyles = [AppStyleRule(bundleID: "com.tinyspeck.slackmacgap", profile: "chat"),
                                AppStyleRule(bundleID: "com.apple.mail", profile: "custom"),
                                AppStyleRule(bundleID: "com.apple.dt.Xcode", profile: "code")]
            },
            form("prompt-default", .cleanup) { styled(&$0); $0.editingStyle = "email" },
            form("prompt-edited", .cleanup) {
                styled(&$0)
                $0.editingStyle = "chat"; $0.showChanges = true
                $0.stylePrompts = ["chat": "Casual and brief. Lowercase is fine. Keep emoji names as spoken, like “thumbs up”."]
            },
            form("prompt-offline", .cleanup) {
                styled(&$0)
                $0.serverStatus = "Unreachable"; $0.serverStatusTone = .error
                $0.catalog = StyleCatalog(profiles: samplePrompts, source: .cached)
                $0.editingStyle = "code"
            },
            form("no-styles", .cleanup) {
                $0.cleanupEnabled = true; $0.cleanupStyle = "notes"; $0.serverOffersStyles = false
            },
            form("unavailable", .cleanup) {
                $0.cleanupDetail = "The server has clean-up turned off; see the README to enable it."; $0.cleanupAvailable = false
            },
            form("library", .notes) {
                $0.notesRetention = .ninetyDays; $0.recentlyDeletedCount = 3
                $0.notesKeepAudio = true; $0.notesAudioBytes = 48_300_000
                $0.exportFolder = NSHomeDirectory() + "/Documents/Notes"
                $0.structureNotes = true; $0.autoReorganize = true
            },
            form("downloaded", .notes) { $0.speakerModelDownloaded = true },
            // The whole Notes page, down to Speakers (the real window scrolls to it).
            Scenario(name: "settings-notes-speakers") {
                var state = SettingsState()
                state.speakerModelDownloaded = true; state.speakerLabels = true
                return settingsWindow(state, .notes, full: true)
            },
            form("not-downloaded", .notes) { _ in },
            form("ready", .advanced) { styled(&$0) },
            form("unreachable", .advanced) {
                $0.tokenPresent = false; $0.serverURL = "https://mainframe.example.ts.net/chirp"
                $0.serverStatus = "Unreachable"; $0.serverStatusTone = .error
            },
            form("warm-off", .advanced) { styled(&$0); $0.keepLoaded = KeepLoadedState(settings: warmOff, availability: .available) },
            form("warm-loading", .advanced) {
                styled(&$0)
                $0.keepLoaded = KeepLoadedState(settings: CleanupModelSettings(keepLoaded: true, loading: true, model: "qwen3-4b", memoryMB: 2662, memoryEstimated: true),
                                                availability: .available)
            },
            form("warm-remote-host", .advanced) {
                styled(&$0); $0.serverHost = "mainframe.example.ts.net"; $0.serverURL = "https://mainframe.example.ts.net/chirp"
                $0.keepLoaded = KeepLoadedState(settings: CleanupModelSettings(keepLoaded: true, loaded: true, model: "qwen3-4b", memoryMB: 2662),
                                                availability: .available)
            },
            form("warm-error", .advanced) {
                styled(&$0)
                $0.keepLoaded = KeepLoadedState(settings: warmOff, availability: .available, error: CleanupSettingsError.unreachable.changeFailure)
            },
            form("warm-old-server", .advanced) { styled(&$0); $0.keepLoaded = KeepLoadedState(availability: .unavailable(.serverTooOld)) },
            form("warm-remote-model", .advanced) { styled(&$0); $0.keepLoaded = KeepLoadedState(availability: .unavailable(.remoteModel)) },
            form("ready", .about) { _ in },
        ]
    }

    /// The Settings window's content for `state`, opened on `tab`: the sidebar (flat, with no window to blur through) and the
    /// page, with the permission badge General shows. `prepare` sets up the form first (a device list, a refused shortcut).
    static func settingsWindow(_ state: SettingsState, _ tab: SettingsTab, full: Bool = true,
                               prepare: (SettingsForm) -> Void = { _ in }) -> NSView {
        let form = SettingsForm(state, icon: appIcon, onNotices: {})
        prepare(form)
        let shell = SettingsShell(form: form, selected: tab, flat: true)
        // `full` stretches the window to the whole page, for review (the real window is fixed and scrolls).
        if full { shell.contentHeight = max(SettingsShell.size.height, form.fittingSize(for: tab).height + 28) }
        shell.setBadge(SettingsShell.permissionProblems(micGranted: state.micGranted, accessibilityGranted: state.accessibilityGranted))
        return shell
    }

    // MARK: setup and About

    public static var onboardingScenarios: [Scenario] {
        func step(_ name: String, _ state: OnboardingState) -> Scenario {
            Scenario(name: "onboarding-\(name)") {
                let view = OnboardingView(icon: appIcon)
                view.apply(state)
                return view
            }
        }
        func checks(_ configure: (inout OnboardingChecks) -> Void) -> OnboardingChecks {
            var c = OnboardingChecks()
            configure(&c)
            return c
        }
        return [
            step("welcome", OnboardingState(step: .welcome)),
            step("microphone-needed", OnboardingState(step: .microphone, checks: checks { $0.microphone = .notAsked })),
            step("microphone-blocked", OnboardingState(step: .microphone, checks: checks { $0.microphone = .denied })),
            step("accessibility-needed", OnboardingState(step: .accessibility, checks: checks { $0.accessibility = false })),
            step("server-ready", OnboardingState(step: .server, checks: checks { $0.server = .ready(engine: "parakeet-mlx:tdt-0.6b-v2") })),
            step("server-unreachable", OnboardingState(step: .server, checks: checks { $0.server = .unreachable(host: "127.0.0.1") })),
            step("try-it-waiting", OnboardingState(step: .tryIt)),
            step("try-it-success", OnboardingState(step: .tryIt, heardHotkey: true)),
        ]
    }

    /// A made-up link: the snapshots never read the real token.
    static let sampleLink = try! PairingLink(serverURL: TailscaleServe.pairingURL(host: "my-mac.example-tailnet.ts.net"),
                                             token: "snapshot-sample-not-a-real-token-0123456789")

    /// The library's newest notes as the menu's Recent Notes lists them (relative to `sampleNow`).
    static let sampleRecentNotes = [
        RecentNote(id: "n1", title: "Weekly standup", updatedAt: sampleNow.addingTimeInterval(-14 * 60)),
        RecentNote(id: "n2", title: "Launch checklist", updatedAt: sampleNow.addingTimeInterval(-3 * 3_600)),
        RecentNote(id: "n3", title: "Ideas for the icon sizes", updatedAt: sampleNow.addingTimeInterval(-26 * 3_600)),
        RecentNote(id: "n4", title: "Call with the design team", updatedAt: sampleNow.addingTimeInterval(-4 * 86_400)),
        RecentNote(id: "n5", title: "Note, 3 October", updatedAt: sampleNow.addingTimeInterval(-11 * 86_400)),
    ]

    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    static let sampleNow = Date(timeIntervalSince1970: 1_792_000_000)   // 2026-10-14 17:46 UTC
    static let samplePhones = [
        PairedDevice(id: "9f3a1c52", name: "Pixel 9", created: sampleNow.addingTimeInterval(-9 * 86_400), lastSeen: sampleNow.addingTimeInterval(-40)),
        PairedDevice(id: "04be77d1", name: "iPad", created: sampleNow.addingTimeInterval(-40 * 86_400), lastSeen: sampleNow.addingTimeInterval(-3 * 3_600)),
        PairedDevice(id: "c81d20aa", name: "Akshay’s phone", created: sampleNow.addingTimeInterval(-3_600)),
    ]

    /// What a busy day looks like to Settings → Devices: the Pixel is dictating now, the iPad cleaned up notes a few minutes ago,
    /// this Mac and a phone on the shared token have been used too.
    static func sampleActivity(refused: Bool = false) -> DeviceActivity {
        let pixel = ActivitySource.device(id: "9f3a1c52", name: "Pixel 9", revoked: false)
        let ipad = ActivitySource.device(id: "04be77d1", name: "iPad", revoked: false)
        func event(_ ago: TimeInterval, _ source: ActivitySource, _ client: String, _ kind: ActivityKind, audio: Int? = nil,
                   ms: Int = 1_800, _ outcome: ActivityOutcome = .ok) -> ActivityEvent {
            ActivityEvent(at: sampleNow.addingTimeInterval(-ago), source: source, client: client, kind: kind, profile: "default",
                          durationMS: ms, audioMS: audio, outcome: outcome)
        }
        var events = [
            event(95, .local, "mac", .dictation, audio: 4_100),
            event(180, ipad, "ios", .notesStructure, ms: 6_200),
            event(240, pixel, "android", .dictation, audio: 9_800),
            event(600, .shared, "ios", .notesSegment, audio: 41_800, ms: 2_310),
            event(900, ipad, "ios", .notesReorganize, ms: 9_400, .timeout),
            event(1_500, pixel, "android", .dictation, audio: 2_600, .cancelled),
            event(2_400, .local, "mac", .transcribe, audio: 61_000, ms: 3_900),
        ]
        // A dozen requests from the iPad today (the row counts them).
        for i in 0..<10 { events.append(event(3_000 + Double(i) * 200, ipad, "ios", .notesSegment, audio: 20_000, ms: 1_500)) }
        let active = [ActiveRequest(source: pixel, client: "android", kind: .dictation, profile: "default", since: sampleNow.addingTimeInterval(-3))]
        let refusals = refused ? [
            Refusal(reason: .unknownToken, count: 3, last: sampleNow.addingTimeInterval(-300)),
            Refusal(reason: .revoked, deviceID: "11aa22bb", deviceName: "Old Pixel", count: 2, last: sampleNow.addingTimeInterval(-3_600)),
        ] : []
        return DeviceActivity(started: sampleNow.addingTimeInterval(-8 * 3_600), active: active, events: events, refused: refusals)
    }

    public static var pairingScenarios: [Scenario] {
        func pairing(_ name: String, _ step: PairingStep, remaining: Int = 107, concealed: Bool = false) -> Scenario {
            Scenario(name: "pairing-\(name)") {
                let view = PairingView()
                view.apply(step, remaining: remaining, concealed: concealed)
                return view
            }
        }
        let command = TailscaleServe.publishCommand(port: 7821)
        return [
            pairing("checking", .checking),
            pairing("naming", .naming(suggested: "Akshay’s phone", problem: nil)),
            pairing("naming-taken", .naming(suggested: "Pixel 9", problem: "A device with that name is already paired; revoke it first")),
            pairing("cannot-mint", .cannotMint(DevicesError.outdated.message)),
            pairing("ready", .ready(sampleLink)),
            pairing("concealed", .ready(sampleLink), concealed: true),
            pairing("not-served", .notServed(command: command)),
            pairing("publish-failed", .publishFailed(command: command, reason: "Serve is not enabled on your tailnet.\nTo enable, visit the Tailscale admin console.")),
            pairing("no-tailscale", .noTailscale),
            pairing("funnel", .funnel),
            pairing("conflict", .conflict("http://127.0.0.1:9000")),
        ]
    }

    private static let boya = AudioInput(uid: "boya", name: "BOYA CM40")
    private static let studio = AudioInput(uid: "studio", name: "Studio Display Microphone")

    public static var menuScenarios: [Scenario] {
        func menu(_ name: String, highlighting: String? = nil, _ configure: (inout MenuInputs) -> Void) -> Scenario {
            var inputs = MenuInputs()
            inputs.inputs = [boya, studio]
            inputs.defaultInput = boya
            inputs.now = sampleNow
            inputs.calendar = utcCalendar
            inputs.recentNotes = sampleRecentNotes
            configure(&inputs)
            let header = MenuContent.header(inputs)
            let entries = MenuContent.entries(inputs)
            return Scenario(name: "menu-\(name)") { MenuPanelView(header: header, entries: entries, highlighting: highlighting) }
        }
        func submenu(_ name: String, of title: String, _ configure: (inout MenuInputs) -> Void) -> Scenario {
            var inputs = MenuInputs()
            inputs.inputs = [boya, studio]
            inputs.defaultInput = boya
            inputs.now = sampleNow
            inputs.calendar = utcCalendar
            inputs.recentNotes = sampleRecentNotes
            configure(&inputs)
            let rows = MenuContent.entries(inputs).first { $0.title == title }?.submenu ?? []
            return Scenario(name: "menu-\(name)") { MenuPanelView(header: nil, entries: rows, native: true) }
        }
        let local = Health(engine: "parakeet-mlx:tdt-0.6b-v2", ready: true, correction: "available", correctionLeavesMachine: false,
                           correctionProfiles: CorrectionProfile.builtIn)
        let remote = Health(engine: "parakeet-mlx:tdt-0.6b-v2", ready: true, debugRetention: true, correction: "available",
                            correctionLeavesMachine: true, correctionHost: "llm.example.com",
                            correctionProfiles: CorrectionProfile.builtIn)
        return [
            menu("private") { $0.health = local; $0.privateSession = true },
            menu("ready") { $0.health = local },
            menu("hover", highlighting: "Clean-up") { $0.health = local; $0.cleanupOn = true; $0.styleID = "email" },
            menu("paused") { $0.health = local; $0.paused = true; $0.hotkeyRegistered = false },
            menu("listening") { $0.state = .listening; $0.health = local; $0.cleanupOn = true; $0.styleID = "email" },
            menu("polishing") { $0.state = .correcting; $0.health = local; $0.cleanupOn = true },
            menu("debug") {
                $0.health = remote; $0.debugRetention = true; $0.cleanupOn = true
                $0.chosenInputUID = "studio"
            },
            menu("cleanup-off-on-server") { $0.health = Health(engine: "parakeet-mlx:tdt-0.6b-v2", ready: true, correction: "off") },
            menu("unreachable") {
                $0.healthError = "Server unreachable at 127.0.0.1"
            },
            menu("permissions-missing") {
                $0.health = Health(engine: "parakeet-mlx:tdt-0.6b-v2", ready: true)
                $0.micGranted = false; $0.accessibilityGranted = false
            },
            menu("error") {
                $0.state = .error("Microphone access denied — enable it in System Settings")
                $0.health = local; $0.micGranted = false; $0.inputs = []; $0.defaultInput = nil
            },
            menu("notes-recording") {
                $0.health = local; $0.cleanupOn = true
                $0.notesRecording = true; $0.notesElapsed = "03:12"; $0.notesTitle = "Weekly standup"; $0.notesHasDocument = true
            },
            menu("loading") { $0.health = Health(engine: "parakeet-mlx:tdt-0.6b-v2", ready: false) },
            menu("empty-library") { $0.health = local; $0.recentNotes = [] },
            menu("use-raw") { $0.health = local; $0.cleanupOn = true; $0.rawOfferOpen = true; $0.rawOfferKey = "⌃⌥Z" },
            menu("long-names") {
                $0.health = local; $0.chosenInputUID = "long"
                $0.inputs = [boya, AudioInput(uid: "long", name: "Studio Display Microphone (Built-in, Aggregate)")]
            },
            submenu("cleanup-submenu", of: "Clean-up") { $0.health = local; $0.cleanupOn = true; $0.styleID = "email" },
            submenu("cleanup-submenu-off", of: "Clean-up") { $0.health = local },
            submenu("recent-notes-submenu", of: "Recent Notes") { $0.health = local },
            submenu("microphone-submenu", of: "Microphone") { $0.health = local; $0.chosenInputUID = "studio" },
        ]
    }

    /// The scenarios whose PNGs are committed under `docs/screenshots/mac`: the key HUD states, the menu in light and
    /// dark, one per Settings tab, and the setup window. The rest only render to a temporary directory for review.
    public static let committedNames: [String] = [
        "hud-rolling", "hud-private", "hud-duration-limit", "hud-long-dictation", "menu-private", "settings-privacy-private",
        "hud-listening", "ripple-speech", "ripple-static",
        "hud-flow-2-polishing", "hud-flow-3-diff", "hud-correction-use-raw",
        "hud-wordwave-listening", "hud-wordwave-long", "hud-wordwave-polishing",
        "menu-ready", "menu-notes-recording", "menu-recent-notes-submenu", "menu-cleanup-submenu",
        "settings-general-ready", "settings-general-missing", "settings-dictation-ready", "settings-dictation-shortcuts-custom",
        "settings-dictation-sounds", "settings-cleanup-custom", "settings-notes-library", "settings-notes-downloaded",
        "settings-devices-ready", "settings-advanced-ready", "settings-about-ready", "onboarding-welcome",
        "notes-empty", "notes-library", "notes-recording", "notes-search", "notes-no-results", "notes-deleted",
        "notes-continued", "notes-inspector-playing", "notes-review-sheet",
        "notes-transcript-speakers", "notes-transcript-speakers-renamed", "notes-recording-call", "notes-sources-call",
        "notes-speaker-model-downloading", "notes-speaker-model-failed",
        "notes-name-speakers-line", "notes-name-speakers-sheet", "notes-name-speakers-suggest", "notes-name-speakers-remember",
        "history-cleaned", "history-empty", "menu-recent-dictations-submenu",
        "settings-saved-voices-ready", "settings-saved-voices-empty", "notes-voice-recognised",
    ]

    public static var committedScenarios: [Scenario] {
        let all = allScenarios
        return committedNames.compactMap { name in all.first { $0.name == name } }
    }

    public static var localModelsScenarios: [Scenario] {
        ["missing", "downloading", "paused", "error", "ready", "stale", "sensevoice"].map { name in
            Scenario(name: "models-" + name) {
                var state = LocalModelsState()
                state.correctionMode = "managed"
                state.correctionEnabled = true
                state.options = [
                    LocalModelOption(id: "v2", kind: .speech, title: "Parakeet TDT v2 · English", repository: "mlx-community/parakeet-tdt-0.6b-v2", revision: "8ae155301e", sizeBytes: 2_472_000_000, details: "English · existing default", license: "cc-by-4.0", ready: name == "ready", active: true, engine: "mlx"),
                    LocalModelOption(id: "v3", kind: .speech, title: "Parakeet TDT v3 · Multilingual", repository: "mlx-community/parakeet-tdt-0.6b-v3", revision: "ed2b7e8c15", sizeBytes: 2_509_000_000, details: "25 languages", engine: "mlx"),
                    LocalModelOption(id: "qwen", kind: .cleanup, title: "Qwen3 4B Instruct · 4-bit", repository: "mlx-community/Qwen3-4B-Instruct-2507-4bit", revision: "50d427756c", sizeBytes: 2_263_000_000, details: "Local text correction", ready: name == "ready", active: true),
                ]
                state.choices = [.speech: "v2", .cleanup: "qwen"]
                state.activeModels = ["speech": "v2", "cleanup": "qwen"]
                state.message = "Choose and download models, then start your local server."
                for model in LocalModel.allCases {
                    state.models[model]?.phase = switch name {
                    case "downloading": "downloading"
                    case "paused": "cancelled"
                    case "error": "error"
                    case "ready": "complete"
                    default: "missing"
                    }
                    state.models[model]?.completed = 850_000_000
                    state.models[model]?.total = 2_470_000_000
                    state.models[model]?.message = "Connection interrupted. Retry to continue."
                }
                if name == "sensevoice" {
                    state.options.append(LocalModelOption(id: "sensevoice-small", kind: .speech, title: "SenseVoice Small · 中文 / 粵語 / English", repository: "csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17", revision: "2365baeacb", sizeBytes: 938_576_997, details: "Mandarin, Cantonese, English and mixed speech · CPU · adds a 12 MB runtime on first download", license: "FunASR model license", ready: true, engine: "sensevoice"))
                    state.choices[.speech] = "sensevoice-small"; state.activeModels["speech"] = "sensevoice-small"
                    state.models[.speech]?.phase = "complete"; state.models[.cleanup]?.phase = "complete"
                    state.restartRequired = true
                    state.message = "Selection saved. Apply and restart the server when you’re ready."
                }
                if name == "stale" { state.finish("download", model: .speech, code: 2, sawEvent: false, interrupted: false) }
                if name == "ready" {
                    state.serverRunning = true
                    state.message = "Server running · Ready to dictate"
                }
                let view = LocalModelsView()
                view.apply(state)
                return view
            }
        }
    }

    // MARK: Live Notes

    /// An invented meeting: an agenda the user typed, three structured segments settled, two more in the AI tail,
    /// a live partial.
    static func demoNotes(gap: Bool = false, short: Bool = false, typed: Bool = true, captured: Bool = false) -> NotesDocument {
        var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 1_792_504_980))
        if captured { d.beginCapture(at: d.startedAt, offset: 0) }
        if typed { d.userEdit(NSRange(location: 0, length: 0), "## Agenda\n- Lantern kickoff\n- Budget check-in\n- [x] Share the doc with Maya\n") }
        let said: [(TimeInterval, String, String)] = [
            (12, "okay so we're kicking off the lantern project today and the launch target moved to march third",
             "Okay, so we're kicking off the Lantern project today, and the launch target moved to March third."),
            (48, "maya will send the draft spec by friday and theo books the design review",
             "Maya will send the draft spec by Friday, and Theo books the design review."),
            (95, "on budget we decided to keep the vendor contract but we will not add new headcount this quarter",
             "On budget, we decided to keep the vendor contract, but we will not add new headcount this quarter."),
        ]
        for (i, s) in said.enumerated() { d.append(NotesSegment(id: i, offset: s.0, raw: s.1, text: s.2, corrected: true)) }
        let first = ["## Project kickoff", "- Launch target moved to **March 3**", "- [ ] Maya to send the draft spec by **Friday**",
                     "- [ ] Theo to book the design review", "", "## Budget", "- **Decision:** keep the vendor contract",
                     "- _No_ new headcount this quarter"].joined(separator: "\n")
        if let r = d.nextStructureRequest() { d.apply(NotesStructureResponse(markdown: first, structured: true), for: r) }
        d.freezeAll()
        if short { return d }
        if gap { d.append(.gap(id: 3, offset: 140, reason: "Server is busy")) }
        d.append(NotesSegment(id: 4, offset: 151, raw: "open question is who owns qa for the beta",
                              text: "open question is who owns qa for the beta", keptOriginal: gap))
        d.append(NotesSegment(id: 5, offset: 176, raw: "the beta itself should start in the second week of april",
                              text: "The beta itself should start in the second week of April.", corrected: true))
        let open = ["## Beta", "- **Question:** who owns QA for the beta?", "- Beta starts in the second week of **April**"]
            .joined(separator: "\n")
        if let r = d.nextStructureRequest() { d.apply(NotesStructureResponse(markdown: open, structured: true), for: r) }
        d.append(NotesSegment(id: 6, offset: 201, raw: "and marketing wants a teaser", text: "And marketing wants a teaser."))
        d.livePartial = "and we still need the onboarding emails for the first"
        return d
    }

    /// The same meeting with speaker labels: three people, a backchannel, a turn across a segment boundary, an
    /// approximate segment (no word timings).
    static func demoSpeakers() -> NotesDocument {
        var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 1_792_504_980))
        typealias T = SpeakerAttribution.Turn
        let said: [(TimeInterval, String, [T])] = [
            (12, "okay so we're kicking off the lantern project today and the launch target moved to march third yeah march third", [
                T(slot: 2, start: 12, text: "Okay, so we're kicking off the Lantern project today, and the launch target moved to March third.",
                  raw: "okay so we're kicking off the lantern project today and the launch target moved to march third"),
                T(slot: 0, start: 19.4, text: "Yeah, March third.", raw: "yeah march third"),
            ]),
            (48, "maya will send the draft spec by friday and theo books the design review", [
                T(slot: 0, start: 48, text: "Maya will send the draft spec by Friday, and Theo books the design review.",
                  raw: "maya will send the draft spec by friday and theo books the design review"),
            ]),
            (95, "on budget we decided to keep the vendor contract but no new headcount this quarter agreed", [
                T(slot: 3, start: 95, text: "On budget, we decided to keep the vendor contract, but no new headcount this quarter.",
                  raw: "on budget we decided to keep the vendor contract but no new headcount this quarter"),
                T(slot: 2, start: 103.2, text: "Agreed.", raw: "agreed"),
            ]),
            (151, "open question is who owns qa for the beta", [
                T(slot: 0, start: 151, text: "Open question is who owns QA for the beta.", raw: "open question is who owns qa for the beta",
                  approximate: true),
            ]),
        ]
        for (i, s) in said.enumerated() {
            d.append(NotesSegment(id: i, offset: s.0, raw: s.1, text: s.2.map(\.text).joined(separator: " "), corrected: true))
            d.attachSpeakers(s.2, toSegment: i)
        }
        d.livePartial = "the beta itself should start in the second week"
        return d
    }

    /// The speaker demo as a call recording (#211): the microphone's person is "You", the call's are Person N.
    static func demoCall() -> NotesDocument {
        var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 1_792_504_980))
        for var segment in demoSpeakers().segments {
            let turns = segment.turns ?? []
            segment.turns = nil
            d.append(segment)
            let slots = turns.map { t -> SpeakerAttribution.Turn in
                let slot = t.person == 1 ? SpeakerRoster.youSlot : t.person
                return SpeakerAttribution.Turn(slot: slot, start: t.start, text: t.text, raw: t.raw, approximate: t.approximate)
            }
            d.attachSpeakers(slots, toSegment: segment.id)
        }
        d.livePartial = "the beta itself should start in the second week"
        return d
    }

    static let demoCallApps = [
        CallAudioApp(bundleID: "us.zoom.xos", name: "zoom.us"), CallAudioApp(bundleID: "com.apple.FaceTime", name: "FaceTime"),
        CallAudioApp(bundleID: "com.google.Chrome", name: "Google Chrome"), CallAudioApp(bundleID: "com.tinyspeck.slackmacgap", name: "Slack"),
    ]

    /// The Sources popover's content on its own (a popover cannot be drawn offscreen).
    static func sources(_ name: String, _ configure: @escaping (NotesModel) -> Void) -> Scenario {
        Scenario(name: "notes-sources-\(name)") {
            let model = NotesModel()
            model.callAudioAvailable = true
            model.callApps = demoCallApps
            model.state = .idle
            configure(model)
            return NSHostingView(rootView: SourcesPanel(model: model))
        }
    }

    /// Forty minutes into a long session: segments that run on without a pause read as one paragraph, sections
    /// remember when they were said, and 1:30 of speech waits for the notes.
    static func demoLong() -> NotesDocument {
        var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 1_792_504_980))
        let said: [(TimeInterval, String, TimeInterval?)] = [
            (2412, "So the launch target moved to March third, which gives us about six weeks for the beta, and", nil),
            (2457, "most of that goes to the onboarding flow. Maya will send the draft spec by Friday.", 0.3),
            (2502, "Theo books the design review for the week after, once the spec is in.", 0.2),
            (2547, "On budget, we decided to keep the vendor contract, but we will not add new headcount this quarter.", 3.1),
            (2592, "Open question is who owns QA for the beta, and whether", nil),
            (2637, "support should join the first two weeks of it.", 0.4),
        ]
        func add(_ i: Int) {
            var s = NotesSegment(id: i, offset: said[i].0, raw: said[i].1.lowercased(), text: said[i].1, corrected: true)
            s.end = said[i].0 + 45
            s.pauseBefore = said[i].2
            d.append(s)
        }
        for i in 0..<3 { add(i) }
        let first = ["## Launch plan", "- Launch target moved to **March 3**: about six weeks of beta",
                     "- [ ] Maya to send the draft spec by **Friday**", "- [ ] Theo to book the design review"].joined(separator: "\n")
        if let r = d.nextStructureRequest() { d.apply(NotesStructureResponse(markdown: first, structured: true), for: r) }
        d.freezeAll()
        add(3)
        let budget = ["## Budget", "- **Decision:** keep the vendor contract", "- _No_ new headcount this quarter"].joined(separator: "\n")
        if let r = d.nextStructureRequest() { d.apply(NotesStructureResponse(markdown: budget, structured: true), for: r) }
        d.freezeAll()
        for i in 4..<6 { add(i) }
        d.livePartial = "and the onboarding emails for the first"
        return d
    }

    /// The demo after a reorganize: the agenda and the kickoff merged, tasks collected at the end.
    static func reorganizedNotes() -> NotesDocument {
        var d = demoNotes()
        let md = ["## Agenda", "- Lantern kickoff", "- Budget check-in", "", "## Project kickoff", "- Launch target moved to **March 3**",
                  "", "## Budget", "- **Decision:** keep the vendor contract", "- _No_ new headcount this quarter", "",
                  "## Beta", "- Beta starts in the second week of **April**", "- **Question:** who owns QA for the beta?", "",
                  "## Action items", "- [x] Share the doc with Maya", "- [ ] Maya to send the draft spec by **Friday**",
                  "- [ ] Theo to book the design review"].joined(separator: "\n")
        if let r = d.reorganizeRequest(final: false, manual: true) {
            d.applyReorganize(NotesReorganizeResponse(markdown: md, reorganized: true, changed: true), for: r)
        }
        return d
    }

    /// One organize that regrouped the demo notes, as the review sheet and the chip show it.
    static func demoSnapshots() -> NotesSnapshots {
        let before = demoNotes().text
        let after = reorganizedNotes().text
        var snapshots = NotesSnapshots()
        if let change = NotesDocument.diff(before, after, kind: .reorganize) {
            snapshots.record([change], from: before, result: after, at: Date(timeIntervalSince1970: 1_700_000_000))
        }
        return snapshots
    }

    /// The snapshot clock: an hour and a half after the demo meeting started (2026-10-20 14:03 UTC), in UTC.
    nonisolated static let notesNow = Date(timeIntervalSince1970: 1_792_504_980 + 5400)
    static var notesCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// An invented library around the demo meeting: today, yesterday, this week, this month and two earlier months.
    static func demoLibrary(current: NotesDocument?, recording: Bool = false) -> [NotesLibraryEntry] {
        func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }
        func at(_ hoursAgo: Double) -> Date { notesNow.addingTimeInterval(-hoursAgo * 3600) }
        var list = [
            NotesLibraryEntry(id: id(2), title: "Design review prep", snippet: "Walk through the onboarding flow first, then the empty states. Theo wants the copy deck before Thursday.",
                              openTodos: 1, createdAt: at(4), updatedAt: at(3.2), duration: 0),
            NotesLibraryEntry(id: id(3), title: "1:1 with Theo", snippet: "Career goals for next half: own the beta, mentor the new designer. Follow up on the conference budget.",
                              openTodos: 2, createdAt: at(27), updatedAt: at(26), duration: 24 * 60, audioBytes: 2_100_000),
            NotesLibraryEntry(id: id(4), title: "Grocery run ideas", snippet: "Lemons, good olive oil, the bread from the place on Fourth, something for Saturday.",
                              openTodos: 3, createdAt: at(80), updatedAt: at(76)),
            NotesLibraryEntry(id: id(5), title: "Quarterly planning", snippet: "Three bets for Q1: the beta, the Android notes library, and a faster first run. Headcount stays flat.",
                              openTodos: 0, createdAt: at(300), updatedAt: at(298), duration: 52 * 60, recovered: true),
            NotesLibraryEntry(id: id(6), title: "Podcast notes: retrieval", snippet: "Chunk size matters less than the reranker. Try the hybrid index on the support corpus.",
                              createdAt: at(960), updatedAt: at(958), duration: 65 * 60, audioBytes: 9_400_000),
            NotesLibraryEntry(id: id(7), title: "Vendor call", snippet: "Renewal at the same price if we sign before the end of the month. Ask legal about the data clause.",
                              openTodos: 1, createdAt: at(1700), updatedAt: at(1690), duration: 31 * 60),
        ]
        if let current {
            list.insert(NotesLibraryEntry(id: current.id, title: current.title, snippet: current.snippet(), openTodos: current.openTodoCount(),
                                          createdAt: current.createdAt, updatedAt: at(0.4), duration: 192, audioBytes: 640_000,
                                          recording: recording), at: 0)
        }
        return list
    }

    /// A search result with every case-insensitive match of `query` in `snippet` highlighted.
    static func demoResult(_ entry: NotesLibraryEntry, snippet: String, query: String) -> NotesSearchResult {
        var matches: [NSRange] = []
        var cursor = snippet.startIndex
        while let r = snippet.range(of: query, options: .caseInsensitive, range: cursor..<snippet.endIndex) {
            matches.append(NSRange(r, in: snippet))
            cursor = r.upperBound
        }
        return NotesSearchResult(entry: entry, snippet: snippet, matches: matches)
    }

    /// The demo meeting with a user title, as a library note: a finished capture, then (with `continued`) a second
    /// one the next morning after Continue recording.
    static func demoNote(continued: Bool = false) -> NotesDocument {
        var d = demoNotes(short: continued, captured: true)
        d.rename("Lantern kickoff", at: Date(timeIntervalSince1970: 1_792_504_980))
        guard continued else { return d }
        d.beginCapture(at: Date(timeIntervalSince1970: 1_792_504_980 + 19 * 3600 + 1680), offset: 120)
        d.append(NotesSegment(id: 3, offset: 121, raw: "picking this up again maya sent the spec last night",
                              text: "Picking this up again: Maya sent the spec last night.", corrected: true))
        d.append(NotesSegment(id: 4, offset: 139, raw: "theo has the design review on thursday at two",
                              text: "Theo has the design review on Thursday at two.", corrected: true))
        let more = ["## Follow-up", "- Maya sent the draft spec", "- Design review **Thursday, 2 PM**"].joined(separator: "\n")
        if let r = d.nextStructureRequest() { d.apply(NotesStructureResponse(markdown: more, structured: true), for: r) }
        d.freezeAll()
        return d
    }

    /// A live session's own Notes window, drawn offscreen (the call selftest's `--snapshot`).
    public static func notesScenario(_ name: String, model: NotesModel, library: NotesLibraryModel) -> Scenario {
        Scenario(name: name, window: { notesWindow(model, library) })
    }

    /// The Notes window as it is on screen, in a window that is never shown: the toolbar, sidebar and inspector are
    /// window chrome, which only a window draws.
    static func notesWindow(_ model: NotesModel, _ library: NotesLibraryModel, size: CGSize = CGSize(width: 1000, height: 620)) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbarStyle = .unified
        library.windowResized(size)
        window.contentViewController = NSHostingController(rootView: NotesView(model: model, library: library))
        window.setContentSize(size)
        return window
    }

    /// A live session's Notes window (the selftest's `--snapshot`): what the real window shows after a recording.
    public static func notesWindow(_ session: NotesSession, name: String, inspector: Bool = true) -> Scenario {
        Scenario(name: name, window: {
            if inspector { session.window.showsInspector = true }
            return notesWindow(session.model, session.window, size: CGSize(width: 1200, height: 720))
        })
    }

    /// A Notes window scenario: the demo meeting open in a populated library, recording, 3:12 in.
    static func notes(_ name: String, size: CGSize = CGSize(width: 1000, height: 620),
                      _ configure: @escaping (NotesModel, NotesLibraryModel) -> Void) -> Scenario {
        Scenario(name: "notes-\(name)", window: {
            let model = NotesModel()
            model.dictationKey = "⌥"
            model.state = .recording
            model.libraryEnabled = true
            model.privacyLine = NotesModel.libraryPrivacy
            model.privacyHelp = NotesModel.libraryPrivacyHelp
            var d = demoNotes()
            d.rename("Lantern kickoff", at: Date(timeIntervalSince1970: 1_792_504_980))
            model.document = d
            model.elapsed = 192
            model.level = 0.55
            model.ripplePhase = 0.35
            model.canManageModels = true
            model.structureEnabled = true
            let library = NotesLibraryModel()
            library.now = { notesNow }
            library.calendar = notesCalendar
            library.notes = demoLibrary(current: d, recording: true)
            library.recordingID = d.id
            library.selection = .note(d.id)
            configure(model, library)
            if !model.state.isActive, library.recordingID == model.document.id { library.recordingID = nil }
            return notesWindow(model, library, size: size)
        })
    }

    /// The Name speakers sheet over the speaker demo (three people, the notes naming Person 2 twice, audio kept so each
    /// has a ▶). `configure` edits the draft and picks the row whose suggestions show.
    @MainActor
    static func nameSpeakersSheet(voices: Bool = false, _ configure: (inout NameSpeakersDraft, inout Int?) -> Void) -> NSView {
        let model = NotesModel()
        var d = demoSpeakers()
        d.livePartial = ""
        d.userEdit(NSRange(location: 0, length: 0), "## Lantern kickoff\n- Launch target moved to **March 3** (**Person 2** confirmed)\n- [ ] **Person 2** to send the draft spec by **Friday**\n")
        model.document = d
        model.state = .stopped
        model.speakerLabels = true; model.speakerModel = .ready
        model.keptAudio = Dictionary(uniqueKeysWithValues: (0..<4).map { ($0, URL(fileURLWithPath: "/dev/null/\($0).m4a")) })
        if voices {
            model.voices = SpeakerVoiceState(enabled: true)
            model.voices.saved = ["Maya Chen", "Theo"]
            model.voices.canRemember = [1, 2]
            model.voices.seconds = [1: 41, 2: 28, 3: 9]
        }
        let library = NotesLibraryModel()
        library.notes = demoLibrary(current: d, recording: false)
        if let i = library.notes.firstIndex(where: { $0.id != d.id }) { library.notes[i].speakerNames = ["Maya", "Akshay"] }
        var draft = NameSpeakersDraft(d), suggesting: Int?
        configure(&draft, &suggesting)
        let state = NameSpeakersState(d, draft: draft, suggesting: suggesting)
        model.nameSpeakers = state
        return NSHostingView(rootView: NameSpeakersSheet(model: model, state: state, library: library))
    }

    /// The demo meeting with a gap, re-transcribed with Parakeet v3 (#287): two segments reworded, the gap filled, the
    /// replaced words kept as the previous transcript.
    static func demoRetranscribed() -> NotesDocument {
        var d = demoNotes(gap: true, captured: true)
        d.rename("Lantern kickoff", at: Date(timeIntervalSince1970: 1_792_504_980))
        d.livePartial = ""
        let v3 = "parakeet-mlx:parakeet-v3"
        d.applyRetranscription([
            NotesRetranscribedSegment(segment: 0, raw: "okay so we're kicking off the lantern project today the launch target moved to march third",
                                      text: "Okay, so we're kicking off the Lantern project today. The launch target moved to March 3.",
                                      corrected: true, clipOffset: 12, engine: v3),
            NotesRetranscribedSegment(segment: 3, raw: "theo asked whether support joins the beta",
                                      text: "Theo asked whether support joins the beta.", corrected: true, clipOffset: 140, engine: v3),
            NotesRetranscribedSegment(segment: 4, raw: "open question who owns qa for the beta",
                                      text: "Open question: who owns QA for the beta?", corrected: true, clipOffset: 151, engine: v3),
        ], at: notesNow)
        return d
    }

    /// The re-transcribe consent sheet over the demo meeting (#287 §2.2).
    static func retranscribeSheet(_ configure: (inout NotesRetranscribeOffer) -> Void = { _ in }) -> NSView {
        var offer = NotesRetranscribeOffer(note: UUID(), title: "Weekly sync", clips: 40, audio: 490, segments: 43, withoutAudio: 3,
                                           local: true, model: "parakeet-mlx:parakeet-v3", before: "parakeet-mlx:tdt-0.6b-v2")
        configure(&offer)
        let library = NotesLibraryModel()
        library.retranscribeOffer = offer
        return NSHostingView(rootView: RetranscribeSheet(library: library, offer: offer))
    }

    /// The demo meeting, finished and saved: the library's ordinary state.
    static func finished(_ model: NotesModel, _ library: NotesLibraryModel, continued: Bool = false) {
        model.state = .stopped
        let d = demoNote(continued: continued)
        model.document = d
        model.elapsed = continued ? 148 : 192
        library.recordingID = nil
        library.notes = demoLibrary(current: d)
        library.selection = .note(d.id)
    }

    public static var notesScenarios: [Scenario] {
        [
            notes("empty") { model, library in
                model.state = .idle; model.document = NotesDocument(); model.elapsed = 0
                library.notes = []; library.recordingID = nil; library.selection = .note(model.document.id)
            },
            notes("library") { model, library in finished(model, library) },
            notes("recording") { model, library in
                // Browsing another note while the demo meeting records: the recording stays pinned and in the toolbar.
                let other = NotesModel()
                var d = NotesDocument(startedAt: notesNow.addingTimeInterval(-4 * 3600))
                d.userEdit(NSRange(location: 0, length: 0), "## Flow\n- Onboarding first, then the empty states\n- Copy deck to Theo before **Thursday**\n\n## Open\n- [ ] Decide on the illustration style\n- **Question:** do we keep the three-step tour?\n")
                d.rename("Design review prep", at: notesNow.addingTimeInterval(-3.2 * 3600))
                other.document = d
                other.state = .stopped
                other.libraryEnabled = true
                other.reorganizeStatus = .unavailable(.unsupported)
                library.browsed = other
                library.selection = .note(library.notes[1].id)
            },
            notes("recording-live") { _, _ in },
            notes("search") { model, library in
                finished(model, library)
                library.query = "beta"
                let notes = library.notes
                library.results = [
                    demoResult(notes[0], snippet: "Open question is who owns QA for the beta. Beta starts in the second week of April.", query: "beta"),
                    demoResult(notes[2], snippet: "Career goals for next half: own the beta, mentor the new designer.", query: "beta"),
                    demoResult(notes[4], snippet: "Three bets for Q1: the beta, the Android notes library, and a faster first run.", query: "beta"),
                ]
            },
            notes("no-results") { model, library in
                finished(model, library)
                library.query = "kangaroo"
                library.results = []
            },
            notes("deleted") { model, library in
                finished(model, library)
                library.selection = .recentlyDeleted
                func at(_ days: Double) -> Date { notesNow.addingTimeInterval(-days * 86400) }
                library.deleted = [
                    NotesLibraryEntry(id: UUID(), title: "Standup scratch", snippet: "Blocked on the staging deploy; pairing with Sam after lunch.",
                                      createdAt: at(3), updatedAt: at(2), deletedAt: at(2), duration: 6 * 60),
                    NotesLibraryEntry(id: UUID(), title: "Old roadmap draft", snippet: "Superseded by Quarterly planning.",
                                      createdAt: at(40), updatedAt: at(12), deletedAt: at(12)),
                    NotesLibraryEntry(id: UUID(), title: "Test recording", snippet: "Testing, one two, testing.",
                                      createdAt: at(26), updatedAt: at(26), deletedAt: at(26), duration: 14),
                ]
            },
            notes("continued") { model, library in
                finished(model, library, continued: true)
                library.showsInspector = true
            },
            notes("inspector-playing") { model, library in
                finished(model, library)
                model.document.livePartial = ""
                library.showsInspector = true
                model.keptAudio = Dictionary(uniqueKeysWithValues: (0..<7).map { ($0, URL(fileURLWithPath: "/dev/null/\($0).m4a")) })
                let rows = model.transcriptRows
                if rows.count > 1 { library.player.showPlaying(note: model.document.id, paragraph: rows[1].id, segment: rows[1].paragraph.segments.lowerBound) }
            },
            notes("editing") { model, _ in model.structuring = .running },
            notes("show-markdown") { model, library in finished(model, library); library.showMarkdown = true },
            notes("reorganized") { model, _ in
                var d = reorganizedNotes()
                d.rename("Lantern kickoff", at: Date(timeIntervalSince1970: 1_792_504_980))
                model.document = d
                model.reorganizeStatus = .applied(at: 1)
                model.snapshots = demoSnapshots()
            },
            notes("reorganizing") { model, _ in model.reorganizeStatus = .running },
            notes("voice-edit-listening") { model, _ in
                model.voiceEditAvailable = true
                model.canVoiceEdit = true
                model.voiceEdit = .listening(heard: "remove the bit about the budget")
            },
            notes("voice-edited") { model, _ in
                model.voiceEditAvailable = true
                model.canVoiceEdit = true
                model.voiceEdit = .done(.applied, at: 1)
            },
            notes("organize-partial") { model, library in
                finished(model, library)
                model.reorganizeStatus = .organized(failed: 1, reason: "rejected: novel_name")
            },
            notes("keep-saving-stopped") { model, library in
                finished(model, library)
                model.keepSaving = .stopped(KeepSavingStatus.moved)
            },
            notes("offline") { model, _ in model.connection = .offline(kept: 252) },
            notes("mic-silent") { model, _ in model.micNotice = .silent },
            notes("paused") { model, _ in model.state = .paused; model.elapsed = 754; model.document.livePartial = "" },
            notes("transcript") { model, library in model.document = demoNotes(gap: true); library.showsInspector = true },
            notes("recording-call") { model, library in
                model.callAudioAvailable = true
                model.sources = NotesSources(callAudio: true, app: demoCallApps[0])
                model.capturingCall = true
                model.callLevel = 0.6
                model.document = demoCall(); model.speakerLabels = true; model.speakerModel = .ready
                library.showsInspector = true
            },
            notes("call-silent") { model, _ in
                model.callAudioAvailable = true
                model.sources = NotesSources(callAudio: true)
                model.capturingCall = true
                model.callNotice = .silent
            },
            // The toolbar's Recording capsule with both ripples (the window's toolbar is overflowed at snapshot width).
            Scenario(name: "notes-record-call") {
                let model = NotesModel()
                model.state = .recording
                model.document = demoCall()
                model.elapsed = 192
                model.level = 0.55
                model.callLevel = 0.8
                model.ripplePhase = 0.35
                model.capturingCall = true
                model.sources = NotesSources(callAudio: true, app: demoCallApps[0])
                return NSHostingView(rootView: SnapshotBackdrop { RecordControl(model: model, library: NotesLibraryModel()) })
            },
            sources("mic") { _ in },
            sources("call") { $0.sources = NotesSources(callAudio: true, app: demoCallApps[0]) },
            sources("explain") { $0.explainingCallAudio = NotesSources(callAudio: true) },
            sources("locked") { $0.state = .recording; $0.sources = NotesSources(callAudio: true) },
            notes("transcript-speakers") { model, library in
                model.document = demoSpeakers(); model.speakerLabels = true; model.speakerModel = .ready
                library.showsInspector = true
            },
            // Person 2 renamed to Maya: every turn of theirs follows, and the banner offers the notes' two mentions.
            notes("transcript-speakers-renamed") { model, library in
                var d = demoSpeakers()
                d.livePartial = ""
                d.userEdit(NSRange(location: 0, length: 0), "## Lantern kickoff\n- Launch target moved to **March 3** (**Person 2** confirmed)\n- [ ] **Person 2** to send the draft spec by **Friday**\n")
                d.renameSpeaker(2, to: "Maya")
                model.document = d
                model.state = .stopped
                model.speakerLabels = true; model.speakerModel = .ready
                model.speakerBanner = SpeakerBanner(document: d.id, kind: .offerReplace(old: "Person 2", new: "Maya", count: 2))
                library.showsInspector = true
            },
            Scenario(name: "notes-voice-recognised") {
                let model = NotesModel()
                var document = demoSpeakers()
                document.livePartial = ""
                document.renameSpeaker(2, to: "Maya")
                model.document = document; model.state = .stopped; model.elapsed = 192
                model.speakerLabels = true; model.speakerModel = .ready
                model.voices = SpeakerVoiceState(enabled: true)
                model.voices.linked = [2: "Maya"]; model.voices.recognised = [2]
                model.voices.canRemember = [2]; model.voices.seconds = [2: 26]
                return NSHostingView(rootView: NotesInspector(model: model, library: NotesLibraryModel()).frame(width: 390, height: 550))
            },
            // After Stop, nobody named yet: the quiet "Who was speaking?" line over the note.
            notes("name-speakers-line") { model, library in
                var d = demoSpeakers()
                d.livePartial = ""
                d.userEdit(NSRange(location: 0, length: 0), "## Lantern kickoff\n- Launch target moved to **March 3** (**Person 2** confirmed)\n- [ ] **Person 2** to send the draft spec by **Friday**\n")
                model.document = d
                model.state = .stopped
                model.speakerLabels = true; model.speakerModel = .ready
                library.showsInspector = true
            },
            // The Name speakers sheet over that note: two named, one voice marked as the same person.
            Scenario(name: "notes-name-speakers-sheet") { nameSpeakersSheet { draft, _ in
                draft.rows[0].name = "Theo"
                draft.rows[1].name = "Maya"
                draft.rows[2].mergeInto = 1
            } },
            // Typing in a field: saved voices first, then names from recent notes.
            Scenario(name: "notes-name-speakers-suggest") { nameSpeakersSheet(voices: true) { draft, suggesting in
                draft.rows[0].name = "Theo"
                draft.rows[1].name = "M"
                suggesting = 2
            } },
            // Where Chirp can remember voices: "Remember voice", ticked, for those with enough speech.
            Scenario(name: "notes-name-speakers-remember") { nameSpeakersSheet(voices: true) { draft, _ in
                draft.rows[0].name = "Theo"
                draft.rows[1].name = "Maya"
                draft.rows[1].remember = false
            } },
            // Labels are on by default: the model is fetched in the background, with one status line (never a prompt).
            notes("speaker-model-downloading") { model, _ in
                model.speakerLabels = true; model.speakerModelSize = "106 MB"; model.speakerModel = .downloading(0.4)
            },
            notes("speaker-model-failed") { model, _ in
                model.speakerLabels = true; model.speakerModelSize = "106 MB"; model.speakerModel = .failed("the download failed")
            },
            notes("structuring-off-editable") { model, _ in
                var d = NotesDocument(startedAt: Date(timeIntervalSince1970: 1_792_504_980))
                d.userEdit(NSRange(location: 0, length: 0), "## My notes\n- Lantern launch moved to **March 3**\n- Ask Theo about the design review\n- [ ] ")
                for s in demoNotes().segments { d.append(s) }
                d.livePartial = "and we still need the onboarding emails"
                model.document = d
                model.structuring = .off(.correctionOff)
                model.reorganizeStatus = .unavailable(.correctionOff)
            },
            notes("structure-failed") { model, _ in
                model.structuring = .failed("timeout")
                model.reorganizeStatus = .failed("rejected")
                model.structuringHost = "llm.example.com"
                model.debugRetention = true
            },
            notes("long-lag") { model, _ in model.document = demoLong(); model.elapsed = 2690 },
            notes("long-run") { model, _ in model.document = demoLong(); model.elapsed = 7262 },
            notes("error") { model, _ in model.state = .error("Notes stopped: Server rejected the token") },
            notes("new-note") { model, library in
                model.state = .idle; model.document = NotesDocument(); model.elapsed = 0
                library.recordingID = nil; library.selection = .note(model.document.id)
                library.notes = demoLibrary(current: nil)
            },
            notes("toast") { model, library in
                finished(model, library)
                library.showToast(NotesLibraryText.deleted, undo: UUID())
            },
            Scenario(name: "notes-review-sheet") {
                let model = NotesModel()
                model.snapshots = demoSnapshots()
                model.review()
                return NSHostingView(rootView: OrganizeReviewSheet(model: model))
            },
            Scenario(name: "notes-review-confirm") {
                let model = NotesModel()
                model.snapshots = demoSnapshots()
                model.review()
                model.confirmingRestore = model.reviewing
                return NSHostingView(rootView: OrganizeReviewSheet(model: model))
            },
            notes("retranscribe-progress") { model, library in
                finished(model, library)
                var d = demoNotes(gap: true, captured: true)
                d.rename("Lantern kickoff", at: Date(timeIntervalSince1970: 1_792_504_980))
                d.livePartial = ""
                model.document = d
                library.notes = demoLibrary(current: d)
                library.selection = .note(d.id)
                library.showsInspector = true
                library.retranscribeAllowed = true
                model.keptAudio = Dictionary(uniqueKeysWithValues: (0..<7).map { ($0, URL(fileURLWithPath: "/dev/null/\($0).m4a")) })
                library.retranscribeRun = NotesRetranscribeRun(
                    note: d.id, progress: NotesRetranscribeProgress(done: 3, total: 7, audioDone: 104, audioTotal: 213), local: true)
            },
            notes("retranscribe-waiting") { model, library in
                finished(model, library)
                library.showsInspector = true
                library.retranscribeRun = NotesRetranscribeRun(
                    note: model.document.id, progress: NotesRetranscribeProgress(done: 3, total: 7, audioDone: 104, audioTotal: 213, waiting: true),
                    local: false)
            },
            notes("retranscribe-stopped") { model, library in
                finished(model, library)
                library.showsInspector = true
                library.retranscribeRun = NotesRetranscribeRun(
                    note: model.document.id, progress: NotesRetranscribeProgress(done: 3, total: 7, audioDone: 104, audioTotal: 213),
                    local: true, failure: NotesRetranscribeText.stopped(code: "busy", local: true), canApplyPartial: true)
            },
            notes("retranscribe-toast") { model, library in
                finished(model, library)
                let d = demoRetranscribed()
                model.document = d
                library.notes = demoLibrary(current: d)
                library.selection = .note(d.id)
                library.showsInspector = true
                library.retranscribeAllowed = true
                model.keptAudio = Dictionary(uniqueKeysWithValues: (0..<7).map { ($0, URL(fileURLWithPath: "/dev/null/\($0).m4a")) })
                library.showToast(NotesRetranscribeText.finished(updated: 3, of: 4), action: .transcript(d.id))
            },
            notes("retranscribe-gap") { model, library in
                finished(model, library)
                var d = demoNotes(gap: true, captured: true)
                d.rename("Lantern kickoff", at: Date(timeIntervalSince1970: 1_792_504_980))
                d.livePartial = ""
                model.document = d
                library.notes = demoLibrary(current: d)
                library.selection = .note(d.id)
                library.showsInspector = true
                library.retranscribeAllowed = true
                model.keptAudio = Dictionary(uniqueKeysWithValues: (0..<7).map { ($0, URL(fileURLWithPath: "/dev/null/\($0).m4a")) })
            },
            Scenario(name: "notes-retranscribe-sheet") { retranscribeSheet() },
            Scenario(name: "notes-retranscribe-sheet-debug") {
                retranscribeSheet {
                    $0.local = false; $0.debugRetention = true; $0.cleanupHost = "llm.example.com"
                    $0.rebuildAvailable = false; $0.canChangeModel = false; $0.withoutAudio = 0
                }
            },
            Scenario(name: "notes-retranscribe-sheet-same") {
                retranscribeSheet { $0.before = $0.model; $0.rebuild = true; $0.withoutAudio = 0 }
            },
            Scenario(name: "notes-retranscribe-sheet-gap") {
                retranscribeSheet { $0.segment = 3; $0.clips = 1; $0.audio = 32 }
            },
            Scenario(name: "notes-retranscribe-sheet-update") { retranscribeSheet { $0.supported = false } },
            Scenario(name: "notes-retranscribe-changes") {
                let library = NotesLibraryModel()
                let changes = NotesTranscriptChanges(demoRetranscribed())
                library.transcriptChanges = changes
                return NSHostingView(rootView: TranscriptChangesSheet(library: library, changes: changes))
            },
            Scenario(name: "notes-tip") {
                NSHostingView(rootView: NotesTipView().background(Color(nsColor: .windowBackgroundColor)))
            },
        ]
    }

    /// Settings → Notes → Saved voices, the detail page (not the old sheet).
    static func savedVoicesWindow(_ value: VoiceProfilesState) -> NSView {
        var settings = SettingsState()
        settings.launch = .on
        settings.serverStatus = "parakeet-mlx:tdt-0.6b-v2"
        settings.about = AboutInfo(version: "0.1.0", build: "1")
        settings.voices = value
        let form = SettingsForm(settings, icon: appIcon, onNotices: {})
        form.voicesView.showsTitle = false
        form.voicesView.fitSettingsPage()
        form.voicesView.apply(value, locale: Locale(identifier: "en_US"), timeZone: TimeZone(secondsFromGMT: 0)!)
        let shell = SettingsShell(form: form, selected: .notes, flat: true)
        shell.showDetail(content: form.voicesView, title: "Saved voices", back: SettingsTab.notes.title)
        shell.layoutSubtreeIfNeeded()
        shell.contentHeight = max(SettingsShell.size.height, shell.openPageHeight + 28)
        return shell
    }

    public static var savedVoicesScenarios: [Scenario] {
        ["ready", "empty", "off", "unsupported", "failed"].map { state in
            Scenario(name: "settings-saved-voices-" + state) {
                var value = VoiceProfilesState()
                value.supported = state != "unsupported"
                value.enabled = state != "off"
                if ["ready", "off", "failed"].contains(state) {
                    let date = Date(timeIntervalSince1970: 1_791_849_600)
                    value.profiles = [
                        SavedVoice(id: "0123456789abcdef", name: "Maya", seconds: 46, created: date, updated: date.addingTimeInterval(8 * 86400)),
                        SavedVoice(id: "fedcba9876543210", name: "Theo", seconds: 31, created: date, updated: date),
                        SavedVoice(id: "0011223344556677", name: "Alex", seconds: 24, created: date, updated: date, compatible: false)
                    ]
                }
                if state == "failed" { value.error = "Couldn’t load saved voices. Try again." }
                return savedVoicesWindow(value)
            }
        }
    }

    public static var allScenarios: [Scenario] {
        // `CHIRP_SNAPSHOT_REVIEW=303 ChirpMac --render-snapshots <dir>` renders only the #303 text-size/geometry review
        // matrix (never part of the committed set).
        if ProcessInfo.processInfo.environment["CHIRP_SNAPSHOT_REVIEW"] == "303" { return modernUXScenarios }
        return hudScenarios + rippleScenarios + wordWaveScenarios + settingsScenarios + onboardingScenarios + menuScenarios
            + localModelsScenarios + notesScenarios + pairingScenarios + historyScenarios + savedVoicesScenarios
    }

    // MARK: rendering

    /// Renders `scenario` at 2x under `appearance` into PNG data.
    public static func png(_ scenario: Scenario, appearance name: NSAppearance.Name) -> Data? {
        let appearance = NSAppearance(named: name)!
        let app = NSApplication.shared
        let previous = app.appearance
        app.appearance = appearance
        defer { app.appearance = previous }
        // Native controls resolve and cache their accent while being created, before the first draw.
        var data: Data?
        appearance.performAsCurrentDrawingAppearance {
            // Eagerly loading the named asset registers the bundle accent before AppKit caches a system blue cell.
            _ = NSColor(named: "AccentColor", bundle: .main)?.usingColorSpace(.sRGB)
            data = png(scenario, appearance: appearance)
        }
        return data
    }

    private static func png(_ scenario: Scenario, appearance: NSAppearance) -> Data? {
        if let window = scenario.window { return windowPNG(window(), appearance: appearance) }
        let view = scenario.make()
        view.appearance = appearance
        let size = view.fittingSize
        guard size.width > 0, size.height > 0 else { return nil }
        view.setFrameSize(size)
        // An AppKit control tree has no window of its own; give Settings the opaque background a window has.
        let host = NSBox(frame: NSRect(origin: .zero, size: size))
        host.boxType = .custom
        host.borderWidth = 0
        host.contentViewMargins = .zero
        let isWindow = ["settings-", "onboarding-", "models-", "notes-", "pairing-"].contains { scenario.name.hasPrefix($0) }
        host.fillColor = isWindow ? .windowBackgroundColor : .clear
        host.appearance = appearance
        host.contentView = view
        host.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        // An NSTextView inside SwiftUI lays out lazily; make it draw offscreen.
        for textView in textViews(in: host) {
            if let tlm = textView.textLayoutManager { tlm.ensureLayout(for: tlm.documentRange) }
            textView.needsDisplay = true
        }
        view.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: host.bounds, to: rep) }
        return isWindow ? opaquePNG(rep) ?? rep.representation(using: .png, properties: [:]) : rep.representation(using: .png, properties: [:])
    }

    /// A window drawn from its frame view (title bar and toolbar included) without ever being ordered on screen.
    private static func windowPNG(_ window: NSWindow, appearance: NSAppearance) -> Data? {
        window.appearance = appearance
        guard let frame = window.contentView?.superview else { return nil }
        // The toolbar and the split view's columns settle over a few layout passes (never the run loop: a window that
        // is not on screen never finishes the display cycle's constraint passes).
        for _ in 0..<4 {
            window.layoutIfNeeded()
            frame.layoutSubtreeIfNeeded()
        }
        for textView in textViews(in: frame) {
            if let tlm = textView.textLayoutManager { tlm.ensureLayout(for: tlm.documentRange) }
            textView.needsDisplay = true
        }
        frame.layoutSubtreeIfNeeded()
        let size = frame.bounds.size
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        appearance.performAsCurrentDrawingAppearance { frame.cacheDisplay(in: frame.bounds, to: rep) }
        // A window that is never shown must not outlive its picture: left alive, its SwiftUI content keeps asking for
        // layout passes that never settle (AppKit then throws).
        window.contentViewController = nil
        window.toolbar = nil
        window.close()
        var backdrop = NSColor.windowBackgroundColor
        appearance.performAsCurrentDrawingAppearance { backdrop = NSColor.windowBackgroundColor.usingColorSpace(.deviceRGB) ?? .gray }
        return opaquePNG(rep, backdrop: backdrop.cgColor) ?? rep.representation(using: .png, properties: [:])
    }

    /// A window is opaque, so its PNG drops the alpha channel: the same pixels in a smaller file. (`cacheDisplay`
    /// only draws into a bitmap with alpha, so the pixels are copied into one that ignores it.)
    private static func opaquePNG(_ rep: NSBitmapImageRep, backdrop: CGColor? = nil) -> Data? {
        guard let image = rep.cgImage,
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        if let backdrop {
            // The window's rounded corners show this instead of black.
            context.setFillColor(backdrop)
            context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = NSMutableData()
        guard let opaque = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, opaque, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    private static func textViews(in view: NSView) -> [NSTextView] {
        (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews)
    }

    /// Writes `<scenario>-<appearance>.png` for every scenario and appearance; returns the files written.
    @discardableResult
    public static func render(to directory: URL, scenarios: [Scenario]? = nil) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [URL] = []
        for scenario in scenarios ?? allScenarios {
            for (label, appearance) in appearances {
                guard let data = png(scenario, appearance: appearance) else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "could not render \(scenario.name)"])
                }
                let url = directory.appendingPathComponent("\(scenario.name)-\(label).png")
                try data.write(to: url)
                written.append(url)
            }
        }
        return written
    }
}

/// A desktop-like backdrop colour so the translucent HUD and the menu read as they do on screen.
private struct SnapshotBackdrop<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        // Solid on purpose: a flat mid-tone keeps the PNGs small and is a fair contrast case for the material.
        content.padding(14).background(Color(red: 0.45, green: 0.52, blue: 0.66))
    }
}

/// The menu-bar menu drawn from its real views: the header (with its switch) and the rows are the same classes the
/// live `NSMenu` uses; only the menu's own chrome (background, border, separators) is approximated, since an `NSMenu`
/// cannot be drawn offscreen. `native` is a submenu, whose rows AppKit draws itself (checkmark column, no values).
final class MenuPanelView: NSView {
    private static let outer: CGFloat = 14
    private static let inner: CGFloat = 6
    private static let backdrop = NSColor(red: 0.45, green: 0.52, blue: 0.66, alpha: 1)

    init(header: MenuHeader?, entries: [MenuEntry], highlighting: String? = nil, native: Bool = false) {
        super.init(frame: .zero)
        var views: [NSView] = []
        var widest: CGFloat = header == nil ? 0 : MenuMetrics.minimumWidth
        if let header { views.append(MenuHeaderView(header: header)) }
        for entry in entries {
            if entry.isSeparator { views.append(MenuSeparatorView()); continue }
            if native {
                let row = SubmenuRowView(entry: entry)
                widest = max(widest, row.fittingWidth)
                views.append(row)
                continue
            }
            let row = MenuRowView(entry: entry)
            row.showsHighlight = entry.title == highlighting
            widest = max(widest, row.fittingWidth)
            views.append(row)
        }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        let pad = Self.outer + Self.inner
        let minimum = widthAnchor.constraint(equalToConstant: widest + 2 * Self.outer)
        NSLayoutConstraint.activate([
            minimum,
            stack.topAnchor.constraint(equalTo: topAnchor, constant: pad),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.outer),
            trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: Self.outer),
            bottomAnchor.constraint(equalTo: stack.bottomAnchor, constant: pad),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        Self.backdrop.setFill()
        bounds.fill()
        let panel = bounds.insetBy(dx: Self.outer, dy: Self.outer)
        let path = NSBezierPath(roundedRect: panel, xRadius: 12, yRadius: 12)
        NSColor.windowBackgroundColor.setFill()
        path.fill()
        NSColor.labelColor.withAlphaComponent(0.12).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// A submenu row as AppKit draws it: a checkmark column, the title, dimmed when it cannot be chosen.
private final class SubmenuRowView: NSView {
    private let entry: MenuEntry

    init(entry: MenuEntry) {
        self.entry = entry
        super.init(frame: NSRect(x: 0, y: 0, width: 10, height: MenuMetrics.rowHeight))
        autoresizingMask = [.width]
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: MenuMetrics.rowHeight) }

    var fittingWidth: CGFloat {
        let width = (entry.title as NSString).size(withAttributes: [.font: MenuStyle.font]).width
        let value = entry.value.map { ($0 as NSString).size(withAttributes: [.font: MenuStyle.font]).width + 28 } ?? 0
        return max(MenuMetrics.minimumWidth - 60, ceil(width + value) + 34 + MenuMetrics.trailing + 12)
    }

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor = entry.isEnabled ? .labelColor : .disabledControlTextColor
        let height = MenuStyle.font.boundingRectForFont.height
        let y = (bounds.height - height) / 2
        if entry.mark == .on {
            ("✓" as NSString).draw(at: NSPoint(x: 14, y: y), withAttributes: [.font: MenuStyle.font, .foregroundColor: color])
        }
        (entry.title as NSString).draw(at: NSPoint(x: 34, y: y), withAttributes: [.font: MenuStyle.font, .foregroundColor: color])
        if let value = entry.value {
            let size = (value as NSString).size(withAttributes: [.font: MenuStyle.font])
            (value as NSString).draw(at: NSPoint(x: bounds.width - MenuMetrics.trailing - size.width, y: y),
                                     withAttributes: [.font: MenuStyle.font, .foregroundColor: NSColor.secondaryLabelColor])
        }
    }
}

// Dedicated #303 review matrix. Kept separate from the canonical captures owned by other workers.
@MainActor extension Snapshots {
    static var modernUXScenarios: [Scenario] {
        var scenes: [Scenario] = []
        for large in [false, true] {
            let type = large ? "200" : "100"
            for narrow in [false, true] {
                let geometry = narrow ? "760" : "1120"
                for state in ["recording", "paused", "empty", "no-results", "error", "transcript", "deleted", "focus"] {
                    let base = notes("modern-\(state)-\(geometry)-\(type)",
                                     size: narrow ? NotesViewMetrics.minimumSize : NotesViewMetrics.defaultSize) { model, library in
                        if large { for _ in 0..<5 { library.textSize.increase() } }
                        if state == "paused" { model.state = .paused }
                        if state == "empty" {
                            model.state = .idle; model.document = NotesDocument(); library.notes = []; library.recordingID = nil
                            library.selection = .note(model.document.id)
                        }
                        if state == "no-results" { library.query = "invoice"; library.results = [] }
                        if state == "error" { model.state = .error("Chirp server offline — check the server connection.") }
                        if state == "transcript" { library.showsInspector = true }
                        // Offscreen windows are never key; the flag stands in for the list holding keyboard focus.
                        if state == "focus" { model.state = .stopped; library.recordingID = nil; library.sidebarFocused = true }
                        if state == "deleted" {
                            model.state = .stopped; library.recordingID = nil; library.selection = .recentlyDeleted
                            library.deleted = [NotesLibraryEntry(id: UUID(), title: "Standup scratch", snippet: "Blocked on the staging deploy; pairing with Sam after lunch.", createdAt: notesNow, updatedAt: notesNow, deletedAt: notesNow.addingTimeInterval(-2 * 86400), audioBytes: 640_000)]
                        }
                    }
                    scenes.append(base)
                }
            }
            scenes.append(Scenario(name: "history-modern-\(type)", window: {
                let model = HistoryModel()
                model.now = { historyNow }; model.calendar = utcCalendar; model.icon = { demoIcon($0) }
                model.show(demoHistory()); model.selection = demoHistory()[1].id
                let size = ChirpTextSize(factor: large ? 2 : 1)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: HistoryViewMetrics.defaultSize),
                                      styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false; window.toolbarStyle = .unified
                window.contentViewController = NSHostingController(rootView: HistoryView(model: model, textSize: size))
                window.setContentSize(HistoryViewMetrics.defaultSize)
                return window
            }))
            scenes.append(Scenario(name: "notes-modern-reader-\(type)") {
                let model = NotesModel()
                model.document = demoNotes()
                let view = NSHostingView(rootView: NotesFormattedReader(model: model) {}
                    .environment(\.chirpTextScale, large ? 2 : 1))
                view.frame = NSRect(x: 0, y: 0, width: 640, height: 520)
                return view
            })
        }
        return scenes
    }
}
