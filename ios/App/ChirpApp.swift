import AVFAudio
import ChirpIOSCore
import SwiftUI

@main
struct ChirpApp: App {
    // Not observed here: the views and commands observe it. Observing it in the App re-ran this body on
    // every published change, and SwiftUI may evaluate the new window closure on its async render thread
    // (seen while rotating during dictation), where the main-actor closure trapped.
    private let coordinator: SessionCoordinator
    init() {
        PrivacyController.shared.start()
        #if DEBUG
        coordinator = ProcessInfo.processInfo.arguments.contains("--chirp-ui-test") ? SessionCoordinator.synthetic(sharedKeyboard: KeyboardTestMode.enabled) : .shared
        OnboardingTestMode.apply()
        #else
        coordinator = .shared
        #endif
    }
    var body: some Scene {
        WindowGroup { ChirpScene(coordinator: coordinator) }
            .commands {
                DictationCommands(model: coordinator)
                NotesCommands(notes: .current(for: coordinator))
                NavigationCommands()
            }
    }
}

struct ChirpScene: View {
    let coordinator: SessionCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("chirp.tab") private var tab = ChirpTab.notes
    var body: some View {
        Group {
            #if DEBUG
            if KeyboardTestMode.enabled {
                KeyboardTestHost(model: coordinator)
            } else {
                root
            }
            #else
            root
            #endif
        }
        .modifier(ShortcutListeningBar(model: coordinator, shortcuts: .shared))
        .onAppear { HardwareShortcutController.shared.attach(coordinator) }
    }
    private var root: some View {
        ChirpRootView(model: coordinator, notes: .current(for: coordinator), tab: $tab)
            .onAppear {
                let notes = LiveNotesController.current(for: coordinator)
                HardwareShortcutController.shared.showDictate = { tab = .dictate }
                // On the Notes tab the dictation key records, pauses and resumes Notes, as in the Mac's Notes window.
                HardwareShortcutController.shared.notesKey = { [weak notes] fieldFocused in notes?.hotkeyPress(fieldFocused: fieldFocused) ?? false }
                notes.notesTabShown = tab == .notes
            }
            .onChange(of: tab) { _, tab in LiveNotesController.current(for: coordinator).notesTabShown = tab == .notes }
            .onChange(of: scenePhase) { _, phase in if phase == .active { coordinator.refreshSetup(); coordinator.reconcile() } }
            .onOpenURL { url in
                let c = URLComponents(url: url, resolvingAgainstBaseURL: false)
                if c?.scheme == "chirp", c?.host == "pair" {
                    Task { await coordinator.pair(link: url.absoluteString) }
                } else if c?.scheme == "chirp", c?.host == "session", c?.path == "/start", c?.query == nil,
                          c?.fragment == nil, c?.user == nil, c?.password == nil, c?.port == nil {
                    tab = .dictate
                    Task { do { try await coordinator.armSession() } catch { coordinator.show(error) } }
                }
            }
    }
}

/// Hardware-keyboard shortcuts. As app commands they work from every tab and are listed in the iPad's
/// hold-⌘ overlay and menu bar. ⌘Space is Spotlight on iPadOS, so dictation uses ⌘Return.
struct DictationCommands: Commands {
    @ObservedObject var model: SessionCoordinator
    private var active: Bool { [.connecting, .listening, .correcting].contains(model.phase) }
    var body: some Commands {
        CommandMenu("Dictation") {
            if active {
                Button("Stop Dictation") { model.stopDictation() }
                    .keyboardShortcut(.return, modifiers: .command).disabled(model.phase == .correcting)
            } else {
                Button("Start Dictation") { Task { do { try await model.begin() } catch { model.show(error) } } }
                    .keyboardShortcut(.return, modifiers: .command).disabled(!model.paired || model.working)
            }
            Button("Cancel Dictation") { model.cancelDictation() }
                .keyboardShortcut(".", modifiers: .command).disabled(!active)
            Divider()
            Button("Copy Result") { model.copy() }
                .keyboardShortcut("c", modifiers: [.command, .shift]).disabled(model.phase != .finished)
            Button("Use Raw Transcript") { model.useRaw() }
                .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.canUseRaw)
            Divider()
            Button("Start Keyboard Session") { Task { do { try await model.armSession() } catch { model.show(error) } } }
                .keyboardShortcut("k", modifiers: [.command, .shift]).disabled(model.armed || !model.paired || model.working)
            Button("End Session") { model.endSession() }
                .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(!model.armed)
            HardwareShortcutCommand(model: model, shortcuts: .shared)
        }
    }
}

/// The hardware-keyboard shortcut in the menu bar and the hold-⌘ overlay. A key shortcut carries its keys, so its
/// press is a key command that never types into a field; a modifier on its own cannot be a key command, so its item
/// says how to use it. Choosing the item starts or stops dictation.
private struct HardwareShortcutCommand: View {
    @ObservedObject var model: SessionCoordinator
    @ObservedObject var shortcuts: HardwareShortcutController
    var body: some View {
        let shortcut = shortcuts.shortcut
        if shortcut.enabled {
            Divider()
            let title = shortcut.mode == .hold ? "Hold \(shortcut.title) to Dictate" : "Press \(shortcut.title) to Dictate"
            let button = Button(title) { shortcuts.run([.toggle]) }.disabled(!model.paired)
            if !shortcut.isModifierOnly, let character = HIDKey.character(shortcut.key) {
                button.keyboardShortcut(KeyEquivalent(character), modifiers: EventModifiers(shortcut.modifiers))
            } else {
                button
            }
        }
    }
}

private extension EventModifiers {
    init(_ modifiers: HardwareShortcut.Modifiers) {
        self = []
        if modifiers.contains(.command) { insert(.command) }
        if modifiers.contains(.option) { insert(.option) }
        if modifiers.contains(.control) { insert(.control) }
        if modifiers.contains(.shift) { insert(.shift) }
    }
}

/// ⌘1–⌘4 switch tabs in the focused window (listed in the hold-⌘ overlay).
struct NavigationCommands: Commands {
    @FocusedBinding(\.chirpTab) private var tab
    var body: some Commands {
        CommandMenu("Go") {
            ForEach(Array(ChirpTab.allCases.enumerated()), id: \.element) { index, item in
                Button(item.title) { tab = item }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .disabled(tab == nil)
            }
        }
    }
}

extension FocusedValues {
    @Entry var chirpTab: Binding<ChirpTab>?
}

/// The four destinations: Android's Notes · History · Settings plus iOS's session owner, Dictate.
enum ChirpTab: String, CaseIterable, Hashable {
    case notes, dictate, history, settings
    var title: String {
        switch self { case .notes: "Notes"; case .dictate: "Dictate"; case .history: "History"; case .settings: "Settings" }
    }
    var symbol: String {
        switch self { case .notes: "note.text"; case .dictate: "mic"; case .history: "clock.arrow.circlepath"; case .settings: "gearshape" }
    }
}

/// Pages inside the Settings tab that other screens deep-link to (the connection chip, banners, the
/// setup card, History's ⋯ menu). Styles lives under Dictation; the Settings tree consumes the rest.
enum SettingsRoute: Hashable { case connection, styles, privacy }

struct ChirpRootView: View {
    @ObservedObject var model: SessionCoordinator
    @ObservedObject var notes: LiveNotesController
    @Binding var tab: ChirpTab
    @State private var settingsRoute: SettingsRoute?
    @State private var onboarding = false
    @AppStorage(Onboarding.doneKey) private var onboarded = false
    @AppStorage("chirp.setupCard.dismissed") private var setupDismissed = false

    var body: some View {
        // The session capsule goes inside each tab's root view: inset on the TabView itself, it covered iOS 27's
        // floating tab bar (a tab tap hit End session); on the NavigationStack, it covered Dictate's own controls.
        TabView(selection: $tab) {
            Tab(ChirpTab.notes.title, systemImage: ChirpTab.notes.symbol, value: .notes) {
                LiveNotesView(notes: notes, session: model, pair: { open(.connection) }, dictate: { tab = .dictate })
                    .modifier(SessionCapsule(model: model))
            }
            Tab(ChirpTab.dictate.title, systemImage: ChirpTab.dictate.symbol, value: .dictate) {
                NavigationStack {
                    DictateView(model: model, notes: notes, openConnection: { open(.connection) }, openNotes: { tab = .notes })
                        .toolbar { ToolbarItem(placement: .topBarTrailing) { ConnectionChip(model: model) { open(.connection) } } }
                        .modifier(SessionCapsule(model: model))
                }
            }
            Tab(ChirpTab.history.title, systemImage: ChirpTab.history.symbol, value: .history) {
                NavigationStack {
                    HistoryView(model: model, openSettings: { open(.privacy) }, notes: notes, openNotes: { tab = .notes })
                        .modifier(SessionCapsule(model: model))
                }
            }
            Tab(ChirpTab.settings.title, systemImage: ChirpTab.settings.symbol, value: .settings) {
                SettingsHome(model: model, notes: notes, showOnboarding: { setupDismissed = false; onboarding = true }, deeplink: $settingsRoute)
                    .modifier(SessionCapsule(model: model))
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .defaultAdaptableTabBarPlacement(.sidebar)
        .tint(Color.chirp.koi)
        .focusedSceneValue(\.chirpTab, $tab)
        .modifier(PrivacyShield())
        .fullScreenCover(isPresented: $onboarding) {
            Onboarding(model: model) {
                onboarded = true; onboarding = false; tab = .notes
            }
            .modifier(PrivacyShield())
        }
        .onAppear { if !onboarded && !model.paired { onboarding = true } }
        // Starting Live Notes (from the Live Activity, Shortcuts or a control) shows the note being recorded.
        .onChange(of: notes.isActive) { _, recording in if recording { tab = .notes } }
    }

    private func open(_ route: SettingsRoute) {
        tab = .settings
        settingsRoute = route
    }

}

/// The armed-session capsule: a quiet Ripple, "Mic on · 4:12 left" and End. Sits above each tab's content,
/// never over the tab bar or sidebar.
struct SessionCapsule: ViewModifier {
    @ObservedObject var model: SessionCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if model.armed {
                capsule.padding(.horizontal, ChirpSpacing.s16).padding(.bottom, ChirpSpacing.s8).frame(maxWidth: 560)
            }
        }
    }

    private var capsule: some View {
        HStack(spacing: ChirpSpacing.s12) {
            Ripple(level: 0.2, reduceMotion: reduceMotion || DictateView.forcedReduceMotion || model.phase != .listening)
                .frame(width: 28, height: 28)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(label(at: context.date)).font(ChirpType.timer(.subheadline).weight(.medium))
                    .foregroundStyle(Color.chirp.ink).fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityAddTraits(.updatesFrequently)
            Spacer(minLength: 0)
            Button("End") { model.endSession() }
                .font(.subheadline.weight(.semibold)).foregroundStyle(Color.chirp.onKoi).fixedSize()
                .frame(minWidth: 64, minHeight: 44).padding(.horizontal, ChirpSpacing.s4)
                .background(Color.chirp.record, in: Capsule())
                .accessibilityLabel("End session").accessibilityIdentifier("chirp.session.end")
        }
        .padding(.leading, ChirpSpacing.s16).padding(.trailing, ChirpSpacing.s4).padding(.vertical, ChirpSpacing.s4)
        .modifier(CapsuleSurface())
        // Chrome like the tab bar: it grows with text size but stops at AX1 so it never covers the screen.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityElement(children: .contain)
    }

    private func label(at date: Date) -> String {
        guard let end = model.expiresAt else { return "Mic on" }
        return "Mic on · \(DictateView.clock(end.timeIntervalSince(date))) left"
    }
}

/// Liquid Glass on iOS 26, a material capsule before that.
private struct CapsuleSurface: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
    }
}

/// Cover every scene (including the scanner sheet) before iOS takes app-switcher snapshots.
struct PrivacyShield: ViewModifier {
    @Environment(\.scenePhase) private var phase
    func body(content: Content) -> some View {
        content.overlay {
            if phase != .active {
                ZStack {
                    Color.chirp.background.ignoresSafeArea()
                    VStack(spacing: ChirpSpacing.s16) {
                        ChirpBrand.glyph.resizable().scaledToFit().frame(width: 96, height: 96)
                            .foregroundStyle(Color.chirp.koi).accessibilityHidden(true)
                        Text("Chirp").font(.largeTitle.bold())
                    }
                }.accessibilityIdentifier("privacyShield")
            }
        }
    }
}
