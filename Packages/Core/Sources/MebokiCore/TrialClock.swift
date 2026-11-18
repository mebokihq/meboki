import Foundation

/// The 7-day trial (PLAN.md §6 "App-side licensing"). A day counts when at least one check ran on it. Days are
/// local calendar days stored as `yyyy-MM-dd`; the latest day seen stops a clock rollback from reviving the
/// trial. The app keeps two copies (Keychain and UserDefaults) and joins them with `merged(with:)`.
public struct TrialClock: Codable, Sendable, Equatable {
    public static let length = 7

    /// Active days, sorted, at most `length`.
    public private(set) var days: [String]
    /// The latest day seen, `yyyy-MM-dd`.
    public private(set) var lastSeen: String?

    public init(days: [String] = [], lastSeen: String? = nil) {
        self.days = Array(Set(days)).sorted().prefix(Self.length).map { $0 }
        self.lastSeen = lastSeen
    }

    /// `yyyy-MM-dd` in `calendar`'s time zone.
    public static func dayString(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Today, never earlier than the latest day seen.
    public func today(now: Date, calendar: Calendar) -> String {
        max(Self.dayString(now, calendar: calendar), lastSeen ?? "")
    }

    /// Remembers that `now` happened (call at launch and when the day changes), without counting a day.
    public mutating func observe(now: Date, calendar: Calendar) {
        lastSeen = today(now: now, calendar: calendar)
    }

    /// A check ran: counts today while the trial is on, never more than `length` days.
    public mutating func recordCheck(now: Date, calendar: Calendar) {
        observe(now: now, calendar: calendar)
        let t = today(now: now, calendar: calendar)
        if days.count < Self.length && !days.contains(t) {
            days.append(t)
            days.sort()
        }
    }

    /// On while fewer than 7 days are stored, or the 7th stored day is today (it stays full until midnight).
    public func isActive(now: Date, calendar: Calendar) -> Bool {
        days.count < Self.length || days[Self.length - 1] == today(now: now, calendar: calendar)
    }

    /// 7 minus stored days, counting today as left when it is already stored. 0 when the trial is over.
    public func daysLeft(now: Date, calendar: Calendar) -> Int {
        guard isActive(now: now, calendar: calendar) else { return 0 }
        let stored = days.contains(today(now: now, calendar: calendar)) ? 1 : 0
        return max(0, Self.length - days.count + stored)
    }

    /// The last trial day (shows "Last day").
    public func isLastDay(now: Date, calendar: Calendar) -> Bool {
        isActive(now: now, calendar: calendar) && daysLeft(now: now, calendar: calendar) == 1
    }

    /// Union of the days (the earliest 7) and the later of the two days seen.
    public func merged(with other: TrialClock) -> TrialClock {
        let seen = [lastSeen, other.lastSeen].compactMap { $0 }.max()
        return TrialClock(days: days + other.days, lastSeen: seen)
    }
}
