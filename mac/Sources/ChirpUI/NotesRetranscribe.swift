import ChirpCore
import SwiftUI

// Re-transcribe a note from its kept audio (#287): the consent sheet, the progress banner, Show changes, and the run
// itself. The engine (decoding, sockets, re-attribution) is ChirpCore's and shared with iOS; this is the Mac's UI.

/// Every re-transcribe string the Mac shows (docs/copy.md: "Re-transcribe", "Allow re-transcribing", "Restore").
public enum NotesRetranscribeText {
    public static let action = "Re-transcribe…"
    public static let menuTitle = "Re-transcribe Note…"
    public static let again = "Transcribe Again…"
    public static let gapAgain = "Transcribe again"
    public static let restore = "Restore Previous Transcript"
    public static let setting = "Allow re-transcribing"
    public static let settingHelp = "Lets you send a note’s kept audio to Chirp again to rebuild its transcript, after a confirmation each time. Nothing is sent otherwise."
    public static let send = "Re-transcribe"
    public static let sendAnyway = "Re-transcribe Anyway"
    public static let changeModel = "Change model…"
    public static let rebuild = "Also rebuild the notes from the new transcript."
    public static let rebuildDetail = "This replaces the notes text, including your edits. You can undo it."
    public static let sameModel = "Same model as before. Results change only if clean-up or context changed."
    public static let updated = "Transcript updated"
    public static let cancelled = "Cancelled. Nothing changed."
    public static let rebuilt = "Notes rebuilt"
    public static let rebuildFailed = "Couldn’t rebuild the notes. Transcript updated."
    public static let restored = "Previous transcript restored"
    public static let applyDone = "Apply What’s Done"
    public static let showChanges = "Show Changes"
    public static let replaceEditsTitle = "Replace your edits?"
    public static let replaceEditsMessage = "You edited the notes while Chirp rebuilt them. Rebuilding replaces the notes text, including those edits. You can undo it."
    public static let replaceEdits = "Replace Notes"
    public static let keepEdits = "Keep My Notes"
    public static let changesTitle = "What re-transcribing changed"

    /// "Chirp on this Mac" or "your Chirp server" (docs/copy.md: the Mac names a local or remote server).
    public static func destination(local: Bool) -> String { local ? "Chirp on this Mac" : "your Chirp server" }

    /// Re-transcribe “Weekly sync”?
    public static func title(_ note: String) -> String { "Re-transcribe “\(note)”?" }

    /// "8 min 10 s" (the consent sheet's length).
    public static func length(_ seconds: TimeInterval) -> String {
        let s = max(1, Int(seconds.rounded()))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return s % 60 == 0 ? "\(s / 60) min" : "\(s / 60) min \(s % 60) s" }
        return "\(s / 3600) h \(String(format: "%02d", s / 60 % 60)) min"
    }

    public static func clips(_ n: Int) -> String { n == 1 ? "1 clip" : "\(n) clips" }

    /// The sheet's first paragraph: what is sent, where, and that nothing keeps it.
    public static func body(audio: TimeInterval, clips n: Int, local: Bool) -> String {
        "Chirp sends this note’s kept audio (\(length(audio)), \(clips(n))) to \(destination(local: local)). It is transcribed in memory there and not kept. Nothing else receives it."
    }

    /// One gap or segment: "Send this 0:32 clip to Chirp on this Mac to transcribe it again?"
    public static func oneClip(_ seconds: TimeInterval, local: Bool) -> String {
        "Send this \(NotesStatus.clock(seconds)) clip to \(destination(local: local)) to transcribe it again?"
    }

    public static func model(_ engine: String?) -> String { "Speech model: \(NotesSpeechModel.displayName(engine))." }
    public static func before(_ engine: String?) -> String { "This note was transcribed with: \(NotesSpeechModel.displayName(engine))." }
    public static func transcribedWith(_ engine: String?) -> String { "Transcribed with \(NotesSpeechModel.displayName(engine))" }

    /// "3 of 43 segments have no kept audio and keep their current text."
    public static func withoutAudio(_ missing: Int, of total: Int) -> String {
        "\(missing) of \(total) segment\(total == 1 ? "" : "s") \(missing == 1 ? "has" : "have") no kept audio and keep\(missing == 1 ? "s its" : " their") current text."
    }

    public static func rebuildNeedsCleanup(local: Bool) -> String { "Needs clean-up on \(MacServerCopy.place(local: local))" }
    public static func update(local: Bool) -> String { MacServerCopy.update(local: local, to: "re-transcribe") }

    /// The red warning when the server keeps debug recordings.
    public static func debugRetention(local: Bool) -> String {
        "\(local ? "Chirp on this Mac is" : "Your Chirp server is") keeping debug recordings. This audio will be saved there for up to 3 days."
    }

    /// Clean-up sends text to another host: only text, never audio.
    public static func cleanupHost(_ host: String) -> String { "Clean-up sends text to \(host). Audio never goes there." }

    /// "Re-transcribing · 12 of 40 · 1:32 of 8:10".
    public static func progress(_ p: NotesRetranscribeProgress) -> String {
        "Re-transcribing · \(p.done) of \(p.total) · \(NotesStatus.clock(p.audioDone)) of \(NotesStatus.clock(p.audioTotal))"
    }

    public static func waiting(local: Bool) -> String { "Waiting for \(destination(local: local))…" }

    /// The finish toast: "Transcript updated", or "38 of 40 updated. 2 kept their old text."
    public static func finished(updated: Int, of total: Int) -> String {
        guard updated < total else { return self.updated }
        let kept = total - updated
        return "\(updated) of \(total) updated. \(kept) kept \(kept == 1 ? "its" : "their") old text."
    }

    /// Why a run stopped before the end; nothing was applied.
    public static func stopped(code: String, local: Bool) -> String {
        code == "busy" ? "\(destination(local: local).capitalizedFirst) stayed busy. Nothing changed yet."
            : "Couldn’t reach \(destination(local: local)). Nothing changed yet."
    }

    public static func refused(local: Bool) -> String {
        "\(destination(local: local).capitalizedFirst) refused the connection. Nothing changed."
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// What the consent sheet says about one run (#287 §2.2). Built fresh every time: there is no "don't ask again".
public struct NotesRetranscribeOffer: Equatable, Sendable, Identifiable {
    public var note: UUID
    public var title: String
    /// One segment ("Transcribe again"), or nil for the whole note.
    public var segment: Int?
    public var clips: Int
    public var audio: TimeInterval
    public var segments: Int
    /// Segments with text but no kept audio: they keep their current text.
    public var withoutAudio: Int
    public var local: Bool
    /// The server's engine now, and the one the note was transcribed with (nil: unknown).
    public var model: String?
    public var before: String?
    /// The server takes `start.retranscribe` (otherwise the sheet asks to update and has no send button).
    public var supported: Bool
    public var debugRetention: Bool
    /// Clean-up sends text to this host (`correction_leaves_machine`).
    public var cleanupHost: String?
    /// Structuring is possible, so the notes can be rebuilt.
    public var rebuildAvailable: Bool
    public var rebuild: Bool
    public var canChangeModel: Bool
    public var id: UUID { note }

    public init(note: UUID, title: String, segment: Int? = nil, clips: Int, audio: TimeInterval, segments: Int,
                withoutAudio: Int = 0, local: Bool = true, model: String? = nil, before: String? = nil, supported: Bool = true,
                debugRetention: Bool = false, cleanupHost: String? = nil, rebuildAvailable: Bool = true, rebuild: Bool = false,
                canChangeModel: Bool = true) {
        self.note = note; self.title = title; self.segment = segment; self.clips = clips; self.audio = audio
        self.segments = segments; self.withoutAudio = withoutAudio; self.local = local; self.model = model; self.before = before
        self.supported = supported; self.debugRetention = debugRetention; self.cleanupHost = cleanupHost
        self.rebuildAvailable = rebuildAvailable; self.rebuild = rebuild; self.canChangeModel = canChangeModel
    }

    /// Every segment already came from the server's current model.
    public var sameModel: Bool { model != nil && before == model }
}

/// The run on screen (one at a time on this Mac): its progress, or why it stopped.
public struct NotesRetranscribeRun: Equatable, Sendable {
    public var note: UUID
    public var progress: NotesRetranscribeProgress
    public var local: Bool
    /// Set when the run stopped early (busy, unreachable, refused): the banner shows it with Dismiss, and Apply What’s
    /// Done when some clips finished.
    public var failure: String?
    public var canApplyPartial = false
    /// The server refused the pairing: the banner offers Server Settings….
    public var fixServer = false

    public init(note: UUID, progress: NotesRetranscribeProgress, local: Bool, failure: String? = nil, canApplyPartial: Bool = false) {
        self.note = note; self.progress = progress; self.local = local; self.failure = failure; self.canApplyPartial = canApplyPartial
    }

    public var text: String {
        if let failure { return failure }
        return progress.waiting ? NotesRetranscribeText.waiting(local: local) : NotesRetranscribeText.progress(progress)
    }
}

/// Show changes: the segments a re-transcribe changed, each as a word diff of the old text against the new.
public struct NotesTranscriptChanges: Equatable, Sendable, Identifiable {
    public struct Row: Equatable, Sendable, Identifiable {
        public var segment: Int
        public var offset: TimeInterval
        public var diff: [WordDiff.Segment]
        public var id: Int { segment }
    }
    public var note: UUID
    public var rows: [Row]
    public var id: UUID { note }

    /// The changed segments of `document` against its previous transcript, in order.
    public init(_ document: NotesDocument) {
        note = document.id
        rows = (document.previousTranscript?.segments ?? []).compactMap { old in
            guard document.segments.indices.contains(old.id) else { return nil }
            let now = document.segments[old.id]
            let before = old.failure != nil ? "" : old.text
            guard before != now.text else { return nil }
            let diff = WordDiff.segments(raw: before, cleaned: now.text)
                ?? [WordDiff.Segment(.removed, before), WordDiff.Segment(.added, now.text)].filter { !$0.text.isEmpty }
            return Row(segment: old.id, offset: now.offset, diff: diff)
        }
    }
}

// MARK: views

/// The consent and options sheet, shown every time (the per-action consent, #287 §4).
struct RetranscribeSheet: View {
    @Bindable var library: NotesLibraryModel
    let offer: NotesRetranscribeOffer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NotesRetranscribeText.title(offer.title)).font(ChirpType.noteTitle(20)).fixedSize(horizontal: false, vertical: true)
            if !offer.supported {
                Label(NotesRetranscribeText.update(local: offer.local), systemImage: "arrow.down.circle")
                    .foregroundStyle(NotesInk.primary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(offer.segment == nil ? NotesRetranscribeText.body(audio: offer.audio, clips: offer.clips, local: offer.local)
                     : NotesRetranscribeText.oneClip(offer.audio, local: offer.local))
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(NotesRetranscribeText.model(offer.model))
                        if offer.canChangeModel {
                            Button(NotesRetranscribeText.changeModel) { library.onManageModels() }
                                .buttonStyle(.link)
                        }
                    }
                    Text(NotesRetranscribeText.before(offer.before)).foregroundStyle(NotesInk.secondary)
                    if offer.sameModel { Text(NotesRetranscribeText.sameModel).foregroundStyle(NotesInk.secondary) }
                }
                .font(.callout)
                if offer.segment == nil {
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(NotesRetranscribeText.rebuild, isOn: Binding(
                            get: { library.retranscribeOffer?.rebuild ?? false },
                            set: { library.retranscribeOffer?.rebuild = $0 }))
                            .toggleStyle(.checkbox)
                            .disabled(!offer.rebuildAvailable)
                        Text(offer.rebuildAvailable ? NotesRetranscribeText.rebuildDetail
                             : NotesRetranscribeText.rebuildNeedsCleanup(local: offer.local))
                            .font(.caption)
                            .foregroundStyle(NotesInk.secondary)
                            .padding(.leading, 20)
                    }
                    if offer.withoutAudio > 0 {
                        Text(NotesRetranscribeText.withoutAudio(offer.withoutAudio, of: offer.segments))
                            .font(.callout.italic())
                            .foregroundStyle(NotesInk.secondary)
                    }
                }
                if let host = offer.cleanupHost {
                    Label(NotesRetranscribeText.cleanupHost(host), systemImage: "arrow.up.right.circle")
                        .font(.callout)
                        .foregroundStyle(NotesInk.secondary)
                }
                if offer.debugRetention {
                    Label(NotesRetranscribeText.debugRetention(local: offer.local), systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(Color.chirp.record)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { library.retranscribeOffer = nil }
                    .keyboardShortcut(.cancelAction)
                if offer.supported {
                    Button(offer.debugRetention ? NotesRetranscribeText.sendAnyway : NotesRetranscribeText.send) {
                        if let current = library.retranscribeOffer { library.onRetranscribeStart(current) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(offer.debugRetention ? Color.chirp.record : Color.chirp.koi)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.top, 4)
        }
        .padding(20)
        .frame(width: 460)
        .background(Color.chirp.background)
        .tint(Color.chirp.koi)
    }
}

/// The banner at the top of the transcript while a run lasts, or after it stopped early.
struct RetranscribeBanner: View {
    @Bindable var library: NotesLibraryModel
    let run: NotesRetranscribeRun

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if run.failure != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.chirp.moon).accessibilityHidden(true)
                }
                Text(run.text)
                    .font(.callout)
                    .foregroundStyle(NotesInk.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if run.failure == nil {
                    Button("Cancel") { library.onRetranscribeCancel() }.controlSize(.small)
                }
            }
            if run.failure == nil {
                ProgressView(value: run.progress.fraction)
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Re-transcribing, \(run.progress.done) of \(run.progress.total)")
            } else {
                HStack(spacing: 8) {
                    Spacer()
                    if run.fixServer {
                        Button("Server Settings…") { library.onServerSettings() }.controlSize(.small)
                    }
                    if run.canApplyPartial {
                        Button(NotesRetranscribeText.applyDone) { library.onRetranscribeApplyPartial() }.controlSize(.small)
                    }
                    Button("Dismiss") { library.onRetranscribeDismiss() }.controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.chirp.koiContainer.opacity(0.35))
        .accessibilityElement(children: .contain)
    }
}

/// Show changes: each changed segment as a word diff in the Pond style (struck-through muted ink for what went,
/// a moon underline for what came).
struct TranscriptChangesSheet: View {
    @Bindable var library: NotesLibraryModel
    let changes: NotesTranscriptChanges

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "waveform").foregroundStyle(Color.chirp.moon)
                Text(NotesRetranscribeText.changesTitle).font(ChirpType.noteTitle(20))
                Spacer()
                Text(changes.rows.count == 1 ? "1 segment changed" : "\(changes.rows.count) segments changed")
                    .font(ChirpType.meta).foregroundStyle(NotesInk.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if changes.rows.isEmpty {
                        Text("No changes").foregroundStyle(NotesInk.secondary)
                    }
                    ForEach(changes.rows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(NotesStatus.clock(row.offset))
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(NotesInk.secondary)
                            Self.text(row.diff)
                                .font(.system(size: 13))
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(12)
            }
            .frame(height: 320)
            .background(RoundedRectangle(cornerRadius: ChirpRadius.row).fill(Color.chirp.surface))
            .overlay(RoundedRectangle(cornerRadius: ChirpRadius.row).strokeBorder(NotesInk.tertiary.opacity(0.4)))
            HStack {
                Spacer()
                Button("Done") { library.transcriptChanges = nil }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
        .background(Color.chirp.background)
        .tint(Color.chirp.koi)
    }

    static func text(_ diff: [WordDiff.Segment]) -> Text {
        diff.enumerated().reduce(Text("")) { text, item in
            let (i, s) = item
            // The space between words stays unstyled, so marks cover the words alone.
            let lead = text + Text(i == 0 ? "" : " ")
            let word = Text(s.text)
            switch s.kind {
            case .same: return lead + word.foregroundColor(NotesInk.primary)
            case .removed: return lead + word.foregroundColor(NotesInk.tertiary).strikethrough(true, color: NotesInk.tertiary)
            case .added, .changed: return lead + word.foregroundColor(NotesInk.primary).underline(true, color: Color.chirp.moon)
            }
        }
    }
}

// MARK: the run

/// Runs re-transcribes for the Notes window: builds the consent offer, decodes and sends the clips with the shared
/// `NotesRetranscriber`, applies the result in one write to whichever copy of the note is open, and handles Undo,
/// Restore previous transcript, Show changes and the optional rebuild. Logs counts only.
@MainActor
final class NotesRetranscribeController {
    struct Dependencies {
        var settings: Preferences
        var library: NotesLibrary
        var window: NotesLibraryModel
        var makeSession: (StartOptions) -> StreamSession
        var structure: NotesRecorder.Structure
        var health: () -> Health?
        /// The server is this Mac (loopback).
        var local: () -> Bool
        /// The note as it is open now (the recorder's or the one beside a recording), else from the library.
        var document: @MainActor (UUID) async -> NotesDocument?
        /// Changes the note where it lives (the open copy, else the library record); false when it could not.
        var update: @MainActor (UUID, @MainActor (inout NotesDocument) -> Void) async -> Bool
        /// The rebuilt body as one `.rebuild` change, when the body is still at `version`; `force` replaces edits.
        var rebuild: @MainActor (UUID, NotesRebuild.Result, _ version: Int?, _ force: Bool) async -> Bool
        var announce: (String) -> Void = { _ in }
    }

    private let deps: Dependencies
    private var task: Task<Void, Never>?
    private var staged: (note: UUID, result: NotesRetranscribeResult)?
    private var rebuildTask: Task<Void, Never>?
    private var pendingRebuild: (note: UUID, result: NotesRebuild.Result)?

    init(_ deps: Dependencies) { self.deps = deps }

    var isRunning: Bool { task != nil || deps.window.retranscribeRun != nil }

    /// Re-transcribe… (the whole note) or Transcribe Again… (one segment): the sheet, filled in.
    func offer(_ id: UUID, segment: Int? = nil) async {
        guard deps.settings.notesAllowRetranscribe, !isRunning, let document = await deps.document(id) else { return }
        let clips = NotesRetranscriber.clips(for: document, only: segment)
        guard !clips.isEmpty else { return }
        let health = deps.health()
        let withAudio = Set(document.audio.map(\.id))
        let spoken = document.segments.filter { !$0.isGap && !$0.text.isEmpty }
        let leaves = health?.correctionLeavesMachine == true && deps.settings.permitsCorrection(health: health)
        deps.window.retranscribeOffer = NotesRetranscribeOffer(
            note: id, title: document.isEmpty && document.userTitle == nil ? NotesLibraryText.untitled : document.title,
            segment: segment, clips: clips.count, audio: clips.reduce(0) { $0 + $1.duration },
            segments: document.segments.count, withoutAudio: spoken.filter { !withAudio.contains($0.id) }.count,
            local: deps.local(), model: health?.engine, before: document.transcribedWith,
            supported: health?.supportsRetranscribe == true, debugRetention: health?.debugRetention == true,
            cleanupHost: leaves ? health?.correctionHost : nil,
            rebuildAvailable: deps.settings.notesStructureEnabled(health: health) && health?.notesStructure == true,
            rebuild: deps.settings.notesRetranscribeRebuild, canChangeModel: deps.local())
    }

    /// The sheet's Re-transcribe.
    func start(_ offer: NotesRetranscribeOffer) {
        deps.window.retranscribeOffer = nil
        guard !isRunning, deps.settings.notesAllowRetranscribe else { return }
        if offer.segment == nil { deps.settings.notesRetranscribeRebuild = offer.rebuild }
        let health = deps.health()
        let store = deps.library.store
        let id = offer.note
        let local = deps.local()
        let runner = NotesRetranscriber(
            makeSession: deps.makeSession, options: deps.settings.notesStartOptions(health: health), health: health,
            audio: { clip in try NotesAudioDecoder.decode(contentsOf: store.audioURL(id, segment: clip.segment)) })
        runner.onProgress = { [weak self] progress in
            Task { @MainActor in
                guard let self, self.deps.window.retranscribeRun?.note == id, self.deps.window.retranscribeRun?.failure == nil else { return }
                self.deps.window.retranscribeRun?.progress = progress
            }
        }
        deps.window.retranscribeRun = NotesRetranscribeRun(
            note: id, progress: NotesRetranscribeProgress(done: 0, total: offer.clips, audioDone: 0, audioTotal: offer.audio), local: local)
        task = Task { [weak self] in
            let document = await self?.deps.document(id)
            let clips = document.map { NotesRetranscriber.clips(for: $0, only: offer.segment) } ?? []
            // The note went away before the first clip: nothing to send, nothing changes.
            let result = clips.isEmpty
                ? NotesRetranscribeResult(end: .cancelled)
                : await runner.run(clips)
            await self?.finish(id, result: result, rebuild: offer.segment == nil && offer.rebuild && offer.rebuildAvailable)
        }
    }

    private func finish(_ id: UUID, result: NotesRetranscribeResult, rebuild: Bool) async {
        task = nil
        chirpLog.info("\(result.logLine, privacy: .public)")
        let local = deps.local()
        switch result.end {
        case .cancelled:
            deps.window.retranscribeRun = nil
            deps.window.showToast(NotesRetranscribeText.cancelled)
        case .auth:
            deps.window.retranscribeRun?.failure = NotesRetranscribeText.refused(local: local)
            deps.window.retranscribeRun?.fixServer = true
        case .stopped(let code):
            staged = (id, result)
            deps.window.retranscribeRun?.failure = NotesRetranscribeText.stopped(code: code, local: local)
            deps.window.retranscribeRun?.canApplyPartial = !result.segments.isEmpty
        case .finished:
            await apply(id, result: result, rebuild: rebuild)
        }
    }

    /// One revision of the note: every staged segment at once, then the toast (and the rebuild when asked for).
    private func apply(_ id: UUID, result: NotesRetranscribeResult, rebuild: Bool) async {
        deps.window.retranscribeRun = nil
        staged = nil
        guard !result.segments.isEmpty else {
            deps.window.showToast(NotesRetranscribeText.finished(updated: 0, of: result.total))
            return
        }
        var updated = 0
        let ok = await deps.update(id) { updated = $0.applyRetranscription(result.segments) }
        guard ok, updated > 0 else { return }
        let text = NotesRetranscribeText.finished(updated: updated, of: result.total)
        deps.window.showToast(text, action: .transcript(id))
        deps.announce(text)
        if rebuild { startRebuild(id) }
    }

    /// The error banner's Apply What’s Done.
    func applyPartial() {
        guard let staged else { return }
        Task { await apply(staged.note, result: staged.result, rebuild: false) }
    }

    /// Cancel: the in-flight clip is cancelled and everything staged goes. The note is exactly as before.
    func cancel() {
        if let task {
            task.cancel()
            return
        }
        dismiss()
    }

    /// Dismiss on the error banner: nothing applies.
    func dismiss() {
        staged = nil
        if deps.window.retranscribeRun != nil {
            deps.window.retranscribeRun = nil
            deps.window.showToast(NotesRetranscribeText.cancelled)
        }
    }

    /// The note went away (deleted) or the setting was turned off: a run on it stops without applying anything.
    func cancel(note id: UUID?) {
        guard id == nil || deps.window.retranscribeRun?.note == id || pendingRebuild?.note == id else { return }
        task?.cancel()
        rebuildTask?.cancel()
        rebuildTask = nil
        pendingRebuild = nil
        deps.window.confirmingRebuild = nil
        if task == nil { dismiss() }
    }

    /// The toast's Undo and Restore Previous Transcript: the kept version swaps back in.
    func restore(_ id: UUID) {
        guard deps.window.retranscribeRun?.note != id else { return }
        Task {
            var swapped = false
            _ = await deps.update(id) { swapped = $0.restorePreviousTranscript() }
            if swapped {
                deps.window.showToast(NotesRetranscribeText.restored)
                deps.announce(NotesRetranscribeText.restored)
            }
        }
    }

    func showChanges(_ id: UUID) {
        Task {
            guard let document = await deps.document(id) else { return }
            deps.window.transcriptChanges = NotesTranscriptChanges(document)
        }
    }

    // MARK: rebuild

    private func startRebuild(_ id: UUID) {
        rebuildTask = Task { [weak self] in
            guard let self, let document = await deps.document(id) else { return }
            let version = document.version
            let result = await NotesRebuild.run(document, structure: deps.structure)
            guard !Task.isCancelled else { return }
            rebuildTask = nil
            guard let result else {
                deps.window.showToast(NotesRetranscribeText.rebuildFailed, action: .transcript(id))
                return
            }
            chirpLog.info("notes retranscribe rebuild windows=\(result.windows, privacy: .public) structured=\(result.structured, privacy: .public)")
            if await deps.rebuild(id, result, version, false) {
                deps.window.showToast(NotesRetranscribeText.rebuilt, action: .rebuild(id))
            } else {
                // The body changed during the run (the late-AI rule): ask before replacing those edits.
                pendingRebuild = (id, result)
                deps.window.confirmingRebuild = id
            }
        }
    }

    /// "Replace your edits?": Replace Notes applies the rebuild anyway; Keep My Notes drops it.
    func confirmRebuild(_ replace: Bool) {
        deps.window.confirmingRebuild = nil
        guard let pending = pendingRebuild else { return }
        pendingRebuild = nil
        guard replace else { return }
        Task {
            if await deps.rebuild(pending.note, pending.result, nil, true) {
                deps.window.showToast(NotesRetranscribeText.rebuilt, action: .rebuild(pending.note))
            }
        }
    }
}
