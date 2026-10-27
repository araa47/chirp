import ChirpCore
import Foundation
import Observation

/// The Notes window's wording, in one place so the controller, the snapshots and the tests agree.
public enum NotesStatus {
    public static let connecting = "Connecting…"
    public static let listening = "Listening…"
    public static let updating = "Updating notes…"
    public static let finishing = "Finishing…"
    public static let reorganizing = "Organizing notes…"
    public static func placeholder(key: String = KeyCombo.controlOptionN.title) -> String { "Type notes, or press Record (\(key))…" }
    public static let reorganized = "Notes organized"
    public static let organized = "Organized"
    public static let organizeLabel = "Organize"
    public static let organizeHelp = "Clean up and organize notes"

    /// "Organizing notes… 2/4" while Organize works through its steps.
    public static func organizing(_ step: Int, of total: Int) -> String { "Organizing notes… \(step)/\(total)" }

    /// "Couldn’t organize 1 section (rejected: novel_name) — kept as is".
    public static func organizeFailed(_ count: Int, reason: String?) -> String {
        "Couldn’t organize \(count) section\(count == 1 ? "" : "s")\(reason.map { " (\($0))" } ?? "") — kept as is"
    }
    /// The header's line about the dictation hotkey, which drives Notes while this window is in front.
    public static func hotkeyHint(key: String, pause: Bool, paused: Bool = false) -> String {
        paused ? "\(key) to resume" : "\(key) to record · \(key) again to \(pause ? "pause" : "stop")"
    }
    public static let stopped = "Stopped"
    /// The server cannot be reached or refused the token, so the banner offers Settings › Server (a busy or slow
    /// server is not something Settings fixes).
    public static func errorOpensServerSettings(_ message: String) -> Bool {
        ["Server unreachable", "Server rejected", "token"].contains { message.contains($0) }
    }
    /// "Server offline — keeping audio (4:12) · retrying": segments wait in memory for the server.
    public static func offline(kept: TimeInterval?) -> String {
        "Chirp server offline — keeping audio" + (kept.map { " (\(clock($0)))" } ?? "") + " · retrying"
    }
    public static func catchingUp(_ segments: Int) -> String { "Catching up \(segments) segment\(segments == 1 ? "" : "s")…" }
    public static let finishingOffline = "Finishing — waiting for the server"
    public static let micSilent = "Microphone is silent (muted?)"
    public static func switchedMic(_ name: String) -> String { "Switched to \(name)" }
    public static let noMic = "No microphone — plug one in"
    public static let sleptPause = "Paused while the Mac slept"
    public static let silencePause = "Paused — the microphone was silent for 15 min"
    public static let paused = "Paused"
    public static let pause = "Pause"
    public static let resume = "Resume"
    /// The header's one-word status when the details are in the banner under it.
    public static let problem = "Problem"
    public static let tip = "Chirp writes here and may still rewrite it. Edit it and it’s yours."
    public static func structuringChip(_ host: String) -> String { "Structuring → \(host)" }
    public static let shortcutsHint = "Keyboard shortcuts: ⌘⇧R record · ⌘⇧P pause · ⌥⌘T transcript"
    public static let keepGoing = "Keep going"
    public static let stopRecording = "Stop"

    /// "Notes 1:20 behind": committed speech the notes have not caught up with.
    public static func behind(_ seconds: TimeInterval) -> String { "Notes \(clock(seconds)) behind" }

    /// "1:20", or "1:02:03" past an hour.
    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// The reminder every `NotesModel.longRunEvery` of recording.
    public static func longRun(hours: Int) -> String { "Notes has been recording for \(hours) h" }
    public static func empty(key: String = KeyCombo.controlOptionN.title) -> String { "Press Record or \(key) to start taking notes." }
    public static let keepSavingCheckbox = "Keep saving changes to this file"

    /// "Recovered unsaved notes from 14:03 (52 min)".
    public static func recovered(startedAt: Date, elapsed: TimeInterval, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "HH:mm"
        let minutes = Int(elapsed / 60)
        let length = minutes < 1 ? "under 1 min" : minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(String(format: "%02d", minutes % 60)) min"
        return "Recovered unsaved notes from \(f.string(from: startedAt)) (\(length))"
    }
    public static let speakerLabels = "Label speakers"
    public static let speakerHelp = "Labels who is talking as Person 1, Person 2… On this Mac only: voices, labels and audio never leave it. Up to 4 people; a 5th voice joins the closest one."
    /// The status line while the model is fetched in the background (it never asks first, and Record never waits).
    public static func speakerModelDownloading(size: String, percent: Int) -> String {
        "Getting the speaker model ready (\(size), once)… \(percent)%"
    }
    public static let speakerModelDownloadFailed = "Couldn’t download the speaker model."
    public static let speakerModelLoadFailed = "The speaker model on this Mac didn’t load."
    public static let speakerTurnOff = "Turn off"
    public static let speakerRetry = "Retry"
}

/// One line in the banner slot: the speaker model is downloading (`progress`) or didn't download or load (`failed`).
public struct SpeakerModelNotice: Equatable, Sendable {
    public var text: String
    public var progress: Double?
    public var failed: Bool

    public init(text: String, progress: Double?, failed: Bool) {
        self.text = text
        self.progress = progress
        self.failed = failed
    }
}

/// Sizes the views report about themselves, so a test can tell a wrapped label or a truncated chip.
public struct NotesLayoutProbe: Equatable {
    public var recordLabel = CGSize.zero
    public var structuringChip = CGSize.zero
}

/// A session the journal found at launch, waiting for Keep, Save… or Discard.
public struct RecoveryOffer: Equatable, Sendable {
    public var startedAt: Date
    public var elapsed: TimeInterval

    public init(startedAt: Date, elapsed: TimeInterval) {
        self.startedAt = startedAt
        self.elapsed = elapsed
    }

    public var text: String { NotesStatus.recovered(startedAt: startedAt, elapsed: elapsed) }
}

/// One transcript row: a paragraph (`TranscriptParagraph`), with the speaker chip where it shows.
public struct TranscriptRow: Identifiable, Equatable {
    public var paragraph: TranscriptParagraph
    /// The speaker chip's name and colour slot; nil when the chip collapses (same person as the row before).
    public var chip: (name: String, color: Int, approximate: Bool)?
    /// The last chip shown, as of this row (who, and when): where the next row's collapse rule picks up.
    var anchor: (person: Int, at: TimeInterval)?

    public var id: String { paragraph.id }
    public var offset: TimeInterval { paragraph.offset }

    public static func == (a: TranscriptRow, b: TranscriptRow) -> Bool {
        a.paragraph == b.paragraph && a.chip?.name == b.chip?.name && a.chip?.color == b.chip?.color
            && a.chip?.approximate == b.chip?.approximate
    }
}

/// A run of the Hearing strip: a person's words (with their name where the speaker changes), or unlabelled text.
public struct HearingPart: Equatable, Sendable {
    public var name: String?
    public var color: Int
    public var text: String
}

/// What the Notes window shows: a mirror of `NotesRecorder` plus the window's own choices. In memory only; the
/// controller stores just the preferences (the tab, "Structure notes", "Organize automatically" and Edit/Preview).
@MainActor @Observable
public final class NotesModel {
    /// The editor's text size when no library window owns one (the window's `NotesLibraryModel.textSize` wins).
    public let textSize = ChirpTextSize()
    /// Toggles the task whose box holds this UTF-16 offset through the attached editor's edit/Undo path (the
    /// formatted reader's checkboxes); false with no editor.
    @ObservationIgnored var toggleAccessibleTask: (Int) -> Bool = { _ in false }
    public var state: NotesRecorderState = .idle
    public var document = NotesDocument()
    public var structuring: StructuringStatus = .idle
    /// Audio recorded into the document, seconds.
    public var elapsed: TimeInterval = 0
    /// Why the session is paused when the user did not pause it ("Paused while the Mac slept").
    public var pauseReason: String?
    /// Whether segments reach the server (offline, they wait in memory).
    public var connection: NotesConnection = .online
    /// What the microphone is doing, when Notes should say so.
    public var micNotice: NotesMicNotice?
    /// The transcript shows each segment's raw text.
    public var showRaw = false
    /// The transcript pane is scrolled to its end, so new segments keep it there. Kept here rather than in `@State`:
    /// the Command Line Tools toolchain has no SwiftUI macro plugins.
    public var transcriptAtBottom = true
    /// The user's "Structure notes" toggle.
    public var structureEnabled = true
    public var privacyLine = NotesModel.libraryPrivacy
    /// Where structuring sends the text when that is off this Mac: its own chip in the footer, never truncated.
    public var structuringHost: String?
    /// The input level while recording, on the HUD's bar scale (0…1).
    public var level: Float = 0
    /// The one-time tip about the tinted AI text was shown (true until the session reads the preference).
    public var tipSeen = true
    @ObservationIgnored public var onTipSeen: () -> Void = {}
    /// What the layout last measured, for the tests (never read by the views).
    @ObservationIgnored public var probe = NotesLayoutProbe()
    /// The tooltip that spells out what the recovery copy holds (empty while it is off).
    public var privacyHelp = ""
    /// A recovered session is waiting (the banner above the notes).
    public var recovery: RecoveryOffer?
    /// A saved file is being kept up to date (the footer says so), or stopped.
    public var keepSaving: KeepSavingStatus = .off
    public var debugRetention = false
    /// The server is on this Mac, so "Manage Local Models…" can open the models window.
    public var canManageModels = false
    /// The server answered but is older than the app, and what the last attempt to fix it said.
    public var serverNotice: ServerNotice?
    public var serverFixMessage: String?
    public var reduceMotion = false
    /// A fixed Ripple phase for the snapshots; nil runs on the clock.
    public var ripplePhase: Double?
    /// The user's "Label speakers" toggle, and the model behind it.
    public var speakerLabels = false
    public var speakerModel: SpeakerModelState = .notDownloaded
    /// The model's size for the status line ("106 MB"), from the model store.
    public var speakerModelSize = ""
    /// The open rename field and what is typed in it, and the banner after a rename or merge (`SpeakerMenu`).
    public var renaming: SpeakerRename?
    public var renameText = ""
    public var speakerBanner: SpeakerBanner?
    /// The Name speakers sheet is open, and the notes whose "Who was speaking?" line was dismissed (or answered).
    var nameSpeakers: NameSpeakersState?
    public var nameLineDismissed: Set<UUID> = []
    /// Voice profiles in this document: suggestions, remembered people (`SpeakerMenu`).
    public var voices = SpeakerVoiceState()
    /// The title field's text while it is being edited (nil: it shows the note's title).
    public var titleDraft: String?
    /// The kept audio of this note's segments (`audio/<segment>.m4a`), for ▶ in the transcript.
    public var keptAudio: [Int: URL] = [:]
    /// The user's "Organize automatically" toggle.
    public var autoReorganize = true
    public var reorganizeStatus: ReorganizeStatus = .idle
    /// What the last reorganizes and Organize runs changed, for Show changes and Restore Notes Before Organize….
    public var snapshots = NotesSnapshots()
    /// The review sheet is open, on this snapshot.
    public var reviewing: Int?
    /// Restoring this snapshot would lose later edits: asks first.
    public var confirmingRestore: Int?
    /// The "Organized · Undo" chip was dismissed for the reorganize applied at this time.
    public var dismissedChip: TimeInterval?
    /// The editor has keyboard focus (set by the editor).
    public var editorFocused = false
    /// Bumped to ask the editor to take keyboard focus (the empty state was clicked, the window opened with focus).
    public var focusRequest = 0
    /// The dictation hotkey's keys ("⌥ Option"), empty until the window is shown.
    public var dictationKey = ""
    /// The Start/Stop Notes shortcut's keys, for the empty state and the editor's placeholder.
    public var notesKey = KeyCombo.controlOptionN.title
    public var hotkeyHint: String? { dictationKey.isEmpty ? nil : NotesStatus.hotkeyHint(key: dictationKey, pause: NotesHotkeyRouter.pauseAvailable, paused: isPaused) }
    /// The transcript paragraph under the pointer: it shows each segment's timestamp.
    public var hoveredParagraph: String?
    /// A section's `[hh:mm:ss]` was clicked: the transcript scrolls to this paragraph (bumped per click) and tints it.
    public var highlightedParagraph: String?
    public var transcriptJump = 0
    /// The lag chip's popover (the Hearing text) is open.
    public var showsBacklog = false
    /// Reminders dismissed with "Keep going": one per `longRunEvery` of recording (reset by New).
    public var longRunAcknowledged = 0

    /// AI changes the editor has not replayed yet. Not observed: the editor drains them as they arrive.
    @ObservationIgnored public private(set) var pendingChanges: [NotesTextChange] = []
    /// The editor that owns the hooks below (the newest one on screen).
    @ObservationIgnored public var editorOwner: ObjectIdentifier?
    /// Set by the editor while it is on screen; called whenever changes are queued.
    @ObservationIgnored public var onPendingChanges: (() -> Void)?

    public var onRestoreSnapshot: (_ id: Int, _ confirmed: Bool) -> Void = { _, _ in }
    public var onRecordToggle: () -> Void = {}
    public var onPauseToggle: () -> Void = {}
    public var onCopy: () -> Void = {}
    public var onSave: () -> Void = {}
    public var onNew: () -> Void = {}
    public var onRecoveryKeep: () -> Void = {}
    public var onRecoverySave: () -> Void = {}
    public var onRecoveryDiscard: () -> Void = {}
    public var onManageModels: () -> Void = {}
    public var onFixServer: () -> Void = {}
    /// The error banner's Server Settings… (Settings › Server).
    public var onServerSettings: () -> Void = {}
    public var onStructureToggle: (Bool) -> Void = { _ in }
    /// A section's `[hh:mm:ss]` asks for the transcript inspector.
    public var onShowTranscript: () -> Void = {}
    /// The title field changed (a rename, saved after a pause in typing).
    public var onTitleEdit: (String) -> Void = { _ in }
    public var onSpeakerLabelsToggle: (Bool) -> Void = { _ in }
    /// The status line's Retry: remove the damaged or partial model and download it again.
    public var onSpeakerRetry: () -> Void = {}
    /// Call audio (#211): this note's sources, whether this Mac can capture call audio, the apps it can record, the
    /// explanation waiting for Continue, the call side's level and capture while recording, and what went wrong.
    public var sources = NotesSources()
    public var callAudioAvailable = false
    public var callApps: [CallAudioApp] = []
    public var explainingCallAudio: NotesSources?
    public var callLevel: Float = 0
    public var capturingCall = false
    public var callNotice: NotesCallNotice?
    /// The toolbar's Sources popover is open.
    public var showsSources = false
    public var onSourcesChange: (NotesSources) -> Void = { _ in }
    public var onCallAudioExplained: (Bool) -> Void = { _ in }
    public var onRefreshCallApps: () -> Void = {}
    public var onOpenCallAudioSettings: () -> Void = {}
    /// The source picker can change: only between recordings.
    public var canChangeSources: Bool { !state.isActive }
    /// The call notice under the toolbar while recording.
    public var callNote: String? {
        guard state.isCapturing, let callNotice else { return nil }
        return NotesSourcesText.notice(callNotice)
    }
    public var onSpeakerEdit: (SpeakerEdit) -> Void = { _ in }
    /// The editor changed the text: the range (UTF-16, in the old text) and its replacement.
    @ObservationIgnored public var onUserEdit: (NSRange, String, NotesTextChange.Kind) -> Void = { _, _, _ in }
    public var onReorganize: () -> Void = {}
    public var onAutoReorganizeToggle: (Bool) -> Void = { _ in }
    /// The caret is in the AI tail with focus, and whether IME is composing.
    @ObservationIgnored public var onEditorFocus: (_ inTail: Bool, _ composing: Bool) -> Void = { _, _ in }
    /// Set by the editor: undoes the last reorganize if it is still the top undo group (the chip's Undo).
    @ObservationIgnored public var undoReorganize: () -> Void = {}
    /// Voice edit (#97, `NotesVoiceEditModel.swift`): its status, whether the server offers it and the button works.
    public var voiceEdit: NotesVoiceEditStatus = .idle
    public var voiceEditAvailable = false
    public var canVoiceEdit = false
    public var onVoiceEdit: () -> Void = {}
    public var onVoiceEditCancel: () -> Void = {}
    public var onVoiceEditDismiss: () -> Void = {}
    /// Set by the editor: undoes the voice edit if it is still the top undo group, and reads the selection.
    @ObservationIgnored public var undoEdit: () -> Void = {}
    @ObservationIgnored public var editorSelection: () -> NSRange? = { nil }

    public var libraryEnabled = false
    public var exportTitle: String { libraryEnabled ? "Export Markdown…" : "Save…" }
    public static let libraryPrivacy = "Notes stay on this Mac and save automatically."
    public static let libraryPrivacyHelp = "Stored locally in Application Support/Chirp/Notes with owner-only permissions. Audio is kept only when enabled."

    public init() {}

    /// Queues AI changes for the editor. With no editor on screen they are dropped: an editor that appears loads
    /// `document.text` as it is then.
    public func enqueue(_ changes: [NotesTextChange]) {
        guard !changes.isEmpty, let sink = onPendingChanges else { return }
        pendingChanges += changes
        sink()
    }

    public func takePendingChanges() -> [NotesTextChange] {
        defer { pendingChanges.removeAll() }
        return pendingChanges
    }

    public var isRecording: Bool { state.isCapturing }
    public var isPaused: Bool { state == .paused }
    public var isBusy: Bool { state == .stopping }
    public var hasContent: Bool { !document.isEmpty }
    /// Record or Stop can be pressed (not while the last segment finishes).
    public var canToggle: Bool { !isBusy }
    public var canExport: Bool { hasContent && !isBusy }
    /// The note has something in it (a blank note is simply not kept).
    public var isBlank: Bool { document.isEmpty && document.segments.isEmpty && document.userTitle == nil }

    /// The title the window and the title field show: the user's, else derived, else "New Note" while blank.
    public var displayTitle: String { isBlank ? NotesLibraryText.untitled : document.title }

    public var elapsedText: String {
        let s = max(0, Int(elapsed))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    public var isError: Bool { if case .error = state { true } else { false } }

    public var statusText: String {
        if !isError, let text = voiceEditStatusText { return text }
        return switch state {
        case .idle: ""
        case .starting: NotesStatus.connecting
        case .recording:
            recordingNotice(clock: true) ?? (isReorganizing ? reorganizingText : structuring == .running ? NotesStatus.updating : NotesStatus.listening)
        case .stopping:
            (isReorganizing ? reorganizingText : connection.isOffline ? NotesStatus.finishingOffline : NotesStatus.finishing) + finishingSuffix
        case .stopped where isReorganizing, .idle where isReorganizing: reorganizingText
        case .paused: "\(pauseReason ?? NotesStatus.paused) · \(elapsedText)"
        case .stopped: NotesStatus.stopped
        case .error(let message): message
        }
    }

    /// The header's status: the error's details live in the banner under the header.
    public var headerStatusText: String { isError ? NotesStatus.problem : statusText }
    /// The error banner's message.
    public var errorText: String? { if case .error(let message) = state { message } else { nil } }

    /// What keeps recording from being ordinary, most urgent first: no input, the server offline or catching up, a
    /// silent microphone, a switched one. Without `clock`, the offline line leaves out the kept time (announcements).
    func recordingNotice(clock: Bool) -> String? {
        if micNotice == .missing { return NotesStatus.noMic }
        switch connection {
        case .offline(let kept): return NotesStatus.offline(kept: clock ? kept : nil)
        case .catchingUp(let n): return NotesStatus.catchingUp(n)
        case .online: break
        }
        switch micNotice {
        case .silent: return NotesStatus.micSilent
        case .switched(let name): return NotesStatus.switchedMic(name)
        case .missing, nil: return nil
        }
    }

    /// The warning over the Hearing strip while recording: a silent or missing microphone.
    public var micNote: String? {
        guard state == .recording else { return nil }
        switch micNotice {
        case .silent: return NotesStatus.micSilent
        case .missing: return NotesStatus.noMic
        default: return nil
        }
    }

    /// An append pass is running on the AI tail.
    public var isUpdating: Bool { structuring == .running }

    public var isReorganizing: Bool { reorganizeStatus.isRunning }

    private var reorganizingText: String {
        if case .organizing(let step, let total) = reorganizeStatus { return NotesStatus.organizing(step, of: total) }
        return NotesStatus.reorganizing
    }

    /// How long Stop has been finishing, while it is (set by the controller once a second).
    public var finishingElapsed: TimeInterval?

    /// " · 12 s" once Stop has taken a few seconds, so a long finish never looks stuck.
    private var finishingSuffix: String {
        guard let e = finishingElapsed, e >= 3 else { return "" }
        return " · \(Int(e)) s"
    }

    /// The empty-state art: no notes, nothing recorded yet, and the editor not focused (a click focuses it).
    public var showsEmptyState: Bool {
        document.text.isEmpty && document.segments.isEmpty && state == .idle && !editorFocused
    }

    /// The Reorganize button can be pressed: structuring and the endpoint are available, there are notes, and no
    /// reorganize is running and the recording is not finishing.
    public var canReorganize: Bool {
        if case .unavailable = reorganizeStatus { return false }
        return !isReorganizing && !isBusy && !document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The server has structuring but no reorganize endpoint: the button is hidden and the toggle explains why.
    public var reorganizeHidden: Bool { reorganizeStatus == .unavailable(.unsupported) && !structuring.isOff }

    /// The "Organize automatically" toggle can be flipped (it shows off otherwise).
    public var autoReorganizeAvailable: Bool { !structuring.isOff && !reorganizeHidden }

    /// The small line under the editor about the last reorganize.
    public var reorganizeNote: String? {
        switch reorganizeStatus {
        case .failed(let code): "Couldn’t organize (\(code)) — will retry"
        case .organized(let failed, let reason): failed == 0 ? NotesStatus.organized : NotesStatus.organizeFailed(failed, reason: reason)
        case .conflict: "Notes changed while organizing — try again"
        case .tooLong: "Too long to organize — split the last section with a heading"
        default: nil
        }
    }

    /// The reorganize note reports a finished Organize with nothing left behind.
    public var reorganizeNoteIsSuccess: Bool { reorganizeStatus == .organized(failed: 0, reason: nil) }

    /// "Organized · Undo" shows after a reorganize until the next edit or append, a click, or 20 s.
    public var showUndoChip: Bool {
        if case .applied(let at) = reorganizeStatus { return dismissedChip != at }
        return false
    }

    public func dismissUndoChip() {
        if case .applied(let at) = reorganizeStatus { dismissedChip = at }
    }

    /// A snapshot can be restored (not while the last segment finishes).
    public var canRestore: Bool { !snapshots.items.isEmpty && !isBusy }

    /// Opens the review sheet on `id`, or the newest snapshot.
    public func review(_ id: Int? = nil) {
        guard let id = id ?? snapshots.latest?.id, snapshots.snapshot(id) != nil else { return }
        confirmingRestore = nil
        reviewing = id
    }

    public func closeReview() {
        reviewing = nil
        confirmingRestore = nil
    }

    /// Why the notes pane shows an explanation instead of notes; nil when structuring is available.
    public var explanation: String? {
        switch structuring {
        case .off(.disabled):
            "Structuring is off. Turn on “Structure notes” below to turn the transcript into headings, bullets and to-dos."
        case .off(.correctionOff):
            canManageModels
                ? "Structured notes need a correction model. Choose one in Models on this Mac, and the transcript is turned into notes as you talk."
                : "Structured notes need a correction model. Turn on clean-up on the server to get them; the transcript keeps working meanwhile."
        case .off(.unsupported):
            serverNotice.map { [$0.message, serverFixMessage].compactMap { $0 }.joined(separator: " ") + " The transcript keeps working meanwhile." }
                ?? "Structured notes need a newer Chirp server. Update chirp-server; the transcript keeps working meanwhile."
        case .off(.waiting):
            "Waiting for the server… Notes are structured once Chirp knows where the structuring model runs; the transcript keeps working meanwhile."
        default: nil
        }
    }

    /// "Manage Local Models…" is offered next to the explanation.
    /// The button that fixes an out-of-date server, next to the explanation.
    public var serverFix: ServerFix? { structuring == .off(.unsupported) ? serverNotice?.fix : nil }

    public var offersModels: Bool { structuring == .off(.correctionOff) && canManageModels }

    /// The small line under the notes after a failed append pass.
    public var retryNote: String? {
        if case .failed(let code) = structuring { return "Couldn’t update notes (\(code)) — will retry" }
        return nil
    }

    /// Structuring can run at all (the toggle is the only thing keeping it off).
    public var structuringAvailable: Bool { !structuring.isOff || structuring == .off(.disabled) }

    /// The "Hearing…" strip under the editor: what no pass has structured yet, then the live partials. Never part of
    /// the editable text.
    public var hearingText: String {
        hearingParts.map { ($0.name.map { $0 + ": " } ?? "") + $0.text }.joined(separator: " ")
    }

    /// The Hearing strip by speaker: a name only where the speaker changes; the live partial is never labelled.
    public var hearingParts: [HearingPart] {
        var parts: [HearingPart] = []
        var last: Int?
        if !structuring.isOff {
            let roster = document.roster
            for part in document.unstructuredParts where !part.text.isEmpty {
                let name = part.person.flatMap { $0 == last ? nil : roster.displayName($0) }
                parts.append(HearingPart(name: name, color: part.person.map(roster.colorIndex) ?? 0, text: part.text))
                last = part.person
            }
        }
        if !document.livePartial.isEmpty { parts.append(HearingPart(name: nil, color: 0, text: document.livePartial)) }
        return parts
    }

    /// What Copy Markdown copies: the notes, or the transcript when there are no notes.
    public var copyText: String {
        if document.notesBody.isEmpty {
            return document.exportMarkdown(includeNotes: false)
        }
        return document.exportMarkdown(includeTranscript: false)
    }

    /// What Save… writes: the notes with the transcript appendix (the transcript only without notes).
    public var saveText: String { document.exportMarkdown(includeTranscript: true) }

    /// The recorder's state, unless a start failed before the recorder ran: that error shows only while the recorder
    /// is idle, stopped or in error itself, never over Connecting/Listening/Finishing.
    public static func displayState(recorder: NotesRecorderState, startError: String?) -> NotesRecorderState {
        guard let startError, acceptsStartError(recorder) else { return recorder }
        return .error(startError)
    }

    /// A start error may be recorded only while the recorder is not starting, recording or finishing.
    public static func acceptsStartError(_ recorder: NotesRecorderState) -> Bool { !recorder.isActive }

    // MARK: speakers

    /// The banner above the notes while labels are on and the model is being fetched or is unusable; nil otherwise.
    public var speakerModelNotice: SpeakerModelNotice? {
        guard speakerLabels else { return nil }
        switch speakerModel {
        case .downloading(let f):
            return SpeakerModelNotice(text: NotesStatus.speakerModelDownloading(size: speakerModelSize, percent: Int((f * 100).rounded())),
                                      progress: f, failed: false)
        case .failed(let message):
            let download = message.contains("download")
            return SpeakerModelNotice(text: download ? NotesStatus.speakerModelDownloadFailed : NotesStatus.speakerModelLoadFailed,
                                      progress: nil, failed: true)
        case .notDownloaded, .loading, .ready: return nil
        }
    }

    /// The footer's speaker line: how many people were heard (the model's own states are `speakerModelNotice`).
    public var speakerStatus: String? {
        switch speakerModel {
        case .loading: return speakerLabels ? "Loading speaker model…" : nil
        case .downloading, .failed: return nil
        case .notDownloaded, .ready:
            guard speakerLabels else { return nil }
            let n = document.speakerCount
            return n == 0 ? nil : n == 1 ? "1 speaker" : "\(n) speakers"
        }
    }

    // MARK: long sessions

    /// The lag chip shows once the notes are this far behind the speech.
    public static let lagThreshold: TimeInterval = 60
    /// A non-blocking reminder after this long recording, and again after each further stretch. There is no cap.
    public static let longRunEvery: TimeInterval = 2 * 3600

    /// "Notes 1:20 behind" while recording with structuring on and more than `lagThreshold` of speech waiting.
    public var lagText: String? {
        guard isRecording, !structuring.isOff else { return nil }
        let lag = document.unstructuredSeconds
        return lag >= Self.lagThreshold ? NotesStatus.behind(lag) : nil
    }

    /// Whole `longRunEvery` stretches recorded so far.
    public var longRunHours: Int { Int(elapsed / Self.longRunEvery) * Int(Self.longRunEvery / 3600) }

    /// The reminder shows while recording, for each stretch not yet acknowledged.
    public var showsLongRunNotice: Bool { isRecording && Int(elapsed / Self.longRunEvery) > longRunAcknowledged }

    /// "Keep going": the reminder comes back after the next stretch.
    public func keepGoing() { longRunAcknowledged = Int(elapsed / Self.longRunEvery) }

    /// A section's `[hh:mm:ss]`: the transcript inspector opens and scrolls to the paragraph said then, and tints it.
    public func jumpToTranscript(at offset: TimeInterval) {
        guard let id = document.paragraphID(at: offset, in: transcriptRows.map(\.paragraph)) else { return }
        onShowTranscript()
        highlightedParagraph = id
        transcriptJump += 1
    }

    /// A chip reappears for the same person after this long.
    public static let chipRepeat: TimeInterval = 60

    /// The rows the transcript last showed, and what they were built from: a new segment walks only the paragraph it
    /// may extend; new labels walk again from the first relabelled segment; another document or a renamed person
    /// rebuilds them all.
    @ObservationIgnored private var rowCache: (document: UUID, segments: Int, labels: Int, roster: SpeakerRoster, rows: [TranscriptRow])?

    /// The transcript's rows, one per paragraph. A labelled paragraph has a chip, which collapses while one person
    /// keeps talking (across paragraphs too) until a minute has passed.
    public var transcriptRows: [TranscriptRow] {
        let d = document
        var paragraphs: [TranscriptParagraph] = []
        var kept: [TranscriptRow] = []
        var from = 0
        if let c = rowCache, c.document == d.id, c.roster == d.roster, c.segments <= d.segments.count, c.labels <= d.labelRevision {
            if c.segments == d.segments.count, c.labels == d.labelRevision { return c.rows }
            // Walk again from the first segment that is new or relabelled; a paragraph reaching into it keeps only
            // its earlier parts (and may grow again).
            from = min(c.segments, d.firstRelabelled(since: c.labels))
            // The last paragraph with anything before `from` is walked on from (cut to those parts): segment
            // `from` may join it.
            let seed = c.rows.lastIndex { $0.paragraph.segments.lowerBound < from }
            kept = Array(c.rows.prefix(seed ?? 0))
            if let seed, case var p = c.rows[seed].paragraph {
                if p.failure == nil { p.parts = p.parts.filter { $0.segment < from } }
                paragraphs = [p]
            }
        }
        d.extendParagraphs(&paragraphs, from: from)
        let roster = d.roster
        var rows = kept
        var anchor = kept.last?.anchor
        for p in paragraphs {
            guard let person = p.person, p.failure == nil else {
                rows.append(TranscriptRow(paragraph: p))
                anchor = nil
                continue
            }
            let same = anchor.map { $0.person == person && p.offset - $0.at < Self.chipRepeat } ?? false
            if !same { anchor = (person, p.offset) }
            rows.append(TranscriptRow(paragraph: p, chip: same ? nil : (roster.displayName(person), roster.colorIndex(person), p.approximate),
                                      anchor: anchor))
        }
        rowCache = (d.id, d.segments.count, d.labelRevision, roster, rows)
        return rows
    }

    /// The words VoiceOver hears for a status change.
    public var announcement: String {
        let text = state == .recording ? recordingNotice(clock: false) ?? statusText : statusText
        return isError ? text : text.isEmpty ? "" : "Notes: \(text)"
    }
}

/// What the microphone is doing, when Live Notes should say so.
/// What went wrong with call audio while recording.
public enum NotesCallNotice: Equatable, Sendable {
    /// The system refused to capture it: the recording has the microphone only.
    case unavailable
    /// Nothing but digital silence so far (what a refused permission delivers).
    case silent
}

/// The source picker's and call audio's wording (#211).
public enum NotesSourcesText {
    public static let title = "Sources"
    public static let microphone = "Microphone"
    public static let microphoneDetail = "Your voice and the room"
    public static let call = "Microphone + call audio"
    public static let callDetail = "Both sides of a call, with speaker labels"
    public static let from = "Call audio from"
    public static let allAudio = "All Mac audio"
    public static let locked = "Sources change between recordings."
    public static let unavailable = "Call audio isn’t available on this Mac."
    public static let privacy = "Audio stays on this Mac and your Chirp server, and is never logged. Kept audio follows Settings › Notes › Audio."
    public static let youLabel = "Your microphone is labelled “You”; voices from the call are Person 1, Person 2…"
    public static let explainTitle = "Include call audio?"
    public static let explainBody = "Chirp also records what your Mac plays (the other people on a call) beside your microphone, so both sides of a meeting are transcribed."
    public static let explainPermission = "macOS asks once to allow Chirp under Screen & System Audio Recording. Chirp only records audio while a note is recording, never the screen."
    public static let notNow = "Not Now"
    public static let continueLabel = "Continue"
    public static let openSettings = "Open System Settings"
    public static let toolbarHelp = "Sources: microphone only, or with call audio"

    /// The chip beside the record control and the meta bar: "Mic + call audio", "Mic + Zoom".
    public static func chip(_ sources: NotesSources) -> String {
        sources.callAudio ? "Mic + " + (sources.app?.name ?? "call audio") : "Mic only"
    }

    /// What the meta bar says is being captured.
    public static func capturing(_ sources: NotesSources) -> String {
        "Recording your microphone and " + (sources.app.map { "\($0.name)’s audio" } ?? "the Mac’s audio")
    }

    public static func notice(_ notice: NotesCallNotice) -> String {
        switch notice {
        case .unavailable: "Call audio is off: macOS refused it, so only the microphone records."
        case .silent: "No call audio yet. If others are talking, allow Chirp under Screen & System Audio Recording."
        }
    }
}

public enum NotesMicNotice: Equatable, Sendable {
    /// Digital zeros (a hardware mute): recording goes on.
    case silent
    /// The input went away and capture went on with this one.
    case switched(String)
    /// No input is left: recording waits for one.
    case missing
}

extension NotesConnection {
    public var isOffline: Bool { if case .offline = self { true } else { false } }
}
