import AppKit
import ApplicationServices
import MebokiCore

/// The text Meboki checks and writes: one field, or one document made of several fields.
///
/// The check flow (the hotkey check, the automatic check, the review session and its watcher) talks to a
/// surface instead of a raw element, so apps that split a document into one element per paragraph (LibreOffice
/// Writer, Notion) can be handled by a surface that joins them (`SegmentMap`), without app checks in the flow.
/// All ranges are UTF-16 and relative to `text()`.
///
/// Every write still goes through `AX.replace` on one real element, with all of its checks.
protocol TextSurface: AnyObject {
    /// The element that had focus when the surface was made. Its window and scroll area place the overlay.
    var anchor: AXUIElement { get }
    /// Every element whose value is part of `text()`: the review watches them for edits.
    var valueElements: [AXUIElement] { get }
    /// Elements whose destruction means the text is gone (the review ends). A document's paragraphs come and
    /// go as it scrolls; only its container going away ends it.
    var lifeElements: [AXUIElement] { get }
    /// After a hotkey review with fixes applied, the caret goes after the checked text (design_code.md §5.7).
    /// A document of paragraph fields leaves the caret where the user put it: its text ends at the last
    /// paragraph on screen, not where the user was writing.
    var placesCaretAfterReview: Bool { get }

    /// The whole text, or nil when it can't be read.
    func text() -> String?
    /// Why `text()` is nil, when the surface knows better than the focused element's role (nil: ask the element).
    var unreadableError: AXError2? { get }
    func selection() -> NSRange?
    /// Selects `range` of `text` and proves it (`AX.select`).
    func select(_ range: NSRange, in text: String) -> Bool
    /// Screen rect (Cocoa) of `range`, or nil.
    func bounds(_ range: NSRange, text: String) -> CGRect?
    /// One screen rect per line for `range`, or nil (`AX.lineRects`).
    func lineRects(_ range: NSRange, in text: String) -> [CGRect]?
    /// Whether the app gives real text bounds here (`AX.hasTextBounds`).
    func hasTextBounds(text: String, visible: NSRange?) -> Bool
    /// The characters on screen, or nil when unknown.
    func visibleCharacterRange() -> NSRange?
    /// The part the user can see, clipped to its scroll area and window (Cocoa), or nil.
    func visibleFrame() -> CGRect?
    /// Screen frame (Cocoa) of the whole surface, or nil.
    func frame() -> CGRect?
    /// `range` of `text` has one formatting run (Apply all groups only such spans).
    func isOneTextRun(_ range: NSRange, text: String) -> Bool
    /// Replaces `range` (holding `original`) with `replacement`; see `AX.replace`. `expected` is the whole text
    /// `range` refers to (what the review believes the surface holds): a surface whose text can change without an
    /// edit (`textFollowsScroll`) refuses to write unless it still holds exactly that.
    func replace(pid: pid_t, range: NSRange, original: String, replacement: String, expected: String,
                 pasteOnly: Bool, beforeKeystroke: () -> Void) -> Bool
    /// The text changes without any edit: the surface lists only what's on screen, so scrolling adds and removes
    /// text (LibreOffice). A live review follows it before measuring (`AppDelegate.syncLive`).
    var textFollowsScroll: Bool { get }
    /// Carries `list` (whose text is what the surface held earlier) over to `now`, the surface's current text.
    /// Nil: one text change between the two describes it (`TextChange.between`, `FixList.textEdited`), as for
    /// any field. A document of paragraph fields matches paragraphs by element instead (`FixList.followParagraphs`).
    func carry(_ list: inout FixList, to now: String) -> [Int: Int]?
    /// The review saw this surface's text change right after a scroll with no key pressed
    /// (`ScrollChangeDetector`): from now on `textFollowsScroll` is true for it (remembered per field).
    func learnTextFollowsScroll()

    /// `el` is part of this surface: focus moving to it stays in the same text.
    func owns(_ el: AXUIElement) -> Bool
    /// The app's focused element is part of this surface.
    func isFocused(pid: pid_t) -> Bool
    /// Some element of the surface is a secure text field.
    var isSecure: Bool { get }
    /// The app reports text positions a moment after it scrolls (Chromium and Electron rich editors, measured
    /// through their text leaves): underlines wait until two measurements agree.
    var settlesLate: Bool { get }
}

extension TextSurface {
    var unreadableError: AXError2? { nil }
}

/// One element is the whole text: every app before multi-field documents, unchanged. Each call is the
/// `AX` function the flow called before surfaces existed.
final class SingleFieldSurface: TextSurface {
    let element: AXUIElement

    init(_ element: AXUIElement) {
        self.element = element
    }

    var anchor: AXUIElement { element }
    var valueElements: [AXUIElement] { [element] }
    var lifeElements: [AXUIElement] { [element] }
    var placesCaretAfterReview: Bool { true }

    func text() -> String? { AX.text(element) }
    func selection() -> NSRange? { AX.selection(element) }
    func select(_ range: NSRange, in text: String) -> Bool { AX.select(element, range, in: text) }
    func bounds(_ range: NSRange, text: String) -> CGRect? { AX.bounds(element, range, text: text) }
    func lineRects(_ range: NSRange, in text: String) -> [CGRect]? { AX.lineRects(element, range: range, in: text) }
    func hasTextBounds(text: String, visible: NSRange?) -> Bool { AX.hasTextBounds(element, text: text, visible: visible) }
    func visibleCharacterRange() -> NSRange? { AX.visibleCharacterRange(element) }
    func visibleFrame() -> CGRect? { AX.visibleFrame(element) }
    func frame() -> CGRect? { AX.frame(element) }
    func isOneTextRun(_ range: NSRange, text: String) -> Bool { AX.isOneTextRun(element, range, text: text) }

    /// `expected` isn't compared: a single field's text only changes by an edit, and `AX.replace` checks the
    /// original is still at `range` (as it always did; some apps report their value slightly differently).
    func replace(pid: pid_t, range: NSRange, original: String, replacement: String, expected: String,
                 pasteOnly: Bool, beforeKeystroke: () -> Void) -> Bool {
        AX.replace(in: element, pid: pid, range: range, original: original, replacement: replacement,
                   pasteOnly: pasteOnly, beforeKeystroke: beforeKeystroke)
    }
    /// False until the review sees the field's text change with a scroll (`learnTextFollowsScroll`): editors that
    /// keep only the lines near the screen in their field, such as Obsidian's CodeMirror.
    var textFollowsScroll: Bool { ScrollFollowingFields.contains(element) }
    func carry(_ list: inout FixList, to now: String) -> [Int: Int]? { nil }
    func learnTextFollowsScroll() { ScrollFollowingFields.add(element) }

    func owns(_ el: AXUIElement) -> Bool { CFEqual(el, element) }
    func isFocused(pid: pid_t) -> Bool { AX.isFocused(element, pid: pid) }
    var isSecure: Bool { AX.isSecureField(element) }

    private var lateCache: Bool?
    /// A field with no bounds of its own (`AXBoundsForRange` empty) that isn't an editable web area: it's measured
    /// through its text leaves (`AX.bounds`), which is how Chromium and Electron editors work. Decided once, on
    /// the first non-empty text.
    var settlesLate: Bool {
        if let lateCache { return lateCache }
        guard let t = AX.text(element), !t.isEmpty else { return false }
        let first = (t as NSString).rangeOfComposedCharacterSequence(at: 0)
        let late = !AX.isEditableWebArea(element) && AX.nativeBounds(element, first) == nil
        lateCache = late
        return late
    }
}

/// A way to see a focused element as part of a bigger text (a document of paragraph fields). Strategies look at
/// the shape of the accessibility tree, not at app names; `SurfaceResolver` asks them in order.
protocol SurfaceStrategy {
    /// A short name for the log and the field probe.
    var name: String { get }
    /// A surface around `focused`, or nil when the tree around it doesn't have this strategy's shape.
    func surface(for focused: AXUIElement, pid: pid_t) -> TextSurface?
}

/// Picks the surface for a focused element: the first strategy that recognises the tree around it, else the
/// element by itself (`SingleFieldSurface`), which is how every app worked before.
enum SurfaceResolver {
    /// Tried in order.
    static let strategies: [SurfaceStrategy] = [MirrorStrategy(), SiblingParagraphsStrategy()]

    static func surface(for focused: AXUIElement, pid: pid_t) -> TextSurface {
        for s in strategies {
            if let surface = s.surface(for: focused, pid: pid) { return surface }
        }
        return SingleFieldSurface(focused)
    }
}

/// Fields whose text was seen to follow the scroll, so a new surface for the same field (the next check, the next
/// review) knows it at once. The last 32, compared with `CFEqual`; used on the main thread only.
enum ScrollFollowingFields {
    nonisolated(unsafe) private static var elements: [AXUIElement] = []

    static func contains(_ el: AXUIElement) -> Bool { elements.contains { CFEqual($0, el) } }

    static func add(_ el: AXUIElement) {
        guard !contains(el) else { return }
        elements.append(el)
        if elements.count > 32 { elements.removeFirst(elements.count - 32) }
    }
}
