import Foundation

/// Two reads of a field that holds a window onto a longer document (Google Docs' hidden copy holds whole
/// paragraphs around the caret, about 4 000 characters, and moves the window when the caret or an edit moves far):
/// where the text they share sits in each. UTF-16.
public enum TextWindow {
    public struct Alignment: Equatable, Sendable {
        /// `old` index i is `new` index i − `shift`, up to `edit` (after it, add the edit's delta).
        public var shift: Int
        /// The text both hold, in `old` indices: whole paragraphs.
        public var overlap: NSRange
        /// One small change inside `overlap` (`old` indices): a write that went in while the window moved.
        public var edit: TextChange?
    }

    /// How `new` lines up with `old` when the window moved, or nil when they share no paragraph, or when one text
    /// change explains the whole difference (a small edit: `TextChange` handles it).
    ///
    /// Both windows start and end at paragraph breaks, so they are lined up paragraph by paragraph: from a paragraph
    /// both start with (one of the first two of either), pairs of paragraphs must be equal, except one pair that may
    /// differ by a small edit. Each place the start occurs is tried; the longest overlap wins (a document may repeat
    /// a paragraph), at equal length the one without an edit.
    ///
    /// `evenWhenSmall`: line the paragraphs up even when one small text change describes the difference. A write's
    /// check uses it: right after a paste Docs may add or drop one short paragraph at an edge of its window, and
    /// that is a shift of whole paragraphs, not an edit (2026-11-22).
    public static func alignment(old: String, new: String, evenWhenSmall: Bool = false) -> Alignment? {
        let o = old as NSString, n = new as NSString
        guard o.length > 0, n.length > 0, old != new else { return nil }
        if !evenWhenSmall, let c = TextChange.between(old, new), c.range.length <= 200,
           (c.replacement as NSString).length <= 200 {
            return nil
        }
        let op = paragraphs(o), np = paragraphs(n)
        var best: Alignment?
        func consider(_ i0: Int, _ j0: Int) {
            var i = i0, j = j0
            var edit: TextChange?
            var end = op[i0].location
            while i < op.count, j < np.count {
                let a = o.substring(with: op[i]), b = n.substring(with: np[j])
                if a != b {
                    guard edit == nil, let c = TextChange.between(a, b), c.range.length <= 200,
                          (c.replacement as NSString).length <= 200 else { break }
                    edit = TextChange(range: NSRange(location: op[i].location + c.range.location, length: c.range.length),
                                      replacement: c.replacement)
                }
                end = NSMaxRange(op[i])
                i += 1
                j += 1
            }
            // Stopped at a paragraph that differs: the break before it is in both.
            if i < op.count, j < np.count, end > op[i0].location { end += 1 }
            let overlap = NSRange(location: op[i0].location, length: end - op[i0].location)
            guard overlap.length >= 20 else { return }
            let a = Alignment(shift: op[i0].location - np[j0].location, overlap: overlap, edit: edit)
            if let b = best {
                guard a.overlap.length > b.overlap.length
                        || (a.overlap.length == b.overlap.length && b.edit != nil && a.edit == nil) else { return }
            }
            best = a
        }
        for j0 in 0..<min(2, np.count) {
            let first = n.substring(with: np[j0])
            for i0 in op.indices.prefix(400) where o.substring(with: op[i0]) == first { consider(i0, j0) }
        }
        for i0 in 0..<min(2, op.count) {
            let first = o.substring(with: op[i0])
            for j0 in np.indices.prefix(400) where n.substring(with: np[j0]) == first { consider(i0, j0) }
        }
        return best
    }

    /// The paragraphs of `s` (ranges without their "\n").
    private static func paragraphs(_ s: NSString) -> [NSRange] {
        var out: [NSRange] = []
        var start = 0
        while start <= s.length {
            let r = s.range(of: "\n", range: NSRange(location: start, length: s.length - start))
            let end = r.location == NSNotFound ? s.length : r.location
            out.append(NSRange(location: start, length: end - start))
            if r.location == NSNotFound { break }
            start = end + 1
        }
        return out
    }
}
