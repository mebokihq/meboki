import Foundation

/// One document made of several text fields (UTF-16).
///
/// Some apps give every paragraph its own editable element instead of one field for the whole document
/// (LibreOffice Writer: one `AXTextArea` per paragraph; Notion: one element per block). The check, the fix
/// list and the underlines work on one text, so the segments are joined into one document text with a
/// separator between them (a newline: each segment is a paragraph). This map turns document ranges into
/// segment-local ones and back.
///
/// The separators belong to no segment: a document range over one is split around it (`pieces(of:)`), and an
/// edit that touches one can't be written (`local(_:)` gives nil).
public struct SegmentMap: Equatable, Sendable {
    /// The text of each segment, in document order.
    public let segments: [String]
    /// What goes between two segments in `text`.
    public let separator: String
    /// The segments joined by `separator`.
    public let text: String
    /// Where each segment sits in `text`, in order, never overlapping.
    public let ranges: [NSRange]

    public init(segments: [String], separator: String = "\n") {
        self.segments = segments
        self.separator = separator
        let sep = (separator as NSString).length
        var ranges: [NSRange] = []
        var location = 0
        for s in segments {
            let length = (s as NSString).length
            ranges.append(NSRange(location: location, length: length))
            location += length + sep
        }
        self.ranges = ranges
        self.text = segments.joined(separator: separator)
    }

    /// UTF-16 length of `text`.
    public var length: Int { ranges.last.map(NSMaxRange) ?? 0 }

    /// `range` of the document split into segment-local ranges, in order. The separators are left out, and so
    /// is an empty range.
    public func pieces(of range: NSRange) -> [(segment: Int, range: NSRange)] {
        guard range.length > 0 else { return [] }
        var out: [(segment: Int, range: NSRange)] = []
        var i = firstSegment(endingAfter: range.location)
        while i < ranges.count, ranges[i].location < NSMaxRange(range) {
            let overlap = NSIntersectionRange(ranges[i], range)
            if overlap.length > 0 {
                out.append((i, NSRange(location: overlap.location - ranges[i].location, length: overlap.length)))
            }
            i += 1
        }
        return out
    }

    /// The one segment that holds all of `range`, and the range local to it. An empty range at a segment's
    /// start or end counts as inside it (a caret, an insertion); where two segments could take it (an empty
    /// segment), the later one does. Nil when the range reaches over a separator, or past the document.
    public func local(_ range: NSRange) -> (segment: Int, range: NSRange)? {
        guard range.location >= 0, range.length >= 0, let (i, offset) = locate(range.location) else { return nil }
        guard offset + range.length <= ranges[i].length else { return nil }
        return (i, NSRange(location: offset, length: range.length))
    }

    /// The segment and segment-local offset of document index `index`: inside a segment, or right at its end
    /// (a caret after its last character, which is also where the separator after it starts). A segment that
    /// starts at `index` wins over one that ends there. Nil past the document.
    public func locate(_ index: Int) -> (segment: Int, offset: Int)? {
        guard index >= 0, !ranges.isEmpty else { return nil }
        var i = firstSegment(endingAfter: index - 1)
        // `i` is the first segment ending at or after `index`; one that starts right there wins.
        while i + 1 < ranges.count, NSMaxRange(ranges[i]) == index, ranges[i + 1].location == index { i += 1 }
        guard i < ranges.count, ranges[i].location <= index, index <= NSMaxRange(ranges[i]) else { return nil }
        return (i, index - ranges[i].location)
    }

    /// The document range of `range` local to segment `segment`. Nil when it doesn't fit in that segment.
    public func documentRange(segment: Int, _ range: NSRange) -> NSRange? {
        guard ranges.indices.contains(segment), range.location >= 0, range.length >= 0,
              NSMaxRange(range) <= ranges[segment].length else { return nil }
        return NSRange(location: ranges[segment].location + range.location, length: range.length)
    }

    /// The map after segment `segment` came to hold `text` (an edit inside it); later segments move along.
    public func replacing(segment: Int, with text: String) -> SegmentMap {
        guard segments.indices.contains(segment) else { return self }
        var s = segments
        s[segment] = text
        return SegmentMap(segments: s, separator: separator)
    }

    /// First segment whose end is after `index` (binary search); `ranges.count` when none.
    private func firstSegment(endingAfter index: Int) -> Int {
        var lo = 0, hi = ranges.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(ranges[mid]) <= index { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
