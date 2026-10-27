import ChirpCore
import SwiftUI

public enum HistoryViewMetrics {
    public static let defaultSize = CGSize(width: 860, height: 560)
    public static let minimumSize = CGSize(width: 640, height: 400)
    static let sidebar = (min: CGFloat(260), ideal: CGFloat(320), max: CGFloat(420))
}

/// The Dictation History window: every kept dictation by day in the sidebar (searchable), the selected one as the
/// detail with what was inserted, what was said, and Insert Again, Copy, Add to Notes and Delete (with Undo).
public struct HistoryView: View {
    @Bindable var model: HistoryModel
    private let textSize: ChirpTextSize

    public init(model: HistoryModel, textSize: ChirpTextSize = ChirpTextSize()) { self.model = model; self.textSize = textSize }

    public var body: some View {
        NavigationSplitView {
            HistorySidebar(model: model)
                .background(Color.chirp.surfaceRaised.ignoresSafeArea())
                .navigationSplitViewColumnWidth(min: HistoryViewMetrics.sidebar.min, ideal: HistoryViewMetrics.sidebar.ideal,
                                                max: HistoryViewMetrics.sidebar.max)
        } detail: {
            HistoryDetail(model: model)
                .background(Color.chirp.background.ignoresSafeArea())
        }
        .searchable(text: $model.query, placement: .sidebar, prompt: HistoryText.searchPrompt)
        .navigationTitle(HistoryText.windowTitle)
        .frame(minWidth: HistoryViewMetrics.minimumSize.width, minHeight: HistoryViewMetrics.minimumSize.height)
        .overlay(alignment: .bottom) { if let toast = model.toast { HistoryToastView(model: model, toast: toast) } }
        .sheet(isPresented: Binding(get: { model.teaching != nil }, set: { if !$0 { model.teaching = nil } })) {
            TeachSheet(model: model)
        }
        .toolbar { ToolbarItem(placement: .primaryAction) { TextSizeControl(size: textSize) } }
        .pondFont(.callout)
        .environment(\.chirpTextScale, textSize.factor)
        .tint(Color.chirp.koi)
    }
}

// MARK: sidebar

private struct HistorySidebar: View {
    @Bindable var model: HistoryModel

    var body: some View {
        List(selection: $model.selection) {
            ForEach(model.groups) { group in
                Section {
                    ForEach(group.entries) { entry in
                        HistoryRow(model: model, entry: entry, selected: model.selection == entry.id)
                            .tag(entry.id)
                            .listRowBackground(SelectionBackground(selected: model.selection == entry.id))
                            .contextMenu { menu(entry) }
                    }
                } header: {
                    Text(group.title)
                        .pondFont(12.5, weight: .semibold, design: .serif)
                        .foregroundStyle(NotesInk.secondary)
                        .textCase(nil)
                        .padding(.top, 4)
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .overlay { overlay }
        .onDeleteCommand { if let id = model.selection { model.delete(id) } }
        .safeAreaInset(edge: .bottom, spacing: 0) { footer }
    }

    @ViewBuilder private func menu(_ entry: DictationEntry) -> some View {
        Button(HistoryText.insertAgain) { model.onInsertAgain(entry) }
        Button(HistoryText.copy) { model.copy(entry) }
        if entry.cleaned { Button(HistoryText.copyRaw) { model.copy(entry, raw: true) } }
        Button(HistoryText.addToNotes) { model.onAddToNotes(entry) }
        if model.canTeach { Button(HistoryText.teach) { model.beginTeaching(entry) } }
        Divider()
        Button(HistoryText.delete, role: .destructive) { model.delete(entry.id) }
    }

    @ViewBuilder private var overlay: some View {
        if !model.enabled, model.entries.isEmpty {
            HistoryMessage(symbol: "clock.badge.xmark", title: HistoryText.off, detail: HistoryText.offDetail,
                           action: ("Open Settings", model.onOpenSettings))
        } else if model.unavailable {
            HistoryMessage(symbol: "lock", title: HistoryText.unavailable, detail: HistoryText.unavailableDetail)
        } else if model.entries.isEmpty {
            HistoryMessage(symbol: "waveform", title: HistoryText.empty, detail: HistoryText.emptyDetail)
        } else if model.filtered.isEmpty {
            HistoryMessage(symbol: "magnifyingglass", title: HistoryText.noResults(model.query),
                           detail: "Search looks through what was inserted, what you said, and the app.")
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "lock.fill").pondFont(12)
            Text(model.enabled ? HistoryText.keptFor(model.retention) : HistoryText.off)
                .pondFont(12)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .foregroundStyle(NotesInk.tertiary)
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }
}

/// A dictation in the list: the app's icon, the app and time, a two-line preview, and a "Polished" badge.
private struct HistoryRow: View {
    let model: HistoryModel
    let entry: DictationEntry
    let selected: Bool
    @Environment(\.colorScheme) private var scheme

    private var ink: RowInk { RowInk(selected: selected, scheme: scheme) }

    @Environment(\.chirpTextScale) private var textScale

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AppIcon(image: model.icon(entry.bundleID), size: 26)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
            let headingLayout = textScale > 1.3 ? AnyLayout(VStackLayout(alignment: .leading, spacing: 3)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 6))
            headingLayout {
                    Text(entry.appTitle)
                        .pondFont(12, weight: .semibold)
                        .foregroundStyle(ink.title)
                        .lineLimit(1)
                    if entry.cleaned { PolishedBadge() }
                    if textScale <= 1.3 { Spacer(minLength: 4) }
                    Text(HistoryText.time(entry.date, calendar: model.calendar))
                        .pondFont(12)
                        .foregroundStyle(ink.meta)
                        .monospacedDigit()
                        .fixedSize()
                }
                Text(entry.text.split(whereSeparator: \.isNewline).joined(separator: " "))
                    .pondFont(12.5)
                    .foregroundStyle(ink.snippet)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.appTitle), \(HistoryText.time(entry.date, calendar: model.calendar))\(entry.cleaned ? ", polished" : ""): \(entry.text)")
    }
}

private struct PolishedBadge: View {
    var body: some View {
        Text(HistoryText.cleaned)
            .pondFont(12, weight: .semibold)
            .foregroundStyle(Color.chirp.moon)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.chirp.moonFill.opacity(0.18)))
            .fixedSize()
    }
}

struct AppIcon: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        if let image {
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.22)
                .fill(Color.chirp.surface)
                .overlay(Image(systemName: "app.dashed").pondFont(size * 0.5).foregroundStyle(NotesInk.tertiary))
                .frame(width: size, height: size)
        }
    }
}

private struct HistoryMessage: View {
    let symbol: String
    let title: String
    let detail: String
    var action: (String, () -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).pondFont(22, weight: .light).foregroundStyle(NotesInk.tertiary)
            Text(title).pondFont(13, weight: .semibold).foregroundStyle(NotesInk.secondary).multilineTextAlignment(.center)
            Text(detail).pondFont(12).foregroundStyle(NotesInk.tertiary).multilineTextAlignment(.center)
            if let action { Button(action.0, action: action.1).padding(.top, 6) }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: detail

private struct HistoryDetail: View {
    @Bindable var model: HistoryModel
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.chirpTextScale) private var textScale

    private var contrast: Bool { colorSchemeContrast == .increased }

    var body: some View {
        if let entry = model.selected {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(entry)
                    actions(entry)
                    TextCard(title: HistoryText.inserted) { Text(entry.text) }
                    if let raw = entry.raw {
                        TextCard(title: HistoryText.changes, footnote: HistoryText.changesFootnote) {
                            if let segments = WordDiff.segments(raw: raw, cleaned: entry.text) {
                                // The HUD's colour-blind-safe diff: removed words struck through in inkMuted, added
                                // or changed words underlined in moon.
                                DiffText(segments: segments, fade: 0, contrast: contrast, font: .system(size: ChirpTextRole.body.points * textScale), lineLimit: nil)
                            } else {
                                Text(raw)
                            }
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "text.bubble").pondFont(30, weight: .light).foregroundStyle(NotesInk.tertiary)
                Text(HistoryText.noSelection).pondFont(13).foregroundStyle(NotesInk.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ entry: DictationEntry) -> some View {
        HStack(alignment: .center, spacing: 12) {
            AppIcon(image: model.icon(entry.bundleID), size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.appTitle).pondFont(22, weight: .semibold, design: .serif).foregroundStyle(NotesInk.primary)
                Text(HistoryText.meta(entry, now: model.now(), calendar: model.calendar))
                    .pondFont(.meta).foregroundStyle(NotesInk.secondary)
            }
            Spacer()
        }
    }

    private func actions(_ entry: DictationEntry) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { actionButtons(entry) }
            VStack(alignment: .leading, spacing: 8) { actionButtons(entry) }
        }
        // Buttons are native chrome: they keep the system size while the content around them grows.
        .font(.body)
        .controlSize(.regular)
    }

    @ViewBuilder private func actionButtons(_ entry: DictationEntry) -> some View {
            Button {
                model.onInsertAgain(entry)
            } label: {
                Label(HistoryText.insertAgain, systemImage: "text.insert")
            }
            .buttonStyle(.borderedProminent)
            .fixedSize()
            .help("Inserts this text into the field you were typing in")
            Button(HistoryText.copy) { model.copy(entry) }
                .fixedSize()
                .keyboardShortcut("c", modifiers: [.command, .shift])
            Menu {
                if entry.cleaned {
                    Button(HistoryText.copyRaw) { model.copy(entry, raw: true) }
                }
                Button(HistoryText.addToNotes) { model.onAddToNotes(entry) }
                if model.canTeach {
                    Divider()
                    Button(HistoryText.teach) { model.beginTeaching(entry) }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.button)
            .fixedSize()
            .help("Copy Original, Add to Notes\(model.canTeach ? " and Teach Chirp" : "")")
            Spacer(minLength: 8)
            if let flash = model.flash {
                Text(flash).pondFont(.meta).foregroundStyle(Color.chirp.lily)
                    .task(id: flash) {
                        try? await Task.sleep(for: .seconds(1.5))
                        if !Task.isCancelled { model.flash = nil }
                    }
            }
            Button(role: .destructive) {
                model.delete(entry.id)
            } label: {
                Image(systemName: "trash")
            }
            .fixedSize()
            .accessibilityLabel(HistoryText.delete)
            .help("Deletes this dictation from the history (Undo brings it back)")
    }
}

private struct TextCard<Content: View>: View {
    let title: String
    var footnote: String?
    @ViewBuilder let content: Content

    init(title: String, footnote: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footnote = footnote
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).pondFont(12.5, weight: .semibold, design: .serif).foregroundStyle(NotesInk.secondary)
            content
                .pondFont(.body)
                .lineSpacing(4)
                .foregroundStyle(NotesInk.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: ChirpRadius.row).fill(Color.chirp.surface))
                .overlay(RoundedRectangle(cornerRadius: ChirpRadius.row).strokeBorder(NotesInk.tertiary.opacity(0.25)))
            if let footnote { Text(footnote).pondFont(12).foregroundStyle(NotesInk.tertiary) }
        }
    }
}

/// Teach Chirp: the dictation in an editor; Teach learns from the difference at once.
struct TeachSheet: View {
    @Bindable var model: HistoryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(HistoryText.teachTitle).pondFont(.section)
            Text(HistoryText.teachDetail).pondFont(.meta).foregroundStyle(NotesInk.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextEditor(text: $model.teachText)
                .pondFont(.body)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: ChirpRadius.control).fill(Color.chirp.surface))
                .overlay(RoundedRectangle(cornerRadius: ChirpRadius.control).strokeBorder(NotesInk.tertiary.opacity(0.35)))
                .frame(minHeight: 120)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.teaching = nil }.keyboardShortcut(.cancelAction)
                Button("Teach") { model.commitTeaching() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.teachText == model.teaching?.text)
            }
        }
        .padding(20)
        .frame(width: 460)
        .tint(Color.chirp.koi)
    }
}

private struct HistoryToastView: View {
    let model: HistoryModel
    let toast: HistoryToast

    var body: some View {
        HStack(spacing: 14) {
            Text(toast.text).pondFont(.callout).foregroundStyle(NotesInk.primary)
            if toast.undo != nil {
                Button("Undo") { model.undoDelete() }
                    .buttonStyle(.plain)
                    .pondFont(.callout, weight: .semibold)
                    .foregroundStyle(Color.chirp.koi)
                    .keyboardShortcut("z", modifiers: .command)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Capsule().fill(Color.chirp.surfaceRaised))
        .overlay(Capsule().strokeBorder(NotesInk.tertiary.opacity(0.35)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .padding(.bottom, 22)
        .task(id: toast.serial) {
            try? await Task.sleep(for: .seconds(6))
            if !Task.isCancelled, model.toast?.serial == toast.serial { model.toast = nil }
        }
        .accessibilityElement(children: .contain)
    }
}
