import AppKit
import ChirpCore
import Observation

/// A day of the History list: Today, Yesterday, then the weekday and date.
public struct HistoryGroup: Identifiable, Equatable, Sendable {
    public var title: String
    public var entries: [DictationEntry]
    public var id: String { title }
}

/// The History window's words, in one place for the view, the snapshots and the tests.
public enum HistoryText {
    public static let windowTitle = "Dictation History"
    public static let searchPrompt = "Search history"
    public static let empty = "No dictations yet"
    public static let emptyDetail = "Everything you dictate is kept here on this Mac, so you can find it, copy it or insert it again."
    public static let off = "History is off"
    public static let offDetail = "Turn it on in Settings → History & privacy to keep what you dictate on this Mac."
    public static let unavailable = "History is locked"
    public static let unavailableDetail = "Chirp could not read its key from the Keychain. Unlock the Mac's login keychain and reopen this window."
    public static let cleaned = "Polished"
    public static let changes = "What clean-up changed"
    public static let changesFootnote = "Struck-through words are what you said that clean-up removed; underlined words were added or changed."
    public static let inserted = "What was inserted"
    public static let insertAgain = "Insert Again"
    public static let copy = "Copy"
    public static let copyRaw = "Copy Original"
    public static let addToNotes = "Add to Notes"
    public static let delete = "Delete"
    public static let teach = "Teach Chirp…"
    public static let teachTitle = "Teach Chirp"
    public static let teachDetail = "Edit this to what you wanted. Chirp learns the names and words you fix, and this app’s style, and uses them from the next dictation."
    public static let nothingToLearn = "Nothing to learn — fix a word or the style"
    public static func learned(_ titles: [String]) -> String { "Learned: " + titles.joined(separator: ", ") }
    public static let deleted = "Dictation deleted"
    public static let noSelection = "Select a dictation"
    /// The one-line privacy disclosure (the window's footer, Settings and onboarding).
    public static let disclosure = "History is kept on this Mac only, encrypted, and never synced. Turn it off in Settings → History & privacy."

    /// Onboarding's line under "Dictate into any app".
    public static let onboarding = "History keeps them on this Mac only, encrypted; turn it off in Settings → History & privacy."

    public static func noResults(_ query: String) -> String { "No dictations match “\(query)”" }

    /// The footer: how long dictations are kept.
    public static func keptFor(_ retention: DictationRetention) -> String {
        retention == .forever ? "Kept on this Mac until you delete them · encrypted"
                              : "Kept on this Mac for \(retention.title) · encrypted"
    }

    /// "3:12 PM".
    public static func time(_ date: Date, calendar: Calendar = .current) -> String {
        date.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).locale(Locale(identifier: "en_US")).hour().minute())
    }

    /// "4.2 s", "1 min 5 s".
    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds >= 60 else { return "\(seconds.formatted(.number.precision(.fractionLength(0...1)))) s" }
        let s = Int(seconds.rounded())
        return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s"
    }

    /// The detail's meta line: "Today at 3:12 PM · 4.2 s · Email style".
    public static func meta(_ entry: DictationEntry, now: Date, calendar: Calendar = .current) -> String {
        var parts = ["\(dayTitle(entry.date, now: now, calendar: calendar)) at \(time(entry.date, calendar: calendar))"]
        if entry.duration > 0 { parts.append(duration(entry.duration)) }
        if let style = entry.style { parts.append("\(CorrectionProfile.displayName(for: style)) style") }
        return parts.joined(separator: " · ")
    }

    /// "Today", "Yesterday", "Monday, Oct 20" this year, else "Oct 20, 2025".
    public static func dayTitle(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days <= 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        var format = Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).locale(Locale(identifier: "en_US"))
        format = calendar.isDate(date, equalTo: now, toGranularity: .year) ? format.weekday(.wide).month(.abbreviated).day()
                                                                          : format.month(.abbreviated).day().year()
        return date.formatted(format)
    }

    /// A one-line preview for the menu's Recent submenu.
    public static func menuTitle(_ entry: DictationEntry, limit: Int = 40) -> String {
        let flat = entry.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…" : flat
    }
}

/// "Dictation deleted · Undo" at the bottom of the window.
public struct HistoryToast: Equatable, Sendable {
    public var text: String
    public var undo: DictationEntry?
    public var serial: Int
}

/// What the History window shows and does. The window controller fills the actions; the snapshots and tests set
/// plain values. Dictated text lives only in `entries` (memory) and is never logged.
@MainActor @Observable public final class HistoryModel {
    public var entries: [DictationEntry] = []
    public var query = ""
    public var selection: UUID?
    public var enabled = true
    /// The Keychain refused the key: say so instead of "No dictations yet".
    public var unavailable = false
    public var retention = DictationRetention.default
    public var toast: HistoryToast?
    /// Counts the toast down; hovering it or focusing Undo pauses the countdown.
    public let toastTimer = ToastTimer()
    /// Shown for a moment after Copy / Insert Again ("Copied").
    public var flash: String?
    private var toastSerial = 0
    @ObservationIgnored public var now: () -> Date = { Date() }
    @ObservationIgnored public var calendar = Calendar.current
    /// The app icon for a bundle id (the workspace's; the snapshots draw a fixed one).
    @ObservationIgnored public var icon: (String?) -> NSImage? = { HistoryModel.workspaceIcon($0) }

    @ObservationIgnored public var onCopy: (String) -> Void = { _ in }
    @ObservationIgnored public var onInsertAgain: (DictationEntry) -> Void = { _ in }
    @ObservationIgnored public var onAddToNotes: (DictationEntry) -> Void = { _ in }
    @ObservationIgnored public var onDelete: (UUID) -> Void = { _ in }
    @ObservationIgnored public var onRestore: (DictationEntry) -> Void = { _ in }
    @ObservationIgnored public var onOpenSettings: () -> Void = {}
    /// Teach Chirp: the entry, and what the user says it should have been.
    @ObservationIgnored public var onTeach: (DictationEntry, String) -> Void = { _, _ in }
    /// Learn from my edits is on (Teach Chirp is offered).
    public var canTeach = false
    /// The Teach Chirp sheet: the dictation being taught and the text being edited.
    public var teaching: DictationEntry?
    public var teachText = ""

    public init() {}

    /// The entries the search keeps, newest first.
    public var filtered: [DictationEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return q.isEmpty ? entries : entries.filter { HistorySearch.matches($0, q) }
    }

    public var groups: [HistoryGroup] { Self.groups(filtered, now: now(), calendar: calendar) }

    public static func groups(_ entries: [DictationEntry], now: Date, calendar: Calendar = .current) -> [HistoryGroup] {
        var out: [HistoryGroup] = []
        for entry in entries.sorted(by: { $0.date > $1.date }) {
            let title = HistoryText.dayTitle(entry.date, now: now, calendar: calendar)
            if out.last?.title == title { out[out.count - 1].entries.append(entry) } else { out.append(HistoryGroup(title: title, entries: [entry])) }
        }
        return out
    }

    public var selected: DictationEntry? { selection.flatMap { id in entries.first { $0.id == id } } }

    /// New entries arrived (or went): keep the selection when it still exists, else select the newest.
    public func show(_ entries: [DictationEntry]) {
        self.entries = entries
        if selection == nil || !entries.contains(where: { $0.id == selection }) { selection = filtered.first?.id }
    }

    public func copy(_ entry: DictationEntry, raw: Bool = false) {
        onCopy(raw ? entry.raw ?? entry.text : entry.text)
        flash = "Copied"
    }

    public func beginTeaching(_ entry: DictationEntry) {
        teachText = entry.text
        teaching = entry
    }

    public func commitTeaching() {
        guard let entry = teaching else { return }
        teaching = nil
        onTeach(entry, teachText)
    }

    /// What Teach Chirp learned, for the flash beside the actions.
    public func taught(_ titles: [String]) {
        flash = titles.isEmpty ? HistoryText.nothingToLearn : HistoryText.learned(titles)
    }

    public func delete(_ id: UUID) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        let next = filtered.firstIndex { $0.id == id }.flatMap { i in
            filtered.indices.contains(i + 1) ? filtered[i + 1].id : i > 0 ? filtered[i - 1].id : nil
        }
        onDelete(id)
        entries.removeAll { $0.id == id }
        selection = next
        toastSerial += 1
        toast = HistoryToast(text: HistoryText.deleted, undo: entry, serial: toastSerial)
    }

    public func undoDelete() {
        guard let entry = toast?.undo else { return }
        toast = nil
        onRestore(entry)
        if !entries.contains(where: { $0.id == entry.id }) {
            entries.append(entry)
            entries.sort { $0.date > $1.date }
        }
        selection = entry.id
    }

    public static func workspaceIcon(_ bundleID: String?) -> NSImage? {
        guard let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
