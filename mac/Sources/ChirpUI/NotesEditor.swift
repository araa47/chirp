import AppKit
import ChirpCore
import SwiftUI

/// The Notes pane's editor: one native `NSTextView` (TextKit 2) over `document.text`, with live Markdown styling.
/// The model is the single source: user edits go out through `model.onUserEdit`, and AI changes come back as
/// `NotesTextChange`s replayed onto the text storage, each one undo group.
struct NotesEditor: NSViewRepresentable {
    let model: NotesModel
    var library: NotesLibraryModel?

    func makeCoordinator() -> NotesEditorCoordinator { NotesEditorCoordinator(model: model, library: library) }

    func makeNSView(context: Context) -> NSScrollView { context.coordinator.scrollView }

    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.update() }

    static func dismantleNSView(_ view: NSScrollView, coordinator: NotesEditorCoordinator) { coordinator.detach() }
}

/// What tests read off a configured editor: every flag that could persist, send or rewrite the notes.
struct NotesEditorProbe: Equatable {
    var isRichText, importsGraphics, allowsUndo, usesFindBar: Bool
    var quoteSubstitution, dashSubstitution, textReplacement, linkDetection, dataDetection, smartInsertDelete: Bool
    var continuousSpellChecking, spellingCorrection, textCompletion: Bool
    var writingToolsOff: Bool
    var pasteTypes: [NSPasteboard.PasteboardType]

    @MainActor init(_ v: NSTextView) {
        isRichText = v.isRichText
        importsGraphics = v.importsGraphics
        allowsUndo = v.allowsUndo
        usesFindBar = v.usesFindBar
        quoteSubstitution = v.isAutomaticQuoteSubstitutionEnabled
        dashSubstitution = v.isAutomaticDashSubstitutionEnabled
        textReplacement = v.isAutomaticTextReplacementEnabled
        linkDetection = v.isAutomaticLinkDetectionEnabled
        dataDetection = v.isAutomaticDataDetectionEnabled
        smartInsertDelete = v.smartInsertDeleteEnabled
        continuousSpellChecking = v.isContinuousSpellCheckingEnabled
        spellingCorrection = v.isAutomaticSpellingCorrectionEnabled
        textCompletion = v.isAutomaticTextCompletionEnabled
        if #available(macOS 15, *) { writingToolsOff = v.writingToolsBehavior == .none }
        else { writingToolsOff = true }
        pasteTypes = v.readablePasteboardTypes
    }
}

/// The text view: reading-width layout, the placeholder, the AI tail's tint, task-box clicks and the Markdown key
/// commands. Everything that edits goes through the normal `shouldChangeText`/`didChangeText` path.
final class NotesTextView: NSTextView {
    weak var coordinator: NotesEditorCoordinator?
    var textScale: CGFloat = 1
    /// The AI tail to tint, UTF-16; empty when the user owns everything.
    var tint = NSRange(location: 0, length: 0) { didSet { if tint != oldValue { needsDisplay = true } } }
    var placeholder = NotesStatus.placeholder() { didSet { if placeholder != oldValue { needsDisplay = true } } }
    /// Live preview: syntax hidden outside `raw` (the caret's paragraphs, while focused).
    var hidesMarkup = true { didSet { if hidesMarkup != oldValue { needsDisplay = true } } }
    var raw: NSRange? { didSet { if raw != oldValue { needsDisplay = true } } }
    /// The title page above the text (`NotesTitleHeader`): it scrolls with the notes.
    var header: NSHostingView<NotesTitleHeader>? {
        didSet {
            oldValue?.removeFromSuperview()
            if let header { addSubview(header) }
            layoutHeader()
        }
    }

    static let readingWidth: CGFloat = NotesViewMetrics.readingWidth
    static let minInset: CGFloat = 32
    static let bottomInset: CGFloat = 28

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutHeader()
    }

    /// The measure (about 680 pt, centred) and the title page above the first line.
    func layoutHeader() {
        let inset = max(Self.minInset, (frame.width - Self.readingWidth) / 2)
        var top = Self.bottomInset
        if let header {
            // Sized by hand, and only set when it changed: the header is not part of any constraint layout.
            let width = max(0, frame.width - 2 * inset)
            // SwiftUI's unconstrained fitting size misses wrapped titles and facts in the inspector split.
            if header.rootView.width != width { header.rootView.width = width }
            let height = ceil(header.fittingSize.height)
            let target = NSRect(x: inset, y: 0, width: width, height: height)
            if header.frame != target { header.frame = target }
            top = height
        }
        let size = NSSize(width: inset, height: top)
        if textContainerInset != size { textContainerInset = size }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawCallouts(in: rect)
        if let frame = tintFrame(), frame.intersects(rect) {
            // The AI tail, which Chirp may still rewrite: a faint moon wash with a moon rule.
            NotesEditorDecorations.moonFill.withAlphaComponent(0.09).setFill()
            NSBezierPath(roundedRect: frame, xRadius: 6, yRadius: 6).fill()
            NotesEditorDecorations.moon.withAlphaComponent(0.55).setFill()
            NSRect(x: frame.minX, y: frame.minY + 4, width: 2, height: frame.height - 8).fill()
        }
        drawMarks(in: rect)
    }

    // MARK: live preview marks

    private var decorationCache: (text: String, hide: Bool, raw: NSRange?, items: [NotesEditorDecorations.Item])?

    var decorations: [NotesEditorDecorations.Item] {
        if let c = decorationCache, c.hide == hidesMarkup, c.raw == raw, c.text == string { return c.items }
        let items = NotesEditorDecorations.items(string, hide: hidesMarkup, raw: raw)
        decorationCache = (string, hidesMarkup, raw, items)
        return items
    }

    /// The frame of `range`'s first line fragment segment, in view coordinates.
    func rect(of range: NSRange) -> NSRect? {
        guard let tlm = textLayoutManager, let tcm = tlm.textContentManager,
              let start = tcm.location(tcm.documentRange.location, offsetBy: range.location),
              let end = tcm.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return nil }
        var union = NSRect.null
        tlm.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            union = union.union(frame)
            return true
        }
        guard !union.isNull else { return nil }
        let origin = textContainerOrigin
        return union.offsetBy(dx: origin.x, dy: origin.y)
    }

    /// Decision and Question callouts: a tinted block behind the line, as on Android.
    private func drawCallouts(in dirty: NSRect) {
        guard let container = textContainer else { return }
        for item in decorations where item.kind == .decision || item.kind == .question {
            guard let line = rect(of: item.line), let mark = rect(of: item.mark) else { continue }
            let block = NSRect(x: mark.minX - 8, y: line.minY - 4, width: textContainerOrigin.x + container.size.width - mark.minX + 16,
                               height: line.height + 8)
            guard block.intersects(dirty) else { continue }
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let tint = item.kind == .decision ? NotesEditorDecorations.lily : NotesEditorDecorations.moonFill
            tint.withAlphaComponent(dark ? 0.16 : (item.kind == .decision ? 0.10 : 0.18)).setFill()
            NSBezierPath(roundedRect: block, xRadius: ChirpRadius.row, yRadius: ChirpRadius.row).fill()
        }
    }

    /// Bullets, check boxes and callout icons where live preview hid the dash or the box.
    private func drawMarks(in dirty: NSRect) {
        for item in decorations where item.concealed {
            guard let mark = rect(of: item.mark), mark.insetBy(dx: -20, dy: -4).intersects(dirty) else { continue }
            let image: NSImage?
            switch item.kind {
            case .bullet(let nested):
                let dot = nested ? "◦" : "•"
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17 * textScale, weight: .bold),
                                                            .foregroundColor: NSColor.secondaryLabelColor]
                let size = (dot as NSString).size(withAttributes: attrs)
                (dot as NSString).draw(at: NSPoint(x: mark.midX - size.width / 2 + 1, y: mark.midY - size.height / 2 - 0.5), withAttributes: attrs)
                continue
            case .task(let checked):
                image = checked
                    ? NotesEditorDecorations.symbol("checkmark.square.fill", size: 14 * textScale, colors: [.white, .chirpKoi], weight: .medium)
                    : NotesEditorDecorations.symbol("square", size: 14 * textScale, color: .secondaryLabelColor, weight: .regular)
            case .decision:
                image = NotesEditorDecorations.symbol("checkmark.circle.fill", size: 15 * textScale, colors: [.white, NotesEditorDecorations.lily])
            case .question:
                image = NotesEditorDecorations.symbol("questionmark.circle.fill", size: 15 * textScale, colors: [.white, NotesEditorDecorations.moon])
            }
            guard let image else { continue }
            let size = image.size
            let x = item.kind == .decision || item.kind == .question ? mark.minX : item.kind == .bullet(nested: false) || item.kind == .bullet(nested: true)
                ? mark.midX - size.width / 2 : mark.minX + (mark.width - size.width) / 2
            image.draw(in: NSRect(x: x, y: mark.midY - size.height / 2, width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    /// The tail's lines, full reading width, in view coordinates.
    func tintFrame() -> NSRect? {
        guard tint.length > 0, let tlm = textLayoutManager, let tcm = tlm.textContentManager,
              let start = tcm.location(tcm.documentRange.location, offsetBy: tint.location),
              let end = tcm.location(start, offsetBy: tint.length),
              let range = NSTextRange(location: start, end: end) else { return nil }
        var union = NSRect.null
        tlm.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
            union = union.union(frame)
            return true
        }
        guard !union.isNull, let container = textContainer else { return nil }
        let origin = textContainerOrigin
        return NSRect(x: origin.x - 12, y: union.minY + origin.y - 6,
                      width: container.size.width + 24, height: union.height + 12)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        let padding = textContainer?.lineFragmentPadding ?? 5
        let origin = NSPoint(x: textContainerOrigin.x + padding, y: textContainerOrigin.y)
        (placeholder as NSString).draw(at: origin, withAttributes: [.font: NSFont.systemFont(ofSize: NotesEditorStyle.bodySize * textScale),
                                                                    .foregroundColor: NSColor.placeholderTextColor])
    }

    private var accessibleTaskCache: (document: UUID?, text: String, tasks: [NotesTaskAccessibilityElement])?

    override func accessibilityChildren() -> [Any]? {
        if accessibleTaskCache?.text != string || accessibleTaskCache?.document != coordinator?.model.document.id {
            let tasks = NotesEditorDecorations.items(string, hide: false, raw: nil).compactMap { item -> NotesTaskAccessibilityElement? in
                guard case .task = item.kind else { return nil }
                return NotesTaskAccessibilityElement(editor: self, item: item)
            }
            accessibleTaskCache = (coordinator?.model.document.id, string, tasks)
        }
        return (super.accessibilityChildren() ?? []) + (accessibleTaskCache?.tasks ?? [])
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 1, event.modifierFlags.intersection([.shift, .command, .option]).isEmpty,
           let coordinator, coordinator.toggleTask(at: characterIndexForInsertion(at: point)) { return }
        super.mouseDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        defer { coordinator?.reportFocus() }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        defer { coordinator?.reportFocus(resigning: true) }
        return super.resignFirstResponder()
    }

    /// Paste is plain text with `\n` line endings (a CRLF paste would hide headings from the section and style rules).
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard let pasted = pboard.string(forType: .string) else { return super.readSelection(from: pboard, type: type) }
        let clean = pasted.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard clean != pasted else { return super.readSelection(from: pboard, type: type) }
        insertText(clean, replacementRange: selectedRange())
        return true
    }

    override func unmarkText() {
        super.unmarkText()
        coordinator?.markedTextEnded()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let coordinator else { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch (mods, event.charactersIgnoringModifiers?.lowercased()) {
        case (.command, "b"): coordinator.wrapSelection("**"); return true
        case (.command, "i"): coordinator.wrapSelection("_"); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    /// Edit ▸ Organize Notes (⌥⌘R), through the responder chain.
    @objc func reorganizeNotes(_ sender: Any?) { coordinator?.model.onReorganize() }

    /// Edit ▸ Edit Notes by Voice (⇧⌘E): starts a spoken edit, or ends the one listening.
    @objc func editNotesByVoice(_ sender: Any?) { coordinator?.model.onVoiceEdit() }

    /// Esc drops a spoken edit that is still listening.
    override func cancelOperation(_ sender: Any?) {
        if let model = coordinator?.model, model.voiceEdit.isListening { model.onVoiceEditCancel() } else { super.cancelOperation(sender) }
    }

    /// ⌘Z / ⇧⌘Z act on the notes' own undo stack (the window's would be empty).
    @objc func undo(_ sender: Any?) { coordinator?.undo.undo() }
    @objc func redo(_ sender: Any?) { coordinator?.undo.redo() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        guard let undo = coordinator?.undo else { return super.validateUserInterfaceItem(item) }
        switch item.action {
        case #selector(reorganizeNotes(_:)):
            return coordinator?.model.canReorganize ?? false
        case #selector(editNotesByVoice(_:)):
            return coordinator?.model.canVoiceEdit ?? false
        case #selector(undo(_:)):
            (item as? NSMenuItem)?.title = undo.undoMenuItemTitle
            return undo.canUndo
        case #selector(redo(_:)):
            (item as? NSMenuItem)?.title = undo.redoMenuItemTitle
            return undo.canRedo
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}

/// Keeps the text view and `NotesModel` in step (see the type comment on `NotesEditor`), restyles the paragraphs
/// each edit touched (typing and paste arrive through `textDidChange`, undo and redo through the undo manager),
/// keeps the caret and scroll position across AI changes, and implements the editing affordances.
@MainActor
final class NotesEditorCoordinator: NSObject, NSTextViewDelegate {
    static let updateAction = "Update Notes"
    static let reorganizeAction = "Organize Notes"
    static let editAction = "Edit by Voice"
    static let toggleAction = "Toggle Task"
    static let renameAction = "Rename Speaker"
    static let restoreAction = "Restore Notes"
    static let rebuildAction = "Rebuild Notes"

    let model: NotesModel
    let library: NotesLibraryModel?
    let scrollView: NSScrollView
    let textView: NotesTextView
    let undo = UndoManager()
    /// The title page's host (nil for an editor without a library window).
    private var header: NSHostingView<NotesTitleHeader>?
    /// Whether the editor has keyboard focus; tests replace it (there is no window offscreen).
    var isFocused: () -> Bool
    private(set) var isApplyingModelChange = false
    private var pendingEdit: (range: NSRange, string: String)?
    private var pendingKind: NotesTextChange.Kind = .user
    private var reporting = false
    private var needsDrain = false
    private var lastFocusRequest: Int
    private var lastFocus: (inTail: Bool, composing: Bool)?
    /// AI changes that arrived while an input method was composing, replayed once it ends (oldest first).
    private var deferred: [NotesTextChange] = []
    /// The model text the storage last matched, marked text aside: what `deferred` changes and an uncommitted
    /// composition are both relative to.
    private var syncedText = ""

    init(model: NotesModel, library: NotesLibraryModel? = nil) {
        self.model = model
        self.library = library
        scrollView = NSScrollView()
        let textView = NotesTextView(usingTextLayoutManager: true)
        self.textView = textView
        lastFocusRequest = model.focusRequest
        isFocused = { [weak textView] in textView?.window?.firstResponder === textView }
        super.init()
        Self.configure(textView)
        textView.setAccessibilityLabel("Notes editor")
        textView.setAccessibilityHelp("Edit Markdown with native text selection. Read Formatted Note in the View menu reads without syntax. Tasks are also available as checkboxes.")
        textView.coordinator = self
        textView.delegate = self
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        // Sized by the clip view (autoresizing): a preset width would be added to the clip view's own.
        textView.frame = NSRect(origin: .zero, size: scrollView.contentSize)
        if let library {
            let header = NSHostingView(rootView: NotesTitleHeader(model: model, library: library))
            header.safeAreaRegions = []
            self.header = header
            textView.header = header
        }
        textView.hidesMarkup = !(library?.showMarkdown ?? false)
        textView.textScale = (library?.textSize ?? model.textSize).factor
        load()
        model.toggleAccessibleTask = { [weak self] index in self?.toggleTask(at: index) ?? false }
        model.editorOwner = ObjectIdentifier(self)
        model.onPendingChanges = { [weak self] in self?.pendingChangesArrived() }
        model.undoReorganize = { [weak self] in self?.undoReorganize() }
        model.undoEdit = { [weak self] in self?.undoEdit() }
        model.editorSelection = { [weak self] in self?.textView.selectedRange() }
        // NSTextView's undo and redo change the storage without `shouldChangeText` or `textDidChange`, so they are
        // reported from here (menu, ⌘Z, the chip's Undo alike).
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            NotificationCenter.default.addObserver(self, selector: #selector(undoneOrRedone), name: name, object: undo)
        }
    }

    @objc private func undoneOrRedone(_ notification: Notification) {
        MainActor.assumeIsolated { reportEdit() }
    }

    /// Every flag that matters for privacy and predictability (asserted by a test through `NotesEditorProbe`).
    static func configure(_ v: NSTextView) {
        v.isRichText = false
        v.importsGraphics = false
        v.allowsImageEditing = false
        v.allowsUndo = true
        v.usesFindBar = true
        v.isIncrementalSearchingEnabled = true
        v.isAutomaticQuoteSubstitutionEnabled = false
        v.isAutomaticDashSubstitutionEnabled = false
        v.isAutomaticTextReplacementEnabled = false
        v.isAutomaticLinkDetectionEnabled = false
        v.isAutomaticDataDetectionEnabled = false
        v.smartInsertDeleteEnabled = false
        v.isContinuousSpellCheckingEnabled = true
        v.isAutomaticSpellingCorrectionEnabled = false
        v.isGrammarCheckingEnabled = false
        v.isAutomaticTextCompletionEnabled = false
        v.inlinePredictionType = .no
        if #available(macOS 15, *) { v.writingToolsBehavior = .none }
        v.usesInspectorBar = false
        v.usesRuler = false
        v.drawsBackground = false
        v.isEditable = true
        v.isSelectable = true
        v.typingAttributes = NotesEditorStyle.typingAttributes
        v.textContainer?.lineFragmentPadding = 0
    }

    /// The editor goes away (Preview, another tab): nothing more is queued for it. Switching Notes ↔ Split builds the
    /// new editor before this one is dismantled, so it only lets go of what it still owns.
    func detach() {
        guard model.editorOwner == ObjectIdentifier(self) else { return }
        model.toggleAccessibleTask = { _ in false }
        model.editorOwner = nil
        model.onPendingChanges = nil
        model.undoReorganize = {}
        model.undoEdit = {}
        model.editorSelection = { nil }
        model.onEditorFocus(false, false)
    }

    /// Sets the storage from the model (at creation, after New, after a resync); clears undo.
    func load() {
        isApplyingModelChange = true
        textView.string = model.document.text
        restyle(nil)
        isApplyingModelChange = false
        undo.removeAllActions()
        _ = model.takePendingChanges()
        deferred.removeAll()
        syncedText = model.document.text
        updateTint()
    }

    /// SwiftUI's update: drain anything queued, catch a replaced document (New), follow a focus request.
    func update() {
        drain()
        if !textView.hasMarkedText(), textView.string != model.document.text {
            if !(model.document.text.isEmpty && model.document.version == 0) {
                chirpLog.info("notes editor resync storage=\(self.textView.string.utf16.count, privacy: .public) model=\(self.model.document.text.utf16.count, privacy: .public)")
            }
            load()
        }
        updateTint()
        let scale = (library?.textSize ?? model.textSize).factor
        if textView.textScale != scale, !textView.hasMarkedText() {
            let selection = textView.selectedRanges
            let scroll = scrollView.contentView.bounds.origin
            textView.textScale = scale
            undo.disableUndoRegistration()
            restyle(nil)
            textView.typingAttributes = [.font: NSFont.systemFont(ofSize: NotesEditorStyle.bodySize * scale),
                                         .foregroundColor: NSColor.labelColor]
            undo.enableUndoRegistration()
            textView.selectedRanges = selection
            textView.layoutHeader()
            scrollView.contentView.scroll(to: scroll)
            textView.needsDisplay = true
        }
        let hides = !(library?.showMarkdown ?? false)
        if hides != textView.hidesMarkup {
            textView.hidesMarkup = hides
            restyle(nil)
        }
        textView.placeholder = NotesStatus.placeholder(key: model.notesKey)
        if model.focusRequest != lastFocusRequest {
            lastFocusRequest = model.focusRequest
            textView.window?.makeFirstResponder(textView)
        }
    }

    // MARK: user → model

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        if !isApplyingModelChange, let replacementString { pendingEdit = (range, replacementString) }
        return true
    }

    func textDidChange(_ notification: Notification) {
        guard !isApplyingModelChange else { return }
        reportEdit()
    }

    /// Composition committed or cancelled: report what it left.
    func markedTextEnded() {
        guard !isApplyingModelChange else { return }
        reportEdit()
        reportFocus()
    }

    /// Reports the storage's difference from the model as one user edit. While IME is composing nothing is
    /// reported; the committed text goes out once composition ends.
    private func reportEdit() {
        defer { pendingEdit = nil; pendingKind = .user }
        guard !textView.hasMarkedText() else { reportFocus(); return }
        if !deferred.isEmpty { replayDeferred() }
        let old = model.document.text, current = textView.string
        guard old != current else { return }
        var edit: (range: NSRange, string: String)
        if let p = pendingEdit, NSMaxRange(p.range) <= old.utf16.count,
           (old as NSString).replacingCharacters(in: p.range, with: p.string) == current {
            edit = p
        } else if let d = NotesDocument.diff(old, current, kind: .user) {
            edit = (d.range, d.replacement)
        } else { return }
        reporting = true
        model.onUserEdit(edit.range, edit.string, pendingKind)
        reporting = false
        syncedText = model.document.text
        restyle(NSRange(location: edit.range.location, length: edit.string.utf16.count))
        if needsDrain { drain() }
        updateTint()
        reportFocus()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        reportFocus()
        updateRaw()
    }

    // MARK: live preview

    /// The caret's paragraphs show their Markdown; everything else hides it (unless Show Markdown is on).
    func updateRaw(focused: Bool? = nil) {
        guard !textView.hasMarkedText() else { return }
        let ns = textView.string as NSString
        let selection = textView.selectedRange()
        let next: NSRange? = (focused ?? isFocused()) && selection.location <= ns.length ? ns.lineRange(for: selection) : nil
        let old = textView.raw
        guard next != old else { return }
        textView.raw = next
        guard textView.hidesMarkup else { return }
        for range in [old, next].compactMap({ $0 }) where NSMaxRange(range) <= ns.length { restyle(range) }
    }

    /// Restyles the paragraphs `range` touches (all of them when nil), hiding syntax off the caret's lines.
    func restyle(_ range: NSRange?) {
        guard let storage = textView.textStorage else { return }
        NotesEditorStyle.restyle(storage, range: range, hide: textView.hidesMarkup, raw: textView.raw, scale: textView.textScale)
    }

    /// Tells the recorder whether an append would land under the caret: focus with the selection touching the tail,
    /// or IME composing.
    func reportFocus(resigning: Bool = false) {
        let focused = !resigning && isFocused()
        if resigning || focused != (textView.raw != nil) { updateRaw(focused: focused) }
        let document = model.document
        // Touching the tail as an edit would claim it; the end of the user's own last line does not.
        let inTail = focused && textView.selectedRanges.contains {
            document.touchesTail($0.rangeValue) || $0.rangeValue.location > document.tailStart
        }
        if model.editorFocused != focused {
            // Not during a SwiftUI update: this can run while the editor replays a change from `update()`.
            DispatchQueue.main.async { [model] in model.editorFocused = focused }
        }
        let state = (inTail, textView.hasMarkedText())
        guard lastFocus.map({ $0 != state }) ?? true else { return }
        lastFocus = state
        model.onEditorFocus(state.0, state.1)
    }

    // MARK: model → editor

    private func pendingChangesArrived() {
        // Never edit the storage from inside our own report of a user edit; drain right after it returns.
        if reporting { needsDrain = true; return }
        drain()
    }

    func drain() {
        needsDrain = false
        let changes = model.takePendingChanges()
        if textView.hasMarkedText() {
            // Replaying now would make NSTextView drop the composition; it goes in once the text is committed.
            deferred += changes
            return
        }
        if !deferred.isEmpty {
            deferred += changes
            reportEdit()
            return
        }
        guard !changes.isEmpty else { return }
        let pinned = isPinnedToBottom
        applyAll(changes)
        syncedText = model.document.text
        if !textView.hasMarkedText(), textView.string != model.document.text {
            chirpLog.info("notes editor resync storage=\(self.textView.string.utf16.count, privacy: .public) model=\(self.model.document.text.utf16.count, privacy: .public)")
            load()
            return
        }
        updateTint()
        if pinned, changes.contains(where: { $0.kind == .append }) { textView.scrollToEndOfDocument(nil) }
    }

    /// Composition ended: replays the AI changes that waited for it around the text it committed (relative to
    /// `syncedText`), so `reportEdit` then reports just the committed text.
    private func replayDeferred() {
        let changes = deferred
        deferred.removeAll()
        let pinned = isPinnedToBottom
        guard let user = NotesDocument.diff(syncedText, textView.string, kind: .user) else {
            applyAll(changes)
            syncedText = model.document.text
            return
        }
        // The committed text replaced `userOld` units at `userStart` (in the text the changes are relative to).
        var userStart = user.range.location
        let userOld = user.range.length, userNew = user.replacement.utf16.count
        var mappedChanges: [NotesTextChange] = []
        for change in changes {
            var mapped = change
            if change.range.location >= userStart {
                // At or after the committed text: it goes after it (an append at the end follows what was typed).
                mapped.range.location += change.range.location >= userStart + userOld
                    ? userNew - userOld : userStart + userNew - change.range.location
            } else {
                // Before it: the committed text moves instead.
                userStart += change.replacement.utf16.count - change.range.length
            }
            mappedChanges.append(mapped)
        }
        applyAll(mappedChanges)
        syncedText = model.document.text
        updateTint()
        if pinned, changes.contains(where: { $0.kind == .append }) { textView.scrollToEndOfDocument(nil) }
    }

    /// Replays changes in order; a run of Organize's in-place replacements (or of one speaker rename's) is one undo
    /// group.
    private func applyAll(_ changes: [NotesTextChange]) {
        var i = 0
        while i < changes.count {
            if let run = changes[i].run { applyStep(changes[i], run: run); i += 1; continue }
            let kind = changes[i].kind
            guard kind == .organize || kind == .rename else { apply(changes[i]); i += 1; continue }
            textView.breakUndoCoalescing()
            undo.beginUndoGrouping()
            while i < changes.count, changes[i].kind == kind { apply(changes[i], grouped: true); i += 1 }
            undo.setActionName(kind == .rename ? Self.renameAction : Self.reorganizeAction)
            undo.endUndoGrouping()
        }
    }

    /// The whole-document Organize run whose steps are being applied: its number and the text after its last step.
    private var organizeRun: (run: Int, after: String)?

    /// A step of a whole-document Organize. The run's first step registers one undo action that puts back the text
    /// from before the run; every step is applied without undo registration, so one ⌘Z (or the chip's Undo) undoes
    /// the whole run, as long as nothing else was done in between.
    private func applyStep(_ change: NotesTextChange, run: Int) {
        let continuing = organizeRun?.run == run && organizeRun?.after == textView.string && undo.undoActionName == Self.reorganizeAction
        if !continuing {
            let before = textView.string
            textView.breakUndoCoalescing()
            undo.beginUndoGrouping()
            undo.registerUndo(withTarget: self) { $0.restore(before) }
            undo.setActionName(Self.reorganizeAction)
            undo.endUndoGrouping()
        }
        undo.disableUndoRegistration()
        apply(change, grouped: true)
        undo.enableUndoRegistration()
        organizeRun = (run, textView.string)
    }

    /// Undo (or redo) of a whole Organize run: the storage goes back to `text`, reported like any undo.
    private func restore(_ text: String) {
        let current = textView.string
        undo.registerUndo(withTarget: self) { $0.restore(current) }
        undo.setActionName(Self.reorganizeAction)
        organizeRun = nil
        guard let storage = textView.textStorage, let d = NotesDocument.diff(current, text, kind: .user) else { return }
        storage.replaceCharacters(in: d.range, with: d.replacement)
        restyle(NSRange(location: d.range.location, length: d.replacement.utf16.count))
        textView.setSelectedRange(NSRange(location: min(d.range.location, storage.length), length: 0))
    }

    /// One AI change as one undo group (unless `grouped` in an open one), with the caret kept where the user left it.
    func apply(_ change: NotesTextChange, grouped: Bool = false) {
        guard let storage = textView.textStorage, NSMaxRange(change.range) <= storage.length else { return }
        let selection = textView.selectedRanges.map(\.rangeValue)
        let reorganize = change.kind == .reorganize
        let caret = reorganize ? caretLine(selection.first ?? NSRange(), scope: change.range) : nil
        let anchor = reorganize ? scrollAnchor() : nil
        isApplyingModelChange = true
        if !grouped {
            textView.breakUndoCoalescing()
            undo.beginUndoGrouping()
        }
        if textView.shouldChangeText(in: change.range, replacementString: change.replacement) {
            storage.replaceCharacters(in: change.range, with: change.replacement)
            textView.didChangeText()
        }
        if !grouped {
            undo.setActionName(change.kind == .edit ? Self.editAction : change.kind == .restore ? Self.restoreAction
                : change.kind == .rebuild ? Self.rebuildAction : reorganize ? Self.reorganizeAction : Self.updateAction)
            undo.endUndoGrouping()
        }
        // Only the paragraphs it replaced: a reorganize late in a long document leaves the rest alone.
        restyle(NSRange(location: change.range.location, length: change.replacement.utf16.count))
        isApplyingModelChange = false
        if reorganize, let caret {
            textView.setSelectedRange(NSRange(location: min(mapCaret(caret, change: change), storage.length), length: 0))
        } else {
            // Selections before the change (for a reorganize: before its scope) stay exactly as they were.
            let mapped = selection.map { Self.map($0, through: change) }
            textView.selectedRanges = mapped.map { NSValue(range: $0) }
        }
        if let anchor { restoreScroll(anchor, change: change) }
    }

    /// A selection across a suffix change: before it, unchanged; after it, shifted; inside it, clamped.
    static func map(_ r: NSRange, through change: NotesTextChange) -> NSRange {
        let delta = change.replacement.utf16.count - change.range.length
        func point(_ p: Int) -> Int {
            if p <= change.range.location { return p }
            if p >= NSMaxRange(change.range) { return p + delta }
            return min(p, change.range.location + change.replacement.utf16.count)
        }
        let start = point(r.location), end = point(NSMaxRange(r))
        return NSRange(location: start, length: max(0, end - start))
    }

    private struct CaretLine { let location: Int; let text: String; let column: Int }

    private func caretLine(_ selection: NSRange, scope: NSRange) -> CaretLine? {
        let ns = textView.string as NSString
        guard selection.location >= scope.location, selection.location <= ns.length else { return nil }
        let line = ns.lineRange(for: NSRange(location: selection.location, length: 0))
        let text = ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
        return CaretLine(location: selection.location, text: text, column: selection.location - line.location)
    }

    /// The caret after a reorganize: on the first line of the new scope with the same text, at the same column; at
    /// the start of the scope when no line matches.
    private func mapCaret(_ caret: CaretLine, change: NotesTextChange) -> Int {
        let ns = textView.string as NSString
        let scope = NSRange(location: change.range.location, length: change.replacement.utf16.count)
        guard let line = Self.firstLine(in: ns, scope: scope, matching: caret.text) else { return scope.location }
        let content = ns.substring(with: line).trimmingCharacters(in: .newlines) as NSString
        return line.location + min(caret.column, content.length)
    }

    static func firstLine(in ns: NSString, scope: NSRange, matching text: String) -> NSRange? {
        guard !text.isEmpty else { return nil }
        var location = scope.location
        while location < NSMaxRange(scope) {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            if ns.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines) == text { return line }
            location = NSMaxRange(line)
        }
        return nil
    }

    // MARK: scrolling

    private var isPinnedToBottom: Bool {
        let clip = scrollView.contentView
        return clip.bounds.maxY >= textView.frame.height - 40
    }

    private struct ScrollAnchor { let text: String; let offset: CGFloat; let y: CGFloat }

    private func scrollAnchor() -> ScrollAnchor? {
        let visible = scrollView.contentView.bounds
        let index = textView.characterIndexForInsertion(at: NSPoint(x: textView.textContainerOrigin.x + 1, y: visible.minY + 1))
        let ns = textView.string as NSString
        guard index < ns.length, let rect = lineRect(index) else { return ScrollAnchor(text: "", offset: 0, y: visible.minY) }
        let text = ns.substring(with: ns.lineRange(for: NSRange(location: index, length: 0))).trimmingCharacters(in: .whitespacesAndNewlines)
        return ScrollAnchor(text: text, offset: rect.minY - visible.minY, y: visible.minY)
    }

    private func restoreScroll(_ anchor: ScrollAnchor, change: NotesTextChange) {
        let ns = textView.string as NSString
        var y = anchor.y
        if let line = Self.firstLine(in: ns, scope: NSRange(location: 0, length: ns.length), matching: anchor.text),
           let rect = lineRect(line.location) {
            y = rect.minY - anchor.offset
        }
        let maxY = max(0, textView.frame.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func lineRect(_ index: Int) -> NSRect? {
        guard let tlm = textView.textLayoutManager, let tcm = tlm.textContentManager,
              let location = tcm.location(tcm.documentRange.location, offsetBy: index),
              let fragment = tlm.textLayoutFragment(for: location) else { return nil }
        return fragment.layoutFragmentFrame.offsetBy(dx: 0, dy: textView.textContainerOrigin.y)
    }

    // MARK: tint

    /// The AI tail without its leading blank lines.
    func updateTint() {
        let ns = model.document.text as NSString
        var start = min(model.document.tailStart, ns.length)
        while start < ns.length, ns.character(at: start) == 10 { start += 1 }
        let tint = textView.string == model.document.text ? NSRange(location: start, length: ns.length - start) : NSRange()
        textView.tint = tint
        showTipIfNeeded()
    }

    private var tip: NSPopover?

    /// The first time AI text shows in the tail: a one-time popover on the tint that says it may still be rewritten and
    /// that editing it makes it the user's. Remembered as a boolean only.
    private func showTipIfNeeded() {
        guard !model.tipSeen, textView.window != nil, let frame = textView.tintFrame() else { return }
        model.tipSeen = true
        model.onTipSeen()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: NotesTipView())
        popover.show(relativeTo: NSRect(x: frame.minX, y: frame.minY, width: 24, height: min(frame.height, 28)), of: textView, preferredEdge: .maxY)
        tip = popover
    }

    // MARK: affordances

    /// Clicking `[ ]`/`[x]` toggles it: one undo group, "Toggle Task". True when `index` was on a box.
    func toggleTask(at index: Int) -> Bool {
        guard let toggle = NotesMarkdown.taskToggle(textView.string, at: index) else { return false }
        edit(toggle.range, toggle.replacement, action: Self.toggleAction, kind: .toggleTask)
        return true
    }

    /// One user edit through the normal path (reported like typing), as its own undo group.
    private func edit(_ range: NSRange, _ replacement: String, action: String? = nil, kind: NotesTextChange.Kind = .user,
                      select: NSRange? = nil) {
        guard let storage = textView.textStorage else { return }
        textView.breakUndoCoalescing()
        undo.beginUndoGrouping()
        pendingKind = kind
        if textView.shouldChangeText(in: range, replacementString: replacement) {
            storage.replaceCharacters(in: range, with: replacement)
            textView.didChangeText()
        }
        if let action { undo.setActionName(action) }
        undo.endUndoGrouping()
        if let select { textView.setSelectedRange(select) }
    }

    /// ⌘B / ⌘I: wraps the selection in `**` / `_` (or puts the caret between a new pair).
    func wrapSelection(_ delimiter: String) {
        let r = textView.selectedRange()
        let selected = (textView.string as NSString).substring(with: r)
        let d = delimiter.utf16.count
        edit(r, delimiter + selected + delimiter, select: NSRange(location: r.location + d, length: r.length))
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): continueList()
        case #selector(NSResponder.insertTab(_:)): indent(by: 1)
        case #selector(NSResponder.insertBacktab(_:)): indent(by: -1)
        default: false
        }
    }

    private func currentLine() -> (range: NSRange, text: Substring)? {
        let r = textView.selectedRange()
        let ns = textView.string as NSString
        guard r.location <= ns.length else { return nil }
        let line = ns.lineRange(for: NSRange(location: r.location, length: 0))
        return (line, Substring(ns.substring(with: line).trimmingCharacters(in: .newlines)))
    }

    /// Return on a list line continues it (`- `, `  - `, `- [ ] `); on an empty item it removes the marker.
    func continueList() -> Bool {
        guard !textView.hasMarkedText(), let (line, text) = currentLine(), let list = NotesMarkdown.listPrefix(text) else { return false }
        let caret = textView.selectedRange()
        guard caret.location >= line.location + list.length || text.utf16.count <= list.length else { return false }
        if text.utf16.count <= list.length, caret.length == 0 {
            edit(NSRange(location: line.location, length: text.utf16.count), "", select: NSRange(location: line.location, length: 0))
            return true
        }
        let marker = String(text.prefix(list.spaces + 2)) + (list.box == nil ? "" : "[ ] ")
        let insert = "\n" + marker
        edit(caret, insert, select: NSRange(location: caret.location + insert.utf16.count, length: 0))
        return true
    }

    /// Tab / Shift-Tab on a list line: two spaces more or fewer at its start (at most `NotesMarkdown.maxIndent`).
    func indent(by step: Int) -> Bool {
        guard let (line, text) = currentLine(), let list = NotesMarkdown.listPrefix(text) else { return false }
        let caret = textView.selectedRange()
        if step > 0 {
            guard list.spaces / 2 < NotesMarkdown.maxIndent else { return true }
            edit(NSRange(location: line.location, length: 0), "  ", select: NSRange(location: caret.location + 2, length: caret.length))
        } else {
            guard list.spaces >= 2 else { return true }
            edit(NSRange(location: line.location, length: 2), "",
                 select: NSRange(location: max(line.location, caret.location - 2), length: caret.length))
        }
        return true
    }

    /// The chip's Undo: only while the reorganize is still the top undo group.
    func undoReorganize() {
        guard undo.canUndo, undo.undoActionName == Self.reorganizeAction else { return }
        undo.undo()
    }

    /// The "Edited · Undo" chip: undoes the voice edit if it is still the top undo group.
    func undoEdit() {
        guard undo.canUndo, undo.undoActionName == Self.editAction else { return }
        undo.undo()
    }

    /// Notes keep their own undo stack, so ⌘Z never reaches into another control's edits.
    func undoManager(for view: NSTextView) -> UndoManager? { undo }
}

/// Real AX checkboxes over the drawn task marks. The NSTextView keeps its native editable value and ranges.
/// An old AX element refuses to act after its line changes, rather than editing a different task at a stale offset.
final class NotesTaskAccessibilityElement: NSAccessibilityElement {
    /// NSAccessibilityElement is explicitly non-Sendable in the SDK. Keep its document access in an isolated
    /// Swift object, and capture only that Sendable reference in the AppKit callback's main-actor bridge.
    private let state: NotesTaskAccessibilityState

    @MainActor init(editor: NotesTextView, item: NotesEditorDecorations.Item) {
        state = NotesTaskAccessibilityState(editor: editor, item: item)
        super.init()
        state.element = self
        setAccessibilityParent(editor)
        setAccessibilityElement(true)
        setAccessibilityEnabled(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(state.label)
    }
    override func accessibilityValue() -> Any? {
        let value: NSNumber? = MainActor.assumeIsolated { [state] in state.value }
        return value
    }
    override func accessibilityFrame() -> NSRect {
        MainActor.assumeIsolated { [state] in state.frame }
    }
    override func accessibilityPerformPress() -> Bool {
        MainActor.assumeIsolated { [state] in state.press() }
    }
}

@MainActor private final class NotesTaskAccessibilityState {
    weak var editor: NotesTextView?
    weak var element: NotesTaskAccessibilityElement?
    let item: NotesEditorDecorations.Item
    let originalLine: String
    let document: UUID?
    let label: String

    init(editor: NotesTextView, item: NotesEditorDecorations.Item) {
        self.editor = editor
        self.item = item
        document = editor.coordinator?.model.document.id
        originalLine = (editor.string as NSString).substring(with: item.line)
        label = NotesLibraryText.plain(String(originalLine.dropFirst(NotesMarkdown.listPrefix(Substring(originalLine))?.length ?? 0)))
    }
    private var valid: Bool {
        guard let editor, editor.coordinator?.model.document.id == document, NSMaxRange(item.line) <= editor.string.utf16.count else { return false }
        let line = (editor.string as NSString).substring(with: item.line)
        func unchecked(_ text: String) -> String {
            text.replacingOccurrences(of: "[x]", with: "[ ]").replacingOccurrences(of: "[X]", with: "[ ]")
        }
        return unchecked(line) == unchecked(originalLine)
    }
    var value: NSNumber? {
        guard valid, let editor else { return nil }
        return NSNumber(value: (editor.string as NSString).substring(with: item.mark).lowercased() == "[x]")
    }
    var frame: NSRect {
        guard valid, let editor, let window = editor.window, let rect = editor.rect(of: item.mark) else { return .zero }
        return window.convertToScreen(editor.convert(rect, to: nil))
    }
    func press() -> Bool {
        guard valid, let editor, let coordinator = editor.coordinator else { return false }
        let selection = editor.selectedRanges
        let result = coordinator.toggleTask(at: item.mark.location + 1)
        editor.selectedRanges = selection
        if result, let element { NSAccessibility.post(element: element, notification: .valueChanged) }
        return result
    }
}
