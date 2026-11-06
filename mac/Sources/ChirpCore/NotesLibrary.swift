import Foundation
import Observation

/// Common crash-safe path for recovery journals, library records and the lightweight index.
enum NotesAtomicFile {
    static func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        var protectedURL = url
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try protectedURL.setResourceValues(values)
        #endif
    }

    static func write(_ data: Data, to final: URL) throws {
        try directory(final.deletingLastPathComponent())
        let temp = final.appendingPathExtension("tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd); try? FileManager.default.removeItem(at: temp) }
        guard fchmod(fd, 0o600) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: temp.path)
        #endif
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                guard n > 0 else { throw CocoaError(.fileWriteOutOfSpace) }
                offset += n
            }
        }
        if fcntl(fd, F_FULLFSYNC) != 0 { fsync(fd) }
        guard rename(temp.path, final.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

public enum NotesRetention: String, CaseIterable, Codable, Sendable {
    case never, oneYear, ninetyDays, thirtyDays
    public var days: Int? {
        switch self { case .never: nil; case .oneYear: 365; case .ninetyDays: 90; case .thirtyDays: 30 }
    }
}

public struct NotesCaptureBoundary: Codable, Equatable, Sendable {
    public var startedAt: Date
    public var offset: TimeInterval
    public var firstSegment: Int
}

public struct NotesAudioReference: Codable, Equatable, Sendable, Identifiable {
    public var id: Int
    public var offset: TimeInterval
    public var duration: TimeInterval
    public var sampleRate: Double
    public var bytes: Int
}

public struct NotesMetadata: Codable, Equatable, Sendable {
    public var userTitle: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var sessions: [NotesCaptureBoundary] = []
    public var audio: [NotesAudioReference] = []
}

extension NotesDocument {
    public var createdAt: Date { libraryMetadata?.createdAt ?? startedAt }
    public var updatedAt: Date { libraryMetadata?.updatedAt ?? startedAt }
    public var deletedAt: Date? { libraryMetadata?.deletedAt }
    public var userTitle: String? { libraryMetadata?.userTitle }
    public var sessions: [NotesCaptureBoundary] { libraryMetadata?.sessions ?? [] }
    public var audio: [NotesAudioReference] { libraryMetadata?.audio ?? [] }

    /// The text's lines a title or library row can use: trimmed, without the "nothing substantive" placeholder or the
    /// "not structured" notice (neither says what the note is about).
    private var meaningfulLines: [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0 != NotesMarkdown.placeholder && $0 != Self.fallbackHeader }
    }

    public var title: String {
        if let userTitle { return userTitle }
        let lines = meaningfulLines
        if let heading = lines.first(where: { $0.range(of: #"^#{1,6}\s+\S"#, options: .regularExpression) != nil }) {
            return String(heading.drop(while: { $0 == "#" || $0.isWhitespace }).prefix(160))
        }
        if let derived = lines.lazy.compactMap({ derivedTitle(from: $0) }).first { return derived }
        if let derived = segments.lazy.filter({ !$0.isGap }).compactMap({ derivedTitle(from: $0.text) }).first { return derived }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMMM"
        return "Note, " + formatter.string(from: createdAt)
    }

    /// Reading text for a library row, preserving the boundary between each line or block.
    public func snippet() -> String {
        func plain(_ line: String) -> String {
            line.replacingOccurrences(of: #"^(#{1,6}\s+|>\s*|[-*+]\s+(\[[ xX]\]\s+)?|\d+[.)]\s+)+"#,
                                      with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\*\*|__|`"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"(^|\s)[*_](\S)"#, with: "$1$2", options: .regularExpression)
                .replacingOccurrences(of: #"(\S)[*_](\s|$|[.,;:!?])"#, with: "$1$2", options: .regularExpression)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        func heading(_ line: String) -> Bool {
            line.range(of: #"^#{1,6}\s+\S"#, options: .regularExpression) != nil
        }
        let lines = meaningfulLines.filter { !$0.isEmpty && !$0.allSatisfy { "-*_ ".contains($0) } }
        let titleLine = userTitle == nil ? lines.firstIndex(where: heading) ?? lines.indices.first : nil
        let displayTitle = plain(title)
        var body = ""
        for (index, line) in lines.enumerated() {
            let value = plain(line)
            guard index != titleLine, !(heading(line) && value.caseInsensitiveCompare(displayTitle) == .orderedSame),
                  !value.isEmpty else { continue }
            body += (body.isEmpty ? "" : " · ") + value
            if body.count >= 240 { break }
        }
        let preview = body.isEmpty ? segments.filter { !$0.isGap }.map(\.text).joined(separator: " ") : body
        return String(preview.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(240))
    }

    /// The longest a title derived from the text runs (about; it ends on a word boundary).
    public static let derivedTitleLength = 60

    /// A short title from a line of text when the note has no heading and no chosen title: list markers and a leading
    /// speaker label (`Person 1:`, or the name a person was renamed to) come off, it stops at the first sentence end, and
    /// it is cut on a word boundary with an ellipsis. Nil when nothing is left.
    func derivedTitle(from line: String) -> String? {
        var text = line.trimmingCharacters(in: .whitespaces)
        text = text.replacingOccurrences(of: #"^(?:>\s*|[-*+]\s+(?:\[[ xX]\]\s+)?|\d+[.)]\s+)+"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\*\*|__|`"#, with: "", options: .regularExpression)
        let names = roster.people.compactMap { $0.name?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        for name in names where text.hasPrefix(name + ":") {
            text = String(text.dropFirst(name.count + 1))
            break
        }
        text = text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"^Person \d+:"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        // The first sentence only.
        if let end = text.range(of: #"[.!?](?=\s|$)"#, options: .regularExpression) { text = String(text[..<end.lowerBound]) }
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        let limit = Self.derivedTitleLength
        guard text.count > limit else { return text }
        let cut = String(text.prefix(limit))
        let words = cut.split(separator: " ", omittingEmptySubsequences: true)
        // A boundary: drop the word the limit fell inside, unless the cut landed exactly after one.
        let whole = text[text.index(text.startIndex, offsetBy: limit)] == " "
        let kept = whole || words.count < 2 ? words : words.dropLast()
        return kept.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-—")) + "…"
    }

    public func openTodoCount() -> Int {
        text.components(separatedBy: .newlines).filter {
            $0.range(of: #"^\s*[-*+] \[ \](?:\s|$)"#, options: .regularExpression) != nil
        }.count
    }

    mutating func ensureMetadata() {
        if libraryMetadata == nil { libraryMetadata = NotesMetadata(createdAt: startedAt, updatedAt: startedAt) }
    }

    public mutating func rename(_ title: String, at date: Date = Date()) {
        ensureMetadata()
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        libraryMetadata?.userTitle = trimmed.isEmpty ? nil : trimmed
        libraryMetadata?.updatedAt = date
    }


}

public struct NotesLibraryEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    public var snippet: String
    // A missing format marker invalidates the old index so snippets rebuild from the original line boundaries.
    private var snippetFormat: Int = 1
    /// The names people were given in the note, for the Name speakers sheet's autocomplete. A missing key invalidates
    /// the old index too, so the first launch after it fills this in.
    public var speakerNames: [String]
    public var openTodos: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var duration: TimeInterval
    public var audioBytes: Int
    public var hasAudio: Bool
    public var recovered: Bool
    public var recording: Bool

    /// A row built by hand (the window's unsaved new note, snapshots and tests); the library builds its own from records.
    public init(id: UUID, title: String, snippet: String = "", openTodos: Int = 0, createdAt: Date, updatedAt: Date,
                deletedAt: Date? = nil, duration: TimeInterval = 0, audioBytes: Int = 0, recovered: Bool = false, recording: Bool = false,
                speakerNames: [String] = []) {
        self.id = id; self.title = title; self.snippet = snippet; self.openTodos = openTodos; self.speakerNames = speakerNames
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt; self.duration = duration
        self.audioBytes = audioBytes; hasAudio = audioBytes > 0; self.recovered = recovered; self.recording = recording
    }

    init(_ r: NotesJournalRecord) {
        let d = r.document
        id = d.id; title = d.title; snippet = d.snippet(); openTodos = d.openTodoCount(); speakerNames = d.namedSpeakers
        createdAt = d.createdAt; updatedAt = d.updatedAt; deletedAt = d.deletedAt
        recording = r.recording == true
        duration = r.elapsed; audioBytes = d.audio.reduce(0) { $0 + $1.bytes }; recovered = r.recovered == true
        hasAudio = audioBytes > 0
    }
}

public struct NotesSearchResult: Sendable, Identifiable {
    public var entry: NotesLibraryEntry
    public var snippet: String
    /// UTF-16 ranges in `snippet`, suitable for an attributed string highlight.
    public var matches: [NSRange]
    public var id: UUID { entry.id }

    public init(entry: NotesLibraryEntry, snippet: String, matches: [NSRange]) {
        self.entry = entry; self.snippet = snippet; self.matches = matches
    }
}

public enum NotesLibraryError: Error { case missing, recording, deleted, unsupportedSchema }

/// Serial disk access and encoding run on this actor, away from the main actor and the audio callback.
public actor NotesLibraryStore {
    public nonisolated let directory: URL
    private let now: @Sendable () -> Date
    private let codec: NotesJournalCodec?
    private var entries: [UUID: NotesLibraryEntry]?
    private var recordingIDs: Set<UUID> = []
    private var purgedIDs: Set<UUID> = []
    public static let recentlyDeletedDays = 30
    public static var defaultDirectory: URL {
        NotesJournalStore.defaultDirectory.deletingLastPathComponent().appendingPathComponent("Notes", isDirectory: true)
    }

    public init(directory: URL = NotesLibraryStore.defaultDirectory, codec: NotesJournalCodec? = nil, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory; self.codec = codec; self.now = now
    }

    public nonisolated func noteDirectory(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString, isDirectory: true) }
    public nonisolated func audioURL(_ id: UUID, segment: Int) -> URL {
        noteDirectory(id).appendingPathComponent("audio", isDirectory: true).appendingPathComponent("\(segment).m4a")
    }
    private func file(_ id: UUID) -> URL { noteDirectory(id).appendingPathComponent("note.json") }

    public func record(_ id: UUID) throws -> NotesJournalRecord {
        let stored = try Data(contentsOf: file(id))
        let data = try codec?.open(stored) ?? stored
        struct Header: Decodable { var schema: Int }
        guard [1, 2].contains(try JSONDecoder().decode(Header.self, from: data).schema) else { throw NotesLibraryError.unsupportedSchema }
        return try JSONDecoder().decode(NotesJournalRecord.self, from: data)
    }

    private func loadIndex() throws {
        guard entries == nil else { return }
        var loaded = false
        // A sealed mobile directory can be temporarily unavailable while locked. Retry from disk after unlock.
        // Keep the existing plaintext Mac path unchanged.
        defer { if codec != nil && !loaded { entries = nil } }
        let index = directory.appendingPathComponent("index.json")
        let cached = (try? Data(contentsOf: index)).flatMap { stored -> [NotesLibraryEntry]? in
            guard let data = try? codec?.open(stored) ?? stored else { return nil }
            return try? JSONDecoder().decode([NotesLibraryEntry].self, from: data)
        }
        entries = Dictionary((cached ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let indexedAt = (try? index.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        let folders = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var found: Set<UUID> = []
        for url in folders {
            guard let id = UUID(uuidString: url.lastPathComponent) else { continue }
            found.insert(id)
            let modified = (try? file(id).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
            // Decode only records absent/stale in the index, and captures that need crash recovery.
            guard cached == nil || entries?[id] == nil || entries?[id]?.recording == true || modified >= indexedAt else { continue }
            let r: NotesJournalRecord
            do { r = try record(id) }
            catch {
                // Only sealed clients quarantine corrupt bytes. Future schemas and temporarily locked files stay put.
                if codec != nil, !(error is NotesLibraryError),
                   (try? Data(contentsOf: file(id))) != nil {
                    let quarantine = directory.appendingPathComponent("quarantine", isDirectory: true)
                    try NotesAtomicFile.directory(quarantine)
                    try FileManager.default.moveItem(at: url, to: quarantine.appendingPathComponent(id.uuidString + "-" + UUID().uuidString))
                }
                entries?[id] = nil
                continue
            }
            var recovered = r
            if recovered.recording == true && !recordingIDs.contains(id) {
                recovered.recording = false; recovered.recovered = true
                try writeBytes(JSONEncoder().encode(recovered), to: file(id))
            }
            entries?[id] = NotesLibraryEntry(recovered)
        }
        entries = entries?.filter { found.contains($0.key) }
        try saveIndex()
        loaded = true
    }

    private func writeBytes(_ plain: Data, to url: URL) throws {
        try NotesAtomicFile.write(codec?.seal(plain) ?? plain, to: url)
    }

    private func saveIndex() throws {
        if directory == Self.defaultDirectory { try NotesAtomicFile.directory(directory.deletingLastPathComponent()) }
        try writeBytes(JSONEncoder().encode(Array((entries ?? [:]).values)), to: directory.appendingPathComponent("index.json"))
    }

    public func list(deleted: Bool = false) throws -> [NotesLibraryEntry] {
        try loadIndex()
        return (entries ?? [:]).values.filter { ($0.deletedAt != nil) == deleted }.sorted {
            $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt
        }
    }

    /// The writer must not resurrect a deleted note, or overwrite a rename/audio change made through the library.
    @discardableResult public func write(_ incoming: NotesJournalRecord) throws -> Int {
        guard [1, 2].contains(incoming.schema) else { throw NotesLibraryError.unsupportedSchema }
        try loadIndex()
        let id = incoming.document.id
        guard !purgedIDs.contains(id) else { throw NotesLibraryError.missing }
        var r = incoming
        r.schema = NotesJournalRecord.schema
        r.document.ensureMetadata()
        var contentChanged = true
        if FileManager.default.fileExists(atPath: file(id).path) {
            let old = try record(id)
            guard old.document.deletedAt == nil else { throw NotesLibraryError.deleted }
            r.document.libraryMetadata?.userTitle = old.document.userTitle
            r.document.libraryMetadata?.createdAt = old.document.createdAt
            r.document.libraryMetadata?.audio = old.document.audio
            r.recovered = incoming.recovered ?? old.recovered
            r.document.libraryMetadata?.updatedAt = old.document.updatedAt
            // Viewing, forgetting a previous diarizer's slots, and exporting are not content modifications.
            var before = old.document, after = r.document
            before.markSaved(); after.markSaved()
            before.forgetSpeakerSlots(); after.forgetSpeakerSlots()
            contentChanged = before != after || old.elapsed != r.elapsed
        }
        if contentChanged { r.document.libraryMetadata?.updatedAt = now() }
        r.writtenAt = now()
        if r.recording == true { recordingIDs.insert(id) } else { recordingIDs.remove(id) }
        if r.document.isEmpty, r.document.segments.isEmpty, r.document.userTitle == nil, r.document.version == 0, r.recording != true {
            if FileManager.default.fileExists(atPath: noteDirectory(id).path) { try FileManager.default.removeItem(at: noteDirectory(id)) }
            entries?[id] = nil; try saveIndex(); return 0
        }
        return try persist(r)
    }

    @discardableResult private func persist(_ record: NotesJournalRecord) throws -> Int {
        let data = try JSONEncoder().encode(record)
        try NotesAtomicFile.directory(directory)
        try writeBytes(data, to: file(record.document.id))
        entries?[record.document.id] = NotesLibraryEntry(record)
        try saveIndex()
        return data.count
    }

    public func rename(_ id: UUID, title: String) throws {
        try loadIndex()
        var r = try record(id); r.document.rename(title, at: now()); try persist(r)
    }

    public func trash(_ id: UUID) throws {
        try loadIndex()
        guard !recordingIDs.contains(id) else { throw NotesLibraryError.recording }
        var r = try record(id)
        r.document.ensureMetadata()
        if r.document.deletedAt != nil { return }
        r.document.libraryMetadata?.deletedAt = now(); r.document.libraryMetadata?.updatedAt = now()
        try persist(r)
    }

    public func restore(_ id: UUID) throws {
        try loadIndex()
        var r = try record(id); r.document.libraryMetadata?.deletedAt = nil
        r.document.libraryMetadata?.updatedAt = now(); try persist(r)
    }

    public func purge(_ id: UUID) throws {
        try loadIndex()
        guard !recordingIDs.contains(id) else { throw NotesLibraryError.recording }
        _ = try record(id) // unknown schemas must remain untouched
        try FileManager.default.removeItem(at: noteDirectory(id))
        entries?[id] = nil; purgedIDs.insert(id); try saveIndex()
    }

    /// Retention moves old notes to Recently Deleted. Only its own 30-day clock permanently purges them.
    public func maintain(retention: NotesRetention) throws {
        for e in try list(deleted: true) where now().timeIntervalSince(e.deletedAt!) >= 30 * 86400 { try purge(e.id) }
        if let days = retention.days {
            for e in try list() where !recordingIDs.contains(e.id) && now().timeIntervalSince(e.updatedAt) >= Double(days) * 86400 {
                try trash(e.id)
            }
        }
    }

    /// Each successful record is removed only after the note and index are durable. Existing IDs always win.
    public func migrate(from recovery: NotesJournalStore) throws {
        try loadIndex()
        for var r in recovery.recoverable() {
            if !FileManager.default.fileExists(atPath: file(r.document.id).path) {
                r.schema = 2; r.recording = false; r.recovered = true
                r.document.ensureMetadata(); r.document.libraryMetadata?.updatedAt = r.writtenAt
                try persist(r)
            } else {
                // A future/unreadable destination must not block migration of other notes, or lose its source.
                guard (try? record(r.document.id)) != nil else { continue }
            }
            recovery.delete(r.document.id)
        }
    }

    public func search(_ query: String) throws -> [NotesSearchResult] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return try list().map { NotesSearchResult(entry: $0, snippet: $0.snippet, matches: []) } }
        return try list().compactMap { entry in
            let r = try record(entry.id)
            let fields = [entry.title, r.document.text, r.document.segments.map { $0.raw + "\n" + $0.text }.joined(separator: "\n")]
            guard let body = fields.first(where: { $0.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }),
                  let hit = body.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
            let ns = body as NSString, range = NSRange(hit, in: body)
            let start = max(0, range.location - 60), end = min(ns.length, range.location + range.length + 140)
            let snippet = ns.substring(with: NSRange(location: start, length: end - start))
            var matches: [NSRange] = [], cursor = snippet.startIndex
            while cursor < snippet.endIndex, let match = snippet.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: cursor..<snippet.endIndex) {
                matches.append(NSRange(match, in: snippet)); cursor = match.upperBound
            }
            return NotesSearchResult(entry: entry, snippet: snippet, matches: matches)
        }
    }

    public func keepAudio(_ id: UUID, segment: Int, frames: [Data], offset: TimeInterval, sampleRate: Double) throws {
        try loadIndex()
        var r = try record(id)
        guard r.document.deletedAt == nil, r.document.segments.indices.contains(segment) else { throw NotesLibraryError.deleted }
        let bytes = try NotesAudioEncoder.write(frames, sampleRate: sampleRate, to: audioURL(id, segment: segment), codec: codec)
        r.document.ensureMetadata()
        r.document.libraryMetadata?.audio.removeAll { $0.id == segment }
        r.document.libraryMetadata?.audio.append(NotesAudioReference(id: segment, offset: offset,
            duration: Double(frames.reduce(0) { $0 + $1.count }) / (sampleRate * 2), sampleRate: sampleRate, bytes: bytes))
        r.document.libraryMetadata?.audio.sort { $0.id < $1.id }
        try persist(r)
    }

    /// Opens kept audio in memory; mobile clients never need a plaintext playback file.
    public func audioData(_ id: UUID, segment: Int) throws -> Data {
        let stored = try Data(contentsOf: audioURL(id, segment: segment))
        return try codec?.open(stored) ?? stored
    }

    public func deleteAudio(_ id: UUID) throws {
        try loadIndex()
        var r = try record(id)
        let folder = noteDirectory(id).appendingPathComponent("audio", isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        r.document.libraryMetadata?.audio = []; try persist(r)
    }

    public func totalAudioBytes() throws -> Int {
        try loadIndex(); return (entries ?? [:]).values.reduce(0) { $0 + $1.audioBytes }
    }
}

/// Observable API for the upcoming library sidebar. All document reads, search and encoding use `store`'s actor.
@MainActor @Observable public final class NotesLibrary {
    public let store: NotesLibraryStore
    public private(set) var notes: [NotesLibraryEntry] = []
    public private(set) var recentlyDeleted: [NotesLibraryEntry] = []
    public private(set) var totalAudioBytes = 0
    public private(set) var recordingID: UUID?
    public init(store: NotesLibraryStore = NotesLibraryStore()) { self.store = store }
    public func reload() async throws {
        notes = try await store.list(); recentlyDeleted = try await store.list(deleted: true)
        totalAudioBytes = try await store.totalAudioBytes()
    }
    public func search(_ query: String) async throws -> [NotesSearchResult] { try await store.search(query) }
    public func record(_ id: UUID) async throws -> NotesJournalRecord { try await store.record(id) }
    public func rename(_ id: UUID, title: String) async throws { try await store.rename(id, title: title); try await reload() }
    public func trash(_ id: UUID) async throws {
        guard id != recordingID else { throw NotesLibraryError.recording }
        try await store.trash(id); try await reload()
    }
    public func restore(_ id: UUID) async throws { try await store.restore(id); try await reload() }
    public func purge(_ id: UUID) async throws {
        guard id != recordingID else { throw NotesLibraryError.recording }
        try await store.purge(id); try await reload()
    }
    public func setRecordingNote(_ id: UUID?) { recordingID = id }
    public func segmentAudio(_ id: UUID) async throws -> [(reference: NotesAudioReference, url: URL)] {
        try await record(id).document.audio.map { ($0, store.audioURL(id, segment: $0.id)) }
    }
    public func deleteAudio(_ id: UUID) async throws { try await store.deleteAudio(id); try await reload() }
    public func maintain(retention: NotesRetention) async throws { try await store.maintain(retention: retention); try await reload() }
    public func migrate(from recovery: NotesJournalStore) async throws { try await store.migrate(from: recovery); try await reload() }
    @discardableResult public func write(_ r: NotesJournalRecord) async throws -> Int {
        let bytes = try await store.write(r)
        try await reload(); return bytes
    }
    public func keepAudio(_ id: UUID, segment: Int, frames: [Data], offset: TimeInterval, sampleRate: Double) async throws {
        try await store.keepAudio(id, segment: segment, frames: frames, offset: offset, sampleRate: sampleRate); try await reload()
    }
}

// String interpolation must never disclose note content, including in diagnostic failures.
extension NotesLibraryEntry: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "NotesLibraryEntry(<redacted>)" }
    public var debugDescription: String { description }
}
extension NotesJournalRecord: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "NotesJournalRecord(<redacted>)" }
    public var debugDescription: String { description }
}
