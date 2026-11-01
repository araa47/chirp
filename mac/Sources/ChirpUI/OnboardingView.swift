import AppKit
import SwiftUI
import ChirpCore

/// Everything the first-run window shows. The controller reads it from the system; the snapshots pass fixed values.
public struct OnboardingState: Sendable {
    public var flow = OnboardingFlow()
    public var checks = OnboardingChecks()
    public var hotkey: KeyCombo = .defaultDictation
    /// New Note's shortcut, shown with the dictation one on the last step.
    public var notesHotkey: KeyCombo = .controlOptionN
    public var activationMode: ActivationMode = .autoStop
    public var localModelsAvailable = false

    public init() {}
    public init(step: OnboardingStep, checks: OnboardingChecks = OnboardingChecks(), heardHotkey: Bool = false,
                hotkey: KeyCombo = .defaultDictation) {
        var flow = OnboardingFlow()
        while flow.step != step { flow.advance(markDone: {}) }
        flow.heardHotkey = heardHotkey
        self.flow = flow
        self.checks = checks
        self.hotkey = hotkey
    }
}

/// What a step's status row says: the words, the symbol tone and the label of its Fix button (nil when there is
/// nothing to fix). Pure, so the wording is tested without a window.
public struct OnboardingStatus: Equatable, Sendable {
    public var text: String
    public var tone: MenuEntry.Tone
    public var fixTitle: String?

    public static func of(_ step: OnboardingStep, _ checks: OnboardingChecks) -> OnboardingStatus? {
        switch step {
        case .welcome, .tryIt: return nil
        case .microphone:
            switch checks.microphone {
            case .granted: return .init(text: "Allowed", tone: .ok)
            case .notAsked: return .init(text: "Not asked yet", tone: .warning, fixTitle: "Allow…")
            case .denied: return .init(text: "Blocked in System Settings", tone: .error, fixTitle: "Open Settings…")
            }
        case .accessibility:
            return checks.accessibility ? .init(text: "Allowed", tone: .ok)
                                        : .init(text: "Not allowed yet", tone: .warning, fixTitle: "Allow…")
        case .server:
            switch checks.server {
            case .ready(let engine): return .init(text: engine.map { "Connected — \($0)" } ?? "Connected", tone: .ok)
            case .loadingModel: return .init(text: "Loading the speech model…", tone: .warning)
            case .checking: return .init(text: "Checking…", tone: .warning)
            case .unreachable(let host): return .init(text: "Can’t reach \(host)", tone: .error, fixTitle: "Copy Fix Command")
            case .noToken: return .init(text: "No pairing code yet — start Chirp on this Mac once", tone: .warning, fixTitle: "Copy Fix Command")
            }
        }
    }

    init(text: String, tone: MenuEntry.Tone, fixTitle: String? = nil) {
        self.text = text; self.tone = tone; self.fixTitle = fixTitle
    }
}

/// What a step's mark in the left rail shows, live: the step you are on, ✓ for one that is in order, ⚠ for one that needs
/// attention, and a hollow number for one still ahead. Pure, so the rules are tested without a window.
public enum OnboardingRail {
    public enum Mark: Equatable, Sendable { case current, done, warning, upcoming }

    public static func marks(_ flow: OnboardingFlow, _ checks: OnboardingChecks) -> [Mark] {
        OnboardingStep.allCases.map { step in
            let satisfied = flow.isSatisfied(step, checks)
            switch step.rawValue {
            case ..<flow.step.rawValue:
                // A step already passed shows how it stands now: a permission revoked later turns it ⚠.
                return step == .tryIt || satisfied ? .done : .warning
            case flow.step.rawValue:
                return .current
            default:
                // Still ahead: only a check that already passes (the microphone was granted earlier) shows its ✓.
                return step != .welcome && step != .tryIt && satisfied ? .done : .upcoming
            }
        }
    }

    /// What VoiceOver reads for a step's row.
    public static func label(_ step: OnboardingStep, _ mark: Mark) -> String {
        switch mark {
        case .current: "\(step.title), current step"
        case .done: "\(step.title), done"
        case .warning: "\(step.title), needs attention"
        case .upcoming: step.title
        }
    }
}

/// The first-run window's content: a step rail at the left with live ✓/⚠ states, and at the right one step's explanation,
/// its live status and Back / Continue. Plain AppKit like Settings. Controls are exposed so the owner can attach actions.
@MainActor
public final class OnboardingView: NSView {
    public static let size = NSSize(width: 720, height: 460)
    static let railWidth: CGFloat = 220
    static let paneWidth = size.width - railWidth

    public let primary = NSButton(title: "", target: nil, action: nil)
    public let back = NSButton(title: "Back", target: nil, action: nil)
    public let fix = NSButton(title: "Fix…", target: nil, action: nil)
    /// The last step's way into the library: finishes setup and opens Notes.
    public let openNotes = NSButton(title: "Open Notes", target: nil, action: nil)
    /// Where the Try it step's dictation lands.
    public let tryField = NSTextField(string: "")

    private let icon: NSImage?
    private let pond: NSImage?
    private let content = NSStackView()
    private let rail = NSStackView()
    private var shownStep: OnboardingStep?

    /// - Parameters:
    ///   - icon: the brand glyph (template), for the rail's header.
    ///   - pond: the app's pond art, the welcome hero.
    public init(icon: NSImage?, pond: NSImage? = ChirpBrand.pond()) {
        self.icon = icon
        self.pond = pond
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        primary.bezelStyle = .rounded
        primary.keyEquivalent = "\r"
        // The accent even where the bundle's AccentColor is not there (unbundled runs, snapshots). v2 fills it with the
        // plan's accent asset values (white label: 4.70:1 on #2F6FE0, 3.57:1 on #4B86E8), not the lighter text accent.
        primary.bezelColor = ChirpDesign.current == .v2
            ? NSColor(name: "ChirpV2Primary") { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(srgbRed: 0x4B / 255, green: 0x86 / 255, blue: 0xE8 / 255, alpha: 1)
                    : NSColor(srgbRed: 0x2F / 255, green: 0x6F / 255, blue: 0xE0 / 255, alpha: 1)
            }
            : .chirpKoi
        back.bezelStyle = .rounded
        openNotes.bezelStyle = .rounded
        openNotes.setAccessibilityLabel("Finish setup and open Notes")
        fix.bezelStyle = .rounded
        fix.controlSize = .small
        fix.setAccessibilityLabel("Fix this step")
        tryField.placeholderString = "Your dictation appears here"
        tryField.font = .systemFont(ofSize: 15)
        tryField.setAccessibilityLabel("Try dictation here")

        let railBackground = SettingsFlatView(SettingsLayout.sidebarBackground)
        let pane = SettingsFlatView(SettingsLayout.pageBackground)
        for v in [railBackground, pane] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }

        rail.orientation = .vertical
        rail.alignment = .leading
        rail.spacing = 4
        rail.translatesAutoresizingMaskIntoConstraints = false
        railBackground.addSubview(rail)

        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(content)

        let buttons = NSStackView(views: [back, openNotes, primary])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(buttons)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height),
            railBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            railBackground.topAnchor.constraint(equalTo: topAnchor),
            railBackground.bottomAnchor.constraint(equalTo: bottomAnchor),
            railBackground.widthAnchor.constraint(equalToConstant: Self.railWidth),
            pane.leadingAnchor.constraint(equalTo: railBackground.trailingAnchor),
            pane.trailingAnchor.constraint(equalTo: trailingAnchor),
            pane.topAnchor.constraint(equalTo: topAnchor),
            pane.bottomAnchor.constraint(equalTo: bottomAnchor),
            rail.leadingAnchor.constraint(equalTo: railBackground.leadingAnchor, constant: 12),
            rail.trailingAnchor.constraint(equalTo: railBackground.trailingAnchor, constant: -12),
            rail.topAnchor.constraint(equalTo: railBackground.topAnchor, constant: 28),
            content.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 36),
            content.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -36),
            content.topAnchor.constraint(equalTo: pane.topAnchor, constant: 32),
            buttons.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -28),
            buttons.bottomAnchor.constraint(equalTo: pane.bottomAnchor, constant: -22),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    private static var contentWidth: CGFloat { paneWidth - 72 }

    public func apply(_ state: OnboardingState) {
        let step = state.flow.step
        var status = OnboardingStatus.of(step, state.checks)
        if step == .server, state.localModelsAvailable { status?.fixTitle = "Set Up Models…" }
        primary.title = state.flow.primaryTitle(state.checks)
        back.isHidden = state.flow.isFirst
        openNotes.isHidden = !state.flow.isLast
        rebuildRail(OnboardingRail.marks(state.flow, state.checks))

        for view in content.arrangedSubviews { content.removeArrangedSubview(view); view.removeFromSuperview() }
        if step == .welcome {
            welcome(state)
        } else {
            let (symbol, body) = Self.copy(step, hotkey: state.hotkey, mode: state.activationMode)
            content.addArrangedSubview(header(symbol: symbol))
            content.setCustomSpacing(14, after: content.arrangedSubviews[0])
            content.addArrangedSubview(titleLabel(step.title))
            content.addArrangedSubview(bodyLabel(body))
            content.setCustomSpacing(18, after: content.arrangedSubviews.last!)
            if let status {
                content.addArrangedSubview(statusBox(status))
            } else if step == .tryIt {
                for view in tryItViews(state) { content.addArrangedSubview(view) }
            }
        }
        shownStep = step
    }

    // MARK: pieces

    private static func copy(_ step: OnboardingStep, hotkey: KeyCombo, mode: ActivationMode) -> (symbol: String, body: String) {
        switch step {
        case .welcome:
            ("", "")
        case .microphone:
            ("mic.fill", "Chirp listens only while you dictate or take Live Notes. Audio goes to your own server and is never stored unless you choose to keep it with a note.")
        case .accessibility:
            ("text.cursor", "Lets Chirp type into the app you’re using. Without it Chirp copies the text and you press ⌘V.")
        case .server:
            ("server.rack", "Chirp sends audio to chirp-server, which runs on this Mac unless you point Chirp elsewhere in Settings.")
        case .tryIt:
            switch mode {
            case .autoStop where hotkey.isSingleModifierKey:
                ("waveform", "Click the box, hold \(hotkey.title) and say something, then let go. Or tap it once and Chirp stops when you pause.")
            case .autoStop: ("waveform", "Click the box, press \(hotkey.title) and say something. Chirp stops when you pause.")
            case .holdToTalk: ("waveform", "Click the box, hold \(hotkey.title) and say something, then let go.")
            }
        }
    }

    private func titleLabel(_ text: String) -> NSTextField {
        let title = NSTextField(labelWithString: text)
        title.font = .systemFont(ofSize: 24, weight: .semibold)
        return title
    }

    private func bodyLabel(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = Self.contentWidth
        return label
    }

    /// Welcome: the pond art, the two things Chirp does, and the keys.
    private func welcome(_ state: OnboardingState) {
        // v2 swaps the pond art for the Wake hero (a glass ribbon and Chirp's orb); Pond keeps the artwork.
        let art: NSView = ChirpDesign.current == .v2
            ? WelcomeHeroView(width: Self.contentWidth, height: WelcomeHero.height)
            : PondArt(pond, width: Self.contentWidth, height: 150)
        content.addArrangedSubview(art)
        content.setCustomSpacing(16, after: art)
        content.addArrangedSubview(titleLabel("Welcome to Chirp"))
        let features = NSStackView(views: [
            feature("mic.fill", "Dictate into any app",
                    (state.hotkey.isSingleModifierKey
                        ? "Hold \(state.hotkey.title) anywhere and talk, then let go, and your words appear where you’re typing. "
                        : "Press \(state.hotkey.title) anywhere, talk, and your words appear where you’re typing. ") + HistoryText.onboarding),
            feature("note.text", "Keep conversations in Notes",
                    "Press \(state.notesHotkey.title) to start a note. Chirp writes it as you talk and keeps every note on this Mac."),
        ])
        features.orientation = .vertical
        features.alignment = .leading
        features.spacing = 12
        content.setCustomSpacing(14, after: content.arrangedSubviews.last!)
        content.addArrangedSubview(features)
        content.setCustomSpacing(14, after: features)
        content.addArrangedSubview(bodyLabel("Setup takes a minute: the microphone, Accessibility and a Chirp server."))
    }

    private func feature(_ symbol: String, _ title: String, _ detail: String) -> NSView {
        let tile = ColorView(SettingsLayout.tonal, cornerRadius: 8)
        tile.translatesAutoresizingMaskIntoConstraints = false
        let glyph = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .medium).applying(.init(paletteColors: [SettingsLayout.onTonal]))) ?? NSImage())
        glyph.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(glyph)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 32), tile.heightAnchor.constraint(equalToConstant: 32),
            glyph.centerXAnchor.constraint(equalTo: tile.centerXAnchor), glyph.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        let text = NSTextField(wrappingLabelWithString: detail)
        text.font = MenuStyle.secondaryFont
        text.textColor = .secondaryLabelColor
        text.preferredMaxLayoutWidth = Self.contentWidth - 46
        let column = NSStackView(views: [name, text])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 1
        let row = NSStackView(views: [tile, column])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        return row
    }

    private func header(symbol: String) -> NSView {
        let size: CGFloat = 56
        let disc = ColorView(SettingsLayout.tonal, cornerRadius: 16)
        let glyph = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 24, weight: .regular).applying(.init(paletteColors: [.chirpKoi]))) ?? NSImage())
        glyph.translatesAutoresizingMaskIntoConstraints = false
        disc.addSubview(glyph)
        disc.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: disc.centerXAnchor), glyph.centerYAnchor.constraint(equalTo: disc.centerYAnchor),
            disc.widthAnchor.constraint(equalToConstant: size), disc.heightAnchor.constraint(equalToConstant: size),
        ])
        return disc
    }

    private func statusBox(_ status: OnboardingStatus) -> NSView {
        let symbolName = switch status.tone {
        case .ok: "checkmark.circle.fill"
        case .error: "xmark.octagon.fill"
        default: "exclamationmark.triangle.fill"
        }
        let image = NSImageView(image: MenuStyle.symbol(symbolName, tone: status.tone) ?? NSImage())
        image.setAccessibilityElement(false)
        let label = NSTextField(labelWithString: status.text)
        label.font = MenuStyle.font
        label.lineBreakMode = .byTruncatingTail
        fix.isHidden = status.fixTitle == nil
        fix.title = status.fixTitle ?? ""
        let row = NSStackView(views: [image, label, NSView(), fix])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 12)
        row.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        return card(around: row)
    }

    private func tryItViews(_ state: OnboardingState) -> [NSView] {
        tryField.translatesAutoresizingMaskIntoConstraints = false
        tryField.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        let heard = state.flow.heardHotkey
        let image = NSImageView(image: MenuStyle.symbol(heard ? "checkmark.circle.fill" : "ellipsis.circle", tone: heard ? .ok : .normal) ?? NSImage())
        image.setAccessibilityElement(false)
        let label = NSTextField(labelWithString: heard ? "It works — Chirp heard \(state.hotkey.title)" : "Waiting for \(state.hotkey.title)…")
        label.font = MenuStyle.semiboldFont
        label.setAccessibilityIdentifier("try-it-status")
        let row = NSStackView(views: [image, label])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY
        let keys = NSStackView(views: [
            shortcutKeys(state.hotkey.title, caption: "Dictate into any app"),
            shortcutKeys(state.notesHotkey.title, caption: "Start a note"),
        ])
        keys.orientation = .horizontal
        keys.alignment = .top
        keys.spacing = 28
        return [tryField, row, keys]
    }

    /// A shortcut as keycaps (one per modifier, one for the key) with what it does underneath.
    private func shortcutKeys(_ title: String, caption: String) -> NSView {
        let caps = NSStackView(views: Self.keySymbols(title).map { Keycap($0) })
        caps.orientation = .horizontal
        caps.spacing = 4
        let small = NSTextField(labelWithString: caption)
        small.font = MenuStyle.secondaryFont
        small.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [caps, small])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.setAccessibilityLabel("\(caption): \(title)")
        return stack
    }

    /// "⌃⌥Space" → ["⌃", "⌥", "Space"]: each modifier glyph on its own, then the rest.
    static func keySymbols(_ title: String) -> [String] {
        if ModifierKeys.isNamedTitle(title) { return [title] }   // "Right ⌥ Option" is one key
        let modifiers = Set("⌃⌥⇧⌘")
        let mods = title.prefix { modifiers.contains($0) }.map(String.init)
        let key = String(title.dropFirst(mods.count))
        return mods + (key.isEmpty ? [] : [key])
    }

    /// A rounded, filled container like a grouped-list row.
    private func card(around inner: NSStackView) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = ChirpRadius.row
        box.borderWidth = 1
        box.borderColor = .separatorColor
        box.fillColor = SettingsLayout.card
        box.contentViewMargins = .zero
        let container = NSView()
        inner.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: container.topAnchor), inner.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            inner.leadingAnchor.constraint(equalTo: container.leadingAnchor), inner.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        box.contentView = container
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    /// The rail: the brand glyph and name, then one row per step with its live mark.
    private func rebuildRail(_ marks: [OnboardingRail.Mark]) {
        for view in rail.arrangedSubviews { rail.removeArrangedSubview(view); view.removeFromSuperview() }
        let brand = NSStackView(views: [brandGlyph(), {
            let name = NSTextField(labelWithString: "Chirp")
            name.font = .systemFont(ofSize: 15, weight: .semibold)
            return name
        }()])
        brand.orientation = .horizontal
        brand.alignment = .centerY
        brand.spacing = 8
        brand.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 0)
        rail.addArrangedSubview(brand)
        rail.setCustomSpacing(22, after: brand)
        for (index, step) in OnboardingStep.allCases.enumerated() {
            let row = RailRow(step: step, number: index + 1, mark: marks[index])
            rail.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rail.widthAnchor).isActive = true
        }
        rail.setAccessibilityLabel("Step \((marks.firstIndex(of: .current) ?? 0) + 1) of \(marks.count)")
    }

    private func brandGlyph() -> NSView {
        let image = NSImageView(image: icon ?? NSImage())
        image.imageScaling = .scaleProportionallyUpOrDown
        image.contentTintColor = .chirpKoi
        image.setAccessibilityLabel("Chirp")
        image.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([image.widthAnchor.constraint(equalToConstant: 26), image.heightAnchor.constraint(equalToConstant: 26)])
        return image
    }
}

/// The pond art as the welcome hero: the app icon's artwork cropped to a wide banner with rounded corners.
@MainActor
final class PondArt: NSView {
    init(_ image: NSImage?, width: CGFloat, height: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        wantsLayer = true
        layer?.cornerRadius = ChirpRadius.panel
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.contents = image
        layer?.contentsGravity = .resizeAspectFill
        // The bird, the moon and the ripples: the middle band of the square artwork.
        layer?.contentsRect = CGRect(x: 0, y: 0.27, width: 1, height: 0.62)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: height).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("A koi-patterned bird singing on a lily pad under the moon")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }
}

/// The v2 welcome hero in the setup window: the SwiftUI `WelcomeHero`, sized like the pond art it replaces. It reads
/// Reduce Motion when it is created and again whenever the setting changes, and shows one still frame while it is on.
@MainActor
final class WelcomeHeroView: NSView {
    private let host: NSHostingView<WelcomeHero>
    private var observer: NSObjectProtocol?

    init(width: CGFloat, height: CGFloat) {
        host = NSHostingView(rootView: WelcomeHero(time: WelcomeHero.pinnedTime,
                                                   reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width), heightAnchor.constraint(equalToConstant: height),
            host.leadingAnchor.constraint(equalTo: leadingAnchor), host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor), host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.host.rootView = WelcomeHero(time: WelcomeHero.pinnedTime,
                                                  reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            }
        }
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    isolated deinit {
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }
}

/// One shortcut key drawn as a keycap.
@MainActor
final class Keycap: NSView {
    private let label: NSTextField

    init(_ text: String) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = ChirpRadius.control
        layer?.borderWidth = 1
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 30),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 30),
            widthAnchor.constraint(equalTo: label.widthAnchor, constant: 16),
        ])
        setAccessibilityElement(false)
        restyle()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

    private func restyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = SettingsLayout.card.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

/// One row of the step rail: a mark (number, ✓, ⚠ or the current step's koi disc) and the step's title.
@MainActor
final class RailRow: NSView {
    private let mark: OnboardingRail.Mark
    private let markView = NSView()
    private let inner = NSImageView()
    private let numeral: NSTextField
    private let title: NSTextField

    init(step: OnboardingStep, number: Int, mark: OnboardingRail.Mark) {
        self.mark = mark
        numeral = NSTextField(labelWithString: "\(number)")
        title = NSTextField(labelWithString: step.title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false

        markView.wantsLayer = true
        markView.layer?.cornerRadius = 11
        markView.translatesAutoresizingMaskIntoConstraints = false
        inner.translatesAutoresizingMaskIntoConstraints = false
        numeral.font = .systemFont(ofSize: 11, weight: .semibold)
        numeral.translatesAutoresizingMaskIntoConstraints = false
        markView.addSubview(inner)
        markView.addSubview(numeral)
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 13, weight: mark == .current ? .semibold : .regular)
        addSubview(markView)
        addSubview(title)
        NSLayoutConstraint.activate([
            inner.centerXAnchor.constraint(equalTo: markView.centerXAnchor), inner.centerYAnchor.constraint(equalTo: markView.centerYAnchor),
            numeral.centerXAnchor.constraint(equalTo: markView.centerXAnchor), numeral.centerYAnchor.constraint(equalTo: markView.centerYAnchor),
            heightAnchor.constraint(equalToConstant: 36),
            markView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            markView.centerYAnchor.constraint(equalTo: centerYAnchor),
            markView.widthAnchor.constraint(equalToConstant: 22), markView.heightAnchor.constraint(equalToConstant: 22),
            title.leadingAnchor.constraint(equalTo: markView.trailingAnchor, constant: 10),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(OnboardingRail.label(step, mark))
        restyle()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); restyle() }

    /// Colours are dynamic, so they are resolved in this row's own appearance whenever it changes.
    private func restyle() {
        func glyph(_ name: String, _ color: NSColor) -> NSImage? {
            NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .bold).applying(.init(paletteColors: [color])))
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            inner.isHidden = true
            numeral.isHidden = false
            markView.layer?.borderWidth = 0
            layer?.backgroundColor = NSColor.clear.cgColor
            title.textColor = mark == .upcoming ? .secondaryLabelColor : .labelColor
            switch mark {
            case .current:
                markView.layer?.backgroundColor = SettingsLayout.selectionTile.cgColor
                numeral.textColor = SettingsLayout.onSelectionTile
                layer?.backgroundColor = SettingsLayout.selection.cgColor
                title.textColor = SettingsLayout.onSelection
            case .done:
                markView.layer?.backgroundColor = MenuStyle.lily.withAlphaComponent(0.18).cgColor
                inner.image = glyph("checkmark", MenuStyle.lily)
                inner.isHidden = false; numeral.isHidden = true
            case .warning:
                markView.layer?.backgroundColor = MenuStyle.moon.withAlphaComponent(0.2).cgColor
                inner.image = glyph("exclamationmark", MenuStyle.moon)
                inner.isHidden = false; numeral.isHidden = true
            case .upcoming:
                markView.layer?.backgroundColor = NSColor.clear.cgColor
                markView.layer?.borderWidth = 1
                markView.layer?.borderColor = NSColor.tertiaryLabelColor.cgColor
                numeral.textColor = .secondaryLabelColor
            }
        }
    }
}

/// A rounded, filled view whose dynamic colour is resolved in the view's own appearance (a plain layer would freeze it
/// at the appearance current when the layer was created).
@MainActor
final class ColorView: NSView {
    private let color: NSColor
    private let radius: CGFloat

    init(_ color: NSColor, cornerRadius: CGFloat) {
        self.color = color
        self.radius = cornerRadius
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = radius
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = color.cgColor }
    }
}
