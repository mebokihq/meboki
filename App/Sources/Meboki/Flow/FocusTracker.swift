import AppKit
import ApplicationServices
import Carbon

/// Follows the focused element of the frontmost app while checking as you type is on (Milestone B, PLAN.md §2
/// "FocusTracker"), so a field gets checked after a typing pause without the hotkey.
///
/// - `NSWorkspace` app activation: the tracker moves to the new frontmost app.
/// - `AXObserver` on that app: `kAXFocusedUIElementChangedNotification` (focus moved), and on the focused
///   element `kAXValueChangedNotification` (the user typed). An editable web area (Mail compose) may not post
///   value changes while the user types, so its `kAXSelectedTextChangedNotification` (the caret moved) counts
///   too; `onEdit` says which one came.
///
/// It reads no text and decides nothing; `AppDelegate` decides whether a field is checked. Meboki's own
/// windows are skipped (the tracker stays on the last other app). Only notifications are used: no global key
/// monitor while no review is up.
@MainActor
final class FocusTracker {
    /// Focus moved to `element` in app `pid` (nil: nothing focused, or no app to follow).
    var onFocus: ((AXUIElement?, pid_t) -> Void)?
    /// The focused element's value changed (typing, paste, undo, or a write by Meboki). `caretOnly`: only
    /// the caret moved (editable web areas), so the text may be the same as before.
    var onEdit: ((AXUIElement, pid_t, _ caretOnly: Bool) -> Void)?
    /// Whether to follow an app at all. Apps it refuses (paused, Off, terminals, code editors) get no observer
    /// and no accessibility switches, and nothing in them is read.
    var shouldFollow: ((NSRunningApplication) -> Bool)?

    private(set) var pid: pid_t?
    private(set) var element: AXUIElement?
    /// `element` is an editable web area, also observed for caret moves.
    private var elementIsWebArea = false
    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var activation: NSObjectProtocol?
    /// A second look at the focused element shortly after a focus notification.
    private var settle: DispatchWorkItem?
    /// While nothing, or something other than a text area, is focused right after a text area was: looks again every
    /// 0.5 s (up to 5 min). Electron reports no focused element while one of Meboki's panels is key, and posts
    /// no focus change when the same field gets the keys back; TextEdit posts none when a sheet closes. Without this
    /// the field would stay unwatched until the user clicked elsewhere.
    private var refocusTimer: Timer?
    private var refocusUntil: Date?
    private(set) var isRunning = false

    /// AX calls into the tracked app time out after this (default 6 s): a hung app must not freeze Meboki.
    private static let messagingTimeout: Float = 1

    func start() {
        guard !isRunning else { return }
        isRunning = true
        activation = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.follow(app) }
        }
        follow(NSWorkspace.shared.frontmostApplication)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        if let activation { NSWorkspace.shared.notificationCenter.removeObserver(activation) }
        activation = nil
        detach()
    }

    /// Follows the frontmost app again: the rules in `shouldFollow` changed, or Accessibility was just granted.
    func retarget() {
        guard isRunning else { return }
        detach(report: true)
        follow(NSWorkspace.shared.frontmostApplication)
    }

    /// The tracked app's focused element is `el`, asked through the app element with the short timeout.
    func isFocused(_ el: AXUIElement) -> Bool {
        guard let f = focusedElement() else { return false }
        return CFEqual(f, el)
    }

    // MARK: App

    private func follow(_ app: NSRunningApplication?) {
        guard isRunning, let app, app.processIdentifier != getpid() else { return }
        if app.processIdentifier == pid, observer != nil { return }
        detach(report: true)
        guard AX.isTrusted(prompt: false), shouldFollow?(app) ?? true else { return }
        let pid = app.processIdentifier
        // Electron and Chromium keep their accessibility tree off until asked (as for the hotkey check).
        AX.prepare(app: app)
        var obs: AXObserver?
        guard AXObserverCreate(pid, { _, el, name, refcon in
            guard let refcon else { return }
            let tracker = Unmanaged<FocusTracker>.fromOpaque(refcon).takeUnretainedValue()
            let n = name as String
            MainActor.assumeIsolated { tracker.handle(n, from: el) }
        }, &obs) == .success, let obs else {
            Log.write("focus: can't observe \(app.bundleIdentifier ?? "pid \(pid)") (AXObserverCreate failed)")
            return
        }
        self.pid = pid
        observer = obs
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, Self.messagingTimeout)
        appElement = appEl
        add(appEl, kAXFocusedUIElementChangedNotification)
        focusChanged()
    }

    /// Stops following the app. `report`: tell the delegate nothing is focused any more (when something was).
    private func detach(report: Bool = false) {
        let had = pid.map { ($0, element != nil) }
        if let observer {
            if let appElement { AXObserverRemoveNotification(observer, appElement, kAXFocusedUIElementChangedNotification as CFString) }
            if let element { removeElementNotifications(observer, element) }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        settle?.cancel()
        settle = nil
        stopRefocus()
        appElement = nil
        element = nil
        pid = nil
        if report, let (oldPid, hadElement) = had, hadElement { onFocus?(nil, oldPid) }
    }

    /// The app's focused element, through the app element (1 s timeout). Nil when nothing is focused.
    private func focusedElement() -> AXUIElement? {
        guard let appElement, let v = AX.copy(appElement, kAXFocusedUIElementAttribute),
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    // MARK: Element

    private func handle(_ name: String, from el: AXUIElement) {
        switch name {
        case kAXFocusedUIElementChangedNotification:
            // The notification names the new element; the app's `AXFocusedUIElement` can still report the old
            // one at this moment (TextEdit opening a window), so ask again once things settled.
            focusChanged(to: el)
            settle?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.focusChanged() }
            settle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
        case kAXValueChangedNotification, kAXSelectedTextChangedNotification:
            guard let element, let pid, CFEqual(el, element) else { return }
            onEdit?(element, pid, name == kAXSelectedTextChangedNotification)
        default:
            break
        }
    }

    /// Moves the value observer to the element that has focus now (`candidate`, from the notification, or the
    /// app's answer), and reports it.
    private func focusChanged(to candidate: AXUIElement? = nil) {
        guard let pid else { return }
        var owner: pid_t = 0
        let named = candidate.flatMap { el -> AXUIElement? in
            AXUIElementGetPid(el, &owner) == .success && owner == pid ? el : nil
        }
        // Nothing is looked at while Secure Input is on (a password field somewhere), and a secure field is
        // never observed.
        let focused = IsSecureEventInputEnabled() ? nil
            : (named ?? focusedElement()).flatMap { AX.isSecureField($0) ? nil : $0 }
        if let focused, let element, CFEqual(focused, element) { return }
        // A canvas that hides its document until asked (Pages, `CanvasWake`): ask once, then look again. The app
        // posts no focus change when its text element appears.
        if let focused, CanvasWake.nudge(focused, pid: pid) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.focusChanged() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.focusChanged() }
        }
        // Left a text area for nothing, or for something that isn't one (a sheet's field: TextEdit's ⌘K link
        // sheet): look again until a text area has focus. TextEdit posts no focus change when the sheet closes and
        // the document gets the keys back (2026-11-16).
        if focused.map(AX.isEditableTextArea) ?? false {
            stopRefocus()
        } else if element.map(AX.isEditableTextArea) ?? false {
            startRefocus()
        }
        if let observer, let element { removeElementNotifications(observer, element) }
        element = focused
        elementIsWebArea = false
        if let focused {
            AXUIElementSetMessagingTimeout(focused, Self.messagingTimeout)
            add(focused, kAXValueChangedNotification)
            if AX.isEditableWebArea(focused) {
                elementIsWebArea = true
                add(focused, kAXSelectedTextChangedNotification)
            }
        }
        onFocus?(focused, pid)
    }

    private func startRefocus() {
        refocusUntil = Date().addingTimeInterval(300)
        guard refocusTimer == nil else { return }
        refocusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let until = self.refocusUntil, Date() > until { self.stopRefocus(); return }
                if let el = self.element, AX.isEditableTextArea(el) { self.stopRefocus(); return }
                self.focusChanged()
            }
        }
    }

    private func stopRefocus() {
        refocusTimer?.invalidate()
        refocusTimer = nil
        refocusUntil = nil
    }

    private func removeElementNotifications(_ observer: AXObserver, _ el: AXUIElement) {
        AXObserverRemoveNotification(observer, el, kAXValueChangedNotification as CFString)
        if elementIsWebArea { AXObserverRemoveNotification(observer, el, kAXSelectedTextChangedNotification as CFString) }
    }

    private func add(_ el: AXUIElement, _ name: String) {
        guard let observer else { return }
        AXObserverAddNotification(observer, el, name as CFString, Unmanaged.passUnretained(self).toOpaque())
    }
}
