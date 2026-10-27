import AppKit
import ChirpCore

/// Settings → History & privacy: the apps whose dictations are never kept, one row each with a remove button, and
/// "+" (the owner shows its app chooser) and Restore Defaults below.
@MainActor
public final class HistoryAppsList: NSObject {
    static let rowHeight: CGFloat = 24

    public let view: NSStackView
    private let scroll = NSScrollView()
    private let rowsStack = FlippedStack()
    private let empty = NSTextField(labelWithString: "No apps. Every dictation is kept.")
    public let addButton = NSButton(title: "", target: nil, action: nil)
    public let resetButton = NSButton(title: "Restore Defaults", target: nil, action: nil)
    public private(set) var apps: [String] = []
    /// Called with the whole list after every edit.
    public var onChange: (([String]) -> Void)?
    /// "+" was pressed; the owner shows its app chooser anchored on the button.
    public var onAdd: ((NSView) -> Void)?

    public override init() {
        let buttons = NSStackView(views: [addButton, resetButton])
        view = NSStackView(views: [scroll, buttons])
        super.init()
        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        rowsStack.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = rowsStack
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.setAccessibilityLabel("Apps whose dictations are never kept")
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: SettingsForm.fieldWidth),
            scroll.heightAnchor.constraint(equalToConstant: 84),
            rowsStack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            rowsStack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            rowsStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        empty.font = MenuStyle.secondaryFont
        empty.textColor = .secondaryLabelColor
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add app")
        addButton.bezelStyle = .smallSquare
        addButton.imagePosition = .imageOnly
        addButton.setAccessibilityLabel("Add an app whose dictations are never kept")
        addButton.widthAnchor.constraint(equalToConstant: 26).isActive = true
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        resetButton.setAccessibilityLabel("Restore the default excluded apps")
        addButton.target = self; addButton.action = #selector(addPressed)
        resetButton.target = self; resetButton.action = #selector(reset)
        buttons.orientation = .horizontal
        buttons.spacing = 8
        view.orientation = .vertical
        view.alignment = .leading
        view.spacing = 6
        rebuild()
    }

    public func setApps(_ apps: [String]) {
        guard apps != self.apps else { return }
        self.apps = apps
        rebuild()
    }

    /// Adds `bundleID` unless it is already listed.
    public func add(bundleID: String) {
        guard !apps.contains(bundleID) else { return }
        apps.append(bundleID)
        rebuild()
        onChange?(apps)
    }

    @objc private func addPressed() { onAdd?(addButton) }

    @objc private func reset() {
        apps = HistoryPolicy.defaultExcludedApps
        rebuild()
        onChange?(apps)
    }

    @objc private func removeRow(_ sender: NSButton) {
        guard apps.indices.contains(sender.tag) else { return }
        apps.remove(at: sender.tag)
        rebuild()
        onChange?(apps)
    }

    private func rebuild() {
        for v in rowsStack.arrangedSubviews { rowsStack.removeArrangedSubview(v); v.removeFromSuperview() }
        if apps.isEmpty {
            rowsStack.addArrangedSubview(empty)
            return
        }
        for (i, id) in apps.enumerated() { rowsStack.addArrangedSubview(row(id, index: i)) }
    }

    private func row(_ bundleID: String, index: Int) -> NSView {
        let name = AppNames.name(for: bundleID)
        let label = NSTextField(labelWithString: name)
        label.font = MenuStyle.font
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = bundleID
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.setAccessibilityLabel(name)
        let remove = NSButton(image: NSImage(systemSymbolName: "minus.circle.fill", accessibilityDescription: "Remove \(name)")
                                ?? NSImage(), target: self, action: #selector(removeRow(_:)))
        remove.isBordered = false
        remove.contentTintColor = .tertiaryLabelColor
        remove.tag = index
        remove.setAccessibilityLabel("Keep dictations in \(name) again")
        remove.widthAnchor.constraint(equalToConstant: 20).isActive = true
        let stack = NSStackView(views: [label, NSView(), remove])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
        stack.widthAnchor.constraint(equalToConstant: SettingsForm.fieldWidth - 12 - 15).isActive = true
        return stack
    }
}

/// The History section's words.
public enum HistorySettingsText {
    public static let keep = "Keep dictation history"
    public static let keepHelp = "Every dictation you insert is kept on this Mac, encrypted, never synced. Password fields and the apps below are never kept."
    public static let retentionHelp = "Older dictations are deleted when Chirp opens and every few hours."
    public static let appsHelp = "Dictations into these apps are never kept. Password managers are listed to begin with."
    public static func count(_ n: Int) -> String { n == 0 ? "None kept" : n == 1 ? "1 dictation" : "\(n) dictations" }
    public static let turnOffTitle = "Turn off dictation history?"
    public static func turnOffDetail(_ n: Int) -> String {
        n == 0 ? "Chirp will stop keeping your dictations." :
            "Chirp will stop keeping new dictations. Delete the \(count(n).lowercased()) already kept on this Mac too?"
    }
    public static let clearTitle = "Delete dictation history?"
    public static func clearDetail(_ n: Int) -> String {
        "\(count(n)) will be deleted from this Mac, with the key that encrypts them. This can’t be undone."
    }
}
