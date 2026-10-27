import ChirpCore
import ChirpIOSCore
import SwiftUI
import UIKit

// The History tab (#194), following Android's `shell/HistoryScreen.kt`: a list of what you said, not a
// settings form. Day-grouped rows, a detail sheet, swipe-to-delete with an Undo toast (the store delete
// is deferred until the toast expires, so HistoryStore needs no restore API), search over the saved text
// and the original, and one action on each empty state. The settings moved to Settings → Privacy &
// history, reached through the ⋯ menu.

/// The History tab: the entries grouped by day, with search, a detail sheet and swipe-delete + Undo.
struct HistoryView: View {
    @ObservedObject var model: SessionCoordinator
    /// Opens Settings → Privacy & history (the ⋯ menu's "History settings").
    var openSettings: () -> Void = {}
    /// The Notes library (#193): "Add to note" appends to the latest note, then shows it.
    var notes: LiveNotesController?
    var openNotes: () -> Void = {}
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entries: [HistoryEntry] = []
    @State private var enabled = false
    @State private var retention = HistoryRetention.week
    @State private var query = ""
    @State private var failure = ""
    @State private var visible = false
    @State private var detail: HistoryEntry?
    @State private var deletion: PendingDeletion?
    @State private var share: ShareItem?
    @State private var notice: String?
    @State private var teaching: HistoryEntry?
    /// Learn from my edits may learn now (history on, learning on, no private session): Teach Chirp is offered.
    @State private var canTeach = false

    struct PendingDeletion {
        let entry: HistoryEntry
        let task: Task<Void, Never>
    }

    struct ShareItem: Identifiable {
        let id = UUID()
        let text: String
    }

    private var filtered: [HistoryEntry] {
        query.isEmpty ? entries : entries.filter { $0.text.localizedCaseInsensitiveContains(query) || ($0.raw?.localizedCaseInsensitiveContains(query) ?? false) }
    }

    /// Today / Yesterday / weekday / date, newest first.
    private var groups: [(label: String, entries: [HistoryEntry])] {
        let calendar = Calendar.current
        let days = Dictionary(grouping: filtered) { calendar.startOfDay(for: $0.createdAt) }
        return days.keys.sorted(by: >).map { day in
            (Self.dayLabel(day), (days[day] ?? []).sorted { $0.createdAt > $1.createdAt })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !failure.isEmpty {
                PondBanner(kind: .error, title: "History storage failed", detail: failure)
                    .padding(.horizontal, ChirpSpacing.gutter(sizeClass)).padding(.top, ChirpSpacing.s8)
            }
            content
        }
        .background(Color.chirp.background)
        .navigationTitle("Dictation history")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { openSettings() } label: { Label("History settings", systemImage: "slider.horizontal.3") }
                } label: {
                    Image(systemName: "ellipsis.circle").symbolRenderingMode(.hierarchical)
                }
                .accessibilityLabel("History options")
                .accessibilityIdentifier("chirp.history.menu")
            }
        }
        .onAppear { visible = true; reload() }
        .onDisappear { visible = false; entries = []; query = ""; commitPending() }
        .onChange(of: model.phase) { _, _ in if visible, scenePhase == .active { reload() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active, visible { reload() } else { entries = []; query = ""; commitPending() }
        }
        .sheet(item: $detail) { entry in
            HistoryDetailSheet(entry: entry, canAddToNote: notes != nil,
                               addToNote: { addToNote(entry) },
                               teachStore: canTeach ? model.services?.learned : nil, taught: { notice = $0 }) { delete(entry) }
        }
        .sheet(item: $teaching) { entry in
            TeachChirpSheet(entry: entry, store: model.services?.learned) { notice = $0 }
        }
        .sheet(item: $share) { item in
            ShareSheet(text: item.text)
        }
        .overlay(alignment: .bottom) { toast }
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: deletion == nil)
        .overlay(alignment: .bottom) {
            if let notice {
                Text(notice).font(.subheadline.weight(.medium)).foregroundStyle(Color.chirp.ink)
                    .padding(.horizontal, ChirpSpacing.s16).padding(.vertical, ChirpSpacing.s12)
                    .background(Color.chirp.surface, in: Capsule())
                    .shadow(color: Color.black.opacity(0.15), radius: 12, y: 4)
                    .padding(.horizontal, ChirpSpacing.s16).padding(.bottom, ChirpSpacing.s8)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .task { try? await Task.sleep(for: .seconds(3)); self.notice = nil }
                    .accessibilityIdentifier("chirp.history.notice")
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: notice == nil)
    }

    @ViewBuilder private var content: some View {
        if !enabled && entries.isEmpty {
            emptyState(symbol: "clock.arrow.circlepath", title: "History is off",
                       body: "Turn it on to keep recent dictations here, encrypted on this device only.",
                       actionTitle: "Turn on", actionID: "chirp.history.turnOn") { change { try $0.setEnabled(true) } }
        } else if filtered.isEmpty, !query.isEmpty {
            emptyState(symbol: "magnifyingglass", title: "No matches",
                       body: "Nothing in your history matches. Try other words.")
        } else if entries.isEmpty {
            emptyState(symbol: "clock.arrow.circlepath", title: "Nothing yet",
                       body: "Dictations you finish appear here and stay for \(retention.label).")
        } else {
            list
        }
    }

    private var list: some View {
        List {
            Section {
                Text(enabled ? "What you dictated, encrypted on this device only" : "History is off. Existing dictations stay until they expire or you delete them.")
                    .font(.subheadline).foregroundStyle(Color.chirp.inkMuted)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1) // an aside: it must not fill the screen at AX5
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: ChirpSpacing.s4, leading: ChirpSpacing.gutter(sizeClass),
                                              bottom: ChirpSpacing.s4, trailing: ChirpSpacing.gutter(sizeClass)))
            }
            ForEach(groups, id: \.label) { group in
                Section {
                    ForEach(group.entries) { entry in
                        HistoryRowView(entry: entry).listRowBackground(Color.chirp.surface)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 2, leading: ChirpSpacing.gutter(sizeClass),
                                                      bottom: 2, trailing: ChirpSpacing.gutter(sizeClass)))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { delete(entry) } label: { Label("Delete", systemImage: "trash") }
                            }
                            .onTapGesture { detail = entry }
                            .contextMenu {
                                Button { UIPasteboard.general.string = entry.text } label: { Label("Copy", systemImage: "doc.on.doc") }
                                if let raw = entry.raw, raw != entry.text {
                                    Button { UIPasteboard.general.string = raw } label: { Label("Copy original", systemImage: "doc.on.doc.fill") }
                                }
                                Button { share = ShareItem(text: entry.text) } label: { Label("Share", systemImage: "square.and.arrow.up") }
                                if notes != nil {
                                    Button { addToNote(entry) } label: { Label("Add to note", systemImage: "note.text") }
                                }
                                if canTeach {
                                    Button { teaching = entry } label: { Label(LearningText.teach, systemImage: "graduationcap") }
                                }
                                Button(role: .destructive) { delete(entry) } label: { Label("Delete", systemImage: "trash") }
                            }
                    }
                } header: {
                    Text(group.label).font(.subheadline.weight(.semibold)).foregroundStyle(Color.chirp.koi)
                        .textCase(nil)
                        .accessibilityAddTraits(.isHeader)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .searchable(text: $query, prompt: "Search history")
    }

    private func emptyState(symbol: String, title: String, body: String,
                            actionTitle: String? = nil, actionID: String? = nil,
                            action: (() -> Void)? = nil) -> some View {
        VStack(spacing: ChirpSpacing.s12) {
            Image(systemName: symbol).font(.system(size: 56)).symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.chirp.koi).accessibilityHidden(true)
            VStack(spacing: ChirpSpacing.s4) {
                Text(title).font(.headline).foregroundStyle(Color.chirp.ink)
                Text(body).font(.subheadline).foregroundStyle(Color.chirp.inkMuted)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.pondTonal)
                    .accessibilityIdentifier(actionID ?? "")
            }
        }
        .padding(ChirpSpacing.s32)
        .frame(maxWidth: 560).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// "Dictation deleted · Undo": the store delete waits out the toast, so Undo only puts the row back.
    @ViewBuilder private var toast: some View {
        if deletion != nil {
            HStack(spacing: ChirpSpacing.s12) {
                Text("Dictation deleted").font(.subheadline.weight(.medium)).foregroundStyle(Color.chirp.ink)
                Spacer(minLength: 0)
                Button("Undo") { undo() }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.chirp.koi)
                    .accessibilityIdentifier("chirp.history.undo")
            }
            .padding(.leading, ChirpSpacing.s16).padding(.trailing, ChirpSpacing.s4).padding(.vertical, ChirpSpacing.s4)
            .background(Color.chirp.surface, in: Capsule())
            .shadow(color: Color.black.opacity(0.15), radius: 12, y: 4)
            .padding(.horizontal, ChirpSpacing.s16).padding(.bottom, ChirpSpacing.s8)
            .accessibilityElement(children: .contain)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Appends the dictation to the latest note (a new note when the library is empty) and shows it.
    private func addToNote(_ entry: HistoryEntry) {
        guard let notes else { return }
        Task {
            if await notes.addToNote(entry.text, id: notes.entries.first?.id) != nil {
                openNotes()
            } else {
                notice = "Couldn't add the note"
            }
        }
    }

    // MARK: Store actions

    private func change(_ action: (HistoryStore) throws -> Void) {
        do {
            guard let store = model.services?.history else { throw SessionFailure.storage }
            try action(store)
        } catch { failure = SessionFailure.storage.localizedDescription }
        reload()
    }

    private func reload() {
        do {
            guard let store = model.services?.history else { throw SessionFailure.storage }
            let settings = try store.settings()
            enabled = settings.enabled; retention = settings.retention
            entries = try store.entries(); failure = ""
            canTeach = model.services?.learned.allowed == true
        } catch {
            entries = []; failure = SessionFailure.storage.localizedDescription
        }
    }

    private func delete(_ entry: HistoryEntry) {
        commitPending()
        entries.removeAll { $0.id == entry.id }
        if detail?.id == entry.id { detail = nil }
        deletion = PendingDeletion(entry: entry, task: Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            commitStore(entry)
            if deletion?.entry.id == entry.id { deletion = nil }
        })
    }

    private func undo() {
        guard let deletion else { return }
        deletion.task.cancel()
        entries.append(deletion.entry)
        entries.sort { $0.createdAt > $1.createdAt }
        self.deletion = nil
    }

    /// A pending deletion is committed at once when another starts or the screen leaves.
    private func commitPending() {
        guard let deletion else { return }
        deletion.task.cancel()
        commitStore(deletion.entry)
        self.deletion = nil
    }

    private func commitStore(_ entry: HistoryEntry) {
        do {
            guard let store = model.services?.history else { throw SessionFailure.storage }
            try store.delete(id: entry.id)
        } catch { failure = SessionFailure.storage.localizedDescription }
    }

    /// Today / Yesterday, then the weekday inside a week, then the date.
    static func dayLabel(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let gap = calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: now)).day ?? 99
        if gap > 0, gap < 7 { return day.formatted(.dateTime.weekday(.wide)) }
        return day.formatted(.dateTime.day().month(.wide))
    }
}

/// One dictation: two lines of text, then the time (and "Polished" when clean-up changed it, docs/copy.md).
private struct HistoryRowView: View {
    let entry: HistoryEntry
    var body: some View {
        VStack(alignment: .leading, spacing: ChirpSpacing.s4) {
            Text(entry.text).font(.body).foregroundStyle(Color.chirp.ink).lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(meta).font(ChirpType.meta).foregroundStyle(Color.chirp.inkMuted)
        }
        .padding(.horizontal, ChirpSpacing.s16).padding(.vertical, ChirpSpacing.s8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: ChirpRadius.row, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: ChirpRadius.row, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var meta: String {
        var parts = [entry.createdAt.formatted(date: .omitted, time: .shortened)]
        if let raw = entry.raw, raw != entry.text { parts.append("Polished") }
        return parts.joined(separator: " · ")
    }
}

/// Tap a row: the full text (selectable), the original when clean-up changed it, and the actions
/// Copy · Copy original · Share · Add to note · Teach Chirp · Delete.
private struct HistoryDetailSheet: View {
    let entry: HistoryEntry
    var canAddToNote = false
    var addToNote: () -> Void = {}
    /// Teach Chirp, offered while learning is allowed.
    var teachStore: IOSLearnedStore?
    var taught: (String) -> Void = { _ in }
    var delete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var share = false
    @State private var teaching = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ChirpSpacing.s16) {
                    Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.footnote).foregroundStyle(Color.chirp.inkMuted)
                    Text(entry.text).font(.title3).foregroundStyle(Color.chirp.ink)
                        .textSelection(.enabled).lineSpacing(4)
                    if let raw = entry.raw, raw != entry.text {
                        VStack(alignment: .leading, spacing: ChirpSpacing.s8) {
                            Text("Before clean-up").font(.subheadline.weight(.semibold)).foregroundStyle(Color.chirp.moon)
                            Text(raw).font(.body).foregroundStyle(Color.chirp.inkMuted)
                                .textSelection(.enabled)
                        }
                        .padding(ChirpSpacing.s12)
                        .overlay(alignment: .leading) { Capsule().fill(Color.chirp.moonFill).frame(width: 3) }
                    }
                    FlowLayout(spacing: ChirpSpacing.s8) {
                        Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = entry.text }.buttonStyle(.capsuleChip)
                        if let raw = entry.raw, raw != entry.text {
                            Button("Copy original", systemImage: "doc.on.doc.fill") { UIPasteboard.general.string = raw }.buttonStyle(.capsuleChip)
                        }
                        Button("Share", systemImage: "square.and.arrow.up") { share = true }.buttonStyle(.capsuleChip)
                        if canAddToNote {
                            Button("Add to note", systemImage: "note.text") { addToNote(); dismiss() }.buttonStyle(.capsuleChip)
                                .accessibilityIdentifier("chirp.history.addNote")
                        }
                        if teachStore != nil {
                            Button(LearningText.teach, systemImage: "graduationcap") { teaching = true }.buttonStyle(.capsuleChip)
                                .accessibilityIdentifier("chirp.history.teach")
                        }
                        Button("Delete", systemImage: "trash", action: delete)
                            .buttonStyle(CapsuleChipStyle())
                            .foregroundStyle(Color.chirp.record)
                            .accessibilityIdentifier("chirp.history.delete")
                    }
                }
                .font(.body)
                .padding(ChirpSpacing.s24)
                .frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.chirp.background)
            .navigationTitle("Dictation").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(ChirpRadius.sheet)
        .modifier(PrivacyShield())
        .sheet(isPresented: $share) { ShareSheet(text: entry.text) }
        .sheet(isPresented: $teaching) {
            TeachChirpSheet(entry: entry, store: teachStore) { taught($0); dismiss() }
        }
    }
}

/// The system share sheet, for the explicit-tap Share actions.
struct ShareSheet: UIViewControllerRepresentable {
    let text: String
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
