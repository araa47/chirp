import ChirpCore
import SwiftUI

/// Sizes the Notes window and its snapshots share.
public enum NotesViewMetrics {
    public static let defaultSize = CGSize(width: 1120, height: 720)
    public static let minimumSize = CGSize(width: 760, height: 460)
    /// Notes read best at a comfortable measure, however wide the window.
    static let readingWidth: CGFloat = 680
    /// The library sidebar's width range, and the transcript inspector's.
    static let sidebar = (min: CGFloat(260), ideal: CGFloat(280), max: CGFloat(320))
    static let inspector = (min: CGFloat(260), ideal: CGFloat(300), max: CGFloat(420))
    /// Below this width the transcript moves under the note: sidebar + note + inspector would crush the note's measure.
    static let transcriptColumnMinWindow: CGFloat = 1000
    public static func compactTranscript(windowWidth: CGFloat) -> Bool { windowWidth < transcriptColumnMinWindow }
    public static func compactTranscriptHeight(windowHeight: CGFloat) -> CGFloat { min(300, max(160, windowHeight * 0.38)) }
}

/// Text inks that keep their value inside vibrant sidebars, selected rows and the inspector, where a hierarchical
/// style can turn dark. Secondary text is Pond's muted ink (at least 4.5:1 on the editor, sidebar and selected rows;
/// AppKit's secondary/tertiary label colours measured 1.9–4:1 there); Increase Contrast turns it into full ink.
enum NotesInk {
    static let primary = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: muted)
    static let tertiary = secondary

    /// AppKit reports Increase Contrast through the high-contrast appearances (and the workspace flag); either one
    /// turns muted text into full ink.
    static let muted = NSColor(name: "ChirpNotesMuted") { appearance in
        let match = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua])
        let c = mutedInk(dark: match == .darkAqua || match == .accessibilityHighContrastDarkAqua,
                         increaseContrast: match == .accessibilityHighContrastAqua || match == .accessibilityHighContrastDarkAqua
                             || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast)
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }

    static func mutedInk(dark: Bool, increaseContrast: Bool) -> ChirpColor.RGB {
        switch (dark, increaseContrast) {
        case (false, false): ChirpColor.Pond.inkMuted.light
        case (true, false): ChirpColor.Pond.inkMuted.dark
        case (false, true): ChirpColor.Pond.ink.light
        case (true, true): ChirpColor.Pond.ink.dark
        }
    }
}

/// The Live Notes window: the notes library as the sidebar, the note as the detail, and its transcript as a trailing
/// inspector, under one unified toolbar (search, New Note, the Recording capsule, ✦ Smart notes, Share/Export).
/// `model` is the recorder's note; `library` is everything around it (`NotesLibraryModel`).
public struct NotesView: View {
    @Bindable var model: NotesModel
    @Bindable var library: NotesLibraryModel

    public init(model: NotesModel, library: NotesLibraryModel = NotesLibraryModel()) {
        self.model = model
        self.library = library
    }

    private var shown: NotesModel { library.displayed(model) }

    public var body: some View {
        NavigationSplitView {
            NotesSidebar(model: model, library: library)
                // The sidebar sits on `surfaceRaised` (under the toolbar too), so it belongs to the Pond beside the
                // editor instead of the grey system material.
                .background(Color.chirp.surfaceRaised.ignoresSafeArea())
                .navigationSplitViewColumnWidth(min: NotesViewMetrics.sidebar.min, ideal: NotesViewMetrics.sidebar.ideal,
                                                max: NotesViewMetrics.sidebar.max)
        } detail: {
            VStack(spacing: 0) {
                detail
                // Narrow windows: a third column would leave the note about 160 pt of text, so the same transcript sits
                // under the note instead. It is not modal: typing, recording and replay all keep working.
                if library.transcriptBelow, library.showsInspector {
                    Divider()
                    NotesInspector(model: shown, library: library)
                        .frame(height: library.transcriptBelowHeight)
                        .background(Color.chirp.surfaceRaised)
                        .onGeometryChange(for: CGSize.self, of: \.size) { library.compactTranscriptSize = $0 }
                }
            }
            // The user's choice survives resizing: only the presentation changes with the width.
            .inspector(isPresented: Binding(get: { library.showsInspector && !library.transcriptBelow },
                                            set: { if !library.transcriptBelow { library.setInspector($0) } })) {
                NotesInspector(model: shown, library: library)
                    .inspectorColumnWidth(min: NotesViewMetrics.inspector.min, ideal: NotesViewMetrics.inspector.ideal,
                                          max: NotesViewMetrics.inspector.max)
            }
        }
        .onGeometryChange(for: CGSize.self, of: \.size) { library.windowResized($0) }
        .searchable(text: $library.query, placement: .sidebar, prompt: "Search notes")
        .toolbar { NotesToolbar(model: model, library: library) }
        .navigationTitle(library.selection == .recentlyDeleted ? NotesLibraryText.recentlyDeleted : shown.displayTitle)
        .navigationSubtitle(subtitle)
        .frame(minWidth: NotesViewMetrics.minimumSize.width, minHeight: NotesViewMetrics.minimumSize.height)
        .overlay(alignment: .bottom) { if let toast = library.toast { NotesToastView(library: library, toast: toast) } }
        .sheet(isPresented: Binding(get: { shown.reviewing != nil }, set: { if !$0 { shown.closeReview() } })) {
            OrganizeReviewSheet(model: shown)
        }
        .sheet(isPresented: $library.readingNote) {
            NotesFormattedReader(model: shown) { library.readingNote = false }
                .environment(\.chirpTextScale, library.textSize.factor)
        }
        .sheet(item: $library.retranscribeOffer) { RetranscribeSheet(library: library, offer: $0) }
        .sheet(item: $library.transcriptChanges) { TranscriptChangesSheet(library: library, changes: $0) }
        .alert(NotesRetranscribeText.replaceEditsTitle,
               isPresented: Binding(get: { library.confirmingRebuild != nil }, set: { if !$0 { library.onConfirmRebuild(false) } })) {
            Button(NotesRetranscribeText.replaceEdits, role: .destructive) { library.onConfirmRebuild(true) }
            Button(NotesRetranscribeText.keepEdits, role: .cancel) { library.onConfirmRebuild(false) }
        } message: {
            Text(NotesRetranscribeText.replaceEditsMessage)
        }
        .alert(NotesLibraryText.switchPrompt(model.displayTitle),
               isPresented: Binding(get: { library.confirmingSwitch != nil }, set: { if !$0 { library.confirmingSwitch = nil } })) {
            Button(NotesLibraryText.stopAndContinue) {
                if let id = library.confirmingSwitch { library.onStopAndContinue(id) }
                library.confirmingSwitch = nil
            }
            Button("Cancel", role: .cancel) { library.confirmingSwitch = nil }
        } message: {
            Text("Only one note records at a time. The recording note keeps everything it has so far.")
        }
        // The alert hands the presented entry to its buttons: SwiftUI may reset the binding (which drops the request)
        // before it runs the action, so Delete Permanently must not depend on `confirmingPurge` still being set.
        .alert("Delete “\(library.confirmingPurge?.title ?? "note")” permanently?",
               isPresented: Binding(get: { library.confirmingPurge != nil }, set: { if !$0 { library.resolvePurge(confirm: false) } }),
               presenting: library.confirmingPurge) { entry in
            Button("Delete Permanently", role: .destructive) { Self.purgeConfirmed(entry, in: library) }
            Button("Cancel", role: .cancel) { library.resolvePurge(confirm: false) }
        } message: { _ in
            Text("This deletes the note and any kept audio. This can’t be undone.")
        }
        .alert(NotesLibraryText.emptyTrashTitle, isPresented: $library.confirmingEmpty) {
            Button(NotesLibraryText.deletePermanently, role: .destructive) { library.onEmptyTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(NotesLibraryText.emptyTrashMessage(library.deleted.count))
        }
        // The app accent (koi): system controls in Notes follow it, bundled or not.
        .tint(Color.chirp.koi)
        .environment(\.chirpTextScale, library.textSize.factor)
    }

    /// The toolbar's second line: what the recorder is doing, or when the note was last edited.
    private var subtitle: String {
        if library.selection == .recentlyDeleted { return NotesLibraryText.trashHelp }
        if shown === model, !model.headerStatusText.isEmpty, model.state != .stopped { return model.headerStatusText }
        guard !shown.isBlank else { return "" }
        let edited = library.entry(shown.document.id)?.updatedAt ?? shown.document.updatedAt
        return "Edited " + NotesLibraryText.relative(edited, now: library.now(), calendar: library.calendar).lowercasedIfTime
    }

    @ViewBuilder private var detail: some View {
        if library.selection == .recentlyDeleted {
            RecentlyDeletedView(library: library)
        } else if library.isEmpty, shown === model, model.showsEmptyState {
            NotesEmptyState(model: model, library: library)
        } else {
            NotesDetail(model: shown, active: model, library: library)
        }
    }
}

private extension String {
    /// "Edited 3:12 PM" reads as is; "Edited Yesterday" becomes "Edited yesterday".
    var lowercasedIfTime: String { self == "Yesterday" ? "yesterday" : self }
}

// MARK: detail

/// The note: banners for what needs attention, the title and editor (one scrolling page), the status lines, the
/// Hearing strip while recording, and the quiet meta bar (where structuring sends text, kept exports).
extension NotesView {
    /// Delete Permanently for the entry the alert presented, whichever order SwiftUI resets the binding and runs the action.
    /// Re-requesting keeps the model's guard: only a note still in Recently Deleted is purged, once.
    static func purgeConfirmed(_ entry: NotesLibraryEntry, in library: NotesLibraryModel) {
        library.requestPurge(entry.id)
        library.resolvePurge(confirm: true)
    }
}

struct NotesDetail: View {
    @Bindable var model: NotesModel
    let active: NotesModel
    @Bindable var library: NotesLibraryModel

    private var isRecorder: Bool { model === active }

    var body: some View {
        VStack(spacing: 0) {
            if isRecorder {
                if let message = model.errorText {
                    ErrorBanner(text: message, action: NotesStatus.errorOpensServerSettings(message) ? ("Server Settings…", model.onServerSettings) : nil)
                }
                if let offer = model.recovery { RecoveryBanner(model: model, offer: offer) }
                if model.showsLongRunNotice { LongRunNotice(model: model) }
                if let explanation = model.explanation { ExplanationBanner(model: model, text: explanation) }
                if let notice = model.speakerModelNotice { SpeakerModelBanner(model: model, notice: notice) }
            }
            if model.showsNameSpeakersLine { SpeakerNameLine(model: model) }
            ZStack(alignment: .topTrailing) {
                NotesEditor(model: model, library: library)
                    .id(ObjectIdentifier(model))
                VStack(alignment: .trailing, spacing: 6) {
                    if model.showEditedChip { EditedChip(model: model) }
                    if model.showUndoChip { UndoChip(model: model) }
                    if model.isUpdating { UpdatingBadge() }
                }
                .padding(.top, 12)
                .padding(.trailing, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            NotesStatusLines(model: model)
            if isRecorder, model.state.isLive, !model.hearingText.isEmpty { HearingStrip(parts: model.hearingParts, text: model.hearingText, paused: model.isPaused) }
            NotesMetaBar(model: model)
        }
        // Under the toolbar too, so the title bar sits on the page.
        .background(Color.chirp.surface.ignoresSafeArea())
        .sheet(isPresented: Binding(get: { model.namingSpeakers }, set: { if !$0 { model.endNamingSpeakers() } })) {
            if let state = model.nameSpeakers { NameSpeakersSheet(model: model, state: state, library: library) }
        }
    }
}

/// The title page above the notes: a large serif title field and one quiet line of facts about the note.
struct NotesTitleHeader: View {
    @Bindable var model: NotesModel
    let library: NotesLibraryModel
    var width: CGFloat?

    private var created: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = library.calendar.timeZone
        f.dateFormat = "MMMM d, yyyy 'at' h:mm a"
        return f
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(NotesLibraryText.untitled, text: Binding(
                get: { model.titleDraft ?? (model.isBlank && model.document.userTitle == nil ? "" : model.document.title) },
                set: { model.titleDraft = $0; model.onTitleEdit($0) }), axis: .vertical)
                .textFieldStyle(.plain)
                .pondFont(26, weight: .semibold, design: .serif)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(NotesInk.primary)
                .onSubmit { model.focusRequest += 1 }
                .accessibilityLabel("Title")
            meta
        }
        .padding(.top, 30)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(width: width)
        .environment(\.chirpTextScale, library.textSize.factor)
    }

    private var meta: some View {
        let d = model.document
        let entry = library.entry(d.id)
        var facts: [String] = [created.string(from: d.createdAt)]
        if let length = NotesLibraryText.duration(model.elapsed) { facts.append(length) }
        let open = d.openTodoCount()
        if open > 0 { facts.append("☐ " + NotesLibraryText.open(open)) }
        if let bytes = entry?.audioBytes, bytes > 0 { facts.append("Audio " + NotesLibraryText.size(bytes)) }
        let line = Text(facts.joined(separator: "  ·  ")).pondFont(.meta).foregroundStyle(NotesInk.secondary)
        // One line while it fits; otherwise the state sits above the facts, so neither wraps into a narrow column.
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { state(entry); line.fixedSize() }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) { state(entry) }
                line.fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func state(_ entry: NotesLibraryEntry?) -> some View {
        if model.state.isLive {
            Image(systemName: model.isPaused ? "pause.circle" : "record.circle.fill")
                .foregroundStyle(model.isPaused ? NotesInk.secondary : Color.chirp.record).accessibilityHidden(true)
            Text(model.isPaused ? NotesStatus.paused : NotesLibraryText.recording)
                .pondFont(.meta, weight: .semibold)
                .foregroundStyle(model.isPaused ? NotesInk.secondary : Color.chirp.record)
        }
        if entry?.recovered == true { RecoveredBadge() }
    }
}

/// "Recovered": a capture that never received Stop, found at launch. No modal, just this mark.
struct RecoveredBadge: View {
    /// The selected dark sidebar row uses the koi container.
    var onPill = false

    var body: some View {
        Text(NotesLibraryText.recovered)
            .pondFont(12, weight: .semibold)
            .foregroundStyle(onPill ? Color.chirp.onKoiContainer : Color.chirp.moon)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(onPill ? Color.chirp.onKoiContainer.opacity(0.14) : Color.chirp.moonFill.opacity(0.22)))
            .fixedSize()
            .help("Chirp found this note after it quit unexpectedly. Everything it had is here.")
    }
}

// MARK: toolbar

/// The unified toolbar's trailing items: the record control (or the Recording capsule), ✦ Smart notes, Share/Export and
/// the transcript inspector. New Note sits over the sidebar.
struct NotesToolbar: ToolbarContent {
    let model: NotesModel
    let library: NotesLibraryModel

    private var shown: NotesModel { library.displayed(model) }

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            let note = library.selection != .recentlyDeleted
            // Toolbar chrome stays native size; View ▸ Bigger Text enlarges the content.
            if note || model.state.isActive { RecordControl(model: model, library: library).environment(\.chirpTextScale, 1) }
            if model.state.isLive { PauseButton(model: model) }
            if model.callAudioAvailable, note || model.state.isActive { SourcesButton(model: model) }
            if note, shown.voiceEditAvailable { VoiceEditButton(model: shown) }
            if note {
                SmartNotesMenu(model: shown, recorder: model)
                ShareMenu(model: shown)
            }
            Button {
                library.setInspector(!library.showsInspector)
            } label: {
                Label("Transcript", systemImage: "sidebar.right")
            }
            .help(library.showsInspector ? "Hide the transcript (⌥⌘T)" : "Show the transcript (⌥⌘T)")
        }
    }
}

/// Not recording: Record (a new note) or Continue (a finished one). Recording: the capsule `◉ <title> 03:12`, which
/// jumps back to the recording note from anywhere in the library, with Stop beside it.
struct RecordControl: View {
    let model: NotesModel
    let library: NotesLibraryModel

    var body: some View {
        if model.state.isActive {
            HStack(spacing: 6) {
                Button {
                    library.select(.note(model.document.id))
                } label: {
                    HStack(spacing: 7) {
                        if model.isPaused {
                            Image(systemName: "pause.circle.fill").foregroundStyle(NotesInk.secondary)
                        } else {
                            Ripple(level: Double(model.level), reduceMotion: model.reduceMotion, phase: model.ripplePhase,
                                   color: .chirp.record, staticColor: .chirp.record, side: 18)
                                .overlay(Circle().fill(Color.chirp.record).frame(width: 7, height: 7))
                            if model.capturingCall {
                                // The call side's own ripple: both sources show they are heard.
                                Ripple(level: Double(model.callLevel), reduceMotion: model.reduceMotion, phase: model.ripplePhase,
                                       side: 18)
                                    .overlay(Image(systemName: "speaker.wave.2.fill").pondFont(7, weight: .bold)
                                        .foregroundStyle(Color.chirp.koi))
                                    .help(NotesSourcesText.capturing(model.sources))
                            }
                        }
                        Text(model.displayTitle)
                            .pondFont(.callout, weight: .medium)
                            .lineLimit(1)
                            .frame(maxWidth: 170, alignment: .leading)
                            .fixedSize(horizontal: true, vertical: false)
                        Text(model.elapsedText)
                            .pondFont(13, weight: .medium, digits: true)
                            .foregroundStyle(NotesInk.secondary)
                    }
                    .padding(.horizontal, 4)
                    .onGeometryChange(for: CGSize.self, of: \.size) { model.probe.recordLabel = $0 }
                }
                .help("Go to the recording note")
                .accessibilityLabel("\(model.isPaused ? "Paused" : "Recording") \(model.displayTitle)\(model.capturingCall ? " with call audio" : ""), \(model.elapsedText). Go to the recording note")
                Button(action: model.onRecordToggle) {
                    Image(systemName: "stop.fill").foregroundStyle(Color.chirp.record)
                }
                .disabled(!model.canToggle)
                .help(model.isPaused ? "Stop and finish the notes" : "Stop recording (⌘⇧R)")
                .accessibilityLabel("Stop notes")
            }
        } else {
            let shown = library.displayed(model)
            let continues = !shown.isBlank
            Button {
                if shown === model { model.onRecordToggle() } else { library.onContinue(shown.document.id) }
            } label: {
                Label {
                    Text(continues ? "Continue recording" : "Record")
                        .onGeometryChange(for: CGSize.self, of: \.size) { model.probe.recordLabel = $0 }
                } icon: {
                    Image(systemName: "record.circle").foregroundStyle(Color.chirp.record)
                }
                .labelStyle(.titleAndIcon)
            }
            .disabled(!model.canToggle)
            .help(continues ? "Continue recording into this note (⌘⇧R)" : "Start recording (⌘⇧R)")
            .accessibilityLabel(continues ? NotesLibraryText.continueRecording : "Start notes")
        }
    }
}

/// Pause (closes the microphone, keeps the notes open) or Resume.
private struct PauseButton: View {
    @Bindable var model: NotesModel

    var body: some View {
        Button(action: model.onPauseToggle) {
            Label(model.isPaused ? NotesStatus.resume : NotesStatus.pause, systemImage: model.isPaused ? "play.fill" : "pause.fill")
        }
        .disabled(!(model.isPaused || model.state == .recording))
        .help(model.isPaused ? "Resume recording into the same notes (⌘⇧P)" : "Pause: the microphone closes, the notes stay open (⌘⇧P)")
        .accessibilityLabel(model.isPaused ? "Resume notes" : "Pause notes")
    }
}

/// ✦ Smart notes: the switches that used to sit in the footer, and Organize.
struct SmartNotesMenu: View {
    @Bindable var model: NotesModel
    /// The recorder's model: the switches are the session's, whichever note is on screen.
    let recorder: NotesModel

    var body: some View {
        Menu {
            if !model.reorganizeHidden {
                Button(NotesStatus.organizeLabel + " Now", action: model.onReorganize).disabled(!model.canReorganize)
                Button("Restore Notes Before Organize…") { model.review() }.disabled(!model.canRestore)
                Divider()
            }
            // On while the model downloads, so switching it off cancels the download.
            Toggle(NotesStatus.speakerLabels, isOn: Binding(get: { recorder.speakerLabels },
                                                             set: { recorder.onSpeakerLabelsToggle($0) }))
                .disabled(recorder.state.isActive)
            Toggle("Structure notes", isOn: Binding(get: { recorder.structureEnabled },
                                                    set: { recorder.structureEnabled = $0; recorder.onStructureToggle($0) }))
                .disabled(!recorder.structuringAvailable && recorder.structuring != .off(.disabled))
            Toggle("Organize automatically", isOn: Binding(get: { recorder.autoReorganize && recorder.autoReorganizeAvailable },
                                                    set: { recorder.autoReorganize = $0; recorder.onAutoReorganizeToggle($0) }))
                .disabled(!recorder.autoReorganizeAvailable)
            if let status = recorder.speakerStatus {
                Divider()
                Text(status)
            }
        } label: {
            Label("Smart notes", systemImage: "sparkles")
                .foregroundStyle(Color.chirp.moon)
        }
        .help("Smart notes: Organize, speaker labels, structuring")
    }
}

/// Share/Export: Export Markdown… (with the "keep this file updated" option), Copy Markdown and the share sheet.
struct ShareMenu: View {
    let model: NotesModel

    var body: some View {
        Menu {
            Button(model.exportTitle, action: model.onSave).disabled(!model.canExport)
            Button("Copy Markdown", action: model.onCopy).disabled(!model.canExport)
            Divider()
            ShareLink(item: model.saveText) { Text("Share…") }.disabled(!model.canExport)
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .help("Share or export this note as Markdown")
    }
}

/// Edit by Voice: starts a spoken edit; while it listens (a check in the record colour), pressing it again ends it.
private struct VoiceEditButton: View {
    let model: NotesModel

    var body: some View {
        let listening = model.voiceEdit.isListening
        Button(action: model.onVoiceEdit) {
            Label("Edit by Voice", systemImage: listening ? "checkmark.circle.fill" : "mic.badge.plus")
                .foregroundStyle(listening ? AnyShapeStyle(Color.chirp.record) : AnyShapeStyle(.primary))
        }
        .disabled(!model.canVoiceEdit)
        .help(listening ? NotesStatus.voiceEditDoneHelp : NotesStatus.voiceEditHelp)
        .accessibilityLabel(listening ? NotesStatus.voiceEditDoneHelp : NotesStatus.voiceEditHelp)
    }
}

// MARK: empty state

/// No notes yet: the Chirp glyph in its rings, what Notes is for, the shortcut as keycaps, and New note / Record.
struct NotesEmptyState: View {
    let model: NotesModel
    let library: NotesLibraryModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.chirpTextScale) private var textScale

    var body: some View {
        GeometryReader { viewport in
        ScrollView {
        VStack(spacing: 0) {
            ZStack {
                ForEach(0..<3) { i in
                    Circle()
                        .strokeBorder(Color.chirp.koiDecor.opacity(0.34 - Double(i) * 0.1), lineWidth: 1.5)
                        .frame(width: 92 + CGFloat(i) * 40, height: 92 + CGFloat(i) * 40)
                }
                // The pale koi disc in light; in dark a raised surface disc (the dark koi container reads as a
                // muddy brown block at this size).
                Circle().fill(scheme == .dark ? Color.chirp.surfaceRaised : Color.chirp.koiContainer)
                    .frame(width: 84, height: 84)
                if let glyph = ChirpBrand.tinted(.chirp.koi, size: 50) {
                    Image(nsImage: glyph)
                } else {
                    Image(systemName: "note.text").pondFont(34, weight: .light).foregroundStyle(Color.chirp.koi)
                }
            }
            .frame(height: 180)
            .accessibilityHidden(true)
            Text(NotesLibraryText.emptyTitle)
                .pondFont(24, weight: .semibold, design: .serif)
                .foregroundStyle(NotesInk.primary)
                .padding(.top, 18)
            Text(NotesLibraryText.emptyBody)
                .pondFont(13)
                .foregroundStyle(NotesInk.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
                .padding(.top, 8)
            let hintLayout = textScale > 1.3 ? AnyLayout(VStackLayout(spacing: 8)) : AnyLayout(HStackLayout(spacing: 6))
            hintLayout {
                HStack(spacing: 6) { ForEach(KeycapRow.keys(model.notesKey), id: \.self) { NotesKeycap(key: $0) } }
                Text("starts a note from any app")
                    .pondFont(12)
                    .foregroundStyle(NotesInk.secondary)
                    .padding(.leading, 4)
            }
            .padding(.top, 18)
            HStack(spacing: 10) {
                Button {
                    library.onNew()
                    model.focusRequest += 1
                } label: {
                    Label("New Note", systemImage: "square.and.pencil").padding(.horizontal, 4)
                }
                .controlSize(.large)
                Button(action: model.onRecordToggle) {
                    Label("Record", systemImage: "record.circle").padding(.horizontal, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 24)
            Label(NotesLibraryText.emptyPrivacy, systemImage: "lock.fill")
                .pondFont(12)
                .foregroundStyle(NotesInk.tertiary)
                .padding(.top, 28)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
        .frame(minHeight: viewport.size.height)
        }
        }
        .pondFont(.callout)
        .background(Color.chirp.surface.ignoresSafeArea())
    }
}

/// The shortcut's modifiers and key, one keycap each ("⌃", "⌥", "N").
enum KeycapRow {
    static func keys(_ title: String) -> [String] {
        if ModifierKeys.isNamedTitle(title) { return [title] }   // "Right ⌥ Option" is one key
        let symbols = title.prefix { "⌃⌥⇧⌘".contains($0) }.map(String.init)
        let rest = title.dropFirst(symbols.count).trimmingCharacters(in: .whitespaces)
        return symbols + (rest.isEmpty ? [] : [String(rest.split(separator: " ").first ?? Substring(rest))])
    }
}

struct NotesKeycap: View {
    let key: String

    var body: some View {
        Text(key)
            .pondFont(12.5, weight: .medium, design: .rounded)
            .foregroundStyle(NotesInk.primary)
            .frame(minWidth: 24, minHeight: 24)
            .padding(.horizontal, key.count > 1 ? 6 : 0)
            .background(RoundedRectangle(cornerRadius: ChirpRadius.control).fill(Color.chirp.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: ChirpRadius.control).strokeBorder(NotesInk.tertiary.opacity(0.6)))
            .shadow(color: .black.opacity(0.12), radius: 0, y: 1)
    }
}

// MARK: toast

/// "Note deleted · Undo" for a few seconds at the bottom of the window.
struct NotesToastView: View {
    let library: NotesLibraryModel
    let toast: NotesToast

    var body: some View {
        HStack(spacing: 14) {
            Text(toast.text).pondFont(.callout).foregroundStyle(NotesInk.primary)
            if let id = toast.undo {
                Button("Undo") {
                    library.onRestore(id)
                    library.toast = nil
                }
                .buttonStyle(.plain)
                .pondFont(.callout, weight: .semibold)
                .foregroundStyle(Color.chirp.koi)
                .keyboardShortcut("z", modifiers: .command)
            }
            if let action = toast.action {
                Button(NotesRetranscribeText.showChanges) {
                    switch action {
                    case .transcript(let id): library.onShowTranscriptChanges(id)
                    case .rebuild(let id): library.onShowRebuild(id)
                    }
                }
                .buttonStyle(.plain)
                .pondFont(.callout, weight: .semibold)
                .foregroundStyle(Color.chirp.koi)
                Button("Undo") {
                    library.toast = nil
                    switch action {
                    case .transcript(let id): library.onRestoreTranscript(id)
                    case .rebuild(let id): library.onUndoRebuild(id)
                    }
                }
                .buttonStyle(.plain)
                .pondFont(.callout, weight: .semibold)
                .foregroundStyle(Color.chirp.koi)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Capsule().fill(Color.chirp.surfaceRaised))
        .overlay(Capsule().strokeBorder(NotesInk.tertiary.opacity(0.35)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(.bottom, 22)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task(id: toast.serial) {
            // Undo and Show Changes stay a little longer; afterwards the transcript inspector's ⋯ menu has them.
            try? await Task.sleep(for: .seconds(toast.action == nil ? 6 : 10))
            if !Task.isCancelled, library.toast?.serial == toast.serial { library.toast = nil }
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: banners

/// What went wrong, under the toolbar (the subtitle only says there is a problem).
struct ErrorBanner: View {
    let text: String
    /// A way to fix it, when there is one (the server or its token: Settings › Server).
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").pondFont(14).foregroundStyle(Color.chirp.record).accessibilityHidden(true)
            Text(text)
                .pondFont(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let action { Button(action.title, action: action.run).controlSize(.small) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.chirp.record.opacity(0.08))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: action == nil ? .combine : .contain)
    }
}

/// After every 2 h of recording, once: a reminder that the microphone is still open. It never stops anything itself.
private struct LongRunNotice: View {
    let model: NotesModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.badge.exclamationmark").foregroundStyle(Color.chirp.moon).accessibilityHidden(true)
            Text(NotesStatus.longRun(hours: model.longRunHours) + " — the microphone is still open.")
                .pondFont(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(NotesStatus.stopRecording, action: model.onRecordToggle).controlSize(.small)
            Button(NotesStatus.keepGoing) { model.keepGoing() }.controlSize(.small).keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.chirp.moonFill.opacity(0.12))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }
}

/// A session the legacy journal found at launch (clients without a library): Keep restores it as a stopped document.
private struct RecoveryBanner: View {
    @Bindable var model: NotesModel
    let offer: RecoveryOffer

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .pondFont(15)
                .foregroundStyle(Color.chirp.koi)
                .accessibilityHidden(true)
            Text(offer.text)
                .pondFont(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Keep", action: model.onRecoveryKeep)
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)
                .disabled(model.isBusy || model.state.isActive)
            Button("Save…", action: model.onRecoverySave)
                .controlSize(.small)
            Button("Discard", role: .destructive, action: model.onRecoveryDiscard)
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.chirp.koi.opacity(0.1))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }
}

/// Why structuring is off, above the editor (which stays editable).
private struct ExplanationBanner: View {
    @Bindable var model: NotesModel
    let text: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "text.badge.star")
                .pondFont(15)
                .foregroundStyle(Color.chirp.moon)
            Text(text)
                .pondFont(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if model.offersModels {
                Button("Manage Local Models…", action: model.onManageModels)
                    .controlSize(.small)
            }
            if let fix = model.serverFix {
                Button(fix.buttonTitle, action: model.onFixServer)
                    .controlSize(.small)
                    .disabled(model.serverFixMessage?.hasSuffix("…") == true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.chirp.moonFill.opacity(0.1))
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// The speaker model is on its way (or didn't arrive): one quiet line, never a prompt. Recording goes on without
/// labels meanwhile; they join once the model is ready.
private struct SpeakerModelBanner: View {
    @Bindable var model: NotesModel
    let notice: SpeakerModelNotice

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if notice.failed {
                Image(systemName: "exclamationmark.triangle.fill").pondFont(14).foregroundStyle(Color.chirp.moon).accessibilityHidden(true)
            } else {
                Image(systemName: "arrow.down.circle").pondFont(14).foregroundStyle(Color.chirp.moon).accessibilityHidden(true)
            }
            Text(notice.text)
                .pondFont(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if notice.failed { Button(NotesStatus.speakerRetry, action: model.onSpeakerRetry).controlSize(.small) }
            Button(NotesStatus.speakerTurnOff) { model.onSpeakerLabelsToggle(false) }.controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.chirp.moonFill.opacity(0.1))
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Speaker model")
    }
}

// MARK: under the notes

/// The retry note for appends, the reorganize note and the microphone warning, under the notes.
private struct NotesStatusLines: View {
    let model: NotesModel

    var body: some View {
        let notes = [model.micNote, model.retryNote, model.reorganizeNote, model.voiceEditNote].compactMap { $0 }
        if !notes.isEmpty || model.callNote != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let call = model.callNote { CallNoticeLine(model: model, text: call) }
                ForEach(notes, id: \.self) { note in
                    let success = note == model.reorganizeNote && model.reorganizeNoteIsSuccess
                    Label(note, systemImage: success ? "checkmark.circle" : note == model.micNote ? "mic.slash" : "arrow.clockwise")
                        .pondFont(.caption)
                        .foregroundStyle(success ? AnyShapeStyle(Color.chirp.lily) : AnyShapeStyle(Color.chirp.moon))
                }
            }
            .frame(maxWidth: NotesViewMetrics.readingWidth, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .task(id: model.voiceEdit) {
                // A voice edit's note goes after a while; the other notes stay until their state changes.
                guard model.voiceEditNote != nil else { return }
                try? await Task.sleep(for: .seconds(12))
                if !Task.isCancelled { model.onVoiceEditDismiss() }
            }
        }
    }
}

/// Speech not yet in the notes: the unstructured window text, then the live partial. Never editable.
private struct HearingStrip: View {
    let parts: [HearingPart]
    let text: String
    let paused: Bool
    @Environment(\.colorScheme) private var scheme

    /// The words, with each speaker's name in their colour where the speaker changes (labels on).
    private var line: Text {
        parts.enumerated().reduce(Text("")) { line, item in
            let (i, part) = item
            var run = Text(i == 0 ? "" : " ")
            if let name = part.name {
                run = run + Text(name + ": ").fontWeight(.semibold).foregroundColor(SpeakerPalette.color(part.color))
            }
            return line + run + Text(part.text)
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: paused ? "pause.circle" : "waveform")
                .pondFont(12, weight: .semibold)
                .foregroundStyle(Color.chirp.koi)
                .accessibilityHidden(true)
            Text(paused ? "Last heard" : "Hearing")
                .pondFont(.caption, weight: .semibold)
                .foregroundStyle(NotesInk.secondary)
            line
                .pondFont(13)
                .foregroundStyle(NotesInk.secondary)
                .lineLimit(2)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: NotesViewMetrics.readingWidth, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        // The pale koi container wash in light; in dark a light koi wash (the dark container reads muddy this wide).
        .background(scheme == .dark ? Color.chirp.koi.opacity(0.1) : Color.chirp.koiContainer.opacity(0.35))
        .overlay(alignment: .top) { Divider().opacity(0.6) }
        // Partials remain available on demand, without a changing sentence in the live region label.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(paused ? "Last heard before pausing" : "Live transcription")
        .accessibilityValue(text)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// The few facts that must stay visible but need no space of their own: where structuring sends the text, a kept
/// export, the speaker model, the debug-retention warning, and how far the notes lag.
private struct NotesMetaBar: View {
    @Bindable var model: NotesModel

    var body: some View {
        let keep = model.keepSaving.text
        let call = model.capturingCall || (model.sources.callAudio && model.callAudioAvailable && !model.state.isActive)
        if model.structuringHost != nil || keep != nil || model.debugRetention || model.speakerStatus != nil || model.lagText != nil || call {
            HStack(spacing: 10) {
                if call { SourcesChip(sources: model.sources) }
                if let lag = model.lagText { LagChip(model: model, text: lag) }
                if let host = model.structuringHost { StructuringChip(model: model, host: host) }
                if let keep {
                    Label(keep, systemImage: model.keepSaving.isSaving ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle")
                        .pondFont(.caption)
                        .foregroundStyle(model.keepSaving.isSaving ? AnyShapeStyle(NotesInk.secondary) : AnyShapeStyle(Color.chirp.moon))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let status = model.speakerStatus {
                    HStack(spacing: 4) {
                        Text(status)
                            .pondFont(.caption)
                            .foregroundStyle(NotesInk.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if model.debugRetention {
                    Text(MenuContent.debugRetention)
                        .pondFont(.caption, weight: .bold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.chirp.record))
                        .fixedSize()
                        .help(MenuContent.debugRetentionHelp)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .overlay(alignment: .top) { Divider().opacity(0.6) }
        }
    }
}

/// "Notes 1:20 behind": the notes lag the speech; a click shows what they have not caught up with yet.
private struct LagChip: View {
    @Bindable var model: NotesModel
    let text: String

    var body: some View {
        Button { model.showsBacklog.toggle() } label: {
            Label(text, systemImage: "hourglass")
                .pondFont(.caption, weight: .medium)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.chirp.moonFill.opacity(0.2)))
                .foregroundStyle(Color.chirp.moon)
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Speech the notes have not caught up with yet")
        .accessibilityHint("Shows the speech that is not in the notes yet")
        .popover(isPresented: $model.showsBacklog, arrowEdge: .top) {
            ScrollView {
                Text(model.hearingText)
                    .pondFont(13)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .frame(width: 380, height: 240)
        }
    }
}

/// "Structuring → llm.example.com": where the text goes when it leaves this Mac. Never truncated: the host is the
/// part that matters.
struct StructuringChip: View {
    let model: NotesModel
    let host: String

    var body: some View {
        Label(NotesStatus.structuringChip(host), systemImage: "arrow.up.forward.circle")
            .labelStyle(.titleAndIcon)
            .pondFont(.caption, weight: .medium)
            .foregroundStyle(Color.chirp.moon)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.chirp.moonFill.opacity(0.16)))
            .overlay(Capsule().strokeBorder(Color.chirp.moon.opacity(0.4)))
            .onGeometryChange(for: CGSize.self, of: \.size) { model.probe.structuringChip = $0 }
            .help("Structuring sends the notes text to \(host). Audio stays on the server you chose.")
    }
}

// MARK: chips over the notes

/// "Edited · Undo", for 20 s after a voice edit (or until the next edit or a click).
private struct EditedChip: View {
    let model: NotesModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "mic.badge.plus").pondFont(.caption).foregroundStyle(Color.chirp.moon)
            Text(NotesStatus.edited).pondFont(.caption, weight: .medium)
            Text("·").pondFont(.caption).foregroundStyle(NotesInk.secondary)
            Button {
                model.undoEdit()
                model.onVoiceEditDismiss()
            } label: {
                Text("Undo").pondFont(.caption, weight: .semibold)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.chirp.koi)
            .accessibilityLabel("Undo the spoken edit")
        }
        .modifier(ChipStyle())
        .task(id: model.voiceEdit) {
            try? await Task.sleep(for: .seconds(20))
            if !Task.isCancelled { model.onVoiceEditDismiss() }
        }
    }
}

/// "Organized · Show changes · Undo", for 20 s after a reorganize (or until the next edit or append).
private struct UndoChip: View {
    let model: NotesModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").pondFont(.caption).foregroundStyle(Color.chirp.moon)
            Text(NotesStatus.organized).pondFont(.caption, weight: .medium)
            Text("·").pondFont(.caption).foregroundStyle(NotesInk.secondary)
            if model.snapshots.latest != nil {
                Button {
                    model.review()
                } label: {
                    Text("Show changes").pondFont(.caption, weight: .semibold)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.chirp.koi)
                .accessibilityLabel("Show what organize changed")
                Text("·").pondFont(.caption).foregroundStyle(NotesInk.secondary)
            }
            Button {
                model.undoReorganize()
                model.dismissUndoChip()
            } label: {
                Text("Undo").pondFont(.caption, weight: .semibold)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.chirp.koi)
            .accessibilityLabel("Undo organize")
        }
        .modifier(ChipStyle())
        .task(id: model.reorganizeStatus) {
            try? await Task.sleep(for: .seconds(20))
            if !Task.isCancelled { model.dismissUndoChip() }
        }
    }
}

private struct UpdatingBadge: View {
    var body: some View {
        Label("Updating", systemImage: "sparkles")
            .pondFont(.caption, weight: .medium)
            .foregroundStyle(Color.chirp.moon)
            .modifier(ChipStyle())
    }
}

/// A small floating capsule over the notes (solid, so it reads over any text).
private struct ChipStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.chirp.surfaceRaised))
            .overlay(Capsule().strokeBorder(NotesInk.tertiary.opacity(0.3)))
            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
    }
}

/// The one-time tip about the tinted AI text (shown in a popover by the editor).
struct NotesTipView: View {
    var body: some View {
        Label(NotesStatus.tip, systemImage: "sparkles")
            .pondFont(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .padding(14)
            .frame(width: 280, alignment: .leading)
    }
}


/// View ▸ Read Formatted Note: the note without Markdown syntax (headings, bullets, emphasis), its tasks as standard
/// checkboxes that toggle through the editor's own edit and Undo path. The editable NSTextView keeps its native text,
/// offsets and selection; this sheet is a second, read-mostly presentation with its own accessibility tree.
struct NotesFormattedReader: View {
    let model: NotesModel
    let done: () -> Void

    enum Line: Equatable {
        case heading(String)
        case bullet(String, indent: Int)
        /// `toggle` is a UTF-16 offset inside the `[ ]` box, as the editor's task toggle expects.
        case task(String, checked: Bool, indent: Int, toggle: Int)
        case text(String)
    }

    static func lines(_ markdown: String) -> [Line] {
        var offset = 0
        return markdown.components(separatedBy: "\n").compactMap { line in
            defer { offset += line.utf16.count + 1 }
            if let prefix = NotesMarkdown.listPrefix(Substring(line)) {
                let rest = String(line.dropFirst(prefix.length))
                if let checked = prefix.box {
                    return .task(rest, checked: checked, indent: prefix.indent, toggle: offset + prefix.spaces + 3)
                }
                return .bullet(rest, indent: prefix.indent)
            }
            if let range = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                return .heading(String(line[range.upperBound...]))
            }
            return line.trimmingCharacters(in: .whitespaces).isEmpty ? nil : .text(line)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.displayTitle).pondFont(.title, weight: .semibold, design: .serif).accessibilityAddTraits(.isHeader)
                    ForEach(Array(Self.lines(model.document.text).enumerated()), id: \.offset) { _, line in
                        switch line {
                        case .heading(let text):
                            Text(.init(text)).pondFont(.section, weight: .semibold).padding(.top, 6).accessibilityAddTraits(.isHeader)
                        case .bullet(let text, let indent):
                            Label { Text(.init(text)) } icon: { Text("•").foregroundStyle(NotesInk.secondary) }
                                .pondFont(.body).padding(.leading, CGFloat(indent) * 20)
                        case .task(let text, let checked, let indent, let toggle):
                            Toggle(isOn: Binding(get: { checked }, set: { _ in _ = model.toggleAccessibleTask(toggle) })) {
                                Text(.init(text))
                            }
                            .toggleStyle(.checkbox)
                            .pondFont(.body)
                            .padding(.leading, CGFloat(indent) * 20)
                        case .text(let text):
                            Text(.init(text)).pondFont(.body)
                        }
                    }
                }
                .textSelection(.enabled)
                .foregroundStyle(NotesInk.primary)
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Text("Tasks you tick here change the note; ⌘Z in the note undoes them.").pondFont(.meta).foregroundStyle(NotesInk.secondary)
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 520, idealWidth: 640, minHeight: 360, idealHeight: 520)
        .background(Color.chirp.surface)
    }
}
