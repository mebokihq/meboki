import AppKit
import ApplicationServices

/// Watches the field and the user's input while a review session is up (design_code.md §5.3), and reports
/// what happened. It decides nothing itself; `AppDelegate` does.
///
/// - Accessibility notifications (only with `observeField`): the field's value changed, the field went away,
///   focus moved to another element, the field's window moved or resized, a scroll bar moved.
/// - Global event monitors (observe only, never swallow): key presses, clicks, pointer moves, scrolling.
///   Events aimed at Meboki's own panels are local and never reach these.
/// - A slow timer, so `AppDelegate` can notice layout changes the app doesn't announce.
@MainActor
final class FieldWatcher {
    var onValueChanged: (() -> Void)?
    var onFieldGone: (() -> Void)?
    var onFocusChanged: (() -> Void)?
    /// The window moved or resized, or the field scrolled: the underline rects are stale.
    var onLayoutChanged: (() -> Void)?
    /// A key press in another app (key code).
    var onKey: ((UInt16) -> Void)?
    /// A click in another app (screen point, Cocoa coordinates), including clicks on underlined words: the
    /// overlay lets clicks through. Clicks on the card are local events and don't come here.
    var onClick: ((CGPoint) -> Void)?
    var onMouseMoved: ((CGPoint) -> Void)?
    var onTick: (() -> Void)?

    private let element: AXUIElement
    private var observer: AXObserver?
    private var registered: [(AXUIElement, String)] = []
    private var monitors: [Any] = []
    private var timer: Timer?

    init(pid: pid_t, element: AXUIElement, observeField: Bool) {
        self.element = element
        installMonitors()
        guard observeField else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTick?() }
        }
        installObserver(pid: pid)
    }

    /// Removes every monitor and observer. Call when the session ends.
    func stop() {
        timer?.invalidate()
        timer = nil
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors = []
        if let observer {
            for (el, name) in registered { AXObserverRemoveNotification(observer, el, name as CFString) }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        registered = []
        observer = nil
        onValueChanged = nil; onFieldGone = nil; onFocusChanged = nil; onLayoutChanged = nil
        onKey = nil; onClick = nil; onMouseMoved = nil; onTick = nil
    }

    // MARK: Global monitors

    private func installMonitors() {
        let add: (NSEvent.EventTypeMask, @escaping (NSEvent) -> Void) -> Void = { [weak self] mask, handler in
            if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) { self?.monitors.append(m) }
        }
        add(.keyDown) { [weak self] e in
            let code = e.keyCode
            MainActor.assumeIsolated { self?.onKey?(code) }
        }
        add([.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let p = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.onClick?(p) }
        }
        add([.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            let p = NSEvent.mouseLocation
            MainActor.assumeIsolated { self?.onMouseMoved?(p) }
        }
        add(.scrollWheel) { [weak self] _ in
            MainActor.assumeIsolated { self?.onLayoutChanged?() }
        }
    }

    // MARK: Accessibility notifications

    private func installObserver(pid: pid_t) {
        var obs: AXObserver?
        guard AXObserverCreate(pid, { _, el, name, refcon in
            guard let refcon else { return }
            let watcher = Unmanaged<FieldWatcher>.fromOpaque(refcon).takeUnretainedValue()
            let n = name as String
            MainActor.assumeIsolated { watcher.handle(n, from: el) }
        }, &obs) == .success, let obs else {
            Log.write("underlines: can't observe the field (AXObserverCreate failed)")
            return
        }
        observer = obs
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)

        register(element, kAXValueChangedNotification)
        register(element, kAXUIElementDestroyedNotification)
        register(AXUIElementCreateApplication(pid), kAXFocusedUIElementChangedNotification)
        if let window = AX.window(of: element) {
            register(window, kAXMovedNotification)
            register(window, kAXResizedNotification)
        }
        if let scroll = AX.scrollArea(around: element) {
            for attr in [kAXVerticalScrollBarAttribute, kAXHorizontalScrollBarAttribute] {
                if let bar = AX.element(scroll, attr) { register(bar, kAXValueChangedNotification) }
            }
        }
    }

    private func register(_ el: AXUIElement, _ name: String) {
        guard let observer else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if AXObserverAddNotification(observer, el, name as CFString, refcon) == .success {
            registered.append((el, name))
        }
    }

    /// A value change from the field is an edit; from a scroll bar, a scroll.
    private func handle(_ name: String, from el: AXUIElement) {
        switch name {
        case kAXValueChangedNotification:
            if CFEqual(el, element) { onValueChanged?() } else { onLayoutChanged?() }
        case kAXUIElementDestroyedNotification:
            onFieldGone?()
        case kAXFocusedUIElementChangedNotification:
            onFocusChanged?()
        default:
            onLayoutChanged?()
        }
    }
}
