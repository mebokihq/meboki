import Foundation

/// Converts offsets between a field's text and the offsets WebKit 27 uses for its positions and selection.
///
/// Safari 27 (macOS 27.2.1, probed 2026-11-23 in a Proton Docs `contenteditable`) reports a multi-paragraph field's
/// `AXValue` with two `\n` between paragraphs (and `AXStringForRange` counts the same way), but `AXBoundsForRange`
/// and `AXSelectedTextRange` (read and set) count one: the offset for value index `i` is `i` minus half the line
/// breaks before it. Measured over 45 paragraphs, the shift was exactly `breaks / 2` at every paragraph start, so
/// underlines drifted right by one character per paragraph and a fix was pasted that far away. Safari 26 counts the
/// same way in all of them.
///
/// Each run of `n` consecutive `\n` in the value is `(n + 1) / 2` of them in WebKit's count (2 → 1, 4 → 2, an
/// empty paragraph between two others); a lone `\n` stays one. Everything else maps one to one.
public struct ParagraphBreakMap: Equatable, Sendable {
    /// A run of two or more `\n` in the value: where it starts in the value and in WebKit's count, and its length.
    struct Run: Equatable, Sendable {
        let value: Int
        let webKit: Int
        let length: Int
        var webKitLength: Int { (length + 1) / 2 }
    }

    let runs: [Run]
    /// UTF-16 length of the value.
    public let length: Int

    public init(text: String) {
        let units = Array(text.utf16)
        length = units.count
        var runs: [Run] = []
        var removed = 0
        var i = 0
        while i < units.count {
            guard units[i] == 0x0A else { i += 1; continue }
            var j = i
            while j < units.count, units[j] == 0x0A { j += 1 }
            let n = j - i
            if n >= 2 {
                runs.append(Run(value: i, webKit: i - removed, length: n))
                removed += n - (n + 1) / 2
            }
            i = j
        }
        self.runs = runs
    }

    /// True when the value has no run to collapse: both counts are the same.
    public var isIdentity: Bool { runs.isEmpty }

    /// WebKit's offset for value offset `i`.
    public func webKitIndex(_ i: Int) -> Int {
        var removed = 0
        for r in runs {
            if i <= r.value { break }
            let j = min(i - r.value, r.length)
            if j < r.length { return r.webKit + (j + 1) / 2 }
            removed += r.length - r.webKitLength
        }
        return i - removed
    }

    /// The value offset for WebKit offset `w`. Inside a collapsed run it lands on the matching `\n` pair.
    public func valueIndex(_ w: Int) -> Int {
        var added = 0
        for r in runs {
            if w <= r.webKit { break }
            let k = w - r.webKit
            if k < r.webKitLength { return r.value + min(2 * k, r.length) }
            added += r.length - r.webKitLength
        }
        return min(w + added, length)
    }

    public func webKitRange(_ r: NSRange) -> NSRange {
        let a = webKitIndex(r.location), b = webKitIndex(NSMaxRange(r))
        return NSRange(location: a, length: max(0, b - a))
    }

    public func valueRange(_ r: NSRange) -> NSRange {
        let a = valueIndex(r.location), b = valueIndex(NSMaxRange(r))
        return NSRange(location: a, length: max(0, b - a))
    }

    /// Paragraph starts to test the quirk on: value offsets right after a run, where the text starts with a
    /// letter or digit (not an indent or a list bullet), with the shift WebKit would have there. At most `limit`.
    public func paragraphStarts(in text: String, limit: Int = 3) -> [(index: Int, shift: Int)] {
        let ns = text as NSString
        var out: [(Int, Int)] = []
        for r in runs {
            let st = r.value + r.length
            guard st < ns.length, let scalar = UnicodeScalar(ns.character(at: st)),
                  CharacterSet.alphanumerics.contains(scalar) else { continue }
            out.append((st, st - webKitIndex(st)))
            if out.count == limit { break }
        }
        return out
    }
}
