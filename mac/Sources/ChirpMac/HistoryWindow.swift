import AppKit
import ChirpCore
import ChirpUI
import SwiftUI

/// The Dictation History window (menu bar: Dictation History… ⌥⌘H). Its own window rather than a section of the
/// Notes library: a dictation is a short piece of text that belongs to another app, its main action (Insert Again)
/// hands the keyboard back to that app, and history is there for people who never use Notes.
@MainActor
final class HistoryWindowController: NSObject, NSWindowDelegate {
    let history: DictationHistory
    let model = HistoryModel()
    /// The window's text size, opened at the remembered one.
    private let textSize = ChirpTextSize()
    private var window: NSWindow?
    static let frameName = "ChirpHistory"
    /// The last app other than Chirp that was frontmost: Insert Again goes back to it.
    private var lastOtherApp: NSRunningApplication?
    var onInsertAgain: (String) async -> Void = { _ in }
    var onAddToNotes: (DictationEntry) -> Void = { _ in }
    var onOpenSettings: () -> Void = {}
    /// Teach Chirp: learn from what the user says the dictation should have been; returns what became active.
    var onTeach: (DictationEntry, String) async -> [String] = { _, _ in [] }

    init(history: DictationHistory) {
        self.history = history
        super.init()
        textSize.restore(settings.historyTextSize)
        textSize.onChange = { settings.historyTextSize = Double($0) }
        model.onCopy = { text in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        model.onInsertAgain = { [weak self] entry in self?.insertAgain(entry.text) }
        model.onAddToNotes = { [weak self] entry in self?.onAddToNotes(entry) }
        model.onDelete = { [history] id in Task { await history.delete(id) } }
        model.onRestore = { [history] entry in Task { await history.restore(entry) } }
        model.onOpenSettings = { [weak self] in self?.onOpenSettings() }
        model.onTeach = { [weak self] entry, wanted in
            Task { @MainActor in
                guard let self else { return }
                self.model.taught(await self.onTeach(entry, wanted))
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                                          queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                self?.lastOtherApp = app
            }
        }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastOtherApp = front
        }
    }

    /// The store changed (a new dictation, a delete, Clear): the window follows.
    func historyChanged() {
        model.show(history.entries)
        model.unavailable = history.unavailable
        model.enabled = settings.historyEnabled
        model.retention = settings.historyRetention
        model.canTeach = settings.learningEnabled
    }

    /// Shows the window, on the dictation `id` when given.
    func show(selecting id: String? = nil) {
        let w = window ?? makeWindow()
        window = w
        historyChanged()
        Task { [history] in await history.maintain(retention: settings.historyRetention) }
        if let id, let uuid = UUID(uuidString: id) {
            model.query = ""
            model.selection = uuid
        }
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let size = HistoryViewMetrics.defaultSize
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = HistoryText.windowTitle
        w.toolbarStyle = .unified
        w.contentViewController = NSHostingController(rootView: HistoryView(model: model, textSize: textSize))
        w.setContentSize(size)
        w.contentMinSize = HistoryViewMetrics.minimumSize
        w.isReleasedWhenClosed = false
        // Size and position only, never content.
        w.isRestorable = false
        w.tabbingMode = .disallowed
        w.delegate = self
        if !w.setFrameUsingName(Self.frameName) { w.center() }
        w.setFrameAutosaveName(Self.frameName)
        return w
    }

    /// Insert Again from the window or the menu: the app you were in comes back to the front (Chirp steps aside when
    /// it is active), then the text goes into its focused field.
    func insertAgain(_ text: String) {
        Task {
            if NSApp.isActive, let app = lastOtherApp, !app.isTerminated {
                app.activate()
                for _ in 0..<20 where NSWorkspace.shared.frontmostApplication?.processIdentifier != app.processIdentifier {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                // Let the app restore its focused field before the text arrives.
                try? await Task.sleep(for: .milliseconds(150))
            }
            await onInsertAgain(text)
        }
    }
}
