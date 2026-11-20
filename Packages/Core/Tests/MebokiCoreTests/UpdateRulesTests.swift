import Foundation
import Testing
@testable import MebokiCore

@Suite struct UpdateRulesTests {
    let key = Data(repeating: 7, count: 32).base64EncodedString()

    @Test func feedNeedsAddressAndKey() {
        #expect(UpdateFeed(feed: nil, publicKey: key) == nil)
        #expect(UpdateFeed(feed: "", publicKey: key) == nil)
        #expect(UpdateFeed(feed: "https://example.com/appcast.xml", publicKey: nil) == nil)
        #expect(UpdateFeed(feed: "https://example.com/appcast.xml", publicKey: "not a key") == nil)
        #expect(UpdateFeed(feed: "https://example.com/appcast.xml", publicKey: Data(repeating: 7, count: 31).base64EncodedString()) == nil)
        let feed = UpdateFeed(feed: " https://example.com/appcast.xml\n", publicKey: key)
        #expect(feed?.url.absoluteString == "https://example.com/appcast.xml")
        #expect(feed?.publicKey == key)
        #expect(feed?.isLocal == false)
    }

    @Test func plainHTTPOnlyFromThisMac() {
        #expect(UpdateFeed(feed: "http://example.com/appcast.xml", publicKey: key) == nil)
        #expect(UpdateFeed(feed: "http://127.0.0.1.example.com/appcast.xml", publicKey: key) == nil)
        #expect(UpdateFeed(feed: "file:///tmp/appcast.xml", publicKey: key) == nil)
        #expect(UpdateFeed(feed: "http://127.0.0.1:8765/appcast.xml", publicKey: key)?.isLocal == true)
        #expect(UpdateFeed(feed: "http://localhost:8765/appcast.xml", publicKey: key)?.isLocal == true)
    }

    @Test func installsOnlyWhenIdleAndAway() {
        #expect(UpdateTiming.canInstallNow(busy: false, secondsSinceInput: UpdateTiming.quietSeconds))
        #expect(!UpdateTiming.canInstallNow(busy: false, secondsSinceInput: UpdateTiming.quietSeconds - 1))
        #expect(!UpdateTiming.canInstallNow(busy: true, secondsSinceInput: 3600))
    }

    @Test func lastCheckedWords() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let locale = Locale(identifier: "en_GB")
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 18))!
        let today = cal.date(from: DateComponents(year: 2026, month: 11, day: 19, hour: 14, minute: 5))!
        let earlier = cal.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 9))!
        #expect(UpdateText.lastChecked(nil, now: now, calendar: cal, locale: locale) == nil)
        #expect(UpdateText.lastChecked(today, now: now, calendar: cal, locale: locale) == "Checked today at 14:05")
        #expect(UpdateText.lastChecked(earlier, now: now, calendar: cal, locale: locale) == "Checked 12 Nov 2026")
    }

    // MARK: Popup badge

    var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    @Test func pillUntilDaySevenThenBanner() {
        #expect(UpdateNudge.level(daysWaiting: 0) == .pill)
        #expect(UpdateNudge.level(daysWaiting: 6) == .pill)
        #expect(UpdateNudge.level(daysWaiting: 7) == .banner)
        #expect(UpdateNudge.level(daysWaiting: 40) == .banner)
    }

    @Test func daysCountCalendarDays() {
        let found = date("2026-11-20T23:30:00Z")
        #expect(UpdateNudge.daysWaiting(since: found, now: date("2026-11-20T23:59:00Z"), calendar: utc) == 0)
        #expect(UpdateNudge.daysWaiting(since: found, now: date("2026-11-21T00:10:00Z"), calendar: utc) == 1)
        #expect(UpdateNudge.daysWaiting(since: found, now: date("2026-11-27T08:00:00Z"), calendar: utc) == 7)
        // A clock set back counts as today.
        #expect(UpdateNudge.daysWaiting(since: found, now: date("2026-11-18T08:00:00Z"), calendar: utc) == 0)
    }

    @Test func badgeOnlyForANewerVersion() {
        let found = date("2026-11-10T09:00:00Z"), now = date("2026-11-20T09:00:00Z")
        let b = UpdateNudge.badge(version: "1.0.3", current: "1.0.2", found: found, now: now, calendar: utc)
        #expect(b == UpdateNudge.Badge(version: "1.0.3", current: "1.0.2", level: .banner, daysWaiting: 10))
        #expect(UpdateNudge.badge(version: "1.0.2", current: "1.0.2", found: found, now: now, calendar: utc) == nil)
        #expect(UpdateNudge.badge(version: "1.0.1", current: "1.0.2", found: found, now: now, calendar: utc) == nil)
    }

    @Test func versionOrder() {
        #expect(UpdateNudge.isNewer("1.0.10", than: "1.0.9"))
        #expect(UpdateNudge.isNewer("1.1", than: "1.0.9"))
        #expect(UpdateNudge.isNewer("2.0.0", than: "1.9"))
        #expect(!UpdateNudge.isNewer("1.1", than: "1.1.0"))
        #expect(!UpdateNudge.isNewer("1.0.2", than: "1.0.3"))
        #expect(!UpdateNudge.isNewer("1.0.3", than: "dev"))
        #expect(!UpdateNudge.isNewer("dev", than: "1.0.0"))
        #expect(!UpdateNudge.isNewer("1..2", than: "1.0"))
    }

    @Test func bannerWords() {
        #expect(UpdateText.badge("1.0.3") == "Update 1.0.3")
        #expect(UpdateText.bannerTitle("1.0.3") == "Meboki 1.0.3 is ready")
        #expect(UpdateText.bannerDetail(daysWaiting: 0, current: "1.0.2") == "Found today · you're on 1.0.2")
        #expect(UpdateText.bannerDetail(daysWaiting: 1, current: "1.0.2") == "Found yesterday · you're on 1.0.2")
        #expect(UpdateText.bannerDetail(daysWaiting: 9, current: "1.0.2") == "Found 9 days ago · you're on 1.0.2")
        #expect(UpdateText.found(daysWaiting: 9) == "Found 9 days ago")
    }
}
