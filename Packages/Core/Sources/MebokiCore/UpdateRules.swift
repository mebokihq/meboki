import Foundation

/// Where an official build looks for updates: the feed address and the public key its updates are signed with.
/// Both come from the app's Info.plist (`SUFeedURL`, `SUPublicEDKey`), which only a release build carries; a
/// build without them (from source, a fork) has no updater at all.
public struct UpdateFeed: Equatable, Sendable {
    public let url: URL
    public let publicKey: String

    /// Nil unless the feed is HTTPS (or plain HTTP on this Mac itself, for a local test feed) and the key is
    /// a base64 Ed25519 public key (32 bytes).
    public init?(feed: String?, publicKey: String?) {
        guard let feed = feed?.trimmingCharacters(in: .whitespacesAndNewlines), !feed.isEmpty,
              let key = publicKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              Data(base64Encoded: key)?.count == 32,
              let url = URL(string: feed), let host = url.host, !host.isEmpty else { return nil }
        switch url.scheme?.lowercased() {
        case "https": break
        case "http": guard Self.isLoopback(host) else { return nil }
        default: return nil
        }
        self.url = url
        self.publicKey = key
    }

    /// A feed served from this Mac (the local update test).
    public var isLocal: Bool { Self.isLoopback(url.host ?? "") }

    static func isLoopback(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "localhost" || host == "::1" || host == "[::1]"
    }
}

/// When a downloaded update may be installed without asking ("Install updates automatically"): the install
/// quits and reopens the app, so it waits until nothing of Meboki's is in use and the user has been away
/// from the keyboard and mouse for a while.
public enum UpdateTiming {
    /// How long the keyboard and mouse must have been still.
    public static let quietSeconds: TimeInterval = 120

    /// - Parameters:
    ///   - busy: a check or a review runs, a popup or one of the app's windows is open, or a model downloads.
    ///   - secondsSinceInput: time since the last key press or mouse event on this Mac.
    public static func canInstallNow(busy: Bool, secondsSinceInput: TimeInterval) -> Bool {
        !busy && secondsSinceInput >= quietSeconds
    }
}

/// The green update badge on the correction popups (design_code.md §8.10 "Popup badge"): a pill from the day a
/// version is found, a full-width banner from day 7 on. It stays until that version is installed, so "Later"
/// in the update window doesn't hide it.
public enum UpdateNudge {
    public enum Level: Equatable, Sendable { case pill, banner }

    /// What a popup shows.
    public struct Badge: Equatable, Sendable {
        public var version: String
        public var current: String
        public var level: Level
        /// Whole days since the version was first found (0 = today).
        public var daysWaiting: Int

        public init(version: String, current: String, level: Level, daysWaiting: Int) {
            self.version = version
            self.current = current
            self.level = level
            self.daysWaiting = daysWaiting
        }
    }

    /// From this many days waiting on, the pill becomes the banner.
    public static let bannerAfterDays = 7

    /// Calendar days from `found` to `now` (never negative: a clock set back counts as today).
    public static func daysWaiting(since found: Date, now: Date, calendar: Calendar = .current) -> Int {
        let a = calendar.startOfDay(for: found), b = calendar.startOfDay(for: now)
        return max(0, calendar.dateComponents([.day], from: a, to: b).day ?? 0)
    }

    public static func level(daysWaiting: Int) -> Level {
        daysWaiting >= bannerAfterDays ? .banner : .pill
    }

    /// The badge for `version`, first found at `found`; nil when it isn't newer than the running `current`.
    public static func badge(version: String, current: String, found: Date, now: Date,
                             calendar: Calendar = .current) -> Badge? {
        guard isNewer(version, than: current) else { return nil }
        let days = daysWaiting(since: found, now: now, calendar: calendar)
        return Badge(version: version, current: current, level: level(daysWaiting: days), daysWaiting: days)
    }

    /// "1.0.10" is newer than "1.0.9"; missing parts count as 0 ("1.1" == "1.1.0"). A version that isn't
    /// dotted numbers ("dev") is never newer and nothing is newer than it.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        guard let x = parts(a), let y = parts(b) else { return false }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private static func parts(_ v: String) -> [Int]? {
        let p = v.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        let n = p.compactMap { Int($0) }
        return !p.isEmpty && n.count == p.count ? n : nil
    }
}

/// The words the app uses for updates (Settings, the menu-bar popover, the menu).
public enum UpdateText {
    public static let checkNow = "Check for Updates…"
    public static let automaticChecks = "Check for updates automatically"
    public static let automaticChecksDetail = "Once a day, Meboki asks whether a new version is out. Nothing about you is sent."
    public static let automaticInstall = "Install updates automatically"
    public static let automaticInstallDetail = "Installs a new version while you're away from the Mac. Off: Meboki shows the update and waits for you."
    public static let privacyTitle = "Updates"

    public static func privacyDetail(automaticChecks: Bool) -> String {
        automaticChecks
            ? "Once a day, Meboki downloads the public list of versions. Nothing about you, your text or your licence is sent."
            : "Off. Meboki looks for a new version only when you ask."
    }

    public static func available(_ version: String) -> String { "Update available · \(version)" }

    /// The popup pill: "Update 1.0.3".
    public static func badge(_ version: String) -> String { "Update \(version)" }
    /// The popup banner: "Meboki 1.0.3 is ready" · "Found 9 days ago · you're on 1.0.2" · "Install…".
    public static func bannerTitle(_ version: String) -> String { "Meboki \(version) is ready" }
    public static func bannerDetail(daysWaiting: Int, current: String) -> String {
        "\(found(daysWaiting: daysWaiting)) · you're on \(current)"
    }
    /// "Found today", "Found yesterday", "Found 9 days ago".
    public static func found(daysWaiting: Int) -> String {
        switch daysWaiting {
        case ...0: "Found today"
        case 1: "Found yesterday"
        default: "Found \(daysWaiting) days ago"
        }
    }
    public static let bannerButton = "Install…"
    public static let badgeHint = "Opens the update window"

    /// "Checked today at 14:05", "Checked 12 Nov"; nil before the first check.
    public static func lastChecked(_ date: Date?, now: Date = Date(), calendar: Calendar = .current,
                                   locale: Locale = .current) -> String? {
        guard let date else { return nil }
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = locale
        if calendar.isDate(date, inSameDayAs: now) {
            f.dateStyle = .none
            f.timeStyle = .short
            return "Checked today at \(f.string(from: date))"
        }
        f.dateStyle = .medium
        f.timeStyle = .none
        return "Checked \(f.string(from: date))"
    }
}
