import AVFAudio
import ChirpCore
import ChirpIOSCore
import SwiftUI

/// The Notes tab's complete navigation surface. The app shell only needs LiveNotesView's existing initializer.
struct NotesLibraryView: View {
    @ObservedObject var notes: LiveNotesController
    @ObservedObject var session: SessionCoordinator
    var pair: () -> Void
    var dictate: () -> Void = {}
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("chirp.setupCard.dismissed") private var setupDismissed = false
    @State private var microphone = AVAudioApplication.shared.recordPermission == .granted
    @SceneStorage("chirp.notes.selection") private var selectedID = ""
    @SceneStorage("chirp.notes.search") private var query = ""
    @SceneStorage("chirp.notes.scroll") private var scrollID = ""
    @State private var results: [NotesSearchResult] = []
    @State private var revision = 0
    @State private var deleted = false
    @State private var confirmRecording = false
    @State private var share: NoteShare?
    @State private var settings = false
    @State private var selecting = false
    @State private var selection = Set<UUID>()
    @State private var visibleRows = Set<UUID>()
    @FocusState private var searchFocused: Bool

    var body: some View {
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    libraryList.navigationSplitViewColumnWidth(min: 320, ideal: 350, max: 380)
                } detail: {
                    if !selectedID.isEmpty { detail }
                    else { NotesEmptyView(title: "A little room to think", message: "Choose a note, or start a new one.") }
                }.navigationSplitViewStyle(.balanced)
            } else {
                NavigationStack {
                    libraryList
                        .navigationDestination(isPresented: Binding(get: { !selectedID.isEmpty }, set: { if !$0 { selectedID = "" } })) { detail }
                }
            }
        }
        .tint(Color.chirp.koi)
        .sheet(item: $share) { share in NotesShareSheet(text: share.text) }
        .confirmationDialog("Another note is recording", isPresented: $confirmRecording, titleVisibility: .visible) {
            Button("Stop current and record") { Task { await notes.stop(); await startRecording() } }
            Button("Go to recording") { if let id = notes.recordingID { Task { await open(id) } } }
        }
        .sheet(isPresented: $deleted) { NavigationStack { RecentlyDeletedView(notes: notes) } }
        .sheet(isPresented: $settings) { NotesSettingsSheet(notes: notes) }
        .task {
            await notes.ready()
            if let requested = notes.requestedSelection { await open(requested); notes.didNavigateToNote() }
            else if let id = UUID(uuidString: selectedID), notes.entries.contains(where: { $0.id == id }) { await notes.open(id) }
            else { selectedID = "" }
            await notes.refreshHealth()
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { microphone = AVAudioApplication.shared.recordPermission == .granted } }
        .onChange(of: notes.requestedSelection) { _, id in
            if let id { Task { await open(id); notes.didNavigateToNote() } }
        }
        .onChange(of: notes.entries) { _, _ in revision += 1 }
        .task(id: query + String(revision)) {
            guard let library = notes.library else { return }
            do {
                let found = try await library.search(query)
                guard !Task.isCancelled else { return }
                results = found
            } catch { results = [] }
        }
    }

    private var detail: some View {
        NoteDetailView(notes: notes, session: session, pair: pair, openRecording: {
            if let id = notes.recordingID { Task { await open(id) } }
        }, deleted: { selectedID = "" })
    }

    private var libraryList: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    Text("Notes").font(ChirpType.noteTitle).foregroundStyle(Color.chirp.ink)
                        .accessibilityAddTraits(.isHeader).listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                }
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !setupDismissed, !SetupProgress(model: session, microphone: microphone).isComplete {
                    Section {
                        SetupCard(progress: SetupProgress(model: session, microphone: microphone), fix: fixSetup,
                                  dismiss: { setupDismissed = true })
                            .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                    }
                }
                if !notes.preferences.keepNotes {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Keep your notes here").font(.headline)
                            Text("New notes are not being kept on this device.").font(.subheadline)
                            Button("Enable notes library") { notes.setKeepNotes(true) }.buttonStyle(.bordered)
                        }.padding(4)
                    }.listRowBackground(Color.chirp.koiContainer)
                }
                if notes.preferences.libraryUpgradeNotice {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Notes are now kept on this device. Turn off in Settings → Notes.").font(.subheadline)
                            Button("Got it") { notes.dismissUpgradeNotice() }
                        }
                    }.listRowBackground(Color.chirp.surface)
                }
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if let id = notes.recordingID {
                        Section {
                            Button { Task { await open(id) } } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Ripple(level: 0.25).frame(width: 36, height: 36)
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(notes.recordingTitle).font(.system(.headline, design: .serif)).foregroundStyle(Color.chirp.ink)
                                        Text(clock(notes.recordingElapsed)).font(ChirpType.timer()).foregroundStyle(Color.chirp.record)
                                        Text(notes.recordingPreview.isEmpty ? "Listening…" : notes.recordingPreview)
                                            .font(.subheadline).foregroundStyle(Color.chirp.inkMuted).lineLimit(2)
                                    }
                                }.padding(.vertical, 8)
                            }.accessibilityElement(children: .combine).accessibilityLabel("Recording, \(notes.recordingTitle), \(Int(notes.recordingElapsed)) seconds")
                                .accessibilityIdentifier("chirp.notes.recordingRow").listRowBackground(Color.chirp.surface)
                        } header: { sectionHeader("Recording") }
                    }
                    ForEach(groups, id: \.title) { group in
                        Section {
                            ForEach(group.entries) { entry in libraryRow(entry, snippet: entry.snippet) }
                        } header: { sectionHeader(group.title) }
                    }
                    if notes.entries.isEmpty && notes.recordingID == nil {
                        Section {
                            NotesEmptyView(title: "Your notes will live here", message: "Tap New note to type, or Record to turn a conversation into notes.", privacy: true)
                                .listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
                        }
                    }
                } else {
                    Section {
                        if results.isEmpty {
                            ContentUnavailableView.search(text: query).listRowBackground(Color.clear)
                                .accessibilityIdentifier("chirp.notes.noResults")
                        }
                        ForEach(results) { result in libraryRow(result.entry, snippet: result.snippet) }
                    } header: { sectionHeader(results.count == 1 ? "1 note" : "\(results.count) notes") }
                }
                Section {
                    Button { deleted = true } label: { Label("Recently Deleted", systemImage: "trash") }
                        .foregroundStyle(Color.chirp.inkMuted).accessibilityIdentifier("chirp.notes.deleted")
                }.listRowBackground(Color.chirp.surface)
            }
            .accessibilityIdentifier("chirp.notes.library")
            .listStyle(.insetGrouped).scrollContentBackground(.hidden).background(Color.chirp.background)
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search notes").searchFocused($searchFocused)
            // ⌘F still focuses the docked field; the toolbar magnifier that duplicated it is gone (#271 2.6).
            .background {
                Button("Search notes") { searchFocused = true }.keyboardShortcut("f", modifiers: .command)
                    .opacity(0).accessibilityHidden(true)
            }
            .onSubmit(of: .search) { searchFocused = false }
            .toolbar { libraryToolbar }
            .safeAreaInset(edge: .bottom) { libraryDock }
            .onAppear { if !scrollID.isEmpty { proxy.scrollTo(scrollID, anchor: .top) } }
            .onKeyPress(keys: [.upArrow, .downArrow]) { key in
                guard !searchFocused else { return .ignored }
                let entries = query.isEmpty ? notes.entries : results.map(\.entry)
                guard !entries.isEmpty else { return .ignored }
                let current = entries.firstIndex { $0.id.uuidString == selectedID } ?? (key.key == .downArrow ? -1 : entries.count)
                let next = min(max(current + (key.key == .downArrow ? 1 : -1), 0), entries.count - 1)
                Task { await open(entries[next].id) }
                return .handled
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title).font(ChirpType.sectionHeader).foregroundStyle(Color.chirp.inkMuted).textCase(nil)
    }

    private func libraryRow(_ entry: NotesLibraryEntry, snippet: String) -> some View {
        Button {
            if selecting {
                if selection.contains(entry.id) { selection.remove(entry.id) } else { selection.insert(entry.id) }
            } else { Task { await open(entry.id) } }
        } label: {
            HStack(alignment: .top, spacing: 12) {
                if selecting { Image(systemName: selection.contains(entry.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(Color.chirp.koi) }
                VStack(alignment: .leading, spacing: 8) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) { rowTitle(entry); Spacer(minLength: 0); rowAge(entry) }
                        VStack(alignment: .leading, spacing: 4) { rowTitle(entry); rowAge(entry) }
                    }
                    Text(highlight(snippet)).font(.subheadline).foregroundStyle(Color.chirp.inkMuted).lineLimit(2)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { metadata(entry) }
                        VStack(alignment: .leading, spacing: 4) { metadata(entry) }
                    }.font(ChirpType.meta).foregroundStyle(Color.chirp.inkMuted)
                }
            }.padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .listRowBackground(selectedID == entry.id.uuidString ? Color.chirp.koiContainer : .chirp.surface)
            .listRowSeparator(.hidden).listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .id(entry.id.uuidString)
            .onScrollVisibilityChange(threshold: 0.5) { visible in
                if visible { visibleRows.insert(entry.id) } else { visibleRows.remove(entry.id) }
                let ordered = query.isEmpty ? notes.entries : results.map(\.entry)
                if let first = ordered.first(where: { visibleRows.contains($0.id) }) { scrollID = first.id.uuidString }
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("chirp.notes.row.\(entry.id.uuidString)")
            .accessibilityAction(named: "Delete") { Task { await notes.delete([entry.id]) } }
            .accessibilityAction(named: "Select") { selecting = true; selection.insert(entry.id) }
            .swipeActions { if entry.id != notes.recordingID { Button("Delete", role: .destructive) { Task { await notes.delete([entry.id]) } }.tint(Color.chirp.record) } }
            .contextMenu {
                Button("Copy", systemImage: "doc.on.doc") { Task { if let record = try? await notes.library?.record(entry.id) { UIPasteboard.general.string = record.document.exportMarkdown() } } }
                Button("Share", systemImage: "square.and.arrow.up") {
                    Task { if let record = try? await notes.library?.record(entry.id) { share = NoteShare(text: record.document.exportMarkdown()) } }
                }
                Button("Delete", systemImage: "trash", role: .destructive) { Task { await notes.delete([entry.id]) } }.disabled(entry.id == notes.recordingID)
            }
    }

    private func rowTitle(_ entry: NotesLibraryEntry) -> some View {
        Text(highlight(entry.title)).font(.system(.headline, design: .serif)).foregroundStyle(Color.chirp.ink)
    }

    /// "Just now", "5 min ago", "Yesterday": refreshed each minute.
    private func rowAge(_ entry: NotesLibraryEntry) -> some View {
        TimelineView(.everyMinute) { context in
            Text(NoteMeta.age(since: entry.updatedAt, now: context.date)).font(.subheadline).foregroundStyle(Color.chirp.inkMuted)
        }.fixedSize()
    }

    /// "3 min · ☐ 2 open", then Recovered and the kept-audio mark (#271 2.4).
    @ViewBuilder private func metadata(_ entry: NotesLibraryEntry) -> some View {
        if let length = NoteMeta.duration(entry.duration) { Text(length).monospacedDigit() }
        if entry.duration >= 1, entry.openTodos > 0 { Text("·").accessibilityHidden(true) }
        if entry.openTodos > 0 { Text("☐ " + NoteMeta.open(entry.openTodos)) }
        if entry.recovered { Text("Recovered").foregroundStyle(Color.chirp.moon) }
        if let run = notes.retranscribeRun, run.note == entry.id, run.failure == nil {
            ProgressView(value: run.progress.fraction).progressViewStyle(.circular).controlSize(.mini)
                .accessibilityLabel("Re-transcribing, \(run.progress.done) of \(run.progress.total)")
        } else if entry.hasAudio { Image(systemName: "waveform").accessibilityLabel("Audio kept") }
    }

    private var libraryDock: some View {
        VStack(spacing: 8) {
            if !notes.undoDeleted.isEmpty {
                HStack {
                    Text(notes.undoDeleted.count == 1 ? "Note deleted" : "Notes deleted")
                    Spacer()
                    Button("Undo") { Task { await notes.restore(notes.undoDeleted) } }.accessibilityIdentifier("chirp.notes.delete.undo")
                }.font(.subheadline).padding().background(Color.chirp.surface, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityElement(children: .contain)
            }
            HStack(spacing: 12) {
                if selecting {
                    Button("Delete selected", systemImage: "trash") {
                        Task { await notes.delete(Array(selection)); selection = []; selecting = false }
                    }.disabled(selection.isEmpty).tint(Color.chirp.record).buttonStyle(.bordered)
                }
                Spacer()
                // New note types a note here, with no computer or microphone, and never stops a recording (A2-7).
                Button { Task { await newNote() } } label: { Image(systemName: "square.and.pencil").frame(minWidth: 44, minHeight: 44) }
                    .buttonStyle(.bordered).buttonBorderShape(.circle).accessibilityLabel("New note")
                    .keyboardShortcut("n", modifiers: .command)
                    .accessibilityShowsLargeContentViewer().accessibilityIdentifier("chirp.notes.new")
                Button(action: dictate) { Image(systemName: "mic").frame(minWidth: 44, minHeight: 44) }
                    .buttonStyle(.bordered).buttonBorderShape(.circle).accessibilityLabel("Dictate")
                    .accessibilityShowsLargeContentViewer()
                Button { if notes.isActive { confirmRecording = true } else { Task { await startRecording() } } } label: {
                    Label("Record", systemImage: "record.circle").font(.headline).padding(.vertical, 8).lineLimit(1)
                }.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(Color.chirp.koi)
                    // ⇧⌘R records from the library; with a note open, its own Record / Stop owns the shortcut.
                    .foregroundStyle(Color.chirp.onKoi).keyboardShortcut(selectedID.isEmpty ? KeyboardShortcut("r", modifiers: [.command, .shift]) : nil)
                    .accessibilityShowsLargeContentViewer()
                    .accessibilityIdentifier("chirp.notes.record")
            }
        }
        // Like the tab bar, the dock stops growing at accessibility sizes and shows the Large Content Viewer on a long
        // press instead; at AX5 the mic and Record otherwise overlap and the dock hides the list (#271 L2).
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .padding(.horizontal, 16).padding(.vertical, 12).background(.ultraThinMaterial)
    }

    @ToolbarContentBuilder private var libraryToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            ConnectionChip(model: session, open: pair)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button("Recently Deleted", systemImage: "trash") { deleted = true }.accessibilityIdentifier("chirp.notes.deleted.menu")
                Button(selecting ? "Done selecting" : "Select", systemImage: "checkmark.circle") { selecting.toggle(); selection = [] }
                Button("Notes settings", systemImage: "gearshape") { settings = true }.accessibilityIdentifier("chirp.notes.settings")
            } label: { Label("More", systemImage: "ellipsis.circle") }.accessibilityIdentifier("chirp.notes.menu")
        }
    }

    private func fixSetup(_ step: SetupProgress.Step) {
        switch step {
        case .pair: pair()
        case .microphone:
            if AVAudioApplication.shared.recordPermission == .undetermined {
                Task { microphone = await AVAudioApplication.requestRecordPermission() }
            } else if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        case .keyboard:
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }
    }

    private func startRecording() async { await notes.newRecording(); selectedID = notes.document.id.uuidString }
    private func newNote() async {
        searchFocused = false; selecting = false; selection = []
        await notes.newNote(); selectedID = notes.document.id.uuidString
    }
    private func open(_ id: UUID) async {
        await notes.open(id)
        guard notes.document.id == id else { return }
        selectedID = id.uuidString; scrollID = id.uuidString
    }
    private func clock(_ value: TimeInterval) -> String { ChirpNotesActivityAttributes.ContentState.clock(value) }
    private func highlight(_ value: String) -> AttributedString {
        var text = AttributedString(value)
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return text }
        var cursor = value.startIndex
        while cursor < value.endIndex, let match = value.range(of: search, options: [.caseInsensitive, .diacriticInsensitive], range: cursor..<value.endIndex) {
            if let range = Range(match, in: text) { text[range].backgroundColor = Color.chirp.moonFill.opacity(0.4) }
            cursor = match.upperBound
        }
        return text
    }
    private var groups: [(title: String, entries: [NotesLibraryEntry])] {
        let calendar = Calendar.current, now = Date()
        var result: [(title: String, entries: [NotesLibraryEntry])] = []
        for entry in notes.entries where entry.id != notes.recordingID {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: entry.updatedAt), to: calendar.startOfDay(for: now)).day ?? 0
            let title: String
            switch days {
            case ...0: title = "Today"
            case 1: title = "Yesterday"
            case 2...7: title = "Previous 7 days"
            case 8...30: title = "Previous 30 days"
            default: title = entry.updatedAt.formatted(calendar.isDate(entry.updatedAt, equalTo: now, toGranularity: .year) ? .dateTime.month(.wide) : .dateTime.month(.wide).year())
            }
            if result.last?.title == title { result[result.count - 1].entries.append(entry) }
            else { result.append((title, [entry])) }
        }
        return result
    }
}

struct NotesEmptyView: View {
    let title: String
    let message: String
    var privacy = false
    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                ForEach(0..<3) { ring in Circle().stroke(Color.chirp.koiDecor.opacity(0.3 - Double(ring) * 0.06), lineWidth: 1).frame(width: CGFloat(72 + ring * 32)) }
                ChirpBrand.glyph.resizable().scaledToFit().frame(width: 52, height: 52).foregroundStyle(Color.chirp.koi)
            }.frame(height: 150).accessibilityHidden(true)
            Text(title).font(ChirpType.noteTitle).multilineTextAlignment(.center)
            Text(message).font(.body).foregroundStyle(Color.chirp.inkMuted).multilineTextAlignment(.center)
            if privacy { Label("Notes stay on this \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone").", systemImage: "lock").font(.footnote).foregroundStyle(Color.chirp.inkMuted).padding(.top, 12) }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.chirp.background)
    }
}

/// The words around a note, the same as the Mac's and Android's: a row's "3 min" and "5 min ago", and the detail's
/// one meta line, "Oct 20, 2026 at 2:03 PM · 3 min · ☐ 1 open · 640 KB" (#271 2.4, 2.8).
enum NoteMeta {
    static let untitled = "Untitled note"

    /// Nothing typed, recorded or named yet: the Mac's blank note.
    static func isBlank(_ document: NotesDocument) -> Bool { document.isEmpty && document.segments.isEmpty && document.userTitle == nil }
    static func displayTitle(_ document: NotesDocument) -> String { isBlank(document) ? untitled : document.title }

    /// "45 sec", "3 min"; nil under a second.
    static func duration(_ seconds: TimeInterval) -> String? {
        guard seconds >= 1 else { return nil }
        return seconds < 60 ? "\(Int(seconds)) sec" : "\(Int(seconds / 60)) min"
    }

    static func open(_ count: Int) -> String { "\(count) open" }

    /// "Just now", "5 min ago", "3 h ago", "Yesterday", "4 days ago": Android's `historyAge`.
    static func age(since date: Date, now: Date = Date()) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60), hours = minutes / 60, days = hours / 24
        switch true {
        case minutes < 1: return "Just now"
        case minutes < 60: return "\(minutes) min ago"
        case hours < 24: return "\(hours) h ago"
        case days == 1: return "Yesterday"
        default: return "\(days) days ago"
        }
    }

    /// Date · duration · open to-dos · audio; a fact with nothing to say is left out.
    static func facts(created: Date, duration: TimeInterval?, openTodos: Int, audioBytes: Int) -> String {
        var parts = [created.formatted(date: .abbreviated, time: .shortened)]
        if let duration, let length = self.duration(duration) { parts.append(length) }
        if openTodos > 0 { parts.append("☐ " + open(openTodos)) }
        if audioBytes > 0 { parts.append(ByteCountFormatter.string(fromByteCount: Int64(audioBytes), countStyle: .file)) }
        return parts.joined(separator: " · ")
    }
}

/// The "N days left" line under a note in Recently Deleted: singular for one, never negative.
enum RecentlyDeletedCopy {
    static let keptDays = 30
    static func daysLeft(since deleted: Date, now: Date = Date()) -> String {
        let left = max(0, keptDays - Int(now.timeIntervalSince(deleted) / 86400))
        return left == 1 ? "1 day left" : "\(left) days left"
    }
}

private struct RecentlyDeletedView: View {
    @ObservedObject var notes: LiveNotesController
    @Environment(\.dismiss) private var dismiss
    @State private var confirmEmpty = false
    var body: some View {
        List {
            Section {
                ForEach(notes.recentlyDeleted) { entry in
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(entry.title).font(.system(.headline, design: .serif))
                            Text(entry.snippet).font(.subheadline).foregroundStyle(Color.chirp.inkMuted).lineLimit(2)
                            if let date = entry.deletedAt { Text(RecentlyDeletedCopy.daysLeft(since: date)).font(.footnote).foregroundStyle(Color.chirp.inkMuted) }
                        }
                        Spacer()
                        Button("Restore") { Task { await notes.restore([entry.id]) } }.buttonStyle(.bordered)
                    }.padding(.vertical, 8).listRowBackground(Color.chirp.surface)
                        .accessibilityElement(children: .contain)
                        .accessibilityAction(named: "Restore") { Task { await notes.restore([entry.id]) } }
                }
            } footer: { Text("Notes are kept here for 30 days.") }
            if !notes.recentlyDeleted.isEmpty {
                Button("Empty Recently Deleted", role: .destructive) { confirmEmpty = true }.tint(Color.chirp.record)
            }
        }.scrollContentBackground(.hidden).background(Color.chirp.background).tint(Color.chirp.koi)
            .overlay { if notes.recentlyDeleted.isEmpty { NotesEmptyView(title: "Nothing in Recently Deleted", message: "Deleted notes stay here for 30 days.") } }
            .navigationTitle("Recently Deleted").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Empty Recently Deleted?", isPresented: $confirmEmpty, titleVisibility: .visible) {
                Button("Delete Permanently", role: .destructive) { Task { await notes.emptyRecentlyDeleted() } }
            } message: { Text("These notes and their audio will be deleted for good. This can’t be undone.") }
    }
}

private struct NoteShare: Identifiable {
    let id = UUID()
    let text: String
}
private struct NotesShareSheet: UIViewControllerRepresentable {
    let text: String
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [text], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
