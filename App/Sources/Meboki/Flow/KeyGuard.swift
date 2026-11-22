import AppKit
import CoreGraphics
import MebokiCore

/// Keeps the review keys away from the target app while fixes are being written (Optimization A).
///
/// An apply runs on the main thread and hides the popup before its first paste, so a second ⏎ pressed because
/// the apply felt slow went to the app: in Discord and Claude desktop it sent the message (2026-11-16). While the
/// guard is on, an event tap on its own thread (the main thread is busy writing) drops ⏎, keypad Enter, ⇥ and
/// the arrows, and after Apply all (which closes the popup) ⏎ for a short moment more. Esc is dropped as well and asks the running
/// apply to stop after its current write (`stopRequested`).
///
/// Only those keys are dropped. Any other key reaches the app; typing changes the field, and the next write's
/// checks then stop the apply. Meboki's own ⌘V and Delete pass. ⇥, the arrows and Esc pass when ⌘, ⌃ or ⌥ is
/// held, so ⌘⇥ (the app switcher) and other system shortcuts always work (Esc with a modifier still stops the
/// apply); ⏎ is dropped with any modifier (⌘⏎
/// sends in chat apps). Without the tap (no permission) the guard does nothing.
///
/// The tap is enabled only while the guard is on (and for the ⏎ tail after it): outside an apply Meboki holds no
/// active tap, so a stall in this process can never hold up the keyboard.
final class KeyGuard: @unchecked Sendable {
    static let shared = KeyGuard()

    /// How long ⏎ stays blocked after an apply ends: a double press lands just after a fast apply.
    static let returnTail = KeyGuardPolicy.returnTail

    private let lock = NSLock()
    /// Whether keys are held and when a stuck guard gives up (`KeyGuardPolicy`, unit-tested).
    private var policy = KeyGuardPolicy()
    private var active: Bool { policy.active }
    private var watchdog: DispatchSourceTimer?
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
    /// With one of these held, ⇥, the arrows and Esc are a shortcut (⌘⇥, ⌃→, ⌥⌘Esc), not a review key.
    private static let shortcutFlags: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]

    /// Esc was pressed since `begin`: the apply stops after its current write.
    var stopRequested: Bool { lock.withLock { stop } }

    /// Starts dropping the review keys. Call before the first write.
    func begin() {
        lock.withLock {
            policy.begin(at: Date())
            stop = false
            swallowed = 0
            // A key-up lost while the tap was off must not make the guard drop a later one.
            held.removeAll()
        }
        Log.write("key guard: begin")
        startTap()
        startWatchdog()
    }

    /// Runs `body` with the guard on; the guard ends however `body` leaves (`defer`), so a begin is never left open.
    func holding<T>(tail: Bool = false, _ body: () -> T) -> T {
        begin()
        defer { end(tail: tail) }
        return body()
    }

    var isOn: Bool { lock.withLock { policy.active } }

    /// A write is going on: the apply is alive, so the watchdog leaves the guard alone.
    func touch() { lock.withLock { policy.touch(at: Date()) } }

    /// Stops dropping keys. `tail`: ⏎ stays dropped for `returnTail` (Apply all closed the popup, so a second ⏎
    /// would reach the app). Not after a single fix: the island or card may still be up for the next ⇧⏎.
    /// Returns how many key presses were dropped.
    @discardableResult
    func end(tail: Bool = false) -> Int {
        let count = lock.withLock { () -> Int in
            policy.end(tail: tail, at: Date())
            return swallowed
        }
        Log.write("key guard: end\(tail ? " (⏎ held \(Self.returnTail) s more)" : ""), \(count) key press(es) held")
        if tail {
            // A bit past the tail, so the check below finds it over.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.returnTail + 0.05) { [weak self] in
                self?.disableTapIfIdle()
            }
        } else {
            disableTapIfIdle()
        }
        return count
    }

    /// Whether the tap must stay enabled: the guard is on, or ⏎ is still in its tail.
    private var needed: Bool { lock.withLock { policy.holdsKeys(at: Date()) } }

    /// Turns the tap off when the guard has nothing left to hold (a `begin` since then keeps it on).
    private func disableTapIfIdle() {
        lock.withLock {
            if !policy.holdsKeys(at: Date()), let tap {
                CGEvent.tapEnable(tap: tap, enable: false)
                held.removeAll()
                watchdog?.cancel()
                watchdog = nil
                Log.write("key guard: tap off")
            }
        }
    }

    /// Hard stop for a guard that was never ended (a code path that returned between `begin` and `end`): checked
    /// twice a second, and also by the tap itself on every key. Releases the keys, turns the tap off and logs it.
    private func startWatchdog() {
        lock.withLock {
            guard watchdog == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInteractive))
            timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
            timer.setEventHandler { [weak self] in self?.checkStuck() }
            watchdog = timer
            timer.resume()
        }
    }

    /// Releases a stuck guard. True when it was stuck.
    @discardableResult
    private func checkStuck() -> Bool {
        let stuck = lock.withLock { () -> TimeInterval? in
            guard let seconds = policy.stuckFor(at: Date()) else { return nil }
            policy.release()
            held.removeAll()
            stop = false
            if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
            watchdog?.cancel()
            watchdog = nil
            return seconds
        }
        guard let stuck else { return false }
        Log.write(String(format: "key guard: released after %.0f s (stuck)", stuck))
        // Whether the main thread was blocked (a write that never returns) or free (an end that never came).
        let sent = Date()
        DispatchQueue.main.async {
            Log.write(String(format: "key guard: main thread ran again %.1f s after the release", Date().timeIntervalSince(sent)))
        }
        return true
    }

    /// The tap's decision for one event. Called on the tap thread.
    private func shouldDrop(_ type: CGEventType, code: Int64, flags: CGEventFlags) -> Bool {
        // A stuck guard lets this event through, and every later one.
        if checkStuck() { return false }
        return lock.withLock {
            if type == .keyUp {
                return held.remove(code) != nil
            }
            let shortcut = !flags.intersection(Self.shortcutFlags).isEmpty
            let drop: Bool
            if Self.returnKeys.contains(code) {
                drop = policy.holdsKeys(at: Date())
            } else if shortcut {
                // A shortcut reaches the app; Esc with a modifier still stops Apply all.
                drop = false
                if code == Self.esc, active { stop = true }
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

    /// One tap for the app's lifetime, on its own run-loop thread, created on the first apply, not at launch.
    /// It is enabled by `begin` and disabled again once the guard ends (`disableTapIfIdle`).
    private func startTap() {
        let (existing, first) = lock.withLock { () -> (CFMachPort?, Bool) in
            defer { tried = true }
            return (tap, !tried)
        }
        guard first else {
            if let existing {
                CGEvent.tapEnable(tap: existing, enable: true)
                Log.write("key guard: tap on")
            }
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
                    // Back on only while an apply needs it; otherwise it stays off as `end` would leave it.
                    if me.needed, let tap = me.lock.withLock({ me.tap }) { CGEvent.tapEnable(tap: tap, enable: true) }
                    return Unmanaged.passUnretained(event)
                }
                let code = event.getIntegerValueField(.keyboardEventKeycode)
                return me.shouldDrop(type, code: code, flags: event.flags) ? nil : Unmanaged.passUnretained(event)
            }
            guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                               options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                               callback: callback,
                                               userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
                Log.write("key guard: no event tap (permission?); keys aren't held during an apply")
                ready.signal()
                return
            }
            let source = CFMachPortCreateRunLoopSource(nil, port, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            // `begin` waits only so long: if the apply already ended, `end` found no tap to turn off, so the tap
            // goes on only while the guard still needs it. Under the lock, like `disableTapIfIdle`.
            self.lock.withLock {
                self.tap = port
                CGEvent.tapEnable(tap: port, enable: self.policy.holdsKeys(at: Date()))
                Log.write("key guard: tap created")
            }
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
