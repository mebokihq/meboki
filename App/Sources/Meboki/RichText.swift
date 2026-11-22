import AppKit
import ApplicationServices
import MebokiCore

/// The text-marker adapter (Milestone B): reading, selecting and measuring text in web editors whose index-based
/// Accessibility API is missing or empty (PLAN.md §5).
///
/// - **Chromium and Electron `contenteditable`** (x.com, Gmail, Notion, Slack, Obsidian): `AXValue` and
///   `AXSelectedTextRange` work, but `AXBoundsForRange` on the field answers with a zero-size rect. Its
///   static-text leaves answer it with leaf-local ranges, so a field range is split over the leaves
///   (`TextLeafMap`). Chrome's own text markers don't help here: markers walked from the field give the field's
///   rect, `AXTextMarkerForIndex` counts from the top of the page, and the marker text has no `\n` between blocks.
/// - **WebKit editable web areas** (Mail compose, `designMode` pages): the focused element is the `AXWebArea`
///   itself, with an empty `AXValue` and no `AXSelectedTextRange`. The text comes from the element's marker
///   range; WebKit's `AXTextMarkerForIndex` / `AXIndexForTextMarker` count UTF-16 units from the start of it, so
///   selection goes through `AXSelectedTextMarkerRange` and bounds through `AXBoundsForRange` (it works there) or
///   `AXBoundsForTextMarkerRange`. Writing is select + paste: there is no `AXSelectedText` to set.
///
/// Probed 2026-11-16 in Chrome (contenteditable) and Safari (`designMode`, the same WebKit path as Mail).
extension AX {
    // MARK: Field text (any field)

    /// An editable WebKit web area (Mail compose): an `AXWebArea` whose value is settable. A web page that
    /// isn't editable reports a value that isn't.
    static func isEditableWebArea(_ el: AXUIElement) -> Bool {
        guard string(el, kAXRoleAttribute) == "AXWebArea" else { return false }
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success else { return false }
        return settable.boolValue
    }

    /// The field's text: `AXValue`, or for an editable web area the text of its marker range. Indices into it
    /// are what `selection`, `select` and `bounds` use.
    static func text(_ el: AXUIElement) -> String? {
        if isEditableWebArea(el) {
            guard let whole = param(el, "AXTextMarkerRangeForUIElement", el),
                  CFGetTypeID(whole) == AXTextMarkerRangeGetTypeID() else { return nil }
            return param(el, "AXStringForTextMarkerRange", whole) as? String
        }
        return string(el, kAXValueAttribute)
    }

    /// The selection (UTF-16, in `text(el)`): `AXSelectedTextRange`, or the selected marker range of an editable
    /// web area.
    static func selection(_ el: AXUIElement) -> NSRange? {
        if let r = selectedRange(el) { return r }
        guard isEditableWebArea(el), let sel = copy(el, "AXSelectedTextMarkerRange"),
              CFGetTypeID(sel) == AXTextMarkerRangeGetTypeID() else { return nil }
        let range = sel as! AXTextMarkerRange
        guard let a = index(el, of: AXTextMarkerRangeCopyStartMarker(range)),
              let b = index(el, of: AXTextMarkerRangeCopyEndMarker(range)), b >= a else { return nil }
        return NSRange(location: a, length: b - a)
    }

    /// Selects `range` of `text` (the field's text as just read) and proves it. With `AXSelectedText` readable,
    /// the selected text must be exactly what `text` has there; an empty range (a caret, an insertion) is proven
    /// by first selecting the character next to it. Otherwise the selection must read back as `range`.
    ///
    /// Chrome's `contenteditable` doesn't count `AXSelectedTextRange` offsets the way it counts `AXValue`: each list
    /// bullet shifts them, and far into a long field the setter does nothing. Its read-back still reports the range
    /// asked for (probed 2026-11-16), so only the selected text tells. When the index selection doesn't prove out
    /// there, the range is selected through text markers anchored on the leaves (`TextLeafMap`).
    /// False when no method could be proven: then nothing may be written.
    static func select(_ el: AXUIElement, _ range: NSRange, in text: String) -> Bool {
        let ns = text as NSString
        guard NSMaxRange(range) <= ns.length else { return false }
        // What to prove: the range itself, or for an empty range the character before it (or after it).
        var probe = range
        if range.length == 0 {
            if range.location > 0 {
                probe = ns.rangeOfComposedCharacterSequence(at: range.location - 1)
            } else if ns.length > 0 {
                probe = ns.rangeOfComposedCharacterSequence(at: 0)
            }
        }
        let expected = ns.substring(with: probe)
        let webArea = isEditableWebArea(el)
        let index: (NSRange) -> Bool = { r in setSelectedRange(el, r) }
        let leafMarkers: (NSRange) -> Bool = { r in leafMarkerRange(el, r, text: text).map { setSelectedMarkers(el, $0) } ?? false }
        // A field where index selection was already off goes to the markers first (each failed proof waits 0.3 s).
        let markersFirst = LeafCache.shared.indexSelectionOff(el)
        let methods: [(NSRange) -> Bool] = webArea
            ? [{ r in markerRange(el, r).map { setSelectedMarkers(el, $0) } ?? false }]
            : markersFirst ? [leafMarkers, index] : [index, leafMarkers]
        for (i, method) in methods.enumerated() {
            guard method(probe), selectionShows(el, probe, expected) else { continue }
            // The probe proved this method's offsets right next to `range` (the read-back can't: Chrome reports
            // its own shifted offsets).
            if probe == range || method(range) {
                if !webArea, !markersFirst, i > 0 {
                    LeafCache.shared.setIndexSelectionOff(el)
                    Log.write("select @\(range.location)+\(range.length): index selection was off; text markers from now on in this field")
                }
                return true
            }
        }
        return false
    }

    /// The app's selection is `probe`, whose text is `expected`: by `AXSelectedText` when the app reports it,
    /// otherwise by the selection's range. Chromium and Electron update the selection a moment after it's set, so
    /// this looks a few times over 0.3 s.
    private static func selectionShows(_ el: AXUIElement, _ probe: NSRange, _ expected: String) -> Bool {
        let deadline = Date().addingTimeInterval(0.3)
        repeat {
            if let selected = string(el, kAXSelectedTextAttribute), !(selected.isEmpty && !expected.isEmpty) {
                if selected == expected { return true }
            } else if selection(el) == probe {
                return true
            }
            Thread.sleep(forTimeInterval: 0.01)
        } while Date() < deadline
        return false
    }

    private static func setSelectedMarkers(_ el: AXUIElement, _ r: AXTextMarkerRange) -> Bool {
        AXUIElementSetAttributeValue(el, "AXSelectedTextMarkerRange" as CFString, r) == .success
    }

    // MARK: Text markers (WebKit)

    static func param(_ el: AXUIElement, _ attr: String, _ p: CFTypeRef) -> CFTypeRef? {
        var v: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, attr as CFString, p, &v) == .success else { return nil }
        return v
    }

    private static func marker(_ el: AXUIElement, at index: Int) -> AXTextMarker? {
        guard let m = param(el, "AXTextMarkerForIndex", index as CFNumber), CFGetTypeID(m) == AXTextMarkerGetTypeID()
        else { return nil }
        return (m as! AXTextMarker)
    }

    private static func index(_ el: AXUIElement, of marker: AXTextMarker) -> Int? {
        (param(el, "AXIndexForTextMarker", marker) as? NSNumber)?.intValue
    }

    /// The marker range for UTF-16 `range` of an editable web area, checked: the markers must map back to the
    /// same indices (WebKit; Chrome counts from the top of the page and is never asked).
    private static func markerRange(_ el: AXUIElement, _ range: NSRange) -> AXTextMarkerRange? {
        guard let a = marker(el, at: range.location), let b = marker(el, at: NSMaxRange(range)),
              index(el, of: a) == range.location, index(el, of: b) == NSMaxRange(range) else { return nil }
        return AXTextMarkerRangeCreate(nil, a, b)
    }

    private static func markerBounds(_ el: AXUIElement, _ range: NSRange) -> CGRect? {
        guard let r = markerRange(el, range), let v = param(el, kAXBoundsForTextMarkerRangeParameterizedAttribute, r)
        else { return nil }
        return rect(v)
    }

    /// The visible part of an editable web area as a UTF-16 range: the markers WebKit finds at the start and end
    /// of its visible frame. WebKit finds no end marker when the frame ends below the text; the text's end
    /// is used then.
    static func visibleMarkerRange(_ el: AXUIElement) -> NSRange? {
        guard let clip = visibleFrame(el), let primary = NSScreen.screens.first else { return nil }
        // Back to AX coordinates (top-left origin of the primary screen, y down).
        var r = CGRect(x: clip.minX, y: primary.frame.maxY - clip.maxY, width: clip.width, height: clip.height)
        guard let rv = AXValueCreate(.cgRect, &r) else { return nil }
        func markerIndex(_ attr: String) -> Int? {
            guard let m = param(el, attr, rv), CFGetTypeID(m) == AXTextMarkerGetTypeID() else { return nil }
            return index(el, of: m as! AXTextMarker)
        }
        guard let a = markerIndex("AXStartTextMarkerForBounds") else { return nil }
        guard let b = markerIndex("AXEndTextMarkerForBounds") ?? endIndex(el), b > a else { return nil }
        return NSRange(location: a, length: b - a)
    }

    /// UTF-16 length of an editable web area's text, from its end marker.
    private static func endIndex(_ el: AXUIElement) -> Int? {
        guard let whole = param(el, "AXTextMarkerRangeForUIElement", el),
              CFGetTypeID(whole) == AXTextMarkerRangeGetTypeID() else { return nil }
        return index(el, of: AXTextMarkerRangeCopyEndMarker(whole as! AXTextMarkerRange))
    }

    // MARK: Bounds

    /// Screen rect (Cocoa coordinates) of UTF-16 `range` of `text(el)`: `AXBoundsForRange` on the field; for an
    /// editable web area, its text markers; for a Chromium rich editor, its text leaves (`text` is the field's
    /// value, read again when nil). Nil when the app gives no bounds.
    static func bounds(_ el: AXUIElement, _ range: NSRange, text: String? = nil) -> CGRect? {
        if let r = nativeBounds(el, range) { return r }
        if isEditableWebArea(el) { return markerBounds(el, range) }
        return leafBounds(el, range, text: text)
    }

    /// `AXBoundsForRange` on `el`. Nil when the app doesn't support it or returns an empty rect.
    static func nativeBounds(_ el: AXUIElement, _ range: NSRange) -> CGRect? {
        var cf = CFRange(location: range.location, length: range.length)
        guard let p = AXValueCreate(.cfRange, &cf), let v = param(el, kAXBoundsForRangeParameterizedAttribute, p)
        else { return nil }
        return rect(v, shiftY: VCLGeometry.boundsShift(el) ?? 0)
    }

    /// An AX rect value converted to Cocoa coordinates (after moving it `shiftY` down in AX coordinates, for an
    /// app quirk); nil when empty or not finite.
    private static func rect(_ v: CFTypeRef, shiftY: CGFloat = 0) -> CGRect? {
        guard CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &r), r.width > 0, r.height > 0,
              r.width.isFinite, r.height.isFinite else { return nil }
        r.origin.y += shiftY
        return cocoa(r)
    }

    /// A marker range for `range` of a Chromium rich editor, anchored on its text leaves (markers walked from the
    /// field itself land on the field, not the text).
    private static func leafMarkerRange(_ el: AXUIElement, _ range: NSRange, text: String) -> AXTextMarkerRange? {
        // A second try on fresh leaves: the editor may have replaced a leaf the map still points at.
        for attempt in 0..<2 {
            guard let leaves = LeafCache.shared.leaves(for: el, value: text, rebuild: attempt > 0, needing: range),
                  let a = leaves.map.locate(range.location), let b = leaves.map.locate(NSMaxRange(range)) else { return nil }
            if let start = leafMarker(leaves.elements[a.leaf], offset: a.offset),
               let end = leafMarker(leaves.elements[b.leaf], offset: b.offset) {
                return AXTextMarkerRangeCreate(nil, start, end)
            }
        }
        return nil
    }

    /// The selection of a Chromium rich editor in `text` (its value) offsets, read through text markers. Chrome's
    /// `AXSelectedTextRange` counts the leaves' text with nothing between blocks, so it falls behind the value by
    /// one or more per paragraph break (Google Docs' hidden field, probed 2026-11-22: 3714 for value offset 3738).
    /// The marker text from the first leaf to the selection's ends has the same count; walking the leaves turns it
    /// into a leaf and an offset, and the leaf map into a value offset. Nil unless every leaf is lined up.
    static func leafSelection(_ el: AXUIElement, text: String) -> NSRange? {
        guard let sel = copy(el, "AXSelectedTextMarkerRange"), CFGetTypeID(sel) == AXTextMarkerRangeGetTypeID(),
              let leaves = LeafCache.shared.leaves(for: el, value: text, rebuild: false),
              leaves.map.segments.count == leaves.elements.count,
              leaves.map.segments.enumerated().allSatisfy({ $0.offset == $0.element.leaf }),
              let firstWhole = param(leaves.elements[0], "AXTextMarkerRangeForUIElement", leaves.elements[0]),
              CFGetTypeID(firstWhole) == AXTextMarkerRangeGetTypeID() else { return nil }
        let origin = AXTextMarkerRangeCopyStartMarker(firstWhole as! AXTextMarkerRange)
        let range = sel as! AXTextMarkerRange
        func valueOffset(_ m: AXTextMarker, atStart: Bool) -> Int? {
            guard let s = param(el, "AXStringForTextMarkerRange", AXTextMarkerRangeCreate(nil, origin, m)) as? String
            else { return nil }
            return leaves.map.valueIndex(leafCount: (s as NSString).length, atStart: atStart)
        }
        let start = AXTextMarkerRangeCopyStartMarker(range), end = AXTextMarkerRangeCopyEndMarker(range)
        guard let a = valueOffset(start, atStart: true) else { return nil }
        if CFEqual(start, end) { return NSRange(location: a, length: 0) }
        guard let b = valueOffset(end, atStart: false), b >= a else { return nil }
        return NSRange(location: a, length: b - a)
    }

    /// The marker `offset` UTF-16 units into `leaf`: its start marker, stepped forward one character at a time
    /// (a step can be two units, an emoji), or its end marker at its end.
    private static func leafMarker(_ leaf: AXUIElement, offset: Int) -> AXTextMarker? {
        guard let whole = param(leaf, "AXTextMarkerRangeForUIElement", leaf),
              CFGetTypeID(whole) == AXTextMarkerRangeGetTypeID() else { return nil }
        let r = whole as! AXTextMarkerRange
        var m = AXTextMarkerRangeCopyStartMarker(r)
        guard offset > 0 else { return m }
        if let all = param(leaf, "AXStringForTextMarkerRange", r) as? String, all.utf16.count == offset {
            return AXTextMarkerRangeCopyEndMarker(r)
        }
        var n = 0, steps = 0
        while n < offset, steps < offset + 8 {
            steps += 1
            guard let next = param(leaf, "AXNextTextMarkerForTextMarker", m), CFGetTypeID(next) == AXTextMarkerGetTypeID(),
                  let piece = param(leaf, "AXStringForTextMarkerRange", AXTextMarkerRangeCreate(nil, m, next as! AXTextMarker)) as? String
            else { return nil }
            n += piece.utf16.count
            m = next as! AXTextMarker
        }
        return n == offset ? m : nil
    }

    /// The union of the leaf rects that make up `range`. The leaf map is built once per field value.
    private static func leafBounds(_ el: AXUIElement, _ range: NSRange, text: String?) -> CGRect? {
        guard let value = text ?? string(el, kAXValueAttribute) else { return nil }
        for attempt in 0..<2 {
            guard let leaves = LeafCache.shared.leaves(for: el, value: value, rebuild: attempt > 0, needing: range)
            else { return nil }
            let pieces = leaves.map.pieces(of: range)
            guard !pieces.isEmpty else { return nil }
            let rects = pieces.compactMap { nativeBounds(leaves.elements[$0.leaf], $0.range) }
            if !rects.isEmpty { return rects.dropFirst().reduce(rects[0]) { $0.union($1) } }
            // Every leaf failed: the editor rebuilt its leaves without changing the text. Map them again once.
        }
        return nil
    }

    /// The part of a Chromium rich editor's `text` whose leaves are on screen (inside `visibleFrame`), from the
    /// first visible leaf to the last. Leaves come in document order, top to bottom, so two binary searches over
    /// their frames find the ends (~20 frame reads on a 300-leaf page). Nil when unknown, when nothing is on
    /// screen, or when the layout doesn't go top to bottom (the two ends must really be on screen).
    static func leafVisibleRange(_ el: AXUIElement, text: String, trace: ((String) -> Void)? = nil) -> NSRange? {
        guard let clip = visibleFrame(el) else { trace?("no visible frame"); return nil }
        guard let leaves = LeafCache.shared.leaves(for: el, value: text, rebuild: false) else { trace?("no leaves"); return nil }
        trace?("clip \(NSStringFromRect(clip)), \(leaves.map.segments.count) segments")
        let segs = leaves.map.segments
        var frames: [Int: CGRect] = [:]
        var unknown = false
        func leafFrame(_ k: Int) -> CGRect? {
            if let f = frames[k] { return f }
            // Chrome clips the frame of a leaf scrolled out of view to the edge of the box, with zero height (probed
            // 2026-11-16): kept, `above` / `below` read the edge. Any other empty frame (a collapsed or hidden leaf)
            // says nothing about where the text is.
            guard let f = frame(leaves.elements[segs[k].leaf]), f.width > 0,
                  f.height > 0 || atTop(f) || atBottom(f) else {
                trace?("leaf \(k): frame \(frame(leaves.elements[segs[k].leaf]).map { NSStringFromRect($0) } ?? "nil")")
                unknown = true
                return nil
            }
            trace?("leaf \(k): \(NSStringFromRect(f))")
            frames[k] = f
            return f
        }
        func atTop(_ f: CGRect) -> Bool { f.height == 0 && abs(f.minY - clip.maxY) < 1 }
        func atBottom(_ f: CGRect) -> Bool { f.height == 0 && abs(f.minY - clip.minY) < 1 }
        // Cocoa coordinates (y up): a leaf is above the visible part when its bottom is over the clip's top.
        func above(_ k: Int) -> Bool {
            guard let f = leafFrame(k) else { return false }
            return atTop(f) || f.minY > clip.maxY
        }
        func below(_ k: Int) -> Bool {
            guard let f = leafFrame(k) else { return false }
            return atBottom(f) || f.maxY < clip.minY
        }
        func firstWhere(_ p: (Int) -> Bool, negate: Bool) -> Int {
            var lo = 0, hi = segs.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if p(mid) != negate { hi = mid } else { lo = mid + 1 }
            }
            return lo
        }
        let first = firstWhere(above, negate: true)   // first leaf not above
        let end = firstWhere(below, negate: false)    // first leaf below
        trace?("first \(first), end \(end), unknown \(unknown)")
        guard !unknown, first < end, first < segs.count,
              let a = leafFrame(first), let b = leafFrame(end - 1), !unknown, a.height > 0, b.height > 0,
              a.minY <= clip.maxY, a.maxY >= clip.minY, b.minY <= clip.maxY, b.maxY >= clip.minY else { return nil }
        let lo = segs[first].range.location, hi = NSMaxRange(segs[end - 1].range)
        return NSRange(location: lo, length: hi - lo)
    }

    // MARK: Formatting runs (Apply all in groups)

    /// `range` of `text` (the field's text as just read) is one run of formatting: replacing it with plain text
    /// can't drop a link, bold or an image inside it. Chromium rich editors: one text leaf covers it. WebKit
    /// editable web areas and native fields: the attributed string over it has the same attributes throughout
    /// (spelling and autocorrect marks aside). False when the app can't tell.
    static func isOneTextRun(_ el: AXUIElement, _ range: NSRange, text: String) -> Bool {
        let ns = text as NSString
        guard range.length > 0, NSMaxRange(range) <= ns.length else { return false }
        let expected = ns.substring(with: range)
        if isEditableWebArea(el) {
            guard let r = markerRange(el, range),
                  let a = param(el, "AXAttributedStringForTextMarkerRange", r) as? NSAttributedString else { return false }
            return a.string == expected && uniform(a)
        }
        if nativeBounds(el, range) == nil {
            guard let leaves = LeafCache.shared.leaves(for: el, value: text, rebuild: false, needing: range) else { return false }
            let pieces = leaves.map.pieces(of: range)
            return pieces.count == 1 && pieces[0].range.length == range.length
        }
        var cf = CFRange(location: range.location, length: range.length)
        guard let p = AXValueCreate(.cfRange, &cf),
              let a = param(el, kAXAttributedStringForRangeParameterizedAttribute, p) as? NSAttributedString else { return false }
        return a.string == expected && uniform(a)
    }

    /// Every character has the same attributes, apart from the marks spell checking and autocorrect add.
    private static func uniform(_ s: NSAttributedString) -> Bool {
        guard s.length > 0 else { return true }
        let transient = ["Misspell", "Autocorrect", "Replacement", "Suggest", "Spelling", "Grammar"]
        var first: NSDictionary?
        var same = true
        s.enumerateAttributes(in: NSRange(location: 0, length: s.length)) { attrs, _, stop in
            let kept = NSDictionary(dictionary: attrs.filter { k, _ in !transient.contains { k.rawValue.contains($0) } })
            if let first {
                if !first.isEqual(to: kept as! [AnyHashable: Any]) { same = false; stop.pointee = true }
            } else {
                first = kept
            }
        }
        return same
    }

    /// The static-text leaves (and list markers) of `el` in document order, at most `limit` elements visited. One IPC call per
    /// element (role, value and children together).
    fileprivate static func textLeaves(of el: AXUIElement, limit: Int = 2000) -> [(element: AXUIElement, text: String)] {
        var out: [(AXUIElement, String)] = []
        var visited = 0
        let attrs = [kAXRoleAttribute, kAXValueAttribute, kAXChildrenAttribute] as CFArray
        func walk(_ node: AXUIElement, depth: Int) {
            guard visited < limit, depth < 64 else { return }
            visited += 1
            var values: CFArray?
            guard AXUIElementCopyMultipleAttributeValues(node, attrs, [], &values) == .success,
                  let list = values as? [Any], list.count == 3 else { return }
            // List bullets ("• ", "1. ") are in the value too, as `AXListMarker`s.
            if let role = list[0] as? String, role == (kAXStaticTextRole as String) || role == "AXListMarker" {
                out.append((node, list[1] as? String ?? ""))
                return
            }
            for child in list[2] as? [AXUIElement] ?? [] { walk(child, depth: depth + 1) }
        }
        for child in (copy(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(child, depth: 1) }
        return out
    }
}

/// The leaf map of the last rich editor measured, for its value. Built on the first bounds request after the
/// value changed; the underline layout asks once per character of a wrapped fix, so it must not rebuild per call.
/// A value that changed inside one leaf (a fix written, a word typed) shifts the map instead of walking the
/// leaves again (`TextLeafMap.edited`, ~100 ms on a 300-leaf page); that leaf is marked dirty, and the map is
/// rebuilt the first time a request touches it.
private final class LeafCache: @unchecked Sendable {
    static let shared = LeafCache()

    struct Leaves {
        let elements: [AXUIElement]
        let map: TextLeafMap
    }

    private let lock = NSLock()
    private var element: AXUIElement?
    private var value: String?
    private var leaves: Leaves?
    /// The last field logged, so each field is logged once.
    private var logged: AXUIElement?
    /// The last field whose index selection didn't prove out (Chrome with lists).
    private var indexOff: AXUIElement?
    /// Leaves (indices into `leaves.elements`) whose text changed since the walk: their element may be stale.
    private var dirty = Set<Int>()

    private func touchesDirty(_ map: TextLeafMap, _ range: NSRange?) -> Bool {
        guard !dirty.isEmpty, let range else { return false }
        var hit = map.pieces(of: range).map(\.leaf)
        if let a = map.locate(range.location) { hit.append(a.leaf) }
        if let b = map.locate(NSMaxRange(range)) { hit.append(b.leaf) }
        return hit.contains { dirty.contains($0) }
    }

    func indexSelectionOff(_ el: AXUIElement) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return indexOff.map { CFEqual($0, el) } ?? false
    }

    func setIndexSelectionOff(_ el: AXUIElement) {
        lock.lock()
        indexOff = el
        lock.unlock()
    }

    /// The leaves of `el` lined up with `value`; nil when there are none or none match. `needing`: the value
    /// range the caller is about to use; a dirty leaf there means a rebuild.
    func leaves(for el: AXUIElement, value: String, rebuild: Bool, needing range: NSRange? = nil) -> Leaves? {
        lock.lock()
        defer { lock.unlock() }
        if !rebuild, let element, CFEqual(element, el), let current = leaves, let old = self.value {
            if old == value, !touchesDirty(current.map, range) { return current }
            if old != value, let change = TextChange.between(old, value), let (map, leaf) = current.map.edited(change) {
                self.value = value
                leaves = Leaves(elements: current.elements, map: map)
                dirty.insert(leaf)
                if !touchesDirty(map, range) { return leaves }
            }
        }
        let found = AX.textLeaves(of: el)
        let map = TextLeafMap(value: value, leaves: found.map(\.text))
        element = el
        self.value = value
        dirty = []
        leaves = map.segments.isEmpty ? nil : Leaves(elements: found.map(\.element), map: map)
        if logged.map({ !CFEqual($0, el) }) ?? true {
            logged = el
            if !found.isEmpty { Log.write("text bounds: \(found.count) text leaves, \(map.segments.count) lined up, "
                + "\(Int((map.coverage(of: value) * 100).rounded()))% of the text covered") }
        }
        return leaves
    }
}
