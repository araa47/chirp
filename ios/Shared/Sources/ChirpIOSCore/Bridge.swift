import Foundation

public enum BridgeRole: Sendable { case app, keyboard }
public enum BridgeAction: Codable, Sendable, Equatable {
    case start, stop, cancel, end, useRaw, style(String), privacy(Bool)
    /// The keyboard takes a dictation the app started for another app (the floating mic, Toggle, a key): it types the
    /// text into the field it is showing in, so the app doesn't copy it.
    case adopt
}
public enum BridgeResultKind: String, Codable, Sendable { case partial, correcting, final, raw }
public struct BridgeState: Codable, Sendable, Equatable {
    public var generation: UUID
    public var phase: SessionPhase
    public var utteranceID: UUID?
    public var leaseUntil: Date
    public var sessionExpiresAt: Date?
    public var debugRetention: Bool
    public var privacyMode: Bool
    public var styleID: String
    public var availableStyleIDs: [String]
    public var errorCode: DiagnosticCode?
    /// The keyboard applies spoken commands to finals. Optional so older mailboxes still decode.
    public var spokenCommands: Bool?
    /// The keyboard's auto-Enter mode (raw value of `AutoEnterMode`); nil is off.
    public var autoEnter: String?
    /// The current dictation was started for another app (the floating mic, Toggle, a key) and nothing types it yet,
    /// so a visible Chirp Keyboard may adopt it. Optional so older mailboxes still decode.
    public var adoptable: Bool?
    public init(generation: UUID, phase: SessionPhase, utteranceID: UUID? = nil, leaseUntil: Date,
                sessionExpiresAt: Date? = nil, debugRetention: Bool = false, privacyMode: Bool = false,
                styleID: String = "default", availableStyleIDs: [String] = ["default"], errorCode: DiagnosticCode? = nil,
                spokenCommands: Bool? = nil, autoEnter: String? = nil, adoptable: Bool? = nil) {
        self.generation = generation; self.phase = phase; self.utteranceID = utteranceID; self.leaseUntil = leaseUntil
        self.sessionExpiresAt = sessionExpiresAt; self.debugRetention = debugRetention; self.privacyMode = privacyMode
        self.styleID = styleID; self.availableStyleIDs = availableStyleIDs; self.errorCode = errorCode
        self.spokenCommands = spokenCommands; self.autoEnter = autoEnter; self.adoptable = adoptable
    }
}
public struct BridgeCommand: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var generation: UUID
    public var utteranceID: UUID?
    public var action: BridgeAction
    public var createdAt: Date
    public var expiresAt: Date
    public init(id: UUID = UUID(), generation: UUID, utteranceID: UUID? = nil, action: BridgeAction,
                createdAt: Date = Date(), expiresAt: Date) {
        self.id = id; self.generation = generation; self.utteranceID = utteranceID; self.action = action
        self.createdAt = createdAt; self.expiresAt = expiresAt
    }
}
public struct BridgeResult: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var generation: UUID
    public var utteranceID: UUID
    public var kind: BridgeResultKind
    public var text: String
    public var raw: String?
    public var sequence: Int
    public var createdAt: Date
    public var expiresAt: Date
    /// A final that is only what was heard before the connection failed (no clean-up). Optional so older
    /// mailboxes still decode.
    public var kept: Bool?
    /// Long dictation: which segment this is (nil for the first). A segment's text starts with its separator.
    public var segment: Int?
    public init(id: UUID = UUID(), generation: UUID, utteranceID: UUID, kind: BridgeResultKind, text: String,
                raw: String? = nil, sequence: Int = 0, createdAt: Date = Date(), expiresAt: Date, kept: Bool? = nil,
                segment: Int? = nil) {
        self.id = id; self.generation = generation; self.utteranceID = utteranceID; self.kind = kind
        self.text = text; self.raw = raw; self.sequence = sequence; self.createdAt = createdAt; self.expiresAt = expiresAt
        self.kept = kept; self.segment = segment
    }
}

/// One bounded, atomic AES-GCM mailbox, with separate logical writers and a stable cross-process lock.
/// Darwin wakes are hints only: always reconcile state from disk after appearance/foreground.
public final class SharedBridge: Sendable {
    public static let keyAccount = "bridge.aes.v1"
    public static let maximumLease: TimeInterval = 15
    public static let maximumTTL: TimeInterval = 120
    public static let maximumQueue = 64
    public static let maximumBytes = 256 * 1024
    private struct Receipt: Codable, Equatable { var id: UUID; var expiresAt: Date }
    private struct Document: Codable, Equatable {
        var state: BridgeState?
        var commands: [BridgeCommand] = []
        var results: [BridgeResult] = []
        var receipts: [Receipt] = []
        var retired: [Receipt] = []
        var utterances: [Receipt] = []
        var sequence = -1
        var resultUtterance: UUID?
        var finalPublished = false
        var rawPublished = false
        /// Long dictation: the segment whose results are being published. Optional so older mailboxes decode.
        var segment: Int?
    }
    private let sealed: SealedStorage
    private let role: BridgeRole
    private let now: @Sendable () -> Date
    public init(root: URL, secrets: any SecretStore, role: BridgeRole,
                now: @escaping @Sendable () -> Date = { Date() }) throws {
        sealed = SealedStorage(files: try ProtectedFiles(root: root.appendingPathComponent("bridge", isDirectory: true)),
                               secrets: secrets, account: Self.keyAccount)
        self.role = role; self.now = now
    }
    private func require(_ role: BridgeRole) throws { guard self.role == role else { throw CoreError.unauthorized } }
    private func load() throws -> Document {
        try sealed.load(Document.self, "mailbox.sealed", max: Self.maximumBytes) ?? Document()
    }
    private func save(_ d: Document) throws { try sealed.save(d, "mailbox.sealed", max: Self.maximumBytes) }
    private func retire(_ generation: UUID, in d: inout Document) throws {
        if !d.retired.contains(where: { $0.id == generation }) {
            guard d.retired.count < 128 else { throw CoreError.queueFull }
            d.retired.append(Receipt(id: generation, expiresAt: now().addingTimeInterval(Self.maximumTTL)))
        }
    }
    private func prune(_ d: inout Document) throws {
        let time = now()
        d.receipts.removeAll { $0.expiresAt <= time }
        d.retired.removeAll { $0.expiresAt <= time }
        d.utterances.removeAll { $0.expiresAt <= time }
        d.commands.removeAll { $0.expiresAt <= time }
        d.results.removeAll { $0.expiresAt <= time }
        if let state = d.state,
           state.leaseUntil <= time || (state.sessionExpiresAt.map { $0 <= time } ?? false) {
            try retire(state.generation, in: &d)
            d.state = nil; d.commands = []; d.results = []
        }
    }
    private func pruned() throws -> Document {
        var d = try load()
        let previous = d
        try prune(&d)
        // Persist actual cleanup even when the operation that follows is rejected.
        // Frequent keyboard reconciliation must not reencrypt/fsync unchanged state.
        if d != previous { try save(d) }
        return d
    }
    private func validTime(created: Date, expires: Date) throws {
        guard created.timeIntervalSince1970.isFinite, expires.timeIntervalSince1970.isFinite,
              created <= now().addingTimeInterval(2), expires > now(), expires > created,
              expires.timeIntervalSince(created) <= Self.maximumTTL else { throw CoreError.expired }
    }
    private func receipt(_ id: UUID, expires: Date, in d: inout Document) throws {
        guard !d.receipts.contains(where: { $0.id == id }) else { throw CoreError.replay }
        guard d.receipts.count < 512 else { throw CoreError.queueFull }
        d.receipts.append(Receipt(id: id, expiresAt: expires))
    }
    private func current(_ generation: UUID, _ d: Document) throws -> BridgeState {
        guard let state = d.state, state.generation == generation else { throw CoreError.staleGeneration }
        return state
    }
    public func state() throws -> BridgeState? {
        try sealed.files.transaction {
            let d = try pruned()
            return d.state
        }
    }
    public func publish(_ state: BridgeState) throws {
        try require(.app)
        guard state.leaseUntil > now(), state.leaseUntil <= now().addingTimeInterval(Self.maximumLease),
              state.sessionExpiresAt.map({ $0 > now() && $0.timeIntervalSince1970.isFinite }) ?? true,
              state.styleID.utf8.count <= 128, state.availableStyleIDs.count <= 32,
              state.availableStyleIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }) else { throw CoreError.invalidState }
        try sealed.files.transaction {
            var d = try pruned()
            guard !d.retired.contains(where: { $0.id == state.generation }) else { throw CoreError.staleGeneration }
            if let previous = d.state, previous.generation != state.generation {
                try retire(previous.generation, in: &d)
                d.commands = []; d.results = []; d.sequence = -1; d.resultUtterance = nil
                d.finalPublished = false; d.rawPublished = false; d.segment = nil
            }
            if d.state?.utteranceID != state.utteranceID {
                // Results for a previous utterance cannot cross an ownership boundary.
                d.results = []; d.sequence = -1; d.resultUtterance = state.utteranceID
                d.finalPublished = false; d.rawPublished = false; d.segment = nil
            }
            d.state = state
            if state.phase == .idle || state.phase == .failed { d.commands = []; d.results = [] }
            try save(d)
        }
    }
    public func send(_ command: BridgeCommand) throws {
        try require(.keyboard); try validTime(created: command.createdAt, expires: command.expiresAt)
        try sealed.files.transaction {
            var d = try pruned()
            let state = try current(command.generation, d)
            switch command.action {
            case .start:
                guard command.utteranceID != nil, state.phase == .armed || state.phase == .finished,
                      !d.commands.contains(where: { if case .start = $0.action { return true }; return false })
                else { throw CoreError.invalidState }
                guard !d.utterances.contains(where: { $0.id == command.utteranceID! }) else { throw CoreError.replay }
                guard d.utterances.count < 128 else { throw CoreError.queueFull }
                d.utterances.append(Receipt(id: command.utteranceID!, expiresAt: now().addingTimeInterval(Self.maximumTTL)))
            case .stop, .cancel, .useRaw:
                guard let id = command.utteranceID, id == state.utteranceID else { throw CoreError.foreignUtterance }
            case .adopt:
                // Only the dictation the app offers, while it is live.
                guard let id = command.utteranceID, id == state.utteranceID else { throw CoreError.foreignUtterance }
                guard state.adoptable == true else { throw CoreError.invalidState }
            case .style(let id): guard state.availableStyleIDs.contains(id) else { throw CoreError.invalidState }
            case .end, .privacy: break
            }
            guard d.commands.count < Self.maximumQueue else { throw CoreError.queueFull }
            try receipt(command.id, expires: command.expiresAt, in: &d)
            d.commands.append(command); try save(d)
        }
    }
    public func takeCommands(generation: UUID) throws -> [BridgeCommand] {
        try require(.app)
        return try sealed.files.transaction {
            var d = try pruned()
            let state = try current(generation, d)
            let commands = d.commands.filter { command in
                guard command.generation == generation else { return false }
                switch command.action {
                case .stop, .cancel, .useRaw: return command.utteranceID == state.utteranceID
                default: return true
                }
            }
            d.commands = []; try save(d); return commands
        }
    }
    public func publish(_ result: BridgeResult) throws {
        try require(.app); try validTime(created: result.createdAt, expires: result.expiresAt)
        guard result.sequence >= 0, result.text.utf8.count <= 65_536, (result.raw?.utf8.count ?? 0) <= 65_536 else {
            throw CoreError.oversized
        }
        try sealed.files.transaction {
            var d = try pruned()
            let state = try current(result.generation, d)
            guard state.utteranceID == result.utteranceID else { throw CoreError.foreignUtterance }
            guard result.sequence > d.sequence else { throw CoreError.replay }
            let segment = result.segment ?? 0, published = d.segment ?? 0
            if segment > published {
                // The next segment of a long dictation opens only after this one's final, strictly in order.
                guard segment == published + 1, d.finalPublished, result.kind != .raw else { throw CoreError.invalidState }
                d.segment = segment; d.finalPublished = false; d.rawPublished = false
            } else if segment < published { throw CoreError.invalidState }
            if d.finalPublished {
                guard result.kind == .raw, !d.rawPublished else { throw CoreError.invalidState }
            } else if result.kind == .raw { throw CoreError.invalidState }
            try receipt(result.id, expires: result.expiresAt, in: &d)
            // Partials are replaceable snapshots. Preserve correcting/final/raw and bound slow readers.
            if result.kind == .partial { d.results.removeAll { $0.kind == .partial } }
            guard d.results.count < Self.maximumQueue else { throw CoreError.queueFull }
            d.results.append(result); d.sequence = result.sequence; d.resultUtterance = result.utteranceID
            if result.kind == .final { d.finalPublished = true }
            if result.kind == .raw { d.rawPublished = true }
            try save(d)
        }
    }
    /// Successful return consumes matching text in one transaction. Receipts/sequence survive consumption.
    public func takeResults(generation: UUID, utteranceID: UUID) throws -> [BridgeResult] {
        try require(.keyboard)
        return try sealed.files.transaction {
            var d = try pruned()
            let state = try current(generation, d)
            guard state.utteranceID == utteranceID else { throw CoreError.foreignUtterance }
            let results = d.results.filter { $0.generation == generation && $0.utteranceID == utteranceID }
            d.results.removeAll { $0.generation == generation && $0.utteranceID == utteranceID }
            try save(d); return results
        }
    }
    public func endSession() throws {
        try require(.app)
        try sealed.files.transaction {
            var d = try pruned()
            if let state = d.state { try retire(state.generation, in: &d) }
            d.state = nil; d.commands = []; d.results = []; d.sequence = -1; d.resultUtterance = nil
            d.finalPublished = false; d.rawPublished = false; d.segment = nil
            // Tombstones contain IDs/deadlines only; no command or transcript survives session end.
            try save(d)
        }
    }
}
