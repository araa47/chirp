import ChirpCore
import ChirpIOSCore
import SwiftUI
import UIKit

// The Settings detail pages (#194): Connection, Microphone session, Dictation, Keyboard, Privacy &
// history and About. Every page is groups of rows (SettingsRows.swift); a row shows one line plus an
// optional one-line summary, and every paragraph that used to sit under a control lives behind its ⓘ
// InfoSheet. The facts are Android's `SettingsPages.kt` with iOS's existing text moved, not deleted.

/// Every page: groups scrolling on the Pond background, centred at a readable width.
struct SettingsPageScroll<Content: View>: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ChirpSpacing.s24) { content }
                .padding(.horizontal, ChirpSpacing.gutter(sizeClass)).padding(.vertical, ChirpSpacing.s16)
                .frame(maxWidth: 640).frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color.chirp.background)
    }
}

// MARK: - Connection

/// The saved pairing and how to change it: one status banner (lily when the Mac answers, warning
/// otherwise), Check connection, Change pairing, this device's name, and Forget pairing (confirmed).
struct ConnectionPage: View {
    @ObservedObject var model: SessionCoordinator
    @State private var forget = false
    var body: some View {
        SettingsPageScroll {
            let status = model.connectionStatus
            PondBanner(kind: status.kind, title: status.title, detail: status.hint ?? status.detail)
                .accessibilityIdentifier("chirp.connection.banner")
            OnboardingCopy.pairingStepsText(.subheadline)
                .foregroundStyle(Color.chirp.inkMuted)
                .accessibilityLabel(OnboardingCopy.pairingSteps)
            SettingsGroup {
                if model.paired {
                    ActionRow(title: "Check connection", symbol: "arrow.triangle.2.circlepath", disabled: model.working,
                              identifier: "chirp.connection.check") { Task { await model.checkConnection() } }
                }
                NavRow(title: model.paired ? "Change pairing" : "Pair computer", symbol: "qrcode.viewfinder",
                       identifier: "chirp.pair.change") {
                    ChangePairingPage(model: model)
                }
            }
            if model.paired {
                SettingsGroup {
                    deviceRow
                    ActionRow(title: "Forget pairing", symbol: "trash", destructive: true) { forget = true }
                        .accessibilityIdentifier("chirp.pair.forget")
                }
            }
        }
        .confirmationDialog("Forget this computer?", isPresented: $forget, titleVisibility: .visible) {
            Button("Forget", role: .destructive) { model.forgetPairing() }
        } message: {
            Text("You’ll need to scan a new code to dictate. This also ends the session.")
        }
    }

    /// This device's pairing name, or the shared-token state with its explanation behind ⓘ.
    private var deviceRow: some View {
        RowTile(hasSummary: true) {
            RowText(title: "This device",
                    summary: model.pairedDevice ?? "Paired with your computer’s shared token")
            Spacer(minLength: 0)
            LearnMore(title: "This device") {
                if let device = model.pairedDevice {
                    Text("Paired as “\(device)”. The computer lists this pairing under that name, and it can be revoked on its own.")
                } else {
                    Text("Paired with your computer’s shared token. For a pairing you can revoke on its own, run chirp-server pair --name \"\(UIDevice.current.model)\" on your computer and pair again.")
                }
            }
        }.accessibilityIdentifier("chirp.pair.device")
    }
}

/// Connection → Change pairing: the QR-first pairing form (the same one onboarding uses), pushed.
struct ChangePairingPage: View {
    @ObservedObject var model: SessionCoordinator
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        SettingsPageScroll {
            SettingsGroup {
                SettingsItem {
                    OnboardingCopy.pairingStepsText(.subheadline)
                        .foregroundStyle(Color.chirp.inkMuted)
                        .accessibilityLabel(OnboardingCopy.pairingSteps)
                    PairingForm(model: model, paired: { dismiss() })
                }
            }
            if !model.notice.isEmpty {
                Text(model.notice).font(.footnote).foregroundStyle(Color.chirp.inkMuted)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .navigationTitle(model.paired ? "Change pairing" : "Pair computer")
    }
}

/// Row summaries that follow their switch, so a row never says "Off by default" while it is on (#271 T14).
enum SettingsSummary {
    static func spokenCommands(on: Bool) -> String { on ? "On" : "Off by default" }
    static func history(on: Bool) -> String { (on ? "On" : "Off by default") + " · encrypted on this device only" }
    static func pause(on: Bool) -> String { on ? "Paused · new dictations aren’t saved" : "Off" }
}

// MARK: - Microphone session

/// Session length, End session (while armed) and the microphone permission link.
struct SessionPage: View {
    @ObservedObject var model: SessionCoordinator
    var body: some View {
        SettingsPageScroll {
            SettingsGroup(title: "Session length") {
                SettingsItem {
                    Text("How long an armed session keeps the microphone").font(.subheadline).foregroundStyle(Color.chirp.inkMuted)
                    ChoiceChips(options: SessionDuration.allCases, selection: durationBinding, label: { $0.label })
                    if model.armed {
                        Text("End the session to change its length.").font(.footnote).foregroundStyle(Color.chirp.inkMuted)
                    }
                    LearnMore(title: "Session length", label: "About session length") {
                        Text("The armed session ends by itself after this length, or when it is interrupted, terminated or its permission is revoked. Never lasts until ended. iOS may suspend or stop the app; indefinite background execution is not guaranteed.")
                    }
                }
            }
            SettingsGroup {
                if model.armed {
                    ActionRow(title: "End session", symbol: "stop.circle", destructive: true) { model.endSession() }
                }
                ActionRow(title: "Open Chirp permissions", symbol: "hand.raised", identifier: "chirp.settings.permissions") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
        }
    }

    private var durationBinding: Binding<SessionDuration> {
        Binding(get: { model.preferences.sessionDuration },
                set: { model.preferences.sessionDuration = $0; model.savePreferences() })
    }
}

// MARK: - Dictation

/// Clean-up (with its consent dialog), the Styles list, Stop dictation, Spoken commands, Press Return and
/// Learning: everything the Dictation category row summarises.
struct DictationPage: View {
    @ObservedObject var model: SessionCoordinator
    @ObservedObject private var shortcuts = HardwareShortcutController.shared
    @State private var consent = false
    var body: some View {
        SettingsPageScroll {
            SettingsGroup(title: "Clean-up") {
                SwitchRow(title: "Clean up final text",
                          isOn: model.preferences.correction,
                          summary: model.cleanupDisclosure,
                          symbol: "text.badge.checkmark",
                          infoTitle: "Clean-up",
                          infoBody: "Starts off. Audio is recognized on your computer. Clean-up only receives the final transcript after you stop. Changes to the clean-up destination suspend consent.",
                          identifier: "chirp.cleanup.enabled", disabled: !model.cleanupCanEnable || model.phase == .correcting,
                          set: { on in if on { consent = true } else { model.setCleanup(false) } })
            }
            StylesList(model: model)
            StopDictationGroup(model: model)
            SettingsGroup(title: "Spoken commands") {
                SwitchRow(title: "Spoken commands",
                          isOn: model.preferences.spokenCommands == true,
                          summary: SettingsSummary.spokenCommands(on: model.preferences.spokenCommands == true),
                          symbol: "text.bubble",
                          infoTitle: "Spoken commands",
                          infoBody: "In Chirp Keyboard, ending a dictation with “new line” or “new paragraph” types a line break instead of the words. Mid-sentence, a common first word such as “so” or “and” starts lower-case.",
                          identifier: "chirp.settings.spokenCommands",
                          set: { on in model.preferences.spokenCommands = on ? true : nil; model.savePreferences() })
            }
            SettingsGroup(title: "Hardware keyboard") {
                NavRow(title: "Keyboard shortcut",
                       summary: shortcuts.shortcut.enabled ? shortcuts.shortcut.instruction : "Off",
                       symbol: "keyboard", identifier: "chirp.settings.hardwareShortcut") {
                    HardwareShortcutSettings(shortcuts: shortcuts)
                }
            }
            SettingsGroup(title: "Press Return after dictating") {
                SettingsItem {
                    Text("After the last words land, Chirp Keyboard types Return")
                        .font(.subheadline).foregroundStyle(Color.chirp.inkMuted)
                    ChoiceChips(options: ["off", "actionKeys", "always"],
                                selection: Binding(get: { model.preferences.autoEnter ?? "off" },
                                                   set: { value in model.preferences.autoEnter = value == "off" ? nil : value; model.savePreferences() }),
                                label: { $0 == "off" ? "Off" : $0 == "actionKeys" ? "On Send, Go or Done" : "Always" })
                        .accessibilityIdentifier("chirp.settings.autoEnter")
                    LearnMore(title: "Press Return after dictating", label: "About Press Return") {
                        Text("Where the field’s Return key is Send, Go or Done, that sends; elsewhere Always types a newline. Never after a failed or partial dictation. A keyboard cannot press an app’s own Send button, such as the one in Messages.")
                    }
                }
            }
            LearningGroup(model: model)
        }
        .confirmationDialog("Enable clean-up?", isPresented: $consent, titleVisibility: .visible) {
            Button("Enable for this destination") { model.setCleanup(true) }
        } message: {
            Text(model.cleanupDisclosure + " Changes to this destination suspend consent.")
        }
    }
}

// MARK: - Keyboard

/// The keyboard's setup state, the ways to dictate outside Chirp (each behind its own sheet) and the
/// hardware-keyboard shortcut table.
struct KeyboardPage: View {
    @ObservedObject var model: SessionCoordinator
    @State private var sheet: WaySheet?

    /// WaysToDictate: the ⓘ texts of #192's OtherAppsGuide, one short row each.
    enum WaySheet: String, CaseIterable, Identifiable {
        case onScreen, hardware, anyApp, oneKey, inside
        var id: String { rawValue }
        var key: String { rawValue }
        var symbol: String {
            switch self { case .onScreen: "hand.tap"; case .hardware: "keyboard"; case .anyApp: "magnifyingglass"; case .oneKey: "command"; case .inside: "keyboard.badge.ellipsis" }
        }
        var title: String {
            switch self { case .onScreen: "On screen"; case .hardware: "With a hardware keyboard"; case .anyApp: "From any app"; case .oneKey: "One key for it"; case .inside: "Inside Chirp" }
        }
        var body: String {
            switch self {
            case .onScreen: "Tap a text field in any app, touch and hold the globe key and choose Chirp. Tap Start dictation, then Stop dictation. The text appears where you were typing. Tap the globe key to go back to your usual keyboard."
            case .hardware: "iPadOS hides on-screen keyboards when a hardware keyboard is attached. Press the globe key (or Control-Space) until Chirp is chosen, then use the small keyboard bar at the bottom of the screen to show it. Chirp Keyboard doesn’t receive hardware keys, so outside Chirp a key can only start and stop (One key for it), not hold."
            case .anyApp: "Start a session here, then press ⌘Space, type Toggle dictation and press Return. Do it again to stop. The text is copied, so press ⌘V to paste."
            case .oneKey: "In the Shortcuts app, make a shortcut with Chirp’s Toggle Chirp dictation action. Then go to Settings → Accessibility → Keyboards & Typing → Full Keyboard Access, turn it on, open Commands and give that shortcut a key combination."
            case .inside: "Hold Right ⌥ Option to dictate into the field you are typing in (Settings → Dictation → Keyboard shortcut). ⌘Return starts or stops dictation, ⌘. cancels, ⌘⇧K starts a keyboard session and ⌘⇧E ends it. Hold ⌘ to see every shortcut."
            }
        }
    }

    var body: some View {
        SettingsPageScroll {
            SettingsGroup {
                RowTile(hasSummary: true) {
                    RowText(title: model.keyboardReady ? "Chirp Keyboard is on with Full Access" : "Chirp Keyboard not detected yet",
                            summary: "Optional. Lets you dictate in other apps.",
                            symbol: model.keyboardReady ? "checkmark.circle.fill" : "keyboard",
                            color: model.keyboardReady ? Color.chirp.lily : Color.chirp.ink)
                    Spacer(minLength: 0)
                    LearnMore(title: "Chirp Keyboard") {
                        Text("In Settings → Chirp → Keyboards, turn on Chirp Keyboard and Allow Full Access (or Settings → General → Keyboard → Keyboards → Add New Keyboard). Then switch to it with the globe key in any app. Full Access enables the encrypted shared mailbox; the keyboard never accesses the microphone. Some apps and secure fields use Apple’s keyboard.")
                        Text("Open Chirp Keyboard once in any app and the status above shows as done.")
                        Text("If the keyboard cannot open Chirp, open the app manually and start a session. Return with the app switcher or system Back affordance. Automatic return to an arbitrary editor is unavailable.")
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("chirp.keyboard.status")
                ActionRow(title: "Open Chirp in Settings", symbol: "arrow.up.forward.app",
                          identifier: "chirp.keyboard.open") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            SettingsGroup(title: "Ways to dictate") {
                ForEach(WaySheet.allCases) { way in
                    ActionRow(title: way.title, symbol: way.symbol) { sheet = way }
                        .accessibilityIdentifier("chirp.keyboard.way." + way.key)
                }
            }
            SettingsGroup(title: "Hardware keyboard") {
                NavRow(title: "Keyboard shortcuts", summary: "⌘Return, ⌘., ⌘⇧K and the rest", symbol: "command.square") {
                    ShortcutsPage()
                }
            }
        }
        .sheet(item: $sheet) { way in
            InfoSheet(title: way.title) { Text(way.body) }
        }
    }
}

/// Keyboard → Keyboard shortcuts: the app's hardware shortcuts as a keycap table.
struct ShortcutsPage: View {
    @ObservedObject private var hardware = HardwareShortcutController.shared

    // The bindings in NotesLibraryView and LiveNotesView: ⌘N is New note, as on the Mac and Android (A2-7).
    static let notesShortcuts: [(title: String, keys: String)] = [
        ("New note", "⌘N"),
        ("Record / Stop note", "⇧⌘R"),
        ("Pause / Resume note", "⇧⌘P"),
        ("Edit by voice", "⇧⌘E"),
        ("Search notes", "⌘F"),
        ("Show or hide transcript", "⌥⌘T"),
    ]

    var body: some View {
        SettingsPageScroll {
            SettingsGroup(title: "Notes") {
                ForEach(Self.notesShortcuts, id: \.keys) { row in
                    shortcut(row.title, row.keys)
                }
            }
            SettingsGroup(title: "Dictation") {
                if hardware.shortcut.enabled {
                    let hw = hardware.shortcut
                    shortcut(hw.mode == .hold ? "Hold to dictate" : "Press to start or stop", hw.title)
                }
                shortcut("Start or stop dictation", "⌘↩")
                shortcut("Cancel dictation", "⌘.")
                shortcut("Copy result", "⇧⌘C")
                shortcut("Use raw transcript", "⇧⌘Z")
                shortcut("Start keyboard session", "⇧⌘K")
                shortcut("End session", "⇧⌘E")
            }
            SettingsGroup(title: "Go") {
                shortcut("Notes, Dictate, History, Settings", "⌘1–4")
            }
            SettingsItem {
                Text("Notes shortcuts work in Notes. Dictation and Go shortcuts work in every Chirp tab. Hold ⌘ to see the available shortcuts.").font(.footnote).foregroundStyle(Color.chirp.inkMuted)
                LearnMore(title: "Global shortcut", label: "Set one key for it") {
                    Text("From any app with a hardware keyboard: start a session in Chirp, then press ⌘Space, type Toggle dictation and press Return. Do it again to stop. The text is copied, so press ⌘V to paste.")
                    Text("For one key: in the Shortcuts app, make a shortcut with Chirp’s Toggle Chirp dictation action. Then go to Settings → Accessibility → Keyboards & Typing → Full Keyboard Access, turn it on, open Commands and give that shortcut a key combination.")
                }
            }
        }.navigationTitle("Keyboard shortcuts")
    }

    private func shortcut(_ title: String, _ keys: String) -> some View {
        RowTile(hasSummary: false) {
            RowText(title: title)
            Spacer(minLength: 0)
            Text(keys).font(.footnote.weight(.medium))
                .padding(.horizontal, ChirpSpacing.s8).frame(minHeight: 28)
                .background(Color.chirp.surfaceRaised, in: RoundedRectangle(cornerRadius: ChirpRadius.control, style: .continuous))
        }.accessibilityElement(children: .combine)
    }
}

// MARK: - Privacy & history

/// Dictation history's opt-in, retention and clear (each confirmed), plus the one-line privacy facts.
struct PrivacyPage: View {
    @ObservedObject var model: SessionCoordinator
    /// Shared with the Settings home, so the row's summary updates beside this page.
    @ObservedObject var history: HistorySettingsModel
    @State private var confirmOff = false
    @State private var confirmClear = false
    var body: some View {
        SettingsPageScroll {
            if !history.failure.isEmpty {
                PondBanner(kind: .error, title: "History storage failed", detail: history.failure)
            }
            SettingsGroup(title: "Dictation history") {
                SwitchRow(title: "Keep dictation history", isOn: history.enabled,
                          summary: SettingsSummary.history(on: history.enabled),
                          symbol: "lock.shield",
                          infoTitle: "Keep dictation history",
                          infoBody: "Off initially. At most 200 nonempty finals. AES-GCM encrypted with a device-only Keychain key, excluded from backup. Disabling deletes history and its key.",
                          identifier: "chirp.history.enabled",
                          set: { on in if on { change { try $0.setEnabled(true) } } else { confirmOff = true } })
                if history.enabled {
                    // Persists until turned off, so it is not a "Private session" (docs/copy.md, #271 A2-12).
                    SwitchRow(title: "Pause dictation history",
                              isOn: model.preferences.privacyMode,
                              summary: SettingsSummary.pause(on: model.preferences.privacyMode),
                              symbol: "pause.circle",
                              infoTitle: "Pause dictation history",
                              infoBody: "Stays on until you turn it off, here or in Chirp Keyboard’s Style menu. Dictation history is kept; new dictations aren’t added. Chirp cannot detect every editor’s private mode, so pause before private dictation. No surrounding editor text is collected.",
                              identifier: "chirp.settings.private",
                              set: { on in model.preferences.privacyMode = on; model.savePreferences() })
                    SettingsItem {
                        Text("Keep for").font(.subheadline).foregroundStyle(Color.chirp.inkMuted)
                        ChoiceChips(options: HistoryRetention.allCases,
                                    selection: Binding(get: { history.retention },
                                                       set: { option in
                                           history.retention = option
                                           change { try $0.setRetention(option) }
                                       }),
                                    label: { $0.label })
                    }
                    ActionRow(title: "Clear all history", symbol: "trash", destructive: true) { confirmClear = true }
                        .accessibilityIdentifier("chirp.history.clear")
                }
            }
            SettingsGroup(title: "What Chirp keeps") {
                SettingsItem {
                    Text("Dictations, notes and diagnostics never leave this device on their own.")
                        .font(.subheadline).foregroundStyle(Color.chirp.ink)
                    LearnMore(title: "Local only") {
                        Text("Dictation history is opt-in and encrypted on this device only. Notes stay on this device and are never backed up or synced. Diagnostics carry numbers only — no text, audio, hosts or tokens.")
                        Text("Audio goes to your paired computer only while you dictate or record; idle audio is discarded on device. Audio is written to disk only if you turn on Keep audio with notes (Settings → Notes): then each note’s speech is sealed on this device until you delete it. If your computer is unreachable during a Notes recording, up to the last ten minutes wait in memory, never on disk.")
                    }
                }
            }
        }
        .confirmationDialog("Turn off dictation history?", isPresented: $confirmOff, titleVisibility: .visible) {
            Button("Turn off and delete", role: .destructive) { change { try $0.setEnabled(false) } }
        } message: {
            Text("This deletes every saved dictation from this device. New dictations won’t be saved.")
        }
        .confirmationDialog("Clear dictation history?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear all", role: .destructive) { change { try $0.clear() } }
        } message: {
            Text("History stays on for new dictations.")
        }
    }

    private func change(_ action: (HistoryStore) throws -> Void) {
        do {
            guard let store = model.services?.history else { throw SessionFailure.storage }
            try action(store)
        } catch { history.failure = SessionFailure.storage.localizedDescription }
        history.reload(model.services)
    }
}

// MARK: - About

/// Version, the privacy summary, content-free diagnostics (timings, Share, Clear) and Show setup again.
struct AboutPage: View {
    @ObservedObject var model: SessionCoordinator
    var showSetup: () -> Void
    @State private var privacy = false
    var body: some View {
        SettingsPageScroll {
            SettingsGroup {
                RowTile(hasSummary: false) {
                    RowText(title: "Version", summary: SettingsHome.versionSummary)
                }
                .accessibilityElement(children: .combine)
                ActionRow(title: "Privacy", summary: "What Chirp keeps, and what never leaves this device", symbol: "lock.shield") {
                    privacy = true
                }
                .accessibilityIdentifier("chirp.about.privacy")
            }
            SettingsGroup(title: "Diagnostics") {
                SettingsItem {
                    VStack(alignment: .leading, spacing: ChirpSpacing.s4) {
                        Text(model.timingSummary).font(.caption.monospaced()).textSelection(.enabled)
                            .accessibilityIdentifier("chirp.diagnostics.timings")
                        Divider()
                        Text(model.diagnosticText).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(ChirpSpacing.s12)
                    .background(Color.chirp.surfaceRaised, in: RoundedRectangle(cornerRadius: ChirpRadius.row, style: .continuous))
                    Text("Numbers only — no transcripts, prompts, audio, addresses or credentials.")
                        .font(.footnote).foregroundStyle(Color.chirp.inkMuted)
                    ShareLink(item: model.diagnosticText) { Label("Share diagnostics", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.capsuleChip).frame(maxWidth: .infinity, alignment: .leading)
                }
                ActionRow(title: "Clear timings", symbol: "trash", destructive: true) { model.clearTimings() }
                    .accessibilityIdentifier("chirp.diagnostics.clear")
            }
            SettingsGroup {
                ActionRow(title: "Show setup again", symbol: "arrow.counterclockwise", identifier: "chirp.settings.showSetup", action: showSetup)
            }
        }
        .sheet(isPresented: $privacy) {
            InfoSheet(title: "Privacy") {
                Text("Nothing persistent by default: audio is not written to disk unless you turn on Keep audio with notes (Settings → Notes), which seals each note’s speech on this device until you delete it. History is opt-in, encrypted on this device only and never backed up or synced. Audio goes to your paired computer only while you dictate or record; idle audio is discarded. If your computer is unreachable during a Notes recording, up to the last ten minutes wait in memory, never on disk.")
                Text("Diagnostics are content-free: version, OS, phase, fixed local error codes, durations and counts — no transcripts, prompts, audio, addresses, network names or credentials. No telemetry, no background sync, no analytics.")
            }
        }
    }
}
