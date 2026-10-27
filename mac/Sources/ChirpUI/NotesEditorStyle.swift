import AppKit
import ChirpCore

/// Live Markdown styling for the notes editor: `NotesMarkdown.styleRuns` mapped to AppKit attributes. Attributes only;
/// the characters (and so the markup) never change.
///
/// Live preview hides the syntax everywhere except the lines the caret is on (`raw`): heading marks and `**`/`_`
/// shrink to nothing, and list dashes and task boxes turn clear so the editor can draw a bullet or a check box in their
/// place (`NotesEditorDecorations`). View ▸ Show Markdown passes `hide: false` and every character shows.
@MainActor
enum NotesEditorStyle {
    static let bodySize: CGFloat = 15
    static let body = NSFont.systemFont(ofSize: bodySize)
    /// `[ ]` and `[x]` in a fixed-width face, so a toggle never shifts the text after it.
    static let box = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let gap = NSFont.systemFont(ofSize: 7)
    /// Hidden syntax: a face too small to take up space.
    static let hidden = NSFont.systemFont(ofSize: 0.01)
    static let indentStep: CGFloat = 22
    /// About 1.5× the body size from one baseline to the next.
    static let lineSpacing: CGFloat = 5

    static func headingFont(_ level: Int) -> NSFont {
        switch level {
        case 1: NSFont.systemFont(ofSize: 22, weight: .bold)
        case 2: NSFont.systemFont(ofSize: 19, weight: .semibold)
        default: NSFont.systemFont(ofSize: 16, weight: .semibold)
        }
    }

    static var baseParagraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = lineSpacing
        p.paragraphSpacing = 3
        return p
    }

    /// What new typing gets before the restyle catches up.
    static var typingAttributes: [NSAttributedString.Key: Any] {
        [.font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: baseParagraph]
    }

    private static var traitCache: [NSFont: [NSFontTraitMask.RawValue: NSFont]] = [:]

    private static func font(_ font: NSFont, adding trait: NSFontTraitMask) -> NSFont {
        if let cached = traitCache[font]?[trait.rawValue] { return cached }
        let converted = NSFontManager.shared.convert(font, toHaveTrait: trait)
        traitCache[font, default: [:]][trait.rawValue] = converted
        return converted
    }

    private static func width(_ s: String, _ font: NSFont) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }

    /// Restyles the paragraphs `range` touches (the whole text when nil). With `hide`, syntax outside `raw` (the caret's
    /// paragraphs; nil when the editor is not focused) is hidden.
    static func restyle(_ storage: NSTextStorage, range: NSRange? = nil, hide: Bool = false, raw: NSRange? = nil, scale: CGFloat = 1) {
        let ns = storage.string as NSString
        let target = range.map { ns.paragraphRange(for: NSRange(location: min($0.location, ns.length), length: max(0, min($0.length, ns.length - min($0.location, ns.length))))) }
            ?? NSRange(location: 0, length: ns.length)
        guard target.length > 0 else { return }
        storage.beginEditing()
        storage.setAttributes(typingAttributes, range: target)
        // A blank line between blocks is a half-height gap, not a full body line.
        var location = target.location
        while location < NSMaxRange(target) {
            let line = ns.lineRange(for: NSRange(location: location, length: 0))
            if line.length == 1, ns.character(at: line.location) == 10 { storage.addAttribute(.font, value: gap, range: line) }
            location = NSMaxRange(line)
        }
        let runs = NotesMarkdown.styleRuns(Substring(ns.substring(with: target)), base: target.location)
        for run in runs { apply(run, to: storage, ns: ns) }
        if hide {
            for run in runs where !isRaw(run.range, raw: raw, ns: ns) { conceal(run, in: storage, ns: ns) }
        }
        // Restyling first resets the affected paragraphs to base attributes; scaling therefore never compounds.
        // Only attributes change. Text, UTF-16 offsets and the undo stack remain native.
        if scale != 1 {
            storage.enumerateAttributes(in: target) { attributes, range, _ in
                if let font = attributes[.font] as? NSFont, font.pointSize > 0.02 {
                    storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toSize: font.pointSize * scale), range: range)
                }
                if let original = attributes[.paragraphStyle] as? NSParagraphStyle,
                   let paragraph = original.mutableCopy() as? NSMutableParagraphStyle {
                    paragraph.lineSpacing *= scale
                    paragraph.paragraphSpacing *= scale
                    paragraph.paragraphSpacingBefore *= scale
                    paragraph.headIndent *= scale
                    paragraph.firstLineHeadIndent *= scale
                    storage.addAttribute(.paragraphStyle, value: paragraph, range: range)
                }
                if let kern = attributes[.kern] as? CGFloat { storage.addAttribute(.kern, value: kern * scale, range: range) }
            }
        }
        storage.endEditing()
    }

    /// The run is on a line the caret is on (`raw` is the selection's paragraphs).
    static func isRaw(_ r: NSRange, raw: NSRange?, ns: NSString) -> Bool {
        guard let raw else { return false }
        let line = ns.lineRange(for: NSRange(location: min(r.location, ns.length), length: 0))
        return NSIntersectionRange(line, raw).length > 0 || (raw.length == 0 && raw.location == line.location)
    }

    /// Live preview: the syntax of one run disappears (heading marks and their space, emphasis delimiters), or turns
    /// clear where the editor draws its own mark (a list dash, a task box).
    private static func conceal(_ run: NotesStyleRun, in storage: NSTextStorage, ns: NSString) {
        var r = run.range
        guard r.length > 0, NSMaxRange(r) <= ns.length else { return }
        switch run.style {
        case .markupDelimiter:
            // `## ` loses its space too; `**`, `_` and the fallback header's `_` only themselves.
            if NSMaxRange(r) < ns.length, ns.character(at: NSMaxRange(r)) == 32, ns.character(at: r.location) == 35 { r.length += 1 }
            storage.addAttributes([.font: hidden, .foregroundColor: NSColor.clear], range: r)
        case .bulletMarker(let indent):
            let spaces = ns.substring(with: r).prefix { $0 == " " }.count
            let dash = NSRange(location: r.location + spaces, length: 2)
            let line = ns.substring(with: ns.lineRange(for: r))
            let rest = line.dropFirst(spaces + 2)
            let base = CGFloat(indent) * indentStep
            if NotesMarkdown.listPrefix(Substring(line))?.box != nil {
                // A task: the box sits where the bullet would, so `- ` goes entirely.
                storage.addAttributes([.font: hidden, .foregroundColor: NSColor.clear], range: dash)
                hang(ns.paragraphRange(for: r), at: base + width("[ ] ", box), in: storage)
            } else if rest.hasPrefix("**Decision:**") || rest.hasPrefix("**Question:**") {
                // A callout: `- ` becomes the room for its icon.
                storage.addAttributes([.foregroundColor: NSColor.clear,
                                       .kern: NotesEditorDecorations.calloutMark - width("- ", body)], range: NSRange(location: dash.location + 1, length: 1))
                storage.addAttribute(.foregroundColor, value: NSColor.clear, range: NSRange(location: dash.location, length: 1))
                hang(ns.paragraphRange(for: r), at: base + width("-", body) + NotesEditorDecorations.calloutMark, in: storage)
            } else {
                storage.addAttribute(.foregroundColor, value: NSColor.clear, range: NSRange(location: dash.location, length: 1))
            }
        case .taskBox:
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: r)
        default: break
        }
    }

    /// Wrapped lines of a list item start at `indent`.
    private static func hang(_ paragraph: NSRange, at indent: CGFloat, in storage: NSTextStorage) {
        let p = (storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
            ?? NSMutableParagraphStyle()
        p.headIndent = indent
        storage.addAttribute(.paragraphStyle, value: p, range: paragraph)
    }

    private static func apply(_ run: NotesStyleRun, to storage: NSTextStorage, ns: NSString) {
        let r = run.range
        guard r.length > 0, NSMaxRange(r) <= ns.length else { return }
        switch run.style {
        case .heading(let level):
            storage.addAttribute(.font, value: headingFont(level), range: r)
            let p = NSMutableParagraphStyle()
            p.lineSpacing = 3
            p.paragraphSpacingBefore = r.location == 0 ? 0 : (level == 1 ? 14 : level == 2 ? 12 : 6)
            p.paragraphSpacing = 4
            storage.addAttribute(.paragraphStyle, value: p, range: ns.paragraphRange(for: r))
        case .markupDelimiter:
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: r)
        case .bold, .italic:
            let trait: NSFontTraitMask = run.style == .bold ? .boldFontMask : .italicFontMask
            storage.enumerateAttribute(.font, in: r) { value, sub, _ in
                guard let f = value as? NSFont else { return }
                storage.addAttribute(.font, value: font(f, adding: trait), range: sub)
            }
        case .bulletMarker(let indent):
            storage.addAttribute(.foregroundColor, value: NotesInk.muted, range: r)
            let line = ns.substring(with: ns.lineRange(for: r))
            let spaces = line.prefix { $0 == " " }.count
            // The leading spaces are kerned to exactly `indent` steps, so nesting reads the same however it was typed.
            if spaces > 0 {
                let kern = CGFloat(indent) * indentStep / CGFloat(spaces) - width(" ", body)
                storage.addAttribute(.kern, value: kern, range: NSRange(location: r.location, length: spaces))
            }
            let task = NotesMarkdown.listPrefix(Substring(line))?.box != nil
            let p = NSMutableParagraphStyle()
            p.lineSpacing = lineSpacing
            p.paragraphSpacing = 3
            p.headIndent = CGFloat(indent) * indentStep + width(String(line.dropFirst(spaces).prefix(2)), body)
                + (task ? width("[ ] ", box) : 0)
            storage.addAttribute(.paragraphStyle, value: p, range: ns.paragraphRange(for: r))
        case .taskBox:
            storage.addAttributes([.font: box, .foregroundColor: NotesInk.muted], range: r)
        case .checkedTaskText:
            storage.addAttributes([.foregroundColor: NotesInk.muted,
                                   .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                   .strikethroughColor: NSColor.tertiaryLabelColor], range: r)
        case .decisionLabel:
            storage.addAttributes([.foregroundColor: NotesEditorDecorations.lily,
                                   .font: NSFont.systemFont(ofSize: bodySize, weight: .semibold)], range: r)
        case .questionLabel:
            storage.addAttributes([.foregroundColor: NotesEditorDecorations.moon,
                                   .font: NSFont.systemFont(ofSize: bodySize, weight: .semibold)], range: r)
        case .fallbackHeader:
            storage.addAttributes([.foregroundColor: NotesInk.muted, .font: font(body, adding: .italicFontMask)], range: r)
        }
    }
}

/// What the editor draws itself under live preview: a bullet in place of a list dash, a check box in place of `[ ]`,
/// and the Decision/Question callouts (a tinted block with its icon, like Android's).
@MainActor
enum NotesEditorDecorations {
    static let lily = named("ChirpNotesLily", ChirpColor.Pond.lily)
    static let moon = named("ChirpNotesMoon", ChirpColor.Pond.moon)
    static let moonFill = named("ChirpNotesMoonFill", ChirpColor.Pond.moonFill)

    /// A dynamic colour with a name of its own: text attributes compare colours, and two dynamic colours sharing a
    /// name would merge into one run (a Question label drawn in the Decision green).
    static func named(_ name: String, _ c: (light: ChirpColor.RGB, dark: ChirpColor.RGB)) -> NSColor {
        NSColor(name: name) { appearance in
            let v = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? c.dark : c.light
            return NSColor(srgbRed: v.r, green: v.g, blue: v.b, alpha: 1)
        }
    }

    /// The room a callout's icon takes in place of `- `.
    static let calloutMark: CGFloat = 24

    enum Kind: Equatable {
        case bullet(nested: Bool)
        case task(checked: Bool)
        case decision, question
    }

    struct Item: Equatable {
        var kind: Kind
        /// The character the mark replaces (the dash, or the `[ ]`).
        var mark: NSRange
        /// The whole line, for a callout's tint.
        var line: NSRange
        /// The mark is hidden (not on the caret's line): draw the replacement.
        var concealed: Bool
    }

    /// Every list line's mark. Callouts are listed even on the caret's line (their tint stays put).
    static func items(_ text: String, hide: Bool, raw: NSRange?) -> [Item] {
        let ns = text as NSString
        var out: [Item] = []
        var location = 0
        for line in text.utf16.split(separator: 10, omittingEmptySubsequences: false).map({ Substring($0) }) {
            let length = line.utf16.count
            defer { location += length + 1 }
            guard let list = NotesMarkdown.listPrefix(line) else { continue }
            let lineRange = NSRange(location: location, length: length)
            let concealed = hide && !NotesEditorStyle.isRaw(lineRange, raw: raw, ns: ns)
            let body = line.dropFirst(list.length)
            let dash = NSRange(location: location + list.spaces, length: 1)
            if let checked = list.box {
                out.append(Item(kind: .task(checked: checked), mark: NSRange(location: location + list.spaces + 2, length: 3), line: lineRange, concealed: concealed))
            } else if body.hasPrefix("**Decision:**") {
                out.append(Item(kind: .decision, mark: dash, line: lineRange, concealed: concealed))
            } else if body.hasPrefix("**Question:**") {
                out.append(Item(kind: .question, mark: dash, line: lineRange, concealed: concealed))
            } else if concealed {
                out.append(Item(kind: .bullet(nested: list.indent > 0), mark: dash, line: lineRange, concealed: true))
            }
        }
        return out
    }

    static func symbol(_ name: String, size: CGFloat, color: NSColor? = nil, colors: [NSColor] = [], weight: NSFont.Weight = .regular) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight).applying(.init(paletteColors: color.map { [$0] } ?? colors))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }
}
