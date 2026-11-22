import Foundation

/// Spans the checker must never rewrite (PLAN.md §2 step 2 and 7, Settings › Writing › "Protect names,
/// code and links"): URLs, emails, @mentions, #tags and issue numbers, `code` and fenced code, file
/// paths and names, identifiers (snake_case, camelCase, iPhone), emoji and emoticons, and words in a
/// non-Latin script (the model sometimes translates them).
///
/// Plain capitalized names ("Siobhan") are not protected: a regex can't tell them from a sentence start,
/// and the prompt already tells the model to keep names.
public enum ProtectedTokens {
    static let fileExtensions = "com|org|net|io|dev|app|ai|co|edu|gov|me|uk|de|ru|us|info|xyz|sh|swift|py|js|ts|tsx|jsx|json|md|txt|yml|yaml|toml|html|css|go|rs|rb|java|kt|cpp|plist|gguf|log|csv|pdf|png|jpg|jpeg|gif|svg|zip|env|lock|cfg|ini|xml|sql"

    /// Order doesn't matter: overlapping matches are merged. `trim`: drop trailing sentence punctuation
    /// from the match, so a URL or path at the end of a sentence keeps its final period or bracket outside.
    static let patterns: [(re: NSRegularExpression, trim: Bool)] = [
        ("```[\\s\\S]*?```", false),                                        // fenced code
        ("`[^`\\n]+`", false),                                              // inline code
        ("(?i)\\b(?:https?://|ftp://|www\\.)[^\\s<>\"'`]+", true),          // URLs
        ("[\\w.+-]+@[\\w-]+(?:\\.[\\w-]+)+", true),                         // emails
        ("(?<![\\w@.])@\\w[\\w.-]*", true),                                 // @mentions
        ("(?<![\\w#&])#[\\w-]+", false),                                     // #channels, #482
        ("\\b[\\w-]+(?:\\.[\\w-]+)*\\.(?:\(fileExtensions))\\b(?:/[^\\s]*)?", true), // domains, file names
        ("(?<![\\w/])(?:~|\\.{1,2})?/[\\w.@%+-]+(?:/[\\w.@%+-]*)*", true),  // /paths, ~/paths, /commands
        ("\\b[\\w.-]+(?:/[\\w.-]+)+", true),                                // feature/login, a/b/c
        ("\\b\\w*_\\w*", false),                                             // snake_case
        ("\\b[a-z]+[A-Z]\\w*", false),                                       // camelCase, iPhone, macOS
        ("\\b[A-Z][a-z]+[A-Z]\\w*", false),                                  // GitHub, JavaScript
        ("\\p{Extended_Pictographic}(?:\\x{FE0F}|\\x{200D}\\p{Extended_Pictographic}|[\\x{1F3FB}-\\x{1F3FF}])*", false), // emoji
        ("(?<![\\w:;])[:;]-?[()DPp](?!\\w)", false),                          // :) ;-) :D
        ("[\\p{L}\\p{M}]*[\\p{L}&&\\P{Script=Latin}][\\p{L}\\p{M}]*", false), // non-Latin words
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    /// Protected UTF-16 ranges in `text`, sorted and merged. `extra`: ranges found elsewhere (the code blocks of
    /// `CodeDetector`), merged in. `words: false` leaves out words in a non-Latin
    /// script (the last pattern): `LanguageGate` blanks out code and links before it guesses the language,
    /// but must still see the words themselves.
    public static func ranges(in text: String, words: Bool = true, extra: [NSRange] = []) -> [NSRange] {
        let ns = text as NSString
        let all = NSRange(location: 0, length: ns.length)
        var found: [NSRange] = extra
        for (re, trim) in words ? patterns[...] : patterns.dropLast() {
            for m in re.matches(in: text, range: all) {
                var r = m.range
                while trim, r.length > 1,
                      let c = ns.substring(with: NSRange(location: NSMaxRange(r) - 1, length: 1)).first,
                      ".,;:!?)]}'\"".contains(c) {
                    r.length -= 1
                }
                if r.length > 0 { found.append(r) }
            }
        }
        found.sort { $0.location < $1.location }
        var merged: [NSRange] = []
        for r in found {
            if let last = merged.last, r.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSUnionRange(last, r)
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    /// True when `range` (an edit's range in the same text) changes protected text: it overlaps a protected
    /// range, or inserts strictly inside one.
    public static func touches(_ range: NSRange, _ protected: [NSRange]) -> Bool {
        protected.contains { p in
            if range.length == 0 { return p.location < range.location && range.location < NSMaxRange(p) }
            return NSIntersectionRange(range, p).length > 0
        }
    }

    /// Protected ranges of the full text that overlap `chunk`, clipped and made relative to it.
    public static func clip(_ protected: [NSRange], to chunk: NSRange) -> [NSRange] {
        protected.compactMap { p in
            let i = NSIntersectionRange(p, chunk)
            return i.length > 0 ? NSRange(location: i.location - chunk.location, length: i.length) : nil
        }
    }

    /// True when protected text covers all of `chunk` (a paragraph inside a fenced code block): nothing to check.
    public static func covers(_ protected: [NSRange], _ chunk: NSRange) -> Bool {
        protected.contains { NSIntersectionRange($0, chunk) == chunk }
    }
}
