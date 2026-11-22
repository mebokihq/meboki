import Foundation

/// When the key guard (an event tap that drops ⏎ and a few review keys while fixes are written) must give the
/// keys back even though nobody ended it. Pure state and clock, so it is unit-tested; the tap itself lives in the
/// app. A guard that holds keys with no write going on is a keyboard that doesn't work in any app.
public struct KeyGuardPolicy: Equatable, Sendable {
    /// Without a write (or a `begin`) for this long, an active guard is stuck.
    public static let idleCap: TimeInterval = 4
    /// An active guard never outlives this, whatever the activity.
    public static let hardCap: TimeInterval = 120
    /// ⏎ stays dropped this long after Apply all ends.
    public static let returnTail: TimeInterval = 0.5

    public private(set) var active = false
    public private(set) var returnUntil = Date.distantPast
    public private(set) var began = Date.distantPast
    public private(set) var lastActivity = Date.distantPast

    public init() {}

    public mutating func begin(at now: Date) {
        active = true
        began = now
        lastActivity = now
    }

    /// A write started or finished: the apply is alive.
    public mutating func touch(at now: Date) {
        if active { lastActivity = now }
    }

    public mutating func end(tail: Bool, at now: Date) {
        active = false
        if tail { returnUntil = now.addingTimeInterval(Self.returnTail) }
    }

    /// Whether ⏎ and the review keys are held at `now`.
    public func holdsKeys(at now: Date) -> Bool { active || now < returnUntil }

    /// Seconds the guard has been stuck at `now`, or nil when it is fine. A stuck guard is released (`release`).
    public func stuckFor(at now: Date) -> TimeInterval? {
        guard active else { return nil }
        let idle = now.timeIntervalSince(lastActivity), total = now.timeIntervalSince(began)
        guard idle > Self.idleCap || total > Self.hardCap else { return nil }
        return total
    }

    /// Gives every key back: no apply, no tail.
    public mutating func release() {
        active = false
        returnUntil = .distantPast
    }
}
