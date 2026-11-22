import Foundation

/// The "What's new" window after an update (design_code.md §8.12): what changed between the version the user ran
/// before and the one running now. The text is written by hand for every release in `App/WhatsNew/whatsnew.json`
/// (newest first), or marked `hidden` for a release without a window; `Scripts/check-whats-new.py` stops a release
/// whose entry is missing or unchanged.
public enum WhatsNewKind: String, Codable, Sendable, CaseIterable {
    case new, improved, fixed

    public var label: String {
        switch self {
        case .new: "New"
        case .improved: "Improved"
        case .fixed: "Fixed"
        }
    }
}

public struct WhatsNewHighlight: Codable, Equatable, Sendable {
    public var kind: WhatsNewKind
    /// An SF Symbol name; the kind's symbol when missing.
    public var symbol: String?
    public var title: String
    public var body: String
    /// A screenshot, relative to the WhatsNew folder (for example `images/1.0.7-writer.png`).
    public var image: String?

    public init(kind: WhatsNewKind, symbol: String? = nil, title: String, body: String, image: String? = nil) {
        self.kind = kind
        self.symbol = symbol
        self.title = title
        self.body = body
        self.image = image
    }
}

public struct WhatsNewItem: Codable, Equatable, Sendable {
    public var kind: WhatsNewKind
    public var text: String

    public init(kind: WhatsNewKind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public struct WhatsNewRelease: Codable, Equatable, Sendable {
    public var version: String
    /// `yyyy-MM-dd`.
    public var date: String
    public var highlights: [WhatsNewHighlight]
    public var items: [WhatsNewItem]
    /// A release that shows no window of its own (a small fix release): `"hidden": true`, no text needed. The
    /// entry still has to exist, so every release is a decision (`Scripts/check-whats-new.py`).
    public var hidden: Bool

    public init(version: String, date: String, highlights: [WhatsNewHighlight] = [], items: [WhatsNewItem] = [],
                hidden: Bool = false) {
        self.version = version
        self.date = date
        self.highlights = highlights
        self.items = items
        self.hidden = hidden
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        date = try c.decode(String.self, forKey: .date)
        highlights = try c.decodeIfPresent([WhatsNewHighlight].self, forKey: .highlights) ?? []
        items = try c.decodeIfPresent([WhatsNewItem].self, forKey: .items) ?? []
        hidden = try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    }

    /// Nothing to show: hidden, or no text.
    public var isEmpty: Bool { hidden || (highlights.isEmpty && items.isEmpty) }

    /// "24 Nov 2026"; the raw string when it isn't `yyyy-MM-dd`.
    public var displayDate: String {
        let parse = DateFormatter()
        parse.locale = Locale(identifier: "en_US_POSIX")
        parse.timeZone = TimeZone(identifier: "UTC")
        parse.dateFormat = "yyyy-MM-dd"
        guard let d = parse.date(from: date) else { return date }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_GB")
        out.timeZone = TimeZone(identifier: "UTC")
        out.dateFormat = "d MMM yyyy"
        return out.string(from: d)
    }
}

public enum WhatsNew {
    /// The file's name inside the WhatsNew folder (app bundle: `Contents/Resources/WhatsNew/`).
    public static let fileName = "whatsnew.json"

    public static func decode(_ data: Data) throws -> [WhatsNewRelease] {
        try JSONDecoder().decode([WhatsNewRelease].self, from: data)
    }

    /// The entries newer than `previous` up to and including `current`, newest first. With no `previous` (the
    /// user came from a build older than this window), only `current`'s own entry.
    public static func releases(_ all: [WhatsNewRelease], from previous: String?, to current: String) -> [WhatsNewRelease] {
        let picked = all.filter { r in
            guard !r.isEmpty, !UpdateNudge.isNewer(r.version, than: current) else { return false }
            if let previous { return UpdateNudge.isNewer(r.version, than: previous) }
            return !UpdateNudge.isNewer(current, than: r.version)  // == current
        }
        return picked.sorted { UpdateNudge.isNewer($0.version, than: $1.version) }
    }

    /// The changelog (Settings › About): every entry with text up to `current`, newest first. A build older than
    /// every entry (a local build) gets them all.
    public static func history(_ all: [WhatsNewRelease], upTo current: String) -> [WhatsNewRelease] {
        let shown = all.filter { !$0.isEmpty }.sorted { UpdateNudge.isNewer($0.version, than: $1.version) }
        let upTo = shown.filter { !UpdateNudge.isNewer($0.version, than: current) }
        return upTo.isEmpty ? shown : upTo
    }

    /// "Version 1.0.6 · 2 releases".
    public static func changelogSubtitle(_ releases: [WhatsNewRelease]) -> String {
        guard let newest = releases.first else { return "" }
        return "Version \(newest.version) · \(releases.count) release\(releases.count == 1 ? "" : "s")"
    }

    public enum Decision: Equatable, Sendable {
        /// Nothing to do (same version, or a version that isn't dotted numbers).
        case none
        /// Store `current` as seen without a window: a fresh install, a downgrade, or no entry to show.
        case record
        /// Show the window with these entries, then store `current` as seen.
        case show(from: String?, releases: [WhatsNewRelease])
    }

    /// What to do at launch. `lastSeen` is the version the window was last settled for (nil: never; an update
    /// from a build older than this window, or a fresh install). A fresh install (onboarding not done) only
    /// records: the Welcome window explains the app.
    public static func decide(current: String, lastSeen: String?, onboardingDone: Bool,
                              all: [WhatsNewRelease]) -> Decision {
        guard isVersion(current) else { return .none }
        if lastSeen == current { return .none }
        guard onboardingDone else { return .record }
        if let lastSeen, isVersion(lastSeen), !UpdateNudge.isNewer(current, than: lastSeen) { return .record }
        let from = lastSeen.flatMap { isVersion($0) ? $0 : nil }
        let picked = releases(all, from: from, to: current)
        return picked.isEmpty ? .record : .show(from: from, releases: picked)
    }

    /// "Updated from 1.0.5 · 24 Nov 2026", "Updated from 1.0.4 · 2 versions", "Released 24 Nov 2026".
    public static func subtitle(from previous: String?, releases: [WhatsNewRelease]) -> String {
        guard let newest = releases.first else { return "" }
        guard let previous else { return "Released \(newest.displayDate)" }
        if releases.count > 1 { return "Updated from \(previous) · \(releases.count) versions" }
        return "Updated from \(previous) · \(newest.displayDate)"
    }

    static func isVersion(_ v: String) -> Bool {
        let p = v.split(separator: ".", omittingEmptySubsequences: false)
        return !p.isEmpty && p.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}
