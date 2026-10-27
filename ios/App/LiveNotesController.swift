import AVFoundation
import ChirpCore
import ChirpIOSCore
import Foundation
import UIKit

enum NotesAction { case start, togglePause, stop }

/// The paired server for the structuring calls, readable off the main actor.
final class NotesServerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ServerConfig?
    var config: ServerConfig? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Live Notes on iPhone and iPad: ChirpCore's `NotesRecorder` (rolling ≤45 s segments over `/v1/stream`, structuring
/// via `/v1/notes/structure` and `/v1/notes/reorganize` on the Mac) wired to its own microphone capture, the sealed
/// document library, the Live Activity and the app's lifecycle. Notes and a keyboard session never hold the microphone
/// together. Nothing here logs or exports text.
@MainActor
final class LiveNotesController: ObservableObject {
    @MainActor struct Dependencies {
        var server: () -> ServerConfig?
        var correctionAllowed: (Health) -> Bool
        var otherCaptureActive: () -> Bool
        var http: URLSession
        var fetchHealth: (ServerConfig, URLSession) async throws -> Health = { try await $0.fetchHealth(session: $1) }
        var makeStream: (ServerConfig, StartOptions, URLSession) -> StreamSession = { StreamSession(config: $0, options: $1, urlSession: $2) }
        /// Re-transcribe's sockets (#287): a `start.retranscribe` may wait up to a minute for the engine, so the app gives
        /// them a longer ready deadline. Nil uses `makeStream`.
        var retranscribeStream: ((ServerConfig, StartOptions, URLSession) -> StreamSession)?
        var structure: @Sendable (ServerConfig, URLSession, NotesStructureRequest, TimeInterval) async throws -> NotesStructureResponse = {
            try await $0.structureNotes($2, session: $1, timeout: $3)
        }
        var reorganize: @Sendable (ServerConfig, URLSession, NotesReorganizeRequest, TimeInterval) async throws -> NotesReorganizeResponse = {
            try await $0.reorganizeNotes($2, session: $1, timeout: $3)
        }
        /// `POST /v1/speakers/model`: the Mac fetches (or drops) its speaker model. Labels are on by default, so the phone asks
        /// for the one pinned download itself while they are on; Turn off stops asking.
        var speakersModel: @Sendable (ServerConfig, URLSession, SpeakersModelAction) async throws -> SpeakersModel = {
            try await $0.speakersModel($2, session: $1)
        }
        var fetchVoices: @Sendable (ServerConfig, URLSession) async throws -> SavedVoices = { try await $0.savedVoices(session: $1) }
        var voiceAction: @Sendable (ServerConfig, URLSession, VoiceLibraryAction) async throws -> SavedVoices = { try await $0.savedVoices($2, session: $1) }
        var audio: any NotesAudio
        var requestPermission: () async -> Bool
        var activity: NotesActivityControl
        var store: NotesStore?
        var copyText: (String) -> Void = { UIPasteboard.general.string = $0 }
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
        /// Starts the once-a-second elapsed tick; the returned closure stops it.
        var startTicker: (@escaping @MainActor () -> Void) -> () -> Void = { tick in
            let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
            return { timer.invalidate() }
        }
        /// Keeps the app running briefly while Stop finishes in the background.
        var backgroundTask: @MainActor (_ expired: @escaping @MainActor () -> Void) -> () -> Void = { expired in
            var id = UIBackgroundTaskIdentifier.invalid
            id = UIApplication.shared.beginBackgroundTask(withName: "Live Notes finishing") { MainActor.assumeIsolated { expired() } }
            return { if id != .invalid { UIApplication.shared.endBackgroundTask(id); id = .invalid } }
        }
        /// Audio kept in memory for an offline Mac (less than the Mac's 30 minutes: iOS limits a background app's memory).
        var keptAudio: TimeInterval = 10 * 60
        var observeLifecycle = true
    }

    /// The app's controller, for the Live Activity buttons and Shortcuts (nil until the Notes tab first appears).
    static private(set) var instance: LiveNotesController?

    static let interruptedReason = "Paused · another app or a call took the microphone"
    static let lostReason = "Paused · microphone unavailable"

    @Published private(set) var state: NotesRecorderState = .idle
    @Published private(set) var document = NotesDocument()
    @Published private(set) var structuring: StructuringStatus = .off(.waiting)
    @Published private(set) var reorganize: ReorganizeStatus = .idle
    @Published private(set) var connection: NotesConnection = .online
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var pauseReason: String?
    @Published private(set) var debugRetention = false
    @Published private(set) var snapshots = NotesSnapshots()
    @Published private(set) var entries: [NotesLibraryEntry] = []
    @Published private(set) var recentlyDeleted: [NotesLibraryEntry] = []
    @Published private(set) var recordingID: UUID?
    @Published private(set) var recordingElapsed: TimeInterval = 0
    @Published private(set) var recordingPreview = ""
    @Published private(set) var totalAudioBytes = 0
    @Published private(set) var libraryReady = false
    @Published private(set) var undoDeleted: [UUID] = []
    @Published private(set) var requestedSelection: UUID?
    let library: NotesLibrary?
    @Published private(set) var health: Health?
    @Published private(set) var notice = ""
    @Published private(set) var preferences = NotesPreferences()
    @Published private(set) var starting = false
    /// The request for the Mac's speaker model could not reach it (the status line offers Retry).
    @Published private(set) var speakerRequestFailed = false
    /// Re-transcribe from kept audio (#287, LiveNotesRetranscribe.swift): the consent sheet on offer, the run (one at a
    /// time), the finish toast and "Replace your edits?" for a rebuild that would overwrite typing.
    @Published var retranscribeOffer: NotesRetranscribeOffer?
    @Published var retranscribeRun: NotesRetranscribeRun?
    @Published var retranscribeToast: NotesRetranscribeToast?
    @Published var confirmingRebuild: UUID?
    let retranscribeWork = NotesRetranscribeWork()
    private var speakerPoll: Task<Void, Never>?
    private var speakerRequest: Task<Void, Never>?
    /// Screen updates skipped while locked in battery saver (for the tests and the status line).
    private(set) var skippedUpdates = 0

    /// Each open document owns its recorder and journal. In-flight AI work always updates its original document.
    private final class NoteSession {
        let recorder: NotesRecorder
        var journal: NotesJournal?
        var snaps = NotesSnapshots()
        var textBefore = ""
        var lastState: NotesRecorderState = .idle
        var voices = NoteVoiceState()
        init(_ recorder: NotesRecorder) { self.recorder = recorder }
    }
    private var sessions: [UUID: NoteSession] = [:]
    private var selected: NoteSession!
    var recorder: NotesRecorder { selected.recorder }
    private var captureRecorder: NotesRecorder? { recordingID.flatMap { sessions[$0]?.recorder } }
    private var journal: NotesJournal? { selected.journal }
    private var snaps: NotesSnapshots {
        get { selected.snaps }
        set { selected.snaps = newValue }
    }
    private(set) var deps: Dependencies
    private let serverBox: NotesServerBox
    private var loading: Task<Void, Never>?
    private var openGeneration = 0
    private var endingActivity: Task<Void, Never>?
    private var lastActivity: ChirpNotesActivityAttributes.ContentState?
    private var activityLive = false
    private var stopTick: (() -> Void)?
    private var endBackgroundTask: (() -> Void)?
    private var pausedForInterruption = false
    private var observers: [NSObjectProtocol] = []
    /// The app is in the background (the screen locked or another app in front).
    private(set) var background = false

    init(_ deps: Dependencies) {
        self.deps = deps
        let box = NotesServerBox()
        serverBox = box
        let preferences = (try? deps.store?.loadPreferences()) ?? NotesPreferences()
        self.preferences = preferences
        library = deps.store.map { NotesLibrary(store: $0.libraryStore) }
        selected = makeSession()
        if deps.observeLifecycle { observeApp() }
        sync()
        loading = Task { [weak self] in await self?.loadLibrary() }
    }

    private func makeSession(record: NotesJournalRecord? = nil) -> NoteSession {
        let box = serverBox
        let http = deps.http, reorganize = deps.reorganize, makeStream = deps.makeStream
        let recorder = NotesRecorder(
            makeSession: { options in makeStream(box.config ?? ServerConfig(baseURL: URL(string: "https://unpaired.invalid")!), options, http) },
            structure: structureCall(),
            reorganize: { [weak self] request in
                guard let config = box.config else { throw NotesStructureError.unsupported(404) }
                return try await reorganize(config, http, request, await self?.health?.operationTimeout(.notesReorganize, fallback: 50) ?? 50)
            },
            now: deps.now, sleep: deps.sleep, options: StartOptions(client: "ios", wordTimings: true), structuring: false,
            autoReorganize: preferences.autoReorganize, keptAudio: deps.keptAudio)
        if let record { recorder.restore(record.document, elapsed: record.elapsed) }
        let context = NoteSession(recorder)
        context.textBefore = recorder.document.text
        context.journal = makeJournal()
        recorder.onChange = { [weak self, weak context] in
            guard let context else { return }
            self?.sync(context)
        }
        recorder.onServerSpeakers = { [weak self, weak context] labels, session in
            guard let self, let context else { return }
            let names = context.voices.receive(labels, session: session, document: context.recorder.document, enabled: self.rememberVoices)
            if !names.isEmpty {
                context.recorder.editSpeakers { document in
                    for (person, name) in names { document.renameSpeaker(person, to: name) }
                    return []
                }
            }
            self.rememberPending(in: context)
        }
        recorder.shouldKeepAudio = { [weak self] in self?.preferences.keepNotes == true && self?.preferences.keepAudio == true }
        recorder.onSegmentAudio = { [weak self, weak context] id, segment, frames, offset in
            guard let context else { return }
            self?.sync(context)
            context.journal?.flush()
            context.journal?.keepAudio(id, segment: segment, frames: frames, offset: offset, sampleRate: PCMConverter.sampleRate)
        }
        sessions[recorder.document.id] = context
        return context
    }

    /// `/v1/notes/structure` on the paired server, with the advertised deadline (live structuring and a rebuild).
    func structureCall() -> NotesRecorder.Structure {
        let box = serverBox, http = deps.http, structure = deps.structure
        return { [weak self] request in
            guard let config = box.config else { throw NotesStructureError.unsupported(404) }
            return try await structure(config, http, request, await self?.health?.operationTimeout(.notesStructure, fallback: 35) ?? 35)
        }
    }

    /// Note `id` as its editor holds it (nil when it is not open).
    func noteDocument(_ id: UUID) -> NotesDocument? { sessions[id]?.recorder.document }

    /// A re-transcribe changes note `id` while it is not recording (its transcript): one change, journalled at once.
    func updateNote(_ id: UUID, _ body: (inout NotesDocument) -> Void) -> Bool {
        guard let context = sessions[id], context.recorder.updateDocument(body) else { return false }
        sync(context)
        context.journal?.flush()
        return true
    }

    /// Re-transcribe's rebuilt notes as one `.rebuild` change (Undo rebuild takes it back), when the body still reads
    /// `body` (nil: replace whatever it holds).
    func rebuildNote(_ id: UUID, _ result: NotesRebuild.Result, ifBody body: String?) -> Bool {
        guard let context = sessions[id], body == nil || context.recorder.document.text == body,
              context.recorder.rebuildNotes(result.text, fallbackBlocks: result.fallbackBlocks) else { return false }
        sync(context)
        context.journal?.flush()
        return true
    }

    private func makeJournal() -> NotesJournal? {
        guard let store = deps.store else { return nil }
        let journal = NotesJournal(store: store.journalStore, enabled: false,
            library: preferences.keepNotes ? library : nil, sleep: deps.sleep)
        journal.onWrite = { [weak self] bytes, _ in
            guard let self else { return }
            if bytes == nil { self.notice = "Notes could not be kept. Unlock this device and try again." }
            self.refreshRows()
        }
        return journal
    }

    func shutdown() {
        for context in sessions.values { context.recorder.onChange = nil; context.recorder.onServerSpeakers = nil; context.recorder.cancel() }
        deps.audio.stop()
        speakerPoll?.cancel(); speakerPoll = nil
        speakerRequest?.cancel(); speakerRequest = nil
        stopTick?(); stopTick = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
    }

    private func loadLibrary() async {
        defer { libraryReady = true }
        guard let store = deps.store, let library else { return }
        do {
            try await store.migrateRecovery()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--chirp-notes-gallery") { try await seedLibrary() }
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "--chirp-retranscribe-seed"), i + 2 < args.count { try await seedRetranscribe([args[i + 1], args[i + 2]]) }
            #endif
            try await library.maintain(retention: preferences.retention)
            refreshRows()
        } catch { notice = "Notes storage is unavailable. Unlock this device and try again." }
    }

    func ready() async { await loading?.value }

    private func refreshRows() {
        entries = library?.notes ?? []
        recentlyDeleted = library?.recentlyDeleted ?? []
        totalAudioBytes = library?.totalAudioBytes ?? 0
    }

    func open(_ id: UUID) async {
        openGeneration += 1
        let generation = openGeneration
        await ready()
        guard generation == openGeneration, id != recorder.document.id else { return }
        journal?.flush()
        if let existing = sessions[id] { selected = existing }
        else if let library {
            do {
                let record = try await library.record(id)
                guard generation == openGeneration else { return }
                selected = makeSession(record: record)
            } catch { notice = "This note could not be opened."; return }
        } else { return }
        notice = ""
        configure()
        publish()
    }

    func newRecording() async {
        await ready()
        guard !isActive else {
            if let recordingID { await open(recordingID) }
            return
        }
        newNotes()
        await record()
    }

    /// New note (⌘N, the library's New note): a blank typed note that opens ready to type. It needs no pairing or
    /// microphone, a note that is recording keeps recording, and it is kept once you type or rename it (as on the Mac).
    func newNote() async {
        await ready()
        newNotes()
        editRequest = document.id
    }

    /// The note New note made, until its editor opens for typing.
    @Published private(set) var editRequest: UUID?

    /// True once for note `id` after New note: the detail opens its editor.
    func takeEditRequest(_ id: UUID) -> Bool {
        guard editRequest == id else { return false }
        editRequest = nil
        return true
    }

    /// Explicit History hand-off. Nothing is copied automatically; capture stays with its own note.
    /// Returns the destination id, or nil for empty input / an unavailable destination.
    @discardableResult
    func addToNote(_ text: String, id: UUID? = nil) async -> UUID? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        await ready()
        if let id {
            await open(id)
            guard document.id == id else { return nil }
        } else { newNotes() }
        edit(document.text + (document.text.isEmpty ? "" : "\n\n") + value)
        let destination = document.id
        await settleJournal()
        requestedSelection = destination
        return destination
    }

    func didNavigateToNote() { requestedSelection = nil }

    func rename(_ title: String) async {
        let context = selected!, id = recorder.document.id
        context.recorder.rename(title)
        context.journal?.update(context.recorder.document, elapsed: context.recorder.elapsed, urgent: true, recording: context.recorder.state.isActive)
        await context.journal?.settle()
        refreshRows()
        if let library, entries.contains(where: { $0.id == id }) {
            do { try await library.rename(id, title: title); refreshRows() }
            catch { notice = "The note could not be renamed." }
        }
    }

    func delete(_ ids: [UUID]) async {
        await settleJournal()
        guard let library else { return }
        var deleted: [UUID] = []
        for id in ids where id != recordingID {
            cancelRetranscribe(note: id)
            do {
                // Flush and retire this editor before moving its durable record to Recently Deleted.
                sessions[id]?.journal?.flush()
                await sessions[id]?.journal?.settle()
                try await library.trash(id)
                sessions[id]?.recorder.onChange = nil
                sessions[id]?.recorder.cancel()
                sessions[id] = nil
                deleted.append(id)
            } catch { notice = "Stop recording before deleting a note." }
        }
        undoDeleted = deleted
        if !deleted.isEmpty { notice = deleted.count == 1 ? "Note deleted" : "Notes deleted" }
        if deleted.contains(document.id) { selected = makeSession(); publish() }
        refreshRows()
    }

    func restore(_ ids: [UUID]) async {
        guard let library else { return }
        for id in ids {
            do { try await library.restore(id) } catch { notice = "The note could not be restored." }
        }
        undoDeleted = []; refreshRows()
    }

    func emptyRecentlyDeleted() async {
        guard let library else { return }
        for entry in recentlyDeleted {
            do { try await library.purge(entry.id) } catch { notice = "Some notes could not be deleted." }
        }
        undoDeleted = []; refreshRows()
    }

    func deleteAudio(all: Bool = false) async {
        guard let library else { return }
        let ids = all ? (entries + recentlyDeleted).filter { $0.hasAudio }.map(\.id) : [document.id]
        for id in ids {
            do { try await library.deleteAudio(id) } catch { notice = "Some audio could not be deleted." }
        }
        refreshRows()
    }

    func audioData(segment: Int) async throws -> Data? {
        try await library?.store.audioData(document.id, segment: segment)
    }

    var recordingTitle: String { recordingID.flatMap { sessions[$0]?.recorder.document.title } ?? "Notes" }
    var selectedAudioBytes: Int { entries.first { $0.id == document.id }?.audioBytes ?? 0 }
    func hasAudio(_ segment: Int) -> Bool {
        (audioSegments[document.id] ?? Set(document.audio.map(\.id))).contains(segment)
    }
    private var audioSegments: [UUID: Set<Int>] = [:]
    func refreshAudio() async {
        guard let library, let record = try? await library.record(document.id) else { return }
        audioSegments[document.id] = Set(record.document.audio.map(\.id))
        objectWillChange.send()
    }

    var isActive: Bool { recordingID != nil || starting }
    var isPaused: Bool { recorder.state == .paused }
    var paired: Bool { deps.server() != nil }

    // MARK: recording

    func record() async {
        await ready()
        guard !starting, !recorder.state.isActive else { return }
        guard recordingID == nil else { notice = "Stop current and continue here."; return }
        guard let config = deps.server() else { notice = "Pair your computer first."; return }
        guard !deps.otherCaptureActive() else { notice = "End the keyboard session to record notes."; return }
        let target = selected
        starting = true
        defer { starting = false }
        guard await deps.requestPermission() else { notice = SessionFailure.permission.localizedDescription; return }
        serverBox.config = config
        if let fresh = try? await deps.fetchHealth(config, deps.http), fresh.ok { health = fresh; recorder.serverAvailable(); fetchSpeakerModelIfNeeded(); pollSpeakerModel() }
        guard selected === target, !recorder.state.isActive, recordingID == nil, !deps.otherCaptureActive() else { return }
        configure()
        notice = ""
        await endingActivity?.value
        recordingPreview = recorder.document.snippet()
        recordingID = recorder.document.id
        library?.setRecordingNote(recordingID)
        recorder.start()
        guard openMicrophone() else { await recorder.fail("Microphone unavailable"); return }
        beginActivity()
    }

    func pause(reason: String? = nil) async {
        guard let active = captureRecorder, active.state == .recording else { return }
        deps.audio.stop()
        await active.pause(reason: reason)
    }

    func resume() async {
        guard let active = captureRecorder, active.state == .paused else { return }
        guard !deps.otherCaptureActive() else { notice = "End the keyboard session to record notes."; return }
        pausedForInterruption = false
        configure(sessions[active.document.id])
        await active.resume()
        guard active.state == .recording else { return }
        if !openMicrophone() { await active.pause(reason: Self.lostReason) }
    }

    func togglePause() async { if captureRecorder?.state == .paused { await resume() } else { await pause() } }

    /// Stop: the microphone closes at once, the last segment finalizes and the final pass runs on the Mac. A background
    /// task keeps a locked phone awake for that.
    func stop() async {
        guard let active = captureRecorder, active.state.isLive else { return }
        deps.audio.stop()
        endBackgroundTask?()
        endBackgroundTask = deps.backgroundTask { [weak self] in self?.captureRecorder?.cancel() }
        await active.stop()
        await sessions[active.document.id]?.journal?.settle()
        refreshRows()
        endBackgroundTask?(); endBackgroundTask = nil
    }

    func perform(_ action: NotesAction) async -> String {
        switch action {
        case .start:
            await record()
            return recorder.state.isActive ? "Recording notes." : (notice.isEmpty ? "Open Chirp to start Live Notes." : notice)
        case .togglePause:
            guard captureRecorder?.state.isLive == true else { return "Live Notes is not recording." }
            await togglePause()
            return captureRecorder?.state == .paused ? "Live Notes paused. Microphone off." : "Live Notes recording."
        case .stop:
            guard captureRecorder?.state.isLive == true else { return "Live Notes is not recording." }
            await stop()
            return "Live Notes stopped. Your notes are in Chirp."
        }
    }

    @discardableResult
    private func openMicrophone() -> Bool {
        let recorder = captureRecorder ?? self.recorder
        do {
            try deps.audio.start(frame: { data in recorder.handleFrame(data, level: Level(pcm16: data)) },
                                 event: { [weak self] event in Task { @MainActor in await self?.audioEvent(event) } })
            return true
        } catch { return false }
    }

    private func audioEvent(_ event: NotesAudioEvent) async {
        switch event {
        case .interrupted:
            guard captureRecorder?.state == .recording else { return }
            pausedForInterruption = true
            await pause(reason: Self.interruptedReason)
        case .resumable:
            guard pausedForInterruption, captureRecorder?.state == .paused else { return }
            await resume()
        case .lost:
            guard captureRecorder?.state == .recording else { return }
            await pause(reason: Self.lostReason)
        }
    }

    /// A blank note is never retained unless the user types, renames it, or starts recording.
    func newNotes() {
        openGeneration += 1
        journal?.flush()
        selected = makeSession()
        notice = ""
        configure()
        publish()
    }

    func stopAndContinue() async {
        await stop()
        await record()
    }

    // MARK: editing and Organize

    /// The editor's text changed. The edit is applied to what the recorder holds now; one that overlaps an AI change
    /// that landed meanwhile is dropped and the editor shows the current text.
    func edit(_ text: String) {
        if let change = NotesEditRebase.change(shown: document.text, edited: text, current: recorder.document.text) {
            recorder.userEdit(change.range, change.replacement)
        }
        publish()
    }

    /// Typing holds structuring appends (up to `NotesRecorder.holdMax` after the last keystroke).
    func setEditing(_ editing: Bool) { recorder.setEditorFocus(inTail: editing, composing: false) }

    func organize() { recorder.reorganizeNow() }

    var canUndoOrganize: Bool { snaps.latest != nil && recorder.state != .stopping }

    /// Undo the last Organize. Returns false when edits since would be lost: the view asks, then calls again confirmed.
    @discardableResult
    func undoOrganize(confirmed: Bool = false) -> Bool {
        guard recorder.state != .stopping, let snapshot = snaps.latest else { return true }
        let current = recorder.document.text
        let target: String
        switch NotesSnapshots.restore(snapshot, now: current) {
        case .text(let text): target = text
        case .replace(let text):
            guard confirmed else { return false }
            target = text
        }
        snaps.remove(snapshot.id)
        if let change = NotesDocument.diff(current, target, kind: .restore) { recorder.restoreText(change.range, change.replacement) }
        sync()
        return true
    }

    // MARK: export

    var markdown: String { recorder.document.exportMarkdown() }

    func copy() { deps.copyText(markdown); notice = "Copied notes and transcript." }

    func didExport() { notice = "Markdown exported." }

    /// Flushes debounced edits before navigation, backgrounding, and tests.
    func settleJournal() async {
        for context in sessions.values { context.journal?.flush() }
        for context in sessions.values { await context.journal?.settle() }
        refreshRows()
    }

    // MARK: preferences

    func setStructure(_ on: Bool) {
        preferences.structure = on
        preferences.structureConsentHost = on && health?.correctionLeavesMachine == true ? health?.correctionHost : nil
        save()
    }
    func setAutoReorganize(_ on: Bool) { preferences.autoReorganize = on; for context in sessions.values { context.recorder.setAutoReorganize(on) }; save() }
    func setBatterySaver(_ on: Bool) { preferences.batterySaver = on; save() }
    func setKeepNotes(_ on: Bool) {
        preferences.keepNotes = on
        for context in sessions.values {
            context.journal?.flush()
            context.journal = makeJournal()
        }
        save()
        sync()
    }
    func setKeepAudio(_ on: Bool) { preferences.keepAudio = on; save() }
    /// Settings → Notes → Allow re-transcribing: off hides every entry point and stops a run.
    func setAllowRetranscribe(_ on: Bool) {
        preferences.allowRetranscribe = on; save()
        if !on { retranscribeOffer = nil; cancelRetranscribe(note: nil) }
    }
    func rememberRebuildChoice(_ on: Bool) { preferences.retranscribeRebuild = on; save() }
    func setRetention(_ retention: NotesRetention) {
        preferences.retention = retention; save()
        Task {
            do { try await library?.maintain(retention: retention); refreshRows() }
            catch { notice = "Retention could not be applied." }
        }
    }

    // MARK: Shared server voice library

    @Published private(set) var savedVoices: SavedVoices?
    @Published private(set) var voicesBusy = false
    @Published private(set) var voicesError: String?
    @Published var rememberedVoiceNotice: String?
    private var voicesServer: ServerConfig?
    private var voicesRevision = 0
    var voicesAvailable: Bool { health?.supportsSpeakerVoices == true }
    var rememberVoices: Bool { voicesAvailable && savedVoices?.enabled == true }

    func refreshSavedVoices() async {
        guard let config = deps.server(), voicesAvailable else { savedVoices = nil; return }
        if voicesServer != config {
            savedVoices = nil
            for context in sessions.values { context.voices = NoteVoiceState() }
            voicesServer = config
        }
        let revision = voicesRevision
        do {
            let library = try await deps.fetchVoices(config, deps.http)
            guard deps.server() == config, voicesRevision == revision else { return }
            savedVoices = library
            voicesError = nil
        } catch { if deps.server() == config { voicesError = SavedVoiceNotice.error(error) } }
    }

    func changeSavedVoices(_ action: VoiceLibraryAction) async {
        guard !voicesBusy, voicesAvailable, let config = deps.server() else { return }
        voicesRevision += 1
        voicesBusy = true
        defer { voicesBusy = false }
        do {
            let library = try await deps.voiceAction(config, deps.http, action)
            guard deps.server() == config else { return }
            savedVoices = library; voicesError = nil
            let ids = Set(library.voices.map(\.id))
            for context in sessions.values {
                context.voices.linked = context.voices.linked.filter { ids.contains($0.value) }
                context.voices.recognised = context.voices.recognised.filter { ids.contains($0.value.voice) }
                if action == .forgetAll { context.voices.pending.removeAll() }
            }
            if !library.enabled {
                for context in sessions.values { context.voices.pending.removeAll(); context.voices.recognised.removeAll() }
            }
        } catch { if deps.server() == config { voicesError = SavedVoiceNotice.error(error) } }
    }

    func recognisedVoice(_ person: Int) -> ServerVoiceMatch? {
        guard rememberVoices else { return nil }
        return selected.voices.recognised[document.roster.resolve(person)]
    }

    func rejectVoice(_ person: Int) {
        let id = document.roster.resolve(person)
        selected.voices.reject(id)
        fixSpeakers { SpeakerFixups.rename(id, to: "", replaceInNotes: true, in: &$0) }
    }

    func canUpdateVoice(_ person: Int) -> Bool {
        rememberVoices && selected.voices.linked[document.roster.resolve(person)] != nil
    }

    func updateVoice(_ person: Int) {
        let id = document.roster.resolve(person)
        selected.voices.pending[id] = document.roster.person(id: id)?.name
        rememberPending(in: selected)
    }

    private func rememberPending(in context: NoteSession) {
        guard rememberVoices, let config = deps.server() else { return }
        for (person, name) in context.voices.pending {
            guard SavedVoice.isValidName(name), !context.voices.inFlight.contains(person) else { continue }
            guard let source = context.voices.sources[person] else {
                if context === selected { voicesError = "Record a little more with them, then try again" }
                continue
            }
            let voice = context.voices.linked[person] ?? savedVoices?.voices.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
            context.voices.inFlight.insert(person)
            let revision = voicesRevision
            Task { [weak self, weak context] in
                guard let self, let context else { return }
                var saveNewerName = false
                defer {
                    context.voices.inFlight.remove(person)
                    if saveNewerName { self.rememberPending(in: context) }
                }
                do {
                    let library = try await self.deps.voiceAction(config, self.deps.http, .remember(name: name, from: source, voice: voice))
                    guard self.deps.server() == config else { return }
                    guard self.voicesRevision == revision else { await self.refreshSavedVoices(); return }
                    self.savedVoices = library; self.voicesError = nil
                    context.voices.linked[person] = library.voice?.id
                    if context.voices.pending[person] == name { context.voices.pending[person] = nil }
                    else { saveNewerName = context.voices.pending[person] != nil }
                    if !self.preferences.voiceNoticeShown {
                        self.preferences.voiceNoticeShown = true; self.save()
                        self.rememberedVoiceNotice = name
                    }
                } catch {
                    guard self.deps.server() == config, self.voicesRevision == revision else { return }
                    if context === self.selected { self.voicesError = SavedVoiceNotice.error(error) }
                    // Too-short remains queued for the next labelled segment; gone needs fresh server state.
                    if error as? VoiceLibraryError == .gone { context.voices.sources[person] = nil }
                    if error as? VoiceLibraryError != .tooShort && error as? VoiceLibraryError != .gone {
                        context.voices.pending[person] = nil
                    }
                }
            }
        }
    }

    // MARK: speaker labels

    /// The Mac's server can label speakers (health); an older one cannot.
    var speakersAvailable: Bool { SpeakerNotice.available(health) }
    /// On unless the user turned it off (`stored ?? true`).
    var labelSpeakers: Bool { preferences.speakerLabelsOn }
    /// The line in the note's banner slot while labels are on but not working yet (never modal; nil: nothing to say).
    var speakerStatus: SpeakerNotice.Status? {
        SpeakerNotice.status(on: labelSpeakers, health: health, recorderError: recorder.speakerError, requestFailed: speakerRequestFailed)
    }
    /// Where the Mac's model stands, for the Settings row.
    var speakerModelStatus: String? {
        SpeakerNotice.modelStatus(on: labelSpeakers, health: health, requestFailed: speakerRequestFailed)
    }

    /// The switch, Turn off and the note's menu: the only writers of the preference, so a stored `false` is the user's
    /// own choice. Applies from the next segment. On fetches the Mac's model if it is missing; off stops looking at it.
    func setLabelSpeakers(_ on: Bool) {
        preferences.labelSpeakers = on
        speakerRequestFailed = false
        save()
        if on {
            if health == nil, deps.server() != nil { Task { await refreshHealth() } } else { fetchSpeakerModelIfNeeded() }
        } else {
            speakerPoll?.cancel(); speakerPoll = nil
        }
    }

    /// The status line's Retry: fetch again (a damaged model is dropped first).
    func retrySpeakerModel() {
        guard labelSpeakers else { return }
        speakerRequestFailed = false
        let damaged = health?.speakersModel?.state == .ready
        requestSpeakerModel(damaged ? [.remove, .download] : [.download])
    }

    /// Labels on and the Mac has no model: ask it for its one pinned download, without a prompt. Recording never waits for
    /// it; labels start with the first segment after the model is ready. One try per failure, then Retry.
    private func fetchSpeakerModelIfNeeded() {
        guard labelSpeakers, speakersAvailable, health?.speakersModel?.state == .notDownloaded,
              speakerRequest == nil, !speakerRequestFailed else { return }
        requestSpeakerModel([.download])
    }

    private func requestSpeakerModel(_ actions: [SpeakersModelAction]) {
        guard let config = deps.server() else { return }
        let http = deps.http, request = deps.speakersModel
        speakerRequest = Task { [weak self] in
            var failed = false
            do { for action in actions { _ = try await request(config, http, action) } } catch { failed = true }
            guard let self else { return }
            self.speakerRequestFailed = failed
            await self.refreshHealth()
            self.speakerRequest = nil
        }
    }

    /// Rename a person everywhere in the note; `replaceInNotes` also swaps their old name in the notes' text.
    @Published private(set) var recentSpeakerNames: [String] = []
    @Published private(set) var dismissedSpeakerLines: Set<UUID> = []
    var showsNameSpeakersLine: Bool {
        !state.isActive && !dismissedSpeakerLines.contains(document.id) && !document.unnamedSpeakers.isEmpty
    }
    func dismissSpeakerLine() { dismissedSpeakerLines.insert(document.id) }
    func nameSpeakers(_ draft: SpeakerNamesDraft) {
        for (id, raw) in draft.names where draft.merges[id] == nil {
            selected.voices.name(id, name: SpeakerFixups.cleanName(raw), remember: rememberVoices && draft.remember[id] != false)
        }
        fixSpeakers { draft.apply(to: &$0) }
        rememberPending(in: selected)
        dismissSpeakerLine()
    }
    func loadRecentSpeakerNames() async {
        let id = document.id
        var names: [String] = []
        for entry in entries.prefix(30) where entry.id != id {
            if let note = try? await library?.record(entry.id) { names += note.document.namedSpeakers }
        }
        guard document.id == id else { return }
        recentSpeakerNames = SpeakerNameSuggestions.names(saved: [], recent: names, matching: "", limit: 120)
    }

    func renameSpeaker(_ person: Int, to name: String, replaceInNotes: Bool, remember: Bool = true) {
        let id = document.roster.resolve(person)
        selected.voices.name(id, name: SpeakerFixups.cleanName(name), remember: rememberVoices && remember)
        fixSpeakers { SpeakerFixups.rename(person, to: name, replaceInNotes: replaceInNotes, in: &$0) }
        rememberPending(in: selected)
    }
    /// "This turn is": one transcript turn goes to `person` (nil: a new person). The turn is marked as the user's, so
    /// later labels and a re-transcribe keep it, and the transcript, export and structuring use that person.
    func reassignTurn(segment: Int, turn: Int, to person: Int?) {
        guard !isRetranscribing else { return }
        fixSpeakers { $0.reassignTurns([SpeakerTurnRef(segment: segment, index: turn)], to: person); return [] }
    }
    func mergeSpeaker(_ person: Int, into target: Int) { fixSpeakers { $0.mergeSpeaker(person, into: target); return [] } }
    func separateSpeaker(_ person: Int) { fixSpeakers { $0.separateSpeaker(person); return [] } }

    private func fixSpeakers(_ body: (inout NotesDocument) -> [NotesTextChange]) {
        let context = selected!
        context.recorder.editSpeakers(body)
        sync(context)
        context.journal?.flush()
    }

    func dismissUpgradeNotice() { preferences.libraryUpgradeNotice = false; save() }
    private func save() {
        do { try deps.store?.save(preferences) } catch { notice = SessionFailure.storage.localizedDescription }
        for context in sessions.values { configure(context) }
    }

    /// Where structuring sends text, for the disclosure line.
    var structureDisclosure: String {
        guard let health else { return "Chirp checks your computer when you record." }
        guard health.correctionAvailable else { return "Clean-up is off on your computer, so notes stay a transcript." }
        if health.notesStructure != true { return "Chirp on your computer is too old to structure notes. Update it." }
        if health.correctionLeavesMachine == false { return "Structuring runs on your computer." }
        if let host = health.correctionHost, !host.isEmpty { return "Structuring sends the transcript to \(host). Audio stays on your computer." }
        return "The structuring destination is unknown, so structuring is off."
    }
    var structureCanEnable: Bool {
        guard let health, health.correctionAvailable, health.notesStructure == true else { return false }
        return health.correctionLeavesMachine == false || health.correctionHost?.isEmpty == false
    }

    func refreshHealth() async {
        guard let config = deps.server() else { health = nil; configure(); return }
        serverBox.config = config
        guard let fresh = try? await deps.fetchHealth(config, deps.http), fresh.ok else { return }
        health = fresh
        await refreshSavedVoices()
        for context in sessions.values { context.recorder.serverAvailable(); configure(context) }
        fetchSpeakerModelIfNeeded()
        pollSpeakerModel()
    }

    /// The Mac fetching its speaker model: look again shortly, until it is ready or failed.
    private func pollSpeakerModel() {
        guard labelSpeakers, health?.speakersModel?.state == .downloading, speakerPoll == nil else { return }
        speakerPoll = Task { [weak self] in
            guard let self else { return }
            await self.deps.sleep(.seconds(3))
            self.speakerPoll = nil
            guard !Task.isCancelled else { return }
            await self.refreshHealth()
        }
    }

    /// The `start` options and the structuring switch for this server (the Mac's hidden `live_notes` style when it has one).
    private func configure(_ context: NoteSession? = nil) {
        let recorder = (context ?? selected!).recorder
        let h = health
        recorder.options = notesStartOptions(health: h)
        recorder.serverHost = deps.server()?.host ?? ""
        recorder.labelSpeakers = preferences.speakerLabelsOn && SpeakerNotice.available(h)
        recorder.configureStructuring(enabled: preferences.structureEnabled(health: h), health: h)
    }

    /// The `start` options for Notes audio on this server: its clean-up setting, in the hidden `live_notes` style when
    /// the server has one.
    func notesStartOptions(health h: Health?) -> StartOptions {
        let correction = h.map(deps.correctionAllowed) ?? false
        return h?.notesCorrection == true
            ? StartOptions(client: "ios", correction: correction, correctionProfile: CorrectionProfile.liveNotesID, wordTimings: true)
            : StartOptions(client: "ios", correction: correction, correctionProfile: CorrectionProfile.defaultID, wordTimings: true)
    }

    // MARK: app lifecycle

    private func observeApp() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setBackground(true) }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setBackground(false) }
        })
    }

    /// Locked or behind another app. With battery saver the screen is not updated meanwhile; the recorder, the journal and
    /// the Live Activity's state go on.
    func setBackground(_ value: Bool) {
        guard value != background else { return }
        background = value
        retranscribeBackground(value)
        if !value {
            captureRecorder?.serverAvailable()
            Task { await loadLibrary(); await refreshHealth(); await settleJournal() }
        }
        sync()
        if value { Task { await settleJournal() } }
    }

    private var quiet: Bool { background && preferences.batterySaver }

    // MARK: sync

    func sync() { sync(selected) }

    private func sync(_ context: NoteSession) {
        let recorder = context.recorder
        let changes = recorder.takePendingChanges()
        context.snaps.record(changes, from: context.textBefore, result: recorder.document.text, at: Date())
        context.textBefore = recorder.document.text
        let state = recorder.state
        let leftCapture = state != context.lastState && !state.isCapturing
        if recorder.document.id == recordingID {
            if state != context.lastState {
                if !state.isCapturing { deps.audio.stop() }
                if state != .paused { pausedForInterruption = false }
            }
            recordingElapsed = recorder.elapsed
            if recordingPreview.isEmpty { recordingPreview = recorder.document.snippet() }
            updateActivity()
            if !state.isActive { recordingID = nil; library?.setRecordingNote(nil) }
        }
        context.lastState = state
        context.journal?.update(recorder.document, elapsed: recorder.elapsed,
            urgent: !changes.isEmpty || leftCapture, recording: state.isActive)
        setTicking(captureRecorder?.state.isCapturing == true && !quiet)
        if quiet { skippedUpdates += 1; return }
        if context === selected { publish() }
    }

    private func publish() {
        state = recorder.state
        document = recorder.document
        structuring = recorder.structuring
        reorganize = recorder.reorganizeStatus
        connection = recorder.connection
        elapsed = recorder.elapsed
        pauseReason = recorder.pauseReason
        debugRetention = recorder.debugRetention || health?.debugRetention == true
        snapshots = snaps
    }

    private func setTicking(_ on: Bool) {
        guard on != (stopTick != nil) else { return }
        stopTick?(); stopTick = nil
        guard on else { return }
        stopTick = deps.startTicker { [weak self] in
            guard let self, !self.quiet else { return }
            self.recordingElapsed = self.captureRecorder?.elapsed ?? 0
            self.elapsed = self.recorder.elapsed
            self.connection = self.recorder.connection
        }
    }

    // MARK: Live Activity

    private var activityState: ChirpNotesActivityAttributes.ContentState? {
        guard let recorder = captureRecorder else { return nil }
        let status: ChirpNotesActivityAttributes.Status
        switch recorder.state {
        case .starting, .recording:
            if case .offline = recorder.connection { status = .offline } else { status = .recording }
        case .paused: status = .paused
        case .stopping: status = .finishing
        default: return nil
        }
        let elapsed = recorder.elapsed
        // Whole seconds, so an update with the same state does not move the start date by a fraction.
        let started = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - elapsed).rounded())
        return .init(status: status, startedAt: started, elapsed: elapsed.rounded(.down),
                     debugRetention: recorder.debugRetention || health?.debugRetention == true, title: String(recorder.document.title.prefix(60)))
    }

    private func beginActivity() {
        guard !activityLive, let state = activityState else { return }
        do {
            try deps.activity.begin(state)
            activityLive = true
            lastActivity = state
        } catch { notice = "Live Activities are off for Chirp, so the lock screen has no controls. Recording continues." }
    }

    /// The activity changes with the state only (status or debug banner), never per segment: the system counts the time.
    private func updateActivity() {
        guard activityLive else { return }
        guard let state = activityState else {
            activityLive = false; lastActivity = nil
            endingActivity = Task { await deps.activity.end() }
            return
        }
        guard state.status != lastActivity?.status || state.debugRetention != lastActivity?.debugRetention || state.title != lastActivity?.title else { return }
        lastActivity = state
        Task { await deps.activity.update(state) }
    }
}

extension LiveNotesController {
    /// The app's controller, built once on the coordinator's pairing and preferences.
    static func current(for coordinator: SessionCoordinator) -> LiveNotesController {
        if let instance { return instance }
        let made: LiveNotesController
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--chirp-ui-test") {
            made = .synthetic(coordinator: coordinator)
        } else {
            made = .production(coordinator: coordinator)
        }
        #else
        made = .production(coordinator: coordinator)
        #endif
        coordinator.otherCaptureActive = { [weak made] in made?.isActive ?? false }
        instance = made
        return made
    }

    private static func production(coordinator: SessionCoordinator) -> LiveNotesController {
        let config = SharedConfiguration(bundle: .main)
        var store: NotesStore?
        do { store = try NotesStore.production(secrets: KeychainSecretStore(accessGroup: config.keychainAccessGroup)) } catch {}
        var fetchVoices: @Sendable (ServerConfig, URLSession) async throws -> SavedVoices = { try await $0.savedVoices(session: $1) }
        var voiceAction: @Sendable (ServerConfig, URLSession, VoiceLibraryAction) async throws -> SavedVoices = { try await $0.savedVoices($2, session: $1) }
        var audio: any NotesAudio = NotesMicrophone()
        #if DEBUG
        if let file = SimulatorNotesAudio.fromArguments() { audio = file }
        #endif
        var deps = Dependencies(
            server: { [weak coordinator] in coordinator?.services.flatMap { try? $0.pairing.load() } },
            correctionAllowed: { [weak coordinator] in coordinator?.preferences.permitsCorrection(health: $0) ?? false },
            otherCaptureActive: { [weak coordinator] in coordinator?.armed ?? false },
            http: SafeHTTPSession.make(), audio: audio,
            requestPermission: { await AVAudioApplication.requestRecordPermission() },
            activity: .system, store: store)
        deps.retranscribeStream = { config, options, http in
            var limits = StreamLimits()
            limits.readyDeadline = NotesRetranscriber.readyDeadline
            return StreamSession(config: config, options: options, urlSession: http, limits: limits)
        }
        let made = LiveNotesController(deps)
        if store == nil { made.notice = "Protected storage unavailable, so notes cannot be kept on this device." }
        return made
    }
}
