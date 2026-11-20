import AppKit
import ApplicationServices

/// LibreOffice's toolkit (VCL) flips y with the wrong screen height on a Mac with more than one display.
/// Its windows are right, but everything inside them is off, in two different ways (AX coordinates, y down):
///
/// - element frames (`AXPosition`): too high by (desktop height − height of the window's screen);
/// - `AXBoundsForRange`: too low by (height of the window's screen − height of the primary screen).
///
/// Measured with LibreOffice 26.8 on two displays (an external one above the built-in), with the window on either
/// one; x is always right. With a single display both shifts are 0. A shift that still lands outside the window
/// is caught by `AX.visibleFrame`, which then clips to the window, so a wrong guess gives no underlines rather
/// than misplaced ones.
enum VCLGeometry {
    static let bundleIDs: Set<String> = ["org.libreoffice.script"]

    /// How far to move an element's AX frame down, or nil when no correction applies.
    static func elementShift(_ el: AXUIElement) -> CGFloat? {
        guard let h = heights(el), h.desktop != h.screen else { return nil }
        return h.desktop - h.screen
    }

    /// How far to move an `AXBoundsForRange` rect down, or nil when no correction applies.
    static func boundsShift(_ el: AXUIElement) -> CGFloat? {
        guard let h = heights(el), h.primary != h.screen else { return nil }
        return h.primary - h.screen
    }

    /// Desktop (all displays), window's screen and primary screen heights for an element inside a VCL window.
    private static func heights(_ el: AXUIElement) -> (desktop: CGFloat, screen: CGFloat, primary: CGFloat)? {
        guard isVCL(el), let window = AX.window(of: el), !CFEqual(window, el),
              let w = AX.axFrame(window) else { return nil }
        let screens = NSScreen.screens
        guard screens.count > 1, let primary = screens.first?.frame else { return nil }
        // The window's AX frame → Cocoa, to find its screen (the window's own frame is reported correctly).
        let mid = CGPoint(x: w.midX, y: primary.maxY - w.midY)
        guard let screen = screens.first(where: { $0.frame.contains(mid) })?.frame else { return nil }
        let top = screens.map(\.frame.maxY).max() ?? primary.maxY
        let bottom = screens.map(\.frame.minY).min() ?? primary.minY
        return (top - bottom, screen.height, primary.height)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var known: [pid_t: Bool] = [:]

    private static func isVCL(_ el: AXUIElement) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(el, &pid) == .success else { return false }
        lock.lock(); defer { lock.unlock() }
        if let v = known[pid] { return v }
        let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        let v = id.map(bundleIDs.contains) ?? false
        known[pid] = v
        return v
    }
}
