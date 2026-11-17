import Foundation

/// One contiguous change between two versions of a field's text (UTF-16), found by the common prefix and
/// suffix. Typing, a paste or a deletion is one change; several edits far apart collapse into one change
/// that covers all of them, which only makes the review drop more fixes, never keep a wrong one.
public struct TextChange: Equatable, Sendable {
    /// The replaced range in the old text.
    public var range: NSRange
    /// What the new text has there.
    public var replacement: String

    public init(range: NSRange, replacement: String) {
        self.range = range
        self.replacement = replacement
    }

    /// How much later text moved: `replacement` length − `range` length.
    public var delta: Int { replacement.utf16.count - range.length }

    /// The change that turns `old` into `new`, or nil when they're equal. Never splits a surrogate pair.
    public static func between(_ old: String, _ new: String) -> TextChange? {
        let a = Array(old.utf16), b = Array(new.utf16)
        guard a != b else { return nil }
        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        var s = 0
        while s < a.count - p, s < b.count - p, a[a.count - 1 - s] == b[b.count - 1 - s] { s += 1 }
        if p > 0, UTF16.isLeadSurrogate(a[p - 1]) { p -= 1 }
        if s > 0, UTF16.isTrailSurrogate(a[a.count - s]) { s -= 1 }
        return TextChange(range: NSRange(location: p, length: a.count - p - s),
                          replacement: String(decoding: b[p..<(b.count - s)], as: UTF16.self))
    }
}
