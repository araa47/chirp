import AppKit
import ChirpCore

/// What the Settings window shows. The window controller reads it from the system; the snapshots pass fixed values.
public struct SettingsState: Sendable {
    public var hotkey: KeyCombo = .defaultDictation
    /// Shortcuts: Start/Stop Notes, Open Notes and Use raw.
    public var notesHotkey: KeyCombo = .controlOptionN
    public var openNotesHotkey: KeyCombo = .controlOptionShiftN
    public var useRawHotkey: KeyCombo = .controlOptionZ
    /// General: "Always show Chirp in the Dock".
    public var alwaysShowInDock = false
    public var activationMode: ActivationMode = .autoStop
    /// Dictation: press Return after inserting (off by default).
    public var autoEnter: AutoEnter = .off
    /// Auto-stop: seconds of quiet that end a dictation.
    public var autoStopSilence = AutoStopDetector.defaultSilence
    public var serverURL = ServerConfig.defaultURL.absoluteString
    public var tokenPresent = true
    public var launch: LaunchState = .off
    /// Dictation: the HUD's word waveform (each word's audio above it). Off by default.
    public var spokenCommands = false
    public var privateSession = false
    public var wordWaveform = false
    public var soundsEnabled = false
    public var soundPack: SoundPack = .default
    /// 0…1.
    public var soundVolume = SoundTiming.defaultVolume
    /// The user's own files for the Custom pack, as imported.
    public var customStart: CustomSound?
    public var customStop: CustomSound?
    public var micGranted = true
    public var accessibilityGranted = true
    /// The server's state in words ("Connected", "Unreachable", …) and its tone.
    public var serverStatus = "Connected"
    public var serverStatusTone: MenuEntry.Tone = .ok
    /// The server is older than the app: what to say and the button that fixes it; the last fix attempt's result.
    public var serverNotice: ServerNotice?
    public var serverFixMessage: String?
    /// Clean-up: on or off, the default style, the edited style prompts, the raw-first option and the per-app styles.
    public var cleanupEnabled = false
    /// Where clean-up runs, or that the server has it off (under the checkbox), and whether it can be turned on.
    public var cleanupDetail = "Tidies punctuation and wording before the text is inserted."
    public var cleanupAvailable = true
    public var cleanupStyle = CorrectionProfile.defaultID
    /// The prompts the user edited, by style id (only styles that differ from the server's default).
    public var stylePrompts: [String: String] = [:]
    /// The styles with their default prompts, and whether they are live, the last-known copy, or not loaded.
    public var catalog = StyleCatalog.unavailable
    /// The style the prompt editor opens on.
    public var editingStyle = CorrectionProfile.defaultID
    public var insertRawFirst = false
    /// "Use raw" stays on offer for 5 seconds after a cleaned insertion (the hotkey and the menu row).
    public var offerRaw = true
    /// "Show changes after clean-up": the diff highlight and the HUD's Use raw button. Off by default.
    public var showChanges = false
    public var appStyles = AppStyleRule.defaults
    /// The styles the server offers (the built-ins until it says otherwise) and whether it offers any at all.
    public var profiles = CorrectionProfile.builtIn
    public var serverOffersStyles = true
    /// "Keep clean-up model loaded": what the server last said, and where its memory is used ("this Mac" or the host).
    public var keepLoaded = KeepLoadedState()
    public var serverHost = "this Mac"
    /// Some of Live Notes' speaker-label model is on this Mac, complete or not (Remove deletes it).
    public var speakerModelDownloaded = false
    /// The speaker model's state and size ("106 MB"), as the Notes window's status line shows them.
    public var speakerModel: SpeakerModelState = .notDownloaded
    public var speakerModelSize = ""
    /// Notes › Speakers: "Label speakers" (the same switch as the Notes window's ✦ menu; on by default), and whether
    /// a recording holds it (it applies from the next Record).
    public var speakerLabels = true
    public var speakerLabelsLocked = false
    /// Notes › Voices: "Recognize saved voices", the voice model and the saved voices.
    public var voices = VoiceProfilesState()
    /// Dictation: every input device, the system default among them, and the one the user picked (nil follows the default).
    public var inputs: [AudioInput] = []
    public var defaultInput: AudioInput?
    public var chosenInputUID: String?
    /// About: the version from the app bundle.
    public var about = AboutInfo()
    /// Notes › Library: how long notes are kept, how many sit in Recently Deleted, and the kept-audio total.
    public var notesRetention: NotesRetention = .never
    public var recentlyDeletedCount = 0
    public var notesKeepAudio = false
    /// Notes › Audio: "Allow re-transcribing" (#287), on by default.
    public var notesAllowRetranscribe = true
    /// Notes › Sources: new notes include call audio (#211).
    public var notesCallAudio = false
    public var notesAudioBytes = 0
    /// Dictation › History: on (the default), how long dictations are kept, the apps never kept, and how many are kept.
    public var historyEnabled = true
    public var historyRetention = DictationRetention.default
    public var historyExcludedApps = HistoryPolicy.defaultExcludedApps
    public var historyCount = 0
    /// Dictation › Learn from my edits: on by default (only while history is on), and what it has learned.
    public var learnFromEdits = true
    public var learnedSummary = "Nothing yet"
    /// Notes › Export: the folder Export Markdown… opens in (nil: wherever it was last used).
    public var exportFolder: String?
    /// Notes › Smart notes: the defaults for new recordings.
    public var structureNotes = false
    public var autoReorganize = true

    public init() {}

    public func combo(for shortcut: ChirpShortcut) -> KeyCombo {
        switch shortcut {
        case .dictation: hotkey
        case .notes: notesHotkey
        case .openNotes: openNotesHotkey
        case .useRaw: useRawHotkey
        }
    }
}

/// The preferences window's pages, in the sidebar's order: start Chirp and fix permissions; dictation (every shortcut,
/// how a dictation stops, sounds and where it listens); history and privacy; clean-up; the Notes library; phones; and
/// Advanced (the server, its token, models and the Doctor). About is the sidebar's footer row.
public enum SettingsTab: String, CaseIterable, Sendable {
    case general, dictation, privacy, cleanup, notes, devices, advanced, about

    public var title: String {
        switch self {
        case .general: "General"
        case .dictation: "Dictation"
        case .privacy: "History & privacy"
        case .cleanup: "Clean-up"
        case .notes: "Notes"
        case .devices: "Devices"
        case .advanced: "Advanced"
        case .about: "About"
        }
    }

    /// The sidebar icon (SF Symbol).
    public var symbol: String {
        switch self {
        case .general: "gearshape"
        case .dictation: "mic"
        case .privacy: "lock.shield"
        case .cleanup: "sparkles"
        case .notes: "note.text"
        case .devices: "iphone"
        case .advanced: "slider.horizontal.3"
        case .about: "info.circle"
        }
    }

    /// What the sidebar's search field matches besides the title, so "login", "token" or "retention" finds its page.
    public var keywords: [String] {
        switch self {
        case .general: ["startup", "launch at login", "dock", "permissions", "microphone", "accessibility", "setup"]
        case .dictation: ["shortcuts", "hotkey", "hold to talk", "auto-stop", "stop", "silence", "return", "word waveform",
                          "sounds", "volume", "input device", "use raw", "new note", "spoken commands", "new line", "new paragraph"]
        case .privacy: ["history", "dictation history", "recent dictations", "retention", "clear", "privacy", "learn",
                        "learned", "edits", "vocabulary", "terms", "private session", "never keep", "excluded"]
        case .cleanup: ["style", "prompts", "per-app", "insert raw", "review changes", "undo", "polish"]
        case .notes: ["library", "retention", "recently deleted", "audio", "storage", "export", "folder", "smart notes",
                      "structure", "reorganize", "speakers", "voices", "saved voices", "call audio", "sources", "zoom", "meeting"]
        case .devices: ["phone", "pair", "paired", "android", "iphone", "token", "revoke"]
        case .advanced: ["server", "url", "token", "models", "doctor", "keep loaded", "status"]
        case .about: ["version", "notices", "licenses"]
        }
    }

    /// The pages listed in the sidebar's body; About sits in the footer.
    public static var sidebar: [SettingsTab] { allCases.filter { $0 != .about } }
}

/// A tab's content view. It accepts first responder so the window can park focus here instead of on a text field,
/// which would otherwise open selected.
public final class SettingsContentView: NSView {
    override public var acceptsFirstResponder: Bool { true }
    /// Top-down, so a page shorter than the window sits at its top inside the scroll view.
    override public var isFlipped: Bool { true }
}

/// The Settings window content, plain AppKit on purpose: the Command Line Tools toolchain has no SwiftUI macro
/// plugins (@State etc.). One view per toolbar tab (`SettingsTab`): labels right-aligned in one column and controls
/// left-aligned in a second, with help text below its control and a little more space between groups of rows. Every
/// tab is as wide as the widest (so the window keeps its width and its toolbar), with the form centred and each tab
/// as tall as its content. All controls live here and are exposed so the owner can attach targets and actions.
@MainActor
public final class SettingsForm {
    /// Notes › Sources: what "Include call audio" records, said before macOS asks for the permission.
    public static let callAudioHelp = "Records what your Mac plays (the other people on a call) beside your microphone, so both sides are transcribed. Your microphone is labelled “You”. macOS asks once for Screen & System Audio Recording. Kept audio stays on this Mac; transcription uses your configured Chirp server."
    /// History & privacy › What Chirp keeps. The privacy-page footer (docs/copy.md).
    public static let privacyKeeps = "Notes stay on this Mac."
    static let margin: CGFloat = ChirpSpacing.gutter
    /// The width a control that fills its row may take.
    static let controlWidth: CGFloat = SettingsLayout.rowWidth
    /// A text field beside its title.
    static let fieldWidth: CGFloat = 280
    /// Every page is this wide: the card column plus the gutters. The window's detail column is exactly this.
    static let pageWidth: CGFloat = SettingsLayout.pageWidth + 2 * margin

    /// One content view per page, holding its body (the sections, or the About view) with a 20 pt margin around it.
    private var tabViews: [SettingsTab: SettingsContentView] = [:]
    private var bodies: [SettingsTab: NSView] = [:]
    public let hotkey = NSPopUpButton(frame: .zero, pullsDown: false)
    public let recorder = HotkeyRecorder()
    /// Shortcuts: every global shortcut besides dictation, with the same recorder and rules.
    public let notesShortcut = ShortcutControls(.notes, purpose: "Starts a new note and records, from any app.")
    public let openNotes = ShortcutControls(.openNotes, purpose: "Brings the Notes library forward without recording.")
    public let useRawShortcut = ShortcutControls(.useRaw, purpose: "Puts the original words back for 5 s after a cleaned insertion.")
    public let alwaysInDock = NSButton(checkboxWithTitle: "Always show Chirp in the Dock", target: nil, action: nil)
    /// Under the hotkey: how it works, or why the last recording was refused.
    public let hotkeyHelp = SettingsForm.help("")
    /// Fn/Globe has a separate macOS action that the user must turn off in Keyboard settings.
    public let fnKeyHelp = SettingsForm.help("To use fn / 🌐 without opening emoji or another macOS action, open System Settings → Keyboard and set “Press 🌐 key to” to “Do Nothing”.")
    public let keyboardSettingsButton = NSButton(title: "Open Keyboard Settings…", target: nil, action: nil)
    private var fnKeySetupRow: SettingsRow?
    /// Auto-stop or hold to talk, and (auto-stop only) how long a pause ends the dictation.
    public let mode = NSPopUpButton(frame: .zero, pullsDown: false)
    public let silence = NSPopUpButton(frame: .zero, pullsDown: false)
    /// Press Return after inserting: Off, Always, or in chat apps only.
    public let autoEnter = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modeHelp = SettingsForm.help("")
    private let offerRawHelp = SettingsForm.help("")
    private var shownHotkey = KeyCombo.defaultDictation
    public let sounds = NSButton(checkboxWithTitle: "Play start and stop sounds", target: nil, action: nil)
    /// Sounds: the pack, ▶ previews, the volume, and (for the Custom pack) the user's files.
    public let soundPack = NSPopUpButton(frame: .zero, pullsDown: false)
    public let previewStart = NSButton(title: "▶ Start", target: nil, action: nil)
    public let previewStop = NSButton(title: "▶ Stop", target: nil, action: nil)
    public let volume = NSSlider(value: SoundTiming.defaultVolume * 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    public let chooseStart = NSButton(title: "Choose…", target: nil, action: nil)
    public let removeStart = NSButton(title: "Remove", target: nil, action: nil)
    public let chooseStop = NSButton(title: "Choose…", target: nil, action: nil)
    public let removeStop = NSButton(title: "Remove", target: nil, action: nil)
    /// Under the start file: the 0.3 s rule, or why the last import failed.
    public let customStartHelp = SettingsForm.help("")
    private let packHelp = SettingsForm.help("")
    private let volumeLabel = NSTextField(labelWithString: "")
    private let startFile = NSTextField(labelWithString: "")
    private let stopFile = NSTextField(labelWithString: "")
    private var customStartSound: CustomSound?
    private var customStopSound: CustomSound?
    private var soundError: String?
    /// The Start sound and Stop sound rows of the Dictation page, shown only for the Custom pack.
    private var customRows: [SettingsRow] = []
    /// Dictation: the input device, as in the menu's Microphone submenu.
    public let microphone = NSPopUpButton(frame: .zero, pullsDown: false)
    private var shownMicrophones: [String]?
    public let serverURL = NSTextField(string: "")
    public let launch = NSButton(checkboxWithTitle: "Launch Chirp at login", target: nil, action: nil)
    /// Dictation: the HUD's word waveform.
    public let wordWaveform = NSButton(checkboxWithTitle: "Word waveform overlay", target: nil, action: nil)
    /// Notes: how long the library keeps a note, what Recently Deleted holds, kept audio, the export folder and the
    /// smart-notes defaults. Presentational: each maps to a preference that already exists (or one folder path).
    public let notesRetention = NSPopUpButton(frame: .zero, pullsDown: false)
    public let emptyDeleted = NSButton(title: "Empty…", target: nil, action: nil)
    private let deletedStatus = NSTextField(labelWithString: "")
    public let keepAudio = NSButton(checkboxWithTitle: "Keep audio with notes", target: nil, action: nil)
    public let allowRetranscribe = NSButton(checkboxWithTitle: NotesRetranscribeText.setting, target: nil, action: nil)
    public let callAudio = NSButton(checkboxWithTitle: "Include call audio in new notes", target: nil, action: nil)
    public let deleteAudio = NSButton(title: "Delete…", target: nil, action: nil)
    private let audioStatus = NSTextField(labelWithString: "")
    public let chooseExport = NSButton(title: "Choose…", target: nil, action: nil)
    public let resetExport = NSButton(title: "Reset", target: nil, action: nil)
    private let exportFolder = NSTextField(labelWithString: "")
    public let structureNotes = NSButton(checkboxWithTitle: "Structure notes", target: nil, action: nil)
    public let autoReorganize = NSButton(checkboxWithTitle: "Organize automatically", target: nil, action: nil)
    /// Dictation › History: keep dictations (on by default), for how long, the apps never kept, and the window/Clear.
    public let privateSession = NSButton(checkboxWithTitle: "Private session", target: nil, action: nil)
    public let spokenCommands = NSButton(checkboxWithTitle: "Spoken commands", target: nil, action: nil)
    public let historyEnabled = NSButton(checkboxWithTitle: HistorySettingsText.keep, target: nil, action: nil)
    public let historyRetention = NSPopUpButton(frame: .zero, pullsDown: false)
    public let historyApps = HistoryAppsList()
    public let openHistory = NSButton(title: "Open History…", target: nil, action: nil)
    public let clearHistory = NSButton(title: "Delete History…", target: nil, action: nil)
    private let historyStatus = NSTextField(labelWithString: "")
    /// Dictation › Learn from my edits: the switch and the Learned list.
    public let learnFromEdits = NSButton(checkboxWithTitle: LearnedText.toggle, target: nil, action: nil)
    public let showLearned = NSButton(title: "Show Learned…", target: nil, action: nil)
    private let learnedStatus = NSTextField(labelWithString: "")
    private let learnHelp = SettingsForm.help(LearnedText.help)
    /// General: reopens the setup walk-through.
    public let setupButton = NSButton(title: "Set Up Chirp…", target: nil, action: nil)
    /// Server: puts the chirp-server doctor command on the pasteboard.
    public let doctorButton = NSButton(title: "Copy Doctor Command", target: nil, action: nil)
    public let modelsButton = NSButton(title: "Manage Local Models…", target: nil, action: nil)
    /// Devices: opens the pairing window (Tailscale check and QR code).
    public let pairButton = NSButton(title: "Pair a Phone…", target: nil, action: nil)
    /// Devices: the phones paired with their own token, each with Revoke; and the advanced shared-token rotation.
    public let devicesView = DevicesView()
    public let rotateButton = NSButton(title: "Reset Shared Code…", target: nil, action: nil)
    /// Notes: "Label speakers", on by default; the one-time model download starts by itself, with a status line here.
    public let labelSpeakers = NSButton(checkboxWithTitle: "Label speakers", target: nil, action: nil)
    /// Notes: deletes Live Notes' on-device speaker model (shown beside its status while it is on this Mac).
    public let removeSpeakerModel = NSButton(title: "Remove", target: nil, action: nil)
    /// Notes: fetches the speaker model again after a failed download (shown beside its status).
    public let retrySpeakerModel = NSButton(title: "Retry", target: nil, action: nil)
    private let speakerStatus = StatusLine()
    private let speakerHelp = SettingsForm.help("")
    /// Notes: the Saved voices library, shown as a detail page rather than a sheet.
    public let voicesView = VoiceProfilesView()
    private let savedVoicesLink = SettingsDisclosure("Saved voices")
    /// The Notes row that opens Saved voices. The whole row is the button.
    public var savedVoicesButton: NSButton { savedVoicesLink.button }
    /// Notes: brings the Notes window forward.
    public let notesButton = NSButton(title: "Open Notes Library", target: nil, action: nil)
    /// About: the icon, the version and Third-Party Notices….
    public let about: AboutView
    /// Server: "Restart server" or "Use Chirp’s managed server instead", shown only for an out-of-date server.
    public let serverFixButton = NSButton(title: ServerFix.restart.buttonTitle, target: nil, action: nil)
    private let serverDetail = SettingsForm.help("")
    private let modelsHelp = SettingsForm.help("")
    public let micButton = NSButton(title: "Fix…", target: nil, action: nil)
    public let accessibilityButton = NSButton(title: "Fix…", target: nil, action: nil)
    /// Under the checkbox: what it does, or why the last change failed.
    public let launchHelp = SettingsForm.help("")
    /// Clean-up: default style, style prompts, raw-first and the per-app table.
    public let cleanupEnabled = NSButton(checkboxWithTitle: "Clean up dictated text", target: nil, action: nil)
    public let style = NSPopUpButton(frame: .zero, pullsDown: false)
    public let prompts = StylePromptsEditor()
    public let insertRawFirst = NSButton(checkboxWithTitle: "Insert raw immediately, then replace with cleaned", target: nil, action: nil)
    public let showChanges = NSButton(checkboxWithTitle: "Show changes after clean-up", target: nil, action: nil)
    public let offerRaw = NSButton(checkboxWithTitle: "Offer “Use raw” for 5 seconds after clean-up", target: nil, action: nil)
    public let appStyles = AppStylesTable()
    /// Server: keeps the server's clean-up model in memory. Its state, memory cost and any error sit under it.
    public let keepLoaded = NSButton(checkboxWithTitle: KeepLoaded.title, target: nil, action: nil)
    private let keepLoadedStatus = StatusLine()
    private let keepLoadedHelp = SettingsForm.help("")
    private let keepLoadedError = SettingsForm.help("")
    private let styleHelp = SettingsForm.help("")
    private let cleanupHelp = SettingsForm.help("")
    private var shownProfileIDs: [String] = []
    private var shownCatalog: StyleCatalog?
    private let tokenStatus = StatusLine()
    private let tokenHelp = SettingsForm.help("")
    private let serverStatus = StatusLine()
    private let micStatus = StatusLine()
    private let accessibilityStatus = StatusLine()
    private var launchUnavailable = false

    public init(_ state: SettingsState, icon: NSImage? = nil, onNotices: (() -> Void)? = nil) {
        about = AboutView(icon: icon, info: state.about, onNotices: onNotices)
        recorder.onStatusChange = { [weak self] _ in self?.refreshHotkeyHelp() }
        serverURL.placeholderString = ServerConfig.defaultURL.absoluteString
        serverURL.font = MenuStyle.font
        serverURL.lineBreakMode = .byTruncatingMiddle
        serverURL.widthAnchor.constraint(equalToConstant: Self.fieldWidth).isActive = true
        for button in [micButton, accessibilityButton, removeSpeakerModel, retrySpeakerModel] { button.bezelStyle = .rounded; button.controlSize = .small }
        micStatus.accessory = micButton
        serverFixButton.bezelStyle = .rounded; serverFixButton.controlSize = .small
        serverFixButton.setAccessibilityLabel("Fix the out-of-date server")
        serverStatus.accessory = serverFixButton
        serverDetail.isHidden = true
        accessibilityStatus.accessory = accessibilityButton
        speakerStatus.accessory = removeSpeakerModel
        speakerStatus.addArrangedSubview(retrySpeakerModel)
        retrySpeakerModel.setAccessibilityLabel("Download the speaker model again")
        micButton.setAccessibilityLabel("Fix Microphone access")
        accessibilityButton.setAccessibilityLabel("Fix Accessibility access")
        removeSpeakerModel.setAccessibilityLabel("Remove the speaker model")
        speakerStatus.setAccessibilityLabel("Speaker model")
        microphone.setAccessibilityLabel("Microphone")
        (microphone.cell as? NSPopUpButtonCell)?.lineBreakMode = .byTruncatingTail
        microphone.widthAnchor.constraint(lessThanOrEqualToConstant: Self.fieldWidth).isActive = true

        for button in [setupButton, doctorButton, modelsButton, pairButton, rotateButton, notesButton] { button.bezelStyle = .rounded }
        setupButton.setAccessibilityLabel("Set up Chirp")
        alwaysInDock.setAccessibilityLabel("Always show Chirp in the Dock")
        alwaysInDock.toolTip = "Off: Chirp is in the Dock and ⌘-Tab only while a Notes window is open."
        keyboardSettingsButton.bezelStyle = .rounded
        keyboardSettingsButton.controlSize = .small

        func row(_ title: String?, _ control: NSView?, help: NSTextField? = nil, stacked: Bool = false) -> SettingsRow {
            SettingsRow(title: title, control: control, help: help, stacked: stacked)
        }

        func stack(_ views: [NSView]) -> NSStackView {
            let stack = NSStackView(views: views)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 4
            return stack
        }

        func line(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = spacing
            return stack
        }

        for button in [emptyDeleted, deleteAudio, chooseExport, resetExport] { button.bezelStyle = .rounded; button.controlSize = .small }
        emptyDeleted.setAccessibilityLabel("Empty Recently Deleted")
        deleteAudio.setAccessibilityLabel("Delete all kept audio")
        chooseExport.setAccessibilityLabel("Choose the export folder")
        resetExport.setAccessibilityLabel("Use the last export folder again")
        for label in [deletedStatus, audioStatus] { label.font = MenuStyle.font; label.textColor = .secondaryLabelColor }
        exportFolder.font = MenuStyle.font
        exportFolder.lineBreakMode = .byTruncatingMiddle
        exportFolder.widthAnchor.constraint(equalToConstant: 170).isActive = true
        notesRetention.setAccessibilityLabel("Delete notes older than")
        for r in NotesRetention.allCases {
            notesRetention.addItem(withTitle: Self.retentionTitle(r))
            notesRetention.lastItem?.representedObject = r.rawValue
        }
        labelSpeakers.setAccessibilityLabel("Label speakers in Live Notes")
        structureNotes.setAccessibilityLabel("Structure notes by default")
        autoReorganize.setAccessibilityLabel("Organize automatically by default")
        keepAudio.setAccessibilityLabel("Keep audio with notes")
        allowRetranscribe.setAccessibilityLabel(NotesRetranscribeText.setting)
        callAudio.setAccessibilityLabel("Include call audio in new notes")

        build(.general, [
            SettingsSection("Startup", [row(nil, launch, help: launchHelp), row(nil, alwaysInDock)]),
            SettingsSection("Permissions", [row(nil, micStatus), row(nil, accessibilityStatus)],
                            footnote: Self.help("The microphone lets Chirp hear you; Accessibility lets it insert text into other apps and send ⌘V.")),
            SettingsSection("Setup", [row("Set up Chirp", setupButton, help: Self.help("Check the permissions and the server, and try a dictation."))]),
        ])

        let hotkeyRow = line([hotkey, recorder], spacing: 10)
        let packRow = line([soundPack, previewStart, previewStop])
        let volumeRow = line([volume, volumeLabel])
        let fnRow = row(nil, stack([fnKeyHelp, keyboardSettingsButton]))
        fnKeySetupRow = fnRow
        let startRow = row("Start sound", Self.fileRow(startFile, choose: chooseStart, remove: removeStart), help: customStartHelp)
        let stopRow = row("Stop sound", Self.fileRow(stopFile, choose: chooseStop, remove: removeStop),
                          help: Self.help("Plays after you stop talking, up to \(SoundTiming.stopLimit) s."))
        customRows = [startRow, stopRow]
        for button in [openHistory, clearHistory] { button.bezelStyle = .rounded; button.controlSize = .small }
        historyStatus.font = MenuStyle.font
        historyStatus.textColor = .secondaryLabelColor
        historyEnabled.setAccessibilityLabel(HistorySettingsText.keep)
        historyRetention.setAccessibilityLabel("Keep dictations for")
        openHistory.setAccessibilityLabel("Open Dictation History")
        clearHistory.setAccessibilityLabel("Delete dictation history")
        showLearned.bezelStyle = .rounded; showLearned.controlSize = .small
        showLearned.setAccessibilityLabel("Show what Chirp learned from your edits")
        learnFromEdits.setAccessibilityLabel(LearnedText.toggle)
        learnedStatus.font = MenuStyle.font
        learnedStatus.textColor = .secondaryLabelColor
        for r in DictationRetention.allCases {
            historyRetention.addItem(withTitle: r.title)
            historyRetention.lastItem?.representedObject = r.rawValue
        }
        build(.dictation, [
            SettingsSection("Shortcuts", [
                row("Dictation", hotkeyRow, help: hotkeyHelp), fnRow,
                row("New note", notesShortcut.view, help: notesShortcut.helpView),
                row("Notes library", openNotes.view, help: openNotes.helpView),
                row("Use raw", useRawShortcut.view, help: useRawShortcut.helpView),
            ]),
            SettingsSection("Dictating", [
                row("Mode", mode, help: modeHelp),
                row("Stop after", silence),
                row("Microphone", microphone, help: Self.help("Follows the system default unless you pick one. Applies from the next dictation.")),
                row(nil, wordWaveform, help: Self.help("Draws each word's audio above it as you speak, so you can see what was heard.")),
                row(nil, spokenCommands, help: Self.help("Off by default. Say “new line” or “new paragraph” at the end of a dictation to insert line breaks.")),
                row("Press Return", autoEnter, help: Self.help("Sends a chat message after inserting. Hold ⇧ when you stop to skip it. Chat apps are those set to the Chat style.")),
            ]),
            SettingsSection("Sounds", [
                row(nil, sounds, help: Self.help("Quiet sounds when dictation starts and stops. Off keeps Chirp silent.")),
                row("Pack", packRow, help: packHelp), row("Volume", volumeRow), startRow, stopRow,
            ]),
        ])

        build(.privacy, [
            SettingsSection("Privacy", [
                row(nil, privateSession, help: Self.help(PrivateSession.help)),
            ]),
            SettingsSection("Dictation history", [
                row(nil, historyEnabled, help: Self.help(HistorySettingsText.keepHelp)),
                row("Keep for", historyRetention, help: Self.help(HistorySettingsText.retentionHelp)),
                row("Never keep", historyApps.view, help: Self.help(HistorySettingsText.appsHelp)),
                row("Kept", line([historyStatus, openHistory, clearHistory])),
            ]),
            SettingsSection(LearnedText.toggle, [
                row(nil, learnFromEdits, help: learnHelp),
                row("Learned", line([learnedStatus, showLearned])),
            ]),
            SettingsSection("What Chirp keeps", [
                row(nil, Self.help(Self.privacyKeeps), stacked: true),
            ]),
        ])

        build(.cleanup, [
            SettingsSection(nil, [row(nil, cleanupEnabled, help: cleanupHelp), row("Style", style, help: styleHelp)]),
            SettingsSection("Style prompts", [row(nil, prompts.view, stacked: true)]),
            SettingsSection("Per-app styles", [row(nil, appStyles.view,
                help: Self.help("The frontmost app when you start dictating picks the style. Other apps use the default style."), stacked: true)]),
            SettingsSection("After clean-up", [
                row(nil, insertRawFirst, help: Self.help("Swaps in the cleaned text in place where Chirp can verify the insert; elsewhere it inserts once.")),
                row(nil, showChanges, help: Self.help("Off: the cleaned text is inserted at once. On: the HUD highlights what changed and keeps a Use raw button.")),
                row(nil, offerRaw, help: offerRawHelp),
            ]),
        ])

        build(.notes, [
            SettingsSection("Library", [
                row("Notes library", notesButton, help: Self.help("Every note is saved as you go and kept on this Mac. Nothing is synced.")),
                row("Delete notes older than", notesRetention,
                    help: Self.help("Never by default. Older notes move to Recently Deleted when Chirp opens, and stay there for 30 days.")),
                row("Recently Deleted", line([deletedStatus, emptyDeleted])),
            ]),
            SettingsSection("Sources", [
                row(nil, callAudio, help: Self.help(SettingsForm.callAudioHelp)),
            ], footnote: Self.help("Each note can change it from Sources in the Notes toolbar. Mac only: iPhone and Android can’t record other apps’ audio.")),
            SettingsSection("Audio", [
                row(nil, keepAudio, help: Self.help("Keeps each spoken segment with its note so you can replay it. Off by default; the audio leaves this Mac only when you re-transcribe a note.")),
                row(nil, allowRetranscribe, help: Self.help(NotesRetranscribeText.settingHelp)),
                row("Kept audio", line([audioStatus, deleteAudio])),
            ]),
            SettingsSection("Export", [
                row("Export folder", line([exportFolder, chooseExport, resetExport]),
                    help: Self.help("Where Export Markdown… opens. Exports are copies; the notes stay in the library.")),
            ]),
            SettingsSection("Smart notes", [
                row(nil, structureNotes, help: Self.help("Turns the transcript into headings, bullets and to-dos while you record.")),
                row(nil, autoReorganize, help: Self.help("Tidies the notes in the background as they grow.")),
            ], footnote: Self.help("Defaults for new recordings. The ✦ menu in the Notes window changes them while you record.")),
            SettingsSection("Speakers", [
                row(nil, labelSpeakers, help: Self.help("On by default. Shows who said what as Person 1, Person 2… in the transcript, the notes and exports. Voices are told apart on this Mac only.")),
                row(nil, stack([speakerStatus, speakerHelp])),
                row(nil, savedVoicesLink, help: Self.help("Names recognised on all your devices.")),
            ]),
        ])

        let keepLoadedStack = stack([keepLoaded, keepLoadedStatus, keepLoadedHelp, keepLoadedError])
        keepLoadedError.textColor = .systemRed
        keepLoadedError.isHidden = true
        keepLoadedStatus.setAccessibilityLabel("Clean-up model status")
        build(.devices, [
            SettingsSection("Phones", [
                row("Pair a phone", pairButton, help: Self.help("Shows a code for Chirp on Android or iPhone to connect over your tailnet. Each phone gets its own pairing.")),
                row(nil, devicesView, help: Self.help(DevicesText.sharedNote), stacked: true),
            ]),
            SettingsSection("Advanced", [row("Shared code", rotateButton, help: Self.help(DevicesText.rotateHelp))]),
        ])

        build(.advanced, [
            SettingsSection("Server", [
                row("Server URL", serverURL),
                row("Pairing code", tokenStatus, help: tokenHelp),
                row("Status", serverStatus, help: serverDetail),
            ]),
            SettingsSection("Clean-up model", [row(nil, keepLoadedStack)]),
            SettingsSection("Tools", [
                row("Local models", modelsButton, help: modelsHelp),
                row("Doctor", doctorButton, help: Self.help("Copies the command that checks the server, to run in Terminal.")),
            ]),
        ])

        place(.about, about)
        for m in ActivationMode.allCases {
            mode.addItem(withTitle: m.title)
            mode.lastItem?.representedObject = m.rawValue
        }
        for m in AutoEnter.allCases {
            autoEnter.addItem(withTitle: m.title)
            autoEnter.lastItem?.representedObject = m.rawValue
        }
        for seconds in AutoStopDetector.silenceChoices {
            silence.addItem(withTitle: "After \(seconds.formatted(.number.precision(.fractionLength(0...1)))) s of quiet")
            silence.lastItem?.representedObject = seconds
        }
        refreshHotkeyHelp()
        configureSoundControls()
        apply(state, full: true)
    }

    private func configureSoundControls() {
        for pack in SoundPack.allCases {
            soundPack.addItem(withTitle: pack.title)
            soundPack.lastItem?.representedObject = pack.rawValue
        }
        for b in [previewStart, previewStop, chooseStart, removeStart, chooseStop, removeStop] {
            b.bezelStyle = .rounded
            b.controlSize = .small
        }
        previewStart.setAccessibilityLabel("Preview the start sound")
        previewStop.setAccessibilityLabel("Preview the stop sound")
        chooseStart.setAccessibilityLabel("Choose a start sound file")
        chooseStop.setAccessibilityLabel("Choose a stop sound file")
        removeStart.setAccessibilityLabel("Remove the custom start sound")
        removeStop.setAccessibilityLabel("Remove the custom stop sound")
        soundPack.setAccessibilityLabel("Sound pack")
        volume.isContinuous = true
        volume.setAccessibilityLabel("Volume")
        volume.widthAnchor.constraint(equalToConstant: 200).isActive = true
        volumeLabel.font = MenuStyle.font
        volumeLabel.alignment = .right
        volumeLabel.widthAnchor.constraint(equalToConstant: 40).isActive = true
        for f in [startFile, stopFile] {
            f.font = MenuStyle.font
            f.lineBreakMode = .byTruncatingMiddle
            f.widthAnchor.constraint(equalToConstant: 170).isActive = true
        }
    }

    /// The label under the slider follows it live.
    public func setVolume(_ fraction: Double) {
        volume.doubleValue = fraction * 100
        volumeLabel.stringValue = "\(SoundTiming.percent(volume: fraction))%"
    }

    /// The Custom rows show only for the Custom pack.
    public func showPack(_ pack: SoundPack) {
        if let i = soundPack.itemArray.firstIndex(where: { $0.representedObject as? String == pack.rawValue }) { soundPack.selectItem(at: i) }
        packHelp.stringValue = pack.detail
        for row in customRows { row.isHidden = pack != .custom }
    }

    /// Shows the imported files (name and length) and the trimming warning; `error` replaces the warning once.
    public func setCustomSounds(start: CustomSound?, stop: CustomSound?, error: String? = nil) {
        customStartSound = start
        customStopSound = stop
        soundError = error
        startFile.stringValue = start.map { "\($0.displayName) · \(SoundTiming.durationText($0.duration))" } ?? "None (uses Chirp)"
        stopFile.stringValue = stop.map { "\($0.displayName) · \(SoundTiming.durationText($0.duration))" } ?? "None (uses Chirp)"
        // The fixed-width labels truncate a long name in the middle; the tooltip shows it whole.
        startFile.toolTip = start.map { _ in startFile.stringValue }
        stopFile.toolTip = stop.map { _ in stopFile.stringValue }
        startFile.textColor = start == nil ? .secondaryLabelColor : .labelColor
        stopFile.textColor = stop == nil ? .secondaryLabelColor : .labelColor
        removeStart.isEnabled = start != nil
        removeStop.isEnabled = stop != nil
        if let error {
            customStartHelp.stringValue = error
            customStartHelp.textColor = .systemRed
        } else if let start, SoundTiming.isTrimmed(.start, duration: start.duration) {
            customStartHelp.stringValue = "\(SoundTiming.longStartWarning) Yours is \(SoundTiming.durationText(start.duration))."
            customStartHelp.textColor = MenuStyle.textColor(.warning)
        } else {
            customStartHelp.stringValue = SoundTiming.longStartWarning
            customStartHelp.textColor = .secondaryLabelColor
        }
    }

    /// Lays `sections` out as `tab`'s page: the title, then each section's heading and card.
    private func build(_ tab: SettingsTab, _ sections: [SettingsSection]) {
        let page = NSStackView()
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = ChirpSpacing.s24
        page.addArrangedSubview(SettingsPageTitle(tab.title))
        for section in sections { page.addArrangedSubview(section.view()) }
        page.setCustomSpacing(ChirpSpacing.s16, after: page.arrangedSubviews[0])
        place(tab, page)
    }

    /// `body` 20 pt from the top, the sides and the bottom of the page.
    private func place(_ tab: SettingsTab, _ body: NSView) {
        body.translatesAutoresizingMaskIntoConstraints = false
        let view = SettingsContentView()
        view.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: view.topAnchor, constant: Self.margin),
            view.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: Self.margin),
            body.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Self.margin),
            view.widthAnchor.constraint(equalToConstant: Self.pageWidth),
        ])
        if tab == .about { body.centerXAnchor.constraint(equalTo: view.centerXAnchor).isActive = true }
        bodies[tab] = body
        tabViews[tab] = view
    }

    /// The page for `tab`.
    public func view(for tab: SettingsTab) -> SettingsContentView { tabViews[tab]! }

    /// The size `tab` needs: the common page width and its own body's height plus the margins. Measured on the bodies,
    /// not the content views, because the window sizes the content view (its fitting size would just echo that).
    public func fittingSize(for tab: SettingsTab) -> NSSize {
        NSSize(width: Self.pageWidth, height: bodies[tab]!.fittingSize.height + 2 * Self.margin)
    }

    /// Fills the window. The periodic refresh passes `full: false` so it only follows the server and permission
    /// states and never overwrites what the user is typing or a login-item error shown under the checkbox.
    public func apply(_ s: SettingsState, full: Bool = false) {
        privateSession.state = s.privateSession ? .on : .off
        if full {
            fillHotkeyMenu(selecting: s.hotkey, taken: ChirpShortcut.dictation.taken(s.combo(for:)))
            showShortcuts(s)
            alwaysInDock.state = s.alwaysShowInDock ? .on : .off
            showMode(s.activationMode, silence: s.autoStopSilence)
            autoEnter.selectItem(at: AutoEnter.allCases.firstIndex(of: s.autoEnter) ?? 0)
            sounds.state = s.soundsEnabled ? .on : .off
            showPack(s.soundPack)
            setVolume(s.soundVolume)
            setCustomSounds(start: s.customStart, stop: s.customStop)
            serverURL.stringValue = s.serverURL
            launch.state = s.launch == .on ? .on : .off
            launch.isEnabled = s.launch != .unavailable
            spokenCommands.state = s.spokenCommands ? .on : .off
            wordWaveform.state = s.wordWaveform ? .on : .off
            if let i = NotesRetention.allCases.firstIndex(of: s.notesRetention) { notesRetention.selectItem(at: i) }
            historyEnabled.state = s.historyEnabled ? .on : .off
            if let i = DictationRetention.allCases.firstIndex(of: s.historyRetention) { historyRetention.selectItem(at: i) }
            historyApps.setApps(s.historyExcludedApps)
            learnFromEdits.state = s.learnFromEdits ? .on : .off
            keepAudio.state = s.notesKeepAudio ? .on : .off
            allowRetranscribe.state = s.notesAllowRetranscribe ? .on : .off
            allowRetranscribe.isEnabled = s.notesKeepAudio || s.notesAudioBytes > 0
            callAudio.state = s.notesCallAudio ? .on : .off
            structureNotes.state = s.structureNotes ? .on : .off
            autoReorganize.state = s.autoReorganize ? .on : .off
            exportFolder.stringValue = s.exportFolder.map { Self.displayPath($0) } ?? "Last used"
            exportFolder.toolTip = s.exportFolder.map { Self.displayPath($0) }
            exportFolder.textColor = s.exportFolder == nil ? .secondaryLabelColor : .labelColor
            resetExport.isEnabled = s.exportFolder != nil
            launchUnavailable = s.launch == .unavailable
            setLaunchError(nil)
            style.controlSize = .regular
            cleanupEnabled.state = s.cleanupEnabled ? .on : .off
            offerRaw.state = s.offerRaw ? .on : .off
            fillStyleMenu(s.profiles, selecting: s.cleanupStyle, offered: s.serverOffersStyles)
            prompts.configure(catalog: s.catalog, overrides: s.stylePrompts, selecting: s.editingStyle)
            shownCatalog = s.catalog
            insertRawFirst.state = s.insertRawFirst ? .on : .off
            showChanges.state = s.showChanges ? .on : .off
            appStyles.setProfiles(s.profiles)
            appStyles.setRules(s.appStyles)
        } else if s.profiles.map(\.id) != shownProfileIDs {
            // The server's style list arrived after the window opened: follow it without touching what is being edited.
            let current = style.selectedItem?.representedObject as? String ?? s.cleanupStyle
            fillStyleMenu(s.profiles, selecting: current, offered: s.serverOffersStyles)
            appStyles.setProfiles(s.profiles)
        }
        if !full, s.catalog != shownCatalog {
            // The server's prompts arrived (or it went away) after the window opened. Edits are saved as they are
            // made, so reloading from the saved ones loses nothing.
            prompts.configure(catalog: s.catalog, overrides: s.stylePrompts)
            shownCatalog = s.catalog
        }
        showLibrary(deleted: s.recentlyDeletedCount, audioBytes: s.notesAudioBytes)
        showHistory(enabled: s.historyEnabled, count: s.historyCount)
        showLearning(on: s.learnFromEdits, historyOn: s.historyEnabled, summary: s.learnedSummary)
        showKeepLoaded(s.keepLoaded, host: s.serverHost)
        cleanupHelp.stringValue = s.cleanupDetail
        cleanupEnabled.isEnabled = s.cleanupAvailable
        tokenStatus.set(symbol: s.tokenPresent ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                        tone: s.tokenPresent ? .ok : .warning, text: s.tokenPresent ? "Ready" : "Not set up")
        tokenHelp.stringValue = s.tokenPresent ? "Chirp uses this code to connect to \(MacServerCopy.place(local: ServerConfig.load(urlString: s.serverURL).isLoopback))."
                                               : "No pairing code yet — start Chirp on this Mac once to create it."
        serverStatus.set(symbol: "circle.fill", tone: s.serverNotice == nil ? s.serverStatusTone : .warning,
                         text: s.serverNotice == nil ? s.serverStatus : ServerNotice.statusText)
        serverFixButton.title = s.serverNotice?.fix?.buttonTitle ?? ServerFix.restart.buttonTitle
        serverFixButton.isHidden = s.serverNotice?.fix == nil
        serverFixButton.isEnabled = s.serverFixMessage?.hasSuffix("…") != true
        let unreachable = s.serverNotice == nil && s.serverStatusTone == .error ? Self.unreachableHelp(serverURL: s.serverURL) : nil
        let detail = [s.serverNotice?.message, s.serverFixMessage, unreachable].compactMap { $0 }.joined(separator: "\n")
        serverDetail.stringValue = detail
        serverDetail.isHidden = detail.isEmpty
        modelsButton.isEnabled = ServerConfig.load(urlString: s.serverURL).isLoopback
        modelsHelp.stringValue = modelsButton.isEnabled ? "Download speech and local Qwen models, see progress, and start Chirp on this Mac."
                                                        : "Only for a server on this Mac: the URL above points to your Chirp server elsewhere."
        fillMicrophoneMenu(s.inputs, defaultInput: s.defaultInput, chosen: s.chosenInputUID)
        let (speakerSymbol, speakerTone, speakerText) = Self.speakerModelLine(s)
        speakerStatus.set(symbol: speakerSymbol, tone: speakerTone, text: speakerText)
        removeSpeakerModel.isHidden = !s.speakerModelDownloaded || s.speakerModel.isDownloading
        retrySpeakerModel.isHidden = !s.speakerModel.isFailure
        // Every refresh: the ✦ menu, a consent or Remove can flip it while Settings is open.
        labelSpeakers.state = s.speakerLabels ? .on : .off
        labelSpeakers.isEnabled = !s.speakerLabelsLocked
        labelSpeakers.toolTip = s.speakerLabelsLocked ? "Applies from the next recording: stop the current one to change it." : nil
        voicesView.apply(s.voices)
        speakerHelp.stringValue = s.speakerModelDownloaded
            ? "Labels who is talking in Live Notes, on this Mac. Remove deletes the model and turns labels off."
            : "Chirp fetches the \(s.speakerModelSize.isEmpty ? "speaker model" : "\(s.speakerModelSize) model") once, in the background, the first time you record with labels on. Recording never waits for it, and no audio leaves this Mac."
        micStatus.set(symbol: s.micGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                      tone: s.micGranted ? .ok : .warning, text: s.micGranted ? "Microphone allowed" : "Microphone not allowed")
        accessibilityStatus.set(symbol: s.accessibilityGranted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                                tone: s.accessibilityGranted ? .ok : .warning,
                                text: s.accessibilityGranted ? "Accessibility allowed" : "Accessibility not allowed")
        micButton.isHidden = s.micGranted
        accessibilityButton.isHidden = s.accessibilityGranted
    }

    /// The Speakers row's status: the model on this Mac, as it is right now.
    static func speakerModelLine(_ s: SettingsState) -> (symbol: String, tone: MenuEntry.Tone, text: String) {
        switch s.speakerModel {
        case .downloading(let f):
            return ("arrow.down.circle", .normal, "Speaker model on this Mac: downloading \(Int((f * 100).rounded()))%")
        case .failed(let message):
            return ("exclamationmark.triangle.fill", .warning,
                    message.contains("download") ? "Speaker model: couldn’t download" : "Speaker model: didn’t load")
        case .notDownloaded, .loading, .ready:
            return s.speakerModelDownloaded ? ("checkmark.circle.fill", .ok, "Speaker model on this Mac: ready")
                                            : ("circle", .normal, "Speaker model not downloaded yet")
        }
    }

    /// Recently Deleted's count and the kept-audio total, which the library reports (they change without the user
    /// touching Settings, so the periodic refresh sets them too).
    public func showLibrary(deleted: Int, audioBytes: Int) {
        deletedStatus.stringValue = deleted == 0 ? "Empty" : deleted == 1 ? "1 note" : "\(deleted) notes"
        emptyDeleted.isEnabled = deleted > 0
        audioStatus.stringValue = audioBytes == 0 ? "None" : Self.sizeText(audioBytes)
        deleteAudio.isEnabled = audioBytes > 0
        // Nothing to re-transcribe without kept audio (or a way to keep some).
        allowRetranscribe.isEnabled = keepAudio.state == .on || audioBytes > 0
    }

    /// History's on/off state follows the menu or an alert; the count changes as dictations come and go.
    public func showHistory(enabled: Bool, count: Int) {
        historyEnabled.state = enabled ? .on : .off
        historyRetention.isEnabled = enabled
        historyStatus.stringValue = HistorySettingsText.count(count)
        clearHistory.isEnabled = count > 0
    }

    /// Learning runs only while history is on; the switch says so instead of pretending.
    public func showLearning(on: Bool, historyOn: Bool, summary: String) {
        learnFromEdits.isEnabled = historyOn
        learnFromEdits.state = on && historyOn ? .on : .off
        learnHelp.stringValue = historyOn ? LearnedText.help : LearnedText.offWithoutHistory
        learnedStatus.stringValue = summary
    }

    /// "Never", "After 1 year", … as the retention popup reads.
    static func retentionTitle(_ r: NotesRetention) -> String {
        switch r {
        case .never: "Never"
        case .oneYear: "1 year"
        case .ninetyDays: "90 days"
        case .thirtyDays: "30 days"
        }
    }

    /// "12.4 MB" for a byte count (decimal units, like Finder).
    public static func sizeText(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// A folder path with the home folder shown as "~".
    static func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// The "Keep clean-up model loaded" switch, its status and help, or why it is unavailable; the periodic refresh
    /// calls this too, so it only sets what changed.
    public func showKeepLoaded(_ state: KeepLoadedState, host: String) {
        let p = KeepLoadedPresentation(state, host: host)
        keepLoaded.state = p.isOn ? .on : .off
        keepLoaded.isEnabled = p.isEnabled
        keepLoaded.setAccessibilityHelp(p.help)
        keepLoadedHelp.stringValue = p.help
        keepLoadedStatus.isHidden = p.status == nil
        if let status = p.status {
            switch p.statusTone {
            case .ok: keepLoadedStatus.set(symbol: "circle.fill", tone: .ok, text: status)
            case .busy: keepLoadedStatus.set(symbol: "circle.fill", tone: .warning, text: status)
            case .idle: keepLoadedStatus.set(symbol: "circle", tone: .normal, text: status)
            }
            keepLoadedStatus.setAccessibilityLabel("Clean-up model: \(status)")
        }
        keepLoadedError.isHidden = p.error == nil
        if let error = p.error {
            keepLoadedError.stringValue = error
            keepLoadedError.setAccessibilityLabel("Error: \(error)")
        }
    }

    /// Start/Stop Notes, Open Notes and Use raw as stored (Clean-up's Undo help names the Use raw keys too).
    public func showShortcuts(_ s: SettingsState) {
        notesShortcut.show(s.notesHotkey)
        openNotes.show(s.openNotesHotkey)
        useRawShortcut.show(s.useRawHotkey)
        offerRawHelp.stringValue = "Puts the original words back, with \(s.useRawHotkey.title) or from the menu."
    }

    /// The other shortcut rows by role.
    public func controls(for shortcut: ChirpShortcut) -> ShortcutControls? {
        switch shortcut {
        case .dictation: nil
        case .notes: notesShortcut
        case .openNotes: openNotes
        case .useRaw: useRawShortcut
        }
    }

    /// The presets, plus the recorded shortcut when one is in use, with `current` selected. A preset another Chirp
    /// shortcut already has (`taken`) is disabled and says which.
    public func fillHotkeyMenu(selecting current: KeyCombo, taken: [(owner: String, combo: KeyCombo)] = []) {
        shownHotkey = current
        refreshHotkeyHelp()
        hotkey.removeAllItems()
        hotkey.autoenablesItems = false
        for combo in KeyCombo.presets + (current.isCustom ? [current] : []) {
            hotkey.addItem(withTitle: combo.isCustom ? "\(combo.title) (custom)" : combo.title)
            hotkey.lastItem?.representedObject = combo.id
            if combo != current, let why = HotKeyValidation.conflict(combo, with: taken) {
                hotkey.lastItem?.isEnabled = false
                hotkey.lastItem?.toolTip = why.reason
            }
        }
        if let index = hotkey.itemArray.firstIndex(where: { $0.representedObject as? String == current.id }) {
            hotkey.selectItem(at: index)
        }
    }

    /// Follow System Default (naming the default), then every input with the picked one selected; a picked device
    /// that is unplugged shows the default, as the menu does. Rebuilt only when something changed, so the periodic
    /// refresh never disturbs it.
    public func fillMicrophoneMenu(_ inputs: [AudioInput], defaultInput: AudioInput?, chosen: String?) {
        let key = [defaultInput?.name ?? "", chosen ?? ""] + inputs.map { "\($0.uid)\t\($0.name)" }
        guard key != shownMicrophones, let menu = microphone.menu else { return }
        shownMicrophones = key
        menu.removeAllItems()
        // Items go straight into the menu: `addItem(withTitle:)` would merge two devices with the same name.
        menu.addItem(NSMenuItem(title: defaultInput.map { "Follow System Default (\($0.name))" } ?? "Follow System Default", action: nil, keyEquivalent: ""))
        if !inputs.isEmpty { menu.addItem(.separator()) }
        for input in inputs {
            let item = NSMenuItem(title: input.name, action: nil, keyEquivalent: "")
            item.representedObject = input.uid
            menu.addItem(item)
        }
        let picked = InputSelection.resolve(chosen: chosen, available: inputs)
        microphone.selectItem(at: picked.flatMap { p in menu.items.firstIndex { $0.representedObject as? String == p.uid } } ?? 0)
        microphone.isEnabled = !inputs.isEmpty || defaultInput != nil
    }

    /// The styles, with `current` selected (an id the server no longer lists stays selectable, so it is not silently changed).
    public func fillStyleMenu(_ profiles: [CorrectionProfile], selecting current: String, offered: Bool = true) {
        var list = profiles
        if !list.contains(where: { $0.id == current }) {
            list.append(CorrectionProfile(id: current, name: CorrectionProfile.displayName(for: current)))
        }
        shownProfileIDs = profiles.map(\.id)
        style.removeAllItems()
        for p in list {
            style.addItem(withTitle: p.name)
            style.lastItem?.representedObject = p.id
            style.lastItem?.toolTip = p.description
        }
        if let i = list.firstIndex(where: { $0.id == current }) { style.selectItem(at: i) }
        let chosen = list.first { $0.id == current }
        var text = chosen?.description ?? ""
        if chosen?.rewrites == true { text += (text.isEmpty ? "" : " ") + "May restructure your text." }
        if !offered { text = "This server does not offer styles yet; update chirp-server to use them." }
        styleHelp.stringValue = text
    }

    /// Selects `mode` and the auto-stop pause (the nearest offered one), which only matters in auto-stop.
    public func showMode(_ m: ActivationMode, silence seconds: TimeInterval) {
        if let i = mode.itemArray.firstIndex(where: { $0.representedObject as? String == m.rawValue }) { mode.selectItem(at: i) }
        modeHelp.stringValue = m.help(singleModifierKey: shownHotkey.isSingleModifierKey)
        let nearest = AutoStopDetector.silenceChoices.enumerated().min { abs($0.element - seconds) < abs($1.element - seconds) }
        if let nearest { silence.selectItem(at: nearest.offset) }
        silence.isEnabled = m == .autoStop
    }

    private func refreshHotkeyHelp() {
        if let raw = mode.selectedItem?.representedObject as? String, let m = ActivationMode(rawValue: raw) {
            modeHelp.stringValue = m.help(singleModifierKey: shownHotkey.isSingleModifierKey)
        }
        fnKeySetupRow?.isHidden = !(shownHotkey.isModifierOnly && shownHotkey.modifiers == ModifierKeys.fn)
        hotkeyHelp.textColor = .secondaryLabelColor
        switch recorder.status {
        case .idle:
            hotkeyHelp.stringValue = shownHotkey.isModifierOnly
                ? "Only on its own; with another key (\(HotKeyValidation.modifierSymbols(shownHotkey.modifiers))←) it does nothing. Esc cancels."
                : "Any key combination, or a modifier alone like ⌥. Esc cancels."
        case .recording: hotkeyHelp.stringValue = "Press the shortcut, or press and release a modifier such as ⌥. Esc gives up."
        case .rejected(let why):
            hotkeyHelp.stringValue = why.reason
            hotkeyHelp.textColor = .systemRed
        }
    }

    /// Under an unreachable server: which address did not answer and what to try next.
    public static func unreachableHelp(serverURL: String) -> String {
        let config = ServerConfig.load(urlString: serverURL)
        let address = config.baseURL.port.map { "\(config.host):\($0)" } ?? config.host
        return config.isLoopback
            ? "Nothing answers at \(address). Start Chirp on this Mac in Manage Local Models…, or run Copy Doctor Command in Terminal to see why."
            : "Nothing answers at \(address). Check that your Chirp server is running and on your tailnet, or run the Doctor command there."
    }

    /// Shows why toggling launch at login failed under the checkbox; nil restores the usual help text.
    public func setLaunchError(_ message: String?) {
        if let message {
            launchHelp.stringValue = "Couldn’t change it: \(message)"
            launchHelp.textColor = .systemRed
        } else {
            launchHelp.stringValue = launchUnavailable ? "Available when Chirp runs from its app bundle."
                                                       : "Opens Chirp when you log in."
            launchHelp.textColor = .secondaryLabelColor
        }
    }

    // MARK: pieces

    /// A file's name and length, then Choose… and Remove.
    private static func fileRow(_ name: NSTextField, choose: NSButton, remove: NSButton) -> NSView {
        let stack = NSStackView(views: [name, choose, remove])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    /// What the server says about clean-up: where it runs, or that it is off.
    public static func cleanupDetail(health: Health?, local: Bool = true) -> (text: String, available: Bool) {
        guard let h = health else { return ("Needs the server. Tidies punctuation and wording before the text is inserted.", true) }
        if !h.correctionAvailable { return ("The server has clean-up turned off; see the README to enable it.", false) }
        if h.correctionLeavesMachine == true { return ("Sends the text to \(h.correctionHost ?? "a remote LLM") to tidy it.", true) }
        return ("Runs on \(MacServerCopy.place(local: local)): tidies punctuation and wording before the text is inserted.", true)
    }

    /// Secondary-colour help text under a control, wrapped to the control column's width.
    static func help(_ text: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = MenuStyle.secondaryFont
        f.textColor = .secondaryLabelColor
        f.preferredMaxLayoutWidth = controlWidth
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return f
    }
}

/// A status symbol, a label and an optional trailing button (hidden when it has nothing to fix).
@MainActor
private final class StatusLine: NSStackView {
    private let icon = NSImageView()
    private let text = NSTextField(labelWithString: "")
    var accessory: NSView? { didSet { if let accessory { addArrangedSubview(accessory) } } }

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 6
        text.font = MenuStyle.font
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
        icon.setAccessibilityElement(false)
        addArrangedSubview(icon)
        addArrangedSubview(text)
        setCustomSpacing(10, after: text)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    func set(symbol: String, tone: MenuEntry.Tone, text string: String) {
        icon.image = MenuStyle.symbol(symbol, tone: tone)
        icon.contentTintColor = tone == .normal ? .tertiaryLabelColor : nil
        text.stringValue = string
    }
}
