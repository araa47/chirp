import AVFoundation
import ChirpCore
import Foundation
import Observation

/// What the library sidebar has selected: a note, or the Recently Deleted list pinned at its bottom.
public enum NotesSidebarItem: Hashable, Sendable {
    case note(UUID)
    case recentlyDeleted

    public var noteID: UUID? { if case .note(let id) = self { id } else { nil } }
}

/// A date group of the library list: Today, Yesterday, Previous 7 Days, Previous 30 Days, then one per month.
public struct NotesGroup: Identifiable, Equatable, Sendable {
    public var title: String
    public var entries: [NotesLibraryEntry]
    public var id: String { title }
}

/// The library list's wording and grouping, in one place so the sidebar, the snapshots and the tests agree.
public enum NotesLibraryText {
    public static let recording = "Recording"
    public static let recentlyDeleted = "Recently Deleted"
    public static let emptyTitle = "Your notes will live here"
    public static let emptyBody = "Record a meeting or a thought, or start typing. Chirp turns what you say into notes."
    public static let emptyPrivacy = "Notes stay on this Mac."
    public static let newNote = "New Note"
    public static let untitled = "Untitled note"
    public static let deleted = "Note deleted"
    public static let recovered = "Recovered"
    public static let stopAndContinue = "Stop Current and Continue Here"
    public static let continueRecording = "Continue Recording"
    public static let cannotDeleteRecording = "Stop recording before deleting this note"
    public static let trashEmpty = "Nothing in Recently Deleted"
    public static let trashHelp = "Deleted notes stay here for \(NotesLibraryStore.recentlyDeletedDays) days, then they’re gone for good."
    public static let emptyTrash = "Empty Recently Deleted…"
    public static let emptyTrashTitle = "Empty Recently Deleted?"
    public static let deletePermanently = "Delete Permanently"
    public static func emptyTrashMessage(_ count: Int) -> String {
        "\(results(count)) and their audio will be deleted for good. This can’t be undone."
    }

    public static func noResults(_ query: String) -> String { "No results for “\(query)”" }
    public static func results(_ count: Int) -> String { count == 1 ? "1 note" : "\(count) notes" }
    /// "☐ 3 open": the note's open to-dos.
    public static func open(_ count: Int) -> String { "\(count) open" }
    /// "Continued · Oct 24, 3:12 PM": the quiet divider a Continue recording leaves in the transcript.
    public static func continued(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "MMM d, h:mm a"
        return "Continued · " + f.string(from: date)
    }
    /// "Stop “Weekly sync” and continue recording here?"
    public static func switchPrompt(_ recording: String) -> String { "Stop “\(recording)” and continue recording here?" }
    /// "Deleted 3 days ago · 27 days left".
    public static func daysLeft(deletedAt: Date, now: Date) -> String {
        let days = max(0, NotesLibraryStore.recentlyDeletedDays - Int(now.timeIntervalSince(deletedAt) / 86400))
        return days == 1 ? "1 day left" : "\(days) days left"
    }

    /// The groups, newest first inside each. `now` and `calendar` are injectable so the tests and snapshots are fixed.
    public static func groups(_ entries: [NotesLibraryEntry], now: Date, calendar: Calendar = .current) -> [NotesGroup] {
        let today = calendar.startOfDay(for: now)
        func daysAgo(_ date: Date) -> Int { calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: today).day ?? 0 }
        let month = DateFormatter()
        month.calendar = calendar
        month.timeZone = calendar.timeZone
        month.locale = Locale(identifier: "en_US_POSIX")
        var groups: [NotesGroup] = []
        for entry in entries.sorted(by: { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }) {
            let ago = daysAgo(entry.updatedAt)
            let title: String
            switch ago {
            case ...0: title = "Today"
            case 1: title = "Yesterday"
            case 2...7: title = "Previous 7 Days"
            case 8...30: title = "Previous 30 Days"
            default:
                month.dateFormat = calendar.isDate(entry.updatedAt, equalTo: now, toGranularity: .year) ? "MMMM" : "MMMM yyyy"
                title = month.string(from: entry.updatedAt)
            }
            if groups.last?.title == title { groups[groups.count - 1].entries.append(entry) } else {
                groups.append(NotesGroup(title: title, entries: [entry]))
            }
        }
        return groups
    }

    /// A row's time: "3:12 PM" today, "Yesterday", "Tuesday" this week, else "Oct 3" (or "Oct 3, 2025").
    public static func relative(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        let ago = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch ago {
        case ...0: f.dateFormat = "h:mm a"
        case 1: return "Yesterday"
        case 2...6: f.dateFormat = "EEEE"
        default: f.dateFormat = calendar.isDate(date, equalTo: now, toGranularity: .year) ? "MMM d" : "MMM d, yyyy"
        }
        return f.string(from: date)
    }

    /// A snippet as reading text: the library keeps the note's Markdown with its whitespace collapsed; the list shows
    /// "Agenda · Lantern kickoff · Share the doc" instead of "## Agenda - Lantern kickoff - [x] Share the doc".
    public static func plain(_ snippet: String) -> String {
        var s = " " + snippet
        // Headings and list marks (with any task box) start a new item.
        s = s.replacingOccurrences(of: #"\s(#{1,6}|[-*+](\s\[[ xX]\])?|\d{1,3}[.)])\s"#, with: " · ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\*\*|__"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(^|\s)_(\S)"#, with: "$1$2", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\S)_(\s|$|[.,;:!?])"#, with: "$1$2", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\s·)+"#, with: " ·", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespaces)
        while s.hasPrefix("·") { s = String(s.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return s
    }

    /// A duration for the meta line: "45 s", "12 min", "1 h 05 min".
    public static func duration(_ seconds: TimeInterval) -> String? {
        guard seconds >= 1 else { return nil }
        let s = Int(seconds)
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min" }
        return "\(s / 3600) h \(String(format: "%02d", s / 60 % 60)) min"
    }

    /// A file size for the note's audio: "1.2 MB".
    public static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// What a toast's buttons act on besides a deleted note: a re-transcribed note ("Transcript updated · Show Changes ·
/// Undo") or its rebuilt notes ("Notes rebuilt · Show Changes · Undo").
public enum NotesToastAction: Equatable, Sendable {
    case transcript(UUID)
    case rebuild(UUID)
}

/// The toast at the bottom of the window ("Note deleted · Undo").
public struct NotesToast: Equatable, Sendable {
    public var text: String
    /// The note Undo brings back; nil for a toast without Undo.
    public var undo: UUID?
    /// Bumped per toast, so a newer one restarts the timer.
    public var serial: Int
    public var action: NotesToastAction?
}

/// The Live Notes window around the note: the library list, search, selection, the inspector and Show Markdown, the
/// toast and the confirmations. The note itself is a `NotesModel` (the recorder's, or one opened beside a recording).
@MainActor @Observable
public final class NotesLibraryModel {
    /// The library, newest first, and Recently Deleted (mirrored from `NotesLibrary` by the session).
    public var notes: [NotesLibraryEntry] = []
    public var deleted: [NotesLibraryEntry] = []
    /// The note that is recording (or paused, or finishing), pinned above the date groups.
    public var recordingID: UUID?
    public var selection: NotesSidebarItem?
    /// What the search field holds, and its results (nil while it is empty).
    public var query = "" { didSet { if query != oldValue { onQuery(query) } } }
    public var results: [NotesSearchResult]?
    /// The row being renamed inline, and what is typed in it.
    public var renaming: UUID?
    public var renameText = ""
    public var toast: NotesToast?
    private var toastSerial = 0
    /// View ▸ Bigger/Smaller Text: this window's content size (the editor, transcript, library and banners).
    public let textSize = ChirpTextSize()
    /// View ▸ Read Formatted Note: the note without Markdown syntax, its tasks as checkboxes.
    public var readingNote = false
    /// Delete Now in Recently Deleted waits for this confirmation.
    public var confirmingPurge: NotesLibraryEntry?
    /// The library list has keyboard focus (AppKit's first responder), drawn apart from the selection.
    public var sidebarFocused = false
    /// The window is too narrow for a transcript column, so the transcript sits under the note. The window's creator
    /// seeds it from the window size, so a window that opens narrow (or wide) never flips its inspector on the first
    /// layout; `windowResized` keeps it current.
    public var transcriptBelow = false
    var transcriptBelowHeight = NotesViewMetrics.compactTranscriptHeight(windowHeight: NotesViewMetrics.minimumSize.height)
    /// The transcript's last size while it sat under the note in a narrow window; for tests.
    @ObservationIgnored var compactTranscriptSize = CGSize.zero

    public func windowResized(_ size: CGSize) {
        let below = NotesViewMetrics.compactTranscript(windowWidth: size.width)
        if below != transcriptBelow { transcriptBelow = below }
        let height = NotesViewMetrics.compactTranscriptHeight(windowHeight: size.height)
        if height != transcriptBelowHeight { transcriptBelowHeight = height }
    }
    /// The transcript inspector (⌥⌘T) and View ▸ Show Markdown.
    public var showsInspector = false
    public var showMarkdown = false
    /// Empty Recently Deleted asks once.
    public var confirmingEmpty = false
    /// Continue recording on this note while another one records: "Stop current and continue here".
    public var confirmingSwitch: UUID?
    /// A note opened while another records: the recorder keeps its own document, this one is edited on its own.
    public var browsed: NotesModel?
    /// Re-transcribe (#287): the consent sheet on offer, the run (one at a time), Show changes, and "Replace your
    /// edits?" for a rebuild that would overwrite typing. `retranscribeAllowed` is Settings → Notes → Allow
    /// re-transcribing: off hides every entry point.
    public var retranscribeOffer: NotesRetranscribeOffer?
    public var retranscribeRun: NotesRetranscribeRun?
    public var transcriptChanges: NotesTranscriptChanges?
    public var confirmingRebuild: UUID?
    public var retranscribeAllowed = false
    /// Segment playback in the transcript.
    public let player = NotesPlayer()
    /// The clock and calendar for the groups and relative times (fixed in snapshots and tests).
    @ObservationIgnored public var now: () -> Date = { Date() }
    @ObservationIgnored public var calendar = Calendar.current

    public var onSelect: (NotesSidebarItem?) -> Void = { _ in }
    public var onNew: () -> Void = {}
    public var onRename: (UUID, String) -> Void = { _, _ in }
    public var onTrash: (UUID) -> Void = { _ in }
    public var onRestore: (UUID) -> Void = { _ in }
    public var onPurge: (UUID) -> Void = { _ in }
    public var onEmptyTrash: () -> Void = {}
    /// Continue recording on a finished note (asks first while another note records).
    public var onContinue: (UUID) -> Void = { _ in }
    public var onStopAndContinue: (UUID) -> Void = { _ in }
    public var onQuery: (String) -> Void = { _ in }
    /// Re-transcribe… for a note, or one segment of it (Transcribe Again…): opens the consent sheet.
    public var onRetranscribe: (UUID, Int?) -> Void = { _, _ in }
    public var onRetranscribeStart: (NotesRetranscribeOffer) -> Void = { _ in }
    public var onRetranscribeCancel: () -> Void = {}
    public var onRetranscribeApplyPartial: () -> Void = {}
    public var onRetranscribeDismiss: () -> Void = {}
    /// Undo and Restore Previous Transcript.
    public var onRestoreTranscript: (UUID) -> Void = { _ in }
    public var onShowTranscriptChanges: (UUID) -> Void = { _ in }
    /// The rebuild toast's Show Changes and Undo, and "Replace your edits?".
    public var onShowRebuild: (UUID) -> Void = { _ in }
    public var onUndoRebuild: (UUID) -> Void = { _ in }
    public var onConfirmRebuild: (Bool) -> Void = { _ in }
    /// The sheet's Change model… (Manage Local Models).
    public var onManageModels: () -> Void = {}
    /// A refused re-transcribe's Server Settings….
    public var onServerSettings: () -> Void = {}
    /// The window focuses its search field (⌥⌘F).
    @ObservationIgnored public var onFocusSearch: () -> Void = {}
    /// Show Markdown and the inspector are remembered.
    public var onShowMarkdown: (Bool) -> Void = { _ in }
    public var onInspector: (Bool) -> Void = { _ in }

    public init() {}

    /// The note in the detail: the one opened beside a recording, or the recorder's.
    public func displayed(_ active: NotesModel) -> NotesModel { browsed ?? active }

    public func showToast(_ text: String, undo: UUID? = nil, action: NotesToastAction? = nil) {
        toastSerial += 1
        toast = NotesToast(text: text, undo: undo, serial: toastSerial, action: action)
    }

    /// A re-transcribe holds this note: its transcript is read-only, and Continue recording waits.
    public func isRetranscribing(_ id: UUID) -> Bool { retranscribeRun?.note == id }

    /// Re-transcribe… shows for this note: allowed, it kept audio, and it is not recording.
    public func canRetranscribe(_ model: NotesModel) -> Bool {
        retranscribeAllowed && !model.keptAudio.isEmpty && !model.state.isActive && retranscribeRun == nil
    }

    /// Restore Previous Transcript shows: a re-transcribe kept a version, and no run holds the note.
    public func canRestoreTranscript(_ model: NotesModel) -> Bool {
        model.document.previousTranscript != nil && !model.state.isActive && !isRetranscribing(model.document.id)
    }

    /// Only confirmation can cross the irreversible purge boundary. Stale requests are harmless.
    public func requestPurge(_ id: UUID) { confirmingPurge = deleted.first { $0.id == id } }
    public func resolvePurge(confirm: Bool) {
        let request = confirmingPurge
        confirmingPurge = nil
        guard confirm, let id = request?.id, deleted.contains(where: { $0.id == id }) else { return }
        onPurge(id)
    }

    public func setInspector(_ on: Bool) {
        showsInspector = on
        onInspector(on)
    }

    public func setShowMarkdown(_ on: Bool) {
        showMarkdown = on
        onShowMarkdown(on)
    }

    public func select(_ item: NotesSidebarItem?) {
        guard item != selection else { return }
        renaming = nil
        selection = item
        onSelect(item)
    }

    public func beginRename(_ id: UUID) {
        renameText = entry(id)?.title ?? ""
        renaming = id
    }

    public func commitRename() {
        guard let id = renaming else { return }
        renaming = nil
        let title = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if title != entry(id)?.title { onRename(id, title) }
    }

    public func entry(_ id: UUID) -> NotesLibraryEntry? { notes.first { $0.id == id } ?? deleted.first { $0.id == id } }

    /// The note can go to Recently Deleted (not while it records).
    public func canTrash(_ id: UUID?) -> Bool { id != nil && id != recordingID && entry(id!)?.deletedAt == nil }

    /// The date groups below the Recording section. `pending` is the open note while the library hasn't kept it yet
    /// (a new note still blank, or not written yet).
    public func groups(pending: NotesLibraryEntry? = nil) -> [NotesGroup] {
        var list = notes.filter { $0.id != recordingID }
        if let pending, pending.id != recordingID, !list.contains(where: { $0.id == pending.id }) { list.append(pending) }
        return NotesLibraryText.groups(list, now: now(), calendar: calendar)
    }

    /// Names people were given in other notes, newest note first, for the Name speakers sheet's autocomplete.
    public func recentSpeakerNames(excluding note: UUID? = nil, limit: Int = 24) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for entry in notes where entry.id != note {
            for name in entry.speakerNames where seen.insert(name.lowercased()).inserted {
                out.append(name)
                if out.count == limit { return out }
            }
        }
        return out
    }

    /// "No notes yet" (the empty state) versus a library that has some.
    public var isEmpty: Bool { notes.isEmpty && recordingID == nil }
}

/// Plays a transcript paragraph's kept segment audio (`audio/<segment>.m4a`), one segment after another; the row
/// highlights while it plays. Nothing is decoded until ▶ is pressed.
@MainActor @Observable
public final class NotesPlayer: NSObject, AVAudioPlayerDelegate {
    /// The note and transcript paragraph playing, and the segment within it.
    public private(set) var playing: (note: UUID, paragraph: String)?
    public private(set) var segment: Int?
    @ObservationIgnored private var queue: [(segment: Int, url: URL)] = []
    @ObservationIgnored private var player: AVAudioPlayer?

    public func isPlaying(note: UUID, paragraph: String) -> Bool { playing?.note == note && playing?.paragraph == paragraph }

    /// ▶ on a row: plays its segments in order; ▶ on the row playing stops it.
    public func toggle(note: UUID, paragraph: String, segments: [(segment: Int, url: URL)]) {
        if isPlaying(note: note, paragraph: paragraph) { stop(); return }
        stop()
        guard !segments.isEmpty else { return }
        playing = (note, paragraph)
        queue = segments
        next()
    }

    /// For the snapshots: a row shown as playing without any audio.
    public func showPlaying(note: UUID, paragraph: String, segment: Int) {
        playing = (note, paragraph)
        self.segment = segment
    }

    public func stop() {
        player?.stop()
        player = nil
        queue.removeAll()
        playing = nil
        segment = nil
    }

    private func next() {
        guard !queue.isEmpty else { stop(); return }
        let item = queue.removeFirst()
        guard let p = try? AVAudioPlayer(contentsOf: item.url) else { next(); return }
        p.delegate = self
        player = p
        segment = item.segment
        p.play()
    }

    public nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let finished = ObjectIdentifier(player)
        MainActor.assumeIsolated { advance(after: finished) }
    }

    public nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let failed = ObjectIdentifier(player)
        MainActor.assumeIsolated { advance(after: failed) }
    }

    /// The segment that just ended was the current one: the next plays (a stale callback is ignored).
    private func advance(after ended: ObjectIdentifier) {
        if let player, ObjectIdentifier(player) == ended { next() }
    }
}
