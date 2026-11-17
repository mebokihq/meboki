import Foundation

/// Cleans model output and rejects suspicious corrections (PLAN.md §2 step 7, `eval/guard.py`).
public enum PostFilter {
    public static let minSimilarity = 0.75

    /// Strips wrappers small models sometimes add: `<think>` blocks, a leading `<text>` / trailing `</text>`,
    /// and wrapping quotes. A wrapper is only removed if the user's own `input` doesn't have it, so quotes
    /// and tags the user typed survive. Inner whitespace and line breaks are kept.
    public static func clean(_ output: String, input: String) -> String {
        let inp = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var s = output.replacingOccurrences(of: "(?s)<think>.*?</think>", with: "", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("<text>"), !inp.hasPrefix("<text>") {
            s = String(s.dropFirst("<text>".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if s.hasSuffix("</text>"), !inp.hasSuffix("</text>") {
            s = String(s.dropLast("</text>".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let quoted = { (t: String) in t.count >= 2 && t.first == "\"" && t.last == "\"" }
        if quoted(s), !quoted(inp) {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s
    }

    /// Normalization used for comparisons only: curly quotes → straight, whitespace runs → one space.
    /// (`eval/bench.py` `norm` also strips edge tags and quotes; here `clean` does that first.)
    public static func normalize(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        t = t.replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return t
    }

    /// Case-insensitive similarity in 0...1 using Ratcliff/Obershelp matching, the algorithm behind
    /// Python's `difflib.SequenceMatcher.ratio()` (without autojunk), which `eval/guard.py` uses.
    /// The 0.75 threshold was tuned with that measure.
    public static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a.lowercased().unicodeScalars), y = Array(b.lowercased().unicodeScalars)
        if x.isEmpty && y.isEmpty { return 1 }
        if x.isEmpty || y.isEmpty { return 0 }
        var matches = 0
        var queue = [(0, x.count, 0, y.count)]
        while let (alo, ahi, blo, bhi) = queue.popLast() {
            let (i, j, k) = longestMatch(x, y, alo, ahi, blo, bhi)
            guard k > 0 else { continue }
            matches += k
            if alo < i && blo < j { queue.append((alo, i, blo, j)) }
            if i + k < ahi && j + k < bhi { queue.append((i + k, ahi, j + k, bhi)) }
        }
        return 2.0 * Double(matches) / Double(x.count + y.count)
    }

    /// Longest common block in x[alo..<ahi], y[blo..<bhi]; ties go to the earliest in x, then in y (as difflib).
    static func longestMatch(_ x: [Unicode.Scalar], _ y: [Unicode.Scalar],
                             _ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> (Int, Int, Int) {
        var best = (alo, blo, 0)
        var prev = [Int](repeating: 0, count: bhi - blo + 1)
        var cur = prev
        for i in alo..<ahi {
            for j in blo..<bhi {
                let c = j - blo + 1
                if x[i] == y[j] {
                    cur[c] = prev[c - 1] + 1
                    if cur[c] > best.2 { best = (i - cur[c] + 1, j - cur[c] + 1, cur[c]) }
                } else {
                    cur[c] = 0
                }
            }
            swap(&prev, &cur)
        }
        return best
    }

    /// True when only capitalization or final sentence punctuation differs.
    public static func isStyleOnly(_ a: String, _ b: String) -> Bool {
        func key(_ s: String) -> String {
            s.replacingOccurrences(of: "[.!?]+$", with: "", options: .regularExpression)
                .lowercased().trimmingCharacters(in: .whitespaces)
        }
        return key(a) == key(b)
    }

    public enum Verdict: Equatable, Sendable {
        case unchanged
        case rejected(reason: String)
        case corrected(String)
    }

    /// Decides whether `rawOutput` is an acceptable correction of `input`.
    public static func judge(input: String, rawOutput: String, ignoreStyleOnly: Bool = true) -> Verdict {
        let out = clean(rawOutput, input: input)
        let ni = normalize(input), no = normalize(out)
        if no == ni { return .unchanged }
        if out.isEmpty { return .rejected(reason: "empty output") }
        if similarity(ni, no) < minSimilarity { return .rejected(reason: "output too different (translated, answered or dropped text)") }
        if ignoreStyleOnly && isStyleOnly(ni, no) { return .unchanged }
        return .corrected(out)
    }
}
