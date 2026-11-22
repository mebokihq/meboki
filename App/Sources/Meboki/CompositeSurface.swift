import AppKit
import ApplicationServices
import MebokiCore

/// A document whose paragraphs are separate text fields: one text for the check, joined with a newline between
/// paragraphs (`SegmentMap`), read and written one paragraph field at a time.
///
/// Which elements are the paragraphs comes from the strategy that made the surface (`members`), so the same
/// surface serves any tree shape. The paragraph list is read again with the text: apps that list only the
/// paragraphs on screen (LibreOffice) change it while the user scrolls, and the live review then sees that as an
/// edit at the top or bottom of the text, like any other change.
///
/// A range that reaches over a paragraph break can't be written (no one field holds it): `replace` refuses it.
/// Every write is `AX.replace` on the one paragraph field, with all of its checks.
final class CompositeSurface: TextSurface {
    /// The element that holds the paragraphs (its frame clips the underlines; it going away ends the review).
    let container: AXUIElement
    let anchor: AXUIElement
    private let pid: pid_t
    /// The paragraph fields now, in document order; nil when the tree no longer has the strategy's shape.
    private let members: () -> [AXUIElement]?
    /// Whether an element is one of the paragraphs, also one that wasn't listed yet (a paragraph just made).
    private let isMember: (AXUIElement) -> Bool
    /// What the strategy knows about the app's layout (the defaults are LibreOffice's: nothing special).
    struct Traits {
        /// Clips the underlines instead of `container` (a scroller taller than the list it holds).
        var clip: AXUIElement?
        /// More elements whose value changes are edits: a page-wide editor root reports edits in any block, also in
        /// blocks the surface didn't list when the review started.
        var extraValueElements: [AXUIElement] = []
        /// Elements whose focus counts as a paragraph's: a page-wide editor root, which the app reports as focused
        /// for a moment after a click and while its window isn't key (also while a write is pasted, see `AX.replace`).
        var focusHolders: [AXUIElement] = []
        /// All the paragraphs share one editing host, so while a write is pasted, focus on any of them counts for
        /// the paragraph written (the host takes keys to where the proven selection is; a window that was just
        /// given back its keys reports the paragraph the caret was in last). Off for separate fields.
        var oneEditingHost = false
        /// The app lists blocks scrolled out of view too, with their frames squeezed to the edge of the scroller
        /// (no height): their rects are dropped, never drawn, and the bounds probe looks for a block on screen.
        var clampsOffscreen = false
        /// Positions lag after a scroll (Chromium rich editors measured through their text leaves).
        var settlesLate = false
        /// Focus passes through something outside the surface between two of its blocks (see `TextSurface.focusGrace`).
        var focusGrace: TimeInterval = 0
        /// See `TextSurface.recreatesOffscreenParagraphs`.
        var recreatesOffscreenParagraphs = false
        /// How many UTF-16 units at the start of a paragraph's text are a list label the app won't let anyone
        /// select (`ParagraphLabels.length`); fixes are cut to start after it. Nil: paragraphs hold only text.
        var labelLength: ((String) -> Int)?
        /// See `TextSurface.skipsUntouchedFailuresInApplyAll`.
        var skipsUntouchedFailures = false
    }
    private let traits: Traits
    private(set) var elements: [AXUIElement] = []
    private(set) var map = SegmentMap(segments: [])
    /// Every paragraph element seen, so each gets a stable id (its index here) across reads.
    private var known: [AXUIElement] = []
    /// The last few texts the surface held, with the ids of their paragraphs, for `carry`: newest last.
    private var history: [(map: SegmentMap, ids: [Int])] = []
    /// A text `map(for:)` couldn't find, and when: asked again right away, it doesn't read everything again.
    private var miss: (text: String, at: Date)?
    private(set) var lastWriteLeftFieldUntouched = false

    init?(container: AXUIElement, anchor: AXUIElement, pid: pid_t, members: @escaping () -> [AXUIElement]?,
          isMember: @escaping (AXUIElement) -> Bool, traits: Traits = Traits()) {
        self.traits = traits
        self.container = container
        self.anchor = anchor
        self.pid = pid
        self.members = members
        self.isMember = isMember
        guard refresh() else { return nil }
    }

    /// Reads the paragraph list and texts again. False when the paragraphs can't be read.
    @discardableResult
    private func refresh() -> Bool {
        guard let els = members(), !els.isEmpty else { return false }
        var texts: [String] = []
        texts.reserveCapacity(els.count)
        for el in els {
            guard let t = AX.text(el) else { return false }
            texts.append(t)
        }
        elements = els
        map = SegmentMap(segments: texts)
        remember(map, ids: els.map(id))
        return true
    }

    private func id(_ el: AXUIElement) -> Int {
        if let i = known.firstIndex(where: { CFEqual($0, el) }) { return i }
        known.append(el)
        return known.count - 1
    }

    private func remember(_ m: SegmentMap, ids: [Int]) {
        if let last = history.last, last.map == m, last.ids == ids { return }
        history.append((m, ids))
        if history.count > 8 { history.removeFirst(history.count - 8) }
    }

    /// The map whose text is `text` (the caller's last read), read again once when it changed since. A text not
    /// found is remembered for 0.25 s, so a burst of lookups for it (one per underline) reads the paragraphs once.
    private func map(for text: String) -> SegmentMap? {
        if map.text == text { return map }
        if let miss, miss.text == text, Date().timeIntervalSince(miss.at) < 0.25 { return nil }
        guard refresh(), map.text == text else {
            miss = (text, Date())
            return nil
        }
        miss = nil
        return map
    }

    private func index(of el: AXUIElement) -> Int? {
        elements.firstIndex { CFEqual($0, el) }
    }

    var valueElements: [AXUIElement] { elements + traits.extraValueElements }
    var lifeElements: [AXUIElement] { [container] }
    var placesCaretAfterReview: Bool { false }

    func text() -> String? {
        refresh() ? map.text : nil
    }

    /// The selection in the focused paragraph, in document offsets.
    func selection() -> NSRange? {
        guard let f = AX.focusedElement(pid: pid), isMember(f) else { return nil }
        if index(of: f) == nil { refresh() }
        guard let i = index(of: f), let r = AX.selection(f) else { return nil }
        return map.documentRange(segment: i, r)
    }

    func select(_ range: NSRange, in text: String) -> Bool {
        guard let m = map(for: text), let (i, local) = m.local(range) else { return false }
        return AX.select(elements[i], local, in: m.segments[i])
    }

    func bounds(_ range: NSRange, text: String) -> CGRect? {
        guard let m = map(for: text) else { return nil }
        let rects = m.pieces(of: range).compactMap { p in
            AX.bounds(elements[p.segment], p.range, text: m.segments[p.segment])
        }.filter(drawable)
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    func lineRects(_ range: NSRange, in text: String) -> [CGRect]? {
        guard let m = map(for: text) else { return nil }
        let rects = m.pieces(of: range).flatMap { p in
            AX.lineRects(elements[p.segment], range: p.range, in: m.segments[p.segment]) ?? []
        }
        let shown = rects.filter(drawable)
        return shown.isEmpty ? nil : shown
    }

    /// A rect worth underlining: with `clampsOffscreen`, one with a real height (a block scrolled out of view
    /// reports a frame of no height at the edge of the scroller).
    private func drawable(_ r: CGRect) -> Bool {
        !traits.clampsOffscreen || r.height > 2
    }

    /// Real bounds in the first paragraph with letters (the app answers alike for all of them).
    func hasTextBounds(text: String, visible: NSRange?) -> Bool {
        guard let m = map(for: text),
              let i = m.segments.firstIndex(where: { $0.rangeOfCharacter(from: .letters) != nil }) else { return false }
        guard traits.clampsOffscreen else { return AX.hasTextBounds(elements[i], text: m.segments[i]) }
        // The first blocks listed may be off screen: the first one on screen answers for all of them.
        let onScreen = m.segments.indices.first {
            m.segments[$0].rangeOfCharacter(from: .letters) != nil && (AX.axFrame(elements[$0])?.height ?? 0) > 2
        }
        return onScreen.map { AX.hasTextBounds(elements[$0], text: m.segments[$0]) } ?? false
    }

    /// Nil: the paragraphs listed are the ones the app has on screen, so the whole text counts as visible.
    func visibleCharacterRange() -> NSRange? { nil }
    func visibleFrame() -> CGRect? { AX.visibleFrame(traits.clip ?? container) }
    func frame() -> CGRect? { AX.frame(container) }

    func isOneTextRun(_ range: NSRange, text: String) -> Bool {
        guard let m = map(for: text), let (i, local) = m.local(range) else { return false }
        return AX.isOneTextRun(elements[i], local, text: m.segments[i])
    }

    /// Writes only when the document still holds exactly `expected`, the text `range` refers to: the paragraphs on
    /// screen change while scrolling, and the same words in another paragraph must never take the fix.
    func replace(pid: pid_t, range: NSRange, original: String, replacement: String, expected: String,
                 pasteOnly: Bool, beforeKeystroke: () -> Void) -> Bool {
        let tag = "edit @\(range.location)+\(range.length) \(Log.pair(original, replacement))"
        lastWriteLeftFieldUntouched = false
        guard refresh() else {
            Log.write("\(tag): can't read the document's paragraphs")
            return false
        }
        guard map.text == expected else {
            Log.write("\(tag): the document changed since the check (scrolled or edited); not written")
            return false
        }
        let ns = map.text as NSString
        guard NSMaxRange(range) <= ns.length, ns.substring(with: range) == original else {
            Log.write("\(tag): document no longer has the original text there: \(Log.snippet(map.text, around: range))")
            return false
        }
        guard let (i, local) = map.local(range) else {
            Log.write("\(tag): the range reaches over a paragraph break; not written")
            return false
        }
        let ok = AX.replace(in: elements[i], pid: pid, range: local, original: original, replacement: replacement,
                            pasteOnly: pasteOnly, beforeKeystroke: beforeKeystroke,
                            focusHolders: traits.focusHolders + (traits.oneEditingHost ? elements : []),
                            onUntouched: { [self] in lastWriteLeftFieldUntouched = true })
        if ok {
            // What the document holds now, for `carry` (the review's text after this write).
            let segment = (map.segments[i] as NSString).replacingCharacters(in: local, with: replacement)
            remember(map.replacing(segment: i, with: segment), ids: elements.map(id))
        }
        return ok
    }

    var textFollowsScroll: Bool { true }
    func learnTextFollowsScroll() {}

    /// Paragraphs matched by element (`FixList.followParagraphs`) when the paragraphs on screen changed. With the
    /// same paragraphs, one text change describes the edit (nil). When the earlier text isn't known any more, every
    /// fix leaves: the next check brings them back, and none can land on the wrong paragraph.
    func carry(_ list: inout FixList, to now: String) -> [Int: Int]? {
        guard let new = history.last(where: { $0.map.text == now }) else {
            Log.write("review: document text not read yet; fixes cleared")
            return list.relocate(to: now) { _ in nil }
        }
        guard let old = history.last(where: { $0.map.text == list.text }) else {
            Log.write("review: earlier document text unknown; fixes cleared")
            return list.relocate(to: now) { _ in nil }
        }
        if old.ids == new.ids { return nil }
        if let remap = list.followParagraphs(from: old.map, ids: old.ids, to: new.map, ids: new.ids) { return remap }
        Log.write("review: paragraphs reordered; fixes cleared")
        return list.relocate(to: now) { _ in nil }
    }

    func owns(_ el: AXUIElement) -> Bool {
        index(of: el) != nil || isMember(el) || traits.focusHolders.contains { CFEqual($0, el) }
    }

    func isFocused(pid: pid_t) -> Bool {
        AX.focusedElement(pid: pid).map(owns) ?? false
    }

    var isSecure: Bool { elements.contains(where: AX.isSecureField) }
    /// Paragraph fields answer `AXBoundsForRange` themselves (LibreOffice), at once, unless the strategy says
    /// they are measured late (`Traits.settlesLate`).
    var settlesLate: Bool { traits.settlesLate }
    var focusGrace: TimeInterval { traits.focusGrace }
    var recreatesOffscreenParagraphs: Bool { traits.recreatesOffscreenParagraphs }
    /// Paragraphs are matched by element, so a change `carry` leaves to one text change (the same paragraphs, or
    /// one more or fewer at an edge of the window) is followed too.
    var followsSmallChangesInApplyAll: Bool { true }
    var skipsUntouchedFailuresInApplyAll: Bool { traits.skipsUntouchedFailures }

    func writableEdits(_ edits: [Edit], in text: String, scopeLocation: Int) -> [Edit] {
        guard let label = traits.labelLength else { return edits }
        return ParagraphLabels.trim(edits, in: text, scopeLocation: scopeLocation, label: label)
    }
}

/// Paragraphs as sibling text areas: the focused text area's parent holds nothing but plain paragraph fields (text
/// areas with no label and no children), at least two, stacked top to bottom (`ParagraphFieldShape`, Core).
/// LibreOffice Writer (VCL) lays out a document like this, one `AXTextArea` per paragraph on screen (probed
/// 2026-11-22: 15 to 19 of 47 paragraphs; list bullets are part of the paragraph's text and count in its offsets).
/// The shape is checked, not the app. Fields it must not join: Obsidian's inline title and note body (the body
/// is a rich editor with children), Pages' labelled body, header and footer, side-by-side form fields.
struct SiblingParagraphsStrategy: SurfaceStrategy {
    var name: String { "sibling paragraphs" }

    func surface(for focused: AXUIElement, pid: pid_t) -> TextSurface? {
        guard AX.string(focused, kAXRoleAttribute) == ParagraphFieldShape.textAreaRole,
              let parent = AX.element(focused, kAXParentAttribute),
              let kids = AX.copy(parent, kAXChildrenAttribute) as? [AXUIElement],
              kids.count >= 2, kids.count <= ParagraphFieldShape.maxParagraphs,
              kids.contains(where: { CFEqual($0, focused) }),
              ParagraphFieldShape.isDocument(kids.map { Self.field($0, frame: true) }) else { return nil }
        // LibreOffice (VCL): list bullets and numbers are the start of the paragraph's value but can't be selected,
        // paragraphs that scroll out of the window come back as new elements, and a write scrolls the document.
        var traits = CompositeSurface.Traits()
        traits.labelLength = ParagraphLabels.length(in:)
        traits.skipsUntouchedFailures = true
        traits.recreatesOffscreenParagraphs = true
        return CompositeSurface(container: parent, anchor: focused, pid: pid,
                                members: { Self.paragraphs(of: parent) },
                                isMember: { el in
                                    AX.string(el, kAXRoleAttribute) == ParagraphFieldShape.textAreaRole
                                        && (AX.element(el, kAXParentAttribute).map { CFEqual($0, parent) } ?? false)
                                }, traits: traits)
    }

    /// What the shape check needs to know about one sibling (the frame only when asked: it costs two calls).
    static func field(_ el: AXUIElement, frame: Bool) -> ParagraphFieldShape.Field {
        var count: CFIndex = 0
        AXUIElementGetAttributeValueCount(el, kAXChildrenAttribute as CFString, &count)
        let label = [kAXDescriptionAttribute, kAXTitleAttribute]
            .compactMap { AX.string(el, $0 as String) }.first { !$0.isEmpty } ?? ""
        return ParagraphFieldShape.Field(role: AX.string(el, kAXRoleAttribute) ?? "", label: label,
                                         childCount: count, frame: frame ? AX.axFrame(el) : nil)
    }

    /// The parent's children while they are still plain paragraph fields; else nil.
    static func paragraphs(of parent: AXUIElement) -> [AXUIElement]? {
        guard let kids = AX.copy(parent, kAXChildrenAttribute) as? [AXUIElement],
              ParagraphFieldShape.isParagraphList(kids.map { field($0, frame: false) }) else { return nil }
        return kids
    }
}
