import Foundation

public enum HistoryRetention: String, Codable, Sendable, CaseIterable {
    case day, week, month
    public var seconds: TimeInterval { switch self { case .day: 86_400; case .week: 604_800; case .month: 2_592_000 } }
}
public struct HistoryEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var createdAt: Date
    public var text: String
    public var raw: String?
    public var corrected: Bool
    public init(id: UUID = UUID(), createdAt: Date = Date(), text: String, raw: String? = nil, corrected: Bool = false) {
        self.id = id; self.createdAt = createdAt; self.text = text; self.raw = raw; self.corrected = corrected
    }
}
public struct HistorySettings: Codable, Sendable, Equatable {
    public var enabled = false
    public var retention: HistoryRetention = .week
    public var generation = UUID()
    public init() {}
    private enum CodingKeys: String, CodingKey { case enabled, retention, generation }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        retention = try values.decodeIfPresent(HistoryRetention.self, forKey: .retention) ?? .week
        generation = try values.decodeIfPresent(UUID.self, forKey: .generation) ?? UUID()
    }
}

/// Disk state is authoritative under the same process-safe lock as Keychain changes. No cached enabled flag/key.
/// Disabling fences new writers; only an explicit delete removes retained entries and their key.
public final class HistoryStore: Sendable {
    public static let keyAccount = "history.aes.v1"
    private let sealed: SealedStorage
    private let now: @Sendable () -> Date
    private let maximumBytes = 4 * 1_048_576
    public init(root: URL, secrets: any SecretStore, now: @escaping @Sendable () -> Date = { Date() }) throws {
        sealed = SealedStorage(files: try ProtectedFiles(root: root.appendingPathComponent("history", isDirectory: true)),
                               secrets: secrets, account: Self.keyAccount)
        self.now = now
    }
    private func settingsLocked() throws -> HistorySettings {
        try sealed.files.load(HistorySettings.self, "settings.json", max: 4096) ?? HistorySettings()
    }
    public func settings() throws -> HistorySettings { try sealed.files.transaction { try settingsLocked() } }
    public func setEnabled(_ enabled: Bool, deleteHistory: Bool = false) throws {
        try sealed.files.transaction {
            var settings = try settingsLocked()
            settings.enabled = enabled; settings.generation = UUID()
            // Persist the disabled fence before an optional delete; racing writers cannot recreate deleted history.
            try sealed.files.save(settings, "settings.json", max: 4096)
            if !enabled && deleteHistory {
                try sealed.files.remove("entries.sealed")
                try sealed.secrets.delete(account: Self.keyAccount)
            }
        }
    }
    public func setRetention(_ retention: HistoryRetention) throws {
        try sealed.files.transaction {
            var settings = try settingsLocked(); settings.retention = retention
            try sealed.files.save(settings, "settings.json", max: 4096)
            try save(prune(try load(), settings: settings))
        }
    }
    @discardableResult
    public func record(text: String, raw: String? = nil, corrected: Bool = false) throws -> HistoryEntry? {
        try record(HistoryEntry(createdAt: now(), text: text, raw: raw, corrected: corrected))
    }
    @discardableResult
    public func record(_ entry: HistoryEntry) throws -> HistoryEntry? {
        guard !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard entry.text.utf8.count <= 65_536, (entry.raw?.utf8.count ?? 0) <= 65_536 else { throw CoreError.oversized }
        return try sealed.files.transaction {
            let settings = try settingsLocked()
            guard settings.enabled else { return nil }
            guard entry.createdAt <= now(), entry.createdAt > now().addingTimeInterval(-settings.retention.seconds) else { return nil }
            var entries = try prune(load(), settings: settings)
            guard !entries.contains(where: { $0.id == entry.id }) else { throw CoreError.replay }
            entries.append(entry)
            entries = prune(entries, settings: settings)
            while try JSONEncoder().encode(entries).count + 28 > maximumBytes { entries.removeFirst() }
            try save(entries)
            return entry
        }
    }
    public func entries() throws -> [HistoryEntry] {
        try sealed.files.transaction {
            let settings = try settingsLocked()
            let entries = try prune(load(), settings: settings)
            if entries.isEmpty { try sealed.files.remove("entries.sealed") } else { try save(entries) }
            return entries.reversed()
        }
    }
    public func delete(id: UUID) throws {
        try sealed.files.transaction {
            try save(load().filter { $0.id != id })
        }
    }
    /// Replaces only an existing retained final with its stored raw text. Never records a new entry.
    /// Safe after disable/clear/expiry: nil means no retained entry could be changed.
    @discardableResult
    public func useRaw(id: UUID) throws -> HistoryEntry? {
        try sealed.files.transaction {
            let settings = try settingsLocked()
            guard settings.enabled else { return nil }
            var entries = try prune(load(), settings: settings)
            guard let index = entries.firstIndex(where: { $0.id == id }),
                  let raw = entries[index].raw,
                  !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            entries[index].text = raw
            entries[index].corrected = false
            try save(entries)
            return entries[index]
        }
    }
    public func clear() throws {
        try sealed.files.transaction {
            try sealed.files.remove("entries.sealed"); try sealed.secrets.delete(account: Self.keyAccount)
        }
    }
    private func load() throws -> [HistoryEntry] {
        try sealed.load([HistoryEntry].self, "entries.sealed", max: maximumBytes) ?? []
    }
    private func save(_ entries: [HistoryEntry]) throws {
        if entries.isEmpty { try sealed.files.remove("entries.sealed") }
        else { try sealed.save(entries, "entries.sealed", max: maximumBytes) }
    }
    private func prune(_ entries: [HistoryEntry], settings: HistorySettings) -> [HistoryEntry] {
        Array(entries.filter { $0.createdAt > now().addingTimeInterval(-settings.retention.seconds) && $0.createdAt <= now() }
            .sorted { $0.createdAt < $1.createdAt }.suffix(200))
    }
}
