import AppKit
import ChirpCore

/// The Notes window's own shortcuts. They live in the main menu (so Help search finds them) and work only while the
/// Notes window is key; this is the list the menu is built from and the tests check.
public enum NotesCommand: CaseIterable, Sendable {
    case newNote, record, pause, renameNote, deleteNote
    /// Re-transcribe Note… and Restore Previous Transcript (#287): hidden, not greyed, when they don't apply.
    case retranscribe, restoreTranscript
    case findNotes, copyMarkdown, export
    case toggleInspector, showMarkdown, biggerText, smallerText, actualSize, readFormattedNote
    case restoreOrganize

    /// Which main-menu menu the command sits in.
    public enum Menu: Sendable { case notes, view, edit }

    public struct Item: Equatable, Sendable {
        public var command: NotesCommand
        public var title: String
        public var key: String
        public var modifiers: NSEvent.ModifierFlags
        public var enabled: Bool
        /// A check mark: Show Markdown is on.
        public var checked: Bool
        /// Left out of the menu (re-transcribe without kept audio, or turned off).
        public var hidden = false
    }

    public var menu: Menu {
        switch self {
        case .toggleInspector, .showMarkdown, .biggerText, .smallerText, .actualSize, .readFormattedNote: .view
        case .restoreOrganize: .edit
        default: .notes
        }
    }

    static let shiftCommand: NSEvent.ModifierFlags = [.command, .shift]
    static let optionCommand: NSEvent.ModifierFlags = [.command, .option]
    /// ⌫ as a key equivalent.
    static let backspace = String(UnicodeScalar(NSBackspaceCharacter)!)

    /// The menu rows. `model` is the recorder's note; `library` (the window) knows the note on screen when another
    /// one records. Everything is disabled unless `windowIsKey`.
    @MainActor
    public static func items(for model: NotesModel, library: NotesLibraryModel? = nil, windowIsKey: Bool) -> [Item] {
        let shown = library?.displayed(model) ?? model
        let onRecorder = shown === model
        let selected = library?.selection?.noteID
        return allCases.map { c in
            let on = windowIsKey
            switch c {
            case .newNote:
                return Item(command: c, title: NotesLibraryText.newNote, key: "n", modifiers: .command, enabled: on, checked: false)
            case .record:
                let title: String
                if onRecorder {
                    title = model.state.isActive ? "Stop Recording" : model.isBlank ? "Start Recording" : NotesLibraryText.continueRecording
                } else {
                    title = model.state.isActive ? "Continue Recording Here…" : NotesLibraryText.continueRecording
                }
                return Item(command: c, title: title, key: "r", modifiers: shiftCommand,
                            enabled: on && model.canToggle && (onRecorder || shown.document.deletedAt == nil), checked: false)
            case .pause:
                return Item(command: c, title: model.isPaused ? "Resume Recording" : "Pause Recording", key: "p", modifiers: shiftCommand,
                            enabled: on && (model.isPaused || model.state == .recording), checked: false)
            case .renameNote:
                return Item(command: c, title: "Rename Note", key: "", modifiers: [],
                            enabled: on && selected.map { library?.entry($0) != nil } == true, checked: false)
            case .deleteNote:
                return Item(command: c, title: "Delete Note", key: backspace, modifiers: .command,
                            enabled: on && library?.canTrash(selected) == true, checked: false)
            case .findNotes:
                return Item(command: c, title: "Search Notes", key: "f", modifiers: optionCommand, enabled: on && library != nil, checked: false)
            case .copyMarkdown:
                return Item(command: c, title: "Copy Markdown", key: "c", modifiers: shiftCommand, enabled: on && shown.canExport, checked: false)
            case .export:
                return Item(command: c, title: model.exportTitle, key: "s", modifiers: shiftCommand, enabled: on && shown.canExport, checked: false)
            case .toggleInspector:
                let showing = library?.showsInspector == true
                return Item(command: c, title: showing ? "Hide Transcript" : "Show Transcript", key: "t", modifiers: optionCommand,
                            enabled: on && library != nil, checked: false)
            case .showMarkdown:
                return Item(command: c, title: "Show Markdown", key: "m", modifiers: shiftCommand,
                            enabled: on && library != nil, checked: library?.showMarkdown == true)
            case .biggerText, .smallerText, .actualSize:
                let size = library?.textSize ?? shown.textSize
                let title = c == .biggerText ? "Bigger Text" : c == .smallerText ? "Smaller Text" : "Actual Size (100%)"
                return Item(command: c, title: title, key: c == .biggerText ? "+" : c == .smallerText ? "-" : "0", modifiers: .command,
                            enabled: on && (c == .biggerText ? size.canIncrease : c == .smallerText ? size.canDecrease : size.factor != 1), checked: false)
            case .readFormattedNote:
                return Item(command: c, title: "Read Formatted Note", key: "", modifiers: [], enabled: on && library != nil && library?.selection != .recentlyDeleted, checked: false)
            case .restoreOrganize:
                return Item(command: c, title: "Restore Notes Before Organize…", key: "", modifiers: [], enabled: on && shown.canRestore, checked: false)
            case .retranscribe:
                let can = library?.canRetranscribe(shown) == true
                return Item(command: c, title: NotesRetranscribeText.menuTitle, key: "", modifiers: [], enabled: on && can,
                            checked: false, hidden: !can)
            case .restoreTranscript:
                let can = library?.canRestoreTranscript(shown) == true
                return Item(command: c, title: NotesRetranscribeText.restore, key: "", modifiers: [], enabled: on && can,
                            checked: false, hidden: !can)
            }
        }
    }
}

extension NotesModel {
    /// Runs a menu command (the same actions as the toolbar's buttons). `library` is the window around the note.
    public func perform(_ command: NotesCommand, library: NotesLibraryModel? = nil) {
        let shown = library?.displayed(self) ?? self
        switch command {
        case .newNote: library?.onNew() ?? onNew()
        case .record:
            if shown === self { onRecordToggle() } else { library?.onContinue(shown.document.id) }
        case .pause: onPauseToggle()
        case .renameNote: if let id = library?.selection?.noteID { library?.beginRename(id) }
        case .deleteNote: if let id = library?.selection?.noteID, library?.canTrash(id) == true { library?.onTrash(id) }
        case .findNotes: library?.onFocusSearch()
        case .copyMarkdown: shown.onCopy()
        case .export: shown.onSave()
        case .toggleInspector: library.map { $0.setInspector(!$0.showsInspector) }
        case .showMarkdown: library.map { $0.setShowMarkdown(!$0.showMarkdown) }
        case .biggerText: (library?.textSize ?? shown.textSize).increase()
        case .smallerText: (library?.textSize ?? shown.textSize).decrease()
        case .actualSize: (library?.textSize ?? shown.textSize).reset()
        case .readFormattedNote: library?.readingNote = true
        case .restoreOrganize: shown.review()
        case .retranscribe: library?.onRetranscribe(shown.document.id, nil)
        case .restoreTranscript: library?.onRestoreTranscript(shown.document.id)
        }
    }
}
