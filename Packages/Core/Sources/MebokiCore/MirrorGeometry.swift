import CoreGraphics
import Foundation

/// Places text measured in an off-screen copy of a document (a "mirror") on the screen, where the app draws the
/// same text itself (a canvas).
///
/// Google Docs with braille support on keeps the text around the caret in a hidden editable field, laid out with
/// the document's own fonts at the page's content width, but at 100% zoom and far off-screen (probed 2026-11-22:
/// the mirror wraps lines at the same words as the page). Its caret is a real element with a screen frame. So a
/// rect in the mirror maps to the screen by the caret: screen = caret on screen + (rect − caret in the mirror) ×
/// zoom. Only the caret's page is mapped (the mirror has no page breaks): `band` keeps the rects that fall in that
/// page's text area.
///
/// Across, the copy and the page agree. Down, they don't: the copy spaces lines by CSS (line spacing × 1.2 × font
/// size), the page by the font's own line height (line spacing × (ascent + descent + leading)). Arial, Docs' default
/// font, is 1.15 em: its lines on the page are 1.15 / 1.2 of the copy's (measured 15.5 pt against 16.2 pt). Chrome
/// doesn't say which font the copy uses, so `lineScale` starts at Arial's and is learned from where the caret
/// sits on different lines (`lineScale(samples:)`).
///
/// All rects and points are Cocoa coordinates (bottom-left origin, y up).
public struct MirrorGeometry: Equatable, Sendable {
    /// The caret's point in the mirror: its x, and the middle of its line.
    public var mirrorCaret: CGPoint
    /// The caret's point on screen: its x, and its middle.
    public var screenCaret: CGPoint
    /// Screen size of one mirror point (the document's zoom; the browser's own zoom applies to both).
    public var scale: CGFloat
    /// Where the mapped text can be: the caret's page text area, clipped to the editor.
    public var band: CGRect
    /// Page line distance over copy line distance (at zoom 1).
    public var lineScale: CGFloat

    /// Arial's line height (1.15 em) over the copy's CSS line height (1.2 em).
    public static let defaultLineScale: CGFloat = 1.15 / 1.2

    public init(mirrorCaret: CGPoint, screenCaret: CGPoint, scale: CGFloat, band: CGRect,
                lineScale: CGFloat = MirrorGeometry.defaultLineScale) {
        self.mirrorCaret = mirrorCaret
        self.screenCaret = screenCaret
        self.scale = scale
        self.band = band
        self.lineScale = lineScale
    }

    /// `r` (a mirror rect) on screen, wherever it lands.
    public func map(_ r: CGRect) -> CGRect {
        let midY = screenCaret.y + (r.midY - mirrorCaret.y) * scale * lineScale
        let height = r.height * scale
        return CGRect(x: screenCaret.x + (r.minX - mirrorCaret.x) * scale, y: midY - height / 2,
                      width: r.width * scale, height: height)
    }

    /// `r` on screen, or nil when its middle is outside `band` (another page, or off screen).
    public func screenRect(_ r: CGRect) -> CGRect? {
        let m = map(r)
        return band.contains(CGPoint(x: m.midX, y: m.midY)) ? m : nil
    }

    /// One caret position seen in both places, with nothing scrolled or zoomed in between.
    public struct Sample: Equatable, Sendable {
        public var mirrorY: CGFloat
        public var screenY: CGFloat
        public init(mirrorY: CGFloat, screenY: CGFloat) {
            self.mirrorY = mirrorY
            self.screenY = screenY
        }
    }

    /// The line scale the samples show: from the two farthest apart (at least 3 copy lines, ~48 pt, so the 1 pt
    /// rounding of AX frames stays under 2%), at `scale`. Nil when they don't span that, or give a scale no font
    /// has (outside 0.85…1.1).
    public static func lineScale(samples: [Sample], scale: CGFloat) -> CGFloat? {
        guard scale > 0, let lo = samples.min(by: { $0.mirrorY < $1.mirrorY }),
              let hi = samples.max(by: { $0.mirrorY < $1.mirrorY }), hi.mirrorY - lo.mirrorY >= 45 else { return nil }
        let s = (hi.screenY - lo.screenY) / ((hi.mirrorY - lo.mirrorY) * scale)
        return (0.85...1.1).contains(s) ? s : nil
    }

    /// A line of text near an empty line, in the mirror: one character's rect on it, and how many lines it is from
    /// the empty line.
    public struct Neighbour: Equatable, Sendable {
        public var rect: CGRect
        public var steps: Int
        public init(rect: CGRect, steps: Int) {
            self.rect = rect
            self.steps = steps
        }
    }

    /// The caret's point in the mirror when it sits on an empty line, where Chrome gives no caret bounds (it
    /// answers with the clipped paragraph box, 2400 × 1 pt; 2026-11-23). An empty paragraph in the copy is one line
    /// with no extra spacing (measured: text lines 16.5 pt apart sit 33 pt apart across one empty line), so the line
    /// lies between the text lines around it: `above` is the last line of the text above, `below` the first line of
    /// the text below, each `steps` lines away. With text on one side only, `pitch` (copy points per line) steps
    /// from it. x: `lineStartX`, where a line of a neighbouring paragraph starts. Nil when the rects don't make sense.
    public static func emptyLineCaret(lineStartX: CGFloat, above: Neighbour?, below: Neighbour?,
                                      pitch: CGFloat?) -> CGPoint? {
        let y: CGFloat
        switch (above, below) {
        case let (a?, b?):
            guard a.steps > 0, b.steps > 0 else { return nil }
            let step = (a.rect.midY - b.rect.midY) / CGFloat(a.steps + b.steps)
            guard step >= minimumPitch else { return nil }
            y = a.rect.midY - step * CGFloat(a.steps)
        case let (a?, nil):
            guard a.steps > 0, let pitch, pitch >= minimumPitch else { return nil }
            y = a.rect.midY - pitch * CGFloat(a.steps)
        case let (nil, b?):
            guard b.steps > 0, let pitch, pitch >= minimumPitch else { return nil }
            y = b.rect.midY + pitch * CGFloat(b.steps)
        case (nil, nil):
            return nil
        }
        return CGPoint(x: lineStartX, y: y)
    }

    /// Copy points per line between two text lines `steps` lines apart (`upper` above `lower`); nil when they
    /// don't give a line height text can have.
    public static func pitch(upper: CGRect, lower: CGRect, steps: Int) -> CGFloat? {
        guard steps > 0 else { return nil }
        let p = (upper.midY - lower.midY) / CGFloat(steps)
        return p >= minimumPitch ? p : nil
    }

    /// No line of text is closer than this to the next (copy points).
    static let minimumPitch: CGFloat = 4

    /// The caret is drawn on screen: an element clipped by its scroll area keeps a frame of height 0 or 1 at the
    /// area's edge (Chrome), which isn't a caret position.
    public static func isVisibleCaret(_ r: CGRect) -> Bool {
        r.height >= 4 && r.width > 0 && r.width < 8
    }

    /// The zoom a percent label shows ("125%" → 1.25). Nil for anything else ("Fit", empty).
    public static func zoom(_ label: String) -> CGFloat? {
        let t = label.trimmingCharacters(in: .whitespaces)
        guard t.hasSuffix("%"), let v = Double(t.dropLast().trimmingCharacters(in: .whitespaces)),
              v >= 10, v <= 1000 else { return nil }
        return CGFloat(v / 100)
    }

    /// One side margin of a page `pageWidth` wide (screen) whose text area is `mirrorWidth` (mirror) at `scale`.
    /// Zero when the page isn't wider than its text (pageless documents).
    public static func margin(pageWidth: CGFloat, mirrorWidth: CGFloat, scale: CGFloat) -> CGFloat {
        max(0, (pageWidth - mirrorWidth * scale) / 2)
    }

    /// The text area of `page` inside `editor`. Elements are clipped to the editor, so a page edge that lies
    /// strictly inside it is real: the text starts `margin` below a real top edge and ends `margin` above a real
    /// bottom edge (top and bottom margins taken as the side margin, the default page setup). No page (pageless):
    /// the editor.
    public static func band(page: CGRect?, editor: CGRect, margin: CGFloat) -> CGRect {
        guard let page else { return editor }
        let clipped = page.intersection(editor)
        guard !clipped.isNull else { return .null }
        var top = clipped.maxY, bottom = clipped.minY
        if page.maxY < editor.maxY - 1 { top = min(top, page.maxY - margin) }
        if page.minY > editor.minY + 1 { bottom = max(bottom, page.minY + margin) }
        guard top > bottom else { return .null }
        return CGRect(x: clipped.minX, y: bottom, width: clipped.width, height: top - bottom)
    }
}
