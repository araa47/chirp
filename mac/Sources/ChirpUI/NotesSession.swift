import AppKit
import ChirpCore
import Foundation

/// Everything `NotesSession` reaches outside itself: the microphone engine, the sockets, the structuring calls, time,
/// permissions, sounds, the hotkey and accessibility. The app passes the system ones (`NotesController.swift`);
/// tests pass fakes, so a whole session runs without a microphone, TCC, a window or the user's server.
public struct NotesSessionDependencies {
    public var settings: Preferences
    public var engine: CaptureEngine
    public var makeSession: (StartOptions) -> StreamSession
    public var structure: NotesRecorder.Structure
    public var reorganize: NotesRecorder.Reorganize
    /// `POST /v1/notes/edit` (#97); set after init (the default: no server support).
    public var edit: NotesRecorder.Edit = { _ in throw NotesStructureError.unsupported(404) }
    public var speakerStore: SpeakerModelStore
    /// Shared server library, plus the legacy Keychain source to migrate once.
    public var voiceClient: VoiceLibraryClient = .unavailable
    public var voiceProfileStore: VoiceProfileStore = MemoryVoiceProfileStore()
    /// Re-transcribe's sockets (#287): a `start.retranscribe` may wait up to a minute for the engine, so the app
    /// gives them a longer ready deadline. Nil uses `makeSession`.
    public var retranscribeSession: ((StartOptions) -> StreamSession)?
    /// Where the crash-recovery journal lives (tests pass a temporary directory).
    public var journalStore: NotesJournalStore
    /// Mac library; nil retains the legacy recovery contract for other clients and isolated harnesses.
    public var library: NotesLibrary?
    /// Digital silence for this long shows "Microphone is silent (muted?)" (its `window`; Notes keeps recording).
    public var silenceGuard: () -> SilenceGuard = { SilenceGuard() }
    /// Where system sleep and wake are posted (nil: `NSWorkspace`'s; tests pass their own center).
    public var workspaceNotifications: NotificationCenter?
    /// Digital silence this long pauses Notes.
    public var silencePause: TimeInterval = NotesCaptureSink.pauseAfter
    /// At most this much audio waits in memory for an offline server.
    public var keptAudio: TimeInterval = NotesRecorder.maxKeptAudio
    public var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    public var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    /// Starts the once-a-second elapsed tick; the returned closure stops it.
    public var startTicker: (_ tick: @escaping @MainActor () -> Void) -> () -> Void = NotesSessionDependencies.timerTicker
    public var requestMicrophone: () async -> Bool = { true }
    /// The microphone was denied: open its Settings pane.
    public var openMicrophoneSettings: () -> Void = {}
    /// The microphone authorization status, for the log.
    public var microphoneStatus: () -> Int = { 3 }
    /// Plays a cue; the session checks the sounds switch first.
    public var play: (SoundCue) -> Void = { _ in }
    /// How long the microphone waits after the start cue begins.
    public var soundStartDelay: () -> TimeInterval = { 0 }
    public var beep: () -> Void = {}
    /// A VoiceOver announcement.
    public var announce: (String) -> Void = { _ in }
    public var reduceMotion: () -> Bool = { false }
    /// Registers the Start/Stop Notes shortcut (⌃⌥N by default); false when another app owns it.
    public var registerHotkey: (_ onDown: @escaping () -> Void) -> Bool = { _ in false }
    public var unregisterHotkey: () -> Void = {}
    /// Call audio (#211): what the Mac plays, beside the microphone (nil: not on this Mac); the apps it can record
    /// on their own; and the Screen & System Audio Recording pane.
    public var callTap: SystemAudioTap?
    public var callApps: () -> [CallAudioApp] = { [] }
    public var openCallAudioSettings: () -> Void = {}
    /// A call recording that heard nothing but digital silence this long says so (a refused permission, a muted app).
    public var callSilenceNotice: TimeInterval = 20
    /// Where the call side starts and stops: off the main thread in the app, since the system can hold the first
    /// start while its permission prompt is up. Tests run it in place.
    public var callAudioQueue: (@escaping @Sendable () -> Void) -> Void = { $0() }

    public init(settings: Preferences, engine: CaptureEngine, makeSession: @escaping (StartOptions) -> StreamSession,
                structure: @escaping NotesRecorder.Structure, reorganize: @escaping NotesRecorder.Reorganize,
                speakerStore: SpeakerModelStore, journalStore: NotesJournalStore) {
        self.settings = settings
        self.engine = engine
        self.makeSession = makeSession
        self.structure = structure
        self.reorganize = reorganize
        self.speakerStore = speakerStore
        self.journalStore = journalStore
    }

    public static func timerTicker(_ tick: @escaping @MainActor () -> Void) -> () -> Void {
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
        return { timer.invalidate() }
    }
}

/// Live Notes glue: its own microphone capture, the `NotesRecorder`, the Start/Stop hotkey and the window's model. Notes and
/// dictation never run together (the AppDelegate wires the checks both ways). Logs carry state names and counts only.
@MainActor
public final class NotesSession {
    public let model = NotesModel()
    /// The window around the note: the library list, search, selection, the inspector (Mac library only).
    public let window = NotesLibraryModel()
    /// A note opened while another one records (`window.browsed` is its model).
    private(set) var browsing: NotesBrowsedNote?
    /// Re-transcribe from kept audio (Mac library only).
    private(set) var retranscribe: NotesRetranscribeController?
    private var renameTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var lastDocumentID: UUID?
    private var audioSeen: [UUID: Int] = [:]
    public let recorder: NotesRecorder
    /// Edit by Voice (#97).
    public let voiceEdit: NotesVoiceEdit
    let deps: NotesSessionDependencies
    private var settings: Preferences { deps.settings }

    public var health: () -> Health? = { nil }
    public var isDictating: () -> Bool = { false }
    public var onChange: (() -> Void)?
    /// Show the window; `focus` is false when started from the hotkey (it must not steal focus).
    public var onShowWindow: ((_ focus: Bool) -> Void)?
    /// The speaker model downloaded, failed, was removed or changed state (Settings shows it).
    public var onSpeakerModelChange: (() -> Void)?
    /// Voice profiles changed (the switch, the model, the saved voices): Settings shows them.
    public var onVoicesChange: (() -> Void)?
    /// "Remember this voice as Maya…": asks for the consent tick; `done(true)` only with it ticked.
    public var confirmRememberVoice: ((_ name: String, _ done: @escaping (Bool) -> Void) -> Void)?

    /// Speaker labels: the switch, the model's background download, offline loads, Remove and this document's diarizer.
    public let speakers: SpeakerLabels
    /// The shared server library and this note’s recognised identities.
    public let voices: SpeakerVoices
    var voiceProcessingTask: Task<Void, Never>?
    /// The crash-recovery journal and the opt-in "keep this file up to date" writes.
    public let journal: NotesJournal
    public var library: NotesLibrary? { deps.library }
    /// Sessions the journal found at launch, newest first; the first is on offer in the window.
    private var recoverable: [NotesJournalRecord] = []

    private let capture: AudioCapture
    /// This note's sources (the Settings default for a new note) and, while recording with call audio, its capture.
    public private(set) var sources: NotesSources
    private var callCapture: CallAudioCapture?
    private var callWatch: Task<Void, Never>?
    private var callNotice: NotesCallNotice?
    private var stopTick: (() -> Void)?
    /// A start that failed before the recorder ran (permission, no input device).
    private var restoringDocument = false
    private var selectionGeneration = 0
    private var startError: String?
    private var lastAnnouncement = ""
    private var lastState: NotesRecorderState = .idle
    private var lastRecorderState: NotesRecorderState = .idle
    private var lastHealth: Health?
    private var lastReorganize: ReorganizeStatus = .idle
    private var lastLongRun = false
    /// The last health this server answered with, kept across a failed poll so one blip never changes what
    /// structuring may do (dropped when the server URL changes).
    private var knownHealth: (url: String, health: Health)?
    /// A silent, switched or missing input while recording.
    private var micNotice: NotesMicNotice?
    private var switchedAt: TimeInterval?
    /// The session paused for a system sleep: wake resumes it (and only that pause).
    private var pausedForSleep = false
    /// "Switched to …" shows this long.
    public static let switchedNoticeFor: TimeInterval = 10

    public private(set) lazy var gate = PauseGate(
        register: { [weak self] in
            self?.deps.registerHotkey({ [weak self] in self?.toggle(fromHotkey: true) }) ?? false
        },
        unregister: { [weak self] in self?.deps.unregisterHotkey() },
        onChange: { [weak self] in self?.onChange?() })

    public init(_ deps: NotesSessionDependencies) {
        self.deps = deps
        let settings = deps.settings
        // A legacy stored "off" was often the app's own (a missing model); the default is on.
        settings.migrateSpeakerLabelsDefault()
        capture = AudioCapture(engine: deps.engine)
        sources = settings.notesSources
        recorder = NotesRecorder(
            makeSession: deps.makeSession, structure: deps.structure, reorganize: deps.reorganize, edit: deps.edit,
            now: deps.now, sleep: deps.sleep,
            options: settings.notesStartOptions(health: nil), structuring: settings.notesStructureEnabled(health: nil),
            autoReorganize: settings.notesAutoReorganize, keptAudio: deps.keptAudio)
        speakers = SpeakerLabels(store: deps.speakerStore, enabled: settings.notesSpeakerLabels,
                                 onPreference: { settings.notesSpeakerLabels = $0 })
        voices = SpeakerVoices(client: deps.voiceClient, legacy: deps.voiceProfileStore,
            imported: { settings.notesImportedVoices.contains($0.uuidString) },
            acknowledgeImport: { settings.notesImportedVoices += [$0.uuidString] })
        journal = NotesJournal(store: deps.journalStore, enabled: settings.notesRecoveryCopy, library: deps.library, sleep: deps.sleep)
        voiceEdit = NotesVoiceEdit(recorder: recorder, makeSession: deps.makeSession, now: deps.now, sleep: deps.sleep)
        recorder.shouldKeepAudio = { settings.notesKeepAudio }
        recorder.onSegmentAudio = { [weak self] id, segment, frames, offset in
            guard let self, deps.library != nil else { return }
            journal.update(recorder.document, elapsed: recorder.elapsed, urgent: true, recording: recorder.state.isActive)
            journal.keepAudio(id, segment: segment, frames: frames, offset: offset, sampleRate: PCMConverter.sampleRate)
        }
        recorder.onChange = { [weak self] in self?.sync() }
        voiceEdit.onChange = { [weak self] in self?.sync() }
        voiceEdit.openMicrophone = { [weak self] session in self?.openCommandMicrophone(session) ?? false }
        voiceEdit.closeMicrophone = { [weak self] in self?.capture.stop() }
        voiceEdit.selection = { [weak self] in self?.model.editorSelection() }
        recorder.onPassEvent = { event in
            switch event {
            case .split(let chars, let depth, let parts, let fallbacks):
                chirpLog.info("notes split chars=\(chars, privacy: .public) depth=\(depth, privacy: .public) parts=\(parts, privacy: .public) fallbacks=\(fallbacks, privacy: .public)")
            case .organize(let steps, let failed, let conflict):
                chirpLog.info("notes organize steps=\(steps, privacy: .public) failed=\(failed, privacy: .public) conflict=\(conflict, privacy: .public)")
            }
        }
        model.libraryEnabled = deps.library != nil
        model.structureEnabled = false
        model.onRecordToggle = { [weak self] in
            guard let self else { return }
            if isPaused { Task { await stop() } } else { toggle(fromHotkey: false) }
        }
        model.onRestoreSnapshot = { [weak self] id, confirmed in self?.restoreSnapshot(id, confirmed: confirmed) }
        model.onPauseToggle = { [weak self] in Task { await self?.togglePause() } }
        model.onStructureToggle = { [weak self] on in self?.setStructure(on) }
        // The inspector is remembered in the old layout preference ("split" showed the transcript beside the notes).
        window.showsInspector = settings.notesTab != "notes"
        window.onInspector = { settings.notesTab = $0 ? "split" : "notes" }
        window.textSize.restore(settings.notesTextSize)
        window.textSize.onChange = { settings.notesTextSize = Double($0) }
        model.onShowTranscript = { [weak self] in self?.window.setInspector(true) }
        model.tipSeen = settings.notesTipSeen
        model.onTipSeen = { settings.notesTipSeen = true }
        model.autoReorganize = settings.notesAutoReorganize
        model.onAutoReorganizeToggle = { [weak self] on in
            settings.notesAutoReorganize = on
            self?.recorder.setAutoReorganize(on)
        }
        model.onUserEdit = { [weak self] range, text, kind in
            self?.recorder.userEdit(range, text, kind: kind)
            self?.voiceEdit.dismiss()
        }
        model.onVoiceEdit = { [weak self] in self?.toggleVoiceEdit() }
        model.onVoiceEditCancel = { [weak self] in self?.voiceEdit.cancel() }
        model.onVoiceEditDismiss = { [weak self] in self?.voiceEdit.dismiss() }
        model.onReorganize = { [weak self] in self?.recorder.reorganizeNow() }
        model.onEditorFocus = { [weak self] inTail, composing in self?.recorder.setEditorFocus(inTail: inTail, composing: composing) }
        model.onSpeakerLabelsToggle = { [weak self] on in self?.setSpeakerLabels(on) }
        model.onSourcesChange = { [weak self] sources in self?.setSources(sources) }
        model.onCallAudioExplained = { [weak self] proceed in self?.callAudioExplained(proceed) }
        model.onRefreshCallApps = { [weak self] in self?.refreshCallApps() }
        model.onOpenCallAudioSettings = { [weak self] in self?.deps.openCallAudioSettings() }
        model.onSpeakerEdit = { [weak self] edit in self?.editSpeakers(edit) }
        journal.onWrite = { bytes, ms in
            chirpLog.info("notes journal bytes=\(bytes ?? -1, privacy: .public) ms=\(ms, privacy: .public)")
        }
        journal.onKeepSaved = { [weak self] in self?.markSaved() }
        journal.onKeepChange = { [weak self] in self?.sync() }
        recorder.onLabels = { [weak self] lag, tentative in
            guard let self else { return }
            chirpLog.info("\(SpeakerLog.labels(speakers: self.recorder.document.speakerCount, lag: lag, tentative: tentative), privacy: .public)")
        }
        voices.onChange = { [weak self] in self?.voicesChanged() }
        voices.beforeRemember = { [weak self] name in
            guard let self else { return false }
            if self.settings.notesVoiceNoticeShown { return true }
            self.settings.notesVoiceNoticeShown = true
            let yes = await withCheckedContinuation { done in
                (self.confirmRememberVoice ?? { _, finish in finish(true) })(name) { done.resume(returning: $0) }
            }
            if !yes { _ = await self.voices.perform(.disable(forget: false)) }
            return yes
        }
        speakers.onChange = { [weak self] in
            self?.sync()
            self?.onSpeakerModelChange?()
        }
        speakers.onReady = { [weak self] in self?.speakersReady() }
        model.speakerModelSize = speakers.sizeText
        model.onSpeakerRetry = { [weak self] in self?.speakers.retry() }
        // Posted on the main thread; the session lives as long as the app (tests pass a center of their own).
        let center = deps.workspaceNotifications ?? NSWorkspace.shared.notificationCenter
        _ = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.willSleep() }
        }
        _ = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        }
        if deps.library != nil { wireLibrary() }
        sync()
    }

    public var isRecording: Bool { recorder.state.isCapturing }
    public var isActive: Bool { recorder.state.isActive }
    public var isPaused: Bool { recorder.state == .paused }
    public var hasDocument: Bool { !recorder.document.segments.isEmpty }
    /// The microphone is open.
    public var isCapturing: Bool { capture.isRunning }

    @discardableResult
    public func registerHotkey() -> Bool { gate.registerHotkey() }
    /// Releases the hotkey while a Settings recorder listens; `registerHotkey()` takes it back.
    public func suspendHotkey() { gate.suspendHotkey() }

    /// The menu's switch: pausing Chirp stops Notes gracefully (the notes stay) and releases its hotkey.
    public func setRunning(_ running: Bool) {
        if !running, isRecording || isPaused { Task { await stop() } }
        gate.setRunning(running)
    }

    // MARK: recording

    public func toggle(fromHotkey: Bool) {
        if isRecording { Task { await stop() }; return }
        if isPaused { Task { await resume() }; return }
        guard recorder.state != .stopping else { return }
        if fromHotkey, library != nil { reset() }
        start(focus: !fromHotkey)
    }

    public func start(focus: Bool) {
        guard !gate.isPaused, !isActive else { return }
        // A re-transcribe holds this note: Continue recording waits for it.
        guard !window.isRetranscribing(recorder.document.id) else { deps.beep(); return }
        // A spoken edit outside a recording has the microphone: it ends (or Esc drops it) before Record.
        guard !voiceEdit.status.isListening else { deps.beep(); return }
        guard !isDictating() else { deps.beep(); return }
        onShowWindow?(focus)
        // Labels are on and the model is missing: fetch it in the background. Recording never waits for it.
        speakers.ensureModel()
        if speakers.needsLoad {
            // The models load offline (~0.1 s warm); recording starts as soon as they are ready, or without labels
            // (or voices) if one is gone or damaged (the status line offers Retry).
            guard !speakers.isLoading else { return }
            Task {
                _ = await speakers.prepare()
                self.start(focus: focus)
            }
            return
        }
        let health = resolvedHealth()
        startError = nil
        let diarizer = speakers.readyDiarizer()
        let labels = diarizer != nil
        diarizer?.collectVoiceClips(voices.enabled)
        Task { await voices.refresh() }
        // With call audio the microphone is "You" and only the call is diarized.
        recorder.speakers = usesCallAudio ? diarizer.map { CallSpeakers(remote: $0) } : diarizer
        recorder.options = settings.notesStartOptions(health: health)
        recorder.serverHost = settings.serverConfig().host
        applyAvailability(health)
        if model.structuring == .off(.correctionOff) || model.structuring == .off(.unsupported), recorder.document.isEmpty {
            window.setInspector(true)   // structuring unavailable: the transcript is the useful view
        }
        chirpLog.info("notes start microphone=\(self.deps.microphoneStatus(), privacy: .public) correction=\(self.recorder.options.correction, privacy: .public) structuring=\(String(describing: self.recorder.structuring), privacy: .public) speakers=\(labels, privacy: .public) call=\(self.usesCallAudio, privacy: .public)")
        if settings.soundsEnabled { deps.play(.start) }
        let micMayOpen = deps.now() + deps.soundStartDelay()
        recorder.start()
        Task {
            guard await deps.requestMicrophone() else {
                deps.openMicrophoneSettings()
                await fail("Microphone access denied — enable it in System Settings")
                return
            }
            let wait = micMayOpen - deps.now()
            if wait > 0 { await deps.sleep(.seconds(wait)) }
            guard isRecording else { return }
            openMicrophone()
        }
    }

    private func openMicrophone() {
        micNotice = nil
        let call = openCallAudio()
        let sink = NotesCaptureSink(recorder: recorder, warnAfter: deps.silenceGuard().window, pauseAfter: deps.silencePause,
                                    onLevel: { [weak self] level in
            Task { @MainActor in if self?.isRecording == true { self?.model.level = UtteranceLevels.normalize(rms: level.rms) } }
        }) { [weak self] event in
            Task { @MainActor in self?.silenceChanged(event) }
        }
        do {
            try capture.start(onInput: { [weak self] event in
                Task { @MainActor in self?.inputChanged(event) }
            }) { [weak self] frame in
                guard let call else { sink.handle(frame); return }
                let mixed = call.mixer.mix(mic: frame)
                sink.handle(mixed.mix, call: mixed)
                let level = UtteranceLevels.normalize(rms: mixed.remoteLevel.rms)
                Task { @MainActor in if self?.isRecording == true { self?.model.callLevel = level } }
            }
        } catch {
            closeCallAudio()
            Task { await fail(error is CaptureError ? "No microphone input device" : "Could not start the microphone") }
        }
    }

    // MARK: call audio

    /// This recording takes call audio: the note asks for it and this Mac can capture it.
    var usesCallAudio: Bool { sources.callAudio && deps.callTap != nil }

    /// Starts the call side before the microphone, so the mix has it from the first frame; nil records the microphone
    /// only (call audio off, or the system refused: said once, and recording goes on).
    private func openCallAudio() -> CallAudioCapture? {
        closeCallAudio()
        callNotice = nil
        guard usesCallAudio, let tap = deps.callTap else { return nil }
        let call = CallAudioCapture(tap: tap)
        let app = sources.app
        callCapture = call
        // The mix plays silence for the call side until the tap runs.
        deps.callAudioQueue { [weak self] in
            do {
                try call.start(app: app)
                chirpLog.info("notes call audio kind=\(call.kind.rawValue, privacy: .public) app=\(app != nil, privacy: .public)")
            } catch {
                Task { @MainActor in self?.callAudioFailed(call) }
            }
        }
        watch(call)
        return call
    }

    /// The system refused call audio: the recording goes on with the microphone only, and says so.
    private func callAudioFailed(_ call: CallAudioCapture) {
        guard callCapture === call else { return }
        chirpLog.info("notes call audio unavailable")
        closeCallAudio()
        callNotice = .unavailable
        sync()
    }

    /// Nothing but digital silence for `callSilenceNotice` says so (macOS delivers silence when the permission was
    /// refused); the notice goes as soon as the call is heard.
    private func watch(_ call: CallAudioCapture) {
        callWatch?.cancel()
        let sleep = deps.sleep, wait = deps.callSilenceNotice
        callWatch = Task { [weak self] in
            await sleep(.seconds(wait))
            while !Task.isCancelled {
                guard let self, self.callCapture === call else { return }
                if call.hasHeardAudio {
                    if self.callNotice == .silent { self.callNotice = nil; self.sync() }
                    return
                }
                if self.callNotice == nil {
                    self.callNotice = .silent
                    chirpLog.info("notes call audio silent")
                    self.sync()
                }
                await sleep(.seconds(2))
            }
        }
    }

    private func closeCallAudio() {
        callWatch?.cancel()
        callWatch = nil
        if let call = callCapture { deps.callAudioQueue { call.stop() } }
        callCapture = nil
        if model.callLevel != 0 { model.callLevel = 0 }
    }

    /// The microphone and the call audio close together.
    private func closeCapture() {
        capture.stop()
        closeCallAudio()
    }

    /// The window's source picker: applies from the next Record (locked while one runs). Turning call audio on the
    /// first time explains what is recorded before anything else happens.
    func setSources(_ new: NotesSources) {
        guard !isActive else { deps.beep(); return }
        if new.callAudio, !sources.callAudio, !settings.notesCallAudioExplained {
            model.explainingCallAudio = new
            return
        }
        sources = new
        if new.callAudio { settings.notesCallAudioApp = new.app }
        callNotice = nil
        chirpLog.info("notes sources call=\(new.callAudio, privacy: .public) app=\(new.app != nil, privacy: .public)")
        sync()
    }

    /// The explanation's Continue (true) or Not Now.
    private func callAudioExplained(_ proceed: Bool) {
        guard let pending = model.explainingCallAudio else { return }
        model.explainingCallAudio = nil
        guard proceed else { return }
        settings.notesCallAudioExplained = true
        setSources(pending)
    }

    /// Settings › Notes › Sources changed the default: a blank note that is not recording takes it.
    public func defaultSourcesChanged() {
        guard !isActive, recorder.document.isEmpty else { return }
        sources = settings.notesSources
        sync()
    }

    private func refreshCallApps() {
        var apps = CallAudioApp.sorted(deps.callApps())
        if let chosen = sources.app, !apps.contains(where: { $0.bundleID == chosen.bundleID }) { apps.append(chosen) }
        model.callApps = apps
    }

    // MARK: voice edit

    /// The button and ⇧⌘E. Outside a recording the microphone opens just for the command (never during a dictation).
    public func toggleVoiceEdit() {
        if !voiceEdit.status.isListening, !isActive, isDictating() { deps.beep(); return }
        voiceEdit.toggle()
    }

    private func openCommandMicrophone(_ session: StreamSession) -> Bool {
        guard !isDictating(), !capture.isRunning else { return false }
        do {
            try capture.start(onFailure: { [weak self] in Task { @MainActor in self?.voiceEdit.cancel() } }) { session.sendAudio($0) }
            return true
        } catch {
            return false
        }
    }

    /// Digital silence warns (recording goes on); `long` silence pauses, keeping the notes.
    private func silenceChanged(_ event: NotesSilenceEvent) {
        guard recorder.state == .recording else { return }
        switch event {
        case .started: micNotice = .silent
        case .ended: if micNotice == .silent { micNotice = nil }
        case .long: Task { await pause(reason: NotesStatus.silencePause) }
        }
        chirpLog.info("notes silence \(String(describing: event), privacy: .public)")
        sync()
    }

    /// The input went away: capture went on with another one, or waits for one.
    private func inputChanged(_ event: CaptureInputEvent) {
        guard isRecording else { return }
        switch event {
        case .lost: micNotice = .missing
        case .switched(let name):
            micNotice = name.map { .switched($0) }
            switchedAt = deps.now()
        }
        chirpLog.info("notes input \(event == .lost ? "lost" : "switched", privacy: .public)")
        sync()
    }

    /// The Mac goes to sleep: the segment is cut and capture closes cleanly (a pause), so sleep is never a failure.
    private func willSleep() {
        guard recorder.state == .recording else { return }
        pausedForSleep = true
        Task { await pause(reason: NotesStatus.sleptPause) }
    }

    /// Awake: a session the sleep paused records again, and what waited for the server is sent.
    private func didWake() {
        recorder.serverAvailable()
        guard pausedForSleep else { return }
        pausedForSleep = false
        Task {
            guard isPaused, recorder.pauseReason == NotesStatus.sleptPause else { return }
            await resume()
        }
    }

    /// Stop: the microphone closes at once, then the last segment finalizes and the final pass runs.
    public func stop() async {
        guard isRecording || isPaused else { return }
        closeCapture()
        if settings.soundsEnabled { deps.play(.stop) }
        await recorder.stop()
    }

    /// Pause: the microphone closes at once and the segment finalizes; no final pass. `reason` (a sleeping Mac, a long
    /// silence) replaces the plain "Paused" in the status.
    public func pause(reason: String? = nil) async {
        guard isRecording, recorder.state == .recording else { return }
        closeCapture()
        if settings.soundsEnabled { deps.play(.stop) }
        await recorder.pause(reason: reason)
        chirpLog.info("notes paused reason=\(reason != nil, privacy: .public)")
    }

    /// Resume: a fresh socket into the same tail, then the microphone opens again.
    public func resume() async {
        guard isPaused, !gate.isPaused else { return }
        guard !isDictating() else { deps.beep(); return }
        recorder.options = settings.notesStartOptions(health: resolvedHealth())
        if settings.soundsEnabled { deps.play(.start) }
        let micMayOpen = deps.now() + deps.soundStartDelay()
        await recorder.resume()
        guard recorder.state == .recording else { return }
        let wait = micMayOpen - deps.now()
        if wait > 0 { await deps.sleep(.seconds(wait)) }
        guard isRecording, !capture.isRunning else { return }
        openMicrophone()
    }

    public func togglePause() async {
        if isPaused { await resume() } else { await pause() }
    }

    private func fail(_ message: String) async {
        closeCapture()
        if isRecording {
            await recorder.fail(message)
        } else if NotesModel.acceptsStartError(recorder.state) {
            // Only a start that never got going; a race with Stop (the recorder is finishing) is not an error.
            startError = message
            sync()
        }
    }

    /// Quit: finish gracefully for at most `limit`, then drop what is still in flight.
    public func stopForQuit(limit: Duration = .seconds(5)) async {
        guard isActive else { return }
        closeCapture()
        let finished = AsyncStream<Void>.makeStream()
        let sleep = deps.sleep
        Task { if self.isRecording || self.isPaused { await self.recorder.stop() } else { await self.waitWhileStopping() }; finished.continuation.yield() }
        Task { await sleep(limit); finished.continuation.yield() }
        for await _ in finished.stream { break }
        if isActive { recorder.cancel() }
    }

    func waitWhileStopping() async {
        while recorder.state == .stopping { await deps.sleep(.milliseconds(100)) }
    }

    /// New (after the dirty guard): an empty document.
    public func reset() {
        guard !isActive else { return }
        selectionGeneration += 1
        startError = nil
        recorder.reset()
        speakers.reset()
        voices.reset()
        recorder.speakers = nil
        sources = settings.notesSources
        callNotice = nil
        model.snapshots.removeAll()
        model.closeReview()
        model.longRunAcknowledged = 0
        model.highlightedParagraph = nil
    }

    /// Opens a stored note after all writes for the previous document are durable.
    public func openNote(_ id: UUID) async throws {
        guard !isActive, let library else { throw NotesLibraryError.recording }
        selectionGeneration += 1
        let generation = selectionGeneration
        journal.flush()
        await journal.settle()
        let record = try await library.record(id)
        guard !isActive, generation == selectionGeneration, record.document.deletedAt == nil else { throw NotesLibraryError.deleted }
        restoreRecord(record)
        model.snapshots.removeAll()
        model.closeReview()
    }

    /// Updating keep-export status may invoke sync; publish only after both journal and recorder adopt the note.
    private func restoreRecord(_ record: NotesJournalRecord) {
        restoringDocument = true
        journal.adopt(record)
        recorder.restore(record.document, elapsed: record.elapsed)
        restoringDocument = false
        sync()
    }

    public func continueRecording(_ id: UUID, focus: Bool = true) async throws {
        try await openNote(id)
        start(focus: focus)
    }

    /// Applies a rename to the current document as well, so a later journal write retains it.
    public func renameNote(_ id: UUID, title: String) async throws {
        guard let library else { throw NotesLibraryError.missing }
        if recorder.document.id == id { recorder.rename(title) }
        await journal.settle()
        try await library.rename(id, title: title)
    }

    // MARK: organize snapshots

    /// Restore Notes Before Organize: the snapshot's text goes back as one undoable change, with the edits typed since
    /// kept when they sit outside what Organize touched; otherwise it asks first (`confirmed`) and replaces the notes.
    private func restoreSnapshot(_ id: Int, confirmed: Bool) {
        guard recorder.state != .stopping, let snapshot = model.snapshots.snapshot(id) else { return }
        let current = recorder.document.text
        let target: String
        switch NotesSnapshots.restore(snapshot, now: current) {
        case .text(let text): target = text
        case .replace(let text):
            guard confirmed else { model.confirmingRestore = id; return }
            target = text
        }
        model.closeReview()
        model.snapshots.remove(id)
        guard let change = NotesDocument.diff(current, target, kind: .restore) else { return }
        recorder.restoreText(change.range, change.replacement)
        chirpLog.info("notes organize restored chars=\(target.utf16.count, privacy: .public)")
    }

    // MARK: speaker labels

    /// "Label speakers", from the ✦ menu, the status line's Turn off or Settings › Notes (applies from the next
    /// Record; refused while recording, except turning it off while no diarizer is running, which cancels the download).
    public func setSpeakerLabels(_ on: Bool) {
        guard !isActive || (!on && speakers.diarizer == nil) else { deps.beep(); return }
        speakers.setEnabled(on, documentHasLabels: recorder.document.speakerCount > 0)
        if !speakers.enabled, speakers.diarizer == nil { recorder.speakers = nil }
    }

    /// The model finished downloading with labels on: a recording or pause in progress joins from here on; otherwise
    /// the next Record picks it up.
    private func speakersReady() {
        guard speakers.enabled, recorder.state.isLive, let diarizer = speakers.readyDiarizer() else { return }
        diarizer.collectVoiceClips(voices.enabled)
        recorder.speakers = usesCallAudio ? CallSpeakers(remote: diarizer) : diarizer
        recorder.joinSpeakers()
        sync()
    }

    /// Settings › Remove: deletes the model, partial downloads too; refused while recording or loading.
    public func removeSpeakerModel() {
        guard !isActive, speakers.remove() else { deps.beep(); return }
        recorder.speakers = nil
    }

    public func markSaved() { recorder.markSaved() }

    /// Save… wrote `url`: the document is saved, and with `keep` the file follows later changes.
    public func didSave(to url: URL, keep: Bool) {
        recorder.markSaved()
        journal.didSave(to: url, keep: keep)
        chirpLog.info("notes saved keep=\(keep, privacy: .public)")
        sync()
    }

    /// Discard (the quit alert, where no New follows): the recovery copy goes with the notes.
    public func discardJournal() { journal.discard() }

    // MARK: recovery

    /// At launch: a journal left by a session that did not end with Save or Discard is offered in the window.
    /// Returns whether there is one.
    @discardableResult
    public func checkRecovery() -> Bool {
        if let library {
            Task {
                try? await library.migrate(from: journal.store)
                try? await library.maintain(retention: settings.notesRetention)
            }
            return false
        }
        recoverable = journal.store.recoverable()
        offerRecovery()
        return model.recovery != nil
    }

    private func offerRecovery() {
        model.recovery = recoverable.first.map { RecoveryOffer(startedAt: $0.document.startedAt, elapsed: $0.elapsed) }
        if let first = recoverable.first {
            chirpLog.info("notes recovery offered segments=\(first.document.segments.count, privacy: .public) chars=\(first.document.text.utf16.count, privacy: .public)")
        }
    }

    /// The offered session, for Save… (it is written without being loaded).
    public var offeredDocument: NotesDocument? { recoverable.first?.document }

    /// Keep: the offered session becomes the stopped, still unsaved document (the caller asked about the current one).
    public func keepRecovered() {
        guard !isActive, !recoverable.isEmpty else { return }
        let record = recoverable.removeFirst()
        journal.discard()
        restoreRecord(record)
        model.snapshots.removeAll()
        model.recovery = nil
        chirpLog.info("notes recovery kept segments=\(record.document.segments.count, privacy: .public)")
        sync()
    }

    /// Discard or Save…: the offered journal is deleted and the next one (if any) is offered.
    public func dropRecovered() {
        guard !recoverable.isEmpty else { return }
        journal.discard(recoverable.removeFirst().document.id)
        offerRecovery()
    }

    /// The Settings switch changed: the footer line follows, and turning it off deletes the copy.
    public func recoveryCopyChanged() {
        journal.setEnabled(settings.notesRecoveryCopy)
        applyAvailability(resolvedHealth())
    }

    // MARK: structuring

    private func setStructure(_ on: Bool) {
        settings.setNotesStructure(on, health: resolvedHealth())
        applyAvailability(resolvedHealth())
    }

    /// The server's health, or the last answer from the same server when a poll just failed.
    private func resolvedHealth() -> Health? {
        let url = settings.serverURL
        if let h = health() {
            knownHealth = (url, h)
            return h
        }
        guard let known = knownHealth, known.url == url else { return nil }
        return known.health
    }

    /// New server health (or the toggle): what structuring may do, and the privacy line.
    public func healthChanged() {
        if health() != nil { recorder.serverAvailable() }
        let h = resolvedHealth()
        let config = settings.serverConfig()
        voices.configure(supported: h?.supportsSpeakerVoices == true, server: config.baseURL.absoluteString + (config.token ?? ""))
        Task { await voices.refresh() }
        guard h != lastHealth else { return }
        lastHealth = h
        if !isActive { recorder.options = settings.notesStartOptions(health: h) }
        applyAvailability(h)
    }

    private func applyAvailability(_ health: Health?) {
        let enabled = settings.notesStructureEnabled(health: health)
        model.structureEnabled = enabled
        recorder.configureStructuring(enabled: enabled, health: health)
        model.privacyHelp = NotesModel.libraryPrivacyHelp
        model.structuringHost = enabled && health?.correctionLeavesMachine == true ? health?.correctionHost ?? settings.serverConfig().host : nil
        model.privacyLine = NotesModel.libraryPrivacy
        model.canManageModels = settings.serverConfig().isLoopback
        sync()
    }

    // MARK: model

    func sync() {
        guard !restoringDocument else { return }
        if recorder.state != lastRecorderState {
            // The recorder moved on: an earlier start error no longer describes it.
            lastRecorderState = recorder.state
            startError = nil
        }
        let state = NotesModel.displayState(recorder: recorder.state, startError: startError)
        let leftCapture = state != lastState && !state.isCapturing
        if state != lastState {
            chirpLog.info("notes \(String(describing: self.lastState.logName), privacy: .public) -> \(state.logName, privacy: .public) segments=\(self.recorder.document.segments.count, privacy: .public) chars=\(self.recorder.document.text.utf16.count, privacy: .public) tail=\(self.recorder.document.tail.utf16.count, privacy: .public)")
            lastState = state
            if !recorder.state.isCapturing { closeCapture() }
        }
        if !recorder.state.isCapturing { micNotice = nil; callNotice = nil }
        model.state = state
        let changes = recorder.takePendingChanges()
        model.snapshots.record(changes, from: model.document.text, result: recorder.document.text, at: Date())
        if let open = model.reviewing, model.snapshots.snapshot(open) == nil { model.closeReview() }
        model.document = recorder.document
        model.structuring = recorder.structuring
        model.speakerLabels = speakers.enabled
        model.sources = sources
        model.callAudioAvailable = deps.callTap != nil
        model.capturingCall = callCapture != nil
        model.callNotice = callNotice
        model.speakerModel = speakers.model
        model.voices = voiceState()
        processVoices()
        let reorganize = recorder.reorganizeStatus
        model.reorganizeStatus = reorganize
        if voiceEdit.status != model.voiceEdit, case .done(let outcome, _) = voiceEdit.status {
            deps.announce(NotesStatus.voiceEditNote(outcome) ?? NotesStatus.voiceEdited)
        }
        model.voiceEdit = voiceEdit.status
        model.voiceEditAvailable = recorder.canEdit
        model.canVoiceEdit = voiceEdit.status.isListening || voiceEdit.canStart
        // The editor replays the AI changes right away, onto text that matches `model.document` before them.
        model.enqueue(changes)
        library?.setRecordingNote(recorder.state.isActive ? recorder.document.id : nil)
        documentShown()
        journal.update(recorder.document, elapsed: recorder.elapsed, urgent: !changes.isEmpty || leftCapture, recording: recorder.state.isActive)
        model.keepSaving = journal.keepStatus
        model.debugRetention = recorder.debugRetention || (resolvedHealth()?.debugRetention ?? false)
        if !recorder.state.isCapturing, model.level != 0 { model.level = 0 }
        model.elapsed = recorder.elapsed
        model.connection = recorder.connection
        model.micNotice = micNotice
        model.pauseReason = recorder.pauseReason
        model.finishingElapsed = recorder.stoppingElapsed
        model.reduceMotion = deps.reduceMotion()
        setTicking(recorder.state.isCapturing || recorder.state == .stopping)
        let announcement = model.announcement
        if announcement != lastAnnouncement {
            lastAnnouncement = announcement
            if !announcement.isEmpty { deps.announce(announcement) }
        }
        if reorganize != lastReorganize {
            if case .applied = reorganize { deps.announce(NotesStatus.reorganized) }
            lastReorganize = reorganize
        }
        onChange?()
    }

    /// The elapsed time in the window and the menu header, once a second while recording.
    private func setTicking(_ on: Bool) {
        guard on != (stopTick != nil) else { return }
        stopTick?()
        stopTick = nil
        guard on else { return }
        stopTick = deps.startTicker { [weak self] in
            guard let self else { return }
            self.model.elapsed = self.recorder.elapsed
            self.model.connection = self.recorder.connection
            if case .switched = self.micNotice, let at = self.switchedAt, self.deps.now() - at >= Self.switchedNoticeFor {
                self.micNotice = nil
                self.model.micNotice = nil
            }
            self.model.finishingElapsed = self.recorder.stoppingElapsed
            self.announceLongRun()
            self.onChange?()
        }
    }

    /// The 2 h reminder is announced once when it appears (it stays on screen until answered).
    private func announceLongRun() {
        let shows = model.showsLongRunNotice
        if shows, !lastLongRun { deps.announce(NotesStatus.longRun(hours: model.longRunHours)) }
        lastLongRun = shows
    }
}

// MARK: library window

extension NotesSession {
    /// The note on screen: one opened beside a recording, or the recorder's.
    public var displayedModel: NotesModel { window.displayed(model) }

    private func wireLibrary() {
        let w = window
        w.onSelect = { [weak self] in self?.select($0) }
        w.onNew = { [weak self] in self?.newNote() }
        w.onRename = { [weak self] id, title in
            guard let self else { return }
            Task { try? await self.rename(id, title: title) }
        }
        w.onTrash = { [weak self] in self?.trash($0) }
        w.onRestore = { [weak self] in self?.restore($0) }
        w.onPurge = { [weak self] id in
            guard let library = self?.library else { return }
            Task { try? await library.purge(id) }
        }
        w.onEmptyTrash = { [weak self] in
            guard let library = self?.library else { return }
            Task { for e in library.recentlyDeleted { try? await library.purge(e.id) } }
        }
        w.onContinue = { [weak self] in self?.continueHere($0) }
        w.onStopAndContinue = { [weak self] id in
            guard let self else { return }
            Task { await self.stopAndContinue(id) }
        }
        w.onQuery = { [weak self] in self?.search($0) }
        model.onTitleEdit = { [weak self] title in
            guard let self else { return }
            self.titleEdited(self.recorder.document.id, title)
        }
        w.selection = .note(recorder.document.id)
        wireRetranscribe()
        observeLibrary()
        if let library { Task { try? await library.reload() } }
    }

    /// The library changed on disk: the list follows, and so does a search and the note's kept audio.
    private func observeLibrary() {
        guard let library else { return }
        withObservationTracking {
            _ = library.notes
            _ = library.recentlyDeleted
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.mirrorLibrary()
                self?.observeLibrary()
            }
        }
        mirrorLibrary()
    }

    private func mirrorLibrary() {
        guard let library else { return }
        window.notes = library.notes
        window.deleted = library.recentlyDeleted
        if !window.query.trimmingCharacters(in: .whitespaces).isEmpty { search(window.query, debounce: false) }
        let shown = displayedModel
        let bytes = window.entry(shown.document.id)?.audioBytes ?? 0
        if audioSeen[shown.document.id] != bytes { refreshKeptAudio(shown) }
    }

    /// Keeps the window in step with the recorder: the Recording section, the selection when the recorder moves to
    /// another note (New, the hotkey, Continue), and the title field.
    func documentShown() {
        guard library != nil else { return }
        window.recordingID = recorder.state.isActive ? recorder.document.id : nil
        let id = recorder.document.id
        guard id != lastDocumentID else { return }
        lastDocumentID = id
        model.titleDraft = nil
        renameTask?.cancel()
        if browsing == nil, window.selection != .recentlyDeleted { window.selection = .note(id) }
        refreshKeptAudio(model)
    }

    /// The note's kept segment audio, for ▶ in the transcript.
    private func refreshKeptAudio(_ target: NotesModel) {
        guard let library else { return }
        let id = target.document.id
        audioSeen[id] = window.entry(id)?.audioBytes ?? 0
        Task {
            let refs = (try? await library.segmentAudio(id)) ?? []
            guard target.document.id == id else { return }
            target.keptAudio = Dictionary(refs.map { ($0.reference.id, $0.url) }, uniquingKeysWith: { _, last in last })
        }
    }

    /// A row was chosen. While a note records, any other note opens beside it (the recording goes on); otherwise the
    /// recorder opens it.
    func select(_ item: NotesSidebarItem?) {
        window.player.stop()
        guard let id = item?.noteID else { return }
        if id == recorder.document.id { closeBrowsing(); return }
        if isActive { browse(id); return }
        closeBrowsing()
        Task {
            do { try await openNote(id) } catch { chirpLog.info("notes open failed") }
        }
    }

    private func browse(_ id: UUID) {
        guard let library else { return }
        Task {
            await browsing?.flush()
            guard let record = try? await library.record(id), window.selection == .note(id), record.document.deletedAt == nil else { return }
            show(NotesBrowsedNote(record: record, library: library, like: model))
        }
    }

    private func show(_ note: NotesBrowsedNote) {
        browsing = note
        note.model.onSpeakerEdit = { [weak self, weak note] edit in
            guard let self, let note else { return }
            guard edit == .dismiss || !self.window.isRetranscribing(note.model.document.id) else { self.deps.beep(); return }
            note.editSpeakers(edit)
        }
        note.model.onRecordToggle = { [weak self, weak note] in if let id = note?.model.document.id { self?.continueHere(id) } }
        note.model.onTitleEdit = { [weak self, weak note] title in if let id = note?.model.document.id { self?.titleEdited(id, title) } }
        note.model.onShowTranscript = { [weak self] in self?.window.setInspector(true) }
        window.browsed = note.model
        refreshKeptAudio(note.model)
    }

    private func closeBrowsing() {
        guard let note = browsing else { return }
        browsing = nil
        window.browsed = nil
        Task { await note.flush() }
    }

    /// New Note (⌘N, the empty state): a blank note. While another records, it opens beside the recording.
    public func newNote() {
        guard library != nil else { reset(); return }
        if isActive {
            guard let library else { return }
            let note = NotesBrowsedNote(record: NotesJournalRecord(document: NotesDocument(), elapsed: 0), library: library, like: model)
            window.selection = .note(note.model.document.id)
            show(note)
            note.model.focusRequest += 1
            return
        }
        closeBrowsing()
        reset()
        window.selection = .note(recorder.document.id)
        model.focusRequest += 1
    }

    /// The title field: saved after a short pause in typing (an empty title goes back to the derived one).
    private func titleEdited(_ id: UUID, _ title: String) {
        renameTask?.cancel()
        renameTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            try? await rename(id, title: title)
        }
    }

    private func rename(_ id: UUID, title: String) async throws {
        if let note = browsing, note.model.document.id == id {
            note.model.document.rename(title)
            await note.flush()
        }
        try await renameNote(id, title: title)
    }

    /// ⌫ / Delete: to Recently Deleted, with Undo in a toast (and ⌘Z). A note that records can't be deleted.
    public func trash(_ id: UUID) {
        guard let library, window.canTrash(id), !(isActive && id == recorder.document.id) else { deps.beep(); return }
        retranscribe?.cancel(note: id)
        let next = neighbor(of: id)
        Task {
            if let note = browsing, note.model.document.id == id {
                await note.flush()
                closeBrowsing()
            }
            let onRecorder = id == recorder.document.id
            if onRecorder {
                journal.flush()
                await journal.settle()
            }
            do { try await library.trash(id) } catch { deps.beep(); return }
            if onRecorder, !isActive { reset() }
            window.showToast(NotesLibraryText.deleted, undo: id)
            if let next { window.select(.note(next)) } else if onRecorder { window.selection = .note(recorder.document.id) }
        }
    }

    /// The row after `id` in the list (or the one before it), for the selection after a delete.
    private func neighbor(of id: UUID) -> UUID? {
        let order = window.groups().flatMap(\.entries).map(\.id)
        guard let i = order.firstIndex(of: id) else { return window.recordingID }
        return i + 1 < order.count ? order[i + 1] : i > 0 ? order[i - 1] : window.recordingID
    }

    /// Undo or Restore: back from Recently Deleted, and selected.
    public func restore(_ id: UUID) {
        guard let library else { return }
        Task {
            try? await library.restore(id)
            if window.toast?.undo == id { window.toast = nil }
            window.select(.note(id))
        }
    }

    /// Continue recording (⌘⇧R) on a finished note: a new capture appends to it after a quiet divider. While another
    /// note records, it asks first ("Stop current and continue here").
    public func continueHere(_ id: UUID) {
        guard !window.isRetranscribing(id) else { deps.beep(); return }
        if id == recorder.document.id {
            if !isActive { start(focus: true) }
            return
        }
        if isActive { window.confirmingSwitch = id; return }
        Task {
            if let note = browsing, note.model.document.id == id { await note.flush() }
            closeBrowsing()
            window.selection = .note(id)
            try? await continueRecording(id)
        }
    }

    /// "Stop current and continue here": the recording finishes (its notes kept), then this note records.
    public func stopAndContinue(_ id: UUID) async {
        await stop()
        await waitWhileStopping()
        if let note = browsing, note.model.document.id == id { await note.flush() }
        closeBrowsing()
        window.selection = .note(id)
        try? await continueRecording(id)
    }

    /// Search over titles, notes and transcripts, a moment after typing stops.
    private func search(_ query: String, debounce: Bool = true) {
        searchTask?.cancel()
        guard let library, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            window.results = nil
            return
        }
        searchTask = Task {
            if debounce { try? await Task.sleep(for: .milliseconds(150)) }
            guard !Task.isCancelled, let results = try? await library.search(query), window.query == query else { return }
            window.results = results
        }
    }
}

/// A note opened while another records: its own `NotesModel`, edited by typing only (no recorder behind it), saved
/// to the library a moment after each edit. Organize and recording need the recorder: Continue asks to switch.
@MainActor
final class NotesBrowsedNote {
    let model = NotesModel()
    private var record: NotesJournalRecord
    private let library: NotesLibrary
    private var pending: Task<Void, Never>?
    private var dirty = false

    init(record: NotesJournalRecord, library: NotesLibrary, like recorder: NotesModel) {
        self.record = record
        self.library = library
        model.document = record.document
        model.elapsed = record.elapsed
        model.state = record.document.isEmpty && record.document.segments.isEmpty ? .idle : .stopped
        model.libraryEnabled = true
        model.structuring = .idle
        model.reorganizeStatus = .unavailable(.unsupported)
        model.tipSeen = true
        model.notesKey = recorder.notesKey
        model.dictationKey = recorder.dictationKey
        model.onCopy = recorder.onCopy
        model.onSave = recorder.onSave
        model.onUserEdit = { [weak self] range, text, kind in self?.edit(range, text, kind) }
        // Its speakers can be renamed, merged and reassigned as the recorder's note's are (saved like typing).
        model.onSpeakerEdit = { [weak self] edit in self?.editSpeakers(edit) }
        model.onRestoreSnapshot = { [weak self] id, confirmed in self?.restoreSnapshot(id, confirmed: confirmed) }
    }

    /// A re-transcribe changed the note (its transcript, or a rebuilt body): saved now.
    func update(_ body: (inout NotesDocument) -> Void) async {
        body(&model.document)
        dirty = true
        await flush()
    }

    /// The rebuilt body as one `.rebuild` change the editor replays and the review can show and take back.
    func rebuild(_ result: NotesRebuild.Result) async {
        let before = model.document.text
        guard let change = model.document.replaceBody(with: result.text, fallbackBlocks: result.fallbackBlocks) else { return }
        model.snapshots.record([change], from: before, result: model.document.text, at: Date())
        model.enqueue([change])
        dirty = true
        await flush()
    }

    /// Restore previous from the review sheet: as the recorder's note does it (later edits kept, or a confirmation).
    private func restoreSnapshot(_ id: Int, confirmed: Bool) {
        guard let snapshot = model.snapshots.snapshot(id) else { return }
        let current = model.document.text
        let target: String
        switch NotesSnapshots.restore(snapshot, now: current) {
        case .text(let text): target = text
        case .replace(let text):
            guard confirmed else { model.confirmingRestore = id; return }
            target = text
        }
        model.closeReview()
        model.snapshots.remove(id)
        guard let change = NotesDocument.diff(current, target, kind: .restore) else { return }
        _ = model.document.userEdit(change.range, change.replacement, kind: .restore)
        model.enqueue([change])
        changed()
    }

    private func edit(_ range: NSRange, _ text: String, _ kind: NotesTextChange.Kind) {
        _ = model.document.userEdit(range, text, kind: kind == .toggleTask ? .toggleTask : .user)
        if model.state == .idle, !model.document.isEmpty { model.state = .stopped }
        changed()
    }

    /// A speaker fix-up from its transcript; a replace in the notes reaches its editor like an AI change. No voice
    /// suggestions here: they belong to the recording.
    func editSpeakers(_ edit: SpeakerEdit) {
        let model = model
        let banner = SpeakerEditing.apply(edit, banner: model.visibleSpeakerBanner?.kind, document: { model.document }) { body in
            let changes = body(&model.document)
            model.enqueue(changes)
        }
        model.speakerBanner = banner.map { SpeakerBanner(document: model.document.id, kind: $0) }
        if edit != .dismiss { changed() }
    }

    private func changed() {
        dirty = true
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await flush()
        }
    }

    /// Writes what was typed now (before another note opens, Continue, or a delete).
    func flush() async {
        pending?.cancel()
        pending = nil
        guard dirty || model.document.userTitle != record.document.userTitle else { return }
        dirty = false
        record.document = model.document
        record.recording = false
        _ = try? await library.write(record)
    }
}

extension NotesRecorderState {
    /// The state's name for the log, never an error message (which could quote the server).
    public var logName: String {
        switch self {
        case .idle: "idle"
        case .starting: "starting"
        case .recording: "recording"
        case .stopping: "stopping"
        case .stopped: "stopped"
        case .paused: "paused"
        case .error: "error"
        }
    }
}

/// What the Live Notes silence watch saw: digital zeros began (a mute), ended, or ran `NotesCaptureSink.pauseAfter`.
public enum NotesSilenceEvent: Sendable { case started, ended, long }

/// Runs on the audio thread: the silence watch, then the frame to the recorder (which routes it and runs the segmenter).
/// Digital silence never stops Notes (dictation's `SilenceGuard` does): it warns, and pauses after `pauseAfter`.
public final class NotesCaptureSink: @unchecked Sendable {
    /// Digital silence this long pauses the session (and keeps the notes).
    public nonisolated static let pauseAfter: TimeInterval = 15 * 60

    private let recorder: NotesRecorder
    private let onSilence: @Sendable (NotesSilenceEvent) -> Void
    private let onLevel: (@Sendable (Level) -> Void)?
    private let warnAfter: TimeInterval
    private let pauseAfter: TimeInterval
    private let lock = NSLock()
    private var clock: TimeInterval = 0
    private var silentSince: TimeInterval?
    private var warned = false
    private var paused = false

    public init(recorder: NotesRecorder, warnAfter: TimeInterval = SilenceGuard().window, pauseAfter: TimeInterval = NotesCaptureSink.pauseAfter,
                onLevel: (@Sendable (Level) -> Void)? = nil, onSilence: @escaping @Sendable (NotesSilenceEvent) -> Void) {
        self.recorder = recorder
        self.onLevel = onLevel
        self.onSilence = onSilence
        self.warnAfter = warnAfter
        self.pauseAfter = pauseAfter
    }

    public func handle(_ frame: Data, call: CallFrame? = nil) {
        let level = Level(pcm16: frame)
        let event = lock.withLock { () -> NotesSilenceEvent? in
            clock += Double(frame.count / 2) / PCMConverter.sampleRate
            if level.peak > 0 {
                silentSince = nil
                paused = false
                defer { warned = false }
                return warned ? .ended : nil
            }
            let since = silentSince ?? clock
            silentSince = since
            if !warned, clock - since >= warnAfter { warned = true; return .started }
            if !paused, clock - since >= pauseAfter { paused = true; return .long }
            return nil
        }
        recorder.handleFrame(frame, level: level, call: call)
        onLevel?(call?.micLevel ?? level)
        if let event { onSilence(event) }
    }
}

// MARK: re-transcribe

extension NotesSession {
    /// Re-transcribe (#287): the controller, routed to whichever copy of a note is open, and the window's actions.
    func wireRetranscribe() {
        guard let library else { return }
        let settings = deps.settings
        retranscribe = NotesRetranscribeController(.init(
            settings: settings, library: library, window: window,
            makeSession: deps.retranscribeSession ?? deps.makeSession, structure: deps.structure,
            health: { [weak self] in self?.health() },
            local: { settings.serverConfig().isLoopback },
            document: { [weak self] id in await self?.retranscribeDocument(id) },
            update: { [weak self] id, body in await self?.retranscribeUpdate(id, body) ?? false },
            rebuild: { [weak self] id, result, version, force in
                await self?.retranscribeRebuild(id, result, version: version, force: force) ?? false
            },
            announce: deps.announce))
        let w = window
        w.retranscribeAllowed = settings.notesAllowRetranscribe
        w.onRetranscribe = { [weak self] id, segment in
            guard let self else { return }
            Task { await self.retranscribe?.offer(id, segment: segment) }
        }
        w.onRetranscribeStart = { [weak self] offer in self?.retranscribe?.start(offer) }
        w.onRetranscribeCancel = { [weak self] in self?.retranscribe?.cancel() }
        w.onRetranscribeApplyPartial = { [weak self] in self?.retranscribe?.applyPartial() }
        w.onRetranscribeDismiss = { [weak self] in self?.retranscribe?.dismiss() }
        w.onRestoreTranscript = { [weak self] id in self?.retranscribe?.restore(id) }
        w.onShowTranscriptChanges = { [weak self] id in self?.retranscribe?.showChanges(id) }
        w.onConfirmRebuild = { [weak self] replace in self?.retranscribe?.confirmRebuild(replace) }
        w.onManageModels = { [weak self] in self?.model.onManageModels() }
        w.onServerSettings = { [weak self] in self?.model.onServerSettings() }
        w.onShowRebuild = { [weak self] id in
            guard let model = self?.openModel(id), let snapshot = model.snapshots.items.last(where: \.rebuild) else { return }
            model.review(snapshot.id)
        }
        w.onUndoRebuild = { [weak self] id in
            guard let model = self?.openModel(id), let snapshot = model.snapshots.items.last(where: \.rebuild) else { return }
            model.onRestoreSnapshot(snapshot.id, false)
            // Edits since sit among the rebuilt lines: the review asks before replacing them.
            if model.confirmingRestore == snapshot.id { model.review(snapshot.id) }
        }
    }

    /// Settings → Notes → Allow re-transcribing changed: off hides every entry point and stops a run.
    public func retranscribeSettingChanged() {
        window.retranscribeAllowed = deps.settings.notesAllowRetranscribe
        if !window.retranscribeAllowed {
            window.retranscribeOffer = nil
            retranscribe?.cancel(note: nil)
        }
    }

    /// The model showing note `id` (the recorder's, or the one opened beside a recording).
    private func openModel(_ id: UUID) -> NotesModel? {
        if recorder.document.id == id { return model }
        if let note = browsing, note.model.document.id == id { return note.model }
        return nil
    }

    private func retranscribeDocument(_ id: UUID) async -> NotesDocument? {
        if recorder.document.id == id { return recorder.document }
        if let note = browsing, note.model.document.id == id { return note.model.document }
        guard let record = try? await library?.record(id), record.document.deletedAt == nil else { return nil }
        return record.document
    }

    /// One write: the open copy of the note when there is one (so the next journal write keeps the change), else its
    /// library record.
    private func retranscribeUpdate(_ id: UUID, _ body: (inout NotesDocument) -> Void) async -> Bool {
        if recorder.document.id == id { return recorder.updateDocument(body) }
        if let note = browsing, note.model.document.id == id {
            await note.update(body)
            return true
        }
        guard let library, var record = try? await library.record(id), record.document.deletedAt == nil else { return false }
        body(&record.document)
        return (try? await library.write(record)) != nil
    }

    private func retranscribeRebuild(_ id: UUID, _ result: NotesRebuild.Result, version: Int?, force: Bool) async -> Bool {
        if recorder.document.id == id {
            guard force || version == recorder.document.version else { return false }
            return recorder.rebuildNotes(result.text, fallbackBlocks: result.fallbackBlocks)
        }
        if let note = browsing, note.model.document.id == id {
            guard force || version == note.model.document.version else { return false }
            await note.rebuild(result)
            return true
        }
        guard let library, var record = try? await library.record(id), record.document.deletedAt == nil else { return false }
        guard force || version == record.document.version else { return false }
        record.document.replaceBody(with: result.text, fallbackBlocks: result.fallbackBlocks)
        return (try? await library.write(record)) != nil
    }
}
