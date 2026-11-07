import AVFAudio
import ChirpCore
import ChirpIOSCore
import SwiftUI
import UIKit

/// One key that starts and stops dictation from any app on an iPad with a hardware keyboard (#259).
///
/// iPadOS gives apps no system-wide keys and keyboard extensions never receive hardware key presses, so the key is
/// a Full Keyboard Access command that runs a Shortcuts-app shortcut with Chirp's Toggle action. Full Keyboard
/// Access → Commands lists only shortcuts from the user's library (checked on an iPadOS 27 iPad: with no shortcut it
/// has no Shortcuts section, and Chirp's own App Shortcuts do not appear), so the shortcut has to exist. iPadOS offers no way for an app to add one for the user or to
/// open that Settings page (`App-prefs:` paths land on Settings' first page), so this sheet gets each step to one
/// tap, and checks the result live: the first Toggle while it is open shows that the key works, and the test field
/// shows that ⌘V pastes. Toggle starts a session itself when none runs (`needsForegroundToStart`).
enum DictationKey {
    /// The user closed the offer on Dictate or onboarding; it is not shown again.
    static let offerDismissedKey = "chirp.dictationKey.offerDismissed"
    /// Toggle has run at least once, from a key or anywhere else; the offer is no longer needed.
    static let workedKey = "chirp.dictationKey.worked"
    /// Other UI tests force a hardware keyboard too; only `--chirp-dictation-key-offer` runs see the offer. Nothing is
    /// written, so a run on a real device leaves the offer as the user left it.
    static var offerHiddenForTests: Bool {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        return args.contains("--chirp-ui-test") && !args.contains("--chirp-dictation-key-offer")
        #else
        false
        #endif
    }
    /// The action's name as Shortcuts lists it.
    static let actionName = "Toggle Chirp dictation"

    /// Apple's documented URL for a new, empty shortcut. On iPadOS 27 it opens the "Describe a shortcut" view; Editor
    /// switches to the action list.
    static func openShortcuts() {
        if let url = URL(string: "shortcuts://create-shortcut") { UIApplication.shared.open(url) }
    }
    /// Settings, at Chirp's page; Accessibility is in the sidebar beside it.
    static func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

/// The offer on Dictate and in onboarding: an iPad with a hardware keyboard attached, once, until it is set up or
/// closed.
struct DictationKeyOffer: View {
    var open: () -> Void
    var dismiss: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .top, spacing: ChirpSpacing.s12) {
            if !typeSize.isAccessibilitySize {
                Image(systemName: "command").font(.title3.weight(.semibold)).foregroundStyle(Color.chirp.koi)
                    .frame(width: 28, height: 28).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: ChirpSpacing.s4) {
                Text("Dictate from any app with one key").font(.headline).foregroundStyle(Color.chirp.ink)
                Text("Press a key on your keyboard to start Chirp in any app, and again to stop.")
                    .font(.subheadline).foregroundStyle(Color.chirp.inkMuted)
                Button("Set up a dictation key", action: open).buttonStyle(.pondTonal).padding(.top, ChirpSpacing.s4)
                    .accessibilityIdentifier("chirp.dictationKey.offer.open")
            }
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark").font(.body.weight(.semibold)) }
                .foregroundStyle(Color.chirp.inkMuted).frame(width: 44, height: 44)
                .accessibilityLabel("Not now").accessibilityIdentifier("chirp.dictationKey.offer.dismiss")
        }
        .padding(ChirpSpacing.s16)
        .background(Color.chirp.surface, in: RoundedRectangle(cornerRadius: ChirpRadius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ChirpRadius.panel, style: .continuous).strokeBorder(Color.chirp.surfaceRaised))
        .accessibilityElement(children: .contain).accessibilityIdentifier("chirp.dictationKey.offer")
    }
}

/// Set up a dictation key: two one-tap steps and a live test.
struct DictationKeySetup: View {
    @ObservedObject var model: SessionCoordinator
    @Environment(\.dismiss) private var dismiss
    @AppStorage(DictationKey.workedKey) private var worked = false
    @State private var openedAt = Date()
    @State private var microphone = AVAudioApplication.shared.recordPermission
    @State private var pasted = ""
    @FocusState private var fieldFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    /// Toggle runs since this sheet opened.
    private var run: SessionCoordinator.ToggleRun? { model.lastToggle.flatMap { $0.at >= openedAt ? $0 : nil } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ChirpSpacing.s24) {
                    Text("Press your key in any app to start dictating, and press it again to stop. Chirp copies the text, so press ⌘V to paste it. If no session is running, the key starts one.")
                        .font(.body).foregroundStyle(Color.chirp.inkMuted)
                    readiness
                    step(1, title: "Make the shortcut",
                         body: "Shortcuts opens a new shortcut. If it asks you to describe the shortcut, tap Editor at the top right. Find \(DictationKey.actionName) in the actions on the right (search for it, or tap Chirp under Apps) and tap it. Then tap the shortcut’s name at the top and rename it Chirp dictation, so you can find it in the next step.",
                         button: "Open Shortcuts", symbol: "square.stack.3d.up", identifier: "chirp.dictationKey.shortcuts",
                         action: DictationKey.openShortcuts)
                    step(2, title: "Give it a key",
                         body: "In Settings, open Accessibility → Keyboards & Typing → Full Keyboard Access and turn it on. Tap Commands, scroll to Shortcuts, choose Chirp dictation and press the keys you want, such as ⌃⌥D.",
                         button: "Open Settings", symbol: "gear", identifier: "chirp.dictationKey.settings",
                         action: DictationKey.openSettings)
                    Text("Full Keyboard Access also lets Tab and the arrow keys move a focus ring. Turn on Auto-Hide on its page to hide the ring until you use it.")
                        .font(.footnote).foregroundStyle(Color.chirp.inkMuted)
                    test
                }
                .frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity)
                .padding(ChirpSpacing.s24)
            }
            .background(Color.chirp.background)
            .navigationTitle("Set up a dictation key").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("chirp.dictationKey.done") } }
        }
        .presentationDetents([.large])
        .presentationCornerRadius(ChirpRadius.sheet)
        .modifier(PrivacyShield())
        .onChange(of: model.lastToggle) { _, value in if value != nil { worked = true } }
        .onChange(of: scenePhase) { _, phase in if phase == .active { microphone = AVAudioApplication.shared.recordPermission } }
        .accessibilityIdentifier("chirp.dictationKey.setup")
    }

    // MARK: Ready to start from another app

    /// What the key needs from Chirp itself: a pairing and the microphone. A running session is not needed.
    @ViewBuilder private var readiness: some View {
        VStack(alignment: .leading, spacing: ChirpSpacing.s8) {
            check(model.paired, model.paired ? "Paired with \(model.pairedDevice ?? "your computer")" : "Pair your computer first (Settings → Connection)")
            if model.microphoneAllowed || microphone == .granted {
                check(true, "Microphone allowed")
            } else {
                HStack(spacing: ChirpSpacing.s12) {
                    check(false, microphone == .denied ? "Microphone off for Chirp" : "Microphone not allowed yet")
                    Spacer(minLength: 0)
                    Button(microphone == .denied ? "Open Settings" : "Allow") {
                        if microphone == .denied { DictationKey.openSettings() }
                        else { Task { _ = await AVAudioApplication.requestRecordPermission(); microphone = AVAudioApplication.shared.recordPermission } }
                    }
                    .buttonStyle(.pondTonal).accessibilityIdentifier("chirp.dictationKey.microphone")
                }
            }
        }
        .accessibilityIdentifier("chirp.dictationKey.readiness")
    }

    private func check(_ done: Bool, _ text: String) -> some View {
        Label(text, systemImage: done ? "checkmark.circle.fill" : "circle")
            .font(.subheadline.weight(done ? .regular : .semibold))
            .foregroundStyle(done ? Color.chirp.lily : Color.chirp.ink)
            .symbolRenderingMode(.hierarchical)
    }

    private func step(_ number: Int, title: String, body: String, button: String, symbol: String, identifier: String,
                      action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: ChirpSpacing.s8) {
            Text("\(number). \(title)").font(.headline).foregroundStyle(Color.chirp.ink).accessibilityAddTraits(.isHeader)
            Text(body).font(.subheadline).foregroundStyle(Color.chirp.inkMuted).fixedSize(horizontal: false, vertical: true)
            Button(button, systemImage: symbol, action: action).buttonStyle(.pondTonal).accessibilityIdentifier(identifier)
        }
    }

    // MARK: Live test

    private enum Progress { case waiting, listening, copied, pasted }
    private var progress: Progress {
        guard let run else { return .waiting }
        if run.started { return .listening }
        return pasted.isEmpty ? .copied : .pasted
    }

    private var test: some View {
        VStack(alignment: .leading, spacing: ChirpSpacing.s8) {
            Text("3. Try it").font(.headline).foregroundStyle(Color.chirp.ink).accessibilityAddTraits(.isHeader)
            Group {
                switch progress {
                case .waiting:
                    Label("Press your key, say a few words, then press it again.", systemImage: "keyboard")
                        .foregroundStyle(Color.chirp.inkMuted)
                case .listening:
                    Label(model.phase == .listening ? "Your key works. Listening… press it again to stop." : "Your key works. Starting…",
                          systemImage: "checkmark.circle.fill").foregroundStyle(Color.chirp.lily)
                case .copied:
                    Label(model.phase == .correcting ? "Polishing…" : "Copied. Press ⌘V in the field below.",
                          systemImage: "checkmark.circle.fill").foregroundStyle(Color.chirp.lily)
                case .pasted:
                    Label("All set. Your key works in any app.", systemImage: "checkmark.seal.fill").foregroundStyle(Color.chirp.lily)
                }
            }
            .font(.subheadline.weight(.semibold)).symbolRenderingMode(.hierarchical)
            .accessibilityAddTraits(.updatesFrequently).accessibilityIdentifier("chirp.dictationKey.status")
            TextField("Paste here with ⌘V", text: $pasted, axis: .vertical)
                .lineLimit(2...5).focused($fieldFocused)
                .padding(ChirpSpacing.s12)
                .background(Color.chirp.surface, in: RoundedRectangle(cornerRadius: ChirpRadius.panel, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: ChirpRadius.panel, style: .continuous)
                    .strokeBorder(fieldFocused ? Color.chirp.koi : Color.chirp.surfaceRaised, lineWidth: fieldFocused ? 2 : 1))
                .accessibilityIdentifier("chirp.dictationKey.field")
        }
    }
}
