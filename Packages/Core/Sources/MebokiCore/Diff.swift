import Foundation

/// One contiguous change: replace `range` (UTF-16, relative to the original text) with `replacement`.
public struct Edit: Equatable, Sendable {
    public var range: NSRange
    public var original: String
    public var replacement: String

    public init(range: NSRange, original: String, replacement: String) {
        self.range = range
        self.original = original
        self.replacement = replacement
    }
}

/// A display segment for showing the diff.
public enum Segment: Equatable, Sendable {
    case same(String)
    case removed(String)
    case added(String)
}

public enum Diff {
    struct Token {
        let text: String
        let range: NSRange  // UTF-16
    }

    /// Words (letters, digits, apostrophes), whitespace runs, and single other characters.
    static func tokenize(_ s: String) -> [Token] {
        let ns = s as NSString
        let re = try! NSRegularExpression(pattern: "[\\p{L}\\p{N}'’_-]+|\\s+|.", options: [.dotMatchesLineSeparators])
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map {
            Token(text: ns.substring(with: $0.range), range: $0.range)
        }
    }

    enum Op { case same(Int, Int), del(Int), ins(Int) }

    /// LCS alignment over tokens. `ignoringCase`: tokens that differ only in case count as the same.
    static func align(_ a: [Token], _ b: [Token], ignoringCase: Bool = false) -> [Op] {
        let n = a.count, m = b.count
        let ka = ignoringCase ? a.map { $0.text.lowercased() } : a.map(\.text)
        let kb = ignoringCase ? b.map { $0.text.lowercased() } : b.map(\.text)
        var lcs = [[Int32]](repeating: [Int32](repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    lcs[i][j] = ka[i] == kb[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }
        var ops: [Op] = []
        var i = 0, j = 0
        while i < n && j < m {
            if ka[i] == kb[j] { ops.append(.same(i, j)); i += 1; j += 1 }
            else if lcs[i + 1][j] >= lcs[i][j + 1] { ops.append(.del(i)); i += 1 }
            else { ops.append(.ins(j)); j += 1 }
        }
        while i < n { ops.append(.del(i)); i += 1 }
        while j < m { ops.append(.ins(j)); j += 1 }
        return ops
    }

    /// Edits that turn `original` into `corrected`. Changes separated only by a single
    /// whitespace token are merged into one edit, so "We was" → "We were" stays readable.
    /// `merge: false` keeps every change separate (used to classify the parts of a merged edit).
    public static func edits(from original: String, to corrected: String, merge: Bool = true) -> [Edit] {
        let a = tokenize(original), b = tokenize(corrected)
        let ops = align(a, b)
        let ns = original as NSString

        // Collect raw hunks as (start index in a, end index in a (exclusive), inserted b tokens).
        struct Hunk { var aStart: Int; var aEnd: Int; var bText: String }
        var hunks: [Hunk] = []
        var cur: Hunk?
        var aPos = 0
        for op in ops {
            switch op {
            case .same(let i, _):
                if let h = cur { hunks.append(h); cur = nil }
                aPos = i + 1
            case .del(let i):
                if cur == nil { cur = Hunk(aStart: i, aEnd: i, bText: "") }
                cur!.aEnd = i + 1
                aPos = i + 1
            case .ins(let j):
                if cur == nil { cur = Hunk(aStart: aPos, aEnd: aPos, bText: "") }
                cur!.bText += b[j].text
            }
        }
        if let h = cur { hunks.append(h) }

        // Merge hunks separated by exactly one whitespace token.
        var merged: [Hunk] = []
        for h in hunks {
            if merge, var last = merged.last, h.aStart == last.aEnd + 1,
               a[last.aEnd].text.allSatisfy(\.isWhitespace) {
                last.bText += a[last.aEnd].text + h.bText
                last.aEnd = h.aEnd
                merged[merged.count - 1] = last
            } else {
                merged.append(h)
            }
        }

        return merged.map { h in
            let loc: Int
            if h.aStart < a.count { loc = a[h.aStart].range.location } else { loc = ns.length }
            let end = h.aEnd > h.aStart ? NSMaxRange(a[h.aEnd - 1].range) : loc
            let range = NSRange(location: loc, length: end - loc)
            return Edit(range: range, original: ns.substring(with: range), replacement: h.bText)
        }
    }

    /// Display segments for `original` with `edits` applied (edits must be sorted, non-overlapping).
    public static func segments(original: String, edits: [Edit]) -> [Segment] {
        let ns = original as NSString
        var out: [Segment] = []
        var pos = 0
        for e in edits.sorted(by: { $0.range.location < $1.range.location }) {
            if e.range.location > pos {
                out.append(.same(ns.substring(with: NSRange(location: pos, length: e.range.location - pos))))
            }
            if !e.original.isEmpty { out.append(.removed(e.original)) }
            if !e.replacement.isEmpty { out.append(.added(e.replacement)) }
            pos = NSMaxRange(e.range)
        }
        if pos < ns.length { out.append(.same(ns.substring(from: pos))) }
        return out
    }

    /// Applies edits to a string (for tests and previews).
    public static func apply(_ edits: [Edit], to text: String) -> String {
        let ms = NSMutableString(string: text)
        for e in edits.sorted(by: { $0.range.location > $1.range.location }) {
            ms.replaceCharacters(in: e.range, with: e.replacement)
        }
        return ms as String
    }
}
