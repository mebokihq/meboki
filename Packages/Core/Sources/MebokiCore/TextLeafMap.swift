import Foundation

/// Where the text leaves of a rich editor sit in the field's value (UTF-16).
///
/// Chromium and Electron `contenteditable` fields (x.com, Gmail, Notion, Slack, Obsidian) report the whole text
/// as the field's `AXValue`, but answer `AXBoundsForRange` on the field with an empty rect. Their static-text
/// children (the leaves) do answer it, with ranges local to the leaf. The value is the leaves' text in order,
/// with a `\n` between blocks and sometimes an object replacement character for an image. This map lines the
/// leaves up with the value, so a field range can be split into leaf-local ranges.
///
/// Matching is strict: a leaf goes where its exact text follows the previous leaf, after a gap of only
/// whitespace, newlines and object replacement characters. A leaf that doesn't match is left out (its text
/// gets no bounds); the next leaf may skip over the text the unmatched one would have covered.
public struct TextLeafMap: Equatable, Sendable {
    public struct Segment: Equatable, Sendable {
        /// Index into the leaves the map was built from.
        public let leaf: Int
        /// Where the leaf's text sits in the value.
        public let range: NSRange
    }

    /// Matched leaves, in value order, never overlapping.
    public let segments: [Segment]
    /// UTF-16 length of the value.
    public let length: Int

    /// - Parameters:
    ///   - value: the field's value.
    ///   - leaves: the text of each leaf, in document order.
    ///   - maxGap: how far past the previous leaf a leaf may start (only skippable characters in between).
    public init(value: String, leaves: [String], maxGap: Int = 8) {
        let ns = value as NSString
        length = ns.length
        var segments: [Segment] = []
        var cursor = 0
        // Text of leaves that didn't match since the last match: the next leaf may start that much later, and
        // the gap may hold anything up to that many characters.
        var unmatched = 0
        for (i, leaf) in leaves.enumerated() {
            let t = leaf as NSString
            guard t.length > 0, cursor < ns.length else { continue }
            let end = min(ns.length, cursor + maxGap + unmatched + t.length)
            let found = ns.range(of: leaf, options: .literal, range: NSRange(location: cursor, length: end - cursor))
            if found.location != NSNotFound,
               Self.gapOK(ns.substring(with: NSRange(location: cursor, length: found.location - cursor)),
                          allowed: unmatched) {
                segments.append(Segment(leaf: i, range: found))
                cursor = NSMaxRange(found)
                unmatched = 0
            } else {
                unmatched += t.length
            }
        }
        self.segments = segments
    }

    private init(segments: [Segment], length: Int) {
        self.segments = segments
        self.length = length
    }

    /// The map after `change` (relative to the value the map was built for), without walking the leaves again:
    /// the leaf the change sits in grows or shrinks by `change.delta` and every later leaf moves by it. Nil when
    /// that isn't safe to assume: the change reaches outside one leaf, or is an insertion at a leaf's edge (it
    /// may belong to the leaf next to it). The returned leaf index is the edited leaf: the editor may have
    /// split or replaced it, so a caller rebuilds before relying on it.
    public func edited(_ change: TextChange) -> (map: TextLeafMap, leaf: Int)? {
        let c = change.range
        guard NSMaxRange(c) <= length,
              let k = segments.firstIndex(where: { NSMaxRange($0.range) >= NSMaxRange(c) }) else { return nil }
        let s = segments[k].range
        guard s.location <= c.location else { return nil }
        if c.length == 0, c.location == s.location || c.location == NSMaxRange(s) { return nil }
        // An edit that empties the leaf leaves nothing to anchor on.
        guard s.length + change.delta > 0 else { return nil }
        var out = segments
        out[k] = Segment(leaf: out[k].leaf, range: NSRange(location: s.location, length: s.length + change.delta))
        for i in (k + 1)..<out.count {
            out[i] = Segment(leaf: out[i].leaf, range: NSRange(location: out[i].range.location + change.delta,
                                                               length: out[i].range.length))
        }
        return (TextLeafMap(segments: out, length: length + change.delta), segments[k].leaf)
    }

    /// Whitespace, newlines and object replacement characters are skipped freely; anything else only up to
    /// `allowed` characters (the text of leaves that didn't match).
    private static func gapOK(_ gap: String, allowed: Int) -> Bool {
        var other = 0
        for u in gap.unicodeScalars where !(CharacterSet.whitespacesAndNewlines.contains(u) || u == "\u{FFFC}") {
            other += 1
        }
        return other <= allowed
    }

    /// `range` of the value split into leaf-local ranges, in order. Parts of `range` that no leaf covers
    /// (the `\n` between blocks, unmatched leaves) are left out.
    public func pieces(of range: NSRange) -> [(leaf: Int, range: NSRange)] {
        guard range.length > 0 else { return [] }
        // First segment that ends after range.location.
        var lo = 0, hi = segments.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(segments[mid].range) <= range.location { lo = mid + 1 } else { hi = mid }
        }
        var out: [(leaf: Int, range: NSRange)] = []
        var i = lo
        while i < segments.count, segments[i].range.location < NSMaxRange(range) {
            let s = segments[i]
            let overlap = NSIntersectionRange(s.range, range)
            if overlap.length > 0 {
                out.append((s.leaf, NSRange(location: overlap.location - s.range.location, length: overlap.length)))
            }
            i += 1
        }
        return out
    }

    /// The leaf and leaf-local offset of value index `index`: inside a leaf, or right at a leaf's end (a caret
    /// after the last character). Nil between leaves (the `\n` between blocks) or past them.
    public func locate(_ index: Int) -> (leaf: Int, offset: Int)? {
        var lo = 0, hi = segments.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(segments[mid].range) < index { lo = mid + 1 } else { hi = mid }
        }
        // `lo` is the first segment ending at or after `index`; a segment starting at `index` wins over one ending there.
        if lo + 1 < segments.count, NSMaxRange(segments[lo].range) == index, segments[lo + 1].range.location == index {
            lo += 1
        }
        guard lo < segments.count else { return nil }
        let s = segments[lo]
        guard s.range.location <= index, index <= NSMaxRange(s.range) else { return nil }
        return (s.leaf, index - s.range.location)
    }

    /// Share of the value's non-whitespace characters that some leaf covers (1 when the value is blank).
    public func coverage(of value: String) -> Double {
        let ns = value as NSString
        var total = 0, covered = 0
        var seg = 0
        for i in 0..<ns.length {
            guard let u = Unicode.Scalar(ns.character(at: i)),
                  !CharacterSet.whitespacesAndNewlines.contains(u) else { continue }
            total += 1
            while seg < segments.count, NSMaxRange(segments[seg].range) <= i { seg += 1 }
            if seg < segments.count, NSLocationInRange(i, segments[seg].range) { covered += 1 }
        }
        return total == 0 ? 1 : Double(covered) / Double(total)
    }
}
