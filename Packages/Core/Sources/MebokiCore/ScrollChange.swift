import Foundation

/// Tells a text change that came from scrolling from one the user made.
///
/// Some editors keep only the lines near the screen in their field (Obsidian's CodeMirror: a 10 800-character note
/// reported 1 800 to 2 800 characters, a different slice after each scroll, probed 2026-11-22). Their text changes
/// when the user scrolls, with no key pressed. A change seen shortly after a scroll, with no key since that scroll,
/// is taken as such a change: the field's text follows the scroll (`TextSurface.textFollowsScroll`).
///
/// Keys that scroll (arrows, Page Down) count as keys, so a field is only ever learned from a wheel or trackpad
/// scroll: never a typed edit taken for a scroll.
public struct ScrollChangeDetector: Sendable, Equatable {
    /// How long after a scroll a text change still counts as caused by it. Editors re-render a moment after the
    /// scroll (Obsidian: ~0.1–0.7 s).
    public var window: TimeInterval
    private var lastScroll: Date?
    private var lastKey: Date?

    public init(window: TimeInterval = 1.5) {
        self.window = window
    }

    public mutating func scrolled(at t: Date) { lastScroll = t }
    public mutating func keyPressed(at t: Date) { lastKey = t }

    /// How long to wait at `t` before showing underlines in a field that is still moving: until neither a scroll nor
    /// a text change (`textMovedAt`) happened for `quiet` seconds. 0 when it's quiet already. Obsidian changes its
    /// text two or three times within ~1 s after one scroll (2026-11-22), and two measurements 0.1 s apart can agree
    /// while both are stale, so agreement alone isn't enough.
    public func settleDelay(at t: Date, textMovedAt: Date?, quiet: TimeInterval = 0.35) -> TimeInterval {
        let last = [lastScroll, textMovedAt].compactMap { $0 }.max()
        guard let last else { return 0 }
        return max(0, quiet - t.timeIntervalSince(last))
    }

    /// A text change seen at `t` came from scrolling: a scroll at most `window` before it, and no key pressed since
    /// that scroll.
    public func isScrollChange(at t: Date) -> Bool {
        guard let s = lastScroll, s <= t, t.timeIntervalSince(s) <= window else { return false }
        if let k = lastKey, k >= s { return false }
        return true
    }
}
