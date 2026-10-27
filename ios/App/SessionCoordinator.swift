import AVFoundation
import ChirpCore
import ChirpIOSCore
import Combine
import Foundation
import UIKit

enum SessionAction { case start, stop, toggle, cancel, end }
enum DictationSource { case app, keyboard, companion }

struct AppServices {
    let pairing: PairingStore
    let preferences: PreferenceStore
    let history: HistoryStore
    let learned: IOSLearnedStore
    let bridge: SharedBridge
    let keyboardSetup: KeyboardSetupStore
    let timings: TimingLog
    init(root: URL, secrets: any SecretStore) throws {
        pairing = try PairingStore(root: root, secrets: secrets)
        preferences = try PreferenceStore(root: root)
        history = try HistoryStore(root: root, secrets: secrets)
        learned = try IOSLearnedStore(root: root, secrets: secrets)
        bridge = try SharedBridge(root: root, secrets: secrets, role: .app)
        keyboardSetup = try KeyboardSetupStore(root: root)
        timings = try TimingLog(root: root)
    }
    static func production() throws -> Self {
        let config = SharedConfiguration(bundle: .main)
        return try Self(root: config.containerURL(), secrets: KeychainSecretStore(accessGroup: config.keychainAccessGroup))
    }
}

/// Single app-process owner, reused by App Intents. Neither extension captures or streams audio.
@MainActor
final class SessionCoordinator: ObservableObject {
    static let shared = SessionCoordinator()
    @Published private(set) var phase: SessionPhase = .idle
    @Published private(set) var armed = false
    @Published private(set) var working = false
    @Published private(set) var text = ""
    @Published private(set) var raw = ""
    @Published private(set) var words: [WordTiming] = []
    @Published private(set) var health: Health?
    @Published private(set) var paired = false
    @Published private(set) var notice = ""
    @Published private(set) var debugRetention = false
    @Published private(set) var canUseRaw = false
    /// Long dictation: what earlier segments contributed, shown before the live segment's `text`.
    @Published private(set) var earlierText = ""
    /// Why the last attempt to reach the Mac failed; nil once it answers.
    @Published private(set) var connectionIssue: ConnectionIssue?
    /// The name this device was paired under on the Mac; nil for the shared token.
    @Published private(set) var pairedDevice: String?
    /// Chirp Keyboard has opened with Full Access at least once (see `KeyboardSetupStore`).
    @Published private(set) var keyboardReady = false
    @Published var preferences = IOSPreferences()
    @Published private(set) var profiles: [CorrectionProfile] = []
    @Published private(set) var diagnostics: [DiagnosticEvent] = []
    /// Content-free timings of recent dictations (SessionTimings.swift), as shown in Diagnostics.
    @Published private(set) var timingSummary = ""
    private(set) var services: AppServices?
    /// Live Notes holds the microphone: a keyboard session cannot arm meanwhile.
    var otherCaptureActive: () -> Bool = { false }
    private let audio: any SessionAudio
    private let http: URLSession
    private let makeStream: (ServerConfig, StartOptions, URLSession) -> StreamSession
    private let requestPermission: () async -> Bool
    private let permissionGranted: () -> Bool
    private let activityBegin: (Bool) throws -> Void
    private let activityActive: () -> Bool
    private let activityUpdate: (String, Bool) async -> Void
    private let activityEnd: () async -> Void
    private let copyText: (String) -> Void
    private let appActive: () -> Bool
    private let now: () -> Date
    private var config: ServerConfig?
    private var generation = UUID()
    private var lifecycle = UUID()
    private var utterance: UUID?
    private var companion: UUID?
    private var utteranceSource: DictationSource?
    private var privateUtterance = false
    private var sequence = 0
    private var lastServerSequence = -1
    private var stream: StreamSession?
    private var ready = false
    private var stopRequested = false
    /// When an armed session ends by itself (nil: Never); the session capsule counts down to it.
    private(set) var expiresAt: Date?
    private var heartbeat: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var utteranceLimit: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private var rawExpiry: Task<Void, Never>?
    /// When Use raw stops being offered after a final (five seconds on), for its countdown label.
    private(set) var rawExpiresAt: Date?
    private var observation: DarwinObservation?
    private var activityTeardown: Task<Void, Never>?
    private var systemObservers: [NSObjectProtocol] = []
    private var waiters: [UUID: [CheckedContinuation<Void, Error>]] = [:]
    private var historyID: UUID?
    /// Published to the keyboard so it can explain the last failure.
    private var lastError: DiagnosticCode?
    // Long dictation (RollingDictation.swift): `stream` is always the live segment.
    private var utteranceOptions: StartOptions?
    private var segmentIndex = 0
    private var finishing: [FinishingSegment] = []
    private var landed: [(text: String, raw: String)] = []
    private var heldLive: (kind: BridgeResultKind, text: String, raw: String?)?
    private var liveFinal: (result: FinalResult, kept: Bool)?
    private var timer: SessionTimer?
    private let network: () -> SessionTiming.Network
    private var startingUtterance = false
    private let signal = DarwinSignal(name: DarwinSignal.bridgeChanged)

    init(services: AppServices? = nil, audio: (any SessionAudio)? = nil,
         http: URLSession = SafeHTTPSession.make(),
         makeStream: @escaping (ServerConfig, StartOptions, URLSession) -> StreamSession = { StreamSession(config: $0, options: $1, urlSession: $2) },
         requestPermission: @escaping () async -> Bool = { await AVAudioApplication.requestRecordPermission() },
         permissionGranted: @escaping () -> Bool = { AVAudioApplication.shared.recordPermission == .granted },
         activityBegin: @escaping (Bool) throws -> Void = { try ChirpLiveActivity.begin(debugRetention: $0) },
         activityActive: @escaping () -> Bool = { ChirpLiveActivity.isActive },
         activityUpdate: @escaping (String, Bool) async -> Void = { await ChirpLiveActivity.update(phase: $0, debugRetention: $1) },
         activityEnd: @escaping () async -> Void = { await ChirpLiveActivity.end() },
         copyText: @escaping (String) -> Void = { UIPasteboard.general.string = $0 },
         appActive: @escaping () -> Bool = { UIApplication.shared.applicationState == .active },
         now: @escaping () -> Date = Date.init,
         network: @escaping () -> SessionTiming.Network = { NetworkKind.shared.current },
         production: Bool = true) {
        #if DEBUG
        self.audio = audio ?? SimulatorFileAudio.fromArguments() ?? MicrophoneCapture()
        #else
        self.audio = audio ?? MicrophoneCapture()
        #endif
        self.http = http; self.makeStream = makeStream; self.requestPermission = requestPermission; self.permissionGranted = permissionGranted
        self.activityBegin = activityBegin; self.activityActive = activityActive
        self.activityUpdate = activityUpdate; self.activityEnd = activityEnd; self.copyText = copyText; self.appActive = appActive; self.now = now; self.network = network
        do {
            let stores = try services ?? (production ? AppServices.production() : nil)
            self.services = stores
            preferences = try stores?.preferences.load() ?? IOSPreferences()
            config = try stores?.pairing.load()
            paired = config != nil
            try stores?.bridge.endSession()
        } catch { notice = SessionFailure.storage.localizedDescription }
        refreshSetup(); refreshTimings()
        guard production else { return }
        observation = signal.observe { [weak self] in Task { @MainActor in self?.processCommands() } }
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
                     AVAudioSession.mediaServicesWereResetNotification] {
            systemObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                if name == AVAudioSession.routeChangeNotification,
                   let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                   AVAudioSession.RouteChangeReason(rawValue: raw) == .categoryChange { return }
                if name == AVAudioSession.interruptionNotification,
                   let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                   AVAudioSession.InterruptionType(rawValue: raw) == .ended { return }
                MainActor.assumeIsolated {
                    guard let self, self.armed else { return }
                    let ticket = self.lifecycle
                    Task { @MainActor in
                        guard self.armed, self.lifecycle == ticket else { return }
                        self.endSession(code: .interrupted)
                    }
                }
            })
        }
    }

    /// Verifies the link against the Mac and saves the pairing; true once it is saved.
    @discardableResult func pair(link: String) async -> Bool {
        guard !working, !armed, let services else { return false }
        working = true
        let ticket = lifecycle
        defer { working = false }
        let seen = IssueBox()
        do {
            let credentials = try PairingLink.parse(link)
            let checked = try await services.pairing.verifyAndSave(credentials) { [http] config in
                do { let checked = try await config.checkedHealth(session: http); seen.device = checked.device; return checked.health }
                catch { seen.issue = ConnectionIssue.classify(error); throw error }
            }
            pairedDevice = seen.device
            guard ticket == lifecycle else { return false }
            config = try services.pairing.load(); paired = config != nil
            reached(checked)
            notice = "Computer verified and pairing saved."
            await loadProfiles()
            return true
        } catch {
            let issue = (error as? CoreError) == .unauthorized ? .refused : seen.issue
            notice = issue?.message ?? "Could not verify pairing. Check the link, Tailscale and your computer."
            connectionIssue = issue; record(issue?.diagnostic ?? .auth)
            return false
        }
    }

    func forgetPairing() {
        endSession()
        do { try services?.pairing.clear(); config = nil; paired = false; health = nil; profiles = []; pairedDevice = nil }
        catch { notice = SessionFailure.storage.localizedDescription }
        preferences.consentHost = nil; savePreferences()
    }

    func checkConnection() async {
        guard let config, !working else { return }
        working = true
        let ticket = lifecycle
        defer { working = false }
        do {
            let checked = try await healthy(config)
            guard ticket == lifecycle else { return }
            reached(checked); notice = "Computer connection verified."
            await loadProfiles()
        } catch {}
    }

    /// Authenticated health or a classified failure. A failure keeps an armed session (and the keyboard's
    /// view of it) alive with the reason, so the user can retry once the Mac is back.
    private func healthy(_ config: ServerConfig) async throws -> Health {
        let checked: Health
        do { let result = try await config.checkedHealth(session: http); checked = result.health; pairedDevice = result.device }
        catch { throw reachFailed(error) }
        guard checked.ok, checked.ready == true, checked.engine != nil else {
            throw reachFailed(ConnectionIssueError(checked.ok && checked.ready == false ? .loading : .other))
        }
        return checked
    }
    private func reachFailed(_ error: Error) -> SessionFailure {
        let issue = ConnectionIssue.classify(error)
        connectionIssue = issue; lastError = issue.diagnostic; notice = issue.message
        record(issue.diagnostic); publishState()
        return .mac(issue)
    }
    private func reached(_ value: Health) {
        connectionIssue = nil; lastError = nil
        applyHealth(value); publishState()
    }

    private func applyHealth(_ value: Health) {
        if value.correctionLeavesMachine != true || preferences.consentHost != value.correctionHost || !value.correctionAvailable {
            preferences.consentHost = nil; savePreferences()
        }
        health = value; debugRetention = value.debugRetention == true
    }
    var pairedHost: String { config?.host ?? "" }

    func loadProfiles() async {
        guard let config else { return }
        let ticket = lifecycle
        struct Response: Decodable { let profiles: [CorrectionProfile] }
        do {
            var request = config.authorized(URLRequest(url: config.baseURL.appendingPathComponent("v1/correction/profiles")))
            request.timeoutInterval = 10
            let (data, response) = try await http.data(for: request)
            guard ticket == lifecycle else { return }
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 256 * 1024 else { throw SessionFailure.connection }
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            let fetched = try decoder.decode(Response.self, from: data).profiles
            guard fetched.count <= 32 else { throw SessionFailure.connection }
            profiles = fetched
            if !profiles.contains(where: { $0.id == preferences.styleID }) { preferences.styleID = "default"; savePreferences() }
        } catch { profiles = []; notice = "Style prompts unavailable. Check your computer connection." }
    }

    var cleanupDisclosure: String {
        guard let health, health.correctionAvailable else { return "Clean-up is off on your computer." }
        if health.correctionLeavesMachine == false { return "Clean-up runs on your computer." }
        if health.correctionLeavesMachine == true, let host = health.correctionHost, !host.isEmpty { return "Sends final text to \(host). Audio stays on your computer." }
        return "Clean-up destination is unknown. Clean-up is unavailable."
    }
    var cleanupCanEnable: Bool {
        guard let health, health.correctionAvailable else { return false }
        return health.correctionLeavesMachine == false || (health.correctionLeavesMachine == true && health.correctionHost?.isEmpty == false)
    }
    func setCleanup(_ enabled: Bool) {
        preferences.correction = enabled && cleanupCanEnable
        preferences.consentHost = enabled && health?.correctionLeavesMachine == true ? health?.correctionHost : nil
        savePreferences()
    }
    func selectStyle(_ id: String) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        preferences.styleID = id; savePreferences(); publishState()
    }
    func editPrompt(_ text: String, profile: CorrectionProfile) {
        preferences.prompts[profile.id] = CorrectionProfile.clampPrompt(text, limit: min(4000, profile.maxPromptChars))
        savePreferences()
    }
    func resetPrompt(_ id: String) { preferences.prompts.removeValue(forKey: id); savePreferences() }
    func savePreferences() {
        if preferences.privacyMode { privateUtterance = true }
        do { try services?.preferences.save(preferences) }
        catch { notice = SessionFailure.storage.localizedDescription; record(.storage) }
    }

    func armSession() async throws {
        guard !otherCaptureActive() else { throw SessionFailure.notesRecording }
        if armed { try reconcileOrThrow(); return }
        guard !working, let config, services != nil else { throw SessionFailure.setup }
        working = true
        let ticket = lifecycle
        defer { working = false }
        guard await requestPermission() else { throw SessionFailure.permission }
        guard ticket == lifecycle else { throw SessionFailure.cancelled }
        let checked = try await healthy(config)
        guard ticket == lifecycle else { throw SessionFailure.cancelled }
        reached(checked)
        await activityTeardown?.value
        guard ticket == lifecycle else { throw SessionFailure.cancelled }
        try activityBegin(debugRetention)
        do {
            try audio.arm { [weak self] in Task { @MainActor in
                guard let self, self.armed, self.lifecycle == ticket else { return }
                self.endSession(code: .interrupted)
            } }
        } catch { await activityEnd(); throw SessionFailure.audio }
        armed = true; generation = UUID(); expiresAt = preferences.sessionDuration.seconds.map { now().addingTimeInterval($0) }
        setPhase(.armed)
        guard armed else { throw SessionFailure.storage }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                do {
                    try self.reconcileOrThrow()
                    await self.activityUpdate(self.phase.rawValue, self.debugRetention)
                    guard !Task.isCancelled, self.armed else { return }
                    self.publishState(); self.processCommands()
                }
                catch { self.endSession(code: .interrupted); return }
            }
        }
        if let seconds = preferences.sessionDuration.seconds {
            expiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                self?.endSession(code: .timeout)
            }
        }
    }

    /// `autoStop` false: a hold-to-talk key ends this dictation, so a pause never does.
    func begin(source: DictationSource = .app, id: UUID = UUID(), autoStop: Bool = true) async throws {
        guard !startingUtterance, stream == nil else { throw SessionFailure.setup }
        startingUtterance = true
        defer { startingUtterance = false }
        let ticket = lifecycle
        let wasArmed = armed
        try await armSession()
        guard ticket == lifecycle else { throw SessionFailure.cancelled }
        if wasArmed, let config {
            let checked = try await healthy(config)
            guard ticket == lifecycle, armed else { throw SessionFailure.cancelled }
            reached(checked)
        }
        try reconcileOrThrow()
        guard stream == nil, let config else { throw SessionFailure.setup }
        clearUtterance()
        lastError = nil
        utterance = id; companion = source == .companion ? id : nil; utteranceSource = source
        timer = SessionTimer(now: now())
        privateUtterance = preferences.privacyMode
        var options = StartOptions(client: "ios", correction: health.map { preferences.permitsCorrection(health: $0) } ?? false,
                                   correctionProfile: preferences.styleID, wordTimings: true)
        if let prompt = preferences.prompts[preferences.styleID] {
            let limit = profiles.first { $0.id == preferences.styleID }?.maxPromptChars ?? 4000
            options.correctionPrompt = CorrectionProfile.clampPrompt(prompt, limit: min(4000, limit))
        }
        // Learn from my edits: the user's terms go to their own computer with the dictation (`start.learned`).
        if !privateUtterance, let learned = try? services?.learned.payload(), !learned.isEmpty { options.learned = learned }
        utteranceOptions = options
        let session = makeStream(config, options, http)
        stream = session
        do {
            try audio.begin(stream: session, onFailure: { [weak self] in Task { @MainActor in
                guard let self, self.armed, self.lifecycle == ticket, self.utterance == id else { return }
                self.endSession(code: .interrupted)
            } }, onLimit: { [weak self] in Task { @MainActor in
                guard let self, self.armed, self.lifecycle == ticket, self.utterance == id else { return }
                self.stopDictation()
            } }, onCut: { [weak self] in Task { @MainActor in
                guard let self, self.armed, self.lifecycle == ticket, self.utterance == id else { return }
                self.rollOver()
            } }, autoStop: autoStop ? preferences.autoStopSilence : nil, onAutoStop: { [weak self] in Task { @MainActor in
                // Stop dictation "When I pause": the same path as tapping Stop.
                guard let self, self.armed, self.lifecycle == ticket, self.utterance == id else { return }
                self.stopDictation()
            } })
        } catch { endSession(code: .interrupted); throw SessionFailure.audio }
        setPhase(.connecting)
        guard armed, utterance == id else { throw SessionFailure.storage }
        eventTask = listen(to: session, id: id)
        utteranceLimit = Task { [weak self] in
            // Each segment stays under the protocol's 120 s cap; the whole dictation stops just under 10 minutes.
            try? await Task.sleep(for: .seconds(RollingDictation.maxTotal - 1))
            guard !Task.isCancelled, self?.utterance == id else { return }
            self?.stopDictation()
        }
    }

    private func listen(to session: StreamSession, id: UUID) -> Task<Void, Never> {
        Task { [weak self] in
            await session.open()
            for await event in session.events {
                guard !Task.isCancelled, let self, self.utterance == id, self.armed else { return }
                if self.stream === session { self.receive(event, id: id) }
                else if let segment = self.finishing.first(where: { $0.stream === session }) { self.receive(event, finishing: segment, id: id) }
                else { return }
            }
        }
    }

    /// Long dictation: at a pause the microphone moves to a new segment; the old one finishes on its own.
    func rollOver() {
        guard armed, let id = utterance, let live = stream, ready, !stopRequested, let config, let options = utteranceOptions,
              finishing.count < RollingDictation.maxFinishing else { return }
        let next = makeStream(config, options, http)
        let old = FinishingSegment(index: segmentIndex, stream: live, partial: text, lastSequence: lastServerSequence, task: eventTask)
        finishing.append(old)
        segmentIndex += 1; timer?.rolledOver()
        stream = next; ready = false; lastServerSequence = -1; text = ""; raw = ""; words = []
        updateEarlierText()
        audio.cut(to: next)
        eventTask = listen(to: next, id: id)
        Task { await live.stop() }
        old.deadline = Task { [weak self, weak old] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, let old, self.utterance == id else { return }
            old.fail(); self.record(.timeout); self.drain(id: id)
        }
    }

    private func receive(_ event: StreamEvent, finishing segment: FinishingSegment, id: UUID) {
        switch event {
        case .closed(let reason): if reason != nil { segment.fail() }
        case .message(let message):
            switch message {
            case .partial(let seq, let value, _, _):
                guard seq > segment.lastSequence, segment.outcome == nil else { return }
                segment.lastSequence = seq; segment.partial = value
                if segment === finishing.first { publishResult(.partial, text: joiner() + value, segment: segment.index) }
            case .correcting(let seq, let value, _, _):
                guard seq > segment.lastSequence else { return }
                segment.lastSequence = seq; segment.raw = value
                if let timeout = health?.operationDeadlines?.advertisedTimeout(for: .dictation) {
                    segment.deadline?.cancel()
                    segment.deadline = Task { [weak self, weak segment] in
                        try? await Task.sleep(for: .seconds(timeout))
                        guard !Task.isCancelled, let self, let segment, self.utterance == id else { return }
                        segment.fail(); self.record(.timeout); self.drain(id: id)
                    }
                }
            case .final(let result): if segment.outcome == nil { segment.outcome = .final(learnedFinal(result)) }
            case .error(let code, _): record(DiagnosticCode.server(code)); segment.fail()
            default: break
            }
        }
        updateEarlierText()
        drain(id: id)
    }

    /// Lands finished segments oldest first, then releases what the next one has held back.
    private func drain(id: UUID) {
        guard utterance == id, armed else { return }
        while let first = finishing.first, let outcome = first.outcome {
            finishing.removeFirst(); first.close()
            let piece: (text: String, raw: String, kept: Bool)?
            switch outcome {
            case .final(let result): piece = result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : (result.text, result.raw, false)
            case .kept(let heard): piece = (heard, heard, true)
            case .nothing: piece = nil
            }
            guard let piece else { continue }
            let separator = joiner()
            landed.append((piece.text, piece.raw))
            publishResult(.final, text: separator + piece.text, raw: separator + piece.raw, kept: piece.kept, segment: first.index)
            if piece.kept { notice = "Part of the dictation was lost. Kept what was heard." }
        }
        updateEarlierText()
        if let next = finishing.first {
            if !next.partial.isEmpty { publishResult(.partial, text: joiner() + next.partial, segment: next.index) }
        } else if let held = liveFinal {
            liveFinal = nil; complete(held.result, id: id, kept: held.kept)
        } else if let held = heldLive {
            heldLive = nil; publishLive(held.kind, text: held.text, raw: held.raw)
        }
    }

    /// The separator before the next segment: none for the first, else a space unless one is there.
    private func joiner() -> String { LongText.joiner(after: LongText.join(landed.map(\.text))) }
    private func updateEarlierText() {
        earlierText = LongText.join(landed.map(\.text) + finishing.map { $0.raw.isEmpty ? $0.partial : $0.raw })
    }
    /// The live segment's results wait while earlier segments are still finishing, so text lands in order.
    private func publishLive(_ kind: BridgeResultKind, text value: String, raw: String? = nil, kept: Bool = false) {
        guard finishing.isEmpty else { heldLive = (kind, value, raw); return }
        let separator = joiner()
        publishResult(kind, text: separator + value, raw: raw.map { separator + $0 }, kept: kept, segment: segmentIndex)
    }

    func stopDictation() {
        guard let stream, !stopRequested else { return }
        stopRequested = true; timer?.stopped(now())
        audio.finish() // serialized against tap conversion; trailing PCM is queued before stream.stop.
        utteranceLimit?.cancel()
        if ready { Task { await stream.stop() } }
        notice = "Finishing…"
        startDeadline(seconds: 20)
    }

    func cancelDictation() {
        finishTiming(.cancelled)
        let previous = stream
        clearUtterance(error: SessionFailure.cancelled)
        if let previous { Task { await previous.cancel() } }
        setPhase(armed ? .armed : .idle)
        // Publishing nil utterance ownership purges the previous utterance's encrypted results.
    }

    func endSession(code: DiagnosticCode? = nil) {
        finishTiming(.cancelled, error: code)
        lifecycle = UUID()
        armed = false
        audio.disarm()
        let previous = stream
        clearUtterance(error: SessionFailure.expired)
        heartbeat?.cancel(); heartbeat = nil; expiry?.cancel(); expiry = nil; expiresAt = nil
        generation = UUID(); phase = .idle; lastError = nil
        if let code { record(code); notice = code == .timeout ? "Session ended." : "Session interrupted. Open Chirp to start again." }
        else { notice = "Session ended. Microphone off." }
        if let previous { Task { await previous.cancel() } }
        activityTeardown = Task { await activityEnd() }
        do { try services?.bridge.endSession(); signal.post() } catch { notice = SessionFailure.storage.localizedDescription }
    }

    func refreshSetup() { keyboardReady = (try? services?.keyboardSetup.fullAccessSeenAt()) != nil }

    func reconcile() { if armed { do { try reconcileOrThrow(); processCommands() } catch { endSession(code: .interrupted) } } }
    private func reconcileOrThrow() throws {
        guard armed else { throw SessionFailure.expired }
        if let expiresAt, now() >= expiresAt { endSession(code: .timeout); throw SessionFailure.expired }
        guard activityActive() else { throw SessionFailure.audio }
        guard permissionGranted() else { throw SessionFailure.permission }
    }

    private func receive(_ event: StreamEvent, id: UUID) {
        switch event {
        case .closed(let reason):
            if reason != nil {
                if phase == .correcting, !raw.isEmpty {
                    lastError = .unreachable
                    finishLive(FinalResult(text: raw), id: id)
                    notice = "Connection lost during clean-up. Kept original."
                    record(.unreachable)
                } else {
                    let issue = ConnectionIssue.classify(streamReason: reason ?? "")
                    if issue.isOffline { connectionIssue = issue }
                    keepHeard(id: id, code: issue.diagnostic, reason: issue == .other ? "Connection lost." : issue.message)
                }
            }
        case .message(let message):
            switch message {
            case .ready(_, _, let debug):
                guard !ready else { return }
                ready = true; debugRetention = debug; audio.ready(); timer?.ready(now())
                setPhase(.listening)
                if stopRequested, let stream { Task { await stream.stop() } }
            case .partial(let seq, let value, _, let timings):
                guard ready, !stopRequested, seq > lastServerSequence else { return }
                lastServerSequence = seq; text = value; words = timings ?? []; timer?.partial(now())
                publishLive(.partial, text: value)
            case .correcting(let seq, let value, _, let timings):
                guard ready, stopRequested, seq > lastServerSequence else { return }
                lastServerSequence = seq; raw = value; text = value; words = timings ?? []
                timer?.polishing(now())
                setPhase(.correcting); publishLive(.correcting, text: value, raw: value); startDeadline(seconds: health?.operationTimeout(.dictation, fallback: 12) ?? 12)
            case .final(let result):
                guard ready, stopRequested else { return }
                finishLive(learnedFinal(result), id: id)
            case .error(let code, _): keepHeard(id: id, code: DiagnosticCode.server(code), reason: Self.serverMessage(code))
            case .unknown: break
            }
        }
    }

    /// A failed utterance keeps its last partial as plain text (no clean-up) and leaves the session armed, so
    /// the keyboard inserts it and shows why. With nothing heard, only the reason is shown.
    private func keepHeard(id: UUID, code: DiagnosticCode, reason: String) {
        guard utterance == id, armed else { return }
        lastError = code; record(code)
        let heard = text
        if ready, !heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            finishLive(FinalResult(text: heard, raw: heard), id: id, kept: true)
            notice = reason + " Kept what was heard."
        } else if !landed.isEmpty || !finishing.isEmpty {
            // Earlier segments still land; the dictation ends with what they heard.
            if let live = stream { Task { await live.cancel() } }
            finishLive(FinalResult(text: ""), id: id)
            notice = reason
        } else {
            finishTiming(.failed, error: code)
            let previous = stream
            clearUtterance(error: SessionFailure.noResult)
            setPhase(.armed)
            notice = reason
            if let previous { Task { await previous.cancel() } }
        }
    }

    static func serverMessage(_ code: String) -> String {
        switch code {
        case "auth": ConnectionIssue.refused.message
        case "busy": "Chirp server is busy. Try again in a moment."
        case "too_long": "That dictation hit the 120-second limit."
        case "bad_audio": SessionFailure.noResult.localizedDescription
        case "engine": "The speech engine had a problem. Try again."
        case "bad_request": "The clean-up prompt is too long. Shorten it in Settings → Dictation → Styles."
        default: "Chirp server couldn't finish that dictation. Try again."
        }
    }

    /// What was learned applies to the final text itself too, so it works with clean-up off or an older server (as
    /// on the Mac and Android). The raw transcript stays as heard.
    private func learnedFinal(_ result: FinalResult) -> FinalResult {
        guard let learned = utteranceOptions?.learned else { return result }
        var result = result
        result.text = learned.apply(to: result.text)
        return result
    }

    /// The live (last) segment finished; it completes once every earlier segment has landed.
    private func finishLive(_ result: FinalResult, id: UUID, kept: Bool = false) {
        guard finishing.isEmpty else {
            liveFinal = (result, kept); audio.discard(); deadline?.cancel(); utteranceLimit?.cancel(); return
        }
        complete(result, id: id, kept: kept)
    }

    private func complete(_ result: FinalResult, id: UUID, kept: Bool = false) {
        guard utterance == id, armed else { return }
        let empty = result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard !empty || !landed.isEmpty else {
            finishTiming(.empty); cancelDictation(); notice = SessionFailure.noResult.localizedDescription; return
        }
        finishTiming(kept ? .kept : .final, error: kept ? lastError : nil)
        audio.discard(); deadline?.cancel(); utteranceLimit?.cancel()
        let finishedStream = stream; stream = nil
        if let finishedStream { Task { await finishedStream.close() } }
        let separator = empty ? "" : joiner()
        text = empty ? "" : result.text; raw = empty ? "" : result.raw; words = result.words ?? []
        canUseRaw = !empty && result.canUseRaw
        setPhase(.finished)
        guard armed, utterance == id else { return }
        if !empty { publishResult(.final, text: separator + result.text, raw: separator + result.raw, kept: kept, segment: segmentIndex) }
        guard armed, utterance == id else { return }
        let whole = LongText.join(landed.map(\.text) + (empty ? [] : [result.text]))
        let wholeRaw = LongText.join(landed.map(\.text) + (empty ? [] : [result.raw]))
        if !privateUtterance, !preferences.privacyMode {
            do { historyID = try services?.history.record(text: whole, raw: wholeRaw, corrected: result.corrected)?.id }
            catch { notice = SessionFailure.storage.localizedDescription; record(.storage) }
        }
        if companion == id { copyText(whole); companion = nil; notice = "Copied final text." }
        else { notice = result.corrected ? "Polished. Copy or share when ready." : "Finished. Copy or share when ready." }
        for waiter in waiters.removeValue(forKey: id) ?? [] { waiter.resume() }
        rawExpiresAt = now().addingTimeInterval(5)
        rawExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, self?.utterance == id else { return }
            self?.canUseRaw = false
        }
    }

    private func startDeadline(seconds: Double) {
        deadline?.cancel()
        let id = utterance
        deadline = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.utterance == id else { return }
            if self.phase == .correcting, !self.raw.isEmpty, let id {
                let fallback = self.raw
                self.complete(FinalResult(text: fallback), id: id)
                self.notice = "Clean-up timed out. Kept original."
            } else { self.keepHeard(id: id ?? UUID(), code: .timeout, reason: SessionFailure.timeout.localizedDescription) }
        }
    }
    private func clearUtterance(error: Error = SessionFailure.cancelled) {
        eventTask?.cancel(); eventTask = nil; deadline?.cancel(); deadline = nil
        utteranceLimit?.cancel(); utteranceLimit = nil; rawExpiry?.cancel(); rawExpiry = nil
        audio.discard(); stream = nil; utterance = nil; companion = nil; utteranceSource = nil
        text = ""; raw = ""; words = []; canUseRaw = false; ready = false; stopRequested = false
        sequence = 0; lastServerSequence = -1; historyID = nil
        for segment in finishing { segment.cancel() }
        finishing = []; landed = []; segmentIndex = 0; heldLive = nil; liveFinal = nil; earlierText = ""; utteranceOptions = nil
        let pending = waiters; waiters.removeAll()
        for group in pending.values { for waiter in group { waiter.resume(throwing: error) } }
    }
    func useRaw() {
        guard canUseRaw, phase == .finished else { return }
        text = raw; canUseRaw = false
        let separator = joiner(); publishResult(.raw, text: separator + raw, raw: separator + raw, segment: segmentIndex)
        if let historyID {
            do { _ = try services?.history.useRaw(id: historyID) }
            catch { notice = SessionFailure.storage.localizedDescription; record(.storage) }
        }
    }
    /// Copies the finished text, or the user's edit of it from Dictate.
    func copy(_ edited: String? = nil) {
        let whole = edited ?? LongText.join(landed.map(\.text) + (text.isEmpty ? [] : [text]))
        guard !whole.isEmpty, phase == .finished else { return }; copyText(whole); notice = "Copied."
    }

    /// Cold setup and permission requests need Chirp on screen; an armed session starts from anywhere.
    var needsForegroundToStart: Bool { !armed && !appActive() }

    func perform(action: SessionAction) async throws -> String {
        switch action {
        case .start:
            guard !needsForegroundToStart else { throw SessionFailure.setup }
            try await begin(source: .companion)
            return "Recording. Stop Chirp to copy the final text."
        case .stop:
            guard let id = utterance, stream != nil else { throw SessionFailure.noResult }
            let copies = companion == id // Only a companion-owned utterance copies; keyboard/app paths never copy.
            stopDictation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in waiters[id, default: []].append(continuation) }
            return copies ? "Copied. Paste with ⌘V." : "Dictation finished."
        case .toggle:
            // One action for a hardware-keyboard shortcut: start in an armed session, or stop and copy.
            if utterance != nil, stream != nil {
                // Keyboard dictation is never copied, so the shortcut leaves it to Chirp Keyboard.
                guard utteranceSource != .keyboard else { return "Chirp Keyboard is dictating. Stop it in the keyboard." }
                return try await perform(action: .stop)
            }
            _ = try await perform(action: .start)
            return "Recording. Run Toggle Chirp dictation again to stop and copy."
        case .cancel: cancelDictation(); return "Dictation cancelled."
        case .end: endSession(); return "Session ended. Microphone off."
        }
    }

    private func setPhase(_ value: SessionPhase) {
        phase = value; publishState()
        let expected = lifecycle
        Task { if expected == lifecycle { await activityUpdate(value.rawValue, debugRetention) } }
    }
    private func publishState() {
        guard armed, let services else { return }
        do {
            try services.bridge.publish(BridgeState(generation: generation, phase: phase, utteranceID: utterance,
                leaseUntil: now().addingTimeInterval(8), sessionExpiresAt: expiresAt, debugRetention: debugRetention,
                privacyMode: preferences.privacyMode, styleID: preferences.styleID,
                availableStyleIDs: profiles.isEmpty ? ["default"] : profiles.map(\.id), errorCode: lastError,
                spokenCommands: preferences.spokenCommands == true ? true : nil, autoEnter: preferences.autoEnter))
            signal.post()
        } catch { endSession(code: .storage) }
    }
    private func publishResult(_ kind: BridgeResultKind, text: String, raw: String? = nil, kept: Bool = false, segment: Int = 0) {
        guard let utterance, armed, let services else { return }
        sequence += 1
        do {
            try services.bridge.publish(BridgeResult(generation: generation, utteranceID: utterance, kind: kind,
                text: text, raw: raw, sequence: sequence, createdAt: now(), expiresAt: now().addingTimeInterval(8),
                kept: kept ? true : nil, segment: segment == 0 ? nil : segment))
            signal.post()
        } catch { endSession(code: .storage) }
    }
    private func processCommands() {
        guard armed, let services else { return }
        do {
            try reconcileOrThrow()
            for command in try services.bridge.takeCommands(generation: generation) {
                switch command.action {
                case .start:
                    guard stream == nil, let id = command.utteranceID else { continue }
                    let expected = generation
                    Task {
                        guard armed, expected == generation else { return }
                        do { try await begin(source: .keyboard, id: id) }
                        catch { notice = "Dictation unavailable. Finish the current utterance first." }
                    }
                case .stop: if command.utteranceID == utterance { stopDictation() }
                case .cancel: if command.utteranceID == utterance { cancelDictation() }
                case .end: endSession(); return
                case .useRaw: if command.utteranceID == utterance { useRaw() }
                case .style(let id): if stream == nil { selectStyle(id) }
                case .privacy(let enabled): preferences.privacyMode = enabled; savePreferences(); publishState()
                }
            }
        } catch { endSession(code: .storage) }
    }
    /// One content-free timing entry per dictation; later calls for the same dictation do nothing.
    private func finishTiming(_ outcome: SessionTiming.Outcome, error: DiagnosticCode? = nil) {
        guard var current = timer else { return }
        timer = nil
        let source: SessionTiming.Source = switch utteranceSource { case .keyboard?: .keyboard; case .companion?: .companion; default: .app }
        guard let entry = current.finish(outcome, error: error, source: source, network: network(), now: now()) else { return }
        try? services?.timings.record(entry)
        refreshTimings()
    }
    func refreshTimings() { timingSummary = TimingSummary.text((try? services?.timings.entries()) ?? []) }
    func clearTimings() { try? services?.timings.clear(); refreshTimings() }

    private func record(_ code: DiagnosticCode) {
        diagnostics.append(DiagnosticEvent(phase: phase, code: code))
        diagnostics = Array(diagnostics.suffix(200))
    }
    func show(_ error: Error) {
        notice = (error as? SessionFailure)?.localizedDescription ?? "Unable to start. Open Chirp and check microphone, connection and Live Activity settings."
    }
    var diagnosticText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let events = (try? DiagnosticExport.data(events: diagnostics)) ?? Data("[]".utf8)
        return "Chirp \(version) · iOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)\n" + String(decoding: events, as: UTF8.self)
            + "\n\nDictation timings\n" + timingSummary
    }
}

/// Carries the classified health failure out of the pairing store's `@Sendable` check.
private final class IssueBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ConnectionIssue?
    private var name: String?
    var issue: ConnectionIssue? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
    var device: String? {
        get { lock.withLock { name } }
        set { lock.withLock { name = newValue } }
    }
}
