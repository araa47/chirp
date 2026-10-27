import CryptoKit
import Foundation
import Testing
@testable import ChirpCore
@testable import ChirpUI

private final class HistoryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    var now: Date { lock.withLock { date } }
    func advance(days: Double) { lock.withLock { date += days * 86400 } }
}

private func historyDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("chirp-history-\(UUID().uuidString)", isDirectory: true)
}

/// A Keychain stand-in that fails like a locked or denied Keychain.
private struct FailingKeys: HistoryKeyStore {
    func read() throws -> Data? { throw KeychainHistoryKeyStore.KeychainError.status(errSecInteractionNotAllowed) }
    func write(_ key: Data) throws { throw KeychainHistoryKeyStore.KeychainError.status(errSecInteractionNotAllowed) }
    func delete() throws {}
}

@Suite(.serialized) struct DictationHistoryTests {
    @Test func defaultsFollowLocalCapabilityAndPreserveEveryExplicitChoice() throws {
        let suite = "chirp-defaults-test-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let local = Health(correction: "available", correctionLeavesMachine: false)
        let external = Health(correction: "available", correctionLeavesMachine: true, correctionHost: "cleanup.example")
        let fresh = Preferences(defaults: defaults)
        #expect(fresh.historyEnabled && fresh.historyRetention == .thirtyDays)
        #expect(fresh.permitsCorrection(health: local))
        #expect(!fresh.permitsCorrection(health: external))
        #expect(!fresh.permitsCorrection(health: nil))
        #expect(!fresh.permitsCorrection(health: Health(correction: "available")))
        #expect(defaults.object(forKey: "correction") == nil)
        for choice in [true, false] {
            for retention in DictationRetention.allCases {
                defaults.set(choice, forKey: "correction")
                defaults.set(choice, forKey: "historyEnabled")
                defaults.set(retention.rawValue, forKey: "historyRetention")
                let reopened = Preferences(defaults: defaults)
                #expect(reopened.correction == choice && reopened.historyEnabled == choice)
                #expect(reopened.historyRetention == retention)
                #expect(reopened.permitsCorrection(health: local) == choice)
                #expect(reopened.permitsCorrection(health: external) == choice)
            }
        }
    }
    private func entry(_ text: String, raw: String? = nil, at date: Date, app: String = "com.apple.TextEdit") -> DictationEntry {
        DictationEntry(date: date, text: text, raw: raw, bundleID: app, appName: "TextEdit", duration: 3.2, style: raw == nil ? nil : "default")
    }

    @Test func entriesRoundTripNewestFirstAndRawIsOnlyKeptWhenItDiffers() async throws {
        let dir = historyDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = HistoryClock()
        let keys = MemoryHistoryKeyStore()
        let store = DictationHistoryStore(directory: dir, keys: keys, now: { clock.now })
        try await store.add(entry("first one", at: clock.now))
        try await store.add(entry("Second, cleaned.", raw: "second cleaned", at: clock.now.addingTimeInterval(60)))
        try await store.add(entry("same", raw: "same", at: clock.now.addingTimeInterval(120)))
        let all = try await store.entries()
        #expect(all.map(\.text) == ["same", "Second, cleaned.", "first one"])
        #expect(all.map(\.cleaned) == [false, true, false])
        // A fresh store (a relaunch) reads the same from disk.
        let reopened = DictationHistoryStore(directory: dir, keys: MemoryHistoryKeyStore(key: try keys.read()))
        #expect(try await reopened.entries() == all)
    }

    @Test func filesAreSealedOwnerOnlyAndHiddenFromSpotlight() async throws {
        let dir = historyDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryHistoryKeyStore()
        let store = DictationHistoryStore(directory: dir, keys: keys)
        let secret = "the launch code is purple elephant"
        try await store.add(entry(secret, raw: "the launch code is purple elephants", at: Date()))
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".sealed") }
        #expect(files.count == 1)
        let bytes = try Data(contentsOf: dir.appendingPathComponent(files[0]))
        #expect(bytes.range(of: Data("purple".utf8)) == nil)
        #expect(bytes.range(of: Data("TextEdit".utf8)) == nil)
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(files[0]).path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let folder = try FileManager.default.attributesOfItem(atPath: dir.path)
        #expect((folder[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".metadata_never_index").path))
        // The key is 256 bits, and opens the file only under its own name.
        let key = SymmetricKey(data: try #require(try keys.read()))
        #expect(try keys.read()?.count == 32)
        let plain = try NotesJournalCodec.aesGCM(key: key, context: DictationHistoryStore.schemaContext + files[0]).open(bytes)
        #expect(String(decoding: plain, as: UTF8.self).contains("purple elephant"))
        #expect(throws: (any Error).self) { try NotesJournalCodec.aesGCM(key: key, context: "chirp.history.v1:other.sealed").open(bytes) }
    }

    @Test func aRelaunchReadsTheHistoryBackWithTheKeychainKey() async throws {
        let dir = historyDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryHistoryKeyStore()
        try await DictationHistoryStore(directory: dir, keys: keys).add(entry("kept across launches", at: Date()))
        #expect(try await DictationHistoryStore(directory: dir, keys: keys).entries().map(\.text) == ["kept across launches"])
    }

    @Test func aLostKeyDiscardsTheUnreadableFilesButALockedKeychainLeavesThem() async throws {
        let dir = historyDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        try await DictationHistoryStore(directory: dir, keys: MemoryHistoryKeyStore()).add(entry("orphaned", at: Date()))
        // Locked or denied: an error, and nothing is deleted.
        await #expect(throws: (any Error).self) { try await DictationHistoryStore(directory: dir, keys: FailingKeys()).entries() }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasSuffix(".sealed") })
        // The key is gone (a new Mac, a deleted Keychain item): the ciphertext can never be read, so it goes.
        let fresh = DictationHistoryStore(directory: dir, keys: MemoryHistoryKeyStore())
        #expect(try await fresh.entries().isEmpty)
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasSuffix(".sealed") }))
        // A tampered file under the right key is discarded too.
        let keys = MemoryHistoryKeyStore()
        let store = DictationHistoryStore(directory: dir, keys: keys)
        try await store.add(entry("tamper me", at: Date()))
        let name = try #require(try FileManager.default.contentsOfDirectory(atPath: dir.path).first { $0.hasSuffix(".sealed") })
        var bytes = try Data(contentsOf: dir.appendingPathComponent(name))
        bytes[bytes.count - 1] ^= 0xFF
        try bytes.write(to: dir.appendingPathComponent(name))
        #expect(try await DictationHistoryStore(directory: dir, keys: keys).entries().isEmpty)
    }

    @Test func retentionDropsOldEntriesAndForeverKeepsThem() async throws {
        let dir = historyDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let clock = HistoryClock()
        let store = DictationHistoryStore(directory: dir, keys: MemoryHistoryKeyStore(), now: { clock.now })
        try await store.add(entry("old", at: clock.now.addingTimeInterval(-40 * 86400)))
        try await store.add(entry("week", at: clock.now.addingTimeInterval(-6 * 86400)))
        try await store.add(entry("today", at: clock.now))
        #expect(try await store.prune(retention: .forever) == 0)
        #expect(try await store.prune(retention: .thirtyDays) == 1)
        #expect(try await store.entries().map(\.text) == ["today", "week"])
        clock.advance(days: 2)
        #expect(try await store.prune(retention: .sevenDays) == 1)
        #expect(try await store.prune(retention: .oneDay) == 1)
        #expect(try await store.entries().isEmpty)
        // Emptied day files are removed, not left as sealed empty arrays.
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasSuffix(".sealed") }))
        #expect(DictationRetention.allCases.map(\.days) == [1, 7, 30, 90, nil])
        #expect(DictationRetention.default == .thirtyDays)
    }

    @Test func deleteRestoreUpdateAndClear() async throws {
        let dir = historyDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let keys = MemoryHistoryKeyStore()
        let store = DictationHistoryStore(directory: dir, keys: keys)
        let cleaned = entry("Hello, world.", raw: "hello world", at: Date())
        try await store.add(cleaned)
        try await store.add(entry("other", at: Date().addingTimeInterval(5)))
        let removed = try #require(try await store.delete(cleaned.id))
        #expect(try await store.entries().map(\.text) == ["other"])
        try await store.add(removed)   // Undo
        #expect(try await store.entries().count == 2)
        // "Use raw": the entry keeps what is now in the field.
        #expect(try await store.update(cleaned.id) { e in e.text = e.raw ?? e.text; e.raw = nil })
        #expect(try await store.entry(cleaned.id)?.text == "hello world")
        #expect(try await store.entry(cleaned.id)?.cleaned == false)
        try await store.clear()
        #expect(try await store.entries().isEmpty)
        #expect(try keys.read() == nil)
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasSuffix(".sealed") }))
    }

    @Test func searchMatchesTextRawAndAppIgnoringCaseAndAccents() async throws {
        let dir = historyDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = DictationHistoryStore(directory: dir, keys: MemoryHistoryKeyStore())
        try await store.add(entry("Meet at the café", at: Date()))
        try await store.add(entry("Deploy to Kubernetes", raw: "deploy to cooper netties", at: Date().addingTimeInterval(1)))
        try await store.add(DictationEntry(date: Date().addingTimeInterval(2), text: "ship it", bundleID: "com.tinyspeck.slackmacgap", appName: "Slack"))
        #expect(try await store.search("CAFE").map(\.text) == ["Meet at the café"])
        #expect(try await store.search("netties").map(\.text) == ["Deploy to Kubernetes"])
        #expect(try await store.search("slack").map(\.text) == ["ship it"])
        #expect(try await store.search("  ").count == 3)
    }

    @Test func policyNeverKeepsSecureFieldsExcludedAppsOrEmptyText() {
        func record(outcome: InsertionOutcome = .inserted(.ax), secure: Bool = false, app: String? = "com.apple.TextEdit",
                    enabled: Bool = true, text: String = "hello") -> Bool {
            HistoryPolicy.shouldRecord(enabled: enabled, outcome: outcome, secureField: secure, bundleID: app,
                                       excluded: HistoryPolicy.defaultExcludedApps, text: text)
        }
        #expect(record())
        #expect(record(outcome: .inserted(.paste)))
        #expect(record(outcome: .insertedUnverified))
        #expect(record(outcome: .copied))
        #expect(record(app: nil))
        #expect(!record(outcome: .refusedSecure))
        #expect(!record(secure: true))
        #expect(!record(enabled: false))
        #expect(!record(app: "com.1password.1password"))
        #expect(!record(text: "  \n"))
        #expect(!record(text: String(repeating: "a", count: HistoryPolicy.maxCharacters + 1)))
    }

    @Test func entriesNeverPrintTheirText() {
        let e = entry("my secret words", raw: "my secret word", at: Date())
        #expect(!String(describing: e).contains("secret"))
        #expect(!String(reflecting: e).contains("secret"))
        #expect(!"\(e)".contains("secret"))
    }

    @Test func preferencesDefaultToOnFor30DaysWithPasswordManagersExcluded() throws {
        let suite = "chirp-history-prefs-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        #expect(prefs.historyEnabled)
        #expect(prefs.historyRetention == .thirtyDays)
        #expect(prefs.historyExcludedApps == HistoryPolicy.defaultExcludedApps)
        prefs.historyEnabled = false
        prefs.historyRetention = .forever
        prefs.historyExcludedApps = ["a", "a", "", "b"]
        #expect(!prefs.historyEnabled)
        #expect(prefs.historyRetention == .forever)
        #expect(prefs.historyExcludedApps == ["a", "b"])
        prefs.historyExcludedApps = []
        #expect(prefs.historyExcludedApps.isEmpty)
    }

    @MainActor @Test func theObservableHistoryRecordsUsesRawAndUndoesADelete() async throws {
        let dir = historyDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        let history = DictationHistory(store: DictationHistoryStore(directory: dir, keys: MemoryHistoryKeyStore()))
        var changes = 0
        history.onChange = { changes += 1 }
        let e = entry("Cleaned text.", raw: "cleaned text", at: Date())
        await history.record(e)
        #expect(history.entries.map(\.text) == ["Cleaned text."])
        await history.usedRaw(e.id)
        #expect(history.entries.first?.text == "cleaned text")
        let removed = try #require(await history.delete(e.id))
        #expect(history.entries.isEmpty)
        await history.restore(removed)
        #expect(history.recent().map(\.id) == [e.id])
        await history.clear()
        #expect(history.entries.isEmpty)
        #expect(changes >= 5)
        #expect(!history.unavailable)
    }

    @MainActor @Test func aLockedKeychainShowsAsUnavailableNotEmpty() async throws {
        let dir = historyDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
        try await DictationHistoryStore(directory: dir, keys: MemoryHistoryKeyStore()).add(entry("x", at: Date()))
        let history = DictationHistory(store: DictationHistoryStore(directory: dir, keys: FailingKeys()))
        await history.reload()
        #expect(history.unavailable)
    }
}

/// The History window's model: day groups, search, delete with Undo, and its words.
@MainActor struct HistoryModelTests {
    private let now = Date(timeIntervalSince1970: 1_792_000_000)   // a Wednesday, 17:46 UTC
    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }

    private func model(_ entries: [DictationEntry]) -> HistoryModel {
        let m = HistoryModel()
        m.now = { [now] in now }
        m.calendar = utc
        m.show(entries)
        return m
    }

    private func entries() -> [DictationEntry] {
        [DictationEntry(date: now.addingTimeInterval(-60), text: "Ship the Kubernetes upgrade", raw: "ship the cooper netties upgrade",
                      bundleID: "com.apple.TextEdit", appName: "TextEdit", duration: 3),
         DictationEntry(date: now.addingTimeInterval(-3600), text: "lunch at noon?", bundleID: "com.tinyspeck.slackmacgap", appName: "Slack"),
         DictationEntry(date: now.addingTimeInterval(-86400), text: "Yesterday's note"),
         DictationEntry(date: now.addingTimeInterval(-3 * 86400), text: "Sunday thoughts"),
         DictationEntry(date: now.addingTimeInterval(-400 * 86400), text: "Long ago")]
    }

    @Test func groupsByDayNewestFirst() {
        let m = model(entries())
        #expect(m.groups.map(\.title) == ["Today", "Yesterday", "Sunday, Oct 11", "Sep 9, 2025"])
        #expect(m.groups[0].entries.count == 2)
        #expect(m.selection == m.entries[0].id)
    }

    @Test func searchFiltersTextRawAndApp() {
        let m = model(entries())
        m.query = "netties"
        #expect(m.filtered.map(\.text) == ["Ship the Kubernetes upgrade"])
        m.query = "slack"
        #expect(m.filtered.map(\.text) == ["lunch at noon?"])
        m.query = "nothing like this"
        #expect(m.groups.isEmpty)
    }

    @Test func deleteSelectsTheNextAndUndoPutsItBack() throws {
        let m = model(entries())
        var deleted: [UUID] = [], restored: [UUID] = []
        m.onDelete = { deleted.append($0) }
        m.onRestore = { restored.append($0.id) }
        let first = m.entries[0], second = m.entries[1]
        m.delete(first.id)
        #expect(deleted == [first.id] && m.selection == second.id && m.entries.count == 4)
        #expect(m.toast?.text == HistoryText.deleted && m.toast?.undo?.id == first.id)
        m.undoDelete()
        #expect(restored == [first.id] && m.selection == first.id && m.entries.first?.id == first.id && m.toast == nil)
    }

    @Test func copyChoosesTheInsertedOrTheOriginalText() {
        let m = model(entries())
        var copied: [String] = []
        m.onCopy = { copied.append($0) }
        m.copy(m.entries[0])
        m.copy(m.entries[0], raw: true)
        m.copy(m.entries[1], raw: true)   // nothing was cleaned: the inserted text
        #expect(copied == ["Ship the Kubernetes upgrade", "ship the cooper netties upgrade", "lunch at noon?"])
        #expect(m.flash == "Copied")
    }

    @Test func words() {
        let e = entries()[0]
        #expect(HistoryText.meta(DictationEntry(date: now.addingTimeInterval(-60), text: "x", duration: 4.2, style: "email"), now: now, calendar: utc)
                    .replacingOccurrences(of: "\u{202F}", with: " ") == "Today at 5:45 PM · 4.2 s · Email style")
        #expect(HistoryText.duration(65) == "1 min 5 s" && HistoryText.duration(120) == "2 min" && HistoryText.duration(3) == "3 s")
        #expect(HistoryText.keptFor(.thirtyDays) == "Kept on this Mac for 30 days · encrypted")
        #expect(HistoryText.keptFor(.forever).hasPrefix("Kept on this Mac until you delete them"))
        #expect(HistoryText.menuTitle(DictationEntry(date: now, text: "one\ntwo   three"), limit: 40) == "one two three")
        #expect(HistoryText.menuTitle(DictationEntry(date: now, text: String(repeating: "word ", count: 20)), limit: 20).count == 20)
        #expect(e.appTitle == "TextEdit" && DictationEntry(date: now, text: "x").appTitle == "Unknown app")
    }
}
