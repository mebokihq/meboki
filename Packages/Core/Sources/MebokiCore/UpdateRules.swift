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
