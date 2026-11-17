import Foundation

/// What kind of mistake a fix corrects (design_code.md §5.9). Drives the chip, the underline color
/// and the reason line.
///
/// Named `FixCategory` rather than `Category`: the ObjectiveC module already exports a `Category`
/// type, which would make the name ambiguous in the app target.
public enum FixCategory: String, CaseIterable, Sendable {
    case spelling, grammar, clarity, punctuation, rewrite

    /// Display name for the chip ("Spelling", …).
    public var title: String {
        switch self {
        case .spelling: return "Spelling"
        case .grammar: return "Grammar"
        case .clarity: return "Clarity"
        case .punctuation: return "Punctuation"
        case .rewrite: return "Rewrite"
        }
    }
}

/// Classifies an `Edit` from the diff and writes a short reason for it.
///
/// The model returns only corrected text, so everything here is derived from the diff. Rules, first
/// match wins (§5.9):
/// 0. **Rewrite:** the edit holds four or more separate changes (a sentence `RewriteDetector` merged).
/// 1. **Clarity:** the edit only deletes a word that repeats its neighbor ("the the" → "the").
/// 2. **Punctuation:** the letters and digits are the same; only punctuation, apostrophes or spacing
///    differ ("Lets" → "Let's", an added comma).
/// 3. **Spelling:** one word → one word, edit distance 1 (or 2 with the same first letter), not a known grammar pair (your/you're,
///    then/than, …) and not an inflection of the same word (go/goes, shoe/shoes). A change of case
///    only ("i" → "I") is also spelling, with its own reason.
/// 4. **Grammar:** everything else.
public enum FixClassifier {
    public static func classify(_ edit: Edit, in text: String) -> FixCategory {
        let old = trimmed(edit.original), new = trimmed(edit.replacement)

        // A merged edit (`RewriteDetector`): several separate changes inside it.
        if Diff.edits(from: edit.original, to: edit.replacement).count >= RewriteDetector.minEdits { return .rewrite }

        if isRepeatedWordDeletion(edit, old: old, new: new, in: text) { return .clarity }

        let oldCore = alnum(old), newCore = alnum(new)
        if oldCore.lowercased() == newCore.lowercased() {
            // Only case changed (punctuation and spacing identical) → capitalization, shown as spelling.
            if old.lowercased() == new.lowercased() && old != new { return .spelling }
            return .punctuation
        }

        if isSingleWord(old), isSingleWord(new),
           !isGrammarPair(old, new), !isInflection(old, new),
           isTypo(oldCore.lowercased(), newCore.lowercased()) {
            return .spelling
        }
        return .grammar
    }

    /// The reason line for a fix (§5.9 templates). Uses typographic quotes.
    public static func reason(for edit: Edit, category: FixCategory, in text: String) -> String {
        let old = trimmed(edit.original), new = trimmed(edit.replacement)
        switch category {
        case .clarity:
            return "The word “\(old)” is repeated."
        case .punctuation:
            return "“\(punctuationContext(edit, in: text))” needs different punctuation."
        case .spelling:
            if old.lowercased() == new.lowercased() {
                let up = new.first.map { $0.isUppercase } ?? false
                return up ? "“\(new)” should be capitalized." : "“\(new)” should be lowercase."
            }
            return "“\(new)” is the correct spelling."
        case .rewrite:
            return "These changes work together: the sentence reads better rewritten."
        case .grammar:
            if new.isEmpty { return "Grammar: remove “\(old)”." }
            if old.isEmpty { return "Grammar: add “\(new)”." }
            return "Grammar: “\(old)” → “\(new)”."
        }
    }

    // MARK: - Rules

    /// The edit removes exactly one word (plus whitespace), and the word next to the removed range is
    /// the same word.
    static func isRepeatedWordDeletion(_ edit: Edit, old: String, new: String, in text: String) -> Bool {
        guard new.isEmpty, isSingleWord(old), !alnum(old).isEmpty else { return false }
        let ns = text as NSString
        guard NSMaxRange(edit.range) <= ns.length else { return false }
        let w = old.lowercased()
        let before = ns.substring(to: edit.range.location)
        let after = ns.substring(from: NSMaxRange(edit.range))
        return lastWord(before)?.lowercased() == w || firstWord(after)?.lowercased() == w
    }

    /// Unordered pairs of real words that are easy to confuse. Changing one into the other is a
    /// grammar or word-choice fix even though the spelling distance is small. Matched on lowercase
    /// letters only, so "dont" → "doesn't" hits the don't/doesn't pair.
    static let grammarPairs: Set<String> = {
        let pairs: [(String, String)] = [
            ("a", "an"), ("a", "the"), ("an", "the"),
            ("is", "are"), ("was", "were"), ("has", "have"), ("do", "does"), ("did", "does"), ("did", "do"),
            ("isn't", "aren't"), ("wasn't", "weren't"), ("hasn't", "haven't"), ("don't", "doesn't"),
            ("your", "you're"), ("you", "your"), ("you", "you're"),
            ("their", "there"), ("their", "they're"), ("there", "they're"),
            ("its", "it's"), ("whose", "who's"), ("then", "than"), ("to", "too"), ("to", "two"), ("too", "two"),
            ("of", "have"), ("of", "off"), ("affect", "effect"), ("lose", "loose"), ("were", "where"),
            ("we're", "were"), ("weather", "whether"), ("accept", "except"), ("advice", "advise"),
            ("less", "fewer"), ("much", "many"), ("this", "these"), ("that", "those"),
            ("saw", "seen"), ("saw", "see"), ("see", "seen"), ("went", "gone"), ("me", "i"), ("who", "whom"),
            ("lay", "lie"), ("in", "on"), ("in", "at"), ("on", "at"), ("for", "since"),
            ("will", "would"), ("can", "could"), ("may", "might"), ("shall", "should"),
            ("hear", "here"), ("know", "now"), ("no", "know"), ("right", "write"), ("by", "buy"),
            ("peace", "piece"), ("quiet", "quite"), ("brake", "break"), ("principal", "principle"),
        ]
        var s = Set<String>()
        for (a, b) in pairs { s.insert(key(a, b)); s.insert(key(b, a)) }
        return s
    }()

    static func isGrammarPair(_ a: String, _ b: String) -> Bool {
        grammarPairs.contains(key(a, b))
    }

    private static func key(_ a: String, _ b: String) -> String { alnum(a).lowercased() + "|" + alnum(b).lowercased() }

    /// One word is the other plus an inflectional suffix (shoe/shoes, go/goes, hear/hearing,
    /// try/tries): number, tense or form changed, which is grammar rather than spelling.
    static func isInflection(_ a: String, _ b: String) -> Bool {
        let x = normalize(a), y = normalize(b)
        let (short, long) = x.count <= y.count ? (x, y) : (y, x)
        guard short.count >= 2, short != long else { return false }
        let suffixes = ["s", "es", "d", "ed", "ing", "er", "est", "ly"]
        for suf in suffixes where long == short + suf { return true }
        // Final e dropped (use/using) or y → i (try/tries, happy/happily).
        if short.hasSuffix("e"), ["ing", "ed", "er", "est"].contains(where: { long == short.dropLast() + $0 }) { return true }
        if short.hasSuffix("y"), ["ies", "ied", "ier", "iest", "ily"].contains(where: { long == short.dropLast() + $0 }) { return true }
        return false
    }

    /// Edit distance 1, or 2 with the same first letter. Real misspellings ("tommorow", "definatly")
    /// keep the first letter; a distance-2 swap that changes it is usually another word ("nothing" → "anything").
    static func isTypo(_ a: String, _ b: String) -> Bool {
        switch distance(a, b) {
        case 1: return true
        case 2: return a.first == b.first
        default: return false
        }
    }

    // MARK: - Text helpers

    static let wordChars: CharacterSet = {
        var s = CharacterSet.alphanumerics
        s.insert(charactersIn: "'’_-")
        return s
    }()

    static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Letters and digits only.
    static func alnum(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }))
    }

    static func normalize(_ s: String) -> String {
        trimmed(s).replacingOccurrences(of: "’", with: "'").lowercased()
    }

    /// A non-empty run of word characters (letters, digits, apostrophes, `_`, `-`) with letters in it.
    static func isSingleWord(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { wordChars.contains($0) }
            && s.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    static func lastWord(_ s: String) -> String? {
        let scalars = Array(s.unicodeScalars)
        var end = scalars.count
        while end > 0, CharacterSet.whitespacesAndNewlines.contains(scalars[end - 1]) { end -= 1 }
        var start = end
        while start > 0, wordChars.contains(scalars[start - 1]) { start -= 1 }
        return start < end ? String(String.UnicodeScalarView(scalars[start..<end])) : nil
    }

    static func firstWord(_ s: String) -> String? {
        let scalars = Array(s.unicodeScalars)
        var start = 0
        while start < scalars.count, CharacterSet.whitespacesAndNewlines.contains(scalars[start]) { start += 1 }
        var end = start
        while end < scalars.count, wordChars.contains(scalars[end]) { end += 1 }
        return start < end ? String(String.UnicodeScalarView(scalars[start..<end])) : nil
    }

    /// The replacement with any word glued to it on either side, so an added comma reads as
    /// “Hello,” rather than “,”.
    static func punctuationContext(_ edit: Edit, in text: String) -> String {
        let ns = text as NSString
        let new = edit.replacement
        guard NSMaxRange(edit.range) <= ns.length else { return trimmed(new) }
        func touching(_ s: String, fromEnd: Bool) -> String {
            let scalars = Array(s.unicodeScalars)
            if fromEnd {
                var i = scalars.count
                while i > 0, wordChars.contains(scalars[i - 1]) { i -= 1 }
                return String(String.UnicodeScalarView(scalars[i...]))
            } else {
                var i = 0
                while i < scalars.count, wordChars.contains(scalars[i]) { i += 1 }
                return String(String.UnicodeScalarView(scalars[..<i]))
            }
        }
        // Only glue on the side where the replacement itself has no whitespace at its edge.
        let left = new.first?.isWhitespace == true ? "" : touching(ns.substring(to: edit.range.location), fromEnd: true)
        let right = new.last?.isWhitespace == true ? "" : touching(ns.substring(from: NSMaxRange(edit.range)), fromEnd: false)
        let s = trimmed(left + new + right)
        return s.isEmpty ? trimmed(new) : s
    }

    /// Optimal string alignment distance (Levenshtein plus adjacent transposition), so "teh" → "the" is 1.
    static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        let n = x.count, m = y.count
        if n == 0 { return m }
        if m == 0 { return n }
        var d = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        for i in 1...n {
            for j in 1...m {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[n][m]
    }
}
