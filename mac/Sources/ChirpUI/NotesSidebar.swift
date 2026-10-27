import ChirpCore
import SwiftUI

/// The library sidebar: the pinned Recording section, the notes by date (or the search results), and Recently Deleted
/// at the bottom. Return renames the selected row inline; ⌫ moves it to Recently Deleted (with Undo).
struct NotesSidebar: View {
    @Bindable var model: NotesModel
    @Bindable var library: NotesLibraryModel
    @Environment(\.undoManager) private var undoManager

    /// The recorder's note while the library has not kept it yet (a new note, or one not written yet), so the list
    /// shows what the detail shows.
    private var pending: NotesLibraryEntry? {
        let d = model.document
        guard library.selection == .note(d.id), library.entry(d.id) == nil, !(model.isBlank && library.isEmpty) else { return nil }
        return NotesLibraryEntry(id: d.id, title: model.displayTitle, snippet: d.snippet(), openTodos: d.openTodoCount(),
                                 createdAt: d.createdAt, updatedAt: d.updatedAt, duration: model.elapsed)
    }

    private var recordingEntry: NotesLibraryEntry? {
        guard let id = library.recordingID else { return nil }
        let d = model.document
        let kept = library.entry(id)
        return NotesLibraryEntry(id: id, title: id == d.id ? model.displayTitle : kept?.title ?? NotesLibraryText.untitled,
                                 snippet: id == d.id ? d.snippet() : kept?.snippet ?? "", openTodos: kept?.openTodos ?? 0,
                                 createdAt: kept?.createdAt ?? d.createdAt, updatedAt: kept?.updatedAt ?? d.updatedAt,
                                 duration: model.elapsed, recording: true)
    }

    var body: some View {
        List(selection: Binding(get: { library.selection }, set: { library.select($0) })) {
            if let results = library.results {
                if !results.isEmpty {
                    Section {
                        ForEach(results) { result in
                            row(result.entry, highlight: result)
                        }
                    } header: {
                        SidebarHeader(title: NotesLibraryText.results(results.count))
                    }
                }
            } else {
                if let recording = recordingEntry {
                    Section {
                        RecordingRow(model: model, entry: recording, selected: library.selection == .note(recording.id))
                            .tag(NotesSidebarItem.note(recording.id))
                            .listRowBackground(SelectionBackground(selected: library.selection == .note(recording.id), focused: library.sidebarFocused))
                    } header: {
                        SidebarHeader(title: model.isPaused ? NotesStatus.paused : NotesLibraryText.recording)
                    }
                }
                ForEach(library.groups(pending: pending)) { group in
                    Section {
                        ForEach(group.entries) { row($0, highlight: nil) }
                    } header: {
                        SidebarHeader(title: group.title)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .background(SidebarFocusObserver(library: library))
        .scrollContentBackground(.hidden)
        .overlay { overlay }
        .onDeleteCommand { trashSelection() }
        .onKeyPress(.return) {
            guard library.renaming == nil, let id = library.selection?.noteID, library.entry(id) != nil else { return .ignored }
            library.beginRename(id)
            return .handled
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { RecentlyDeletedButton(library: library) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    library.onNew()
                } label: {
                    Label(NotesLibraryText.newNote, systemImage: "square.and.pencil")
                }
                .help("New note (⌘N)")
            }
        }
    }

    @ViewBuilder private var overlay: some View {
        if let results = library.results, results.isEmpty {
            SidebarMessage(symbol: "magnifyingglass", title: NotesLibraryText.noResults(library.query),
                           detail: "Search looks through titles, notes and transcripts.")
        } else if library.results == nil, library.isEmpty, pending == nil {
            SidebarMessage(symbol: "note.text", title: "No notes yet", detail: nil)
        }
    }

    private func row(_ entry: NotesLibraryEntry, highlight: NotesSearchResult?) -> some View {
        NoteRow(entry: entry, library: library, highlight: highlight,
                renaming: Binding(get: { library.renaming == entry.id }, set: { if !$0 { library.renaming = nil } }),
                selected: library.selection == .note(entry.id))
            .tag(NotesSidebarItem.note(entry.id))
            .listRowBackground(SelectionBackground(selected: library.selection == .note(entry.id), focused: library.sidebarFocused))
            .contextMenu { menu(entry) }
    }

    @ViewBuilder private func menu(_ entry: NotesLibraryEntry) -> some View {
        Button("Rename") { library.beginRename(entry.id) }
        if entry.id != library.recordingID {
            Button(NotesLibraryText.continueRecording) { library.onContinue(entry.id) }
                .disabled(library.isRetranscribing(entry.id))
        }
        if library.retranscribeAllowed, entry.hasAudio, entry.id != library.recordingID, library.retranscribeRun == nil {
            Button(NotesRetranscribeText.action) { library.onRetranscribe(entry.id, nil) }
        }
        if library.displayed(model).document.id == entry.id, library.canRestoreTranscript(library.displayed(model)) {
            Button(NotesRetranscribeText.restore) { library.onRestoreTranscript(entry.id) }
        }
        Divider()
        Button("Delete", role: .destructive) { trash(entry.id) }
            .disabled(!library.canTrash(entry.id))
    }

    private func trashSelection() {
        guard let id = library.selection?.noteID else { return }
        trash(id)
    }

    /// Recently Deleted, the toast's Undo and ⌘Z (the window's undo manager, while the list has the keyboard).
    private func trash(_ id: UUID) {
        guard library.canTrash(id) else { NSSound.beep(); return }
        library.onTrash(id)
        undoManager?.registerUndo(withTarget: library) { $0.onRestore(id); $0.toast = nil }
        undoManager?.setActionName("Delete Note")
    }
}

/// A library section header: the serif, sentence case (never all caps).
private struct SidebarHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .pondFont(12.5, weight: .semibold, design: .serif)
            .foregroundStyle(NotesInk.secondary)
            .textCase(nil)
            .padding(.top, 4)
    }
}

/// Selected library rows use the Pond koi container in both appearances.
struct SelectionBackground: View {
    let selected: Bool
    var focused = false

    var body: some View {
        RoundedRectangle(cornerRadius: ChirpRadius.row)
            .fill(selected ? Color.chirp.koiContainer : .clear)
            .overlay(RoundedRectangle(cornerRadius: ChirpRadius.row)
                .strokeBorder(selected && focused ? Color.chirp.koi : .clear, lineWidth: 2))
            .padding(.horizontal, 10)
    }
}

/// Selected dark rows use the container's warm ink, with quieter snippet and metadata text.
struct RowInk {
    /// How much pond ink the snippet and meta keep on the pill (the theme tests check their contrast).
    static let snippetOnPill: Double = 0.78
    static let metaOnPill: Double = 0.85

    let selected: Bool
    let scheme: ColorScheme

    init(selected: Bool, scheme: ColorScheme) {
        self.selected = selected
        self.scheme = scheme
    }

    var onPill: Bool { selected && scheme == .dark }
    var title: Color { onPill ? Color.chirp.onKoiContainer : NotesInk.primary }
    var snippet: Color { onPill ? Color.chirp.onKoiContainer.opacity(Self.snippetOnPill) : NotesInk.secondary }
    var meta: Color { onPill ? Color.chirp.onKoiContainer.opacity(Self.metaOnPill) : NotesInk.secondary }
    /// The record-coloured marks (the timer, the dot): pond ink while they sit on the pill.
    var mark: Color { onPill ? Color.chirp.onKoiContainer : Color.chirp.record }
}

/// A note in the list: serif title and time, a two-line snippet, and the meta line (duration, open to-dos).
private struct NoteRow: View {
    let entry: NotesLibraryEntry
    @Bindable var library: NotesLibraryModel
    let highlight: NotesSearchResult?
    @Binding var renaming: Bool
    let selected: Bool
    @Environment(\.colorScheme) private var scheme

    private var ink: RowInk { RowInk(selected: selected, scheme: scheme) }

    @Environment(\.chirpTextScale) private var textScale

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            let headingLayout = textScale > 1.3 ? AnyLayout(VStackLayout(alignment: .leading, spacing: 3)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
            headingLayout {
                if renaming {
                    TextField("Title", text: $library.renameText)
                        .textFieldStyle(.roundedBorder)
                        .pondFont(13.5, weight: .semibold, design: .serif)
                        .onSubmit { library.commitRename() }
                        .onExitCommand { library.renaming = nil }
                } else {
                    Text(entry.title)
                        .pondFont(14, weight: .semibold, design: .serif)
                        .foregroundStyle(ink.title)
                        .lineLimit(1)
                }
                if textScale <= 1.3 { Spacer(minLength: 4) }
                Text(NotesLibraryText.relative(entry.updatedAt, now: library.now(), calendar: library.calendar))
                    .pondFont(12)
                    .foregroundStyle(ink.snippet)
                    .lineLimit(1)
                    .fixedSize()
            }
            snippet
                .pondFont(12)
                .foregroundStyle(ink.snippet)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            MetaLine(entry: entry, ink: ink,
                     progress: library.retranscribeRun.flatMap { $0.note == entry.id && $0.failure == nil ? $0.progress.fraction : nil })
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var snippet: some View {
        if let highlight, !highlight.matches.isEmpty {
            Text(Self.highlighted(highlight))
        } else if entry.snippet.isEmpty {
            Text("No additional text").foregroundStyle(NotesInk.tertiary)
        } else {
            Text(NotesLibraryText.plain(entry.snippet))
        }
    }

    /// The snippet with every match in koi on its container tint.
    static func highlighted(_ result: NotesSearchResult) -> AttributedString {
        // Newlines become spaces one for one, so the UTF-16 match ranges still line up.
        let text = result.snippet.replacingOccurrences(of: "\n", with: " ")
        var out = AttributedString(text)
        let ns = text as NSString
        for match in result.matches where NSMaxRange(match) <= ns.length {
            guard let range = Range(match, in: text), let lower = AttributedString.Index(range.lowerBound, within: out),
                  let upper = AttributedString.Index(range.upperBound, within: out) else { continue }
            out[lower..<upper].foregroundColor = Color.chirp.onKoiContainer
            out[lower..<upper].backgroundColor = Color.chirp.koiContainer
            out[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return out
    }
}

/// "12 min · ☐ 3 open · Recovered".
private struct MetaLine: View {
    let entry: NotesLibraryEntry
    let ink: RowInk
    /// A re-transcribe runs on this note: a small ring in place of the audio glyph.
    var progress: Double?

    var body: some View {
        if NotesLibraryText.duration(entry.duration) != nil || entry.openTodos > 0 || entry.recovered || entry.hasAudio {
            // One line while it fits; enlarged text wraps the facts instead of clipping them.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { facts }
                VStack(alignment: .leading, spacing: 4) { facts }
            }
            .labelStyle(MetaLabelStyle())
            .pondFont(12)
            .foregroundStyle(ink.meta)
            .padding(.top, 1)
        }
    }

    @ViewBuilder private var facts: some View {
        let length = NotesLibraryText.duration(entry.duration)
        if let length, let progress {
            Label {
                Text(length)
            } icon: {
                ProgressRing(value: progress, color: ink.meta).frame(width: 10, height: 10)
            }
            .accessibilityLabel("\(length), re-transcribing")
        } else if let length {
            Label(length, systemImage: entry.hasAudio ? "waveform" : "mic")
        }
        if entry.openTodos > 0 {
            Label(NotesLibraryText.open(entry.openTodos), systemImage: "square")
        }
        if entry.recovered { RecoveredBadge(onPill: ink.onPill) }
    }
}

private struct MetaLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// The pinned Recording row: the Ripple, the live timer and the frozen preview of what it holds so far.
private struct RecordingRow: View {
    let model: NotesModel
    let entry: NotesLibraryEntry
    let selected: Bool
    @Environment(\.colorScheme) private var scheme

    private var ink: RowInk { RowInk(selected: selected, scheme: scheme) }

    @Environment(\.chirpTextScale) private var textScale

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                if model.isPaused {
                    Image(systemName: "pause.fill").pondFont(12, weight: .bold).foregroundStyle(ink.snippet)
                } else {
                    Ripple(level: Double(model.level), reduceMotion: model.reduceMotion, phase: model.ripplePhase,
                           color: ink.onPill ? .chirp.onKoiContainer : .chirp.koiDecor,
                           staticColor: ink.onPill ? .chirp.onKoiContainer : .chirp.koi, side: 30)
                    Circle().fill(ink.mark).frame(width: 9, height: 9)
                }
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 3) {
                // Over 130% the timer drops under the title, which keeps the row's width for the title.
                let headingLayout = textScale > 1.3 ? AnyLayout(VStackLayout(alignment: .leading, spacing: 3)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
                headingLayout {
                    Text(entry.title)
                        .pondFont(14, weight: .semibold, design: .serif)
                        .foregroundStyle(ink.title)
                        .lineLimit(1)
                    if textScale <= 1.3 { Spacer(minLength: 4) }
                    Text(model.elapsedText)
                        .pondFont(12, weight: .semibold, digits: true)
                        .foregroundStyle(model.isPaused ? ink.snippet : ink.mark)
                }
                Text(entry.snippet.isEmpty ? (model.isPaused ? NotesStatus.paused : NotesStatus.listening) : NotesLibraryText.plain(entry.snippet))
                    .pondFont(12)
                    .foregroundStyle(ink.snippet)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.isPaused ? "Paused" : "Recording"): \(entry.title), \(model.elapsedText)")
    }
}

/// Recently Deleted, pinned at the bottom of the sidebar with its count.
private struct RecentlyDeletedButton: View {
    let library: NotesLibraryModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let selected = library.selection == .recentlyDeleted
        let ink = RowInk(selected: selected, scheme: scheme)
        Button {
            library.select(.recentlyDeleted)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "trash").foregroundStyle(ink.onPill ? Color.chirp.onKoiContainer : (selected ? Color.chirp.koi : NotesInk.secondary))
                Text(NotesLibraryText.recentlyDeleted).foregroundStyle(ink.title)
                Spacer()
                if !library.deleted.isEmpty {
                    Text("\(library.deleted.count)").pondFont(12, digits: true).foregroundStyle(ink.snippet)
                }
            }
            .pondFont(13)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(SelectionBackground(selected: selected).padding(.horizontal, -10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(alignment: .top) { Divider().padding(.horizontal, 12) }
        .accessibilityLabel("\(NotesLibraryText.recentlyDeleted), \(library.deleted.count) notes")
    }
}

/// A message in the middle of the list (no notes yet, no results).
private struct SidebarMessage: View {
    let symbol: String
    let title: String
    let detail: String?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).pondFont(22, weight: .light).foregroundStyle(NotesInk.tertiary)
            Text(title).pondFont(13, weight: .semibold).foregroundStyle(NotesInk.secondary).multilineTextAlignment(.center)
            if let detail {
                Text(detail).pondFont(12).foregroundStyle(NotesInk.tertiary).multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

// MARK: Recently Deleted

/// The detail for Recently Deleted: each note with its days left, Restore and Delete Now, and Empty.
struct RecentlyDeletedView: View {
    @Bindable var library: NotesLibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(NotesLibraryText.recentlyDeleted).pondFont(26, weight: .semibold, design: .serif).foregroundStyle(NotesInk.primary)
                    Text(NotesLibraryText.trashHelp).pondFont(.meta).foregroundStyle(NotesInk.secondary)
                }
                Spacer()
                Button("Empty…") { library.confirmingEmpty = true }
                    .disabled(library.deleted.isEmpty)
                    .help(NotesLibraryText.emptyTrash)
            }
            .padding(.bottom, 18)
            if library.deleted.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "trash").pondFont(30, weight: .light).foregroundStyle(NotesInk.tertiary)
                    Text(NotesLibraryText.trashEmpty).pondFont(.callout).foregroundStyle(NotesInk.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(library.deleted) { entry in DeletedRow(entry: entry, library: library) }
                    }
                }
            }
        }
        .frame(maxWidth: NotesViewMetrics.readingWidth, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.top, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.chirp.surface.ignoresSafeArea())
    }
}

private struct DeletedRow: View {
    let entry: NotesLibraryEntry
    let library: NotesLibraryModel

    @Environment(\.chirpTextScale) private var textScale

    var body: some View {
        let layout = textScale > 1.3 ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
        layout {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title).pondFont(14, weight: .semibold, design: .serif).foregroundStyle(NotesInk.primary).lineLimit(1)
                Text(entry.snippet.isEmpty ? "No additional text" : NotesLibraryText.plain(entry.snippet))
                    .pondFont(12).foregroundStyle(NotesInk.secondary).lineLimit(1)
                if let deletedAt = entry.deletedAt {
                    Text(NotesLibraryText.daysLeft(deletedAt: deletedAt, now: library.now()))
                        .pondFont(12).foregroundStyle(NotesInk.tertiary)
                }
            }
            if textScale <= 1.3 { Spacer(minLength: 8) }
            HStack(spacing: 10) {
            Button("Restore") { library.onRestore(entry.id) }
            Button("Delete Now", role: .destructive) { library.requestPurge(entry.id) }
                .foregroundStyle(Color.chirp.record)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: ChirpRadius.row).fill(Color.chirp.surfaceRaised.opacity(0.7)))
    }
}

/// A small determinate ring (a library row's re-transcribe progress).
private struct ProgressRing: View {
    let value: Double
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.3), lineWidth: 1.6)
            Circle().trim(from: 0, to: max(0.04, min(1, value)))
                .stroke(Color.chirp.koi, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}


/// Observe AppKit's actual first responder; selection alone is not keyboard focus.
private struct SidebarFocusObserver: NSViewRepresentable {
    let library: NotesLibraryModel
    func makeNSView(context: Context) -> SidebarFocusView { SidebarFocusView(library: library) }
    func updateNSView(_ view: SidebarFocusView, context: Context) { view.refresh() }
}
private final class SidebarFocusView: NSView {
    let library: NotesLibraryModel
    init(library: NotesLibraryModel) { self.library = library; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("not used") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self)
        if let window {
            for name in [NSWindow.didUpdateNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: name, object: window)
            }
        }
        refresh()
    }
    @objc func refresh() {
        var responder = window?.firstResponder
        var inList = false
        while let current = responder {
            if current is NSTableView { inList = true; break }
            responder = current.nextResponder
        }
        let focused = window?.isKeyWindow == true && inList
        guard library.sidebarFocused != focused else { return }
        DispatchQueue.main.async { [weak self] in self?.library.sidebarFocused = focused }
    }
    deinit { NotificationCenter.default.removeObserver(self) }
}
