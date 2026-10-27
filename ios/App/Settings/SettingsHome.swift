import ChirpCore
import ChirpIOSCore
import SwiftUI

/// The seven Settings categories (#194 / spec §D): each row carries an SF Symbol and a live one-line
/// summary of what sits behind it, and opens one detail page.
enum SettingsCategory: String, CaseIterable, Identifiable, Hashable {
    case connection, session, dictation, keyboard, notes, privacy, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .connection: "Connection"
        case .session: "Microphone session"
        case .dictation: "Dictation"
        case .keyboard: "Keyboard"
        case .notes: "Notes"
        case .privacy: "Privacy & history"
        case .about: "About"
        }
    }
    var symbol: String {
        switch self {
        case .connection: "desktopcomputer"
        case .session: "mic"
        case .dictation: "slider.horizontal.3"
        case .keyboard: "keyboard"
        case .notes: "note.text"
        case .privacy: "lock.shield"
        case .about: "info.circle"
        }
    }
    /// The rows' accessibility identifiers, as the UI tests and e2e reach them.
    var identifier: String { "chirp.settings." + rawValue }
    /// Where a SettingsRoute deep link lands (Styles lives inside Dictation).
    static func category(for route: SettingsRoute) -> SettingsCategory {
        switch route { case .connection: .connection; case .styles: .dictation; case .privacy: .privacy }
    }
}

/// The Settings tab root: seven category rows with live summaries, detail pages behind them — a
/// NavigationSplitView at regular width (opening on Connection, summaries on one line beside the open
/// page) and push navigation on iPhone. The DEBUG retention banner sits at the top, as on Android.
struct SettingsHome: View {
    @ObservedObject var model: SessionCoordinator
    /// The Notes tab's controller, for the Notes category's page and summary (#193 owns its form).
    @ObservedObject var notes: LiveNotesController
    var showOnboarding: () -> Void = {}
    /// Deep links from the rest of the app (the connection chip, banners, History's ⋯ menu); consumed here.
    @Binding var deeplink: SettingsRoute?
    @StateObject private var history = HistorySettingsModel()
    @State private var path: [SettingsCategory] = []
    @State private var selection: SettingsCategory = .connection
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group { if sizeClass == .regular { split } else { stack } }
            .tint(Color.chirp.koi)
            .onAppear { history.reload(model.services); consume(deeplink) }
            .onChange(of: deeplink) { _, route in consume(route) }
            .onChange(of: scenePhase) { _, phase in if phase == .active { history.reload(model.services) } }
    }

    /// iPad: the categories on the left (at least 320 pt, so a summary fits on one line), detail on the
    /// right. The detail column carries its own stack, so the pages can push (Change pairing, prompts).
    private var split: some View {
        NavigationSplitView {
            list.navigationTitle("Settings")
                .navigationSplitViewColumnWidth(min: 320, ideal: 340, max: 420)
        } detail: {
            NavigationStack { page(selection) }
        }
        // Picking another category starts over on its own page: the detail column's stack is the split view's,
        // so a pushed page (Change pairing) would otherwise stay on top of the new selection.
        .id(selection)
    }

    /// iPhone: the categories push their page, Back returns to the list.
    private var stack: some View {
        NavigationStack(path: $path) {
            list.navigationTitle("Settings")
                .navigationDestination(for: SettingsCategory.self) { page($0) }
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ChirpSpacing.s24) {
                if model.debugRetention {
                    PondBanner(kind: .error, title: "DEBUG RETENTION IS ON", detail: "The Chirp server may retain audio and text")
                }
                SettingsGroup {
                    ForEach(SettingsCategory.allCases) { row($0) }
                }
            }
            .padding(.horizontal, ChirpSpacing.gutter(sizeClass)).padding(.vertical, ChirpSpacing.s16)
            .frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color.chirp.background)
    }

    /// One category row: symbol, title, live summary, chevron. In the split the selected row stays
    /// highlighted (koiContainer) beside its open page.
    /// The session row re-renders each second while armed, so its countdown summary stays live.
    @ViewBuilder private func row(_ category: SettingsCategory) -> some View {
        if category == .session, model.armed {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                rowTile(category, summary: sessionSummaryText(at: context.date))
            }.accessibilityAddTraits(.updatesFrequently)
        } else {
            rowTile(category, summary: summaryText(category))
        }
    }

    @ViewBuilder private func rowTile(_ category: SettingsCategory, summary: String) -> some View {
        let chosen = sizeClass == .regular && selection == category
        let tile = RowTile(hasSummary: true, fill: chosen ? Color.chirp.koiContainer : Color.chirp.surface) {
            RowText(title: category.title, summary: summary, symbol: category.symbol, summaryLimit: 2)
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                .foregroundStyle(Color.chirp.inkMuted).accessibilityHidden(true)
        }
        if sizeClass == .regular {
            Button { selection = category } label: { tile }
                .buttonStyle(.rowPress).accessibilityIdentifier(category.identifier)
                .accessibilityAddTraits(chosen ? [.isSelected] : [])
        } else {
            NavigationLink(value: category) { tile }
                .buttonStyle(.rowPress).accessibilityIdentifier(category.identifier)
        }
    }

    @ViewBuilder private func page(_ category: SettingsCategory) -> some View {
        switch category {
        case .connection: ConnectionPage(model: model).navigationTitle(category.title)
        case .session: SessionPage(model: model).navigationTitle(category.title)
        case .dictation: DictationPage(model: model).navigationTitle(category.title)
        case .keyboard: KeyboardPage(model: model).navigationTitle(category.title)
        case .notes: NotesSettingsView(notes: notes)
        case .privacy: PrivacyPage(model: model, history: history).navigationTitle(category.title)
        case .about: AboutPage(model: model, showSetup: showOnboarding).navigationTitle(category.title)
        }
    }

    // MARK: The live one-line summaries

    private func summaryText(_ category: SettingsCategory) -> String {
        switch category {
        case .connection:
            let status = model.connectionStatus
            return status.detail.isEmpty ? status.title : status.title + " · " + status.detail
        case .session: return sessionSummaryText(at: Date())
        case .dictation: return model.dictationSummary
        case .keyboard: return model.keyboardReady ? "Chirp Keyboard on · Full Access" : "Not set up"
        case .notes: return notesSummary
        case .privacy:
            guard history.enabled else { return "History off" }
            return model.preferences.privacyMode ? "History paused" : "History on · keeps \(history.retention.label)"
        case .about: return Self.versionSummary
        }
    }

    /// "Kept forever · structure on": the notes library's retention and structuring state (#193).
    private var notesSummary: String {
        guard notes.preferences.keepNotes else { return "Notes library off" }
        var parts = [notes.preferences.retention.label]
        if notes.preferences.structureEnabled(health: notes.health) { parts.append("structure on") }
        if notes.preferences.keepAudio { parts.append("audio kept") }
        return parts.joined(separator: " · ")
    }

    /// "Session running · 4:12 left" while armed, else the length.
    private func sessionSummaryText(at date: Date) -> String {
        guard model.armed else {
            return model.preferences.sessionDuration.label
        }
        guard let end = model.expiresAt else { return "Session running" }
        return "Session running · \(DictateView.clock(end.timeIntervalSince(date))) left"
    }

    static var versionSummary: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "Chirp \(version) (\(build))"
    }

    private func consume(_ route: SettingsRoute?) {
        guard let route else { return }
        let category = SettingsCategory.category(for: route)
        if sizeClass == .regular { selection = category } else { path = [category] }
        deeplink = nil
    }
}

/// The live summaries are read-only views of the session state (a port of Android's
/// `ConnectionSummary.kt` / `SettingsHome.kt` summaries); no behaviour changes.
extension SessionCoordinator {
    struct ConnectionStatus: Equatable {
        var kind = PondBanner.Kind.info
        var title = ""
        var detail = ""
        /// The fix hint an unreachable banner adds (Android's `hint`).
        var hint: String?
    }

    /// "Connected · host · engine · clean-up on your computer" and its variants; `nil` health reads as never checked.
    var connectionStatus: ConnectionStatus {
        guard paired else { return .init(kind: .warning, title: "Not paired", detail: "Pair your computer to dictate") }
        let details = [health?.engine.flatMap { $0.isEmpty ? nil : $0 } ?? "Engine not reported", cleanupDetail].joined(separator: " · ")
        if working { return .init(kind: .info, title: "Checking · \(pairedHost)", detail: details) }
        if let issue = connectionIssue {
            if issue == .loading { return .init(kind: .info, title: "Paired · \(pairedHost)", detail: "Computer is loading its speech model") }
            return .init(kind: .warning, title: "Computer unreachable · \(pairedHost)", detail: details, hint: issue.message)
        }
        guard let health else { return .init(kind: .info, title: "Paired · \(pairedHost)", detail: details) }
        if health.ready == false { return .init(kind: .info, title: "Paired · \(pairedHost)", detail: "Computer is loading its speech model") }
        return .init(kind: .success, title: "Connected · \(pairedHost)", detail: details)
    }

    private var cleanupDetail: String {
        guard let health, health.correctionAvailable else { return "clean-up off" }
        if health.correctionLeavesMachine == true { return "clean-up via \(health.correctionHost ?? "another host")" }
        return "clean-up on your computer"
    }

    /// "Clean-up on · Email style · Return on Send": the three things the Dictation page decides.
    var dictationSummary: String {
        var parts: [String] = []
        if let health, health.correctionAvailable {
            parts.append(preferences.permitsCorrection(health: health) ? "Clean-up on" : "Clean-up off")
        } else if paired {
            parts.append("No clean-up from your computer")
        }
        parts.append("\(styleName) style")
        if let autoEnter = preferences.autoEnter {
            parts.append(autoEnter == "actionKeys" ? "Return on Send" : "Return always")
        }
        return parts.joined(separator: " · ")
    }

    /// The selected style's display name, or "Default" before the profiles load.
    var styleName: String { profiles.first { $0.id == preferences.styleID }?.name ?? "Default" }
}

extension SessionDuration {
    /// The picker and summary label for each length.
    var label: String {
        switch self { case .fiveMinutes: "5 minutes"; case .fifteenMinutes: "15 minutes"; case .oneHour: "1 hour"; case .never: "Never" }
    }
}

extension HistoryRetention {
    /// "1 day", "7 days", "30 days": what Keep for offers and the Privacy summary shows.
    var label: String {
        switch self { case .day: "1 day"; case .week: "7 days"; case .month: "30 days" }
    }
}

extension NotesRetention {
    /// What the Notes category row summarises: the library's retention choice.
    var label: String {
        switch self { case .never: "Kept forever"; case .oneYear: "1 year"; case .ninetyDays: "90 days"; case .thirtyDays: "30 days" }
    }
}

/// Disk-backed history settings as observable state, shared by the Settings home summary and the
/// Privacy & history page, so a change beside the split updates the row above it.
@MainActor
final class HistorySettingsModel: ObservableObject {
    @Published var enabled = false
    @Published var retention = HistoryRetention.week
    /// A storage failure shows as the page's error banner.
    @Published var failure = ""

    func reload(_ services: AppServices?) {
        do {
            guard let store = services?.history else { throw SessionFailure.storage }
            let settings = try store.settings()
            enabled = settings.enabled; retention = settings.retention; failure = ""
        } catch { failure = SessionFailure.storage.localizedDescription }
    }
}
