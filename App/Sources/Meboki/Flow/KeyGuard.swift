import AppKit
import CoreGraphics

/// Keeps the review keys away from the target app while fixes are being written (Optimization A).
///
/// An apply runs on the main thread and hides the popup before its first paste, so a second ⏎ pressed because
/// the apply felt slow went to the app: in Discord and Claude desktop it sent the message (2026-11-16). While the
/// guard is on, an event tap on its own thread (the main thread is busy writing) drops ⏎, keypad Enter, ⇥ and
/// the arrows, and after Apply all (which closes the popup) ⏎ for a short moment more. Esc is dropped as well and asks the running
/// apply to stop after its current write (`stopRequested`).
///
/// Only those keys are dropped. Any other key reaches the app; typing changes the field, and the next write's
/// checks then stop the apply. Meboki's own ⌘V and Delete pass. Without the tap (no permission) the guard
/// does nothing.
final class KeyGuard: @unchecked Sendable {
    static let shared = KeyGuard()

    /// How long ⏎ stays blocked after an apply ends: a double press lands just after a fast apply.
    static let returnTail: TimeInterval = 0.5

    private let lock = NSLock()
    private var active = false
    private var returnUntil = Date.distantPast
    private var stop = false
    /// Key codes whose key-down was dropped: their key-up is dropped too.
    private var held = Set<Int64>()
    private var swallowed = 0
    private var tap: CFMachPort?
    private var thread: Thread?
    /// The tap was tried once (it may have failed: then the guard stays off rather than retrying every apply).
    private var tried = false

    private static let returnKeys: Set<Int64> = [36, 76]
    private static let otherKeys: Set<Int64> = [48, 123, 124, 125, 126]
    private static let esc: Int64 = 53

    /// Esc was pressed since `begin`: the apply stops after its current write.
    var stopRequested: Bool { lock.withLock { stop } }

    /// Starts dropping the review keys. Call before the first write.
    func begin() {
        lock.withLock {
            active = true
            stop = false
            swallowed = 0
            // A key-up lost while the tap was off must not make the guard drop a later one.
            held.removeAll()
        }
        startTap()
    }

    /// Stops dropping keys. `tail`: ⏎ stays dropped for `returnTail` (Apply all closed the popup, so a second ⏎
    /// would reach the app). Not after a single fix: the island or card may still be up for the next ⇧⏎.
    /// Returns how many key presses were dropped.
    @discardableResult
    func end(tail: Bool = false) -> Int {
        lock.withLock {
            active = false
            if tail { returnUntil = Date().addingTimeInterval(Self.returnTail) }
            return swallowed
        }
    }

    /// The tap's decision for one event. Called on the tap thread.
    private func shouldDrop(_ type: CGEventType, code: Int64) -> Bool {
        lock.withLock {
            if type == .keyUp {
                return held.remove(code) != nil
            }
            let drop: Bool
            if Self.returnKeys.contains(code) {
                drop = active || Date() < returnUntil
            } else if code == Self.esc {
                drop = active
                if active { stop = true }
            } else {
                drop = active && Self.otherKeys.contains(code)
            }
            if drop {
                held.insert(code)
                swallowed += 1
            }
            return drop
        }
    }

    // MARK: Event tap

    /// One tap for the app's lifetime, on its own run-loop thread; it's cheap while the guard is off (a lock and a
    /// set lookup per key) and is created on the first apply, not at launch.
    private func startTap() {
        let (existing, first) = lock.withLock { () -> (CFMachPort?, Bool) in
            defer { tried = true }
            return (tap, !tried)
        }
        guard first else {
            if let existing { CGEvent.tapEnable(tap: existing, enable: true) }
            return
        }
        let ready = DispatchSemaphore(value: 0)
        let t = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            let callback: CGEventTapCallBack = { _, type, event, info in
                guard let info else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<KeyGuard>.fromOpaque(info).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    me.lock.withLock { me.held.removeAll() }
                    if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                let code = event.getIntegerValueField(.keyboardEventKeycode)
                return me.shouldDrop(type, code: code) ? nil : Unmanaged.passUnretained(event)
            }
            guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                               options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                               callback: callback,
                                               userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                Log.write("key guard: no event tap (permission?); keys aren't held during an apply")
                ready.signal()
                return
            }
            self.lock.withLock { self.tap = port }
            let source = CFMachPortCreateRunLoopSource(nil, port, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        t.name = "Meboki.KeyGuard"
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
        // The tap must be in place before the first write hides the popup.
        _ = ready.wait(timeout: .now() + 0.5)
    }
}
