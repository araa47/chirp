import CryptoKit
import Foundation
import Observation

/// Something Chirp learned from the user's edits: a term (theirs everywhere) or an app's style preference.
public struct LearnedItem: Codable, Sendable, Equatable, Identifiable, CustomStringConvertible {
    public enum State: String, Codable, Sendable {
        /// Seen fewer than `LearnedStore.threshold` times: not used yet.
        case learning
        case active
        /// The user turned it off (Undo): kept so the same edit does not bring it back.
        case off
    }

    public var id: UUID
    public var correction: LearnedCorrection
    /// The app the edit was made in. Style applies only there; a term applies everywhere and is listed under it.
    public var bundleID: String?
    public var appName: String?
    public var state: State
    public var count: Int
    public var firstSeen: Date
    public var lastSeen: Date
    /// The edit it was learned from (the inserted span and what the user made of it), bounded.
    public var inserted: String
    public var edited: String
    /// For a style: the raw transcript and the user's edit, the app's few-shot example.
    public var said: String?

    public init(id: UUID = UUID(), correction: LearnedCorrection, bundleID: String?, appName: String?, state: State, count: Int,
                firstSeen: Date, lastSeen: Date, inserted: String, edited: String, said: String? = nil) {
        self.id = id; self.correction = correction; self.bundleID = bundleID; self.appName = appName; self.state = state
        self.count = count; self.firstSeen = firstSeen; self.lastSeen = lastSeen; self.inserted = inserted; self.edited = edited
        self.said = said
    }

    public var description: String { "LearnedItem(<redacted>)" }
    public var appTitle: String { appName ?? bundleID ?? "All apps" }
}

/// The learned items, sealed like the history (AES-GCM, a Keychain key of its own) in
/// `~/Library/Application Support/Chirp/Learned/learned.sealed`. Serial access on this actor.
public actor LearnedStore {
    /// How many times the same correction must be seen before it is used (one Teach Chirp is enough).
    public static let threshold = 2
    /// Most items kept; the oldest still learning (then the oldest turned off) go first.
    public static let maxItems = 200
    /// Few-shot examples per app sent with `start`.
    public static let maxExamples = 3
    static let maxText = 300

    public nonisolated let directory: URL
    private let keys: HistoryKeyStore
    private let now: @Sendable () -> Date
    private var items: [LearnedItem]?
    static let fileName = "learned.sealed"
    static let context = "chirp.learned.v1:" + fileName

    public static var defaultDirectory: URL {
        NotesJournalStore.defaultDirectory.deletingLastPathComponent().appendingPathComponent("Learned", isDirectory: true)
    }

    public init(directory: URL = LearnedStore.defaultDirectory,
                keys: HistoryKeyStore = KeychainHistoryKeyStore(account: KeychainHistoryKeyStore.learnedAccount),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.keys = keys
        self.now = now
    }

    private var file: URL { directory.appendingPathComponent(Self.fileName) }

    private func key(create: Bool) throws -> SymmetricKey? {
        if let data = try keys.read(), data.count == 32 { return SymmetricKey(data: data) }
        guard create else { return nil }
        let key = SymmetricKey(size: .bits256)
        try keys.write(key.withUnsafeBytes { Data($0) })
        return key
    }

    private func load() throws {
        guard items == nil else { return }
        guard let sealed = try? Data(contentsOf: file) else { items = []; return }
        guard let key = try key(create: false),
              let plain = try? NotesJournalCodec.aesGCM(key: key, context: Self.context).open(sealed),
              let decoded = try? JSONDecoder().decode([LearnedItem].self, from: plain) else {
            // The key is gone or the file is damaged: it can never be read, so it goes.
            try? FileManager.default.removeItem(at: file)
            items = []
            return
        }
        items = decoded
    }

    private func save() throws {
        let list = items ?? []
        if list.isEmpty { try? FileManager.default.removeItem(at: file); return }
        guard let key = try key(create: true) else { throw DictationHistoryError.keyUnavailable }
        try NotesAtomicFile.directory(directory)
        let marker = directory.appendingPathComponent(".metadata_never_index")
        if !FileManager.default.fileExists(atPath: marker.path) {
            FileManager.default.createFile(atPath: marker.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try NotesAtomicFile.write(try NotesJournalCodec.aesGCM(key: key, context: Self.context).seal(JSONEncoder().encode(list)), to: file)
    }

    public func all() throws -> [LearnedItem] {
        try load()
        return items ?? []
    }

    /// One edit's corrections: counted, and active once seen `threshold` times or when `explicit` (Teach Chirp).
    /// Returns the items that became active just now. An item the user turned off stays off.
    @discardableResult
    public func observe(_ corrections: [LearnedCorrection], bundleID: String?, appName: String?, inserted: String,
                        edited: String, said: String?, explicit: Bool = false) throws -> [LearnedItem] {
        try load()
        var activated: [LearnedItem] = []
        let date = now()
        for correction in corrections {
            if let i = items?.firstIndex(where: { Self.same($0, correction, bundleID) }) {
                var item = items![i]
                item.count += 1
                item.lastSeen = date
                item.inserted = Self.bounded(inserted); item.edited = Self.bounded(edited); item.said = said.map(Self.bounded)
                if item.state == .learning, item.count >= Self.threshold || explicit { item.state = .active; activated.append(item) }
                items![i] = item
            } else {
                let item = LearnedItem(id: UUID(), correction: correction, bundleID: bundleID, appName: appName,
                                       state: explicit ? .active : .learning, count: 1, firstSeen: date, lastSeen: date,
                                       inserted: Self.bounded(inserted), edited: Self.bounded(edited), said: said.map(Self.bounded))
                items?.append(item)
                if explicit { activated.append(item) }
            }
        }
        trim()
        try save()
        return activated
    }

    /// A term is the user's everywhere (one item per heard → term); a style is one per app.
    static func same(_ item: LearnedItem, _ correction: LearnedCorrection, _ bundleID: String?) -> Bool {
        guard item.correction == correction else { return false }
        if case .style = correction { return item.bundleID == bundleID }
        return true
    }

    static func bounded(_ text: String) -> String { String(text.prefix(maxText)) }

    private func trim() {
        guard var list = items, list.count > Self.maxItems else { return }
        for state in [LearnedItem.State.learning, .off, .active] where list.count > Self.maxItems {
            let victims = list.filter { $0.state == state }.sorted { $0.lastSeen < $1.lastSeen }.prefix(list.count - Self.maxItems)
            let ids = Set(victims.map(\.id))
            list.removeAll { ids.contains($0.id) }
        }
        items = list
    }

    /// Approve (use it now), Undo (stop using it, and don't learn it again) or put it back to learning.
    public func set(_ id: UUID, state: LearnedItem.State) throws {
        try load()
        guard let i = items?.firstIndex(where: { $0.id == id }) else { return }
        items?[i].state = state
        try save()
    }

    public func delete(_ id: UUID) throws {
        try load()
        items?.removeAll { $0.id == id }
        try save()
    }

    /// Reset an app: everything learned from edits in it goes.
    public func reset(bundleID: String?) throws {
        try load()
        items?.removeAll { $0.bundleID == bundleID }
        try save()
    }

    public func clear() throws {
        try? FileManager.default.removeItem(at: file)
        items = []
        try keys.delete()
    }

    /// What a dictation in `bundleID` sends: every active term, and that app's active style with its examples.
    public func payload(for bundleID: String?) throws -> LearnedPayload {
        try load()
        return Self.payload(items ?? [], for: bundleID)
    }

    public static func payload(_ items: [LearnedItem], for bundleID: String?) -> LearnedPayload {
        let active = items.filter { $0.state == .active }
        var terms: [LearnedPayload.Term] = []
        for item in active {
            guard case .term(let heard, let term) = item.correction else { continue }
            if let i = terms.firstIndex(where: { $0.term == term }) {
                if !terms[i].heard.contains(heard), terms[i].heard.count < 4 { terms[i].heard.append(heard) }
            } else if terms.count < 100 {
                terms.append(.init(term: term, heard: [heard]))
            }
        }
        var style: [LearnedStyle] = [], examples: [LearnedPayload.Example] = []
        for item in active.sorted(by: { $0.lastSeen > $1.lastSeen }) where item.bundleID == bundleID && bundleID != nil {
            guard case .style(let s) = item.correction else { continue }
            if !style.contains(s) { style.append(s) }
            if let said = item.said, examples.count < maxExamples, !examples.contains(where: { $0.said == said }) {
                examples.append(.init(said: said, wanted: item.edited))
            }
        }
        return LearnedPayload(terms: terms, style: LearnedStyle.allCases.filter(style.contains), examples: examples)
    }
}

// MARK: watching the field

/// The text field Chirp inserted into, as the watcher sees it. The app's is the focused Accessibility element; tests
/// and the selftest use `TestTextField`.
@MainActor
public protocol WatchedField: AnyObject {
    /// The field's whole text, nil when it can no longer be read.
    func value() -> String?
    /// The selection or caret (UTF-16), nil when the app does not say: finds a pasted dictation.
    func selection() -> NSRange?
    /// It is still the focused element.
    var isFocused: Bool { get }
    /// A password field, or secure input is on: nothing is read or learned.
    var isSecure: Bool { get }
}

/// Whether a committed dictation's field is watched, every gate in order. An AX write and a paste go through the same
/// gates; only what passes them may be looked for in the field (and only then is a Chromium or Electron app asked to
/// expose it). The gate names go to the log.
public enum LearnWatchPlan: Sendable, Equatable {
    case skip(gate: String)
    /// A verified AX write that said where it went.
    case watch(NSRange)
    /// A paste, or an AX write that was not confirmed or gave no range: look for it in the field.
    case find

    public static func plan(learningEnabled: Bool, historyEnabled: Bool, isPrivate: Bool, excluded: Bool, secureField: Bool,
                            outcome: InsertionOutcome, axRange: NSRange?) -> LearnWatchPlan {
        guard learningEnabled else { return .skip(gate: historyEnabled ? "learningOff" : "historyOff") }
        guard !isPrivate else { return .skip(gate: "private") }
        guard !excluded else { return .skip(gate: "excludedApp") }
        guard !secureField else { return .skip(gate: "secure") }
        switch outcome {
        case .inserted(.ax): return axRange.map(LearnWatchPlan.watch) ?? .find
        case .inserted(.paste), .insertedUnverified: return .find
        case .inserted(.copy), .copied, .refusedSecure: return .skip(gate: "notInserted")
        }
    }
}

/// A plain in-memory text field: the test-mode stand-in for an app's field (unit tests and `--learn-selftest`).
@MainActor
public final class TestTextField: WatchedField {
    public var text: String
    public var isFocused = true
    public var isSecure = false
    /// The caret, after the last insertion; nil for an app that does not report it.
    public var caret: NSRange?
    public init(_ text: String = "") { self.text = text }
    public func value() -> String? { text }
    public func selection() -> NSRange? { caret }

    /// Inserts at the end as a dictation does; returns where it went (UTF-16).
    @discardableResult
    public func insert(_ inserted: String) -> NSRange {
        let range = NSRange(location: (text as NSString).length, length: (inserted as NSString).length)
        text += inserted
        caret = NSRange(location: NSMaxRange(range), length: 0)
        return range
    }

    /// The user's own edit: every `old` becomes `new`.
    public func edit(_ old: String, to new: String) { text = text.replacingOccurrences(of: old, with: new) }
}

/// Watches the field a dictation went into for a bounded window: it ends at the first focus change, when the text
/// around the dictation changes (the message was sent, the field cleared, an edit elsewhere), after `window`, or when
/// the next dictation starts. Then the inserted span, as the user last left it, goes to `onEdit`. Secure fields are
/// never read. Field text is held in memory only for the window; the log says why a window started or ended, never
/// what the field holds.
@MainActor
public final class EditWatcher {
    public static let window: Duration = .seconds(60)
    public static let interval: Duration = .milliseconds(400)
    /// A paste lands when the app gets to it: how often and how long to look for it.
    public static let pasteInterval: Duration = .milliseconds(125)
    public static let pasteAttempts = 12

    public struct Edit: Sendable, Equatable {
        public var inserted: String
        public var edited: String
        public var raw: String
        public var bundleID: String?
        public var appName: String?
    }

    /// Why a window ended, for the log.
    public enum End: String, Sendable {
        case next, focus, timeout, moved, unreadable, secure
    }

    private struct Watch {
        var field: WatchedField
        var before: String
        var latest: String
        var range: NSRange
        var inserted: String
        var raw: String
        var bundleID: String?
        var appName: String?
    }

    private var current: Watch?
    private var task: Task<Void, Never>?
    /// Bumped whenever a window ends or is cancelled, so a paste still being looked for gives up.
    private var generation = 0
    private let sleep: (Duration) async -> Void
    private let window: Duration
    private let interval: Duration
    public var onEdit: (Edit) -> Void = { _ in }
    public var isWatching: Bool { current != nil }

    public init(window: Duration = EditWatcher.window, interval: Duration = EditWatcher.interval,
                sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.window = window
        self.interval = interval
        self.sleep = sleep
    }

    /// Starts watching `field`, where `inserted` went at `range`; the previous window ends first.
    @discardableResult
    public func watch(_ field: WatchedField, inserted: String, range: NSRange, raw: String, bundleID: String?, appName: String?) -> Bool {
        finish()
        let app = bundleID ?? "-"
        guard !field.isSecure else { chirpLog.info("learn skip gate=secure app=\(app, privacy: .public)"); return false }
        guard let before = field.value() else { chirpLog.info("learn skip gate=unreadable app=\(app, privacy: .public)"); return false }
        guard let r = Range(range, in: before), before[r] == inserted else {
            chirpLog.info("learn skip gate=notInField app=\(app, privacy: .public)")
            return false
        }
        current = Watch(field: field, before: before, latest: before, range: range, inserted: inserted, raw: raw,
                        bundleID: bundleID, appName: appName)
        chirpLog.info("learn watch app=\(app, privacy: .public)")
        let polls = max(1, Int(window / interval))
        task = Task { [weak self] in
            for _ in 0..<polls {
                await self?.sleep(self?.interval ?? .seconds(1))
                guard !Task.isCancelled, let self else { return }
                if let end = self.poll() { self.finish(end); return }
            }
            guard !Task.isCancelled else { return }
            self?.finish(.timeout)
        }
        return true
    }

    /// After a paste, or an AX write that did not say where it landed: the app applies it on its own time, so look
    /// for the text in the focused field (just before the caret, or its only occurrence) for a moment, then watch it
    /// there. Gives up when the next dictation starts or Use raw runs meanwhile.
    @discardableResult
    public func watchPasted(_ field: @escaping () -> WatchedField?, inserted: String, raw: String, bundleID: String?,
                            appName: String?, attempts: Int = EditWatcher.pasteAttempts) async -> Bool {
        finish()
        let started = generation
        var gate = "unreadable"
        for attempt in 0..<max(1, attempts) {
            if attempt > 0 { await sleep(Self.pasteInterval) }
            guard generation == started, !Task.isCancelled else { return false }
            guard let f = field() else { continue }
            if f.isSecure { gate = "secure"; break }
            guard let value = f.value() else { continue }
            gate = "notInField"
            if let range = EditRegion.pasted(inserted, in: value, caret: f.selection()) {
                return watch(f, inserted: inserted, range: range, raw: raw, bundleID: bundleID, appName: appName)
            }
        }
        chirpLog.info("learn skip gate=\(gate, privacy: .public) app=\(bundleID ?? "-", privacy: .public)")
        return false
    }

    /// One look: why the window is over (focus moved, the text around it changed, the field went secure or
    /// unreadable), or nil to keep watching.
    private func poll() -> End? {
        guard var watch = current else { return .next }
        if watch.field.isSecure { return .secure }
        guard watch.field.isFocused else { return .focus }
        guard let value = watch.field.value() else { return .unreadable }
        // Sent, cleared or edited elsewhere: what the user made of the dictation is the last text seen.
        guard EditRegion.holds(before: watch.before, after: value, range: watch.range) else { return .moved }
        watch.latest = value
        current = watch
        return nil
    }

    /// Ends the window (the next dictation, focus moved, time is up) and reports the edit, if any.
    public func finish(_ end: End = .next) {
        task?.cancel()
        task = nil
        generation += 1
        guard var watch = current else { return }
        current = nil
        let app = watch.bundleID ?? "-"
        if watch.field.isSecure { chirpLog.info("learn end=secure app=\(app, privacy: .public)"); return }
        if watch.field.isFocused, let value = watch.field.value(),
           EditRegion.holds(before: watch.before, after: value, range: watch.range) { watch.latest = value }
        let edited = EditRegion.edited(before: watch.before, after: watch.latest, range: watch.range)
        let changed = edited.map { $0 != watch.inserted } ?? false
        chirpLog.info("learn end=\(end.rawValue, privacy: .public) edited=\(changed, privacy: .public) app=\(app, privacy: .public)")
        guard let edited, changed else { return }
        onEdit(Edit(inserted: watch.inserted, edited: edited, raw: watch.raw, bundleID: watch.bundleID, appName: watch.appName))
    }

    /// Chirp itself changed the field (Use raw): forget the window without learning.
    public func cancel() {
        task?.cancel()
        task = nil
        generation += 1
        if let watch = current { chirpLog.info("learn end=cancelled app=\(watch.bundleID ?? "-", privacy: .public)") }
        current = nil
    }
}

// MARK: the app's learning

/// Learn from my edits for the app and its windows: the watcher's edits become corrections in the store, and
/// `payload`/`apply` hand the active ones to the next dictation. The log has counts and the app only, never the words.
@MainActor @Observable public final class EditLearning {
    public let store: LearnedStore
    @ObservationIgnored public let watcher: EditWatcher
    public private(set) var items: [LearnedItem] = []
    /// Items that just became active, for the HUD's "Learned: Kubernetes".
    @ObservationIgnored public var onLearned: ([LearnedItem]) -> Void = { _ in }
    @ObservationIgnored public var onChange: () -> Void = {}

    public init(store: LearnedStore = LearnedStore(), watcher: EditWatcher = EditWatcher()) {
        self.store = store
        self.watcher = watcher
        watcher.onEdit = { [weak self] edit in self?.learn(edit) }
    }

    public func reload() async {
        items = (try? await store.all()) ?? []
        onChange()
    }

    /// An edit the watcher saw.
    public func learn(_ edit: EditWatcher.Edit) {
        let corrections = EditCorrections.extract(inserted: edit.inserted, edited: edit.edited)
        guard !corrections.isEmpty else {
            chirpLog.info("learn edit corrections=0 app=\(edit.bundleID ?? "-", privacy: .public)")
            return
        }
        Task { await observe(corrections, edit: edit, explicit: false) }
    }

    /// Teach Chirp (History): what the user says the dictation should have been; used at once.
    @discardableResult
    public func teach(inserted: String, wanted: String, raw: String?, bundleID: String?, appName: String?) async -> [LearnedItem] {
        let corrections = EditCorrections.extract(inserted: inserted, edited: wanted)
        guard !corrections.isEmpty else { return [] }
        return await observe(corrections, edit: .init(inserted: inserted, edited: wanted, raw: raw ?? inserted,
                                                      bundleID: bundleID, appName: appName), explicit: true)
    }

    @discardableResult
    private func observe(_ corrections: [LearnedCorrection], edit: EditWatcher.Edit, explicit: Bool) async -> [LearnedItem] {
        var activated: [LearnedItem] = []
        do {
            activated = try await store.observe(corrections, bundleID: edit.bundleID, appName: edit.appName,
                                                inserted: edit.inserted, edited: edit.edited, said: edit.raw, explicit: explicit)
        } catch {
            let e = error as NSError   // the domain and code only: an error's description may quote a value
            chirpLog.error("learn store failed domain=\(e.domain, privacy: .public) code=\(e.code, privacy: .public)")
        }
        await reload()
        let counts = corrections.map { c in items.first { LearnedStore.same($0, c, edit.bundleID) }.map { "\($0.state.rawValue):\($0.count)" } ?? "lost" }
        chirpLog.info("learn edit corrections=\(corrections.count, privacy: .public) activated=\(activated.count, privacy: .public) items=\(counts.joined(separator: ","), privacy: .public) explicit=\(explicit, privacy: .public) app=\(edit.bundleID ?? "-", privacy: .public)")
        if !activated.isEmpty { onLearned(activated) }
        return activated
    }

    public func payload(for bundleID: String?) -> LearnedPayload { LearnedStore.payload(items, for: bundleID) }

    public func set(_ id: UUID, state: LearnedItem.State) async { try? await store.set(id, state: state); await reload() }
    public func delete(_ id: UUID) async { try? await store.delete(id); await reload() }
    public func reset(bundleID: String?) async { try? await store.reset(bundleID: bundleID); await reload() }
    public func clear() async { try? await store.clear(); await reload() }
}
