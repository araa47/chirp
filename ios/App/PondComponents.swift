import AVFAudio
import ChirpIOSCore
import SwiftUI
import UIKit

// Pond building blocks shared by the app's screens (#192): the one-banner slot, the ⓘ help sheet, the
// connection chip, the setup progress card, the other-apps guide and the button/chip styles. Ports of
// Android's `ui/ChirpComponents.kt` (StatusBanner, InfoSheet, LearnMore) and the Notes ConnectionChip.

// MARK: - Buttons and chips

/// The one koi primary action on a screen: a full-width filled capsule that wraps at large text sizes.
struct PondPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold)).multilineTextAlignment(.center)
            .foregroundStyle(Color.chirp.onKoi)
            .frame(maxWidth: .infinity, minHeight: 50).padding(.horizontal, ChirpSpacing.s16).padding(.vertical, ChirpSpacing.s4)
            .background(Color.chirp.koi.opacity(enabled ? 1 : 0.4), in: Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(Capsule())
    }
}

/// A tonal capsule for secondary actions that still matter (Start keyboard session, a setup fix): koiContainer
/// in light; in dark a raised pond surface with koi text, as on Mac and Android (the dark koiContainer reads muddy).
struct PondTonalButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold)).multilineTextAlignment(.center)
            .foregroundStyle(scheme == .dark ? Color.chirp.koi : Color.chirp.onKoiContainer)
            .frame(minHeight: 44).padding(.horizontal, ChirpSpacing.s16).padding(.vertical, ChirpSpacing.s4)
            .background(scheme == .dark ? Color.chirp.surfaceRaised : Color.chirp.koiContainer, in: Capsule())
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .contentShape(Capsule())
    }
}

/// A capsule chip (result actions, quick choices): surfaceRaised fill, at least 44 pt tall.
struct CapsuleChipStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium)).labelStyle(.titleAndIcon).symbolRenderingMode(.hierarchical)
            .foregroundStyle(Color.chirp.ink)
            .frame(minHeight: 44).padding(.horizontal, ChirpSpacing.s16)
            .background(Color.chirp.surfaceRaised, in: Capsule())
            .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == PondPrimaryButtonStyle { static var pondPrimary: PondPrimaryButtonStyle { .init() } }
extension ButtonStyle where Self == PondTonalButtonStyle { static var pondTonal: PondTonalButtonStyle { .init() } }
extension ButtonStyle where Self == CapsuleChipStyle { static var capsuleChip: CapsuleChipStyle { .init() } }

// MARK: - Banner

/// One status banner. Screens show at most one at a time, picked by priority, each with one fix.
struct PondBanner: View {
    enum Kind { case info, success, warning, error }
    let kind: Kind
    let title: String
    var detail: String?
    var action: String?
    var actionID: String?
    var perform: () -> Void = {}

    var body: some View {
        let (fill, ink) = colors
        ViewThatFits(in: .horizontal) {
            HStack(spacing: ChirpSpacing.s12) { icon; text; Spacer(minLength: 0); button(ink) }
            VStack(alignment: .leading, spacing: ChirpSpacing.s8) {
                HStack(alignment: .top, spacing: ChirpSpacing.s12) { icon; text }
                button(ink)
            }
        }
        .foregroundStyle(ink)
        .padding(.horizontal, ChirpSpacing.s16).padding(.vertical, ChirpSpacing.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: ChirpRadius.panel, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var icon: some View {
        Image(systemName: symbol).symbolRenderingMode(.hierarchical).font(.body.weight(.semibold))
            .foregroundStyle(kind == .success ? Color.chirp.lily : kind == .error ? Color.chirp.record : colors.1)
            .accessibilityHidden(true)
    }

    private var text: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline.weight(.semibold))
            if let detail { Text(detail).font(.footnote) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine).accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder private func button(_ ink: Color) -> some View {
        if let action {
            Button(action, action: perform)
                .font(.subheadline.weight(.semibold)).foregroundStyle(ink)
                .frame(minHeight: 44).padding(.horizontal, ChirpSpacing.s12)
                .background(ink.opacity(0.12), in: Capsule())
                .accessibilityIdentifier(actionID ?? "")
        }
    }

    private var symbol: String {
        switch kind {
        case .info: "info.circle"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    /// Fill and ink. Error uses Android's errorContainer pair (the record family); the rest are Pond tokens.
    private var colors: (Color, Color) {
        switch kind {
        case .info, .success: (Color.chirp.surfaceRaised, Color.chirp.ink)
        case .warning: (Color.chirp.warningContainer, Color.chirp.onWarningContainer)
        case .error: (PondBanner.errorContainer, PondBanner.onErrorContainer)
        }
    }
    static let errorContainer = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0x5C / 255, green: 0x1D / 255, blue: 0x1D / 255, alpha: 1)
        : UIColor(red: 0xFF / 255, green: 0xDA / 255, blue: 0xD5 / 255, alpha: 1) })
    static let onErrorContainer = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 0xFF / 255, green: 0xD9 / 255, blue: 0xD4 / 255, alpha: 1)
        : UIColor(red: 0x5C / 255, green: 0x13 / 255, blue: 0x13 / 255, alpha: 1) })
}

// MARK: - Help behind ⓘ

/// Long explanations live here, so screens show one line plus an ⓘ or "Learn more".
struct InfoSheet<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: ChirpSpacing.s16) { content }
                    .font(.body).foregroundStyle(.secondary)
                    .frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity)
                    .padding(ChirpSpacing.s24)
            }
            .background(Color.chirp.background)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationCornerRadius(ChirpRadius.sheet)
        .modifier(PrivacyShield())
    }
}

/// An ⓘ (or text) button that opens an `InfoSheet`.
struct LearnMore<Content: View>: View {
    let title: String
    var label: String?
    @ViewBuilder var content: () -> Content
    @State private var open = false
    var body: some View {
        Button { open = true } label: {
            if let label { Text(label).font(.subheadline.weight(.semibold)) }
            else { Image(systemName: "info.circle").font(.title3).symbolRenderingMode(.hierarchical) }
        }
        .frame(minWidth: 44, minHeight: 44)
        .accessibilityLabel(label ?? "About \(title)")
        .sheet(isPresented: $open) { InfoSheet(title: title, content: content) }
    }
}

// MARK: - Connection chip

/// The toolbar connection status (Android's ConnectionChip): lily "Computer" when the computer answers, muted
/// "Offline" or "Not paired" otherwise. Tapping opens Settings → Connection.
struct ConnectionChip: View {
    @ObservedObject var model: SessionCoordinator
    var open: () -> Void

    nonisolated static func status(paired: Bool, issue: ConnectionIssue?) -> (label: String, connected: Bool) {
        guard paired else { return ("Not paired", false) }
        return issue == nil ? ("Computer", true) : ("Offline", false)
    }

    var body: some View {
        let status = Self.status(paired: model.paired, issue: model.connectionIssue)
        Button(action: open) {
            HStack(spacing: 6) {
                Circle().fill(status.connected ? Color.chirp.lily : Color.chirp.inkMuted).frame(width: 8, height: 8)
                Text(status.label).font(.subheadline.weight(.medium))
                    .foregroundStyle(status.connected ? Color.chirp.lily : Color.chirp.inkMuted)
            }
            .padding(.horizontal, 4).frame(minHeight: 44)
        }
        .accessibilityLabel("Connection: \(status.label). Open connection settings")
        .accessibilityIdentifier("chirp.connection.chip")
    }
}

// MARK: - Setup progress

/// What's left to set up, in order: pair the Mac, allow the microphone, turn on Chirp Keyboard. Notes shows
/// the first missing step as a dismissible card (#193 renders it in the library); onboarding checks them off.
struct SetupProgress: Equatable {
    enum Step: CaseIterable { case pair, microphone, keyboard }
    var paired: Bool
    var microphone: Bool
    var keyboard: Bool

    @MainActor init(model: SessionCoordinator, microphone: Bool = AVAudioApplication.shared.recordPermission == .granted) {
        self.init(paired: model.paired, microphone: microphone, keyboard: model.keyboardReady)
    }
    init(paired: Bool, microphone: Bool, keyboard: Bool) {
        self.paired = paired; self.microphone = microphone; self.keyboard = keyboard
    }

    func done(_ step: Step) -> Bool {
        switch step { case .pair: paired; case .microphone: microphone; case .keyboard: keyboard }
    }
    var firstMissing: Step? { Step.allCases.first { !done($0) } }
    var isComplete: Bool { firstMissing == nil }

    static func title(_ step: Step) -> String {
        switch step {
        case .pair: "Pair your computer"
        case .microphone: "Allow the microphone"
        case .keyboard: "Turn on Chirp Keyboard"
        }
    }
    static func fix(_ step: Step) -> String {
        switch step {
        case .pair: "Pair computer"
        case .microphone: "Allow"
        case .keyboard: "Open Settings"
        }
    }
}

/// The dismissible "finish setting up" card: names the first missing step and offers its one fix.
struct SetupCard: View {
    let progress: SetupProgress
    var fix: (SetupProgress.Step) -> Void
    var dismiss: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        if let step = progress.firstMissing {
            HStack(alignment: .top, spacing: ChirpSpacing.s12) {
                // At accessibility sizes the glyph gives its column to the text (#271 L2).
                if !typeSize.isAccessibilitySize {
                    ChirpBrand.glyph.resizable().scaledToFit().frame(width: 28, height: 28)
                        .foregroundStyle(Color.chirp.koi).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: ChirpSpacing.s4) {
                    Text("Finish setting up").font(.headline).foregroundStyle(Color.chirp.ink)
                    Text("Next: \(SetupProgress.title(step).lowercasedFirst)").font(.subheadline).foregroundStyle(Color.chirp.inkMuted)
                    Button(SetupProgress.fix(step)) { fix(step) }.buttonStyle(.pondTonal).padding(.top, ChirpSpacing.s4)
                        .accessibilityIdentifier("chirp.setup.fix")
                }
                Spacer(minLength: 0)
                Button { dismiss() } label: { Image(systemName: "xmark").font(.body.weight(.semibold)) }
                    .foregroundStyle(Color.chirp.inkMuted).frame(width: 44, height: 44)
                    .accessibilityLabel("Dismiss setup")
            }
            .padding(ChirpSpacing.s16)
            .background(Color.chirp.surface, in: RoundedRectangle(cornerRadius: ChirpRadius.panel, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: ChirpRadius.panel, style: .continuous).strokeBorder(Color.chirp.surfaceRaised))
            .accessibilityElement(children: .contain).accessibilityIdentifier("chirp.setup")
        }
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

// MARK: - Other apps

/// Ways to dictate outside Chirp. Lives behind ⓘ on Dictate; #194 embeds it in Settings → Keyboard.
struct OtherAppsGuide: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("On screen: tap a text field in any app, touch and hold the globe key and choose Chirp. Tap Start dictation, then Stop dictation. The text appears where you were typing. Tap the globe key to go back to your usual keyboard.",
                  systemImage: "hand.tap")
            Label("With a hardware keyboard: iPadOS hides on-screen keyboards, Chirp Keyboard included (with it selected, nothing may show at the bottom of the screen). Use a dictation key instead, or the floating mic with its Record button on (Settings → Dictation → Floating mic). To get Apple's keyboard bar back, press 🌐 (or Control-Space) on the hardware keyboard.",
                  systemImage: "keyboard")
            Label("From any app with a hardware keyboard: press ⌘Space, type Toggle dictation and press Return. Do it again to stop. The text is copied, so press ⌘V to paste. If no session is running, Toggle starts one.",
                  systemImage: "magnifyingglass")
            Label("One key for it: Settings → Dictation → Keyboard shortcut → Set up a dictation key walks you through it in two steps and tests the key.",
                  systemImage: "command")
            Label("Inside Chirp: hold Right ⌥ Option to dictate into the field you are typing in (change it in Settings → Dictation → Keyboard shortcut). ⌘Return starts or stops dictation, ⌘. cancels, ⌘⇧K starts a keyboard session and ⌘⇧E ends it. Hold ⌘ to see every shortcut.",
                  systemImage: "keyboard.badge.ellipsis")
        }.font(.subheadline).symbolRenderingMode(.hierarchical).padding(.top, 8)
    }
}
