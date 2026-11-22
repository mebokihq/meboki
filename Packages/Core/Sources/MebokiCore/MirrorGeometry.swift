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
