import Foundation

/// Fixes the user ignored (⇥), so a later check doesn't bring them back (Milestone B: the automatic check
/// runs again on every typing pause, and the sentence cache returns the same fixes).
///
/// A fix is remembered with its sentence: the trimmed text of the sentences the edit touches, the edit's
/// offset in them, and the original and replacement. The same fix in the same sentence stays ignored
/// wherever the sentence moves in the field; once the sentence changes, the fix may come back (the context
/// it was ignored in is gone).
///
/// Memory only, never written anywhere; the oldest entries go past `capacity`.
public struct IgnoredFixes: Sendable, Equatable {
    public var capacity: Int
    private var keys: Set<String> = []
    private var order: [String] = []

    public init(capacity: Int = 1000) {
        self.capacity = capacity
    }

    public var count: Int { keys.count }

    public mutating func add(_ edit: Edit, in text: String) {
        guard let k = Self.key(edit, in: text), keys.insert(k).inserted else { return }
        order.append(k)
        if order.count > capacity {
            let drop = order.count - capacity
            for old in order.prefix(drop) { keys.remove(old) }
            order.removeFirst(drop)
        }
    }

    public func contains(_ edit: Edit, in text: String) -> Bool {
        guard !keys.isEmpty, let k = Self.key(edit, in: text) else { return false }
        return keys.contains(k)
    }

    /// `edits` (relative to `text`) without the ignored ones.
    public func filter(_ edits: [Edit], in text: String) -> [Edit] {
        keys.isEmpty ? edits : edits.filter { !contains($0, in: text) }
    }

    public mutating func removeAll() {
        keys.removeAll()
        order.removeAll()
    }

    /// Sentence text, offset in it, original, replacement. Nil when the range is outside `text`.
    static func key(_ edit: Edit, in text: String) -> String? {
        let ns = text as NSString
        let r = edit.range
        guard r.location >= 0, NSMaxRange(r) <= ns.length else { return nil }
        let context = sentenceRange(around: r, in: ns)
        let sentence = ns.substring(with: context)
        let sep = "\u{1F}"
        return sentence + sep + String(r.location - context.location) + sep + edit.original + sep + edit.replacement
    }

    /// The trimmed union of the sentences `range` touches (an insertion: the sentence it sits in or ends).
    static func sentenceRange(around range: NSRange, in ns: NSString) -> NSRange {
        let paragraph = ns.paragraphRange(for: range)
        var union: NSRange?
        ns.enumerateSubstrings(in: paragraph, options: [.bySentences, .substringNotRequired]) { _, s, _, _ in
            let touches = range.length > 0
                ? NSIntersectionRange(s, range).length > 0
                : (range.location >= s.location && range.location <= NSMaxRange(s))
            if touches { union = union.map { NSUnionRange($0, s) } ?? s }
        }
        var u = union ?? paragraph
        // Every touched sentence must include the edit itself (a range across a sentence's trailing space).
        u = NSUnionRange(u, range)
        // Trim whitespace and newlines at both ends, but never past the edit.
        let ws = CharacterSet.whitespacesAndNewlines
        var start = u.location, end = NSMaxRange(u)
        while start < range.location, let c = Unicode.Scalar(ns.character(at: start)), ws.contains(c) { start += 1 }
        while end > NSMaxRange(range), let c = Unicode.Scalar(ns.character(at: end - 1)), ws.contains(c) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }
}
