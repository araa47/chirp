import AppKit
import ChirpCore
import ChirpUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = DictationController()
    private let settingsWindow = SettingsWindowController()
    private let localModelsWindow = LocalModelsWindowController()
    private let pairingWindow = PairingWindowController()
    private lazy var notes = NotesController(health: { [controller] in controller.health })
    private let serverWatch = ServerWatch()
    private lazy var notesWindow = NotesWindowController(notes: notes)
    private let history = DictationHistory()
    private let learning = EditLearning()
    private lazy var historyWindow = HistoryWindowController(history: history)
    private let dock = DockController()
    private let openNotesHotkey = OpenNotesHotkey()
    /// Paste Last Dictation (⌃⌥V) and Dictation History (⌃⌥H), from any app.
    private let pasteLastHotkey = ActionHotkey(.pasteLast, id: 6)
    private let historyHotkey = ActionHotkey(.openHistory, id: 7)
    private lazy var onboardingWindow = OnboardingWindowController(controller: controller)
    private var menu: MenuBarController?
    private var healthTimer: Timer?
    private var historyTimer: Timer?

    func applicationWillTerminate(_ notification: Notification) { localModelsWindow.stop() }

    /// Quit stops Notes gracefully (at most 5 s), then asks about unsaved notes before the app goes.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if notes.library != nil {
            Task {
                await notes.stopForQuit()
                notes.journal.flush()
                await notes.journal.settle()
                NSApp.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        guard notes.isActive || notes.model.document.isDirty else { return .terminateNow }
        Task {
            await notes.stopForQuit()
            self.notesWindow.confirmDiscard { ok in
                NSApp.reply(toApplicationShouldTerminate: ok)
            }
        }
        return .terminateLater
    }

    /// A click on the Dock icon (or opening Chirp again) brings the Notes window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        notesWindow.show()
        return false
    }

    /// Dock menu: Open Notes, New Note, Start/Stop Recording, Pause while recording (the window list is AppKit's).
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Notes", action: #selector(dockOpenNotes), keyEquivalent: ""))
        let new = NSMenuItem(title: "New Note", action: #selector(dockNewNotes), keyEquivalent: "")
        new.isEnabled = !notes.isActive
        menu.addItem(new)
        let record = NSMenuItem(title: notes.isRecording ? "Stop Recording" : notes.isPaused ? "Resume Recording" : "Start Recording",
                                action: #selector(dockToggleRecording), keyEquivalent: "")
        record.isEnabled = notes.isRecording || notes.isPaused || (!notes.isActive && !controller.state.isActive)
        menu.addItem(record)
        if notes.isRecording { menu.addItem(NSMenuItem(title: "Pause Recording", action: #selector(dockPauseRecording), keyEquivalent: "")) }
        for item in menu.items { item.target = self }
        return menu
    }
    @objc private func dockOpenNotes() { notesWindow.show() }
    @objc private func dockNewNotes() { notesWindow.newNotes() }
    @objc private func dockToggleRecording() { notes.toggle(fromHotkey: false) }
    @objc private func dockPauseRecording() { notes.togglePauseFromHotkey() }

    /// Dictation history: the controller keeps each dictation, the window and Settings show them, and retention runs
    /// at launch and every few hours.
    private func setUpHistory() {
        controller.history = history
        controller.learning = learning
        learning.onLearned = { [controller] items in controller.showLearned(items) }
        learning.onChange = { [settingsWindow] in settingsWindow.learnedChanged() }
        settingsWindow.learning = learning
        historyWindow.onTeach = { [learning] entry, wanted in
            await learning.teach(inserted: entry.text, wanted: wanted, raw: entry.raw ?? entry.text, bundleID: entry.bundleID,
                                 appName: entry.appName).map(\.correction.title)
        }
        Task { [learning] in await learning.reload() }
        history.onChange = { [weak self] in self?.historyWindow.historyChanged() }
        historyWindow.onInsertAgain = { [controller] text in await controller.insertAgain(text) }
        historyWindow.onAddToNotes = { [weak self] entry in self?.addToNotes(entry) }
        historyWindow.onOpenSettings = { [settingsWindow] in settingsWindow.show(tab: .dictation) }
        settingsWindow.history = history
        settingsWindow.onOpenHistory = { [weak self] in self?.historyWindow.show() }
        Task { [history] in await history.maintain(retention: settings.historyRetention) }
        historyTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [history] _ in
            Task { @MainActor in await history.maintain(retention: settings.historyRetention) }
        }
    }

    /// The menu's newest dictation: this run's, else History's newest entry after a relaunch.
    private func lastDictation() -> LastDictation? {
        if let last = controller.lastDictation {
            return LastDictation(preview: HistoryText.preview(last.text, limit: 60), date: last.date,
                                 historyID: last.historyID?.uuidString)
        }
        guard let entry = history.recent(1).first else { return nil }
        return LastDictation(preview: HistoryText.menuTitle(entry, limit: 60), date: entry.date, historyID: entry.id.uuidString)
    }

    /// Paste Last Dictation (the shortcut and the menu): through Insert Again, so Chirp steps aside first when one of
    /// its windows is in front.
    private func pasteLast() {
        controller.pasteLast { [historyWindow] text in historyWindow.insertAgain(text) }
    }

    /// History's Add to Notes: the dictation becomes a new note in the library, shown in the Notes window.
    private func addToNotes(_ entry: DictationEntry) {
        guard let library = notes.library else { return }
        let document = NotesDocument(startedAt: Date(), text: entry.text)
        Task {
            do {
                try await library.write(NotesJournalRecord(document: document, elapsed: 0))
                notes.showNote(document.id.uuidString)
                notesWindow.show()
            } catch {
                NSSound.beep()
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu = MenuBarController(
            controller: controller,
            actions: .init(openSettings: { [settingsWindow] in settingsWindow.show(tab: $0) },
                           openSetup: { [onboardingWindow] in onboardingWindow.show() },
                           toggleNotes: { [notes] in notes.toggle(fromHotkey: false) },
                           showNotes: { [notesWindow] in notesWindow.show() },
                           newNote: { [notes] in notes.recordNewNote() },
                           openNote: { [notes, notesWindow] id in notes.showNote(id); notesWindow.show() },
                           recentNotes: { [notes] in notes.recentNotes },
                           notes: { [notes, openNotesHotkey] in var state = notes.menuState; state.openShortcut = openNotesHotkey.title; return state },
                           setRunning: { [notes, openNotesHotkey, pasteLastHotkey, historyHotkey] in
                               notes.setRunning($0); openNotesHotkey.setRunning($0)
                               pasteLastHotkey.setRunning($0); historyHotkey.setRunning($0)
                           },
                           serverNotice: { [serverWatch] in (serverWatch.notice, serverWatch.message) },
                           fixServer: { [serverWatch] in serverWatch.fix() },
                           showHistory: { [weak self] id in self?.historyWindow.show(selecting: id) },
                           historyEnabled: { settings.historyEnabled },
                           recentDictations: { [history] in
                               history.recent(MenuContent.recentDictationLimit).map {
                                   RecentDictation(id: $0.id.uuidString, preview: HistoryText.menuTitle($0, limit: 60), date: $0.date)
                               }
                           },
                           insertDictation: { [weak self] id in
                               guard let self, let entry = self.history.entries.first(where: { $0.id.uuidString == id }) else { return }
                               self.historyWindow.insertAgain(entry.text)
                           },
                           copyDictation: { [history] id in
                               guard let entry = history.entries.first(where: { $0.id.uuidString == id }) else { return }
                               NSPasteboard.general.clearContents()
                               NSPasteboard.general.setString(entry.text, forType: .string)
                           },
                           lastDictation: { [weak self] in self?.lastDictation() },
                           pasteLast: { [weak self] in self?.pasteLast() },
                           copyLast: { [controller] in
                               guard let text = controller.lastDictationText() else { return }
                               NSPasteboard.general.clearContents()
                               NSPasteboard.general.setString(text, forType: .string)
                           },
                           pasteLastShortcut: { [pasteLastHotkey] in pasteLastHotkey.title },
                           historyShortcut: { [historyHotkey] in historyHotkey.title }))
        settingsWindow.privateSession = controller.privateSession
        setUpHistory()
        settingsWindow.library = notes.library
        settingsWindow.onOpenSetup = { [onboardingWindow] in onboardingWindow.show() }
        settingsWindow.onOpenModels = { [localModelsWindow] in localModelsWindow.show() }
        settingsWindow.onPairPhone = { [pairingWindow] in pairingWindow.show() }
        pairingWindow.onPaired = { [settingsWindow] in settingsWindow.refreshDevices() }
        settingsWindow.onOpenNotes = { [notesWindow] in notesWindow.show() }
        onboardingWindow.onOpenModels = { [localModelsWindow] in localModelsWindow.show() }
        onboardingWindow.onOpenNotes = { [notesWindow] in notesWindow.show() }
        localModelsWindow.onServerChanged = { [controller] in Task { await controller.refreshHealth() } }
        settingsWindow.serverStatus = { [controller] in MenuContent.serverStatus(health: controller.health, healthError: controller.healthError) }
        settingsWindow.health = { [controller] in controller.health }
        settingsWindow.serverNotice = { [serverWatch] in (serverWatch.notice, serverWatch.message) }
        settingsWindow.onFixServer = { [serverWatch] in serverWatch.fix() }
        notes.model.onFixServer = { [serverWatch] in serverWatch.fix() }
        notes.model.onServerSettings = { [settingsWindow] in settingsWindow.show(tab: .advanced) }
        serverWatch.onFixed = { [controller] in Task { await controller.refreshHealth() } }
        serverWatch.onChange = { [weak self] in
            guard let self else { return }
            notes.model.serverNotice = serverWatch.notice
            notes.model.serverFixMessage = serverWatch.message
        }
        settingsWindow.catalog = { [controller] in controller.styleCatalog }
        settingsWindow.onHotkeyChange = { [controller, notes] in controller.registerHotkey(); notes.model.dictationKey = settings.hotkey.title }
        settingsWindow.onRecordingChanged = { [controller, notes, openNotesHotkey, pasteLastHotkey, historyHotkey] recording in
            // A live shortcut would start a dictation or Notes while the user is typing the new one.
            if recording {
                controller.suspendHotkey(); notes.suspendHotkey(); openNotesHotkey.suspend()
                pasteLastHotkey.suspend(); historyHotkey.suspend()
            } else {
                controller.registerHotkey(); notes.registerHotkey(); openNotesHotkey.register()
                pasteLastHotkey.register(); historyHotkey.register()
            }
        }
        settingsWindow.onShortcutChange = { [weak self, notes, openNotesHotkey, pasteLastHotkey, historyHotkey] shortcut in
            switch shortcut {
            case .notes: notes.registerHotkey(); notes.model.notesKey = settings.notesHotkey.title
            case .openNotes: openNotesHotkey.register()
            case .pasteLast: pasteLastHotkey.register()
            case .openHistory: historyHotkey.register()
            case .dictation, .useRaw: break   // dictation has onHotkeyChange; Use raw is registered per offer
            }
            self?.menu?.refreshIcon()
        }
        controller.onChange = { [weak self, serverWatch, controller] in
            self?.menu?.refreshIcon()
            self?.notes.healthChanged()
            Task { await serverWatch.update(health: controller.health) }
        }
        controller.isBlocked = { [notes] in notes.isActive }
        notes.health = { [controller] in controller.health }
        notes.isDictating = { [controller] in controller.state.isActive }
        notes.onChange = { [weak self] in
            guard let self else { return }
            self.menu?.refreshIcon()
            // Recording behind a closed window keeps the Dock icon, so the window can be found again.
            let active = self.notes.isActive
            if self.dock.presence.recording != active { self.dock.update { $0.recordingChanged(active) } }
        }
        notes.onShowWindow = { [weak self] focus in self?.notesWindow.show(focus: focus) }
        settingsWindow.onCallAudioDefaultChange = { [notes] in notes.defaultSourcesChanged() }
        settingsWindow.onAllowRetranscribe = { [notes] in notes.retranscribeSettingChanged() }
        notesWindow.dock = dock
        NotesWindowController.onAbout = { [settingsWindow] in settingsWindow.show(tab: .about) }
        NotesWindowController.onSettings = { [settingsWindow] in settingsWindow.show(tab: .general) }
        NotesWindowController.installEditMenu()
        dock.apply()
        settingsWindow.onAlwaysShowInDockChange = { [weak self] on in self?.dock.update { $0.alwaysShow = on } }
        openNotesHotkey.open = { [notesWindow] in notesWindow.show() }
        openNotesHotkey.onChange = { [weak self] in self?.menu?.refreshIcon() }
        controller.routeToNotes = { [weak self] dictating in
            guard let self else { return false }
            return self.notes.takeDictationHotkey(notesFrontmost: self.notesWindow.isFrontmost, dictationActive: dictating)
        }
        notesWindow.onOpenModels = { [localModelsWindow] in localModelsWindow.show() }
        settingsWindow.onRemoveSpeakerModel = { [notes] in notes.removeSpeakerModel() }
        settingsWindow.onSpeakerLabels = { [notes] on in notes.setSpeakerLabels(on) }
        settingsWindow.onRetrySpeakerModel = { [notes] in notes.speakers.retry() }
        settingsWindow.speakerModel = { [notes] in (notes.speakers.model, notes.speakers.sizeText) }
        settingsWindow.notesRecording = { [notes] in notes.isActive }
        notes.onSpeakerModelChange = { [settingsWindow] in settingsWindow.speakerModelChanged() }
        settingsWindow.voices = notes.voices
        notes.onVoicesChange = { [settingsWindow] in settingsWindow.voicesChanged() }
        controller.onHotkeyPressed = { [weak self] in self?.onboardingWindow.hotkeyPressed() }

        chirpLog.info("launch microphone=\(Permissions.microphone.rawValue, privacy: .public) accessibility=\(Permissions.accessibilityGranted, privacy: .public) hotkey=\(settings.hotkey.id, privacy: .public)")
        if !controller.registerHotkey() {
            NSLog("Chirp: could not register the hotkey \(settings.hotkey.title); it may be in use by another app")
        }

        if !notes.registerHotkey() {
            NSLog("Chirp: could not register the Live Notes hotkey \(settings.notesHotkey.title); it may be in use by another app")
        }
        if !openNotesHotkey.register() {
            NSLog("Chirp: could not register the Open Notes hotkey \(settings.openNotesHotkey.title); it may be in use by another app")
        }
        pasteLastHotkey.action = { [weak self] in self?.pasteLast() }
        historyHotkey.action = { [weak self] in self?.historyWindow.show() }
        for hotkey in [pasteLastHotkey, historyHotkey] {
            hotkey.onChange = { [weak self] in self?.menu?.refreshIcon() }
            if !hotkey.register() {
                NSLog("Chirp: could not register the \(hotkey.shortcut.owner) hotkey \(settings[shortcut: hotkey.shortcut].title); it may be in use by another app")
            }
        }

        Sounds.prepare()   // decode the cues now so the first start sound has no wait
        Task { await controller.refreshHealth() }
        healthTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [controller] _ in
            Task { @MainActor in
                controller.retryHotkeyIfNeeded()
                await controller.refreshHealth()
            }
        }
        // Posted when any app's Accessibility access changes; the trust check settles a moment later.
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.accessibility.api"),
                                                            object: nil, queue: .main) { [controller] _ in
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                controller.retryHotkeyIfNeeded()
            }
        }

        // A session the last run did not end with Save or Discard (a crash, a force quit, a power loss) comes back here.
        if notes.checkRecovery() { notesWindow.show(focus: false) }

        // First run: the setup window, not Settings. It records completion itself, only once finished.
        if !settings.didOnboard { onboardingWindow.show() }
        if ProcessInfo.processInfo.arguments.contains("--models") { localModelsWindow.show() }
    }
}
