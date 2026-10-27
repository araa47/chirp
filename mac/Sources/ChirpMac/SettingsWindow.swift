import AppKit
import UniformTypeIdentifiers
import ChirpCore
import ChirpSpeakers
import ChirpUI
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSTextFieldDelegate {
    /// Called after the hotkey preset changes so the app can re-register it.
    var onHotkeyChange: (() -> Void)?
    /// One of the shortcut recorders started or stopped listening.
    var onRecordingChanged: ((Bool) -> Void)?
    /// Start/Stop Notes, Open Notes or Use raw changed (recorded or reset).
    var onShortcutChange: ((ChirpShortcut) -> Void)?
    /// The server's state for the Status row, from the app's last health check.
    var serverStatus: () -> (text: String, tone: MenuEntry.Tone) = { ("Checking…", .warning) }
    /// The server's last health, for the styles it offers.
    var health: () -> Health? = { nil }
    /// A server older than the app, and what the last fix said; `onFixServer` runs the fix.
    var serverNotice: () -> (notice: ServerNotice?, message: String?) = { (nil, nil) }
    var onFixServer: (() -> Void)?
    /// The styles with their default prompts (live, or the last-known copy).
    var catalog: () -> StyleCatalog = { .unavailable }
    /// "Set Up Chirp…" in General.
    var onOpenSetup: (() -> Void)?
    var onOpenModels: (() -> Void)?
    var onPairPhone: (() -> Void)?
    var onOpenNotes: (() -> Void)?
    var onRemoveSpeakerModel: (() -> Void)?
    /// Notes › Speakers › Label speakers flipped (the Notes session downloads the model by itself when it is missing).
    var onSpeakerLabels: ((Bool) -> Void)?
    /// Settings → Notes → Allow re-transcribing changed (off stops a run and hides the actions).
    var onAllowRetranscribe: (() -> Void)?
    /// Retry after a failed speaker model download, and the model's state and size as the Notes window has them.
    var onRetrySpeakerModel: (() -> Void)?
    var speakerModel: () -> (state: SpeakerModelState, size: String) = { (.notDownloaded, "") }
    /// A Live Notes recording is running: Label speakers waits for the next one.
    var notesRecording: () -> Bool = { false }
    /// Live Notes voice profiles (Settings → Notes → Saved voices).
    var voices: SpeakerVoices?
    /// The Notes library: Recently Deleted's count and the kept-audio total, and the two bulk actions on them.
    var library: NotesLibrary?
    /// Notes › Sources: the call-audio default changed.
    var onCallAudioDefaultChange: (() -> Void)?
    /// Dictation history: the kept dictations (count, Clear), and the History window.
    var history: DictationHistory?
    var onOpenHistory: (() -> Void)?
    /// Learn from my edits: what was learned, shown in the Learned sheet.
    var learning: EditLearning?
    private let learnedModel = LearnedModel()
    private var learnedSheet: NSWindow?
    /// "Always show in the Dock" flipped.
    var onAlwaysShowInDockChange: ((Bool) -> Void)?
    private lazy var devices: DevicesModel = {
        let model = DevicesModel(store: PairedDevices.store, remoteHost: {
            let config = settings.serverConfig()
            return config.isLoopback ? nil : config.host
        }, activity: { DeviceActivityClient(baseURL: settings.serverConfig().baseURL) })
        model.onChange = { [weak self] in self?.showDevices() }
        return model
    }()
    /// Asks for device activity every few seconds, only while the Devices tab or the Activity sheet is on screen.
    private lazy var activityPoller = ActivityPoller(schedule: ActivityPoller.timer) { [weak self] in
        guard let self else { return }
        Task { await self.devices.refreshActivity() }
    }
    private var activityView: DeviceActivityView?
    private var activitySheet: NSWindow?
    private var testTask: Task<Void, Never>?
    private var window: NSWindow?
    private var tabs: SettingsShellController?
    private var form: SettingsForm?
    private var refreshTimer: Timer?
    /// What the server last said about keeping the clean-up model loaded, and the request that is updating it.
    private var keepLoaded = KeepLoadedState()
    private var keepLoadedTask: Task<Void, Never>?

    var privateSession: PrivateSession?

    private var state: SettingsState {
        var s = SettingsState()
        s.hotkey = settings.hotkey
        s.notesHotkey = settings.notesHotkey
        s.openNotesHotkey = settings.openNotesHotkey
        s.useRawHotkey = settings.useRawHotkey
        s.alwaysShowInDock = settings.alwaysShowInDock
        s.activationMode = settings.activationMode
        s.autoEnter = settings.autoEnter
        s.autoStopSilence = settings.autoStopSilence
        s.serverURL = settings.serverURL
        s.tokenPresent = ServerConfig.readToken() != nil
        s.launch = LaunchAtLogin.state
        s.privateSession = privateSession?.isActive ?? false
        s.spokenCommands = settings.spokenCommands
        s.wordWaveform = settings.wordWaveform
        s.notesRetention = settings.notesRetention
        s.notesKeepAudio = settings.notesKeepAudio
        s.notesAllowRetranscribe = settings.notesAllowRetranscribe
        s.notesCallAudio = settings.notesCallAudio
        s.recentlyDeletedCount = library?.recentlyDeleted.count ?? 0
        s.notesAudioBytes = library?.totalAudioBytes ?? 0
        s.exportFolder = settings.notesExportFolder
        s.historyEnabled = settings.historyEnabled
        s.historyRetention = settings.historyRetention
        s.historyExcludedApps = settings.historyExcludedApps
        s.historyCount = history?.entries.count ?? 0
        s.learnFromEdits = settings.learnFromEdits
        s.learnedSummary = LearnedText.summary(learning?.items ?? [])
        s.autoReorganize = settings.notesAutoReorganize
        s.soundsEnabled = settings.soundsEnabled
        s.soundPack = settings.soundPack
        s.soundVolume = settings.soundVolume
        s.customStart = settings.customStartSound
        s.customStop = settings.customStopSound
        s.micGranted = Permissions.microphoneGranted
        s.accessibilityGranted = Permissions.accessibilityGranted
        (s.serverStatus, s.serverStatusTone) = serverStatus()
        (s.serverNotice, s.serverFixMessage) = serverNotice()
        s.cleanupStyle = settings.correctionProfile
        s.stylePrompts = settings.correctionPrompts
        s.cleanupEnabled = settings.permitsCorrection(health: health())
        s.offerRaw = settings.showRawAfterCleanup
        s.insertRawFirst = settings.insertRawFirst
        s.showChanges = settings.showChangesAfterCleanup
        s.appStyles = settings.appStyles
        let health = health()
        s.structureNotes = settings.notesStructureEnabled(health: health)
        (s.cleanupDetail, s.cleanupAvailable) = SettingsForm.cleanupDetail(health: health, local: settings.serverConfig().isLoopback)
        let catalog = catalog()
        s.catalog = catalog
        s.profiles = catalog.source == .unavailable ? CorrectionProfile.offered(by: health) : catalog.profiles
        s.serverOffersStyles = health == nil || health?.correctionProfiles != nil
        s.keepLoaded = keepLoaded
        s.speakerModelDownloaded = SpeakerModel.hasFiles()
        (s.speakerModel, s.speakerModelSize) = speakerModel()
        s.speakerLabels = settings.notesSpeakerLabels
        s.speakerLabelsLocked = notesRecording()
        s.voices = voicesState
        s.inputs = InputDevice.all().map(\.input)
        s.defaultInput = InputDevice.systemDefault()?.input
        s.chosenInputUID = settings.inputDeviceUID
        s.about = AboutInfo(infoDictionary: Bundle.main.infoDictionary)
        s.serverHost = KeepLoaded.hostPhrase(ServerConfig(baseURL: URL(string: settings.serverURL) ?? ServerConfig.defaultURL))
        return s
    }

    /// Fills the form from the system, and puts the permission badge on General.
    private func refresh(full: Bool = false) {
        let state = state
        form?.apply(state, full: full)
        tabs?.shell.setBadge(SettingsShell.permissionProblems(micGranted: state.micGranted, accessibilityGranted: state.accessibilityGranted))
    }

    /// Opens Settings, on `tab` when given (else on the page it was left on).
    func show(tab: SettingsTab? = nil) {
        if window == nil { window = makeWindow() }
        refresh()
        Task { await voices?.refresh() }
        if let tab { tabs?.shell.show(tab, notify: false) }
        Task { [weak self] in
            try? await self?.library?.reload()
            self?.refresh()
        }
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        // Ordering the window front lets AppKit pick the first text field; park focus on the page instead.
        if let window, let shell = tabs?.shell { window.makeFirstResponder(shell.form.view(for: shell.selected)) }
        pageShown(tabs?.shell.selected ?? .general)
    }

    /// A page came on screen: the ones that ask the server or the library refresh what they show.
    private func pageShown(_ tab: SettingsTab) {
        if tab == .advanced { refreshKeepLoaded() }
        if tab == .devices { refreshDevices() }
        activityPoller.tabVisible = tab == .devices && window?.isVisible == true
    }

    // MARK: paired devices

    /// Asks the server for its devices again (opening the tab, after a pairing or a revoke).
    func refreshDevices() {
        guard form != nil else { return }
        Task { await devices.refresh() }
    }

    private func showDevices() {
        form?.devicesView.apply(devices.phase, revoking: devices.revoking, problem: devices.problem, activity: devices.activity,
                                keepProblem: devices.keepProblem)
        if let activity = devices.activity.activity, activity.keep { activityView?.apply(activity) }
        // Activity turned off (here or elsewhere) while the sheet is open: close it.
        if activitySheet != nil, devices.activity.activity?.keep != true { closeActivitySheet() }
    }

    private func showActivitySheet() {
        guard let window, let activity = devices.activity.activity, activitySheet == nil else { return }
        let view = DeviceActivityView()
        view.apply(activity)
        view.onDone = { [weak self] in self?.closeActivitySheet() }
        let sheet = NSWindow(contentRect: NSRect(origin: .zero, size: DeviceActivityView.size), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.contentView = view
        sheet.isReleasedWhenClosed = false
        activityView = view
        activitySheet = sheet
        activityPoller.sheetVisible = true
        window.beginSheet(sheet)
    }

    private func closeActivitySheet() {
        guard let sheet = activitySheet else { return }
        window?.endSheet(sheet)
        activitySheet = nil
        activityView = nil
        activityPoller.sheetVisible = false
    }

    /// "Keep device activity" flipped. Turning it off deletes the stored list, so it asks first.
    private func keepActivity(_ on: Bool) {
        guard !on else {
            Task { await devices.setKeepActivity(true) }
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = ActivityText.confirmOffTitle()
        alert.informativeText = ActivityText.confirmOffDetail
        alert.addButton(withTitle: "Turn Off")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn {
                Task { await self.devices.setKeepActivity(false) }
            } else {
                self.showDevices()   // put the switch back
            }
        }
        if let window, window.isVisible { alert.beginSheetModal(for: window, completionHandler: handle) } else { handle(alert.runModal()) }
    }

    private func confirmRevoke(_ device: PairedDevice) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = DevicesText.revokeTitle(device)
        alert.informativeText = DevicesText.revokeDetail
        alert.addButton(withTitle: "Revoke")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task { await self.devices.revoke(device) }
        }
    }

    /// The shared token is replaced where the server runs, so this explains and copies the commands rather than
    /// restarting a server Chirp did not start.
    @objc private func rotateSharedToken() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset the shared code?"
        alert.informativeText = SharedTokenRotation.warning + "\n\nChirp copies the commands to run in Terminal; nothing changes until you run them."
        alert.addButton(withTitle: "Copy Commands")
        alert.addButton(withTitle: "Cancel")
        guard let window else { return }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(SharedTokenRotation.commands, forType: .string)
        }
    }

    // MARK: keep clean-up model loaded

    private var serverConfig: ServerConfig { ServerConfig.load(urlString: settings.serverURL) }

    private func showKeepLoaded() {
        form?.showKeepLoaded(keepLoaded, host: state.serverHost)
    }

    /// Asks the server, and keeps asking every 2 s (for up to 90 s) while the model is loading so the status follows it.
    private func refreshKeepLoaded() {
        keepLoadedTask?.cancel()
        let config = serverConfig
        keepLoadedTask = Task { @MainActor [weak self] in
            for _ in 0..<45 {
                do throws(CleanupSettingsError) {
                    let s = try await config.fetchCleanupSettings()
                    guard !Task.isCancelled, let self else { return }
                    self.keepLoaded.fetched(s)
                } catch {
                    guard !Task.isCancelled, let self else { return }
                    self.keepLoaded.fetchFailed(error)
                }
                guard let self else { return }
                self.showKeepLoaded()
                guard self.keepLoaded.isLoading, self.window?.isVisible == true else { return }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// The switch changes at once; a refused change puts it back with the reason under it. Either way the server is
    /// asked again afterwards, so the status shows what it really did.
    @objc private func toggleKeepLoaded(_ sender: NSButton) {
        let on = sender.state == .on
        guard keepLoaded.toggle(to: on) else { showKeepLoaded(); return }
        showKeepLoaded()
        keepLoadedTask?.cancel()
        let config = serverConfig
        keepLoadedTask = Task { @MainActor [weak self] in
            do throws(CleanupSettingsError) {
                let s = try await config.setKeepLoaded(on)
                self?.keepLoaded.toggleSucceeded(s)
            } catch {
                self?.keepLoaded.toggleFailed(error)
            }
            self?.showKeepLoaded()
            self?.refreshKeepLoaded()
        }
    }

    /// A row appeared or went (the Custom sound rows, a paired phone): the page re-flows itself; the window never resizes.
    private func tabSizeChanged() {
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func makeWindow() -> NSWindow {
        let form = SettingsForm(state, icon: ChirpBrand.glyph(), onNotices: { Self.openNotices() })
        form.setupButton.target = self
        form.setupButton.action = #selector(openSetup)
        form.doctorButton.target = self
        form.doctorButton.action = #selector(copyDoctor)
        form.serverFixButton.target = self
        form.serverFixButton.action = #selector(fixServer)
        form.modelsButton.target = self
        form.modelsButton.action = #selector(openModels)
        form.pairButton.target = self
        form.pairButton.action = #selector(pairPhone)
        form.rotateButton.target = self
        form.rotateButton.action = #selector(rotateSharedToken)
        form.devicesView.onRevoke = { [weak self] in self?.confirmRevoke($0) }
        form.devicesView.onShowActivity = { [weak self] in self?.showActivitySheet() }
        form.devicesView.onKeepActivity = { [weak self] in self?.keepActivity($0) }
        form.devicesView.onResize = { [weak self] in self?.tabSizeChanged() }
        form.notesButton.target = self
        form.notesButton.action = #selector(openNotes)
        form.microphone.target = self
        form.microphone.action = #selector(microphoneChanged(_:))
        form.removeSpeakerModel.target = self
        form.removeSpeakerModel.action = #selector(removeSpeakerModel)
        form.retrySpeakerModel.target = self
        form.retrySpeakerModel.action = #selector(retrySpeakerModel)
        form.savedVoicesButton.target = self
        form.savedVoicesButton.action = #selector(showSavedVoices)
        form.voicesView.onRefresh = { [weak self] in Task { await self?.voices?.refresh() } }
        form.voicesView.onRename = { [weak self] in self?.renameSavedVoice($0) }
        form.voicesView.onToggle = { [weak self] in self?.toggleVoices($0) }
        form.voicesView.onForget = { [weak self] in self?.confirmForgetVoice($0) }
        form.voicesView.onForgetAll = { [weak self] in self?.confirmForgetVoice(nil) }
        form.voicesView.onResize = { [weak self] in self?.tabSizeChanged() }
        form.cleanupEnabled.target = self
        form.cleanupEnabled.action = #selector(toggleCleanup(_:))
        form.keepLoaded.target = self
        form.keepLoaded.action = #selector(toggleKeepLoaded(_:))
        form.offerRaw.target = self
        form.offerRaw.action = #selector(toggleOfferRaw(_:))
        form.hotkey.target = self
        form.hotkey.action = #selector(hotkeyChanged(_:))
        form.keyboardSettingsButton.target = self
        form.keyboardSettingsButton.action = #selector(openKeyboardSettings)
        form.recorder.onCapture = { [weak self] combo in
            settings.hotkey = combo
            self?.fillHotkeyMenu()
            self?.tabSizeChanged()
            self?.onHotkeyChange?()
        }
        form.recorder.onRecordingChanged = { [weak self] recording in self?.onRecordingChanged?(recording) }
        form.recorder.conflict = { ChirpShortcut.dictation.conflict($0) { settings[shortcut: $0] } }
        for shortcut in ChirpShortcut.allCases {
            guard let controls = form.controls(for: shortcut) else { continue }
            controls.recorder.conflict = { shortcut.conflict($0) { settings[shortcut: $0] } }
            controls.recorder.onCapture = { [weak self] combo in self?.setShortcut(shortcut, combo) }
            controls.recorder.onRecordingChanged = { [weak self] in self?.onRecordingChanged?($0) }
            controls.reset.target = self
            controls.reset.action = #selector(resetShortcut(_:))
        }
        form.alwaysInDock.target = self
        form.alwaysInDock.action = #selector(toggleAlwaysInDock(_:))
        form.mode.target = self
        form.mode.action = #selector(modeChanged(_:))
        form.silence.target = self
        form.silence.action = #selector(silenceChanged(_:))
        form.sounds.target = self
        form.sounds.action = #selector(toggleSounds(_:))
        form.soundPack.target = self
        form.soundPack.action = #selector(packChanged(_:))
        form.volume.target = self
        form.volume.action = #selector(volumeChanged(_:))
        for (button, action) in [(form.previewStart, #selector(previewStart)), (form.previewStop, #selector(previewStop)),
                                 (form.chooseStart, #selector(chooseStart)), (form.chooseStop, #selector(chooseStop)),
                                 (form.removeStart, #selector(removeStart)), (form.removeStop, #selector(removeStop))] {
            button.target = self
            button.action = action
        }
        form.autoEnter.target = self
        form.autoEnter.action = #selector(autoEnterChanged(_:))
        form.style.target = self
        form.style.action = #selector(styleChanged(_:))
        form.prompts.onEdit = { [weak self] id, text in
            guard let self else { return }
            settings.setPrompt(text, for: id, in: self.catalog())
        }
        form.prompts.onReset = { settings.resetPrompt(for: $0) }
        form.appStyles.testButton.target = self
        form.appStyles.testButton.action = #selector(testAppStyle)
        form.showChanges.target = self
        form.showChanges.action = #selector(toggleShowChanges(_:))
        form.insertRawFirst.target = self
        form.insertRawFirst.action = #selector(toggleRawFirst(_:))
        form.appStyles.onChange = { settings.appStyles = $0 }
        form.appStyles.onAdd = { [weak self] button in self?.showAppChooser(from: button) }
        form.historyEnabled.target = self
        form.historyEnabled.action = #selector(toggleHistory(_:))
        form.historyRetention.target = self
        form.historyRetention.action = #selector(historyRetentionChanged(_:))
        form.openHistory.target = self
        form.openHistory.action = #selector(openHistory)
        form.clearHistory.target = self
        form.clearHistory.action = #selector(clearHistory)
        form.historyApps.onChange = { settings.historyExcludedApps = $0 }
        form.learnFromEdits.target = self
        form.learnFromEdits.action = #selector(toggleLearning(_:))
        form.showLearned.target = self
        form.showLearned.action = #selector(showLearned)
        form.historyApps.onAdd = { [weak self] button in
            self?.showAppChooser(from: button, have: Set(settings.historyExcludedApps)) { self?.form?.historyApps.add(bundleID: $0) }
        }
        form.serverURL.delegate = self
        form.launch.target = self
        form.launch.action = #selector(toggleLaunch(_:))
        form.privateSession.target = self
        form.privateSession.action = #selector(togglePrivateSession(_:))
        form.spokenCommands.target = self
        form.spokenCommands.action = #selector(toggleSpokenCommands(_:))
        form.wordWaveform.target = self
        form.wordWaveform.action = #selector(toggleWordWaveform(_:))
        form.micButton.target = self
        form.micButton.action = #selector(grantMic)
        form.accessibilityButton.target = self
        form.accessibilityButton.action = #selector(grantAX)
        form.notesRetention.target = self
        form.notesRetention.action = #selector(retentionChanged(_:))
        form.keepAudio.target = self
        form.keepAudio.action = #selector(toggleKeepAudio(_:))
        form.allowRetranscribe.target = self
        form.allowRetranscribe.action = #selector(toggleAllowRetranscribe(_:))
        form.callAudio.target = self
        form.callAudio.action = #selector(toggleCallAudio(_:))
        form.deleteAudio.target = self
        form.deleteAudio.action = #selector(confirmDeleteAudio)
        form.emptyDeleted.target = self
        form.emptyDeleted.action = #selector(confirmEmptyDeleted)
        form.chooseExport.target = self
        form.chooseExport.action = #selector(chooseExportFolder)
        form.resetExport.target = self
        form.resetExport.action = #selector(resetExportFolder)
        form.labelSpeakers.target = self
        form.labelSpeakers.action = #selector(toggleSpeakerLabels(_:))
        form.structureNotes.target = self
        form.structureNotes.action = #selector(toggleStructureNotes(_:))
        form.autoReorganize.target = self
        form.autoReorganize.action = #selector(toggleAutoReorganize(_:))
        self.form = form

        let tabs = SettingsTabs.makeController(form: form) { [weak self] tab in self?.pageShown(tab) }
        tabs.shell.onDetail = { [weak self] title in
            let name = title ?? self?.tabs?.shell.selected.title ?? "Settings"
            self?.window?.title = "Chirp Settings — \(name)"
        }
        self.tabs = tabs
        let w = NSWindow(contentViewController: tabs)
        // A System Settings-style window: fixed size, the sidebar running up under a transparent title bar.
        w.styleMask = [.titled, .closable, .fullSizeContentView]
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.setContentSize(SettingsShell.size)
        w.contentMinSize = SettingsShell.size
        w.contentMaxSize = SettingsShell.size
        w.isReleasedWhenClosed = false
        w.center()
        // Closing the window stops the activity poll; showing it again starts it with the tab.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.closeActivitySheet()
                self?.activityPoller.tabVisible = false
            }
        }
        return w
    }

    func controlTextDidChange(_ obj: Notification) {
        if let f = obj.object as? NSTextField { settings.serverURL = f.stringValue }
    }

    @objc private func openSetup() { onOpenSetup?() }
    @objc private func openModels() { onOpenModels?() }
    @objc private func fixServer() { onFixServer?() }
    @objc private func pairPhone() { onPairPhone?() }
    @objc private func openNotes() { onOpenNotes?() }
    @objc private func microphoneChanged(_ sender: NSPopUpButton) { settings.inputDeviceUID = sender.selectedItem?.representedObject as? String }
    @objc private func openKeyboardSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
    }
    @objc private func removeSpeakerModel() { onRemoveSpeakerModel?() }
    @objc private func retrySpeakerModel() { onRetrySpeakerModel?() }

    /// The speaker model came or went: refresh the Notes tab's row.
    func speakerModelChanged() { refresh() }

    // MARK: voice profiles

    @objc private func showSavedVoices() {
        guard let view = form?.voicesView, let shell = tabs?.shell else { return }
        view.showsTitle = false
        view.fitSettingsPage()
        shell.showDetail(content: view, title: "Saved voices", back: SettingsTab.notes.title)
        Task { await voices?.refresh() }
    }

    private func renameSavedVoice(_ profile: SavedVoice) {
        guard let voices, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Rename saved voice"
        alert.informativeText = "Existing notes keep their names."
        let field = NSTextField(string: profile.name)
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task { await voices.perform(.rename(voice: profile.id, name: field.stringValue)) }
        }
    }

    private var voicesState: VoiceProfilesState {
        var v = VoiceProfilesState()
        v.localServer = settings.serverConfig().isLoopback
        guard let voices else { return v }
        v.enabled = voices.enabled
        v.supported = voices.supported
        v.busy = voices.busy
        v.error = voices.error
        v.profiles = voices.profiles
        return v
    }

    /// The voice switch, the model or the saved voices changed.
    func voicesChanged() { form?.voicesView.apply(voicesState) }

    /// The server-wide stop-storing control. Disable first, then offer to delete the library too.
    private func toggleVoices(_ on: Bool) {
        guard let voices else { return }
        if on { Task { await voices.perform(.enable) }; return }
        let count = voices.profiles.count
        Task { [weak self] in
            guard await voices.perform(.disable(forget: false)), count > 0,
                  let self, let window = self.window else { return }
            let alert = NSAlert()
            alert.messageText = VoiceProfilesText.turnOffTitle(count)
            alert.informativeText = VoiceProfilesText.turnOffDetail(local: settings.serverConfig().isLoopback)
            alert.addButton(withTitle: "Forget")
            alert.addButton(withTitle: "Keep")
            alert.buttons[0].hasDestructiveAction = true
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { Task { await voices.perform(.forgetAll) } }
            }
        }
    }

    /// Forget one saved voice (or all, for nil), after asking.
    private func confirmForgetVoice(_ profile: SavedVoice?) {
        guard let voices, let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = profile.map(VoiceProfilesText.forgetTitle) ?? VoiceProfilesText.forgetAllTitle
        alert.informativeText = VoiceProfilesText.forgetDetail(profile?.name, local: settings.serverConfig().isLoopback)
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            if let profile { Task { await voices.perform(.forget(voice: profile.id)) } } else { Task { await voices.perform(.forgetAll) } }
        }
    }

    /// The notices shipped in the app bundle (`bundle.sh` copies them); the repository copy for a bare `swift run`.
    private static func openNotices() {
        let url = Bundle.main.url(forResource: "NOTICES", withExtension: "md", subdirectory: "ThirdParty")
            ?? URL(string: "https://github.com/araa47/chirp/blob/main/mac/Assets/ThirdParty/NOTICES.md")!
        NSWorkspace.shared.open(url)
    }

    @objc private func copyDoctor() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(DoctorHelp.clipboardText(serverURL: settings.serverURL), forType: .string)
    }

    @objc private func toggleCleanup(_ sender: NSButton) { settings.correction = sender.state == .on }
    // MARK: notes library

    @objc private func retentionChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let retention = NotesRetention(rawValue: raw) else { return }
        // Applied when Chirp opens (`NotesSession` maintains the library then); older notes go to Recently Deleted first.
        settings.notesRetention = retention
    }

    /// On keeps audio for new notes. Off stops that, and offers to delete what is already kept.
    /// The default for new notes; the help above the switch is the explanation, so turning it on here counts as read.
    @objc private func toggleCallAudio(_ sender: NSButton) {
        settings.notesCallAudio = sender.state == .on
        if sender.state == .on { settings.notesCallAudioExplained = true }
        onCallAudioDefaultChange?()
    }

    @objc private func toggleKeepAudio(_ sender: NSButton) {
        settings.notesKeepAudio = sender.state == .on
        form?.allowRetranscribe.isEnabled = sender.state == .on || (library?.totalAudioBytes ?? 0) > 0
        if sender.state == .off, (library?.totalAudioBytes ?? 0) > 0 { confirmDeleteAudio() }
    }

    @objc private func toggleAllowRetranscribe(_ sender: NSButton) {
        settings.notesAllowRetranscribe = sender.state == .on
        onAllowRetranscribe?()
    }

    @objc private func confirmDeleteAudio() {
        guard let library, let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete kept audio (\(SettingsForm.sizeText(library.totalAudioBytes)))?"
        alert.informativeText = "The notes and transcripts stay; only the recordings of your voice are removed from this Mac."
        alert.addButton(withTitle: "Delete Audio")
        alert.addButton(withTitle: "Keep")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let library = self?.library else { return }
            Task {
                for entry in library.notes + library.recentlyDeleted where entry.hasAudio { try? await library.deleteAudio(entry.id) }
                self?.refresh()
            }
        }
    }

    @objc private func confirmEmptyDeleted() {
        guard let library, let window else { return }
        let count = library.recentlyDeleted.count
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = NotesLibraryText.emptyTrashTitle
        alert.informativeText = NotesLibraryText.emptyTrashMessage(count)
        alert.addButton(withTitle: NotesLibraryText.deletePermanently)
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let library = self?.library else { return }
            Task {
                for entry in library.recentlyDeleted { try? await library.purge(entry.id) }
                self?.refresh()
            }
        }
    }

    @objc private func chooseExportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Export Markdown… opens in this folder."
        if let current = settings.notesExportFolder { panel.directoryURL = URL(fileURLWithPath: current) }
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            settings.notesExportFolder = url.path
            self?.refresh(full: true)
        }
    }

    @objc private func resetExportFolder() {
        settings.notesExportFolder = nil
        refresh(full: true)
    }

    @objc private func toggleStructureNotes(_ sender: NSButton) {
        settings.setNotesStructure(sender.state == .on, health: health())
    }

    @objc private func toggleSpeakerLabels(_ sender: NSButton) {
        onSpeakerLabels?(sender.state == .on)
        // On waits for the consent (and download); the box shows what the switch is now.
        refresh()
    }

    @objc private func toggleAutoReorganize(_ sender: NSButton) {
        settings.notesAutoReorganize = sender.state == .on
    }

    private func setShortcut(_ shortcut: ChirpShortcut, _ combo: KeyCombo) {
        settings[shortcut: shortcut] = combo
        form?.showShortcuts(state)
        fillHotkeyMenu()
        onShortcutChange?(shortcut)
    }
    /// Reset goes back to the default unless another shortcut has those keys now; the recorder then says so.
    @objc private func resetShortcut(_ sender: NSButton) {
        guard let shortcut = ChirpShortcut.allCases.first(where: { form?.controls(for: $0)?.reset === sender }),
              let controls = form?.controls(for: shortcut) else { return }
        if let why = shortcut.conflict(shortcut.defaultCombo, current: { settings[shortcut: $0] }) {
            controls.refuse(why)
            return
        }
        setShortcut(shortcut, shortcut.defaultCombo)
    }
    /// The presets, with any another shortcut already has disabled.
    private func fillHotkeyMenu() {
        form?.fillHotkeyMenu(selecting: settings.hotkey, taken: ChirpShortcut.dictation.taken { settings[shortcut: $0] })
    }
    @objc private func toggleAlwaysInDock(_ sender: NSButton) {
        settings.alwaysShowInDock = sender.state == .on
        onAlwaysShowInDockChange?(sender.state == .on)
    }
    @objc private func togglePrivateSession(_ sender: NSButton) { privateSession?.setEnabled(sender.state == .on); refresh() }
    @objc private func toggleSpokenCommands(_ sender: NSButton) { settings.spokenCommands = sender.state == .on }
    @objc private func toggleWordWaveform(_ sender: NSButton) { settings.wordWaveform = sender.state == .on }
    @objc private func toggleOfferRaw(_ sender: NSButton) { settings.showRawAfterCleanup = sender.state == .on }

    @objc private func hotkeyChanged(_ sender: NSPopUpButton) {
        settings.hotkey = KeyCombo.resolve(id: sender.selectedItem?.representedObject as? String)
        fillHotkeyMenu()
        tabSizeChanged()
        onHotkeyChange?()
    }

    @objc private func modeChanged(_ sender: NSPopUpButton) {
        settings.activationMode = (sender.selectedItem?.representedObject as? String).flatMap(ActivationMode.init(rawValue:)) ?? .autoStop
        form?.showMode(settings.activationMode, silence: settings.autoStopSilence)
        onHotkeyChange?()
    }

    @objc private func silenceChanged(_ sender: NSPopUpButton) {
        guard let seconds = sender.selectedItem?.representedObject as? Double else { return }
        settings.autoStopSilence = seconds
    }

    @objc private func autoEnterChanged(_ sender: NSPopUpButton) {
        settings.autoEnter = (sender.selectedItem?.representedObject as? String).flatMap(AutoEnter.init(rawValue:)) ?? .off
    }

    @objc private func styleChanged(_ sender: NSPopUpButton) {
        guard let id = sender.selectedItem?.representedObject as? String else { return }
        settings.correctionProfile = id
        form?.fillStyleMenu(state.profiles, selecting: id, offered: state.serverOffersStyles)
    }

    /// "Test": Settings itself is frontmost while the button is pressed, so wait a moment for the user to switch to the
    /// app to check, then say which style applies to it.
    @objc private func testAppStyle() {
        testTask?.cancel()
        form?.appStyles.showTestResult("Switch to the app you want to check. Reading it in 3 seconds…")
        testTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            let app = NSWorkspace.shared.frontmostApplication
            let id = app?.bundleIdentifier
            guard id != Bundle.main.bundleIdentifier else {
                self.form?.appStyles.showTestResult("Chirp itself was frontmost. Press Test, then switch to another app within 3 seconds.")
                return
            }
            let state = self.state
            let resolved = settings.cleanupStyle(frontmostBundleID: id, available: state.serverOffersStyles ? state.profiles : nil)
            let name = state.profiles.first { $0.id == resolved.profile }?.name ?? CorrectionProfile.displayName(for: resolved.profile)
            let appName = id.map { AppNames.name(for: $0) } ?? app?.localizedName
            self.form?.appStyles.showTestResult(CleanupStyle.testSummary(appName: appName, resolved: resolved, styleName: name))
        }
    }

    @objc private func toggleShowChanges(_ sender: NSButton) {
        settings.showChangesAfterCleanup = sender.state == .on
    }

    @objc private func toggleRawFirst(_ sender: NSButton) {
        settings.insertRawFirst = sender.state == .on
    }

    /// "+": the running apps that have no rule yet, then a file chooser for any other app.
    private func showAppChooser(from button: NSView) {
        showAppChooser(from: button, have: Set(settings.appStyles.map(\.bundleID))) { [weak self] in self?.form?.appStyles.add(bundleID: $0) }
    }

    /// Where the app chooser's pick goes (the per-app styles, or History's excluded apps).
    private var addPickedApp: (String) -> Void = { _ in }

    /// The running apps not in `have`, then a file chooser for any other app; the pick goes to `add`.
    private func showAppChooser(from button: NSView, have: Set<String>, add: @escaping (String) -> Void) {
        addPickedApp = add
        let menu = NSMenu()
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .filter { !have.contains($0.bundleIdentifier!) }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
        for app in running {
            let item = NSMenuItem(title: app.localizedName ?? app.bundleIdentifier!, action: #selector(addApp(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app.bundleIdentifier
            item.image = app.icon.map { icon in
                let small = icon.copy() as! NSImage
                small.size = NSSize(width: 16, height: 16)
                return small
            }
            menu.addItem(item)
        }
        if !running.isEmpty { menu.addItem(.separator()) }
        let choose = NSMenuItem(title: "Choose App…", action: #selector(chooseApp), keyEquivalent: "")
        choose.target = self
        menu.addItem(choose)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
    }

    @objc private func addApp(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { addPickedApp(id) }
    }

    @objc private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
        addPickedApp(id)
    }

    // MARK: dictation history

    /// On keeps new dictations at once. Off asks whether to delete what is already kept (Cancel leaves it on).
    @objc private func toggleHistory(_ sender: NSButton) {
        guard sender.state == .off else { settings.historyEnabled = true; refresh(); return }
        let count = history?.entries.count ?? 0
        guard count > 0, let window else { settings.historyEnabled = false; refresh(); return }
        let alert = NSAlert()
        alert.messageText = HistorySettingsText.turnOffTitle
        alert.informativeText = HistorySettingsText.turnOffDetail(count)
        alert.addButton(withTitle: "Turn Off and Delete")
        alert.addButton(withTitle: "Turn Off, Keep History")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                settings.historyEnabled = false
                Task { await self.history?.clear(); self.refresh() }
            case .alertSecondButtonReturn:
                settings.historyEnabled = false
            default:
                break
            }
            self.refresh()
        }
    }

    @objc private func historyRetentionChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String, let retention = DictationRetention(rawValue: raw) else { return }
        settings.historyRetention = retention
        Task { [weak self] in
            await self?.history?.maintain(retention: retention)
            self?.refresh()
        }
    }

    @objc private func openHistory() { onOpenHistory?() }

    // MARK: learn from my edits

    @objc private func toggleLearning(_ sender: NSButton) {
        settings.learnFromEdits = sender.state == .on
        if !settings.learnFromEdits { learning?.watcher.cancel() }
        refresh()
    }

    /// The Learned list as a sheet on Settings; it follows the store while open.
    @objc private func showLearned() {
        guard let window, learnedSheet == nil, let learning else { return }
        learnedModel.items = learning.items
        learnedModel.onSet = { [weak self] id, state in Task { await learning.set(id, state: state); self?.learnedChanged() } }
        learnedModel.onDelete = { [weak self] id in Task { await learning.delete(id); self?.learnedChanged() } }
        learnedModel.onReset = { [weak self] bundleID in self?.confirmReset(bundleID) }
        learnedModel.onDone = { [weak self] in
            guard let self, let sheet = self.learnedSheet else { return }
            window.endSheet(sheet)
            self.learnedSheet = nil
        }
        let sheet = NSWindow(contentViewController: NSHostingController(rootView: LearnedView(model: learnedModel)))
        sheet.setContentSize(LearnedView.size)
        learnedSheet = sheet
        window.beginSheet(sheet)
    }

    /// The store changed (an edit was learned, or the sheet changed something): the sheet and the summary follow.
    func learnedChanged() {
        learnedModel.items = learning?.items ?? []
        refresh()
    }

    private func confirmReset(_ bundleID: String?) {
        guard let sheet = learnedSheet, let learning else { return }
        let alert = NSAlert()
        alert.messageText = "Reset what Chirp learned in \(bundleID.map { AppNames.name(for: $0) } ?? "every app")?"
        alert.informativeText = "Everything learned from your edits there is forgotten. Chirp starts learning again from your next edit."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: sheet) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { await learning.reset(bundleID: bundleID); self?.learnedChanged() }
        }
    }

    @objc private func clearHistory() {
        let count = history?.entries.count ?? 0
        guard count > 0, let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = HistorySettingsText.clearTitle
        alert.informativeText = HistorySettingsText.clearDetail(count)
        alert.addButton(withTitle: "Delete History")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            Task { await self.history?.clear(); self.refresh() }
        }
    }

    @objc private func toggleSounds(_ sender: NSButton) {
        settings.soundsEnabled = sender.state == .on
    }

    // MARK: sounds

    @objc private func packChanged(_ sender: NSPopUpButton) {
        let pack = SoundPack.resolve(id: sender.selectedItem?.representedObject as? String)
        let previous = settings.soundPack
        settings.soundPack = pack
        form?.showPack(pack)
        form?.setCustomSounds(start: settings.customStartSound, stop: settings.customStopSound)
        tabSizeChanged()
        // "Custom…" with nothing chosen yet goes straight to the file chooser; giving up keeps the old pack.
        if pack == .custom, settings.customStartSound == nil, settings.customStopSound == nil {
            if !importSound(for: .start) {
                settings.soundPack = previous
                form?.showPack(previous)
                tabSizeChanged()
            }
        }
        Sounds.prepare()
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        let fraction = sender.doubleValue / 100
        settings.soundVolume = fraction
        form?.setVolume(fraction)
        // Let go of the slider and hear the level (not on every tick of the drag).
        if NSApp.currentEvent?.type == .leftMouseUp { Sounds.play(.start) }
    }

    @objc private func previewStart() { Sounds.prepare(); Sounds.play(.start) }
    @objc private func previewStop() { Sounds.prepare(); Sounds.play(.stop) }
    @objc private func chooseStart() { importSound(for: .start) }
    @objc private func chooseStop() { importSound(for: .stop) }
    @objc private func removeStart() { removeSound(for: .start) }
    @objc private func removeStop() { removeSound(for: .stop) }

    /// Asks for an audio file, copies it into Application Support and remembers the copy. Returns false when the user
    /// cancelled or the file could not be used (the reason shows under the row).
    @discardableResult
    private func importSound(for cue: SoundCue) -> Bool {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]   // aiff, wav, caf, m4a, mp3, …
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = cue == .start ? "Choose the sound that plays when dictation starts."
                                      : "Choose the sound that plays when dictation stops."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            let imported = try Sounds.customStore.importFile(from: url, cue: cue, replacing: settings.customSound(for: cue))
            if cue == .start { settings.customStartSound = imported } else { settings.customStopSound = imported }
            form?.setCustomSounds(start: settings.customStartSound, stop: settings.customStopSound)
            Sounds.prepare()
            Sounds.play(cue)
            return true
        } catch {
            form?.setCustomSounds(start: settings.customStartSound, stop: settings.customStopSound, error: error.localizedDescription)
            return false
        }
    }

    private func removeSound(for cue: SoundCue) {
        Sounds.customStore.remove(settings.customSound(for: cue))
        if cue == .start { settings.customStartSound = nil } else { settings.customStopSound = nil }
        form?.setCustomSounds(start: settings.customStartSound, stop: settings.customStopSound)
        Sounds.prepare()
    }

    @objc private func toggleLaunch(_ sender: NSButton) {
        let error = LaunchAtLogin.toggle()
        sender.state = LaunchAtLogin.state == .on ? .on : .off
        form?.setLaunchError(error)
    }
    @objc private func grantMic() {
        Task {
            if Permissions.microphone == .notDetermined { _ = await Permissions.requestMicrophone() }
            else { Permissions.openSettings(.microphone) }
        }
    }
    @objc private func grantAX() {
        Permissions.promptAccessibility()
        Permissions.openSettings(.accessibility)
    }
}
