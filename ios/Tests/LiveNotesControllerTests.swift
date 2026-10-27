import AppIntents
import ChirpCore
import ChirpIOSCore
import Foundation
import Testing
@testable import ChirpIOS

@Suite("Live Notes", .serialized)
@MainActor
struct LiveNotesControllerTests {
    final class Values {
        var activity: [String] = []
        var copied: [String] = []
        var otherCapture = false
        var permission = true
        var activityEnabled = true
        var backgroundTasks = 0
        var backgroundEnded = 0
        /// Every socket the recorder opened, oldest first (their `sent` messages are the `start`s).
        var transports: [SyntheticTransport] = []
        let speakerCalls = SpeakerCalls()
        var speakerRequests: [SpeakersModelAction] { speakerCalls.actions }
        /// Every spoken-edit instruction the server was asked to apply, oldest first.
        let editCalls = EditCalls()
        var starts: [String] {
            transports.flatMap { $0.sent }.compactMap { if case .string(let text) = $0, text.contains(#""type":"start""#) { text } else { nil } }
        }
    }
    /// The model requests the controller made (its closure is `@Sendable`, so the record needs a lock).
    final class SpeakerCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [SpeakersModelAction] = []
        private var failing = false
        var actions: [SpeakersModelAction] { lock.withLock { list } }
        /// Makes the Mac unreachable for the next requests (they are still recorded).
        var fail: Bool { get { lock.withLock { failing } } set { lock.withLock { failing = newValue } } }
        func add(_ action: SpeakersModelAction) { lock.withLock { list.append(action) } }
    }
    /// The spoken-edit requests the controller made (same locking reason as `SpeakerCalls`).
    final class EditCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [NotesEditRequest] = []
        var requests: [NotesEditRequest] { lock.withLock { list } }
        func add(_ request: NotesEditRequest) { lock.withLock { list.append(request) } }
    }
    @MainActor struct Fixture {
        let notes: LiveNotesController
        let audio: SyntheticNotesAudio
        let values: Values
        let store: NotesStore
        let root: URL
        func clean() { notes.shutdown(); audio.stop(); try? FileManager.default.removeItem(at: root) }
        /// Journal files on disk (polling `recoverable()` would delete a write's temp file mid-write).
        var journalFiles: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: store.recoveryDirectory.path)) ?? []).filter { $0.hasSuffix(".json") }
        }
    }

    func fixture(root: URL? = nil, paired: Bool = true, voiceLibrary: TestVoiceLibrary? = nil, voiceMatches: [ServerVoiceMatch] = [], secrets: MemorySecretStore = MemorySecretStore(), health: Health = LiveNotesController.syntheticHealth,
                 reorganize: @escaping @Sendable (NotesReorganizeRequest) async throws -> NotesReorganizeResponse = { LiveNotesController.syntheticReorganize($0) },
                 structure: @escaping @Sendable (NotesStructureRequest) async throws -> NotesStructureResponse = { LiveNotesController.syntheticStructure($0) },
                 edit: @escaping @Sendable (NotesEditRequest) async throws -> NotesEditResponse = { LiveNotesController.syntheticEdit($0) },
                 retranscribe: (() -> SyntheticTransport)? = nil) throws -> Fixture {
        let root = root ?? FileManager.default.temporaryDirectory.appendingPathComponent("chirp-notes-unit-" + UUID().uuidString)
        let store = try NotesStore(root: root, secrets: secrets)
        let values = Values(), audio = SyntheticNotesAudio()
        var deps = LiveNotesController.Dependencies(
            server: { paired ? ServerConfig(baseURL: URL(string: "https://synthetic.test.ts.net/chirp")!, token: "synthetic-only") : nil },
            correctionAllowed: { _ in true },
            otherCaptureActive: { values.otherCapture },
            http: URLSession(configuration: .ephemeral),
            fetchHealth: { _, _ in health },
            makeStream: { _, options, _ in
                let transport = SyntheticTransport(automatic: true, voiceMatches: { voiceMatches })
                values.transports.append(transport)
                return StreamSession(transport: transport, options: options)
            },
            structure: { _, _, request, _ in try await structure(request) },
            reorganize: { _, _, request, _ in try await reorganize(request) },
            editNotes: { [calls = values.editCalls] _, _, request, _ in
                calls.add(request)
                return try await edit(request)
            },
            speakersModel: { [calls = values.speakerCalls] _, _, action in
                calls.add(action)
                if calls.fail { throw URLError(.cannotConnectToHost) }
                return SpeakersModel(state: .downloading)
            },
            fetchVoices: { _, _ in guard let voiceLibrary else { throw VoiceLibraryError.unsupported }; return await voiceLibrary.read() },
            voiceAction: { _, _, action in guard let voiceLibrary else { throw VoiceLibraryError.unsupported }; return try await voiceLibrary.perform(action) },
            audio: audio, requestPermission: { values.permission },
            activity: NotesActivityControl(begin: { state in
                guard values.activityEnabled else { throw NotesLiveActivity.Unavailable.disabled }
                values.activity.append("begin:" + state.status.rawValue)
            }, update: { values.activity.append("update:" + $0.status.rawValue) }, end: { values.activity.append("end") }),
            store: store, copyText: { values.copied.append($0) }, startTicker: { _ in {} },
            backgroundTask: { _ in values.backgroundTasks += 1; return { values.backgroundEnded += 1 } }, observeLifecycle: false)
        if let retranscribe {
            deps.retranscribeStream = { _, options, _ in
                let transport = retranscribe()
                values.transports.append(transport)
                return StreamSession(transport: transport, options: options)
            }
        }
        return Fixture(notes: LiveNotesController(deps), audio: audio, values: values, store: store, root: root)
    }

    func eventually(_ what: Comment, timeout: Duration = .seconds(5), _ check: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if check() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(check(), what)
    }

    @Test func recordsPausesResumesAndStopsWithTheLiveActivityFollowing() async throws {
        let f = try fixture(); defer { f.clean() }
        await f.notes.record()
        try await eventually("recording") { f.notes.state == .recording }
        #expect(f.audio.isRunning && f.audio.starts == 1)
        #expect(f.values.activity == ["begin:recording"])
        try await eventually("partial") { f.notes.document.livePartial == "synthetic words" }

        await f.notes.pause()
        #expect(f.notes.state == .paused && !f.audio.isRunning)
        try await eventually("segment committed while paused") { f.notes.document.segments.count == 1 }
        try await eventually("structured") { f.notes.document.text.contains("## Synthetic notes") }
        #expect(f.notes.document.text.contains("Synthetic words."))
        try await eventually("activity paused") { f.values.activity.last == "update:paused" }

        await f.notes.resume()
        try await eventually("recording again") { f.notes.state == .recording }
        #expect(f.audio.starts == 2)
        try await eventually("activity recording") { f.values.activity.last == "update:recording" }

        await f.notes.stop()
        try await eventually("stopped") { f.notes.state == .stopped }
        #expect(!f.audio.isRunning && f.values.backgroundTasks == 1)
        try await eventually("activity ended") { f.values.activity.last == "end" }
        #expect(f.values.activity.contains("update:finishing"))
        #expect(f.notes.document.segments.count == 2)
        #expect(f.notes.document.transcriptParagraphs.first?.text(raw: true) == "synthetic words")
        f.notes.copy()
        #expect(f.values.copied.first?.contains("Synthetic words.") == true)
    }

    @Test func notesAndAKeyboardSessionNeverShareTheMicrophone() async throws {
        let f = try fixture(); defer { f.clean() }
        f.values.otherCapture = true
        await f.notes.record()
        #expect(f.notes.state == .idle && !f.audio.isRunning && f.notes.notice.contains("keyboard session"))
        f.values.otherCapture = false
        await f.notes.record()
        try await eventually("recording") { f.notes.state == .recording }
        let coordinator = SessionCoordinator(audio: SyntheticAudio(), production: false)
        coordinator.otherCaptureActive = { f.notes.isActive }
        await #expect(throws: SessionFailure.notesRecording) { try await coordinator.armSession() }
    }

    @Test func microphoneDeniedOrLiveActivitiesOff() async throws {
        let f = try fixture(); defer { f.clean() }
        f.values.permission = false
        await f.notes.record()
        #expect(f.notes.state == .idle && f.notes.notice == SessionFailure.permission.localizedDescription)
        f.values.permission = true; f.values.activityEnabled = false
        await f.notes.record()
        try await eventually("recording without a Live Activity") { f.notes.state == .recording }
        #expect(f.notes.notice.contains("Live Activities are off"))
    }

    @Test func batterySaverSkipsScreenUpdatesWhileLockedButNotTheWork() async throws {
        let f = try fixture(); defer { f.clean() }
        await f.notes.record()
        try await eventually("recording") { f.notes.state == .recording }
        f.notes.setBackground(true)
        await f.notes.pause()
        try await eventually("segment committed in the recorder") { f.notes.recorder.document.segments.count == 1 }
        #expect(f.notes.state == .recording, "the screen state is not updated while locked")
        #expect(f.notes.document.segments.isEmpty && f.notes.skippedUpdates > 0)
        try await eventually("the Live Activity still follows the state") { f.values.activity.last == "update:paused" }
        f.notes.setBackground(false)
        #expect(f.notes.state == .paused && f.notes.document.segments.count == 1)

        f.notes.setBatterySaver(false)
        f.notes.setBackground(true)
        await f.notes.resume()
        try await eventually("published while in the background without battery saver") { f.notes.state == .recording }
    }

    @Test func aCallPausesAndResumesWhenIOSSaysSo() async throws {
        let f = try fixture(); defer { f.clean() }
        await f.notes.record()
        try await eventually("recording") { f.notes.state == .recording }
        f.audio.event?(.interrupted)
        try await eventually("paused") { f.notes.state == .paused }
        #expect(f.notes.pauseReason == LiveNotesController.interruptedReason && !f.audio.isRunning)
        f.audio.event?(.resumable)
        try await eventually("resumed") { f.notes.state == .recording }
        #expect(f.audio.starts == 2)
        // A user pause is never resumed by iOS.
        await f.notes.pause()
        f.audio.event?(.resumable)
        try await Task.sleep(for: .milliseconds(100))
        #expect(f.notes.state == .paused)
    }

    @Test func organizeAndUndoOrganize() async throws {
        let f = try fixture(); defer { f.clean() }
        await f.notes.record()
        try await eventually("recording") { f.notes.state == .recording }
        await f.notes.stop()
        try await eventually("structured and stopped") { f.notes.state == .stopped && f.notes.document.text.contains("Synthetic words.") }
        let typed = f.notes.document.text + "\n- Apples go on the list before the spring fair opens on the village green"
        f.notes.edit(typed)
        #expect(f.notes.document.text == typed)
        f.notes.organize()
        try await eventually("organized", timeout: .seconds(10)) { f.notes.canUndoOrganize }
        #expect(f.notes.document.text != typed)
        #expect(f.notes.undoOrganize())
        #expect(f.notes.document.text == typed && !f.notes.canUndoOrganize)
    }

    @Test func stoppedNotesPersistAcrossRelaunchAndExportDoesNotDeleteThem() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-notes-unit-" + UUID().uuidString)
        let secrets = MemorySecretStore()
        let first = try fixture(root: root, secrets: secrets)
        await first.notes.record()
        try await eventually("recording") { first.notes.state == .recording }
        await first.notes.stop()
        await first.notes.settleJournal()
        let id = first.notes.document.id, text = first.notes.document.text
        #expect(first.notes.entries.map(\.id) == [id])
        first.notes.didExport()
        await first.notes.settleJournal()
        first.notes.recorder.cancel(); first.audio.stop()

        let second = try fixture(root: root, secrets: secrets); defer { second.clean() }
        await second.notes.ready()
        #expect(second.notes.entries.map(\.id) == [id])
        await second.notes.open(id)
        #expect(second.notes.document.text == text && second.notes.state == .stopped)
        #expect(second.notes.entries.first?.recovered == false)
    }

    @Test func explicitOptOutStopsNewWritesAndCanBeEnabledAgain() async throws {
        let f = try fixture(); defer { f.clean() }
        await f.notes.ready()
        f.notes.setKeepNotes(false)
        f.notes.edit("A private transient thought")
        await f.notes.settleJournal()
        #expect(f.notes.entries.isEmpty)
        #expect(try f.store.loadPreferences().keepNotes == false)
        f.notes.setKeepNotes(true)
        await f.notes.settleJournal()
        #expect(f.notes.entries.count == 1)
    }

    @Test func browsingKeepsRecordingPinnedAndContinueAppendsABoundary() async throws {
        let f = try fixture(); defer { f.clean() }
        await f.notes.ready()
        f.notes.edit("## Older note\n- [ ] Review")
        await f.notes.settleJournal()
        let older = f.notes.document.id
        await f.notes.newRecording()
        try await eventually("recording") { f.notes.state == .recording }
        let active = f.notes.document.id
        await f.notes.open(older)
        #expect(f.notes.document.id == older && f.notes.recordingID == active && f.notes.isActive)
        #expect(f.audio.isRunning)
        await f.notes.delete([active])
        #expect(f.notes.entries.contains { $0.id == active })
        await f.notes.stop()
        #expect(!f.notes.isActive && f.notes.document.id == older)
        await f.notes.open(active)
        let elapsed = f.notes.elapsed
        await f.notes.record()
        try await eventually("continued") { f.notes.state == .recording }
        #expect(f.notes.document.sessions.count == 2)
        #expect(f.notes.document.sessions.last?.offset == elapsed)
        await f.notes.stop()
        await f.notes.delete([older])
        #expect(f.notes.recentlyDeleted.map(\.id) == [older])
        await f.notes.restore([older])
        #expect(f.notes.entries.contains { $0.id == older })
    }

    @Test func explicitHistoryHandoffCreatesOrAppendsWithoutMovingTheRecording() async throws {
        let f = try fixture(); defer { f.clean() }
        await f.notes.record()
        try await eventually("recording") { f.notes.state == .recording }
        let active = f.notes.document.id
        let destination = try #require(await f.notes.addToNote("A thought from dictation"))
        #expect(destination != active && f.notes.recordingID == active && f.audio.isRunning)
        #expect(f.notes.requestedSelection == destination)
        #expect(await f.notes.addToNote("A second thought", id: destination) == destination)
        #expect(f.notes.document.text == "A thought from dictation\n\nA second thought")
        #expect(try await f.store.libraryStore.record(destination).document.text == f.notes.document.text)
        #expect(await f.notes.addToNote("  ") == nil)
        await f.notes.stop()
    }

    /// New note (A2-7): a typed note with no computer, kept once typed in; a blank one is never kept.
    @Test func newNoteTypesWithoutAComputerAndIsKeptOnceTyped() async throws {
        let f = try fixture(paired: false); defer { f.clean() }
        await f.notes.newNote()
        let id = f.notes.document.id
        #expect(NoteMeta.displayTitle(f.notes.document) == "Untitled note")
        #expect(f.notes.takeEditRequest(id) && !f.notes.takeEditRequest(id), "the editor opens once")
        await f.notes.settleJournal()
        #expect(f.notes.entries.isEmpty, "a blank note is not kept")
        f.notes.edit("Shopping\n- [ ] Bread")
        await f.notes.settleJournal()
        #expect(f.notes.entries.map(\.id) == [id])
        #expect(try await f.store.libraryStore.record(id).document.text == "Shopping\n- [ ] Bread")
        #expect(f.values.transports.isEmpty && !f.audio.isRunning, "no stream and no microphone")
    }

    @Test func newNoteNeverStopsARecording() async throws {
        let f = try fixture(); defer { f.clean() }
        await f.notes.record()
        try await eventually("recording") { f.notes.state == .recording }
        let active = f.notes.document.id
        await f.notes.newNote()
        #expect(f.notes.document.id != active && f.notes.state == .idle)
        #expect(f.notes.recordingID == active && f.audio.isRunning && f.notes.isActive)
        f.notes.edit("Typed while it records")
        await f.notes.settleJournal()
        #expect(f.notes.entries.contains { $0.id == f.notes.document.id })
        await f.notes.stop()
        #expect(f.notes.document.text == "Typed while it records")
    }

    actor OrganizeGate {
        private var continuation: CheckedContinuation<NotesReorganizeResponse, Never>?
        private var released = false
        private var response: NotesReorganizeResponse { NotesReorganizeResponse(markdown: "## Organized original\n- First note only", reorganized: true, changed: true) }
        func respond(_ request: NotesReorganizeRequest) async -> NotesReorganizeResponse {
            if released { return response }
            return await withCheckedContinuation { continuation = $0 }
        }
        func release() {
            released = true
            continuation?.resume(returning: response)
            continuation = nil
        }
    }

    @Test func lateOrganizeUpdatesItsOriginalNoteWhileAnotherIsOpen() async throws {
        let gate = OrganizeGate()
        let f = try fixture(reorganize: { await gate.respond($0) }); defer { f.clean() }
        await f.notes.ready()
        await f.notes.refreshHealth()
        f.notes.setAutoReorganize(false)
        f.notes.edit("## Original\n- We reviewed the next quarter budget and agreed to send the updated contract on Thursday.")
        await f.notes.settleJournal()
        let original = f.notes.document.id
        let originalRecorder = f.notes.recorder
        f.notes.organize()
        try await eventually("organize pending") { f.notes.reorganize.isRunning }
        f.notes.newNotes()
        f.notes.edit("## Other\n- Keep exactly these words")
        let other = f.notes.document
        await gate.release()
        try await eventually("original organize finished") { !originalRecorder.reorganizeStatus.isRunning }
        await f.notes.settleJournal()
        #expect(f.notes.document.id == other.id && f.notes.document.text == other.text)
        #expect(try await f.store.libraryStore.record(original).document.text.contains("Organized original"))
    }

    actor StructureGate {
        private var continuation: CheckedContinuation<NotesStructureResponse, Never>?
        private var released = false
        private var response: NotesStructureResponse { NotesStructureResponse(markdown: "## Structured original\n- Original recording only", structured: true) }
        func respond(_ request: NotesStructureRequest) async -> NotesStructureResponse {
            if released { return response }
            return await withCheckedContinuation { continuation = $0 }
        }
        func release() { released = true; continuation?.resume(returning: response); continuation = nil }
    }

    @Test func lateStructureUpdatesThePausedRecordingWhileAnotherNoteIsEdited() async throws {
        let gate = StructureGate()
        let f = try fixture(structure: { await gate.respond($0) }); defer { f.clean() }
        await f.notes.record()
        try await eventually("recording") { f.notes.state == .recording }
        let original = f.notes.recorder, id = f.notes.document.id
        await f.notes.pause()
        try await eventually("structure pending") { original.structuring == .running }
        f.notes.newNotes()
        f.notes.edit("## Another thought\n- Keep this note unchanged")
        let other = f.notes.document
        await gate.release()
        try await eventually("original structured") { original.document.text.contains("Structured original") }
        await f.notes.settleJournal()
        #expect(f.notes.document == other)
        #expect(f.notes.recordingID == id && f.notes.isActive)
        #expect(try await f.store.libraryStore.record(id).document.text.contains("Original recording only"))
        await f.notes.stop()
    }

    @Test func audioIsOptInAndStoredAfterItsSegment() async throws {
        let f = try fixture(); defer { f.clean() }
        await f.notes.record()
        try await eventually("recording") { f.notes.state == .recording }
        await f.notes.stop()
        #expect(f.notes.totalAudioBytes == 0)
        f.notes.setKeepAudio(true)
        await f.notes.record()
        try await eventually("recording again") { f.notes.state == .recording }
        try await Task.sleep(for: .milliseconds(250))
        await f.notes.stop()
        await f.notes.settleJournal()
        #expect(f.notes.totalAudioBytes > 0)
        let record = try await f.store.libraryStore.record(f.notes.document.id)
        let reference = try #require(record.document.audio.first)
        #expect(reference.id == 1)
        #expect(try await f.notes.audioData(segment: reference.id)?.isEmpty == false)
        await f.notes.deleteAudio()
        #expect(f.notes.totalAudioBytes == 0 && !f.notes.document.text.isEmpty)
    }

    @Test func structuringNeedsConsentForAnOffMacDestination() async throws {
        let remote = Health(engine: "e", ready: true, correction: "available", correctionLeavesMachine: true,
                            correctionHost: "api.example.test", notesStructure: true, notesReorganize: true)
        let f = try fixture(health: remote); defer { f.clean() }
        await f.notes.refreshHealth()
        #expect(f.notes.structuring == .off(.disabled))
        #expect(f.notes.structureDisclosure.contains("api.example.test"))
        f.notes.setStructure(true)
        #expect(f.notes.preferences.structureConsentHost == "api.example.test")
        #expect(f.notes.structuring == .idle)
    }

    @Test func notesShortcutsArePublishedAlongsideDictation() {
        #expect(ChirpShortcuts.appShortcuts.count == 8)
        #expect(String(localized: StartChirpNotesIntent.title) == "Record note with Chirp")
        #expect(String(localized: PauseChirpNotesIntent.title) == "Pause or resume note with Chirp")
        #expect(String(localized: StopChirpNotesIntent.title) == "Stop note with Chirp")
        #expect(StartChirpNotesIntent.openAppWhenRun)
    }

    @Test func notesShortcutTableMatchesCurrentBindings() {
        #expect(ShortcutsPage.notesShortcuts.map(\.title) == [
            "New note", "Record / Stop note", "Pause / Resume note", "Edit by voice", "Search notes", "Show or hide transcript",
        ])
        #expect(ShortcutsPage.notesShortcuts.map(\.keys) == ["⌘N", "⇧⌘R", "⇧⌘P", "⇧⌘E", "⌘F", "⌥⌘T"])
    }

    @Test func notesIntentActionsActOnlyOnALiveSession() async throws {
        let f = try fixture(); defer { f.clean() }
        #expect(await f.notes.perform(StopChirpNotesIntent.action) == "Live Notes is not recording.")
        #expect(await f.notes.perform(PauseChirpNotesIntent.action) == "Live Notes is not recording.")
        #expect(!f.audio.isRunning)
        #expect(await f.notes.perform(StartChirpNotesIntent.action) == "Recording notes.")
        try await eventually("recording") { f.notes.state == .recording }
        let starts = f.audio.starts
        #expect(await f.notes.perform(StartChirpNotesIntent.action) == "Recording notes.")
        #expect(f.audio.starts == starts)
        #expect(await f.notes.perform(PauseChirpNotesIntent.action) == "Live Notes paused. Microphone off.")
        #expect(!f.audio.isRunning)
        #expect(await f.notes.perform(PauseChirpNotesIntent.action) == "Live Notes recording.")
        #expect(f.audio.isRunning)
        #expect(await f.notes.perform(StopChirpNotesIntent.action) == "Live Notes stopped. Your notes are in Chirp.")
        #expect(!f.audio.isRunning)
        #expect(await f.notes.perform(StopChirpNotesIntent.action) == "Live Notes is not recording.")
    }

    // MARK: speaker labels (#201)

    private func speakerHealth(_ state: SpeakersModel.State?, speakers: Bool = true) -> Health {
        var h = LiveNotesController.syntheticHealth
        h.notesSpeakers = speakers ? true : nil
        h.speakersModel = state.map { SpeakersModel(state: $0) }
        return h
    }

    @Test func speakerLabelsAreOnByDefaultWithoutAnyPromptOrStoredChoice() async throws {
        let f = try fixture(health: speakerHealth(.ready)); defer { f.clean() }
        await f.notes.refreshHealth()
        #expect(f.notes.labelSpeakers && f.notes.speakersAvailable && f.notes.recorder.labelSpeakers)
        #expect(f.notes.speakerStatus == nil && f.values.speakerRequests.isEmpty)
        await f.notes.record()
        try await eventually("recording") { f.notes.state == .recording }
        await f.notes.stop()
        #expect(!f.values.starts.isEmpty && f.values.starts.allSatisfy { $0.contains(#""speakers":{"session":""#) })
        try await eventually("labelled segment") { f.notes.document.segments.contains { $0.turns?.count == 2 } }
        // Nothing but the user's own choice is ever stored.
        #expect(try f.store.loadPreferences().labelSpeakers == nil)
    }

    @Test func aMissingModelIsFetchedWithoutAskingAndNeverSwitchesTheChoiceOff() async throws {
        let f = try fixture(health: speakerHealth(.notDownloaded)); defer { f.clean() }
        await f.notes.refreshHealth()
        try await eventually("download requested") { f.values.speakerRequests == [.download] }
        try await eventually("settled") { f.notes.speakerStatus == .preparing(size: nil) }
        #expect(f.notes.labelSpeakers && f.notes.recorder.labelSpeakers && !f.notes.speakerRequestFailed)
        #expect(f.notes.speakerStatus?.text == "Getting the speaker model ready (once)…")
        #expect(try f.store.loadPreferences().labelSpeakers == nil)
        // Recording starts at once; the labels apply once the Mac has the model.
        await f.notes.record()
        try await eventually("recording") { f.notes.state == .recording }
        await f.notes.stop()
        #expect(f.values.speakerRequests.allSatisfy { $0 == .download })
        #expect(!f.notes.document.segments.isEmpty)
    }

    @Test func aFailedFetchShowsRetryOnceAndRetryAsksAgain() async throws {
        let f = try fixture(health: speakerHealth(.notDownloaded)); defer { f.clean() }
        f.values.speakerCalls.fail = true
        await f.notes.refreshHealth()
        try await eventually("request failed") { f.notes.speakerStatus == .failed }
        let tries = f.values.speakerRequests.count
        await f.notes.refreshHealth()
        #expect(f.values.speakerRequests.count == tries)   // one try per failure, never a loop
        #expect(f.notes.speakerStatus?.canRetry == true && f.notes.labelSpeakers)
        f.values.speakerCalls.fail = false
        f.notes.retrySpeakerModel()
        try await eventually("retried") { f.values.speakerRequests.count == tries + 1 && f.notes.speakerStatus == .preparing(size: nil) }
        #expect(f.values.speakerRequests.last == .download)
    }

    @Test func turnOffIsTheOnlyWriterAndKeepsLabelsOffFromThenOn() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chirp-notes-unit-" + UUID().uuidString)
        let secrets = MemorySecretStore()
        let f = try fixture(root: root, secrets: secrets, health: speakerHealth(.notDownloaded)); defer { f.clean() }
        await f.notes.refreshHealth()
        try await eventually("download requested") { f.values.speakerRequests == [.download] }
        f.notes.setLabelSpeakers(false)
        #expect(!f.notes.labelSpeakers && !f.notes.recorder.labelSpeakers && f.notes.speakerStatus == nil)
        #expect(try f.store.loadPreferences().labelSpeakers == false)
        await f.notes.refreshHealth()
        #expect(f.values.speakerRequests == [.download])   // off asks for nothing more
        await f.notes.record()
        try await eventually("recording") { f.notes.state == .recording }
        await f.notes.stop()
        #expect(f.values.starts.allSatisfy { !$0.contains("speakers") })
        // A fresh launch respects the explicit off, and turning it on again asks nothing of a Mac that has its model.
        let again = try fixture(root: root, secrets: secrets, health: speakerHealth(.ready)); defer { again.clean() }
        await again.notes.refreshHealth()
        #expect(!again.notes.labelSpeakers && !again.notes.recorder.labelSpeakers)
        again.notes.setLabelSpeakers(true)
        #expect(again.notes.labelSpeakers && again.notes.recorder.labelSpeakers && again.values.speakerRequests.isEmpty)
        #expect(try again.store.loadPreferences().labelSpeakers == true)
    }

    @Test func anOlderServerGetsNoStartSpeakersNoStatusAndNoDownloadRequest() async throws {
        let f = try fixture(health: speakerHealth(nil, speakers: false)); defer { f.clean() }
        await f.notes.refreshHealth()
        #expect(f.notes.labelSpeakers && !f.notes.speakersAvailable && !f.notes.recorder.labelSpeakers)
        #expect(f.notes.speakerStatus == nil && f.values.speakerRequests.isEmpty)   // no line, no nag, no request
        await f.notes.record()
        try await eventually("recording") { f.notes.state == .recording }
        await f.notes.stop()
        #expect(f.values.starts.allSatisfy { !$0.contains("speakers") })
    }

    @Test func labelledNotesKeepTwoPeopleThroughRenameMergeSeparateAndTheSealedLibrary() async throws {
        let f = try fixture(health: speakerHealth(.ready)); defer { f.clean() }
        await f.notes.refreshHealth()
        await f.notes.record()
        try await eventually("recording") { f.notes.state == .recording }
        await f.notes.stop()
        try await eventually("labelled segment") { f.notes.document.segments.contains { $0.turns?.count == 2 } }
        #expect(f.values.starts.allSatisfy { $0.contains(#""speakers":{"session":""#) })
        let document = f.notes.document, segment = try #require(document.segments.first { $0.turns != nil })
        #expect(segment.turns?.map(\.person) == [1, 2] && document.speakerCount == 2)
        try await eventually("structured with names") { f.notes.document.text.contains("Person 2: Second voice.") }

        f.notes.renameSpeaker(2, to: "Maya", replaceInNotes: true)
        #expect(f.notes.document.roster.displayName(2) == "Maya")
        #expect(f.notes.document.text.contains("Maya: Second voice.") && !f.notes.document.text.contains("Person 2"))
        #expect(f.notes.markdown.contains("Maya:"))

        f.notes.mergeSpeaker(2, into: 1)
        #expect(f.notes.document.roster.displayName(2) == "Person 1" && f.notes.document.speakerCount == 1)
        f.notes.separateSpeaker(2)
        #expect(f.notes.document.roster.displayName(2) == "Maya" && f.notes.document.speakerCount == 2)

        // Labels and names are inside the sealed note, and nothing but text is there.
        await f.notes.settleJournal()
        let stored = try await f.store.libraryStore.record(f.notes.document.id).document
        #expect(stored.segments.compactMap(\.turns) == f.notes.document.segments.compactMap(\.turns))
        #expect(stored.roster.displayName(2) == "Maya" && stored.roster.displayName(1) == "Person 1")
    }

    /// "This turn is" (A2-10): one turn moves, the person's other turns stay, and the override is sealed in the note.
    @Test func thisTurnIsMovesOneTurnToAPersonOrANewOne() async throws {
        let f = try fixture(health: speakerHealth(.ready)); defer { f.clean() }
        await f.notes.refreshHealth()
        await f.notes.record()
        try await eventually("recording") { f.notes.state == .recording }
        await f.notes.stop()
        try await eventually("labelled segment") { f.notes.document.segments.contains { $0.turns?.count == 2 } }
        let index = try #require(f.notes.document.segments.firstIndex { $0.turns?.count == 2 })
        f.notes.renameSpeaker(2, to: "Maya", replaceInNotes: false)

        f.notes.reassignTurn(segment: index, turn: 0, to: 2)
        var turns = try #require(f.notes.document.segments[index].turns)
        #expect(turns.map(\.person) == [2, 2] && turns[0].manual && !turns[1].manual)
        #expect(f.notes.document.roster.displayName(1) == "Person 1", "the rest of Person 1 is untouched")

        f.notes.reassignTurn(segment: index, turn: 1, to: nil)
        turns = try #require(f.notes.document.segments[index].turns)
        #expect(turns.map(\.person) == [2, 3] && turns[1].manual)
        #expect(f.notes.document.roster.displayName(3) == "Person 3")
        // The export and the next structuring pass read the effective person.
        #expect(f.notes.markdown.contains(" Maya:** ") && f.notes.markdown.contains(" Person 3:** "))
        #expect(f.notes.document.labelledText(f.notes.document.segments[index]).hasPrefix("Maya: "))

        await f.notes.settleJournal()
        let stored = try await f.store.libraryStore.record(f.notes.document.id).document
        #expect(stored.segments[index].turns == turns)

        // A turn that is not there changes nothing.
        f.notes.reassignTurn(segment: index, turn: 9, to: 1)
        #expect(f.notes.document.segments[index].turns == turns)
    }
}

/// Edit by voice (A2-4): the Command button's flow, on ChirpCore's `NotesVoiceEdit`.
extension LiveNotesControllerTests {
    /// Hold to edit: the command opens its own socket and the microphone (never the recorder's), what it heard shows,
    /// sending applies the instruction as one edit, and the chip's Undo puts the notes back.
    @Test func editByVoiceAppliesTheInstructionAndUndoPutsItBack() async throws {
        let f = try fixture(); defer { f.clean() }
        await f.notes.refreshHealth()
        f.notes.edit("One\n\n- [ ] Buy figs")
        await f.notes.settleJournal()
        #expect(f.notes.voiceEditAvailable)

        await f.notes.startVoiceEdit()
        try await eventually("listening") { f.notes.voiceEditListening }
        // The microphone opens once the command's own socket is open, a moment after "listening" shows.
        try await eventually("the command opens the microphone itself") { f.audio.isRunning && f.audio.starts == 1 }
        try await eventually("heard") { f.notes.voiceEditStatusText == "“synthetic words”" }

        f.notes.finishVoiceEdit()
        try await eventually("applied") { f.notes.showsEditedChip }
        #expect(!f.audio.isRunning)
        #expect(f.values.editCalls.requests.map(\.instruction) == ["Synthetic words."])
        #expect(f.notes.document.text.contains("Edited by voice: “Synthetic words.”"))

        f.notes.undoVoiceEdit()
        #expect(!f.notes.showsEditedChip)
        #expect(f.notes.document.text == "One\n\n- [ ] Buy figs", "Undo restores the notes before the edit")
        // Typing after the edit would have made Undo unavailable too (the version moved on).
        f.notes.edit("One\n\n- [ ] Buy figs\n\nTyped")
        #expect(!f.notes.showsEditedChip)
    }

    /// A quick tap latches the command (tap again to send); a hold sends it on release (as on Android).
    @Test func editByVoiceHoldsAndLatches() async throws {
        let f = try fixture(); defer { f.clean() }
        await f.notes.refreshHealth()
        f.notes.edit("Shopping list")
        await f.notes.settleJournal()

        f.notes.commandPress()
        try await eventually("listening") { f.notes.voiceEditListening }
        f.notes.commandRelease(held: 0.1)
        try await Task.sleep(for: .milliseconds(150))
        #expect(f.notes.voiceEditListening, "a tap leaves the command latched")

        f.notes.commandPress()
        #expect(!f.notes.commandDown, "the second press sends a latched command")
        try await eventually("applied") { f.notes.showsEditedChip }

        f.notes.undoVoiceEdit()
        f.notes.commandPress()
        try await eventually("listening again") { f.notes.voiceEditListening }
        f.notes.commandRelease(held: 0.6)
        try await eventually("applied again") { f.notes.showsEditedChip }
        #expect(f.values.editCalls.requests.count == 2)
    }

    /// While the note records, the command borrows the capture on its own socket — the microphone stays the
    /// recording's, and the recording continues on a fresh socket once the command ends.
    @Test func editByVoiceDivertsARecordingInsteadOfEnteringIt() async throws {
        let f = try fixture(); defer { f.clean() }
        await f.notes.refreshHealth()
        // Something to edit, as in the Mac's routing test: the notes start empty, and the first segment's final only
        // arrives when the command cuts it.
        f.notes.edit("Plan\n\n- keep the vendor")
        await f.notes.record()
        try await eventually("recording") { f.notes.state == .recording }
        let sockets = f.values.transports.count

        await f.notes.startVoiceEdit()
        try await eventually("listening") { f.notes.voiceEditListening }
        #expect(f.values.transports.count == sockets + 1, "the command has its own socket")
        // "Listening" shows at once; the recorder hands its capture over once the command's socket is open. Sending
        // before that would leave the recording on its own socket (a real hold is far longer than this hop).
        let command = f.values.transports[sockets]
        try await eventually("the recording's capture reaches the command's socket") {
            command.sent.contains { if case .data = $0 { true } else { false } }
        }
        #expect(f.audio.starts == 1, "no second microphone: the recorder's capture is diverted")

        f.notes.finishVoiceEdit()
        try await eventually("applied") { f.notes.showsEditedChip }
        #expect(f.notes.state == .recording, "the note records on through the command")
        #expect(f.notes.document.text.contains("- keep the vendor") && f.notes.document.text.contains("Edited by voice: “Synthetic words.”"))
        try await eventually("a fresh notes socket") { f.values.transports.count == sockets + 2 }

        await f.notes.stop()
        try await eventually("stopped") { f.notes.state == .stopped }
        #expect(f.notes.document.segments.count == 2, "the command's words made no segment")
        #expect(f.values.editCalls.requests.map(\.instruction) == ["Synthetic words."])
    }

    /// What the note shows when the edit does not apply (the server refused to add content, the call failed), and
    /// Cancel drops a listening command without editing anything.
    @Test func editByVoiceOutcomesAndCancel() async throws {
        let f = try fixture(edit: { _ in NotesEditResponse(markdown: nil, edited: false, changed: false, error: "refused", reason: "adds_content") }); defer { f.clean() }
        await f.notes.refreshHealth()
        f.notes.edit("One")
        await f.notes.settleJournal()

        await f.notes.startVoiceEdit()
        try await eventually("listening") { f.notes.voiceEditListening }
        f.notes.finishVoiceEdit()
        try await eventually("refused") { f.notes.voiceEditNote == "Can’t add new content by voice — ask to remove, move, tidy or reword" }
        #expect(f.notes.document.text == "One" && !f.notes.showsEditedChip)
        f.notes.dismissVoiceEdit()
        #expect(f.notes.voiceEditNote == nil)

        // The call fails: the notes stay and the note says so.
        let e = try fixture(edit: { _ in throw URLError(.timedOut) }); defer { e.clean() }
        await e.notes.refreshHealth()
        e.notes.edit("One")
        await e.notes.settleJournal()
        await e.notes.startVoiceEdit()
        try await eventually("listening") { e.notes.voiceEditListening }
        e.notes.finishVoiceEdit()
        try await eventually("failed") { e.notes.voiceEditNote?.hasPrefix("Couldn’t edit notes") == true }
        #expect(e.notes.document.text == "One" && !e.notes.showsEditedChip && !e.audio.isRunning)

        // Cancel: the command is dropped, its words go nowhere and nothing is sent.
        let g = try fixture(); defer { g.clean() }
        await g.notes.refreshHealth()
        g.notes.edit("Two")
        await g.notes.settleJournal()
        await g.notes.startVoiceEdit()
        try await eventually("listening") { g.notes.voiceEditListening }
        try await eventually("the microphone opened") { g.audio.isRunning }
        g.notes.cancelVoiceEdit()
        try await eventually("dropped") { !g.notes.voiceEditListening && !g.audio.isRunning }
        #expect(g.notes.voiceEditNote == nil, "a cancelled command leaves no note")
        #expect(g.values.editCalls.requests.isEmpty && g.notes.document.text == "Two")
    }

    /// The command needs the pairing, the server's endpoint and the microphone to itself: a keyboard session or an
    /// unpaired computer leaves a notice instead, and Record waits for a listening command.
    @Test func editByVoiceNeedsPairingAndTheMicrophone() async throws {
        let f = try fixture(); defer { f.clean() }
        f.values.otherCapture = true
        await f.notes.refreshHealth()
        f.notes.edit("One")
        await f.notes.settleJournal()
        await f.notes.startVoiceEdit()
        #expect(!f.notes.voiceEditListening && f.notes.notice.contains("keyboard session"))
        f.values.otherCapture = false

        await f.notes.startVoiceEdit()
        try await eventually("listening") { f.notes.voiceEditListening }
        await f.notes.record()
        #expect(f.notes.notice == "Finish the spoken edit first." && f.notes.state == .idle)
        f.notes.cancelVoiceEdit()

        let g = try fixture(paired: false); defer { g.clean() }
        g.notes.edit("One")
        await g.notes.settleJournal()
        await g.notes.startVoiceEdit()
        #expect(g.notes.notice == "Pair your computer first.")

        // An older server without the endpoint does not offer the button at all.
        var older = LiveNotesController.syntheticHealth; older.notesEdit = nil
        let h = try fixture(health: older); defer { h.clean() }
        await h.notes.refreshHealth()
        h.notes.edit("One")
        await h.notes.settleJournal()
        #expect(!h.notes.voiceEditAvailable)
    }
}
