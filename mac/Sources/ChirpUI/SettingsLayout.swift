import AppKit

/// The building blocks of a Settings page in the grouped-form style of System Settings: a page title, then sections
/// (a small heading above a rounded card), each card holding rows separated by hairlines. A row is a title with its
/// control at the right and a help line under both, or (for wide controls) the title, the control and the help stacked.
/// Plain AppKit, because the Command Line Tools toolchain has no SwiftUI macro plugins; the colours are the design tokens.
@MainActor
enum SettingsLayout {
    /// The page's content width: the 520 pt detail column less a 20 pt gutter on each side.
    static let pageWidth: CGFloat = 480
    static let cardInset: CGFloat = 14
    /// Room for a control that fills a row: the page width less the card's insets.
    static let rowWidth: CGFloat = pageWidth - 2 * cardInset

    static let card = ChirpColor.dynamic(.surface)
    static let pageBackground = ChirpColor.dynamic(.background)
    static let sidebarBackground = ChirpColor.dynamic(.surfaceRaised)
    static let ink = ChirpColor.dynamic(.ink)
    static let inkMuted = ChirpColor.dynamic(.inkMuted)
    static let koiContainer = ChirpColor.dynamic(.koiContainer)
    static let onKoiContainer = ChirpColor.dynamic(.onKoiContainer)
    /// A small tonal tile (onboarding's feature icons): the pale accent container in light, and in dark an accent fill at
    /// 28% over the surface (Pond's solid dark container reads as a brown block there). Follows the current design.
    static let tonal = NSColor(name: "ChirpTonal") { appearance in
        let (r, g, b, a) = tonalRGBA(dark: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua, in: ChirpDesign.current)
        return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
    }
    nonisolated static func tonalRGBA(dark: Bool, in design: ChirpDesign) -> (Double, Double, Double, Double) {
        let c = dark ? ChirpColor.Token.koi.pair(in: design).dark : ChirpColor.Token.koiContainer.pair(in: design).light
        return (c.r, c.g, c.b, dark ? 0.28 : 1)
    }
    static let onTonal = ChirpColor.dynamic(.onKoiContainer)
    /// Selected sidebar rows and active onboarding steps use the koi container in both themes.
    static let selection = koiContainer
    static let onSelection = onKoiContainer
    /// The icon tile or step number inside the selected row: a koi tile in light, a pond-ink tile in dark.
    static let selectionTile = ChirpColor.dynamic(light: .koi, dark: .onKoi)
    static let onSelectionTile = ChirpColor.dynamic(light: .onKoi, dark: .koi)
    static let onKoi = ChirpColor.dynamic(.onKoi)
}

/// A page title ("General") above the sections.
@MainActor
final class SettingsPageTitle: NSTextField {
    init(_ text: String) {
        super.init(frame: .zero)
        stringValue = text
        isEditable = false; isBordered = false; drawsBackground = false
        font = .systemFont(ofSize: 22, weight: .semibold)
        textColor = .labelColor
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }
}

/// One row in a card. `header` holds the title and the control side by side; the help line sits under it, full width.
@MainActor
final class SettingsRow: NSView {
    private let stack = NSStackView()
    private let divider = NSView()
    let title: String?

    /// - Parameters:
    ///   - title: the row's label; nil when the control carries its own (a checkbox).
    ///   - control: at the trailing edge beside the title, or under it when `stacked`.
    init(title: String?, control: NSView?, help: NSTextField? = nil, stacked: Bool = false) {
        self.title = title
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 10, left: SettingsLayout.cardInset, bottom: 10, right: SettingsLayout.cardInset)
        addSubview(stack)

        var label: NSTextField?
        if let title {
            let l = NSTextField(labelWithString: title)
            l.font = MenuStyle.font
            l.textColor = .labelColor
            l.lineBreakMode = .byTruncatingTail
            l.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            label = l
        }
        if stacked {
            if let label { stack.addArrangedSubview(label) }
            if let control { stack.addArrangedSubview(control) }
        } else {
            let header = NSStackView()
            header.orientation = .horizontal
            header.alignment = .centerY
            header.spacing = 12
            if let label {
                header.addArrangedSubview(label)
                let spacer = NSView()
                spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
                header.addArrangedSubview(spacer)
            }
            if let control {
                control.setContentHuggingPriority(.required, for: .horizontal)
                header.addArrangedSubview(control)
            }
            stack.addArrangedSubview(header)
            header.widthAnchor.constraint(equalToConstant: SettingsLayout.rowWidth).isActive = true
        }
        if let help {
            help.preferredMaxLayoutWidth = SettingsLayout.rowWidth
            help.font = MenuStyle.secondaryFont
            stack.addArrangedSubview(help)
            help.widthAnchor.constraint(lessThanOrEqualToConstant: SettingsLayout.rowWidth).isActive = true
        }

        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.isHidden = true
        addSubview(divider)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SettingsLayout.cardInset),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
        ])
        if let title { setAccessibilityLabel(title) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    /// Rows after the first draw a hairline above themselves.
    var showsDivider: Bool {
        get { !divider.isHidden }
        set { divider.isHidden = !newValue }
    }

    override func updateLayer() {
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
    }

    override func layout() {
        super.layout()
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
}

/// A rounded card of rows.
@MainActor
final class SettingsCard: NSView {
    private let stack = NSStackView()
    private(set) var rows: [SettingsRow] = []

    init(rows: [SettingsRow]) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = ChirpRadius.row
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(equalToConstant: SettingsLayout.pageWidth),
        ])
        self.rows = rows
        for (i, row) in rows.enumerated() {
            row.showsDivider = i > 0
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        restyle()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    private func restyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = SettingsLayout.card.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }
}

/// A section: its heading in secondary grey above the card, with an optional footnote under it.
@MainActor
struct SettingsSection {
    var title: String?
    var rows: [SettingsRow]
    var footnote: NSTextField?

    init(_ title: String? = nil, _ rows: [SettingsRow], footnote: NSTextField? = nil) {
        self.title = title; self.rows = rows; self.footnote = footnote
    }

    func view() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let title {
            let heading = NSTextField(labelWithString: title)
            heading.font = .systemFont(ofSize: 12, weight: .semibold)
            heading.textColor = .secondaryLabelColor
            heading.setAccessibilityRole(.staticText)
            stack.addArrangedSubview(heading)
            stack.setCustomSpacing(6, after: heading)
        }
        let card = SettingsCard(rows: rows)
        stack.addArrangedSubview(card)
        if let footnote {
            footnote.preferredMaxLayoutWidth = SettingsLayout.pageWidth
            stack.addArrangedSubview(footnote)
        }
        return stack
    }
}

/// A settings row that opens a detail page: the title on the left, a chevron on the right, and one button over both.
@MainActor
final class SettingsDisclosure: NSView {
    let button = NSButton()

    init(_ title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: title)
        label.font = MenuStyle.font
        label.textColor = .labelColor
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let chevron = NSImageView()
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.contentTintColor = .tertiaryLabelColor
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        chevron.setAccessibilityElement(false)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label, spacer, chevron])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.title = ""
        button.setAccessibilityLabel(title)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        addSubview(button)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: SettingsLayout.rowWidth),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 22),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 10),
            chevron.heightAnchor.constraint(equalToConstant: 14),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }
}
