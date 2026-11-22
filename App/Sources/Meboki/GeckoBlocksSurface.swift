import AppKit
import ApplicationServices
import MebokiCore

/// A Gecko (Firefox) rich editor whose value joins its paragraphs with nothing between them.
///
/// Gecko reports a `contenteditable` (`AXTextArea`, subrole `AXApplicationGroup`) as one value, but puts no `\n`
/// between its `<p>` blocks ("…we expected.This is paragraph 23…", telegra.ph, probed 2026-11-22). The model then
/// sees joined sentences, and an Apply all group reached over eight paragraphs, which the paste merged into one. This
/// surface is the one field (`SingleFieldSurface`) with a `\n` put back between blocks that touch (`BlockBreaks`):
/// every range is mapped to the real value before it reaches `AX`, and a write never reaches over a block break.
///
/// Only Gecko gets it: every other engine reports its blocks with a separator and keeps its own path unchanged.
final class GeckoBlocksSurface: TextSurface {
    let element: AXUIElement
    private let inner: SingleFieldSurface
    /// The breaks for the last value read.
    private var cache: BlockBreaks?

    init(_ element: AXUIElement) {
        self.element = element
        inner = SingleFieldSurface(element)
    }

    /// The breaks for the field's value now (the tree is walked again only when the value changed).
    private func current() -> BlockBreaks? {
        guard let real = AX.text(element) else { return nil }
        if let cache, cache.real == real { return cache }
        let map = BlockBreaks(real: real, breaks: BlockBreaks.breaks(between: Self.blockRanges(of: element, value: real),
                                                                     in: real))
        cache = map
        return map
    }

    /// The breaks whose `text` is `text` (the caller's last read), read again once when the field changed since.
    private func map(for text: String) -> BlockBreaks? {
        if let cache, cache.text == text { return cache }
        guard let m = current(), m.text == text else { return nil }
        return m
    }

    var anchor: AXUIElement { element }
    var valueElements: [AXUIElement] { inner.valueElements }
    var lifeElements: [AXUIElement] { inner.lifeElements }
    var placesCaretAfterReview: Bool { inner.placesCaretAfterReview }

    func text() -> String? { current()?.text }

    func selection() -> NSRange? {
        guard let r = inner.selection(), let m = current() else { return nil }
        return m.textRange(r)
    }

    func select(_ range: NSRange, in text: String) -> Bool {
        guard let m = map(for: text), let r = m.realRange(range) else { return false }
        return AX.select(element, r, in: m.real)
    }

    func bounds(_ range: NSRange, text: String) -> CGRect? {
        guard let m = map(for: text) else { return nil }
        let rects = m.realPieces(range).compactMap { AX.bounds(element, $0, text: m.real) }
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    func lineRects(_ range: NSRange, in text: String) -> [CGRect]? {
        guard let m = map(for: text) else { return nil }
        let rects = m.realPieces(range).flatMap { AX.lineRects(element, range: $0, in: m.real) ?? [] }
        return rects.isEmpty ? nil : rects
    }

    func hasTextBounds(text: String, visible: NSRange?) -> Bool {
        guard let m = map(for: text) else { return false }
        let v = visible.map { r -> NSRange in
            let start = m.realOffset(r.location)
            return NSRange(location: start, length: m.realOffset(NSMaxRange(r)) - start)
        }
        return AX.hasTextBounds(element, text: m.real, visible: v)
    }

    func visibleCharacterRange() -> NSRange? {
        guard let r = inner.visibleCharacterRange(), let m = current() else { return nil }
        return m.textRange(r)
    }

    func visibleFrame() -> CGRect? { inner.visibleFrame() }
    func frame() -> CGRect? { inner.frame() }

    func isOneTextRun(_ range: NSRange, text: String) -> Bool {
        guard let m = map(for: text), let r = m.realRange(range) else { return false }
        return AX.isOneTextRun(element, r, text: m.real)
    }

    /// Mapped onto the field's value as it is now; `AX.replace` then checks the original is still there, as for any
    /// field. An insertion at a block break takes a neighbouring character along so it lands in the right block.
    func replace(pid: pid_t, range: NSRange, original: String, replacement: String, expected: String,
                 pasteOnly: Bool, beforeKeystroke: () -> Void) -> Bool {
        let tag = "edit @\(range.location)+\(range.length) \(Log.pair(original, replacement))"
        guard let m = current() else {
            Log.write("\(tag): can't read the field")
            return false
        }
        guard let w = m.writable(range, original: original, replacement: replacement) else {
            Log.write("\(tag): the range reaches over a paragraph break; not written")
            return false
        }
        return inner.replace(pid: pid, range: w.range, original: w.original, replacement: w.replacement,
                             expected: m.real, pasteOnly: pasteOnly, beforeKeystroke: beforeKeystroke)
    }

    var textFollowsScroll: Bool { inner.textFollowsScroll }
    func carry(_ list: inout FixList, to now: String) -> [Int: Int]? { nil }
    func learnTextFollowsScroll() { inner.learnTextFollowsScroll() }

    func owns(_ el: AXUIElement) -> Bool { inner.owns(el) }
    func isFocused(pid: pid_t) -> Bool { inner.isFocused(pid: pid) }
    var isSecure: Bool { inner.isSecure }
    var settlesLate: Bool { inner.settlesLate }
    var skipsUntouchedFailuresInApplyAll: Bool { inner.skipsUntouchedFailuresInApplyAll }
    var lastWriteLeftFieldUntouched: Bool { inner.lastWriteLeftFieldUntouched }

    func writableEdits(_ edits: [Edit], in text: String, scopeLocation: Int) -> [Edit] {
        inner.writableEdits(edits, in: text, scopeLocation: scopeLocation)
    }

    // MARK: Blocks

    /// Stands in for a list bullet with no text: four noncharacters, never in a field's value, so it never matches
    /// and lets the next leaf skip a bullet of up to four characters ("• ", "10. ").
    private static let unknownMarker = String(repeating: "\u{FFFF}", count: 4)

    /// Each block's range in `value`: the field's children are its blocks (a list's items count one by one), and a
    /// block covers its text leaves, lined up with the value (`TextLeafMap`). Nil for a block with no leaf found.
    static func blockRanges(of el: AXUIElement, value: String, limit: Int = 4000) -> [NSRange?] {
        var visited = 0
        func leaves(_ node: AXUIElement, depth: Int, into out: inout [String]) {
            guard visited < limit, depth < 64 else { return }
            visited += 1
            let role = AX.string(node, kAXRoleAttribute) ?? ""
            if role == (kAXStaticTextRole as String) {
                out.append(AX.string(node, kAXValueAttribute) ?? "")
                return
            }
            if role == "AXListMarker" {
                // Gecko puts the bullet ("• ", "1. ") in the value but reports its marker with no text (test page,
                // 2026-11-22). A leaf that can't match stands in for it: `TextLeafMap` then lets the next leaf skip
                // up to that many characters, so the bullet doesn't stop the matching of every block after it.
                let text = AX.string(node, kAXValueAttribute) ?? ""
                out.append(text.isEmpty ? Self.unknownMarker : text)
                return
            }
            for child in (AX.copy(node, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                leaves(child, depth: depth + 1, into: &out)
            }
        }
        var blocks: [[String]] = []
        for child in (AX.copy(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
            if AX.string(child, kAXRoleAttribute) == (kAXListRole as String) {
                for item in (AX.copy(child, kAXChildrenAttribute) as? [AXUIElement]) ?? [] {
                    var out: [String] = []
                    leaves(item, depth: 2, into: &out)
                    blocks.append(out)
                }
            } else {
                var out: [String] = []
                leaves(child, depth: 1, into: &out)
                blocks.append(out)
            }
        }
        var owner: [Int] = []
        for (b, texts) in blocks.enumerated() { owner += Array(repeating: b, count: texts.count) }
        let map = TextLeafMap(value: value, leaves: blocks.flatMap { $0 })
        var ranges = [NSRange?](repeating: nil, count: blocks.count)
        for seg in map.segments {
            let b = owner[seg.leaf]
            ranges[b] = ranges[b].map { NSUnionRange($0, seg.range) } ?? seg.range
        }
        return ranges
    }
}

/// Gecko rich editors (`contenteditable`: `AXTextArea` with subrole `AXApplicationGroup`) get `GeckoBlocksSurface`.
/// The engine is checked, not the site: Firefox joins `<p>` blocks with nothing in any rich editor, and no other
/// engine does, so every other app keeps its old surface.
struct GeckoBlocksStrategy: SurfaceStrategy {
    var name: String { "gecko blocks" }

    func surface(for focused: AXUIElement, pid: pid_t) -> TextSurface? {
        // Thunderbird is Gecko too, but tested and working as it is (its compose window ends lines in `\n`): left alone.
        guard AX.isGecko(pid: pid),
              NSRunningApplication(processIdentifier: pid)?.bundleIdentifier?.hasPrefix("org.mozilla.thunderbird") != true,
              AX.string(focused, kAXRoleAttribute) == "AXTextArea",
              AX.string(focused, kAXSubroleAttribute) == "AXApplicationGroup" else { return nil }
        return GeckoBlocksSurface(focused)
    }
}
