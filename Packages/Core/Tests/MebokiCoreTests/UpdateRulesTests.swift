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
}
