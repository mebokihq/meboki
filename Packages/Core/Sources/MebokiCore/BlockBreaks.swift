import Foundation

/// A field's value with a `\n` put back between blocks the app joined with nothing.
///
/// Gecko (Firefox) reports a multi-paragraph `contenteditable` as one value with no separator between its `<p>`
/// blocks ("…we expected.This is paragraph 23…", probed 2026-11-22 on telegra.ph). Checked like that, the model
/// sees joined sentences and words, and an Apply all group can reach over several blocks, which a paste then merges
/// into one paragraph. This map gives the check a text (`text`) with a `\n` at each such joint (`breaks`, offsets in
/// the real value) and maps ranges between the two. All offsets are UTF-16.
public struct BlockBreaks: Equatable, Sendable {
    /// The field's real value.
    public let real: String
    /// Offsets in `real` where a `\n` is added: sorted, unique, inside `0...real.length`.
    public let breaks: [Int]
    /// `real` with a `\n` at every break.
    public let text: String

    public init(real: String, breaks: [Int]) {
        let length = (real as NSString).length
        let clean = Array(Set(breaks.filter { $0 > 0 && $0 < length })).sorted()
        self.real = real
        self.breaks = clean
        let out = NSMutableString(string: real)
        for b in clean.reversed() { out.insert("\n", at: b) }
        text = out as String
    }

    /// The breaks between blocks with no line break between them in `real`: `blocks` are the blocks' ranges in
    /// `real`, in document order (nil for a block with no text found). A break goes at the end of a block when what
    /// follows up to the next block holds no line break: nothing (two `<p>` side by side), or characters no block
    /// covers, such as a list bullet ("• ") that Gecko puts in the value but reports with no text. A block followed
    /// by a `\n` of the app's own (an empty paragraph, a `<br>`) needs none.
    public static func breaks(between blocks: [NSRange?], in real: String) -> [Int] {
        let found = blocks.compactMap { $0 }.filter { $0.length > 0 }
        guard found.count > 1 else { return [] }
        let ns = real as NSString
        var out: [Int] = []
        for (a, b) in zip(found, found.dropFirst()) where NSMaxRange(a) <= b.location {
            let gap = ns.substring(with: NSRange(location: NSMaxRange(a), length: b.location - NSMaxRange(a)))
            if gap.rangeOfCharacter(from: .newlines) == nil { out.append(NSMaxRange(a)) }
        }
        return out
    }

    /// Where the added `\n` of break `k` sits in `text`.
    private func separatorIndex(_ k: Int) -> Int { breaks[k] + k }

    /// `text` offset → `real` offset. An offset right before or right after an added `\n` maps to the break.
    public func realOffset(_ v: Int) -> Int {
        var count = 0
        for k in breaks.indices where separatorIndex(k) < v { count += 1 }
        return v - count
    }

    /// `real` offset → `text` offset. A break offset maps to the end of the block before it (before the `\n`).
    public func textOffset(_ r: Int) -> Int {
        r + breaks.filter { $0 < r }.count
    }

    /// `range` of `text` in `real`, or nil when it holds an added `\n` (it reaches over a block break).
    public func realRange(_ range: NSRange) -> NSRange? {
        for k in breaks.indices {
            let s = separatorIndex(k)
            if s >= range.location && s < NSMaxRange(range) { return nil }
        }
        let start = realOffset(range.location)
        return NSRange(location: start, length: range.length)
    }

    /// `range` of `real` in `text` (a range over a break takes the added `\n` in).
    public func textRange(_ range: NSRange) -> NSRange {
        // A non-empty range starting at a break starts in the next block, after the added `\n`.
        let start = textOffset(range.location) + (range.length > 0 && breaks.contains(range.location) ? 1 : 0)
        let end = range.length == 0 ? start : textOffset(NSMaxRange(range) - 1) + 1
        return NSRange(location: start, length: end - start)
    }

    /// `range` of `text` split at the added `\n`s, as ranges of `real` (the `\n`s left out).
    public func realPieces(_ range: NSRange) -> [NSRange] {
        var pieces: [NSRange] = []
        var start = range.location
        let end = NSMaxRange(range)
        for k in breaks.indices {
            let s = separatorIndex(k)
            guard s >= start, s < end else { continue }
            if s > start, let r = realRange(NSRange(location: start, length: s - start)) { pieces.append(r) }
            start = s + 1
        }
        if end > start, let r = realRange(NSRange(location: start, length: end - start)) { pieces.append(r) }
        if pieces.isEmpty, range.length == 0, let r = realRange(range) { pieces.append(r) }
        return pieces
    }

    /// An edit of `text` turned into one the app writes into the right block: an insertion right at a block
    /// break (a full stop added at a paragraph's end) is ambiguous in `real`, where the end of one block and the
    /// start of the next are the same offset, so it takes the character before it (or, at a block's start, the
    /// one after it) along. Nil when the edit reaches over a break.
    public func writable(_ range: NSRange, original: String, replacement: String)
        -> (range: NSRange, original: String, replacement: String)? {
        let ns = text as NSString
        var range = range, original = original, replacement = replacement
        if range.length == 0 {
            let seps = Set(breaks.indices.map(separatorIndex))
            if seps.contains(range.location), range.location > 0, !seps.contains(range.location - 1) {
                // At a block's end: take the last character of that block along.
                let prev = ns.rangeOfComposedCharacterSequence(at: range.location - 1)
                let ch = ns.substring(with: prev)
                range = NSRange(location: prev.location, length: prev.length)
                original = ch
                replacement = ch + replacement
            } else if seps.contains(range.location - 1), range.location < ns.length, !seps.contains(range.location) {
                // At a block's start: take its first character along.
                let next = ns.rangeOfComposedCharacterSequence(at: range.location)
                let ch = ns.substring(with: next)
                range = next
                original = ch
                replacement = replacement + ch
            }
        }
        guard let r = realRange(range) else { return nil }
        return (r, original, replacement)
    }
}
