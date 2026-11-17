import Foundation

/// Rewrite detection (PLAN.md §2 step 7, measured 2026-11-16 in `eval/rewrite_report.py`).
///
/// A sentence with many changes that only make sense together is shown as one "Rewrite" fix, not as
/// several underlines that the user would have to accept one by one (and could accept halfway, leaving
/// a sentence that is neither the old one nor the new one: "If I had more money, I would bought …").
///
/// The rule works on one sentence and the edits that survived the settings' filters:
/// - at least `minEdits` edits, and
/// - the *structural* words they touch are at least `minStructuralRatio` of the sentence's words.
///
/// A structural edit is anything but a one-word → one-word change (a typo, an inflection, a case) or a
/// punctuation-only change: words added, words removed, a phrase replaced. Typos and inflections are
/// independent, so a short line with four typos stays four fixes ("Thanks for you're help … realy usefull
/// … alot": 4 edits, 0 structural words); a sentence with the clause rebuilt around the mistake does not.
///
/// What the numbers rest on (Gemma 4 E4B Q4_0, 62 sentences that the model changed): 6 sentences reach
/// ratio 0.40 with 4+ edits and all six are real rebuilds; the nearest sentences below the line sit at 0.33
/// (5 edits) and at 0.43 with only 2 edits ("Could you please explain me the problem?"). The edit-count
/// floor and the ratio each guard against one of those. See PLAN.md for the table and its limits.
public enum RewriteDetector {
    public static let minEdits = 4
    public static let minStructuralRatio = 0.40

    /// `edits` (relative to `chunk`, any order) with each rewritten sentence's edits merged into one edit
    /// that spans from the sentence's first change to its last. Edits outside such sentences are returned
    /// as they were. Edits that cross a sentence boundary count for the sentence where they start.
    public static func group(_ edits: [Edit], in chunk: String) -> [Edit] {
        guard edits.count >= minEdits else { return edits }
        let ns = chunk as NSString
        let sorted = edits.sorted { $0.range.location < $1.range.location }
        let sentences = CheckPipeline.sentences(in: ns, range: NSRange(location: 0, length: ns.length))
        var out: [Edit] = []
        var i = 0
        for s in sentences {
            var j = i
            while j < sorted.count, sorted[j].range.location < NSMaxRange(s) || s == sentences.last { j += 1 }
            let mine = Array(sorted[i..<j])
            i = j
            if isRewrite(mine, sentence: ns.substring(with: s)) {
                out.append(merged(mine, in: ns))
            } else {
                out += mine
            }
        }
        out += sorted[i...]
        return out
    }

    /// True when `edits` (the changes inside one sentence) are a rewrite by the rule above.
    public static func isRewrite(_ edits: [Edit], sentence: String) -> Bool {
        edits.count >= minEdits && structuralRatio(edits, sentence: sentence) >= minStructuralRatio
    }

    /// Words the structural edits touch (the larger side of each), divided by the sentence's words.
    public static func structuralRatio(_ edits: [Edit], sentence: String) -> Double {
        var structural = 0
        for e in edits {
            let a = wordCount(e.original), b = wordCount(e.replacement)
            if a == 0 && b == 0 { continue }
            if a == 1 && b == 1 { continue }
            structural += max(a, b)
        }
        return Double(structural) / Double(max(1, wordCount(sentence)))
    }

    /// One edit from the first change to the last, with every change in between applied.
    static func merged(_ edits: [Edit], in ns: NSString) -> Edit {
        let first = edits.first!.range.location
        let last = edits.map { NSMaxRange($0.range) }.max()!
        let span = NSRange(location: first, length: last - first)
        let original = ns.substring(with: span)
        let local = edits.map { e -> Edit in
            var e = e
            e.range.location -= first
            return e
        }
        return Edit(range: span, original: original, replacement: Diff.apply(local, to: original))
    }

    static func wordCount(_ s: String) -> Int {
        Diff.tokenize(s).filter { t in t.text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) } }.count
    }
}
