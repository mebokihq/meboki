import AppKit
import ApplicationServices
import MebokiCore

/// A canvas editor whose text lives in a hidden editable copy (a "mirror"): Google Docs with braille support on.
///
/// Docs draws its pages on a canvas. Its keyboard goes to an editable field inside an off-screen frame
/// (`docs-texteventtarget-iframe`). With Tools › Accessibility › braille support on, Docs fills that field with the
/// text around the caret (about 4 000 characters, whole paragraphs, joined by "\n") and keeps its selection in step
/// with the real one; with it off, the field holds two zero-width spaces (probed 2026-11-22).
///
/// - Read and select: the field itself (`AX.text`, `AX.select`); setting its selection moves Docs' selection.
/// - Write: paste only. Docs ignores `AXSelectedText`, and a paste replaces the selected range exactly.
/// - Positions: the field's own bounds describe the off-screen copy. `MirrorGeometry` (Core) maps them onto the
///   canvas through Docs' caret (`kix-cursor-caret`, a real element with a screen frame), the zoom shown in the
///   toolbar, and the caret's page. Only text on the caret's page is placed; with no visible caret and no earlier
///   anchor for the same layout, nothing is (the card opens below the editor instead).
final class MirrorSurface: TextSurface {
    let element: AXUIElement
    private let pid: pid_t
    private let parts: MirrorParts

    init(element: AXUIElement, pid: pid_t, parts: MirrorParts) {
        self.element = element
        self.pid = pid
        self.parts = parts
    }

    var anchor: AXUIElement { element }
    var valueElements: [AXUIElement] { [element] }
    var lifeElements: [AXUIElement] { [element] }
    /// The checked text is the window around the caret, not what the user was writing: the caret stays put.
    var placesCaretAfterReview: Bool { false }

    /// The field holds only zero-width spaces: braille support is off, so the text isn't shared.
    private var isPlaceholder: Bool {
        guard let t = AX.text(element) else { return false }
        return Self.isPlaceholder(t)
    }

    static func isPlaceholder(_ t: String) -> Bool {
        !t.isEmpty && t.unicodeScalars.allSatisfy { $0 == "\u{200B}" }
    }

    /// No-break spaces read as spaces: Docs turns a space at the edge of a styled run (a word it marked) into
    /// U+00A0 in the copy and back again without an edit (2026-11-22), which looked like a change next to every
    /// write. One UTF-16 unit for another, so offsets don't move.
    static func normalize(_ t: String) -> String { t.replacingOccurrences(of: "\u{00A0}", with: " ") }

    func text() -> String? {
        guard let t = AX.text(element), !Self.isPlaceholder(t) else { return nil }
        return Self.normalize(t)
    }

    /// The field's own value behind `text` (a read of `text()`): what the `AX` helpers compare with the app's
    /// leaves and selection. Nil when the field changed since.
    private func raw(_ text: String) -> String? {
        guard let t = AX.text(element), Self.normalize(t) == text else { return nil }
        return t
    }

    var unreadableError: AXError2? { isPlaceholder ? .brailleSupportOff : nil }

    /// Through text markers: the field's `AXSelectedTextRange` falls behind its value at every paragraph break.
    func selection() -> NSRange? {
        guard let t = AX.text(element), !Self.isPlaceholder(t) else { return nil }
        return AX.leafSelection(element, text: t)
    }
    func select(_ range: NSRange, in text: String) -> Bool {
        guard let raw = raw(text) else { return false }
        return AX.select(element, range, in: raw)
    }

    func bounds(_ range: NSRange, text: String) -> CGRect? {
        guard let rects = lineRects(range, in: text), let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    func lineRects(_ range: NSRange, in text: String) -> [CGRect]? {
        guard let g = geometry(text: text), let raw = raw(text),
              let mirror = AX.lineRects(element, range: range, in: raw) else { return nil }
        let rects = mirror.compactMap(g.screenRect)
        return rects.isEmpty ? nil : rects
    }

    /// The copy gives real bounds and the editor can be measured (its frame and zoom). Not whether they can be placed
    /// this instant: that needs the caret on screen, and a selection or a scroll hides it for a moment; the automatic
    /// check turned itself off for the field after such moments (2026-11-22). The review waits for the caret instead.
    func hasTextBounds(text: String, visible: NSRange?) -> Bool {
        guard parts.editorFrame() != nil, parts.zoom() != nil, let raw = raw(text) else { return false }
        return AX.hasTextBounds(element, text: raw)
    }

    /// Nil: the copy holds only text near the caret.
    func visibleCharacterRange() -> NSRange? { nil }

    /// The editor, clipped to its window: the field itself is a 1 pt strip off the page.
    func visibleFrame() -> CGRect? {
        guard var f = parts.editorFrame() else { return nil }
        if let w = AX.window(of: element).flatMap(AX.frame) { f = f.intersection(w) }
        return f.isNull || f.width <= 1 || f.height <= 1 ? nil : f
    }

    func frame() -> CGRect? { parts.editorFrame() }

    func isOneTextRun(_ range: NSRange, text: String) -> Bool {
        guard let raw = raw(text) else { return false }
        return AX.isOneTextRun(element, range, text: raw)
    }

    /// Writes only while the field still holds exactly `expected`: the copy is replaced by another stretch of the
    /// document when the caret moves far, and the same words there must never take the fix. Paste only.
    func replace(pid: pid_t, range: NSRange, original: String, replacement: String, expected: String,
                 pasteOnly: Bool, beforeKeystroke: () -> Void) -> Bool {
        lastWriteLeftFieldUntouched = false
        guard text() == expected else {
            Log.write("edit @\(range.location)+\(range.length) \(Log.pair(original, replacement)): "
                      + "the document text around the caret changed since the check; not written")
            return false
        }
        if AX.replace(in: element, pid: pid, range: range, original: original, replacement: replacement,
                      pasteOnly: true, beforeKeystroke: beforeKeystroke, normalize: Self.normalize,
                      onUntouched: { [self] in lastWriteLeftFieldUntouched = true }) {
            return true
        }
        // Proven untouched (Docs wouldn't select the range): nothing was pasted, so there is no moved write to find.
        if lastWriteLeftFieldUntouched { return false }
        // Docs may move the copy's window right after a paste, so the check above (everything before the fix
        // unchanged) can fail for a write that went in. It counts only when the text as written lines up with the
        // new window and the written range lies in what both hold.
        let written = (expected as NSString).replacingCharacters(in: range, with: replacement)
        let writtenRange = NSRange(location: range.location, length: (replacement as NSString).length)
        for _ in 0..<10 {
            if let now = text() {
                if now == written { return true }
                if let a = TextWindow.alignment(old: written, new: now, evenWhenSmall: true), a.edit == nil,
                   NSLocationInRange(writtenRange.location, a.overlap),
                   NSMaxRange(writtenRange) <= NSMaxRange(a.overlap), a.overlap.length >= 200 {
                    Log.write("edit @\(range.location)+\(range.length): written; the text around the caret moved "
                              + "(\(a.shift >= 0 ? "+" : "")\(a.shift)) right after it")
                    return true
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    /// The copy holds a window of whole paragraphs that Docs moves on its own (a write near the top shrank it from
    /// 4 241 to 1 054 characters, 2026-11-22), so the review follows it before measuring, like a field that follows
    /// the scroll.
    var textFollowsScroll: Bool { true }
    func learnTextFollowsScroll() {}

    /// Docs sometimes won't select one fix's range (the selection never proves out; 2026-11-22, "there" → "their"
    /// stopped every Apply all at its first write). The field is proven unchanged then, so Apply all skips that
    /// fix and goes on.
    var skipsUntouchedFailuresInApplyAll: Bool { true }
    private(set) var lastWriteLeftFieldUntouched = false
    /// Docs also trims or adds one paragraph at an edge of its window between writes (2026-11-22: 93 characters
    /// left the end after the 16th write, and Apply all stopped). One `TextChange` describes that, so Apply all
    /// follows it: fixes it touches leave, the rest keep going. Every write still needs the copy to hold exactly
    /// the expected text.
    var followsSmallChangesInApplyAll: Bool { true }

    /// A small edit: nil (one text change describes it). A moved window: fixes in the paragraphs both windows hold
    /// move with them (`TextWindow.alignment`), the rest leave until the next check. Nothing shared: every fix leaves.
    func carry(_ list: inout FixList, to now: String) -> [Int: Int]? {
        let old = list.text
        if let c = TextChange.between(old, now), c.range.length <= 200, (c.replacement as NSString).length <= 200 {
            return nil
        }
        guard let a = TextWindow.alignment(old: old, new: now) else {
            Log.write("review: the document text around the caret was replaced; fixes cleared")
            return list.relocate(to: now) { _ in nil }
        }
        // A write that went in while the window moved: take it first (fixes it touches leave), then the move.
        var overlap = a.overlap
        var first: [Int: Int]?
        if let e = a.edit {
            guard let m = list.textEdited(e) else { return list.relocate(to: now) { _ in nil } }
            first = m
            overlap.length += e.delta
        }
        let second = list.relocate(to: now) { r in
            NSLocationInRange(r.location, overlap) && NSMaxRange(r) <= NSMaxRange(overlap)
                ? NSRange(location: r.location - a.shift, length: r.length) : nil
        }
        guard let first else { return second }
        var both: [Int: Int] = [:]
        for (old, mid) in first { if let new = second[mid] { both[old] = new } }
        return both
    }

    func owns(_ el: AXUIElement) -> Bool { CFEqual(el, element) }
    func isFocused(pid: pid_t) -> Bool { AX.isFocused(element, pid: pid) }
    var isSecure: Bool { AX.isSecureField(element) }
    /// The canvas redraws a moment after a scroll.
    var settlesLate: Bool { true }

    // MARK: Geometry

    /// The last anchor taken from a visible caret, and the layout it holds for.
    private var lastAnchor: (geometry: MirrorGeometry, key: LayoutKey)?
    private var cached: (geometry: MirrorGeometry?, text: String, at: Date)?

    /// What must stay the same for an earlier caret anchor to still hold: nothing scrolled (the pages on screen),
    /// zoomed, or reflowed in the copy (its first character's place).
    private struct LayoutKey: Equatable {
        var pages: [CGRect]
        var editor: CGRect
        var scale: CGFloat
        var origin: CGRect?
    }

    /// The mapping from the copy to the screen, or nil when it can't be made now. Reused for 0.1 s: the review
    /// measures every fix in one go.
    private func geometry(text: String) -> MirrorGeometry? {
        if let c = cached, c.text == text, Date().timeIntervalSince(c.at) < 0.1 { return c.geometry }
        let g = makeGeometry(text: text)
        cached = (g, text, Date())
        return g
    }

    private func makeGeometry(text: String) -> MirrorGeometry? {
        guard let editor = parts.editorFrame(), let scale = parts.zoom(),
              let mirrorWidth = AX.frame(element)?.width, mirrorWidth > 1 else { return nil }
        guard let raw = raw(text) else { return nil }
        let ns = raw as NSString
        let pages = parts.pageFrames()
        let key = LayoutKey(pages: pages, editor: editor, scale: scale,
                            origin: ns.length > 0 ? AX.bounds(element, ns.rangeOfComposedCharacterSequence(at: 0),
                                                              text: raw) : nil)
        guard let caret = parts.caretFrame(), MirrorGeometry.isVisibleCaret(caret),
              let mirrorCaret = mirrorCaretPoint() else {
            // No caret on screen (a selection hides it, or it scrolled away): the last anchor, if nothing moved.
            if let last = lastAnchor, last.key == key { return last.geometry }
            return nil
        }
        let screenCaret = CGPoint(x: caret.minX, y: caret.midY)
        parts.learn(MirrorGeometry.Sample(mirrorY: mirrorCaret.y, screenY: screenCaret.y),
                    layout: "\(key)", scale: scale)
        let page = pages.first { $0.minY <= screenCaret.y && screenCaret.y <= $0.maxY }
        let margin = page.map { MirrorGeometry.margin(pageWidth: $0.width, mirrorWidth: mirrorWidth, scale: scale) } ?? 0
        let g = MirrorGeometry(mirrorCaret: mirrorCaret, screenCaret: screenCaret, scale: scale,
                               band: MirrorGeometry.band(page: page, editor: editor, margin: margin),
                               lineScale: parts.lineScale ?? MirrorGeometry.defaultLineScale)
        lastAnchor = (g, key)
        return g
    }

    /// Where the caret sits in the copy: Chrome's bounds of the collapsed selection (a zero-width rect). Asked by
    /// marker, not by offset: an offset at a paragraph break is both the end of one paragraph and the start of the
    /// next, and the caret at the end of a line was placed on the next line (2026-11-22).
    private func mirrorCaretPoint() -> CGPoint? {
        guard let sel = AX.copy(element, "AXSelectedTextMarkerRange"),
              CFGetTypeID(sel) == AXTextMarkerRangeGetTypeID() else { return nil }
        let range = sel as! AXTextMarkerRange
        guard CFEqual(AXTextMarkerRangeCopyStartMarker(range), AXTextMarkerRangeCopyEndMarker(range)),
              let v = AX.param(element, kAXBoundsForTextMarkerRangeParameterizedAttribute, range),
              CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(v as! AXValue, .cgRect, &r), r.height > 0, r.height.isFinite, r.width < 4,
              let c = AX.cocoa(r) else { return nil }
        return CGPoint(x: c.minX, y: c.midY)
    }
}

/// The parts of the editor page around the hidden field, found once by their DOM classes (Chrome exposes them as
/// `AXDOMClassList`) and found again when one goes stale.
final class MirrorParts {
    private let root: AXUIElement
    private var editor: AXUIElement?
    private var caret: AXUIElement?
    private var pages: AXUIElement?
    private var zoomField: AXUIElement?
    private var searched: Date?

    init(root: AXUIElement) {
        self.root = root
        search()
    }

    static let editorClass = "kix-appview-editor"
    static let caretClass = "kix-cursor-caret"
    static let pagesClass = "kix-rotatingtilemanager-content"
    static let pageClass = "kix-page-paginated"
    static let zoomClass = "docs-toolbar-zoom-combobox"

    /// Breadth-first under the page's web area, at most 4 000 elements (a Docs window has about 400), at most
    /// once a second.
    private func search() {
        if let searched, Date().timeIntervalSince(searched) < 1 { return }
        searched = Date()
        var queue = [root]
        var seen = 0
        var found: (editor: AXUIElement?, caret: AXUIElement?, pages: AXUIElement?, zoom: AXUIElement?)
        while !queue.isEmpty, seen < 4000 {
            let el = queue.removeFirst()
            seen += 1
            let classes = AX.domClasses(el)
            if classes.contains(Self.editorClass) { found.editor = el }
            if classes.contains(Self.caretClass) { found.caret = el }
            if classes.contains(Self.pagesClass) { found.pages = el }
            if classes.contains(Self.zoomClass) { found.zoom = el }
            if found.editor != nil, found.caret != nil, found.pages != nil, found.zoom != nil { break }
            queue += (AX.copy(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        editor = found.editor
        caret = found.caret
        pages = found.pages
        zoomField = found.zoom.flatMap(Self.firstTextField)
    }

    private static func firstTextField(under el: AXUIElement) -> AXUIElement? {
        var queue = [el]
        var seen = 0
        while !queue.isEmpty, seen < 20 {
            let e = queue.removeFirst()
            seen += 1
            if AX.string(e, kAXRoleAttribute) == (kAXTextFieldRole as String) { return e }
            queue += (AX.copy(e, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        }
        return nil
    }

    /// The element `get` returns, or after a search when it went stale (Docs replaces its caret element after an
    /// edit). Read through a closure, never `inout`: `search` assigns the same properties (an `inout` access held
    /// across it crashed the app on every write, 2026-11-22).
    private func fresh(_ get: () -> AXUIElement?) -> AXUIElement? {
        if let e = get(), AX.copy(e, kAXRoleAttribute) != nil { return e }
        search()
        if let e = get(), AX.copy(e, kAXRoleAttribute) != nil { return e }
        return nil
    }

    /// The page's line spacing over the copy's, once two caret positions far enough apart were seen in one layout
    /// (`MirrorGeometry.lineScale(samples:)`); kept for this editor page.
    private(set) var lineScale: CGFloat?
    private var samples: [MirrorGeometry.Sample] = []
    private var sampleLayout: String?

    /// A caret position seen in `layout` (scroll, zoom and copy unchanged): samples from one layout only.
    func learn(_ sample: MirrorGeometry.Sample, layout: String, scale: CGFloat) {
        if layout != sampleLayout {
            sampleLayout = layout
            samples = []
        }
        if samples.contains(where: { abs($0.mirrorY - sample.mirrorY) < 1 }) { return }
        samples.append(sample)
        if samples.count > 16 { samples.removeFirst() }
        if let s = MirrorGeometry.lineScale(samples: samples, scale: scale) { lineScale = s }
    }

    func editorFrame() -> CGRect? { fresh { editor }.flatMap(AX.frame) }
    func caretFrame() -> CGRect? { fresh { caret }.flatMap(AX.frame) }

    /// The document's zoom from the toolbar ("125%"); nil when it isn't a percentage.
    func zoom() -> CGFloat? {
        guard let f = fresh({ zoomField }), let v = AX.string(f, kAXValueAttribute) else { return nil }
        return MirrorGeometry.zoom(v)
    }

    /// The pages on screen (Cocoa), each clipped to the editor; empty when the document has no pages.
    func pageFrames() -> [CGRect] {
        guard let p = fresh({ pages }), let kids = AX.copy(p, kAXChildrenAttribute) as? [AXUIElement] else { return [] }
        return kids.filter { AX.domClasses($0).contains(Self.pageClass) }
            .compactMap(AX.frame)
            .filter { $0.height > 1 }
    }
}

/// The focused field is the hidden keyboard field of a canvas editor (`MirrorSurface`): a text area that is the
/// only document of a frame whose element carries `docs-texteventtarget-iframe`. Fields anywhere else don't have
/// that frame around them, so they never match.
struct MirrorStrategy: SurfaceStrategy {
    var name: String { "canvas editor mirror" }
    static let frameClass = "docs-texteventtarget-iframe"

    func surface(for focused: AXUIElement, pid: pid_t) -> TextSurface? {
        guard AX.string(focused, kAXRoleAttribute) == ParagraphFieldShape.textAreaRole,
              let web = AX.element(focused, kAXParentAttribute),
              AX.string(web, kAXRoleAttribute) == "AXWebArea",
              let frame = AX.element(web, kAXParentAttribute),
              AX.domClasses(frame).contains(Self.frameClass) else { return nil }
        // The editor page's own web area: the nearest one above the frame.
        var root = frame
        for _ in 0..<12 {
            guard let up = AX.element(root, kAXParentAttribute) else { break }
            root = up
            if AX.string(up, kAXRoleAttribute) == "AXWebArea" { break }
        }
        return MirrorSurface(element: focused, pid: pid, parts: MirrorParts.cached(root: root))
    }
}

extension MirrorParts {
    /// One set of parts per editor page, kept while the same page is focused (main thread only).
    nonisolated(unsafe) private static var last: (root: AXUIElement, parts: MirrorParts)?

    static func cached(root: AXUIElement) -> MirrorParts {
        if let last, CFEqual(last.root, root) { return last.parts }
        let p = MirrorParts(root: root)
        last = (root, p)
        return p
    }
}

extension AX {
    /// The element's DOM classes (Chromium web content only; empty elsewhere).
    static func domClasses(_ el: AXUIElement) -> [String] {
        (copy(el, "AXDOMClassList") as? [String]) ?? []
    }
}
