import ChirpCore
import Foundation

/// Whether Chirp starts at login: the presence of its LaunchAgent.
public enum LaunchState: Equatable, Sendable {
    case on, off
    /// Not running from an app bundle (e.g. `swift run`), so there is no app to launch.
    case unavailable
}

public enum MenuAction: Equatable, Sendable {
    /// `toggleNotes` starts, stops or resumes the recording; `newNote` always starts a new one; `openNote` carries a note id.
    case togglePrivateSession, toggleDictation, toggleNotes, newNote, showNotes, openNote(String), useRaw, pickInput(String?), toggleCleanup, pickStyle(String)
    case fixServer, showSettings, editStyles, showSetup, quit
    /// v2 design only: the island in the notch, or the classic HUD.
    case toggleShowInNotch
    /// Dictation history: the window, and one recent dictation's Insert Again, Copy and Show in History (its id).
    case showHistory, insertDictation(String), copyDictation(String), openDictation(String)

    /// What the AppKit item carries to its action method.
    public var payload: String? {
        switch self {
        case .pickInput(let uid): uid
        case .pickStyle(let id): id
        case .openNote(let id): id
        case .insertDictation(let id), .copyDictation(let id), .openDictation(let id): id
        default: nil
        }
    }
}

/// One row of the menu: a title, then (for the top-level rows) a grey value or shortcut at the right.
public struct MenuEntry: Equatable, Sendable {
    public enum Tone: Sendable { case normal, ok, active, warning, error }
    public enum Mark: Sendable { case off, on, mixed }

    public var title: String
    /// The current value of a submenu row ("Default", "BOYA CM40"), right-aligned in secondary grey. Already truncated.
    public var value: String?
    /// The untruncated value, for VoiceOver, when `value` was shortened.
    public var fullValue: String?
    /// A keyboard shortcut shown in grey at the right ("⌃⌥Space").
    public var shortcut: String?
    public var tone: Tone = .normal
    /// nil for informational lines and rows that only open a submenu.
    public var action: MenuAction?
    public var mark: Mark = .off
    public var submenu: [MenuEntry]?
    public var isSeparator = false
    /// ⌘-key equivalent that really triggers the row ("," and "q"); its glyphs are the `shortcut`.
    public var keyEquivalent: String?
    /// The key equivalent also holds ⌥ (⌥⌘L for the Notes library).
    public var keyEquivalentOption = false

    public static let separator = MenuEntry(title: "", isSeparator: true)

    public var isEnabled: Bool { action != nil || submenu != nil }

    /// What VoiceOver reads: the title and the full value or shortcut.
    public var accessibilityLabel: String {
        [title, fullValue ?? value ?? shortcut].compactMap { $0 }.joined(separator: ", ")
    }
}

/// The status dot before the header's status line: lily = ready, moon = loading, record = error; paused is a hollow ring.
public enum MenuDot: Equatable, Sendable { case ready, loading, error, paused }

/// A note in the Recent Notes submenu.
public struct RecentNote: Equatable, Sendable {
    public var id: String
    public var title: String
    public var updatedAt: Date

    public init(id: String, title: String, updatedAt: Date) {
        self.id = id; self.title = title; self.updatedAt = updatedAt
    }
}

/// A dictation in the Recent Dictations submenu: a one-line preview, never logged.
public struct RecentDictation: Equatable, Sendable {
    public var id: String
    public var preview: String
    public var date: Date

    public init(id: String, preview: String, date: Date) {
        self.id = id; self.preview = preview; self.date = date
    }
}

/// The header block: the name, a one-line status and the main switch.
public struct MenuHeader: Equatable, Sendable {
    public var title = "Chirp"
    public var status: String
    public var tone: MenuEntry.Tone
    public var dot: MenuDot = .ready
    /// The switch: on while Chirp is running, off while it is paused.
    public var isOn: Bool
    /// The status line's tooltip: how to end the debug warning, for now.
    public var help: String? = nil

    public var accessibilityLabel: String { "\(title), \(status)" }
}

/// Everything the menu-bar menu shows, as plain values so the same content feeds the real `NSMenu` and the snapshots.
public struct MenuInputs: Sendable {
    public var state: DictationState = .idle
    public var health: Health?
    public var healthError: String?
    /// The server answered but is older than the app (see `ServerNotice`), and what the last fix attempt said.
    public var serverNotice: ServerNotice?
    public var serverFixMessage: String?
    public var debugRetention = false
    /// The menu's switch is off: the hotkey is released and the bird is dimmed.
    public var privateSession = false
    public var paused = false
    /// The dictation hotkey is registered (it is not while paused, or when another app owns the shortcut).
    public var hotkeyRegistered = true
    public var activationMode: ActivationMode = .autoStop
    /// Every input device, the system default among them, and the one the user picked (nil follows the default).
    public var inputs: [AudioInput] = []
    public var defaultInput: AudioInput?
    public var chosenInputUID: String?
    public var cleanupOn = false
    public var showChanges = false
    /// The v2 design is on, so "Show in Notch" is offered; `showInNotch` is its state.
    public var notchOffered = false
    public var showInNotch = true
    /// The 5-second "Use raw" window after a cleaned insertion is open; `rawOfferKey` is its hotkey when it has one.
    public var rawOfferOpen = false
    public var rawOfferKey: String?
    /// The default clean-up style (a profile id); a per-app rule can override it for one dictation.
    public var styleID = CorrectionProfile.defaultID
    public var hotkey: KeyCombo = .defaultDictation
    public var micGranted = true
    public var accessibilityGranted = true
    /// Live Notes is recording (starting or listening); `notesElapsed` is its `mm:ss`.
    public var notesRecording = false
    public var notesElapsed: String?
    /// The title of the note being recorded (or paused), for the menu's first row.
    public var notesTitle: String?
    /// Live Notes is paused (the microphone is closed, Resume continues the same notes).
    public var notesPaused = false
    /// Live Notes is finishing its last segment and pass.
    public var notesFinishing = false
    /// A notes document exists (recorded, not yet discarded with New).
    public var notesHasDocument = false
    /// The Start/Stop Notes shortcut is registered (not while paused, or when another app owns it), and its keys.
    public var notesHotkeyRegistered = true
    public var notesShortcut = KeyCombo.controlOptionN.title
    /// The "Open Notes" shortcut's keys, nil while it is not registered (paused, or another app owns it).
    public var openNotesShortcut: String?
    /// The library's newest notes (most recently modified first); the menu shows the top `MenuContent.recentLimit`.
    public var recentNotes: [RecentNote] = []
    /// Dictation history is on, and its newest dictations (the menu shows `MenuContent.recentDictationLimit`).
    public var historyEnabled = true
    public var recentDictations: [RecentDictation] = []
    /// The moment relative dates in Recent Notes are measured from.
    public var now = Date()
    public var calendar = Calendar.current

    public init() {}

    /// Something Set Up Chirp would fix: a missing permission, or a server that cannot be reached.
    public var setupIncomplete: Bool {
        !micGranted || !accessibilityGranted || (health == nil && healthError != nil)
    }
}

public enum MenuContent {
    /// Longest value shown in a row; longer ones end in "…" so a long microphone name never stretches the menu.
    public static let valueLimit = 22

    /// `text` cut to `limit` characters (grapheme clusters) with a trailing "…".
    public static func truncated(_ text: String, limit: Int = valueLimit) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// The header: the name, what Chirp is doing or what is wrong, and the switch.
    public static func header(_ m: MenuInputs) -> MenuHeader {
        let (status, tone) = statusLine(m)
        return MenuHeader(status: m.privateSession ? "Private session · " + status : status, tone: tone, dot: dot(m, tone: tone), isOn: !m.paused,
                          help: status == debugRetention ? debugRetentionHelp : nil)
    }

    /// lily = ready (including while it works), moon = loading or checking, record = error, a hollow ring = paused.
    static func dot(_ m: MenuInputs, tone: MenuEntry.Tone) -> MenuDot {
        if m.paused { return .paused }
        switch tone {
        case .error: return .error
        case .warning: return .loading
        default: return .ready
        }
    }

    /// The one-line status under the name. What Chirp is doing wins over the server's state, which wins over the
    /// debug warning; the idle line carries the hotkey.
    public static func statusLine(_ m: MenuInputs) -> (text: String, tone: MenuEntry.Tone) {
        if m.paused { return ("Paused", .normal) }
        if m.notesRecording { return ("Notes · \(m.notesElapsed ?? "00:00")", .active) }
        if m.notesFinishing { return ("Notes · Finishing…", .active) }
        if m.notesPaused { return ("Notes · Paused \(m.notesElapsed ?? "00:00")", .normal) }
        switch m.state {
        case .connecting: return ("Connecting…", .active)
        case .listening: return ("Listening…", .active)
        case .finalizing: return ("Finishing…", .active)
        case .correcting: return ("Polishing…", .active)
        case .inserting: return ("Inserting…", .active)
        case .error(let message): return (message, .error)
        case .idle: break
        }
        guard let h = m.health else {
            return m.healthError == nil ? ("Checking server…", .warning) : ("Server unreachable", .error)
        }
        if h.ready == false { return ("Loading model…", .warning) }
        if m.serverNotice != nil { return ("Server out of date", .warning) }
        if m.debugRetention { return (debugRetention, .error) }
        if !m.hotkeyRegistered {
            // A tap-matched shortcut (⌥ on its own) fails only without Accessibility; a Carbon one, when another app owns it.
            return m.hotkey.needsEventTap && !m.accessibilityGranted ? ("Ready · hotkey needs Accessibility", .warning)
                                                                     : ("Ready · shortcut in use elsewhere", .warning)
        }
        return ("Ready · \(m.activationMode == .holdToTalk ? "hold " : "")\(m.hotkey.title)", .normal)
    }

    /// The rows below the header: what to do now (dictate, take notes), the last result's Use raw while it is on
    /// offer, the two choices people change between dictations, then Settings and Quit. Set-once preferences (sounds,
    /// the server, About) live in Settings.
    public static func entries(_ m: MenuInputs) -> [MenuEntry] {
        var out: [MenuEntry] = [.separator]

        // While Notes records (or is paused) its row leads the menu: the way to stop without opening the window.
        let notesBusy = m.notesRecording || m.notesFinishing || m.notesPaused
        if let live = liveNotesRow(m) {
            out.append(live)
            out.append(.separator)
        }

        // Dictation: the same toggle as the hotkey. Off while paused or while a dictation is wrapping up.
        // Notes holds the engine: dictation cannot start while it records (the hotkey shows a toast instead).
        let shortcut = m.paused || !m.hotkeyRegistered ? nil : m.hotkey.title
        switch m.state {
        case .idle, .error:
            out.append(MenuEntry(title: "Start Dictation", shortcut: shortcut, action: m.paused || notesBusy ? nil : .toggleDictation))
        case .connecting, .listening:
            out.append(MenuEntry(title: "Stop Dictation", shortcut: shortcut, action: .toggleDictation))
        case .finalizing, .correcting, .inserting:
            out.append(MenuEntry(title: "Start Dictation", shortcut: shortcut))
        }
        let notes = notesRows(m)
        out.append(notes[0])
        out.append(.separator)
        out += historyRows(m)
        out.append(.separator)
        out += notes.dropFirst()
        out.append(.separator)
        if m.rawOfferOpen {
            out.append(MenuEntry(title: "Use Raw for Last Dictation", shortcut: m.rawOfferKey, action: .useRaw))
            out.append(.separator)
        }

        out.append(MenuEntry(title: "Private session", value: m.privateSession ? "On · up to 1 hour" : "Off",
                             action: .togglePrivateSession, mark: m.privateSession ? .on : .off))
        if m.notchOffered {
            out.append(MenuEntry(title: "Show in Notch", value: m.showInNotch ? "On" : "Off",
                                 action: .toggleShowInNotch, mark: m.showInNotch ? .on : .off))
        }
        out.append(cleanupMenu(m))
        out.append(microphoneMenu(m))
        out.append(.separator)

        if let fix = m.serverNotice?.fix { out.append(MenuEntry(title: fix.buttonTitle, action: .fixServer)) }
        if m.setupIncomplete { out.append(MenuEntry(title: "Set Up Chirp…", action: .showSetup)) }
        out.append(MenuEntry(title: "Settings…", shortcut: "⌘,", action: .showSettings, keyEquivalent: ","))
        out.append(.separator)
        out.append(MenuEntry(title: "Quit Chirp", shortcut: "⌘Q", action: .quit, keyEquivalent: "q"))
        return out
    }

    /// The warning every surface shows while the server keeps recordings (`--debug-retain`).
    public static let debugRetention = "DEBUG: recordings kept"
    /// Where the warning comes from and how to end it (the server's `[debug] retain` or `--debug-retain`).
    public static let debugRetentionHelp = "chirp-server keeps each dictation's audio and text for a few days because it runs with --debug-retain or [debug] retain = true in server.toml. Restart it without them to stop."

    /// The first row while Notes is recording, paused or finishing: `◉ Recording "Standup" 03:12 — Stop`.
    static func liveNotesRow(_ m: MenuInputs) -> MenuEntry? {
        let title = noteTitle(m.notesTitle)
        let elapsed = m.notesElapsed ?? "00:00"
        if m.notesRecording {
            return MenuEntry(title: "◉ Recording \"\(title)\" \(elapsed) — Stop", tone: .active, action: .toggleNotes)
        }
        if m.notesFinishing {
            return MenuEntry(title: "◉ Finishing \"\(title)\" \(elapsed)…", tone: .active)
        }
        if m.notesPaused {
            return MenuEntry(title: "⏸ Paused \"\(title)\" \(elapsed) — Resume", action: m.paused || m.state.isActive ? nil : .toggleNotes)
        }
        return nil
    }

    /// A title cut for the menu: long note titles end in "…".
    static func noteTitle(_ title: String?) -> String {
        let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return truncated(t.isEmpty ? "Untitled note" : t, limit: 28)
    }

    /// How many notes Recent Notes lists.
    public static let recentLimit = 5

    /// Live Notes: New Note (always a new note; the same keys as the global shortcut) joins Start Dictation; Recent Notes and
    /// the library window follow as their own group.
    /// A new note cannot start during a dictation, while paused, while one records, or while the last session finishes.
    static func notesRows(_ m: MenuInputs) -> [MenuEntry] {
        let shortcut = m.paused || !m.notesHotkeyRegistered ? nil : m.notesShortcut
        let busy = m.notesRecording || m.notesPaused || m.notesFinishing
        let canStart = !m.paused && !m.state.isActive && !busy
        return [
            MenuEntry(title: "New Note", shortcut: shortcut, action: canStart ? .newNote : nil),
            recentNotesMenu(m),
            MenuEntry(title: "Notes Library…", shortcut: "⌥⌘L", action: .showNotes, keyEquivalent: "l", keyEquivalentOption: true),
        ]
    }

    /// How many dictations Recent Dictations lists.
    public static let recentDictationLimit = 3

    /// Dictation history: "Recent Dictations ▸" (each with Insert Again, Copy and Show in History) and the window.
    static func historyRows(_ m: MenuInputs) -> [MenuEntry] {
        var recent: [MenuEntry]
        if !m.historyEnabled {
            recent = [MenuEntry(title: "History is off")]
        } else if m.recentDictations.isEmpty {
            recent = [MenuEntry(title: "No dictations yet")]
        } else {
            recent = m.recentDictations.prefix(recentDictationLimit).map { d in
                MenuEntry(title: truncated(d.preview, limit: 36), value: relativeDate(d.date, now: m.now, calendar: m.calendar), submenu: [
                    MenuEntry(title: "Insert Again", action: m.paused || m.state.isActive ? nil : .insertDictation(d.id)),
                    MenuEntry(title: "Copy", action: .copyDictation(d.id)),
                    MenuEntry(title: "Show in History", action: .openDictation(d.id)),
                ])
            }
        }
        return [
            MenuEntry(title: "Recent Dictations", submenu: recent),
            MenuEntry(title: "Dictation History…", shortcut: "⌥⌘H", action: .showHistory, keyEquivalent: "h", keyEquivalentOption: true),
        ]
    }

    /// "Recent Notes ▸": the newest notes with a relative date each, or one dimmed line while the library is empty.
    static func recentNotesMenu(_ m: MenuInputs) -> MenuEntry {
        let notes = Array(m.recentNotes.prefix(recentLimit))
        guard !notes.isEmpty else {
            return MenuEntry(title: "Recent Notes", submenu: [MenuEntry(title: "No notes yet")])
        }
        let rows = notes.map {
            MenuEntry(title: noteTitle($0.title), value: relativeDate($0.updatedAt, now: m.now, calendar: m.calendar), action: .openNote($0.id))
        }
        return MenuEntry(title: "Recent Notes", submenu: rows)
    }

    /// "Just now", "12 min ago", "3 hr ago", "Yesterday", a weekday within the last week, else "Oct 3".
    public static func relativeDate(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3600)) hr ago" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days == 1 { return "Yesterday" }
        var format = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).locale(Locale(identifier: "en_US"))
        format = days < 7 ? format.weekday(.abbreviated) : format.month(.abbreviated).day()
        return date.formatted(format)
    }

    private static func row(_ title: String, value: String, tone: MenuEntry.Tone = .normal, submenu: [MenuEntry]?) -> MenuEntry {
        let short = truncated(value)
        return MenuEntry(title: title, value: short, fullValue: short == value ? nil : value, tone: tone, submenu: submenu)
    }

    // MARK: clean-up

    /// "Clean-up": the toggle, the styles and a way into the clean-up settings (the style editor, "Show changes" and the
    /// other set-once choices live there, not in the menu). The value is
    /// the default style, or Off. A server without clean-up gets one explanatory line and nothing to toggle.
    static func cleanupMenu(_ m: MenuInputs) -> MenuEntry {
        let edit = MenuEntry(title: "Clean-up Settings…", action: .editStyles)
        if let h = m.health, !h.correctionAvailable {
            return row("Clean-up", value: "Unavailable", submenu: [
                MenuEntry(title: "Clean-up is off on the server"), .separator, edit])
        }
        var sub = [MenuEntry(title: "Clean up Text", action: .toggleCleanup, mark: m.cleanupOn ? .on : .off), .separator]
        if m.health == nil || m.health?.correctionProfiles != nil {
            for p in CorrectionProfile.offered(by: m.health) {
                sub.append(MenuEntry(title: p.name, action: .pickStyle(p.id), mark: p.id == m.styleID ? .on : .off))
            }
            sub.append(.separator)
        }
        sub.append(edit)
        let value = m.cleanupOn ? CorrectionProfile.name(for: m.styleID, in: m.health) : "Off"
        return row("Clean-up", value: value, submenu: sub)
    }

    // MARK: microphone

    /// "Microphone": follows the system default unless one is picked and still connected.
    static func microphoneMenu(_ m: MenuInputs) -> MenuEntry {
        guard !m.inputs.isEmpty || m.defaultInput != nil else {
            return MenuEntry(title: "Microphone", value: "None", tone: .warning)
        }
        let picked = InputSelection.resolve(chosen: m.chosenInputUID, available: m.inputs)
        let value = picked?.name ?? m.defaultInput?.name ?? "System Default"
        var sub = [MenuEntry(title: "Follow System Default", action: .pickInput(nil), mark: picked == nil ? .on : .off)]
        if !m.inputs.isEmpty { sub.append(.separator) }
        sub += m.inputs.map { MenuEntry(title: $0.name, action: .pickInput($0.uid), mark: $0 == picked ? .on : .off) }
        return row("Microphone", value: value, submenu: sub)
    }

    // MARK: server

    /// The server's state in words and tone, for the Settings window.
    public static func serverStatus(health: Health?, healthError: String?, notice: ServerNotice? = nil) -> (text: String, tone: MenuEntry.Tone) {
        if notice != nil { return (ServerNotice.statusText, .warning) }
        switch health {
        case nil: return healthError == nil ? ("Checking…", .warning) : ("Unreachable", .error)
        case let h? where h.ready == false: return ("Loading model…", .warning)
        case let h?: return (h.engine ?? "Connected", .ok)
        }
    }
}
