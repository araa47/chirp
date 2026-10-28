import AppKit
import ChirpCore

/// What Settings → Devices says about its list, in words (kept apart from the AppKit rows so tests can read it).
public enum DevicesText {
    public static func detail(_ d: PairedDevice, now: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let style = Date.FormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: .current, timeZone: timeZone)
        return "Paired \(d.created.formatted(style)) · \(lastSeen(d.lastSeen, now: now, locale: locale))"
    }

    public static func lastSeen(_ date: Date?, now: Date, locale: Locale = .current) -> String {
        guard let date else { return "not used yet" }
        // The server records a device at most once a minute.
        if now.timeIntervalSince(date) < 90 { return "seen just now" }
        let f = RelativeDateTimeFormatter()
        f.locale = locale
        f.unitsStyle = .abbreviated
        return "seen \(f.localizedString(for: date, relativeTo: now))"
    }

    public static let empty = "No phones paired yet."
    public static let loading = "Loading…"
    public static let sharedNote = "Phones paired with the shared code don’t show here and keep working until you reset it."
    public static let rotateHelp = "Replaces the shared code. Every phone paired with it must pair again; phones in the list are not affected."

    public static func revokeTitle(_ d: PairedDevice) -> String { "Revoke “\(d.name)”?" }
    public static let revokeDetail = "It stops working right away and has to be paired again to reconnect. Other phones are not affected."
}

/// Settings → Devices: the phones paired with their own token (name, when paired, last seen) and a Revoke button for
/// each. When the server reports activity it adds a line per row (in use now, or the last request), This Mac and Shared
/// token rows, the refused-request lines, an Activity… button and the "Keep device activity" switch. The owner supplies
/// the data through `apply` and handles `onRevoke` (which asks first), `onShowActivity` and `onKeepActivity`.
@MainActor
public final class DevicesView: NSStackView {
    public var onRevoke: ((PairedDevice) -> Void)?
    public var onShowActivity: (() -> Void)?
    /// "Keep device activity" was flipped to this value.
    public var onKeepActivity: ((Bool) -> Void)?
    /// The list grew or shrank: the window should resize.
    public var onResize: (() -> Void)?
    private var shown: [PairedDevice] = []

    public init() {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        widthAnchor.constraint(equalToConstant: SettingsForm.controlWidth).isActive = true
        apply(.loading, revoking: nil, problem: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    public var devices: [PairedDevice] { shown }

    public func apply(_ phase: DevicesPhase, revoking: String?, problem: String?, activity: ActivityPhase = .hidden, keepProblem: String? = nil,
                      now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) {
        for v in arrangedSubviews { removeArrangedSubview(v); v.removeFromSuperview() }
        shown = []
        switch phase {
        case .loading: addNote(DevicesText.loading)
        case .remote: addNote("Manage the devices paired with your Chirp server by running chirp-server devices there.")
        case .unavailable(let why): addNote(why, tone: .warning)
        case .loaded(let devices):
            shown = devices
            // Only a server that keeps activity has anything to add to the rows.
            let shownActivity = activity.activity.flatMap { $0.keep ? $0 : nil }
            func line(_ matches: (ActivitySource) -> Bool) -> ActivityLine? {
                guard let shownActivity,
                      let text = ActivityText.line(shownActivity, source: matches, now: now, locale: locale, timeZone: timeZone) else { return nil }
                return ActivityLine(text: text, inUse: shownActivity.active.contains { matches($0.source) })
            }
            if let shownActivity {
                let isLocal: (ActivitySource) -> Bool = { $0 == .local }
                let isShared: (ActivitySource) -> Bool = { $0 == .shared }
                if ActivityText.has(shownActivity, source: isLocal), let l = line(isLocal) {
                    addRow(name: ActivityText.thisMac, detail: nil, activity: l, revoke: nil, busy: false, enabled: true)
                }
                if ActivityText.has(shownActivity, source: isShared), let l = line(isShared) {
                    let clients = ActivityText.clients(shownActivity, source: isShared)
                    let via = clients.isEmpty ? nil : "via " + clients.joined(separator: ", ")
                    addRow(name: ActivityText.sharedToken, detail: via, activity: l, revoke: nil, busy: false, enabled: true)
                }
            }
            if devices.isEmpty { addNote(DevicesText.empty) }
            for d in devices {
                let mine: (ActivitySource) -> Bool = { if case .device(let id, _, _) = $0 { id == d.id } else { false } }
                addRow(name: d.name, detail: DevicesText.detail(d, now: now, locale: locale, timeZone: timeZone), activity: line(mine), revoke: d,
                       busy: revoking == d.id, enabled: revoking == nil)
            }
            if let shownActivity {
                for r in shownActivity.refused { addNote(ActivityText.refusal(r, now: now, locale: locale), tone: .warning) }
            }
        }
        if let problem { addNote(problem, tone: .error) }
        if case .loaded = phase { addActivityControls(activity, keepProblem: keepProblem) }
        onResize?()
    }

    /// The Activity… button and the "Keep device activity" switch, or the old-server note.
    private func addActivityControls(_ activity: ActivityPhase, keepProblem: String?) {
        switch activity {
        case .hidden: return
        case .outdated: addNote(ActivityText.outdated)
        case .shown(let shownActivity):
            let keep = ClosureButton(checkbox: ActivityText.keepTitle) { [weak self] on in self?.onKeepActivity?(on) }
            keep.state = shownActivity.keep ? .on : .off
            keep.setAccessibilityHelp(ActivityText.keepHelp)
            var views: [NSView] = [keep]
            if shownActivity.keep {
                let show = ClosureButton(title: ActivityText.showButton) { [weak self] _ in self?.onShowActivity?() }
                show.setAccessibilityLabel("Show device activity")
                views = [show, keep]
            }
            let row = NSStackView(views: views)
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 14
            addArrangedSubview(row)
            addNote(shownActivity.keep ? ActivityText.keepHelp : ActivityText.keepOff)
            if let keepProblem { addNote(keepProblem, tone: .error) }
        }
    }

    private func addNote(_ text: String, tone: MenuEntry.Tone = .normal) {
        let f = SettingsForm.help(text)
        if tone == .error { f.textColor = .systemRed }
        if tone == .warning { f.textColor = .systemOrange }
        addArrangedSubview(f)
    }

    /// The activity line under a row's detail; `inUse` draws the small green dot.
    struct ActivityLine { var text: String; var inUse: Bool }

    /// A row: bold name, a grey detail line, the activity line, and Revoke when it is a phone with its own token.
    private func addRow(name title: String, detail: String?, activity: ActivityLine?, revoke device: PairedDevice?, busy: Bool, enabled: Bool) {
        let name = NSTextField(labelWithString: title)
        name.font = MenuStyle.semiboldFont
        name.lineBreakMode = .byTruncatingTail
        name.toolTip = title
        var lines: [NSView] = [name]
        if let detail {
            let field = NSTextField(labelWithString: detail)
            field.font = MenuStyle.secondaryFont
            field.textColor = .secondaryLabelColor
            field.lineBreakMode = .byTruncatingTail
            lines.append(field)
        }
        if let activity {
            let field = NSTextField(labelWithString: activity.text)
            field.font = MenuStyle.secondaryFont
            field.textColor = .secondaryLabelColor
            field.lineBreakMode = .byTruncatingTail
            if activity.inUse {
                let text = NSMutableAttributedString(string: "● ", attributes: [.foregroundColor: NSColor.systemGreen, .font: MenuStyle.secondaryFont])
                text.append(NSAttributedString(string: activity.text, attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: MenuStyle.secondaryFont]))
                field.attributedStringValue = text
                field.setAccessibilityLabel(activity.text)
            }
            lines.append(field)
        }
        let text = NSStackView(views: lines)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [text, NSView()]
        if let device {
            let button = ClosureButton(title: busy ? "Revoking…" : "Revoke…") { [weak self] _ in self?.onRevoke?(device) }
            button.isEnabled = enabled
            button.setAccessibilityLabel("Revoke \(device.name)")
            views.append(button)
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
}

/// A small push button or checkbox that runs a closure; the checkbox passes its new state.
@MainActor
final class ClosureButton: NSButton {
    private let handler: (Bool) -> Void

    init(title: String, handler: @escaping (Bool) -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        controlSize = .small
        target = self
        action = #selector(pressed)
    }

    init(checkbox title: String, handler: @escaping (Bool) -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        setButtonType(.switch)
        controlSize = .small
        target = self
        action = #selector(pressed)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func pressed() { handler(state == .on) }
}
