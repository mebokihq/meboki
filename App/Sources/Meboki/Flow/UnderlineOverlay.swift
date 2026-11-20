import AppKit
import MebokiCore
import SwiftUI

/// One fix's underline: its line rects on screen (Cocoa coordinates) and its category.
struct UnderlineMark: Equatable {
    var fix: Int
    var rects: [CGRect]
    var category: FixCategory
}

/// The underline overlay (design_code.md §5.3): a transparent, click-through panel over the visible part of
/// the target field. It draws a wavy underline in the category color under every pending fix, a fill on the
/// current fix (popup open on it) and on the hovered one, and the `appliedFlash` on a word just written.
///
/// It never takes clicks or the keyboard: clicks reach the target app (and move its caret), and `AppDelegate`
/// hit-tests them with a global mouse monitor (`hit(_:)`).
@MainActor
final class UnderlineOverlay {
    private let panel: NSPanel
    private let view = UnderlineView()

    /// Room around the visible field for the wave under the last line and the current-fix ring.
    private static let margin: CGFloat = 8

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // Above normal windows, below the card and toasts (`.floating`).
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = view
        view.wantsLayer = true
    }

    var isVisible: Bool { panel.isVisible }
    /// On screen and not suspended.
    var alphaValueIsShown: Bool { panel.isVisible && panel.alphaValue > 0 }
    var marks: [UnderlineMark] { view.marks }
    /// The visible part of the field the marks were last shown over (screen, Cocoa); `.null` when hidden.
    private(set) var clip: CGRect = .null

    /// The fix the popup is open on: 17% fill and a 2 pt ring. Nil when no popup is open.
    var current: Int? {
        get { view.current }
        set { if view.current != newValue { view.current = newValue; view.needsDisplay = true } }
    }

    /// The fix under the pointer: 10% fill.
    var hovered: Int? {
        get { view.hovered }
        set { if view.hovered != newValue { view.hovered = newValue; view.needsDisplay = true } }
    }

    /// The marks are a typing guess (`retarget`), not a measurement: drawn, but no hit-testing until the next
    /// `show`, so a click can't open a fix at the wrong spot.
    private(set) var stale = false

    /// Shows `marks` over `clip` (the visible part of the field). Marks are drawn only inside `clip`.
    func show(_ marks: [UnderlineMark], clip: CGRect) {
        let frame = clip.insetBy(dx: -Self.margin, dy: -Self.margin).integral
        let wasStale = stale
        stale = false
        // Nothing changed (a re-check that found the same fixes, a relayout after typing that moved nothing):
        // no repaint.
        if !wasStale, panel.isVisible, panel.alphaValue == 1, panel.frame == frame, self.clip == clip,
           view.marks == marks { return }
        if panel.frame != frame { panel.setFrame(frame, display: false) }
        self.clip = clip
        view.clip = clip.offsetBy(dx: -frame.minX, dy: -frame.minY)
        view.marks = marks
        if hovered.map({ h in !marks.contains { $0.fix == h } }) == true { view.hovered = nil }
        view.needsDisplay = true
        panel.alphaValue = 1
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// Hides the underlines while the field scrolls or its window moves; `show` brings them back.
    func suspend() {
        panel.alphaValue = 0
    }

    /// The user typed: keeps the underlines on screen instead of blinking them off until the relayout
    /// measures them again. `remap` says where each kept fix went (old index → new index; fixes missing from
    /// it left the list), and `keep` decides, per old mark and line rect, whether that rect can stay where it
    /// is (text before the edit, or on other lines, doesn't move for a small edit). Until the next `show`
    /// the marks don't hit-test.
    func retarget(_ remap: [Int: Int], keep: (_ oldFix: Int, _ rect: CGRect) -> Bool) {
        guard panel.isVisible else { return }
        var marks: [UnderlineMark] = []
        for m in view.marks {
            guard let n = remap[m.fix] else { continue }
            let rects = m.rects.filter { keep(m.fix, $0) }
            if !rects.isEmpty { marks.append(UnderlineMark(fix: n, rects: rects, category: m.category)) }
        }
        stale = true
        view.marks = marks
        view.current = nil
        view.hovered = nil
        view.needsDisplay = true
    }

    func hide() {
        panel.orderOut(nil)
        clip = .null
        stale = false
        view.marks = []
        view.current = nil
        view.hovered = nil
        view.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
    }

    /// The fix whose underlined word (or the wave under it) is at `point` (screen, Cocoa), and that line's rect.
    func hit(_ point: CGPoint) -> (fix: Int, rect: CGRect)? {
        guard panel.isVisible, panel.alphaValue > 0, !stale else { return nil }
        guard clip.insetBy(dx: -2, dy: -6).contains(point) else { return nil }
        for mark in view.marks {
            for r in mark.rects where Self.hitRect(r).contains(point) { return (mark.fix, r) }
        }
        return nil
    }

    /// The word plus the wave below it, with a little slack.
    private static func hitRect(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX - 2, y: r.minY - 5, width: r.width + 4, height: r.height + 6)
    }

    /// `appliedFlash`: `ok` at 40% fading to clear over 1.4 s on each rect. Skipped with Reduce Motion.
    func flash(_ rects: [CGRect]) {
        guard panel.isVisible, !DS.Motion.reduceMotion, let root = view.layer else { return }
        var color: CGColor = NSColor.clear.cgColor
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor(DS.ok).withAlphaComponent(0.4).cgColor
        }
        for r in rects {
            let layer = CALayer()
            layer.frame = r.offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
            layer.cornerRadius = DS.Radius.underline
            layer.backgroundColor = color
            layer.opacity = 0
            root.addSublayer(layer)
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = DS.Motion.appliedFlashDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            CATransaction.begin()
            CATransaction.setCompletionBlock { layer.removeFromSuperlayer() }
            layer.add(fade, forKey: "appliedFlash")
            CATransaction.commit()
        }
    }
}

/// Draws the marks. Coordinates are the panel's (Cocoa, y up).
private final class UnderlineView: NSView {
    var marks: [UnderlineMark] = []
    var clip: CGRect = .zero
    var current: Int?
    var hovered: Int?

    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let window else { return }
        NSGraphicsContext.saveGraphicsState()
        // The wave sits below the last visible line, so let it out of the clip a little at the bottom.
        NSBezierPath(rect: CGRect(x: clip.minX - 4, y: clip.minY - 6, width: clip.width + 8, height: clip.height + 8)).addClip()
        // Increase Contrast (§11): a 2 pt wave, and a stronger fill on the current and hovered fix.
        let high = DS.A11y.increaseContrast
        for mark in marks {
            let color = NSColor(mark.category.color)
            for screenRect in mark.rects {
                let r = screenRect.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
                if mark.fix == current {
                    // 17% fill plus a 2 pt ring at 17%, which together read as one 17% shape 2 pt larger.
                    color.withAlphaComponent(high ? 0.28 : 0.17).setFill()
                    NSBezierPath(roundedRect: r.insetBy(dx: -2, dy: -2), xRadius: DS.Radius.underline + 2,
                                 yRadius: DS.Radius.underline + 2).fill()
                } else if mark.fix == hovered {
                    color.withAlphaComponent(high ? 0.18 : 0.10).setFill()
                    NSBezierPath(roundedRect: r, xRadius: DS.Radius.underline, yRadius: DS.Radius.underline).fill()
                }
                color.setStroke()
                // AX rects end at the descent, about 3 pt below the baseline in body text, so this sits ~4 pt
                // below the baseline (§5.3) without touching the next line in tightly set text.
                let wave = Self.wave(from: r.minX, to: r.maxX, y: r.minY - 1)
                if high { wave.lineWidth = 2 }
                wave.stroke()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Wavy line: 1.5 pt stroke, wavelength 4 pt, amplitude 1.5 pt, centered on `y`.
    static func wave(from x0: CGFloat, to x1: CGFloat, y: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let amplitude: CGFloat = 1.5, wavelength: CGFloat = 4, step: CGFloat = 0.5
        var x = x0
        path.move(to: CGPoint(x: x, y: y + amplitude))
        while x < x1 {
            x = min(x + step, x1)
            path.line(to: CGPoint(x: x, y: y + amplitude * cos((x - x0) / wavelength * 2 * .pi)))
        }
        return path
    }
}
