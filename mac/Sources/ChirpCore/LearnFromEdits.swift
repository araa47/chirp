import Foundation

// Learn from my edits (#220): after Chirp inserts a dictation it watches that same field for a while; when the user
// fixes a misheard word or restyles the text, the edit becomes a correction. A correction seen twice (or taught once
// from History) becomes active: the user's own terms go to the server's known terms with every `start`, and per-app
// style preferences shape that app's clean-up. Pure parts here; the store and watcher follow. Nothing is logged.

// MARK: what can be learned

/// A per-app style preference. The server maps each id to its own fixed prompt line; no free-form text is sent.
public enum LearnedStyle: String, Codable, CaseIterable, Sendable {
    case lowercaseStart = "lowercase_start"
    case noFinalPeriod = "no_final_period"

    public var title: String {
        switch self {
        case .lowercaseStart: "Start in lowercase"
        case .noFinalPeriod: "No period at the end"
        }
    }
}

/// One correction found in one edit.
public enum LearnedCorrection: Codable, Sendable, Equatable, Hashable {
    /// A misheard phrase the user retyped as their own term ("cooper netties" → "Kubernetes").
    case term(heard: String, term: String)
    case style(LearnedStyle)

    public var title: String {
        switch self {
        case .term(_, let term): term
        case .style(let style): style.title
        }
    }
}

// MARK: the edited span

/// Where the inserted text went, as the user left it.
public enum EditRegion {
    /// The inserted span (`range`, UTF-16 in `before`) as it reads in `after`; nil when the field also changed outside
    /// it (the edit is unrelated, or mixed with one that is) or the only change is more text typed at its edges.
    public static func edited(before: String, after: String, range: NSRange) -> String? {
        let b = before as NSString, a = after as NSString
        guard range.location >= 0, NSMaxRange(range) <= b.length else { return nil }
        if before == after { return b.substring(with: range) }
        let shorter = min(b.length, a.length)
        var prefix = 0
        while prefix < shorter, b.character(at: prefix) == a.character(at: prefix) { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix, b.character(at: b.length - 1 - suffix) == a.character(at: a.length - 1 - suffix) { suffix += 1 }
        let start = prefix, endBefore = b.length - suffix
        guard start >= range.location, endBefore <= NSMaxRange(range) else { return nil }
        // Nothing removed, only typed at the very start or end: the user went on writing, it is not an edit.
        if endBefore == start, start == range.location || start == NSMaxRange(range) { return nil }
        let tail = b.length - NSMaxRange(range)
        let length = a.length - range.location - tail
        guard length >= 0 else { return nil }
        return a.substring(with: NSRange(location: range.location, length: length))
    }

    /// The text around the inserted span is unchanged in `after` and something is left of the span: the user is still
    /// working on it. False once the field is cleared or sent, the span deleted, or the text before or after it edited.
    public static func holds(before: String, after: String, range: NSRange) -> Bool {
        let b = before as NSString, a = after as NSString
        guard range.location >= 0, NSMaxRange(range) <= b.length else { return false }
        let head = b.substring(to: range.location), tail = b.substring(from: NSMaxRange(range))
        // NSString says no empty string is a prefix or suffix.
        return a.length > head.utf16.count + tail.utf16.count && (head.isEmpty || a.hasPrefix(head)) && (tail.isEmpty || a.hasSuffix(tail))
    }

    /// Where `text` went after a paste: just before the caret, or else its only occurrence in the field. Nil when it
    /// is not there (yet) or appears more than once with no caret to tell which.
    public static func pasted(_ text: String, in value: String, caret: NSRange?) -> NSRange? {
        let v = value as NSString, length = (text as NSString).length
        guard length > 0 else { return nil }
        if let caret, caret.length == 0, caret.location >= length, caret.location <= v.length {
            let range = NSRange(location: caret.location - length, length: length)
            if v.substring(with: range) == text { return range }
        }
        let first = v.range(of: text, options: .literal)
        guard first.location != NSNotFound else { return nil }
        let after = NSMaxRange(first)
        let again = v.range(of: text, options: .literal, range: NSRange(location: after, length: v.length - after))
        return again.location == NSNotFound ? first : nil
    }
}

// MARK: corrections in an edit

/// The corrections one edit holds. Pure and bounded, so it is unit-tested with fixtures of typical edits.
public enum EditCorrections {
    /// Most words a misheard phrase may span, and its replacement.
    public static let maxHeardWords = 4
    public static let maxTermWords = 3
    /// Above this many words the edit is not compared at all.
    public static let maxWords = 300

    /// What `inserted` → `edited` teaches. A large rewrite (under half the words kept, and more than a short phrase
    /// changed) teaches nothing: the user wrote something new. Plain grammar fixes ("their" → "there") are not terms; only names and technical words are.
    public static func extract(inserted: String, edited: String) -> [LearnedCorrection] {
        let a = WordDiff.words(inserted), b = WordDiff.words(edited)
        guard inserted != edited, !a.isEmpty, !b.isEmpty, a.count <= maxWords, b.count <= maxWords else { return [] }
        let pairs = matches(a.map(key), b.map(key))
        let changed = max(a.count, b.count) - pairs.count
        guard pairs.count * 2 >= max(a.count, b.count) || changed <= maxHeardWords else { return [] }
        var out: [LearnedCorrection] = []
        func add(_ c: LearnedCorrection) { if !out.contains(c) { out.append(c) } }

        // Gaps between matched words: a misheard phrase replaced by the user's term.
        var previous = (i: -1, j: -1)
        for pair in pairs + [(a.count, b.count)] {
            let heard = Array(a[(previous.i + 1)..<pair.0]), typed = Array(b[(previous.j + 1)..<pair.1])
            if (1...maxHeardWords).contains(heard.count), (1...maxTermWords).contains(typed.count) {
                let atStart = previous.i < 0 || endsSentence(a[previous.i])
                let term = strip(typed.joined(separator: " "))
                if let correction = termCorrection(heard: strip(heard.joined(separator: " ")), term: term, atSentenceStart: atStart) {
                    add(correction)
                }
            }
            previous = (pair.0, pair.1)
        }
        // Matched words whose case changed: a name written properly ("kubernetes" → "Kubernetes").
        for (i, j) in pairs where a[i] != b[j] {
            let x = strip(a[i]), y = strip(b[j])
            // Only capitals added ("github" → "GitHub"), never taken away ("NASA" → "nASA").
            let raised = zip(x, y).contains { $0.isLowercase && $1.isUppercase }
            let lowered = zip(x, y).contains { $0.isUppercase && $1.isLowercase }
            guard x != y, x.lowercased() == y.lowercased(), raised, !lowered else { continue }
            let atStart = i == 0 || endsSentence(a[i - 1])
            if let correction = termCorrection(heard: x, term: y, atSentenceStart: atStart) { add(correction) }
        }
        // Style: the first word lowercased, or the final period dropped, with the words otherwise kept.
        if let first = a.first, let edit = b.first, pairs.first.map({ $0 == (0, 0) }) == true,
           first != edit, first.prefix(1).uppercased() == first.prefix(1), first.prefix(1) != first.prefix(1).lowercased(),
           edit == first.prefix(1).lowercased() + first.dropFirst(), !isPronounI(first), !isAcronym(strip(first)) {
            add(.style(.lowercaseStart))
        }
        if let last = a.last, let edit = b.last, last.hasSuffix("."), !last.hasSuffix(".."),
           edit.last.map({ $0.isLetter || $0.isNumber }) == true {
            add(.style(.noFinalPeriod))
        }
        return out
    }

    /// The word compared: lowercased letters and digits only.
    static func key(_ word: String) -> String { String(word.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }) }

    /// Leading and trailing punctuation off.
    static func strip(_ text: String) -> String { text.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces).union(.symbols)) }

    static func endsSentence(_ word: String) -> Bool { word.hasSuffix(".") || word.hasSuffix("!") || word.hasSuffix("?") }

    static func isPronounI(_ word: String) -> Bool {
        let w = strip(word)
        return w == "I" || w.hasPrefix("I'") || w.hasPrefix("I’")
    }

    static func isAcronym(_ word: String) -> Bool { word.count > 1 && word == word.uppercased() && word != word.lowercased() }

    /// A term only when it reads like a name or a technical word: a capital inside a word (GitHub, iOS), a digit, or a
    /// capital that is not just the start of a sentence. The heard phrase must differ from it.
    static func termCorrection(heard: String, term: String, atSentenceStart: Bool) -> LearnedCorrection? {
        guard !heard.isEmpty, !term.isEmpty, term.count <= 48, heard.count <= 64, key(heard) != "" else { return nil }
        guard heard != term, term.rangeOfCharacter(from: .letters) != nil else { return nil }
        let words = term.split(separator: " ").map(String.init)
        let innerCapital = words.contains { $0.dropFirst().contains(where: \.isUppercase) }
        let digit = term.rangeOfCharacter(from: .decimalDigits) != nil
        let capitals = words.enumerated().filter { $0.element.first?.isUppercase == true }.map(\.offset)
        let capitalized = capitals.contains { $0 > 0 } || (capitals.contains(0) && !atSentenceStart)
        guard innerCapital || digit || capitalized else { return nil }
        // "I" and sentence-case alone are not terms.
        if words.count == 1, isPronounI(term) { return nil }
        return .term(heard: heard.lowercased(), term: term)
    }

    /// Longest common subsequence of keys, as index pairs in order.
    static func matches(_ a: [String], _ b: [String]) -> [(Int, Int)] {
        var table = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] && !a[i].isEmpty ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var out: [(Int, Int)] = [], i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j], !a[i].isEmpty { out.append((i, j)); i += 1; j += 1 }
            else if table[i + 1][j] >= table[i][j + 1] { i += 1 } else { j += 1 }
        }
        return out
    }
}

// MARK: applying what was learned

/// What one dictation sends with `start.learned` (version 1), for the frontmost app.
public struct LearnedPayload: Sendable, Equatable {
    public struct Term: Sendable, Equatable {
        public var term: String
        public var heard: [String]
        public init(term: String, heard: [String]) { self.term = term; self.heard = heard }
    }
    public struct Example: Sendable, Equatable {
        public var said: String
        public var wanted: String
        public init(said: String, wanted: String) { self.said = said; self.wanted = wanted }
    }

    public var terms: [Term]
    public var style: [LearnedStyle]
    public var examples: [Example]

    public init(terms: [Term] = [], style: [LearnedStyle] = [], examples: [Example] = []) {
        self.terms = terms; self.style = style; self.examples = examples
    }

    public var isEmpty: Bool { terms.isEmpty && style.isEmpty && examples.isEmpty }

    /// The wire object (`v` 1).
    public var wire: [String: Any] {
        var out: [String: Any] = ["v": 1]
        if !terms.isEmpty { out["terms"] = terms.map { ["term": $0.term, "heard": $0.heard] as [String: Any] } }
        if !style.isEmpty { out["style"] = style.map(\.rawValue) }
        if !examples.isEmpty { out["examples"] = examples.map { ["said": $0.said, "wanted": $0.wanted] } }
        return out
    }

    /// What Chirp applies itself to the final text, so a learned item works with clean-up off or an older server too:
    /// a term whose misheard phrase has several words (never an ordinary word on its own) or differs only in case, and
    /// the app's style. Never adds a word: it only respells or restyles what was said.
    public func apply(to text: String) -> String {
        var out = text
        for t in terms {
            for heard in t.heard where heard.contains(" ") || heard.lowercased() == t.term.lowercased() {
                out = Self.replace(heard, with: t.term, in: out)
            }
        }
        if style.contains(.lowercaseStart), let first = out.split(separator: " ").first.map(String.init),
           !EditCorrections.isPronounI(first), !EditCorrections.isAcronym(EditCorrections.strip(first)),
           !terms.contains(where: { first.hasPrefix($0.term) }), let c = out.first, c.isUppercase {
            out = c.lowercased() + out.dropFirst()
        }
        if style.contains(.noFinalPeriod), out.hasSuffix("."), !out.hasSuffix("..") {
            out.removeLast()
        }
        return out
    }

    /// Whole-word, case-insensitive, any run of spaces between the words.
    static func replace(_ heard: String, with term: String, in text: String) -> String {
        let words = heard.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !words.isEmpty else { return text }
        let pattern = "(?<![\\w'’-])" + words.joined(separator: "\\s+") + "(?![\\w'’-])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let ns = text as NSString
        return regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: term))
    }
}
