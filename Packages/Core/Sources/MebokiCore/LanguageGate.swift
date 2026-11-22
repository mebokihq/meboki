import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// Finds text that isn't English (PLAN.md §2 "Check Pipeline", step 2), so it never goes to the model: the
/// prompt and the benchmark are English-only, and a model asked to proofread German text may "fix" it into
/// English. Uses `NLLanguageRecognizer` (on device, no network).
///
/// Precision comes first: text wrongly judged "not English" silently loses its real fixes. So text is judged
/// only when
/// - it has at least `minLetters` letters after code, links, @mentions, paths and identifiers are blanked out
///   (short chat lines fool the recognizer: "np, happy to help :)" reads as 93% Polish, and a GitHub URL as
///   Danish), and
/// - the top guess is another language at `minConfidence` or more, and English gets `maxEnglish` or less, and
/// - it has fewer than two distinct English function words (`englishMarkers`: "the", "with", "you", …). A
///   list of names and acronyms with a little English ("Harper (Apache-2.0), Sparkle (MIT) — all compatible
///   with GPL-3.0 and Apache-2.0.") reads as 98% German to the recognizer.
///
/// Short foreign text ("Danke, bis morgen!") still goes to the model, as before: the prompt tells it never to
/// translate, and words in a non-Latin script are protected tokens. Single foreign words in Latin script inside
/// an English sentence ("Danke for the help") aren't detected.
public enum LanguageGate {
    /// Fewest letters (after blanking) a text needs before it's judged at all.
    public static let minLetters = 20
    /// The top non-English guess must be at least this sure.
    public static let minConfidence = 0.95
    /// …and English at most this likely.
    public static let maxEnglish = 0.01

    /// The language `text` is confidently written in (a BCP 47 code such as "de"), when that isn't English.
    /// nil for English, for text too short to tell, and when unsure. Pass text with code and links blanked
    /// out (`blanked(_:)`).
    public static func foreignLanguage(_ text: String) -> String? {
        guard judgeable(text), !hasEnglishMarkers(text) else { return nil }
        #if canImport(NaturalLanguage)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        let guesses = recognizer.languageHypotheses(withMaximum: 3)
        guard let top = guesses.max(by: { $0.value < $1.value }), top.key != .english,
              top.value >= minConfidence, (guesses[.english] ?? 0) <= maxEnglish
        else { return nil }
        return top.key.rawValue
        #else
        return nil
        #endif
    }

    /// Common English words that aren't words in the other languages people mix with English (so not "in",
    /// "is", "to", "for", "was", "will", "me", "my", "an", "die", "so": German, Dutch, Polish, Scandinavian or
    /// Romance words too).
    static let englishMarkers: Set<String> = [
        "the", "and", "with", "you", "your", "that", "this", "these", "those", "are", "were", "have", "would",
        "should", "could", "what", "which", "there", "their", "they", "them", "from", "about", "been", "into",
        "just", "our", "how", "why", "when", "who", "can", "it's", "i'm", "don't", "can't", "isn't", "i'll",
        "you're", "we're", "doesn't", "didn't", "won't", "please", "thanks", "because", "after",
    ]

    /// True when `text` has at least two distinct `englishMarkers`.
    static func hasEnglishMarkers(_ text: String) -> Bool {
        var seen = Set<String>()
        let words = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .split { !($0.isLetter || $0 == "'") }
        for w in words where englishMarkers.contains(String(w)) {
            seen.insert(String(w))
            if seen.count >= 2 { return true }
        }
        return false
    }

    /// `text` with code, links, emails, @mentions, #tags, paths, identifiers and emoji replaced by spaces, so
    /// they don't sway the guess. Same UTF-16 length, so ranges stay valid. Words in any script are kept.
    public static func blanked(_ text: String, extra: [NSRange] = []) -> NSString {
        let out = NSMutableString(string: text)
        for r in ProtectedTokens.ranges(in: text, words: false, extra: extra) {
            out.replaceCharacters(in: r, with: String(repeating: " ", count: r.length))
        }
        return out
    }

    /// Sentence ranges (UTF-16) of `text` a check leaves out because they aren't English: what
    /// `ProofreadEngine` and `CheckPipeline` skip, paragraph by paragraph. For `eval/language_report.py`.
    public static func foreignRanges(in text: String) -> [NSRange] {
        let ns = text as NSString
        let blanked = blanked(text)
        return ProofreadEngine.chunks(of: text).flatMap { p -> [NSRange] in
            let sentences = CheckPipeline.sentences(in: ns, range: p)
            let found = foreignSentences(paragraph: p, sentences: sentences, blanked: blanked,
                                         isForeign: { foreignLanguage($0) != nil })
            return found.sorted().map { sentences[$0] }
        }
    }

    /// True when the recognizer's best guess for `text` is English, however short and unsure: a short sentence
    /// that leans English keeps its check even inside a foreign paragraph.
    static func leansEnglish(_ text: String) -> Bool {
        if hasEnglishMarkers(text) { return true }
        #if canImport(NaturalLanguage)
        return NLLanguageRecognizer.dominantLanguage(for: text) == .english
        #else
        return true
        #endif
    }

    /// True when `text` has enough letters to be judged (`minLetters`).
    static func judgeable(_ text: String) -> Bool {
        var letters = 0
        for c in text.unicodeScalars where CharacterSet.letters.contains(c) {
            letters += 1
            if letters >= minLetters { return true }
        }
        return false
    }

    /// Indices of the sentences of one paragraph that aren't English. `blanked`: the whole text through
    /// `blanked(_:)`; `sentences`: the paragraph's sentence ranges in it (`CheckPipeline.sentences`).
    /// `isForeign` judges one blanked text (the pipeline passes a cached `foreignLanguage`).
    ///
    /// - A sentence long enough to judge is judged on its own, so an English sentence next to a long German
    ///   one stays English.
    /// - The short ones are judged together ("Danke! Bis morgen. Ich komme um acht."). When even together
    ///   they're too short, they follow the whole paragraph ("Ich melde mich später." after a long German
    ///   sentence), unless on their own they lean English ("She dont like apples." before a long French one).
    static func foreignSentences(paragraph: NSRange, sentences: [NSRange], blanked: NSString,
                                 isForeign: (String) -> Bool) -> Set<Int> {
        var out = Set<Int>()
        var short: [Int] = []
        for (i, r) in sentences.enumerated() {
            let s = blanked.substring(with: r)
            if judgeable(s) {
                if isForeign(s) { out.insert(i) }
            } else {
                short.append(i)
            }
        }
        guard !short.isEmpty else { return out }
        let together = short.map { blanked.substring(with: sentences[$0]) }.joined(separator: " ")
        let foreign = judgeable(together) ? isForeign(together)
            : short.count < sentences.count && !leansEnglish(together) && isForeign(blanked.substring(with: paragraph))
        if foreign { out.formUnion(short) }
        return out
    }

    /// The English parts of a paragraph: runs of sentences next to each other that aren't in `foreign`,
    /// one range each (from the first sentence's start to the last one's end).
    static func englishRuns(_ sentences: [NSRange], foreign: Set<Int>) -> [NSRange] {
        var runs: [NSRange] = []
        var open: NSRange?
        for (i, s) in sentences.enumerated() {
            if foreign.contains(i) {
                if let o = open { runs.append(o); open = nil }
            } else {
                open = open.map { NSUnionRange($0, s) } ?? s
            }
        }
        if let o = open { runs.append(o) }
        return runs
    }
}
