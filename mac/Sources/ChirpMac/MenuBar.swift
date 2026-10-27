import AppKit
import ChirpCore
import ChirpUI

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let controller: DictationController
    private let actions: Actions
    private let badge = NSView()
    private let cleanedBadge = NSView()
    private let glyphs = Glyphs()
    private var pulseTimer: Timer?
    private var pulsePhase = 0

    /// The windows the menu opens.
    struct Actions {
        /// Opens Settings, on `tab` when given (else wherever it was).
        var openSettings: (SettingsTab?) -> Void
        var openSetup: () -> Void
        var toggleNotes: () -> Void = {}
        var showNotes: () -> Void = {}
        /// New Note: a fresh note, recording, in the Notes window.
        var newNote: () -> Void = {}
        /// Recent Notes: opens the note with this id in the Notes window.
        var openNote: (String) -> Void = { _ in }
        /// The library's newest notes (most recently modified first).
        var recentNotes: () -> [RecentNote] = { [] }
        /// Live Notes' state for the menu and the icon.
        var notes: () -> NotesMenuState = { NotesMenuState() }
        /// The menu's switch, for Live Notes (pausing stops it and releases its shortcut).
        var setRunning: (Bool) -> Void = { _ in }
        /// A server older than the app, what the last fix said, and the fix.
        var serverNotice: () -> (notice: ServerNotice?, message: String?) = { (nil, nil) }
        var fixServer: () -> Void = {}
        /// Dictation history: the window (on a dictation when given), whether it is on, the newest dictations, and
        /// one dictation's Insert Again and Copy (by id).
        var showHistory: (String?) -> Void = { _ in }
        var historyEnabled: () -> Bool = { false }
        var recentDictations: () -> [RecentDictation] = { [] }
        var insertDictation: (String) -> Void = { _ in }
        var copyDictation: (String) -> Void = { _ in }
    }

    /// What the menu and the icon need from Live Notes.
    struct NotesMenuState {
        var recording = false
        var finishing = false
        var paused = false
        var elapsed: String?
        /// The title of the note being recorded.
        var title: String?
        var hasDocument = false
        var hotkeyRegistered = true
        var openShortcut: String?
        var debugRetention = false
    }

    init(controller: DictationController, actions: Actions) {
        self.controller = controller
        self.actions = actions
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        installBadge()
        installCleanedBadge()
        refreshIcon()
    }

    // MARK: status icon

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func refreshIcon() {
        let notes = actions.notes()
        let icon = StatusIcon.of(state: controller.state, serverReachable: controller.health != nil,
                                 debugRetention: controller.debugRetention || notes.debugRetention, reduceMotion: reduceMotion,
                                 rawOfferOpen: controller.rawOffer.isOpen, paused: controller.isPaused,
                                 notesRecording: notes.recording)
        guard let button = item.button else { return }
        switch icon.glyph {
        case .idle: button.image = glyphs.idle ?? Self.symbol(controller.health == nil ? "mic.slash" : "mic")
        case .listening: button.image = glyphs.listening(waveAlpha: StatusIcon.waveAlpha(phase: pulsePhase, reduceMotion: reduceMotion))
            ?? Self.symbol("waveform")
        case .error: button.image = Self.symbol("exclamationmark.triangle")
        }
        button.title = controller.privateSession.isActive ? " 🔒" : ""
        button.alphaValue = icon.dimmed ? 0.45 : 1
        let label = icon.accessibilityLabel + (controller.privateSession.isActive ? ", Private session" : "")
        button.setAccessibilityLabel(label)
        button.toolTip = label
        badge.isHidden = !icon.debugBadge
        cleanedBadge.isHidden = !icon.cleanedBadge
        setPulsing(icon.animatesWaves)
    }

    private func setPulsing(_ on: Bool) {
        guard on != (pulseTimer != nil) else { return }
        pulseTimer?.invalidate()
        pulseTimer = nil
        pulsePhase = 0
        guard on else { return }
        pulseTimer = Timer.scheduledTimer(withTimeInterval: StatusIcon.pulseInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pulsePhase += 1
                self.refreshIcon()
            }
        }
    }

    /// A small red dot at the icon's top right while the server keeps recordings, so retention is never invisible.
    private func installBadge() {
        guard let button = item.button else { return }
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor.systemRed.cgColor
        badge.layer?.cornerRadius = 3.5
        badge.layer?.borderWidth = 1
        badge.layer?.borderColor = NSColor.black.withAlphaComponent(0.35).cgColor
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.widthAnchor.constraint(equalToConstant: 7), badge.heightAnchor.constraint(equalToConstant: 7),
            badge.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -3),
            badge.topAnchor.constraint(equalTo: button.topAnchor, constant: 3),
        ])
    }

    /// A tiny dot at the icon's bottom right while "Use raw" is on offer.
    private func installCleanedBadge() {
        guard let button = item.button else { return }
        cleanedBadge.wantsLayer = true
        cleanedBadge.layer?.backgroundColor = NSColor.systemGreen.cgColor
        cleanedBadge.layer?.cornerRadius = 3
        cleanedBadge.layer?.borderWidth = 1
        cleanedBadge.layer?.borderColor = NSColor.black.withAlphaComponent(0.35).cgColor
        cleanedBadge.isHidden = true
        cleanedBadge.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(cleanedBadge)
        NSLayoutConstraint.activate([
            cleanedBadge.widthAnchor.constraint(equalToConstant: 6), cleanedBadge.heightAnchor.constraint(equalToConstant: 6),
            cleanedBadge.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -3),
            cleanedBadge.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -3),
        ])
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: "Chirp")
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        Task { await controller.refreshHealth() }
        build(menu)
    }

    private func build(_ menu: NSMenu) {
        var inputs = MenuInputs()
        inputs.privateSession = controller.privateSession.isActive
        inputs.state = controller.state
        inputs.health = controller.health
        inputs.healthError = controller.healthError
        (inputs.serverNotice, inputs.serverFixMessage) = actions.serverNotice()
        inputs.debugRetention = controller.debugRetention
        inputs.paused = controller.isPaused
        inputs.hotkeyRegistered = controller.gate.hotkeyRegistered
        inputs.inputs = InputDevice.all().map(\.input)
        inputs.defaultInput = InputDevice.systemDefault()?.input
        inputs.chosenInputUID = settings.inputDeviceUID
        inputs.cleanupOn = settings.permitsCorrection(health: controller.health)
        inputs.showChanges = settings.showChangesAfterCleanup
        inputs.styleID = settings.correctionProfile
        inputs.rawOfferOpen = controller.rawOffer.isOpen
        inputs.rawOfferKey = controller.rawOffer.hotkeyActive ? settings.useRawHotkey.title : nil
        inputs.hotkey = settings.hotkey
        inputs.activationMode = settings.activationMode
        inputs.micGranted = Permissions.microphoneGranted
        inputs.accessibilityGranted = Permissions.accessibilityGranted
        let notes = actions.notes()
        inputs.notesRecording = notes.recording
        inputs.notesFinishing = notes.finishing
        inputs.notesPaused = notes.paused
        inputs.notesElapsed = notes.elapsed
        inputs.notesTitle = notes.title
        inputs.recentNotes = actions.recentNotes()
        inputs.historyEnabled = actions.historyEnabled()
        inputs.recentDictations = actions.recentDictations()
        inputs.now = Date()
        inputs.notesHasDocument = notes.hasDocument
        inputs.notesHotkeyRegistered = notes.hotkeyRegistered
        inputs.notesShortcut = settings.notesHotkey.title
        inputs.openNotesShortcut = notes.openShortcut
        inputs.debugRetention = controller.debugRetention || notes.debugRetention
        menu.removeAllItems()
        menu.addItem(headerItem(MenuContent.header(inputs), menu: menu))
        for entry in MenuContent.entries(inputs) { menu.addItem(topLevelItem(for: entry)) }
    }

    /// The name, the status and the switch: a custom view, since a plain item cannot hold a control.
    private func headerItem(_ header: MenuHeader, menu: NSMenu) -> NSMenuItem {
        let view = MenuHeaderView(header: header)
        view.onToggle = { [weak self, weak menu] running in
            guard let self else { return }
            self.controller.setRunning(running)
            self.actions.setRunning(running)
            self.refreshIcon()
            // Let the switch finish its slide, then close the menu on the new state.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { menu?.cancelTracking() }
        }
        let i = NSMenuItem()
        i.view = view
        return i
    }

    /// Top-level rows are drawn by `MenuRowView` (grey value or shortcut at the right, chevron for submenus); the
    /// submenus beneath them are plain native items.
    private func topLevelItem(for entry: MenuEntry) -> NSMenuItem {
        if entry.isSeparator { return .separator() }
        let i = item(for: entry)
        i.view = MenuRowView(entry: entry)
        return i
    }

    private func item(for entry: MenuEntry) -> NSMenuItem {
        if entry.isSeparator { return .separator() }
        let i = NSMenuItem(title: entry.title, action: selector(for: entry.action), keyEquivalent: entry.keyEquivalent ?? "")
        if entry.keyEquivalent != nil { i.keyEquivalentModifierMask = entry.keyEquivalentOption ? [.command, .option] : .command }
        if entry.action != nil { i.target = self }
        i.isEnabled = entry.isEnabled
        i.state = switch entry.mark { case .off: .off; case .on: .on; case .mixed: .mixed }
        i.representedObject = entry.action?.payload
        if entry.tone == .warning || entry.tone == .error, entry.isEnabled {
            i.attributedTitle = NSAttributedString(string: entry.title, attributes: [
                .foregroundColor: MenuStyle.textColor(entry.tone), .font: NSFont.menuFont(ofSize: 0)])
        }
        if let sub = entry.submenu {
            let m = NSMenu()
            for e in sub { m.addItem(item(for: e)) }
            i.submenu = m
        }
        if let detail = entry.value, entry.action != nil || entry.submenu != nil {
            // A submenu row with a value (Recent Notes: the note's age): the title, then the value in secondary grey.
            let style = NSMutableParagraphStyle()
            style.tabStops = [NSTextTab(textAlignment: .right, location: Self.submenuValueColumn)]
            let text = NSMutableAttributedString(string: entry.title, attributes: [.font: NSFont.menuFont(ofSize: 0), .paragraphStyle: style])
            text.append(NSAttributedString(string: "\t" + detail, attributes: [
                .font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]))
            i.attributedTitle = text
        }
        return i
    }

    /// Where a submenu row's value ends, measured from the row's text start.
    private static let submenuValueColumn: CGFloat = 250

    private func selector(for action: MenuAction?) -> Selector? {
        switch action {
        case nil: nil
        case .togglePrivateSession: #selector(togglePrivateSession)
        case .toggleDictation: #selector(toggleDictation)
        case .toggleNotes: #selector(toggleNotes)
        case .newNote: #selector(newNote)
        case .showNotes: #selector(showNotes)
        case .openNote: #selector(openNote(_:))
        case .useRaw: #selector(useRaw)
        case .pickInput: #selector(pickInput(_:))
        case .toggleCleanup: #selector(toggleCleanup)
        case .pickStyle: #selector(pickStyle(_:))
        case .fixServer: #selector(fixServer)
        case .showSettings: #selector(showSettings)
        case .editStyles: #selector(editStyles)
        case .showSetup: #selector(showSetup)
        case .quit: #selector(quit)
        case .showHistory: #selector(showHistory)
        case .insertDictation: #selector(insertDictation(_:))
        case .copyDictation: #selector(copyDictation(_:))
        case .openDictation: #selector(openDictation(_:))
        }
    }

    @objc private func togglePrivateSession() { controller.privateSession.setEnabled(!controller.privateSession.isActive) }
    @objc private func toggleDictation() { controller.toggleDictation() }
    @objc private func toggleNotes() { actions.toggleNotes() }
    @objc private func newNote() { actions.newNote() }
    @objc private func showNotes() { actions.showNotes() }
    @objc private func openNote(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { actions.openNote(id) }
    }
    @objc private func useRaw() { controller.rawOffer.take() }
    @objc private func pickInput(_ sender: NSMenuItem) { settings.inputDeviceUID = sender.representedObject as? String }
    @objc private func toggleCleanup() { settings.correction = !settings.permitsCorrection(health: controller.health) }
    @objc private func pickStyle(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        settings.correctionProfile = id
        // Custom needs instructions: open the style editor, where they are written.
        if id == CorrectionProfile.customID { actions.openSettings(.cleanup) }
    }
    @objc private func fixServer() { actions.fixServer() }
    @objc private func showSettings() { actions.openSettings(nil) }
    @objc private func editStyles() { actions.openSettings(.cleanup) }
    @objc private func showSetup() { actions.openSetup() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func showHistory() { actions.showHistory(nil) }
    @objc private func insertDictation(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { actions.insertDictation(id) }
    }
    @objc private func copyDictation(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { actions.copyDictation(id) }
    }
    @objc private func openDictation(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { actions.showHistory(id) }
    }
}

/// The bird glyphs (template images in Contents/Resources). The waves are the listening glyph minus the idle bird, so
/// the pulse can fade them while the bird stays put. SF Symbols stand in when run outside the bundle.
@MainActor
private final class Glyphs {
    let idle: NSImage?
    private let full: NSImage?
    private let waves: NSImage?

    init() {
        idle = Self.load("MenuBarIdle")
        full = Self.load("MenuBarListening")
        if let full, let idle {
            waves = NSImage(size: full.size, flipped: false) { rect in
                full.draw(in: rect)
                idle.draw(in: rect, from: .zero, operation: .destinationOut, fraction: 1)
                return true
            }
        } else {
            waves = nil
        }
    }

    func listening(waveAlpha: Double) -> NSImage? {
        guard let idle, let waves else { return full }
        guard waveAlpha < 1 else { return full }
        let image = NSImage(size: idle.size, flipped: false) { rect in
            idle.draw(in: rect)
            waves.draw(in: rect, from: .zero, operation: .sourceOver, fraction: waveAlpha)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Chirp"
        return image
    }

    private static func load(_ name: String) -> NSImage? {
        guard let image = Bundle.main.image(forResource: name) else { return nil }
        image.isTemplate = true
        image.accessibilityDescription = "Chirp"
        return image
    }
}
