import Foundation

/// "Keep clean-up ready" (once "Keep clean-up model loaded"): the client side of `GET`/`PUT /v1/correction/settings`. The server loads its managed
/// MLX clean-up model on first use and unloads it after a pause; this setting keeps it in memory instead. Everything
/// here is pure (decoding, error mapping, wording, the state transitions), so it is unit-tested without a server.

/// The server's answer to `GET` and `PUT /v1/correction/settings`.
public struct CleanupModelSettings: Decodable, Sendable, Equatable {
    /// Where clean-up runs on the server. Only `managed` (its own MLX model) can be kept loaded.
    public enum Mode: Sendable, Equatable {
        case off, managed, endpoint
        case other(String)

        init(_ raw: String) {
            switch raw {
            case "off": self = .off
            case "managed": self = .managed
            case "endpoint": self = .endpoint
            default: self = .other(raw)
            }
        }
    }

    public var keepLoaded: Bool
    public var loaded: Bool
    public var loading: Bool
    /// The catalog id of the model, nil when there is none.
    public var model: String?
    /// The helper's memory in MB: measured while loaded, else the last measurement or a catalog estimate. nil unless managed.
    public var memoryMB: Int?
    /// `memoryMB` is a catalog estimate, not a measurement.
    public var memoryEstimated: Bool
    public var mode: Mode

    public init(keepLoaded: Bool, loaded: Bool = false, loading: Bool = false, model: String? = nil, memoryMB: Int? = nil,
                memoryEstimated: Bool = false, mode: Mode = .managed) {
        self.keepLoaded = keepLoaded
        self.loaded = loaded
        self.loading = loading
        self.model = model
        self.memoryMB = memoryMB
        self.memoryEstimated = memoryEstimated
        self.mode = mode
    }

    private enum CodingKeys: String, CodingKey {
        case keepLoaded = "keep_loaded", loaded, loading, model, memoryMB = "memory_mb", memoryEstimated = "memory_estimated", mode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keepLoaded = try c.decode(Bool.self, forKey: .keepLoaded)
        loaded = try c.decodeIfPresent(Bool.self, forKey: .loaded) ?? false
        loading = try c.decodeIfPresent(Bool.self, forKey: .loading) ?? false
        model = try c.decodeIfPresent(String.self, forKey: .model)
        memoryMB = try c.decodeIfPresent(Int.self, forKey: .memoryMB)
        memoryEstimated = try c.decodeIfPresent(Bool.self, forKey: .memoryEstimated) ?? false
        mode = Mode(try c.decodeIfPresent(String.self, forKey: .mode) ?? "managed")
    }

    /// "2.6 GB", or "about 2.6 GB" for an estimate; nil without a memory figure.
    public var memoryText: String? {
        memoryMB.map { KeepLoaded.memoryText(mb: $0, estimated: memoryEstimated) }
    }
}

/// Why a request to `/v1/correction/settings` did not give settings.
public enum CleanupSettingsError: Error, Sendable, Equatable {
    /// 401: the bearer token is missing or wrong.
    case unauthorized
    /// 404: a server that predates the setting.
    case serverTooOld
    /// 409 `unsupported`: clean-up is off or runs on a remote endpoint, so there is no model to keep loaded.
    case unsupported
    /// 400: the server did not accept the body.
    case badRequest
    /// No answer (offline, refused, timed out).
    case unreachable
    /// Any other status.
    case server(Int)
    /// A 200 that is not the documented shape.
    case malformed

    static func status(_ code: Int) -> CleanupSettingsError {
        switch code {
        case 401: .unauthorized
        case 404: .serverTooOld
        case 409: .unsupported
        case 400: .badRequest
        default: .server(code)
        }
    }

    /// One sentence for an inline error under the switch after a failed change.
    public var changeFailure: String {
        switch self {
        case .unauthorized: "The server did not accept Chirp’s token, so nothing changed."
        case .serverTooOld: KeepLoaded.updateServer
        case .unsupported: "This server’s clean-up has no model to keep loaded."
        case .badRequest: "The server did not accept that change."
        case .unreachable: "Can’t reach the server, so nothing changed."
        case .server(let code): "The server answered with an error (\(code)), so nothing changed."
        case .malformed: "The server’s answer was not understood, so nothing changed."
        }
    }
}

extension ServerConfig {
    public var cleanupSettingsURL: URL { baseURL.appendingPathComponent("v1/correction/settings") }

    /// The `PUT` body: exactly `{"keep_loaded": <bool>}`.
    public static func keepLoadedBody(_ on: Bool) -> Data {
        Data((on ? #"{"keep_loaded":true}"# : #"{"keep_loaded":false}"#).utf8)
    }

    /// `GET /v1/correction/settings`.
    public func fetchCleanupSettings(session: URLSession = .shared) async throws(CleanupSettingsError) -> CleanupModelSettings {
        var req = authorized(URLRequest(url: cleanupSettingsURL))
        req.timeoutInterval = 3
        return try await Self.perform(req, session: session)
    }

    /// `PUT /v1/correction/settings`: keeps the model loaded (or lets the idle timer unload it). Answers like `GET`.
    public func setKeepLoaded(_ on: Bool, session: URLSession = .shared) async throws(CleanupSettingsError) -> CleanupModelSettings {
        var req = authorized(URLRequest(url: cleanupSettingsURL))
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.keepLoadedBody(on)
        req.timeoutInterval = 5
        return try await Self.perform(req, session: session)
    }

    private static func perform(_ req: URLRequest, session: URLSession) async throws(CleanupSettingsError) -> CleanupModelSettings {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: req) } catch { throw .unreachable }
        guard let http = response as? HTTPURLResponse else { throw .malformed }
        guard http.statusCode == 200 else { throw .status(http.statusCode) }
        do { return try JSONDecoder().decode(CleanupModelSettings.self, from: data) } catch { throw .malformed }
    }
}

public enum KeepLoaded {
    public static let title = "Keep clean-up ready"
    /// What it does, in front of the memory cost.
    public static let benefit = "Keeps the clean-up model in memory, so clean-up starts instantly instead of loading the model after a pause."
    public static let updateServer = "Update the Chirp server to use this."

    /// MB as GB with one decimal ("2.6 GB"; 1 GB = 1024 MB, as the helper counts), prefixed "about" for an estimate.
    public static func memoryText(mb: Int, estimated: Bool) -> String {
        let gb = (Double(max(mb, 0)) / 1024 * 10).rounded() / 10
        let text = String(format: "%.1f GB", gb)
        return estimated ? "about \(text)" : text
    }

    /// Where the memory is used: "this Mac" for a server on loopback, else its host.
    public static func hostPhrase(_ config: ServerConfig) -> String { config.isLoopback ? "this Mac" : "your Chirp server" }

    /// Why the switch cannot be used, in one line.
    public enum Unavailable: Sendable, Equatable {
        case cleanupOff, remoteModel, serverTooOld, unreachable, unauthorized

        public var reason: String {
            switch self {
            case .cleanupOff: "The server has clean-up turned off."
            case .remoteModel: "Not needed: this server sends text to a remote model."
            case .serverTooOld: KeepLoaded.updateServer
            case .unreachable: "Can’t reach the server."
            case .unauthorized: "The server did not accept Chirp’s token."
            }
        }
    }
}

/// What Settings → Clean-up's Keep clean-up ready switch shows, as the server's answers come in. The switch changes at once and goes back with
/// an inline error when the server refuses.
public struct KeepLoadedState: Sendable, Equatable {
    public enum Availability: Sendable, Equatable {
        /// Nothing fetched yet.
        case unknown
        case available
        case unavailable(KeepLoaded.Unavailable)
    }

    public private(set) var settings: CleanupModelSettings?
    public private(set) var availability: Availability
    /// The value the user just chose, while its `PUT` is in flight.
    public private(set) var pending: Bool?
    public private(set) var error: String?

    public init(settings: CleanupModelSettings? = nil, availability: Availability = .unknown, pending: Bool? = nil, error: String? = nil) {
        self.settings = settings
        self.availability = availability
        self.pending = pending
        self.error = error
    }

    /// The server's settings arrived (`GET` or `PUT`).
    public mutating func received(_ s: CleanupModelSettings) {
        switch s.mode {
        case .managed:
            settings = s
            availability = .available
        case .off:
            settings = nil
            availability = .unavailable(.cleanupOff)
        case .endpoint, .other:
            settings = nil
            availability = .unavailable(.remoteModel)
        }
    }

    /// A `GET` answered. A refused change is not replaced by a refresh that happens to land meanwhile.
    public mutating func fetched(_ s: CleanupModelSettings) {
        guard pending == nil else { return }
        received(s)
    }

    public mutating func fetchFailed(_ e: CleanupSettingsError) {
        guard pending == nil else { return }
        settings = nil
        availability = .unavailable(Self.unavailable(for: e))
    }

    /// The user flipped the switch. False when it cannot change now (unavailable, or a change is in flight).
    public mutating func toggle(to on: Bool) -> Bool {
        guard availability == .available, pending == nil else { return false }
        pending = on
        error = nil
        return true
    }

    public mutating func toggleSucceeded(_ s: CleanupModelSettings) {
        pending = nil
        error = nil
        received(s)
    }

    /// The change was refused or never arrived: the switch goes back and says why. A server that turns out not to
    /// support the setting stops offering it.
    public mutating func toggleFailed(_ e: CleanupSettingsError) {
        pending = nil
        switch e {
        case .serverTooOld, .unsupported, .unauthorized:
            settings = nil
            availability = .unavailable(Self.unavailable(for: e))
            error = nil
        default:
            error = e.changeFailure
        }
    }

    static func unavailable(for e: CleanupSettingsError) -> KeepLoaded.Unavailable {
        switch e {
        case .serverTooOld: .serverTooOld
        case .unsupported: .remoteModel
        case .unauthorized: .unauthorized
        default: .unreachable
        }
    }

    /// The model is on its way into memory, so the tab keeps checking until it is loaded.
    public var isLoading: Bool { settings?.loading == true }
}

/// The wording and states of the switch row, derived from `KeepLoadedState` and the server's host.
public struct KeepLoadedPresentation: Sendable, Equatable {
    public enum Tone: Sendable, Equatable { case ok, busy, idle }

    public var isOn: Bool
    public var isEnabled: Bool
    /// Under the switch: what it does and its memory cost, or why it is unavailable.
    public var help: String
    /// "Loaded · 2.6 GB", "Loading…" or "Not loaded"; nil when there is no model state to show.
    public var status: String?
    public var statusTone: Tone
    public var error: String?

    public init(_ state: KeepLoadedState, host: String = "this Mac") {
        error = state.error
        switch state.availability {
        case .unknown:
            isOn = false
            isEnabled = false
            help = "Checking the server…"
            status = nil
            statusTone = .idle
        case .unavailable(let why):
            isOn = false
            isEnabled = false
            help = why.reason
            status = nil
            statusTone = .idle
        case .available:
            let s = state.settings
            isOn = state.pending ?? s?.keepLoaded ?? false
            isEnabled = state.pending == nil
            var text = KeepLoaded.benefit
            if let memory = s?.memoryText { text += " Uses \(memory) of RAM on \(host)." }
            help = text
            // Turning it on starts the load, so say so before the server's next answer.
            let loading = s?.loading == true || (state.pending == true && s?.loaded != true)
            if loading {
                status = "Loading…"
                statusTone = .busy
            } else if s?.loaded == true {
                status = s?.memoryText.map { "Loaded · \($0)" } ?? "Loaded"
                statusTone = .ok
            } else {
                status = "Not loaded"
                statusTone = .idle
            }
        }
    }

    /// With the server's host spelled out ("this Mac" for loopback).
    public init(_ state: KeepLoadedState, config: ServerConfig) {
        self.init(state, host: KeepLoaded.hostPhrase(config))
    }
}

/// The one-time hint after a dictation waited on a cold clean-up model: the moment the cost of leaving it unloaded is
/// felt. It is shown once ever, never during a dictation, and only when the server said its model was not ready as
/// clean-up began and the wait was long enough to notice.
public enum KeepLoadedHint {
    /// Polishing shorter than this goes unnoticed, so no hint.
    public static let minimumWait: TimeInterval = 2
    public static let message = "Clean-up was loading its model. Keep it ready in Settings → Clean-up."
    /// How long the toast stays up.
    public static let duration: TimeInterval = 4

    /// The server's answer as clean-up began says it had to load the model, and this switch would have avoided that.
    public static func coldLoad(_ s: CleanupModelSettings) -> Bool {
        s.mode == .managed && !s.keepLoaded && (s.loading || !s.loaded)
    }

    /// Whether the hint is due after a dictation: not shown before, the model was cold, and the user waited for it.
    public static func shouldShow(alreadyShown: Bool, cold: Bool, waited: TimeInterval) -> Bool {
        !alreadyShown && cold && waited >= minimumWait
    }
}
