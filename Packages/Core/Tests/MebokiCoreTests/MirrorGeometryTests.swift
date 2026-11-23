import CoreGraphics
import Foundation
import Testing
@testable import MebokiCore

/// Mapping Google Docs' off-screen text (braille support on) onto its canvas by the caret.
@Suite struct MirrorGeometryTests {
    /// Measured 2026-11-22 in Chrome at 80% page zoom, Docs at 100%, converted to Cocoa with a 1000 pt screen.
    /// Caret after "misteak." on the last line: screen (526, 428 top-left, 14 tall); in the mirror at x 158 on the
    /// line whose middle is 8610. "sentense" in the mirror: (78, 8668, 48 × 13). On the canvas its line runs from
    /// y 365 to 380 (top-left) and the line starts at x 369, so the word starts at 369 + 78 = 447.
    @Test func measuredDocsWordLandsOnItsCanvasWord() {
        let g = MirrorGeometry(mirrorCaret: CGPoint(x: 158, y: 8610), screenCaret: CGPoint(x: 526, y: 565),
                               scale: 1, band: CGRect(x: 0, y: 0, width: 2000, height: 2000))
        let r = g.map(CGRect(x: 78, y: 8668, width: 48, height: 13))
        #expect(abs(r.minX - 447) <= 2)
        let topLeftMid = 1000 - r.midY
        #expect(abs(topLeftMid - 372.5) <= 2)
        #expect(r.width == 48)
    }

    @Test func zoomScalesOffsetsAndSize() {
        let g = MirrorGeometry(mirrorCaret: CGPoint(x: 100, y: 500), screenCaret: CGPoint(x: 400, y: 300),
                               scale: 1.25, band: CGRect(x: 0, y: 0, width: 2000, height: 2000))
        let r = g.map(CGRect(x: 20, y: 516, width: 40, height: 16))
        #expect(r.minX == 400 + (20 - 100) * 1.25)
        #expect(r.midY == 300 + (524 - 500) * 1.25 * MirrorGeometry.defaultLineScale)
        #expect(r.width == 50)
        #expect(r.height == 20)
    }

    @Test func rectOutsideBandIsDropped() {
        let g = MirrorGeometry(mirrorCaret: .zero, screenCaret: CGPoint(x: 400, y: 400), scale: 1,
                               band: CGRect(x: 300, y: 300, width: 500, height: 200))
        #expect(g.screenRect(CGRect(x: 10, y: 10, width: 30, height: 14)) != nil)
        #expect(g.screenRect(CGRect(x: 10, y: 300, width: 30, height: 14)) == nil)  // above the band
        #expect(g.screenRect(CGRect(x: -300, y: 10, width: 30, height: 14)) == nil)  // left of it
    }

    /// Measured 2026-11-22: copy lines 16.25 pt apart (8668 → 8603 over 4 lines), page lines 15.5 pt (365 → 427).
    /// Twelve lines below the caret, the copy's spacing put underlines 9 pt too low; Arial's ratio keeps it under 1.
    @Test func linesFollowThePagesSpacingNotTheCopys() {
        let g = MirrorGeometry(mirrorCaret: CGPoint(x: 0, y: 8668), screenCaret: CGPoint(x: 363, y: 1000 - 372.5),
                               scale: 1, band: CGRect(x: 0, y: 0, width: 2000, height: 2000))
        let twelveBelow = g.map(CGRect(x: 0, y: 8668 - 12 * 16.25 - 6.5, width: 30, height: 13))
        let expected = 372.5 + 12 * 15.5
        #expect(abs((1000 - twelveBelow.midY) - expected) < 1)
    }

    @Test func lineScaleFromCaretSamples() {
        let samples = [MirrorGeometry.Sample(mirrorY: 8668, screenY: 627.5),
                       MirrorGeometry.Sample(mirrorY: 8603, screenY: 565.5)]
        let s = MirrorGeometry.lineScale(samples: samples, scale: 1)
        #expect(s.map { abs($0 - 62.0 / 65.0) < 0.001 } == true)
        // One line apart: too close to trust.
        #expect(MirrorGeometry.lineScale(samples: [samples[0], .init(mirrorY: 8652, screenY: 612)], scale: 1) == nil)
        // A scale no font gives (the user scrolled between the samples).
        #expect(MirrorGeometry.lineScale(samples: [samples[0], .init(mirrorY: 8600, screenY: 300)], scale: 1) == nil)
    }

    @Test func zoomLabel() {
        #expect(MirrorGeometry.zoom("100%") == 1)
        #expect(MirrorGeometry.zoom("125%") == 1.25)
        #expect(MirrorGeometry.zoom(" 50 % ") == 0.5)
        #expect(MirrorGeometry.zoom("Fit") == nil)
        #expect(MirrorGeometry.zoom("") == nil)
        #expect(MirrorGeometry.zoom("0%") == nil)
    }

    /// Measured: page 653 wide, mirror 500 at 100% (margins 76.5 = 1 in at 80% page zoom); page 817 at 125%.
    @Test func marginFromPageAndMirrorWidth() {
        #expect(MirrorGeometry.margin(pageWidth: 653, mirrorWidth: 500, scale: 1) == 76.5)
        #expect(MirrorGeometry.margin(pageWidth: 817, mirrorWidth: 500, scale: 1.25) == 96)
        #expect(MirrorGeometry.margin(pageWidth: 480, mirrorWidth: 500, scale: 1) == 0)
    }

    @Test func caretVisibility() {
        #expect(MirrorGeometry.isVisibleCaret(CGRect(x: 363, y: 365, width: 2, height: 14)))
        // Scrolled out of the editor: Chrome clips it to a 1 pt sliver at the editor's edge.
        #expect(!MirrorGeometry.isVisibleCaret(CGRect(x: 488, y: 276, width: 2, height: 1)))
    }

    /// Cocoa: editor 0…572 high. A page whose top is inside the editor starts its text `margin` lower; a page
    /// whose bottom is inside starts it `margin` higher; edges clipped by the editor aren't page edges.
    @Test func bandFollowsRealPageEdges() {
        let editor = CGRect(x: 0, y: 0, width: 1256, height: 572)
        // Whole page visible from y 100 to 500.
        let whole = MirrorGeometry.band(page: CGRect(x: 286, y: 100, width: 653, height: 400), editor: editor,
                                        margin: 77)
        #expect(whole == CGRect(x: 286, y: 177, width: 653, height: 246))
        // Page running past the editor top: only its bottom edge is real.
        let topCut = MirrorGeometry.band(page: CGRect(x: 286, y: 100, width: 653, height: 472), editor: editor,
                                         margin: 77)
        #expect(topCut == CGRect(x: 286, y: 177, width: 653, height: 395))
        // Page filling the editor: nothing is cut.
        #expect(MirrorGeometry.band(page: editor.insetBy(dx: 286, dy: 0), editor: editor, margin: 77)
                == editor.insetBy(dx: 286, dy: 0))
        // No pages (pageless): the editor.
        #expect(MirrorGeometry.band(page: nil, editor: editor, margin: 77) == editor)
        // A sliver of a page whose text area isn't on screen.
        #expect(MirrorGeometry.band(page: CGRect(x: 286, y: 0, width: 653, height: 60), editor: editor,
                                    margin: 77).isNull)
    }

    /// Measured 2026-11-23 in a test doc (Cocoa, copy points): "together." ends paragraph 0 on the line at 8723.5,
    /// paragraph 1 is empty, "Yesterday" starts paragraph 2 at 8691 (x 0). The empty line lies halfway.
    @Test func emptyLineBetweenTextLiesBetweenItsLines() {
        let p = MirrorGeometry.emptyLineCaret(
            lineStartX: 0,
            above: .init(rect: CGRect(x: 303, y: 8717, width: 45, height: 13), steps: 1),
            below: .init(rect: CGRect(x: 0, y: 8684, width: 52, height: 14), steps: 1), pitch: nil)
        #expect(p != nil)
        #expect(p!.x == 0)
        #expect(abs(p!.y - 8707.25) < 0.01)
    }

    /// Two empty lines between text: the caret on the second is two thirds of the way down.
    @Test func secondOfTwoEmptyLines() {
        let p = MirrorGeometry.emptyLineCaret(
            lineStartX: 0,
            above: .init(rect: CGRect(x: 0, y: 900, width: 10, height: 10), steps: 2),
            below: .init(rect: CGRect(x: 0, y: 852, width: 10, height: 10), steps: 1), pitch: nil)
        #expect(abs((p?.y ?? 0) - 873) < 0.01)
    }

    /// The empty last line of the copy: one pitch below the text above it ("unchanged." at 8587, pitch 16).
    @Test func emptyLastLineStepsDownByPitch() {
        let pitch = MirrorGeometry.pitch(upper: CGRect(x: 67, y: 8619, width: 23, height: 14),
                                         lower: CGRect(x: 0, y: 8587, width: 22, height: 14), steps: 2)
        #expect(pitch == 16)
        let p = MirrorGeometry.emptyLineCaret(
            lineStartX: 0, above: .init(rect: CGRect(x: 213, y: 8587, width: 61, height: 13), steps: 2),
            below: nil, pitch: pitch)
        #expect(p?.y == 8593.5 - 32)
        // Empty first line: steps up from the text below.
        let q = MirrorGeometry.emptyLineCaret(
            lineStartX: 5, above: nil, below: .init(rect: CGRect(x: 0, y: 100, width: 10, height: 10), steps: 1),
            pitch: 16)
        #expect(q == CGPoint(x: 5, y: 121))
    }

    @Test func emptyLineGivesUpOnNonsense() {
        let r = CGRect(x: 0, y: 100, width: 10, height: 10)
        // No text on either side, or one side and no pitch.
        #expect(MirrorGeometry.emptyLineCaret(lineStartX: 0, above: nil, below: nil, pitch: 16) == nil)
        #expect(MirrorGeometry.emptyLineCaret(lineStartX: 0, above: .init(rect: r, steps: 1), below: nil,
                                              pitch: nil) == nil)
        // "Below" isn't below (clipped frames all at one y).
        #expect(MirrorGeometry.emptyLineCaret(lineStartX: 0, above: .init(rect: r, steps: 1),
                                              below: .init(rect: r, steps: 1), pitch: nil) == nil)
        #expect(MirrorGeometry.pitch(upper: r, lower: r, steps: 1) == nil)
        #expect(MirrorGeometry.pitch(upper: r, lower: r.offsetBy(dx: 0, dy: -20), steps: 0) == nil)
    }
}
