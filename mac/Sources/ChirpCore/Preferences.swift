import Foundation

/// The only persistent client state besides the token file: plain UserDefaults preferences. The defaults are
/// injectable so tests use a throwaway suite.
public final class Preferences: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        migrateLegacyInstructions()
    }

    public var serverURL: String {
        get { defaults.string(forKey: "serverURL") ?? ServerConfig.defaultURL.absoluteString }
        set { defaults.set(newValue, forKey: "serverURL") }
    }
    #if os(macOS)
    /// One of `KeyCombo.presets` (Right ⌥ by default) or a recorded shortcut that passed `HotKeyValidation`. Nothing
    /// stored means the user never chose one, so they follow the default; a stored choice (⌃⌥Space included) stays.
    public var hotkey: KeyCombo {
        get { KeyCombo.resolve(id: defaults.string(forKey: "hotkey")) }
        set { defaults.set(newValue.id, forKey: "hotkey") }
    }
    /// The "Open Notes" shortcut (⌃⌥⇧N by default): a recorded one that passed `HotKeyValidation`, else the default.
    public var openNotesHotkey: KeyCombo {
        get { KeyCombo.resolve(id: defaults.string(forKey: "openNotesHotkey"), fallback: .controlOptionShiftN) }
        set { defaults.set(newValue.id, forKey: "openNotesHotkey") }
    }
    /// Starts and stops Live Notes from any app (⌃⌥N by default).
    public var notesHotkey: KeyCombo {
        get { KeyCombo.resolve(id: defaults.string(forKey: "notesHotkey"), fallback: .controlOptionN) }
        set { defaults.set(newValue.id, forKey: "notesHotkey") }
    }
    /// "Use raw" during the 5 s after a cleaned insertion (⌃⌥Z by default).
    public var useRawHotkey: KeyCombo {
        get { KeyCombo.resolve(id: defaults.string(forKey: "useRawHotkey"), fallback: .controlOptionZ) }
        set { defaults.set(newValue.id, forKey: "useRawHotkey") }
    }
    /// Any of Chirp's shortcuts by role.
    public subscript(shortcut shortcut: ChirpShortcut) -> KeyCombo {
        get {
            switch shortcut {
            case .dictation: hotkey
            case .notes: notesHotkey
            case .openNotes: openNotesHotkey
            case .useRaw: useRawHotkey
            }
        }
        set {
            switch shortcut {
            case .dictation: hotkey = newValue
            case .notes: notesHotkey = newValue
            case .openNotes: openNotesHotkey = newValue
            case .useRaw: useRawHotkey = newValue
            }
        }
    }
    #endif
    /// Show Chirp in the Dock and ⌘-Tab even with no Notes window open. Off by default.
    public var alwaysShowInDock: Bool {
        get { defaults.bool(forKey: "alwaysShowInDock") }
        set { defaults.set(newValue, forKey: "alwaysShowInDock") }
    }
    /// Auto-stop (the default) or hold to talk. An unknown stored value falls back to auto-stop.
    public var activationMode: ActivationMode {
        get { defaults.string(forKey: "activationMode").flatMap(ActivationMode.init(rawValue:)) ?? .autoStop }
        set { defaults.set(newValue.rawValue, forKey: "activationMode") }
    }
    /// Auto-stop: seconds of quiet after speech that end a dictation (one of `AutoStopDetector.silenceChoices`).
    public var autoStopSilence: TimeInterval {
        get {
            guard let v = defaults.object(forKey: "autoStopSilence") as? Double, v.isFinite else { return AutoStopDetector.defaultSilence }
            return min(max(v, 0.5), 10)
        }
        set { defaults.set(newValue.isFinite ? min(max(newValue, 0.5), 10) : AutoStopDetector.defaultSilence, forKey: "autoStopSilence") }
    }
    /// Press Return after a successful insertion: off (the default), always, or only in apps with a Chat style rule.
    public var autoEnter: AutoEnter {
        get { defaults.string(forKey: "autoEnter").flatMap(AutoEnter.init(rawValue:)) ?? .off }
        set { defaults.set(newValue.rawValue, forKey: "autoEnter") }
    }
    /// Same opt-in name and default as the phones.
    public var spokenCommands: Bool {
        get { defaults.bool(forKey: "spokenCommands") }
        set { defaults.set(newValue, forKey: "spokenCommands") }
    }
    /// Clean-up (the server’s `correction` flag). Unset follows verified on-computer capability.
    public var correction: Bool {
        get { defaults.object(forKey: "correction") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "correction") }
    }
    /// An explicit choice survives upgrades. The automatic default never enables an external or unknown destination.
    public func permitsCorrection(health: Health?) -> Bool {
        guard let health, health.correctionAvailable else { return false }
        if let choice = defaults.object(forKey: "correction") as? Bool { return choice }
        return health.correctionLeavesMachine == false
    }
    /// Whether the HUD offers "Use raw" after a cleaned-up insertion. On by default.
    public var showRawAfterCleanup: Bool {
        get { defaults.object(forKey: "showRawAfterCleanup") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showRawAfterCleanup") }
    }
    /// Insert the raw transcript at once and swap in the cleaned text when it arrives (only for a verified AX
    /// insertion; otherwise the raw text stays). Off by default: the HUD shows the transition and inserts once.
    public var insertRawFirst: Bool {
        get { defaults.bool(forKey: "insertRawFirst") }
        set { defaults.set(newValue, forKey: "insertRawFirst") }
    }
    /// Show what clean-up changed (the diff highlight) and keep "Use raw" in the HUD after a cleaned insertion. Off by
    /// default: the cleaned text is inserted at once, the HUD fades away, and "Use raw" lives on ⌃⌥Z and in the menu.
    public var showChangesAfterCleanup: Bool {
        get { defaults.bool(forKey: "showChangesAfterCleanup") }
        set { defaults.set(newValue, forKey: "showChangesAfterCleanup") }
    }
    /// The HUD's word waveform: each word's audio drawn above it while dictating. Off by default; on asks the server
    /// for word timings.
    public var wordWaveform: Bool {
        get { defaults.bool(forKey: "wordWaveform") }
        set { defaults.set(newValue, forKey: "wordWaveform") }
    }
    /// The default clean-up style (a `correction_profiles` id).
    public var correctionProfile: String {
        get { defaults.string(forKey: "correctionProfile") ?? CorrectionProfile.defaultID }
        set { defaults.set(newValue, forKey: "correctionProfile") }
    }
    /// The prompts the user edited, by style id. A style is in here only while its prompt differs from the server's
    /// default; the others follow the server. Never logged.
    public var correctionPrompts: [String: String] {
        get { defaults.dictionary(forKey: "correctionPrompts") as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: "correctionPrompts") }
    }
    /// The styles with their default prompts as last fetched from the server, for showing them when it is unreachable.
    public var cachedProfiles: [CorrectionProfile]? {
        get { defaults.data(forKey: "cachedProfiles").flatMap { try? JSONDecoder().decode([CorrectionProfile].self, from: $0) } }
        set { defaults.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "cachedProfiles") }
    }
    public func isPromptEdited(_ id: String) -> Bool { correctionPrompts[id] != nil }

    /// Saves what the user typed for style `id`: kept as an edit, or dropped when it is blank or the style's default.
    /// Returns whether the style is edited afterwards. Edits need the live server's default and limit; otherwise nothing changes.
    @discardableResult
    public func setPrompt(_ text: String, for id: String, in catalog: StyleCatalog) -> Bool {
        guard catalog.canEdit else { return isPromptEdited(id) }
        var prompts = correctionPrompts
        if let kept = StylePrompts.override(for: text, default: catalog.defaultPrompt(for: id), limit: catalog.limit(for: id)) {
            prompts[id] = kept
        } else {
            prompts[id] = nil
        }
        correctionPrompts = prompts
        return prompts[id] != nil
    }

    /// Back to the server's prompt for style `id`.
    public func resetPrompt(for id: String) {
        var prompts = correctionPrompts
        prompts[id] = nil
        correctionPrompts = prompts
    }

    /// Before editable prompts, Custom's text lived in `correctionInstructions`; it is now the Custom style's prompt.
    /// Moved once: an existing Custom prompt is kept, and the old key is removed either way.
    private func migrateLegacyInstructions() {
        guard let legacy = defaults.string(forKey: "correctionInstructions") else { return }
        defaults.removeObject(forKey: "correctionInstructions")
        var prompts = correctionPrompts
        guard prompts[CorrectionProfile.customID] == nil else { return }
        let text = (CorrectionProfile.clamp(legacy) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        prompts[CorrectionProfile.customID] = text
        correctionPrompts = prompts
    }
    /// Frontmost app → style. A fresh install has `AppStyleRule.defaults`; once edited the stored list is the truth,
    /// including an empty one.
    public var appStyles: [AppStyleRule] {
        get {
            guard let data = defaults.data(forKey: "appStyles"),
                  let rules = try? JSONDecoder().decode([AppStyleRule].self, from: data) else { return AppStyleRule.defaults }
            return rules
        }
        set {
            var seen = Set<String>()
            let unique = newValue.filter { !$0.bundleID.isEmpty && seen.insert($0.bundleID).inserted }
            defaults.set(try? JSONEncoder().encode(unique), forKey: "appStyles")
        }
    }
    /// UID of the input device the user picked; nil follows the system default input.
    public var inputDeviceUID: String? {
        get { defaults.string(forKey: "inputDeviceUID") }
        set { defaults.set(newValue, forKey: "inputDeviceUID") }
    }
    /// Quiet cues when dictation starts and stops. Off by default.
    public var soundsEnabled: Bool {
        get { defaults.bool(forKey: "soundsEnabled") }
        set { defaults.set(newValue, forKey: "soundsEnabled") }
    }
    /// Which pack plays (Chirp by default; an unknown stored value falls back to it).
    public var soundPack: SoundPack {
        get { SoundPack.resolve(id: defaults.string(forKey: "soundPack")) }
        set { defaults.set(newValue.rawValue, forKey: "soundPack") }
    }
    /// The cue volume, 0…1 (60 % by default). `SoundTiming.gain(volume:)` maps it to a gain.
    public var soundVolume: Double {
        get {
            guard let v = defaults.object(forKey: "soundVolume") as? Double, v.isFinite else { return SoundTiming.defaultVolume }
            return min(max(v, 0), 1)
        }
        set { defaults.set(newValue.isFinite ? min(max(newValue, 0), 1) : SoundTiming.defaultVolume, forKey: "soundVolume") }
    }
    /// The user's own start and stop files (copies in Application Support), used by the Custom pack.
    public var customStartSound: CustomSound? {
        get { customSound(forKey: "customStartSound") }
        set { setCustomSound(newValue, forKey: "customStartSound") }
    }
    public var customStopSound: CustomSound? {
        get { customSound(forKey: "customStopSound") }
        set { setCustomSound(newValue, forKey: "customStopSound") }
    }
    public func customSound(for cue: SoundCue) -> CustomSound? { cue == .start ? customStartSound : customStopSound }

    private func customSound(forKey key: String) -> CustomSound? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(CustomSound.self, from: $0) }
    }
    private func setCustomSound(_ sound: CustomSound?, forKey key: String) {
        if let sound, let data = try? JSONEncoder().encode(sound) { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
    /// Live Notes' "Structure notes" toggle; nil until the user flips it, so the default can follow the server
    /// (on for a local model, off when correction leaves the Mac). A preference, never notes content.
    public var notesStructure: Bool? {
        get { defaults.object(forKey: "notesStructure") as? Bool }
        set { defaults.set(newValue, forKey: "notesStructure") }
    }
    /// Where `notesStructure` was chosen: `local`, or `remote:<host>` when correction left the Mac. A choice only
    /// applies to the same place, so turning it on for this Mac never carries over to another host.
    public var notesStructureScope: String? {
        get { defaults.string(forKey: "notesStructureScope") }
        set { defaults.set(newValue, forKey: "notesStructureScope") }
    }
    public static func notesStructureScope(for health: Health) -> String {
        health.correctionLeavesMachine == true ? "remote:\(health.correctionHost ?? "unknown")" : "local"
    }
    /// The user flipped "Structure notes" against a server with this health (ignored while health is unknown).
    public func setNotesStructure(_ on: Bool, health: Health?) {
        guard let health else { return }
        notesStructure = on
        notesStructureScope = Self.notesStructureScope(for: health)
    }
    /// The Notes window's layout (`notes`, `transcript` or `split`).
    public var notesTab: String {
        get { defaults.string(forKey: "notesTab") ?? "notes" }
        set { defaults.set(newValue, forKey: "notesTab") }
    }
    /// Live Notes' "Auto-reorganize" toggle (on by default). A preference, never notes content.
    public var notesAutoReorganize: Bool {
        get { defaults.object(forKey: "notesAutoReorganize") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "notesAutoReorganize") }
    }
    /// Notes retention is independent of opt-in dictation history. Upgrades also default to Never.
    public var notesRetention: NotesRetention {
        get { defaults.string(forKey: "notesRetention").flatMap(NotesRetention.init(rawValue:)) ?? .never }
        set { defaults.set(newValue.rawValue, forKey: "notesRetention") }
    }
    /// Turning this off only affects future segments; deleting existing audio is an explicit library operation.
    public var notesKeepAudio: Bool {
        get { defaults.bool(forKey: "notesKeepAudio") }
        set { defaults.set(newValue, forKey: "notesKeepAudio") }
    }
    /// Settings → Notes → Allow re-transcribing: a note's kept audio may be sent to the Chirp server again, on request
    /// and after a confirmation each time. On by default (kept audio is opt-in already); off hides every entry point.
    public var notesAllowRetranscribe: Bool {
        get { defaults.object(forKey: "notesAllowRetranscribe") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "notesAllowRetranscribe") }
    }
    /// The re-transcribe sheet's "Also rebuild the notes" box, as last left (off by default: it replaces body edits).
    public var notesRetranscribeRebuild: Bool {
        get { defaults.bool(forKey: "notesRetranscribeRebuild") }
        set { defaults.set(newValue, forKey: "notesRetranscribeRebuild") }
    }

    /// The folder Export Markdown… opens in (a path); nil opens wherever it was last used.
    public var notesExportFolder: String? {
        get { defaults.string(forKey: "notesExportFolder") }
        set { defaults.set(newValue, forKey: "notesExportFolder") }
    }

    /// Legacy transient recovery preference. The Mac library always saves notes independently.
    public var notesRecoveryCopy: Bool {
        get { defaults.object(forKey: "notesRecoveryCopy") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "notesRecoveryCopy") }
    }
    /// The one-time "Chirp writes here and may still rewrite it" tip was shown (a boolean, nothing else).
    public var notesTipSeen: Bool {
        get { defaults.bool(forKey: "notesTipSeen") }
        set { defaults.set(newValue, forKey: "notesTipSeen") }
    }
    /// The Notes pane shows the read-only Preview instead of the editor.
    public var notesPreview: Bool {
        get { defaults.bool(forKey: "notesPreview") }
        set { defaults.set(newValue, forKey: "notesPreview") }
    }
    /// Whether structuring is on: the user's choice for this server's scope, else on only when correction stays on
    /// this Mac. Unknown health is always off, since nothing says where the text would go.
    public func notesStructureEnabled(health: Health?) -> Bool {
        guard let health else { return false }
        // A choice saved before scoping was made against a local model.
        if let choice = notesStructure, (notesStructureScope ?? "local") == Self.notesStructureScope(for: health) { return choice }
        return health.correctionLeavesMachine != true
    }
    /// The `start` options for a Live Notes segment: the clean-up toggle (when the server offers it) with the server's
    /// hidden `live_notes` style, whose prompt is tuned to its guard, so no edited prompt goes along. An older server
    /// gets the default style with the user's edited default prompt. Per-app styles never apply. Word timings always:
    /// they trim an overlapped cut to one copy of each word and place words on the speaker timeline.
    public func notesStartOptions(health: Health?) -> StartOptions {
        let enabled = correction && (health?.correctionAvailable ?? false)
        if health?.notesCorrection == true {
            return StartOptions(client: "mac", correction: enabled, correctionProfile: CorrectionProfile.liveNotesID,
                                wordTimings: true)
        }
        return StartOptions(client: "mac", correction: enabled, correctionProfile: CorrectionProfile.defaultID,
                            correctionPrompt: correctionPrompts[CorrectionProfile.defaultID], wordTimings: true)
    }
    /// Live Notes' "Label speakers": on unless the user turned it off. Only the user's own Turn off (or Remove)
    /// stores a value; a missing or failed model is a model state, never a preference. A preference only; no label,
    /// name or voice is ever stored.
    public var notesSpeakerLabels: Bool {
        get { notesSpeakerLabelsChoice ?? true }
        set { notesSpeakerLabelsChoice = newValue }
    }
    /// The stored choice; nil until the user makes one. Writing one stamps `speakerLabelsDefault`, so the migration
    /// below never mistakes it for a legacy value.
    public var notesSpeakerLabelsChoice: Bool? {
        get { defaults.object(forKey: "notesSpeakerLabels") as? Bool }
        set {
            if let newValue { defaults.set(newValue, forKey: "notesSpeakerLabels") } else { defaults.removeObject(forKey: "notesSpeakerLabels") }
            defaults.set(Self.speakerLabelsDefault, forKey: "speakerLabelsDefault")
        }
    }
    /// Version of the "labels are on by default" rule. Before it (nothing stored), the app wrote `false` itself
    /// whenever the model was missing or failed to load, so a stored `false` did not mean the user chose off.
    static let speakerLabelsDefault = 2
    /// Once, at launch: clears a legacy `false` (back to the default, on), keeps a legacy `true`, and from then on
    /// only the user's own choices are stored. Returns whether it cleared one.
    @discardableResult
    public func migrateSpeakerLabelsDefault() -> Bool {
        guard defaults.integer(forKey: "speakerLabelsDefault") < Self.speakerLabelsDefault else { return false }
        let cleared = notesSpeakerLabelsChoice == false
        if cleared { defaults.removeObject(forKey: "notesSpeakerLabels") }
        defaults.set(Self.speakerLabelsDefault, forKey: "speakerLabelsDefault")
        return cleared
    }
    /// Settings › Notes › Sources: new notes include call audio (#211). Off by default; each note can change it.
    public var notesCallAudio: Bool {
        get { defaults.bool(forKey: "notesCallAudio") }
        set { defaults.set(newValue, forKey: "notesCallAudio") }
    }
    /// The one app call audio comes from (its bundle id and name); nil records everything the Mac plays.
    public var notesCallAudioApp: CallAudioApp? {
        get {
            guard let id = defaults.string(forKey: "notesCallAudioApp"), !id.isEmpty else { return nil }
            return CallAudioApp(bundleID: id, name: defaults.string(forKey: "notesCallAudioAppName") ?? id)
        }
        set {
            defaults.set(newValue?.bundleID, forKey: "notesCallAudioApp")
            defaults.set(newValue?.name, forKey: "notesCallAudioAppName")
        }
    }
    /// The sources a new note starts with.
    public var notesSources: NotesSources { NotesSources(callAudio: notesCallAudio, app: notesCallAudioApp) }
    /// The user read what "Include call audio" records and continued (asked once, before the system prompt).
    public var notesCallAudioExplained: Bool {
        get { defaults.bool(forKey: "notesCallAudioExplained") }
        set { defaults.set(newValue, forKey: "notesCallAudioExplained") }
    }
    /// The one-time saved-voice notice; the server owns the Remember voices switch.
    public var notesVoiceNoticeShown: Bool {
        get { defaults.bool(forKey: "notesVoiceNoticeShown") }
        set { defaults.set(newValue, forKey: "notesVoiceNoticeShown") }
    }

    public var notesImportedVoices: [String] {
        get { defaults.stringArray(forKey: "notesImportedVoices") ?? [] }
        set { defaults.set(newValue, forKey: "notesImportedVoices") }
    }

    public var notesVoiceProfiles: Bool {
        get { defaults.bool(forKey: "notesVoiceProfiles") }
        set { defaults.set(newValue, forKey: "notesVoiceProfiles") }
    }
    /// Dictation history (Settings → History & privacy): on by default, kept on this Mac only, sealed.
    public var historyEnabled: Bool {
        get { defaults.object(forKey: "historyEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "historyEnabled") }
    }
    /// How long dictations are kept (30 days by default).
    public var historyRetention: DictationRetention {
        get { defaults.string(forKey: "historyRetention").flatMap(DictationRetention.init(rawValue:)) ?? .default }
        set { defaults.set(newValue.rawValue, forKey: "historyRetention") }
    }
    /// Apps whose dictations are never kept (bundle ids). Password managers until the user edits the list; once
    /// edited the stored list is the truth, including an empty one.
    public var historyExcludedApps: [String] {
        get { defaults.stringArray(forKey: "historyExcludedApps") ?? HistoryPolicy.defaultExcludedApps }
        set {
            var seen = Set<String>()
            defaults.set(newValue.filter { !$0.isEmpty && seen.insert($0).inserted }, forKey: "historyExcludedApps")
        }
    }
    /// Learn from my edits (Settings → History & privacy): on by default; it only runs while history is on.
    public var learnFromEdits: Bool {
        get { defaults.object(forKey: "learnFromEdits") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "learnFromEdits") }
    }
    public var learningEnabled: Bool { historyEnabled && learnFromEdits }
    /// Set only when the first-run window is finished (never on close), so an interrupted setup shows again.
    public var didOnboard: Bool {
        get { defaults.bool(forKey: "didOnboard") }
        set { defaults.set(newValue, forKey: "didOnboard") }
    }

    public func serverConfig() -> ServerConfig { ServerConfig.load(urlString: serverURL) }

    /// The style for a dictation that starts in `bundleID`'s app. `available` is the server's list, when known.
    public func cleanupStyle(frontmostBundleID bundleID: String?, available: [CorrectionProfile]? = nil) -> CleanupStyle.Resolved {
        CleanupStyle.resolve(bundleID: bundleID, rules: appStyles, defaultProfile: correctionProfile,
                             prompts: correctionPrompts, available: available)
    }

    /// What the next `start` message asks for: the clean-up toggle is the wire `correction` flag, and the style comes
    /// from the frontmost app's rule or the default style, and the prompt goes along only when the user edited that style.
    public func startOptions(frontmostBundleID bundleID: String? = nil, available: [CorrectionProfile]? = nil) -> StartOptions {
        let style = cleanupStyle(frontmostBundleID: bundleID, available: available)
        return StartOptions(client: "mac", correction: correction, correctionProfile: style.profile,
                            correctionInstructions: style.instructions, correctionPrompt: style.prompt,
                            wordTimings: wordWaveform)
    }
}
