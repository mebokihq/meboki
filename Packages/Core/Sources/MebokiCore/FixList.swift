import Foundation

public enum FixStatus: Sendable, Equatable {
    case pending, applied, skipped
}

/// One proposed fix in a check session.
///
/// `edit.range` is always relative to the session's *current* text (`FixList.text`), in UTF-16.
/// For a pending or skipped fix it covers `edit.original`; for an applied fix it starts where
/// `edit.replacement` now sits (see `currentRange`).
public struct Fix: Equatable, Sendable {
    public var edit: Edit
    public var category: FixCategory
    public var reason: String
    public var status: FixStatus

    public init(edit: Edit, category: FixCategory, reason: String, status: FixStatus = .pending) {
        self.edit = edit
        self.category = category
        self.reason = reason
        self.status = status
    }

    /// The UTF-16 range this fix occupies in the current text: the original while pending or
    /// skipped, the replacement once applied (for the applied-word flash).
    public var currentRange: NSRange {
        status == .applied
            ? NSRange(location: edit.range.location, length: edit.replacement.utf16.count)
            : edit.range
    }
}

/// The fixes of one check, in reading order, applied in any order (design_code.md §5.1).
///
/// The list only tracks state. The app writes each fix to the field (`AX.replace`) and calls
/// `applyOne(at:)` when the write succeeded, so the model always matches what is in the field.
/// Applying a fix shifts the ranges of every later fix by `replacement.utf16.count − range.length`;
/// earlier fixes never move.
public struct FixList: Equatable, Sendable {
    /// The checked text with every applied fix written in.
    public private(set) var text: String
    /// Reading order. Ranges are relative to `text`.
    public private(set) var fixes: [Fix]
    /// Index into `fixes` of the fix the popup or island shows. Always a pending fix; nil when none is left.
    public private(set) var current: Int?

    /// Builds the list from diff edits against `text`. Edits are sorted; an edit that overlaps the
    /// one before it, lies outside the text, or whose `original` doesn't match the text at its range
    /// is dropped, so nothing unverified is ever offered.
    public init(text: String, edits: [Edit]) {
        self.text = text
        let ns = text as NSString
        var kept: [Fix] = []
        var lastEnd = 0
        for e in edits.sorted(by: { $0.range.location < $1.range.location }) {
            guard e.range.location >= lastEnd, NSMaxRange(e.range) <= ns.length,
                  ns.substring(with: e.range) == e.original,
                  e.original != e.replacement else { continue }
            // Two insertions at the same point would be ambiguous; keep the first.
            if let prev = kept.last, e.range.length == 0, prev.edit.range.length == 0,
               prev.edit.range.location == e.range.location { continue }
            let cat = FixClassifier.classify(e, in: text)
            kept.append(Fix(edit: e, category: cat, reason: FixClassifier.reason(for: e, category: cat, in: text)))
            lastEnd = NSMaxRange(e.range)
        }
        fixes = kept
        current = kept.isEmpty ? nil : 0
    }

    // MARK: - Counts

    public var pendingIndices: [Int] { fixes.indices.filter { fixes[$0].status == .pending } }
    public var pendingCount: Int { fixes.lazy.filter { $0.status == .pending }.count }
    /// Applied in this session, including fixes that later left the list (`textEdited`, `update`).
    public var appliedCount: Int { retiredApplied + fixes.lazy.filter { $0.status == .applied }.count }
    /// Skipped in this session, including fixes that later left the list.
    public var skippedCount: Int { retiredSkipped + fixes.lazy.filter { $0.status == .skipped }.count }
    /// Applied and skipped fixes no longer in `fixes`, counted for the done line.
    private var retiredApplied = 0
    private var retiredSkipped = 0
    public var isEmpty: Bool { fixes.isEmpty }
    /// No pending fix is left (the session goes to `done`).
    public var isDone: Bool { current == nil }
    public var currentFix: Fix? { current.map { fixes[$0] } }

    /// 1-based position of fix `index` among the pending fixes: the n in "n of N". Nil if not pending.
    public func pendingPosition(of index: Int) -> Int? {
        guard fixes.indices.contains(index), fixes[index].status == .pending else { return nil }
        return fixes[..<index].lazy.filter { $0.status == .pending }.count + 1
    }

    /// "n of N" for the current fix, or nil when none is pending.
    public var currentPosition: (n: Int, total: Int)? {
        guard let c = current, let n = pendingPosition(of: c) else { return nil }
        return (n, pendingCount)
    }

    // MARK: - Apply and skip

    /// What `text` becomes when fix `index` is applied, without changing the list. Nil if not pending.
    public func textApplying(_ index: Int) -> String? {
        guard fixes.indices.contains(index), fixes[index].status == .pending else { return nil }
        let e = fixes[index].edit
        return (text as NSString).replacingCharacters(in: e.range, with: e.replacement)
    }

    /// Marks fix `index` applied, writes it into `text` and shifts every later fix. Call after the
    /// field write succeeded. Returns the new text, or nil (and changes nothing) if the fix isn't pending.
    @discardableResult
    public mutating func applyOne(at index: Int) -> String? {
        guard let newText = textApplying(index) else { return nil }
        let e = fixes[index].edit
        let delta = e.replacement.utf16.count - e.range.length
        text = newText
        fixes[index].status = .applied
        for i in fixes.indices where i > index {
            fixes[i].edit.range.location += delta
        }
        advance(from: index)
        return newText
    }

    /// Marks fix `index` skipped. Writes nothing; ranges don't move. Returns false if it wasn't pending.
    @discardableResult
    public mutating func skip(at index: Int) -> Bool {
        guard fixes.indices.contains(index), fixes[index].status == .pending else { return false }
        fixes[index].status = .skipped
        advance(from: index)
        return true
    }

    /// Pending fixes in the order Apply all writes them: last to first, so writing one never moves
    /// the range of a fix still to be written.
    public func applyAllOrder() -> [Int] { pendingIndices.reversed() }

    /// Applies every pending fix in `applyAllOrder()` and returns the new text. For tests and
    /// previews; the app writes them one by one so it can stop when the field rejects a write.
    @discardableResult
    public mutating func applyAll() -> String {
        for i in applyAllOrder() { applyOne(at: i) }
        return text
    }

    // MARK: - Apply all in groups (Optimization A)

    /// Pending fixes written to the field as one write: `range` of `text` holds `original` and becomes
    /// `replacement` (the text between the fixes is copied as it is).
    public struct ApplyGroup: Equatable, Sendable {
        /// Fix indices, in reading order.
        public var indices: [Int]
        public var range: NSRange
        public var original: String
        public var replacement: String
    }

    /// Pending fixes grouped for Apply all, last group first, so writing one group never moves the range of a
    /// group still to be written. Neighbouring pending fixes share a group when the text between them stays in
    /// one paragraph (no line break, no object replacement character), the group's span stays within `maxSpan`
    /// UTF-16 units, and `canJoin` accepts the span (the app proves it's one run of formatting, so a plain-text
    /// write can't drop a link or bold in between). Every other fix is a group of its own.
    public func applyAllGroups(maxSpan: Int = 400, canJoin: (NSRange) -> Bool) -> [ApplyGroup] {
        let ns = text as NSString
        var groups: [[Int]] = []
        for i in pendingIndices {
            if let last = groups.last, let first = last.first {
                let start = fixes[first].edit.range.location
                let prevEnd = NSMaxRange(fixes[last.last!].edit.range)
                let end = NSMaxRange(fixes[i].edit.range)
                let gap = NSRange(location: prevEnd, length: max(0, fixes[i].edit.range.location - prevEnd))
                let span = NSRange(location: start, length: end - start)
                if span.length <= maxSpan, !Self.breaksParagraph(ns.substring(with: gap)), canJoin(span) {
                    groups[groups.count - 1].append(i)
                    continue
                }
            }
            groups.append([i])
        }
        return groups.reversed().map { idx in
            let start = fixes[idx.first!].edit.range.location
            let span = NSRange(location: start, length: NSMaxRange(fixes[idx.last!].edit.range) - start)
            // Front to back, so an insertion right before a replacement keeps its place.
            var replacement = "", pos = start
            for i in idx {
                let e = fixes[i].edit
                replacement += ns.substring(with: NSRange(location: pos, length: e.range.location - pos)) + e.replacement
                pos = NSMaxRange(e.range)
            }
            return ApplyGroup(indices: idx, range: span, original: ns.substring(with: span), replacement: replacement)
        }
    }

    /// Marks every fix of `group` applied (call after the group's write succeeded). Returns the new text, or
    /// nil (changing nothing) when a fix of the group is no longer pending.
    @discardableResult
    public mutating func applyGroup(_ group: ApplyGroup) -> String? {
        guard group.indices.allSatisfy({ fixes.indices.contains($0) && fixes[$0].status == .pending }) else { return nil }
        for i in group.indices.reversed() { applyOne(at: i) }
        return text
    }

    private static func breaksParagraph(_ gap: String) -> Bool {
        gap.unicodeScalars.contains { CharacterSet.newlines.contains($0) || $0 == "\u{FFFC}" }
    }

    // MARK: - Live review (Milestone B)

    /// The user edited the text: `change` is relative to `text`. Fixes before the change stay and fixes after
    /// it move by `change.delta`. These leave the list (their text or context is no longer what the model saw;
    /// the next check brings back the ones still right):
    /// - every pending fix in a sentence the change touches (a fix can depend on the rest of the sentence:
    ///   "a apple" → "a pear");
    /// - any fix the change touches: overlaps it, or sits right next to it. Typing a space or punctuation
    ///   right after or before a fixed word doesn't touch it; typing a letter there does (the word grew).
    ///   An insertion fix (an added comma) is touched by anything at its point.
    /// Returns where each kept fix went (old index → new index), or nil, changing nothing, when `change`
    /// doesn't fit `text`. Fixes missing from the map left the list.
    @discardableResult
    public mutating func textEdited(_ change: TextChange) -> [Int: Int]? {
        let ns = text as NSString
        guard change.range.location >= 0, NSMaxRange(change.range) <= ns.length else { return nil }
        let c = change.range
        let sentences = CheckPipeline.sentences(in: ns, range: ns.paragraphRange(for: c))
            .filter { Self.touchesSentence(change, $0) }
        let old = current.map { (index: $0, location: fixes[$0].edit.range.location) }
        var kept: [Fix] = []
        var newIndex: [Int: Int] = [:]
        for (i, var f) in fixes.enumerated() {
            let r = f.currentRange
            let inEditedSentence = f.status == .pending && sentences.contains { Self.overlaps($0, r) }
            if inEditedSentence || Self.touches(change, r) {
                if f.status == .applied { retiredApplied += 1 }
                if f.status == .skipped { retiredSkipped += 1 }
                continue
            }
            if r.location >= NSMaxRange(c) { f.edit.range.location += change.delta }
            newIndex[i] = kept.count
            kept.append(f)
        }
        text = ns.replacingCharacters(in: c, with: change.replacement)
        fixes = kept
        if let old {
            let at = old.location >= NSMaxRange(c) ? old.location + change.delta : old.location
            current = newIndex[old.index] ?? nearestPending(to: at)
        }
        return newIndex
    }

    /// A check of the current `text` (or part of it) came back. Inside the `covered` ranges (the paragraphs
    /// it checked) the list now matches `edits`: a pending fix the check found again stays as it is (status,
    /// `current`), one it didn't find goes, and new edits are added as pending. Outside them nothing changes,
    /// so a partial result never wipes fixes elsewhere. A skipped fix stays, and no edit overlapping it is
    /// offered (the user ignored that spot). Applied fixes in covered paragraphs become counts (their flash
    /// is over). Edits outside `covered` are ignored.
    public mutating func reconcile(edits: [Edit], covered: [NSRange]) {
        func inCovered(_ r: NSRange) -> Bool {
            covered.contains { r.location >= $0.location && NSMaxRange(r) <= NSMaxRange($0) }
        }
        let old = current.map { fixes[$0] }
        var kept: [Fix] = []
        for f in fixes {
            guard inCovered(f.currentRange) else { kept.append(f); continue }
            switch f.status {
            case .applied: retiredApplied += 1
            case .skipped: kept.append(f)
            case .pending: if edits.contains(f.edit) { kept.append(f) }
            }
        }
        let added = edits.filter { e in
            inCovered(e.range) && !kept.contains { $0.edit == e || Self.overlaps($0.currentRange, e.range) }
        }
        let fresh = FixList(text: text, edits: added).fixes
        fixes = (kept + fresh).sorted { $0.edit.range.location < $1.edit.range.location }
        if let old, let i = fixes.firstIndex(where: { $0.status == .pending && $0.edit == old.edit }) {
            current = i
        } else {
            current = nearestPending(to: old?.edit.range.location ?? 0)
        }
    }

    /// The first pending fix at or after `location`, else the last pending fix, else nil.
    private func nearestPending(to location: Int) -> Int? {
        let p = pendingIndices
        return p.first { fixes[$0].edit.range.location >= location } ?? p.last
    }

    /// True when `change` touches fix range `r`: overlaps it, or sits right next to it. A pure insertion at the
    /// edge of a fix that spans text only touches it when it continues the word there.
    static func touches(_ change: TextChange, _ r: NSRange) -> Bool {
        let c = change.range
        guard c.location <= NSMaxRange(r), NSMaxRange(c) >= r.location else { return false }
        guard c.length == 0, r.length > 0, !change.replacement.isEmpty else { return true }
        if c.location == NSMaxRange(r) { return change.replacement.first.map(FixDisplay.isWordCharacter) ?? true }
        if c.location == r.location { return change.replacement.last.map(FixDisplay.isWordCharacter) ?? true }
        return true
    }

    /// True when `change` edits sentence `s` (trimmed): overlaps it or sits right next to it, except a pure
    /// insertion that starts a new sentence before it or after it (ends or starts with whitespace).
    static func touchesSentence(_ change: TextChange, _ s: NSRange) -> Bool {
        let c = change.range
        guard c.location <= NSMaxRange(s), NSMaxRange(c) >= s.location else { return false }
        guard c.length == 0, let first = change.replacement.first, let last = change.replacement.last else { return true }
        if c.location == NSMaxRange(s) { return !first.isWhitespace }
        if c.location == s.location { return !last.isWhitespace }
        return true
    }

    /// Ranges share a character, or one is an insertion point inside or at the edge of the other.
    static func overlaps(_ a: NSRange, _ b: NSRange) -> Bool {
        if a.length == 0 || b.length == 0 {
            return a.location <= NSMaxRange(b) && b.location <= NSMaxRange(a)
        }
        return max(a.location, b.location) < min(NSMaxRange(a), NSMaxRange(b))
    }

    // MARK: - Navigation

    /// Index of the next pending fix after `index` in reading order, or nil.
    public func next(after index: Int) -> Int? {
        fixes.indices.first { $0 > index && fixes[$0].status == .pending }
    }

    /// Index of the previous pending fix before `index` in reading order, or nil.
    public func previous(before index: Int) -> Int? {
        fixes.indices.last { $0 < index && fixes[$0].status == .pending }
    }

    /// Moves `current` to the next pending fix. Stops at the last one (no wrap). Returns true if it moved.
    @discardableResult
    public mutating func selectNext() -> Bool {
        guard let c = current, let n = next(after: c) else { return false }
        current = n
        return true
    }

    /// Moves `current` to the previous pending fix. Stops at the first one (no wrap). Returns true if it moved.
    @discardableResult
    public mutating func selectPrevious() -> Bool {
        guard let c = current, let p = previous(before: c) else { return false }
        current = p
        return true
    }

    /// Makes fix `index` current (a click on its underline). Returns false if it isn't pending.
    @discardableResult
    public mutating func select(_ index: Int) -> Bool {
        guard fixes.indices.contains(index), fixes[index].status == .pending else { return false }
        current = index
        return true
    }

    /// After fix `index` stops being pending: if it was current, move to the next pending fix in
    /// reading order, else the previous one, else nil (done).
    private mutating func advance(from index: Int) {
        guard let c = current else { return }
        if fixes[c].status == .pending { return }
        current = next(after: index) ?? previous(before: index)
    }
}

// MARK: - Display

/// What a popup shows for one fix: "old → new", trimmed. An empty `new` is a deletion, an empty `old` an insertion.
public struct FixSwap: Equatable, Sendable {
    public var old: String
    public var new: String

    public init(old: String, new: String) {
        self.old = old
        self.new = new
    }
}

public enum FixDisplay {
    /// The swap for `edit`, whose range is relative to `text`. When neither side has a letter or digit
    /// (an added comma, a removed full stop), the word the change touches is added to both sides, so an
    /// inserted comma reads "Hello → Hello," instead of "+ ,".
    public static func swap(for edit: Edit, in text: String) -> FixSwap {
        var old = edit.original, new = edit.replacement
        if !hasWordCharacter(old), !hasWordCharacter(new) {
            let ns = text as NSString
            let start = min(max(0, edit.range.location), ns.length)
            let end = min(max(start, NSMaxRange(edit.range)), ns.length)
            let left = String(String(ns.substring(to: start).reversed().prefix(while: isWordCharacter)).reversed())
            if !left.isEmpty {
                old = left + old
                new = left + new
            } else {
                let right = String(ns.substring(from: end).prefix(while: isWordCharacter))
                old += right
                new += right
            }
        }
        let ws = CharacterSet.whitespacesAndNewlines
        return FixSwap(old: old.trimmingCharacters(in: ws), new: new.trimmingCharacters(in: ws))
    }

    /// The UTF-16 range to underline (or flash) for the span `range` of `text`: the span trimmed of
    /// whitespace. When it has no letter or digit (an insertion, an added comma, a removed full stop, an
    /// extra space), the word it touches is included, the one on the left first, like `swap`, so there is
    /// always something visible to click. Empty only when there is no word next to it either.
    public static func markRange(_ range: NSRange, in text: String) -> NSRange {
        let ns = text as NSString
        let start = min(max(0, range.location), ns.length)
        let end = min(max(start, NSMaxRange(range)), ns.length)
        var lo = start, hi = end
        if !hasWordCharacter(ns.substring(with: NSRange(location: start, length: end - start))) {
            let left = String(String(ns.substring(to: start).reversed().prefix(while: isWordCharacter)).reversed())
            if !left.isEmpty {
                lo = start - left.utf16.count
            } else {
                hi = end + String(ns.substring(from: end).prefix(while: isWordCharacter)).utf16.count
            }
        }
        // Trim whitespace on both sides (whole composed characters, so emoji stay intact).
        let ws = CharacterSet.whitespacesAndNewlines
        func isSpace(_ r: NSRange) -> Bool {
            ns.substring(with: r).unicodeScalars.allSatisfy { ws.contains($0) }
        }
        while lo < hi {
            let r = ns.rangeOfComposedCharacterSequence(at: lo)
            guard isSpace(r) else { break }
            lo = min(hi, NSMaxRange(r))
        }
        while hi > lo {
            let r = ns.rangeOfComposedCharacterSequence(at: hi - 1)
            guard isSpace(r) else { break }
            hi = max(lo, r.location)
        }
        return NSRange(location: lo, length: hi - lo)
    }

    static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "'" || c == "’" }
    static func hasWordCharacter(_ s: String) -> Bool { s.contains { $0.isLetter || $0.isNumber } }
}

extension FixList {
    /// The swap the popup shows for fix `index`, against the current `text`.
    public func swap(at index: Int) -> FixSwap? {
        guard fixes.indices.contains(index) else { return nil }
        return FixDisplay.swap(for: fixes[index].edit, in: text)
    }

    /// The range of `text` to underline for fix `index`: its original while pending or skipped, its
    /// replacement once applied (for the applied-word flash). See `FixDisplay.markRange`.
    public func markRange(at index: Int) -> NSRange? {
        guard fixes.indices.contains(index) else { return nil }
        return FixDisplay.markRange(fixes[index].currentRange, in: text)
    }
}
