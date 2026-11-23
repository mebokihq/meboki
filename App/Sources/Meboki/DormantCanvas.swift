import AppKit
import ApplicationServices

/// AppKit apps that draw their document on a canvas and build its accessibility tree only once an assistive app
/// asks for it. Until then the focused element is the canvas's scroll area, holding nothing but its scroll bars, so
/// there is no text to read (Pages, probed 2026-11-23: a cold Pages reports `AXScrollArea` with two `AXScrollBar`
/// children; setting `AXEnhancedUserInterface` on the app gives `AXLayoutArea` › `AXPage` › `AXTextArea "Body"` at
/// once, and the tree stays for every document until the app quits; `AXManualAccessibility` is unsupported there).
///
/// Recognised by the tree's shape, not the app: a focused scroll area whose children are all scroll bars. Each
/// app is woken once (per process): an app whose empty scroll area is really empty costs one set attribute and,
/// on the hotkey path, one short wait.
enum CanvasWake {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var tried: Set<pid_t> = []
    /// How long the hotkey path waits for the woken app to report its text element.
    static let wait: TimeInterval = 0.5

    /// `el` is a scroll area that has keyboard focus itself and whose content isn't exposed: it has children and
    /// every one is a scroll bar. (Finder's preview pane has the same shape, probed 2026-11-23, but never focus.)
    static func isDormant(_ el: AXUIElement) -> Bool {
        guard AX.string(el, kAXRoleAttribute) == kAXScrollAreaRole as String,
              AX.copy(el, kAXFocusedAttribute) as? Bool == true else { return false }
        let kids = (AX.copy(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
        return !kids.isEmpty && kids.allSatisfy { AX.string($0, kAXRoleAttribute) == kAXScrollBarRole as String }
    }

    /// Asks the app for its full tree, once per process. True when this call sent the request (the caller may then
    /// look at the focus again); false when `el` isn't dormant or the app was asked before.
    @discardableResult
    static func nudge(_ el: AXUIElement, pid: pid_t) -> Bool {
        guard isDormant(el) else { return false }
        lock.lock()
        let first = tried.insert(pid).inserted
        if tried.count > 64 { tried = [pid] }
        lock.unlock()
        guard first else { return false }
        // AppKit answers "not implemented" (-25208) but turns its accessibility tree on all the same.
        let result = AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid),
                                                  "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        Log.write("canvas: focused scroll area exposes no content, asked the app for its tree (\(result.rawValue))")
        return true
    }

    /// Wakes the app (`nudge`) and waits for the element that has focus after it: up to `wait` the first time, a
    /// short look after that (the automatic check may have asked a moment before the hotkey). Nil when `el` isn't
    /// dormant or focus still sits on an empty scroll area.
    static func wake(_ el: AXUIElement, pid: pid_t) -> AXUIElement? {
        guard isDormant(el) else { return nil }
        let first = nudge(el, pid: pid)
        let deadline = Date().addingTimeInterval(first ? wait : 0.15)
        repeat {
            if let f = AX.focusedElement(pid: pid), !CFEqual(f, el), !isDormant(f) {
                Log.write("canvas: focus is now \(AX.string(f, kAXRoleAttribute) ?? "unknown")")
                return f
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        if first { Log.write("canvas: no text element after waking") }
        return nil
    }
}

/// A focused canvas scroll area that hides its document until asked (`CanvasWake`): wakes the app and resolves
/// the element that has focus then, with the other strategies (Pages' body is a plain `AXTextArea`).
struct DormantCanvasStrategy: SurfaceStrategy {
    var name: String { "dormant canvas" }

    func surface(for focused: AXUIElement, pid: pid_t) -> TextSurface? {
        guard let woken = CanvasWake.wake(focused, pid: pid) else { return nil }
        return SurfaceResolver.surface(for: woken, pid: pid)
    }
}
