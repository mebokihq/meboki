import Foundation
import CryptoKit
import Testing
@testable import MebokiCore

/// Test signer: a throwaway key pair made at run time. The production key never appears here.
struct TestSigner {
    let priv = Curve25519.Signing.PrivateKey()
    var pub: Data { priv.publicKey.rawRepresentation }

    func key(kid: String = "ABCDEFGHIJKLMNOP", email: String = "a@example.com", type: String = "personal", seats: Int = 1,
             iat: String = "2026-11-18T21:08:01.000Z", exp: String? = nil, v: Int = 1) -> String {
        var json = "{\"v\":\(v),\"kid\":\"\(kid)\",\"email\":\"\(email)\",\"type\":\"\(type)\",\"seats\":\(seats),\"iat\":\"\(iat)\""
        if let exp { json += ",\"exp\":\"\(exp)\"" }
        json += "}"
        return signed(Data(json.utf8))
    }

    func signed(_ payload: Data) -> String {
        let sig = try! priv.signature(for: payload)
        return "MEBOKI-\(b64u(payload)).\(b64u(sig))"
    }

    func revoked(issued: String, kids: [String], v: Int = 1) -> Data {
        let list = "{\"v\":\(v),\"issued\":\"\(issued)\",\"kids\":[" + kids.map { "\"\($0)\"" }.joined(separator: ",") + "]}"
        let payload = Data(list.utf8)
        let sig = try! priv.signature(for: payload)
        return Data("{\"payload\":\"\(b64u(payload))\",\"sig\":\"\(b64u(sig))\"}".utf8)
    }
}

func b64u(_ d: Data) -> String {
    d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

@Suite struct LicenceKeyTests {
    let signer = TestSigner()

    @Test func verifiesAndReadsPayload() throws {
        let key = signer.key(email: "buyer@example.com", seats: 2)
        let info = try LicenceKey.verify(key, publicKey: signer.pub).get()
        #expect(info.kid == "ABCDEFGHIJKLMNOP")
        #expect(info.email == "buyer@example.com")
        #expect(info.type == .personal)
        #expect(info.seats == 2)
        #expect(info.expires == nil)
        #expect(info.key == key)
        #expect(info.issued == Date(timeIntervalSince1970: 1_795_036_081))
    }

    @Test func corporateExpiry() throws {
        let info = try LicenceKey.verify(signer.key(type: "corporate", exp: "2027-11-18T21:08:01.000Z"), publicKey: signer.pub).get()
        #expect(info.type == .corporate)
        #expect(info.expires == Date(timeIntervalSince1970: 1_795_036_081 + 365 * 86_400))
    }

    @Test func cleansPastedText() throws {
        let key = signer.key()
        let wrapped = stride(from: 0, to: key.count, by: 60).map { i -> String in
            let s = key.index(key.startIndex, offsetBy: i)
            return String(key[s..<key.index(s, offsetBy: min(60, key.count - i))])
        }.joined(separator: "\n  ")
        let variants = [key, wrapped, "\"\(key)\"", "<\(key)>", "'\(key)'", "Licence key: \(key)", "Licence key:\n\(key)\n",
                        "Your key is \(wrapped)\n\nThanks for buying!", "  \(key)  \r\n", "“\(key)”"]
        for v in variants {
            #expect(LicenceKey.clean(v) == key, "variant: \(v.prefix(40))")
            #expect((try? LicenceKey.verify(v, publicKey: signer.pub).get())?.kid == "ABCDEFGHIJKLMNOP")
        }
    }

    @Test func notAKey() {
        for text in ["", "hello", "MEBOKI-", "MEBOKI-abc", "licence 1234"] {
            #expect(LicenceKey.verify(text, publicKey: signer.pub) == .failure(.notAKey), "\(text)")
        }
    }

    @Test func damaged() {
        let key = signer.key()
        let parts = key.dropFirst(7).split(separator: ".").map(String.init)
        // Tampered payload (signature no longer matches).
        let other = signer.key(email: "evil@example.com")
        let otherPayload = other.dropFirst(7).split(separator: ".").map(String.init)[0]
        #expect(LicenceKey.verify("MEBOKI-\(otherPayload).\(parts[1])", publicKey: signer.pub) == .failure(.damaged))
        // Truncated signature, garbage characters, signature from another key.
        #expect(LicenceKey.verify(String(key.dropLast(10)), publicKey: signer.pub) == .failure(.damaged))
        #expect(LicenceKey.verify(key, publicKey: TestSigner().pub) == .failure(.damaged))
        // Signed, but not JSON.
        #expect(LicenceKey.verify(signer.signed(Data("nope".utf8)), publicKey: signer.pub) == .failure(.damaged))
        // Signed JSON with an unknown type or a bad date.
        #expect(LicenceKey.verify(signer.key(type: "gold"), publicKey: signer.pub) == .failure(.damaged))
        #expect(LicenceKey.verify(signer.key(iat: "yesterday"), publicKey: signer.pub) == .failure(.damaged))
        // A bad public key never verifies.
        #expect(LicenceKey.verify(key, publicKey: Data([1, 2, 3])) == .failure(.damaged))
    }

    @Test func newerFormat() {
        #expect(LicenceKey.verify(signer.key(v: 2), publicKey: signer.pub) == .failure(.newerFormat))
        #expect(LicenceKey.verify(signer.key(v: 0), publicKey: signer.pub) == .failure(.damaged))
    }

    @Test func messages() {
        #expect(LicenceError.notAKey.message.hasPrefix("That doesn't look like a Meboki licence key."))
        #expect(LicenceError.damaged.message.hasPrefix("This key is incomplete or was changed."))
        #expect(LicenceError.newerFormat.message == "This key needs a newer version of Meboki.")
        #expect(LicenceText.revoked == "This licence was refunded or cancelled. Questions: support@meboki.com")
    }

    @Test func productionKeyIs32Bytes() {
        #expect(LicenceKey.productionPublicKey.count == 32)
        #expect(LicenceKey.sandboxPublicKey.count == 32)
        #expect(LicenceKey.sandboxPublicKey != LicenceKey.productionPublicKey)
    }

    /// Signed with the real test-payment key (the one the site uses for test cards).
    static let sandboxKey = "MEBOKI-eyJ2IjoxLCJraWQiOiJTQU5EQk9YRklYVFVSRTAxIiwiZW1haWwiOiJ0ZXN0QGV4YW1wbGUuY29tIiwidHlwZSI6InBlcnNvbmFsIiwic2VhdHMiOjEsImlhdCI6IjIwMjYtMTEtMTlUMTA6MDA6MDAuMDAwWiJ9.1Jz9zVB8S7EmAycFd0gA9V9D-HSV0UJaho_uKqOay5i3uIb_LtyqxRGpePLpYHWPqD0tKd0BGCJ0wNzRLoqEDw"
    static let sandboxList = Data("{\"payload\":\"eyJ2IjoxLCJpc3N1ZWQiOiIyMDI2LTExLTE5VDEwOjAwOjAwLjAwMFoiLCJraWRzIjpbIlNBTkRCT1hGSVhUVVJFMDEiXX0\",\"sig\":\"SXqTTYL3db6JLy53dtmChA6oX3HqtbOdzhFU_MIP7MJ-wkw9779cR_obVEgH_jtGfKNE-QDhuG5nYvKwhBdZCQ\"}".utf8)

    @Test func sandboxKeyOnlyWhereAllowed() throws {
        // Release builds: a test-card key is refused like any foreign key.
        #expect(LicenceKey.verify(Self.sandboxKey, sandboxAllowed: false) == .failure(.damaged))
        #expect(RevokedList.parse(Self.sandboxList, sandboxAllowed: false) == nil)
        // Development builds: accepted and marked.
        let info = try LicenceKey.verify(Self.sandboxKey, sandboxAllowed: true).get()
        #expect(info.sandbox && info.kid == "SANDBOXFIXTURE01" && info.email == "test@example.com")
        let list = try #require(RevokedList.parse(Self.sandboxList, sandboxAllowed: true))
        #expect(list.contains("SANDBOXFIXTURE01"))
        // Damage still reads as damage with both keys tried.
        #expect(LicenceKey.verify(String(Self.sandboxKey.dropLast(4)), sandboxAllowed: true) == .failure(.damaged))
        #expect(LicenceKey.verify("hello", sandboxAllowed: true) == .failure(.notAKey))
    }

    @Test func sandboxOnlyInDebug() {
        #if DEBUG
        #expect(LicenceKey.acceptsSandboxKeys)
        #else
        #expect(!LicenceKey.acceptsSandboxKeys)
        #endif
    }

    /// Produced by a throwaway Node script with the Worker's steps (WebCrypto Ed25519, JSON.stringify field order
    /// v, kid, email, type, seats, iat[, exp], base64url). The key pair is not the production pair.
    @Test func workerFixture() throws {
        let pub = Data(base64Encoded: "kDz8cRkpyaNKWFpNXy0iKiKJAvCg1DEndE4kdu+CHBU=")!
        let personal = "MEBOKI-eyJ2IjoxLCJraWQiOiJBQkNERUZHSElKS0xNTk9QIiwiZW1haWwiOiJidXllckBleGFtcGxlLmNvbSIsInR5cGUiOiJwZXJzb25hbCIsInNlYXRzIjoyLCJpYXQiOiIyMDI2LTExLTE4VDIxOjA4OjAxLjAwMFoifQ.tCNMp9TWLH57tqx5VSEmCsuul0mXPj6-lDJyD6SqYC8F8tyJXL7jT7QhPv1Fgp9O3VdDjUAQ1pbe5b_npfogCg"
        let corporate = "MEBOKI-eyJ2IjoxLCJraWQiOiJRUlNUVVZXWFlaMjM0NTY3IiwiZW1haWwiOiJ0ZWFtQGV4YW1wbGUuY29tIiwidHlwZSI6ImNvcnBvcmF0ZSIsInNlYXRzIjo1LCJpYXQiOiIyMDI2LTExLTE4VDIxOjA4OjAxLjAwMFoiLCJleHAiOiIyMDI3LTExLTE4VDIxOjA4OjAxLjAwMFoifQ.pJFu9SERePi3UtAajbv6CKxhiEUw8SLmQXdUiHbh5VdhwwQZpNSZzfaSgOa6L8yQDK4V1TsKBCkVQulIGUPDDw"
        let revokedBody = Data("{\"payload\":\"eyJ2IjoxLCJpc3N1ZWQiOiIyMDI2LTExLTE4VDIyOjAwOjAwLjAwMFoiLCJraWRzIjpbIkFCQ0RFRkdISUpLTE1OT1AiXX0\",\"sig\":\"zJ4M6AfRHcecb3xgSl6KZxVfvlZINNZ3wrDwXc7BtpEC0MfxTLV-ZiueT0D8gP29auqi0e4itMZKU1oyG6KxAQ\"}".utf8)

        let p = try LicenceKey.verify(personal, publicKey: pub).get()
        #expect(p.email == "buyer@example.com" && p.seats == 2 && p.type == .personal && p.kid == "ABCDEFGHIJKLMNOP")
        let c = try LicenceKey.verify(corporate, publicKey: pub).get()
        #expect(c.type == .corporate && c.seats == 5 && c.expires != nil)
        let list = try #require(RevokedList.parse(revokedBody, publicKey: pub))
        #expect(list.contains("ABCDEFGHIJKLMNOP") && list.kids.count == 1)
        #expect(list.issued == ISODate.parse("2026-11-18T22:00:00.000Z"))

        // Not valid under the production key.
        #expect(LicenceKey.verify(personal) == .failure(.damaged))
        #expect(LicenceKey.verify(corporate) == .failure(.damaged))
        #expect(RevokedList.parse(revokedBody) == nil)
    }
}

@Suite struct RevokedListTests {
    let signer = TestSigner()

    @Test func parses() throws {
        let body = signer.revoked(issued: "2026-11-18T10:00:00.000Z", kids: ["B", "A"])
        let list = try #require(RevokedList.parse(body, publicKey: signer.pub))
        #expect(list.kids == ["A", "B"])
        #expect(list.contains("A") && !list.contains("C"))
        #expect(list.raw == body)
    }

    @Test func rejectsBadInput() {
        let body = signer.revoked(issued: "2026-11-18T10:00:00.000Z", kids: ["A"])
        #expect(RevokedList.parse(body, publicKey: TestSigner().pub) == nil)
        #expect(RevokedList.parse(Data("garbage".utf8), publicKey: signer.pub) == nil)
        #expect(RevokedList.parse(signer.revoked(issued: "2026-11-18T10:00:00.000Z", kids: [], v: 2), publicKey: signer.pub) == nil)
        // Tampered: payload swapped for another list's, same signature.
        let a = try! JSONSerialization.jsonObject(with: body) as! [String: String]
        let b = try! JSONSerialization.jsonObject(with: signer.revoked(issued: "2026-11-18T10:00:00.000Z", kids: [])) as! [String: String]
        let tampered = try! JSONSerialization.data(withJSONObject: ["payload": b["payload"]!, "sig": a["sig"]!])
        #expect(RevokedList.parse(tampered, publicKey: signer.pub) == nil)
    }

    @Test func newerWins() throws {
        let old = try #require(RevokedList.parse(signer.revoked(issued: "2026-11-18T10:00:00.000Z", kids: ["A"]), publicKey: signer.pub))
        let new = try #require(RevokedList.parse(signer.revoked(issued: "2026-11-19T10:00:00.000Z", kids: []), publicKey: signer.pub))
        #expect(RevokedList.newer(current: old, candidate: new) == new)
        #expect(RevokedList.newer(current: new, candidate: old) == new)
        #expect(RevokedList.newer(current: old, candidate: nil) == old)
        #expect(RevokedList.newer(current: nil, candidate: old) == old)
        #expect(RevokedList.newer(current: nil, candidate: nil) == nil)
    }
}

@Suite struct TrialClockTests {
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return c
    }
    func date(_ day: Int, _ hour: Int = 12) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 12, day: day, hour: hour))!
    }

    @Test func freshInstall() {
        let t = TrialClock()
        #expect(t.isActive(now: date(1), calendar: cal))
        #expect(t.daysLeft(now: date(1), calendar: cal) == 7)
        #expect(!t.isLastDay(now: date(1), calendar: cal))
    }

    @Test func dayStrings() {
        #expect(TrialClock.dayString(date(5), calendar: cal) == "2026-12-05")
        // 23:30 UTC on Dec 5 is already Dec 6 in Berlin.
        let late = Date(timeIntervalSince1970: date(5, 0).timeIntervalSince1970 + 23.5 * 3600)
        #expect(TrialClock.dayString(late, calendar: cal) == "2026-12-05")
        #expect(TrialClock.dayString(late.addingTimeInterval(3600), calendar: cal) == "2026-12-06")
    }

    @Test func onlyCheckedDaysCount() {
        var t = TrialClock()
        t.recordCheck(now: date(1), calendar: cal)
        t.recordCheck(now: date(1, 18), calendar: cal)
        #expect(t.days.count == 1)
        #expect(t.daysLeft(now: date(1), calendar: cal) == 7)
        #expect(t.daysLeft(now: date(2), calendar: cal) == 6)
        // Ten idle days pass; nothing is lost.
        #expect(t.isActive(now: date(12), calendar: cal))
        #expect(t.daysLeft(now: date(12), calendar: cal) == 6)
    }

    @Test func seventhDayLastsUntilMidnight() {
        var t = TrialClock()
        for d in 1...7 { t.recordCheck(now: date(d), calendar: cal) }
        #expect(t.days.count == 7)
        #expect(t.isActive(now: date(7, 23), calendar: cal))
        #expect(t.isLastDay(now: date(7, 23), calendar: cal))
        #expect(t.daysLeft(now: date(7), calendar: cal) == 1)
        #expect(!t.isActive(now: date(8, 0), calendar: cal))
        #expect(t.daysLeft(now: date(8), calendar: cal) == 0)
        t.recordCheck(now: date(8), calendar: cal)
        #expect(t.days.count == 7)
        #expect(!t.isActive(now: date(8), calendar: cal))
    }

    @Test func lastDayBeforeFirstCheck() {
        var t = TrialClock()
        for d in 1...6 { t.recordCheck(now: date(d), calendar: cal) }
        #expect(t.isLastDay(now: date(7), calendar: cal))
        #expect(t.daysLeft(now: date(7), calendar: cal) == 1)
        #expect(t.daysLeft(now: date(6), calendar: cal) == 2)
    }

    @Test func rollbackDoesNotRevive() {
        var t = TrialClock()
        for d in 1...7 { t.recordCheck(now: date(d), calendar: cal) }
        t.observe(now: date(10), calendar: cal)
        // The clock goes back to day 7: still the later day.
        #expect(!t.isActive(now: date(7), calendar: cal))
        t.recordCheck(now: date(3), calendar: cal)
        #expect(t.days.count == 7)
        #expect(t.today(now: date(3), calendar: cal) == "2026-12-10")
    }

    // Replaces `rollbackDoesNotAddDays`, which encoded the old behaviour (an earlier real day was dropped).
    @Test func earlierRealDayStillCounts() {
        var t = TrialClock()
        t.recordCheck(now: date(5), calendar: cal)
        t.recordCheck(now: date(2), calendar: cal)
        #expect(t.days == ["2026-12-02", "2026-12-05"])
        #expect(t.lastSeen == "2026-12-05")
    }

    @Test func forwardJumpThenBackKeepsCounting() {
        var t = TrialClock()
        t.recordCheck(now: date(1), calendar: cal)
        // The date is wrong for one launch (30 days ahead), then right again.
        t.observe(now: date(1).addingTimeInterval(30 * 86_400), calendar: cal)
        for d in 2...6 {
            t.recordCheck(now: date(d), calendar: cal)
            #expect(t.days.count == d)
            #expect(t.days.last == "2026-12-0\(d)")
        }
        #expect(t.isActive(now: date(6), calendar: cal))
        t.recordCheck(now: date(7), calendar: cal)
        #expect(t.days.count == 7)
        // Seven real active days: over (the later day seen keeps it over).
        #expect(!t.isActive(now: date(7), calendar: cal))
        #expect(t.daysLeft(now: date(8), calendar: cal) == 0)
    }

    @Test func forwardJumpCheckDoesNotFreeze() {
        var t = TrialClock()
        // A check while the clock is 30 days ahead stores that real (wrong) day once, then the real days follow.
        let ahead = date(1).addingTimeInterval(30 * 86_400)
        t.recordCheck(now: ahead, calendar: cal)
        t.recordCheck(now: date(2), calendar: cal)
        t.recordCheck(now: date(3), calendar: cal)
        #expect(t.days.count == 3)
    }

    @Test func rollbackToCountedSeventhDayStaysOver() {
        var t = TrialClock()
        for d in 1...7 { t.recordCheck(now: date(d), calendar: cal) }
        #expect(t.isActive(now: date(7), calendar: cal))
        t.observe(now: date(8), calendar: cal)
        #expect(!t.isActive(now: date(8), calendar: cal))
        #expect(!t.isActive(now: date(7), calendar: cal))
        t.recordCheck(now: date(7), calendar: cal)
        #expect(!t.isActive(now: date(7), calendar: cal))
    }

    @Test func dayStringIsGregorianWhateverTheCalendar() {
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = cal.timeZone
        #expect(TrialClock.dayString(date(5), calendar: buddhist) == "2026-12-05")
        var japanese = Calendar(identifier: .japanese)
        japanese.timeZone = cal.timeZone
        #expect(TrialClock.dayString(date(5), calendar: japanese) == "2026-12-05")
    }

    @Test func mergeAndCodable() throws {
        let a = TrialClock(days: ["2026-12-01", "2026-12-02"], lastSeen: "2026-12-02")
        let b = TrialClock(days: ["2026-12-02", "2026-12-04"], lastSeen: "2026-12-04")
        let m = a.merged(with: b)
        #expect(m.days == ["2026-12-01", "2026-12-02", "2026-12-04"])
        #expect(m.lastSeen == "2026-12-04")
        #expect(a.merged(with: TrialClock()) == a)
        let many = TrialClock(days: (1...9).map { "2026-12-0\($0)" })
        #expect(many.days.count == 7)
        let back = try JSONDecoder().decode(TrialClock.self, from: JSONEncoder().encode(m))
        #expect(back == m)
    }
}

@Suite struct EntitlementTests {
    let signer = TestSigner()
    var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func info(type: String = "personal", exp: Date? = nil) throws -> LicenceInfo {
        var expStr: String?
        if let exp {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            expStr = f.string(from: exp)
        }
        return try LicenceKey.verify(signer.key(type: type, exp: expStr), publicKey: signer.pub).get()
    }

    var usedUp: TrialClock { TrialClock(days: (1...7).map { "2026-01-0\($0)" }, lastSeen: "2026-01-07") }

    func list(_ kids: [String]) -> RevokedList {
        RevokedList.parse(signer.revoked(issued: "2026-11-18T10:00:00.000Z", kids: kids), publicKey: signer.pub)!
    }

    @Test func licensed() throws {
        let i = try info()
        let e = Entitlement.resolve(licence: .success(i), revoked: nil, trial: usedUp, now: now, calendar: cal)
        #expect(e == .licensed(i))
        #expect(e.isFull)
        #expect(Entitlement.resolve(licence: .success(i), revoked: list(["OTHER"]), trial: usedUp, now: now, calendar: cal) == .licensed(i))
    }

    @Test func trial() {
        let e = Entitlement.resolve(licence: nil, revoked: nil, trial: TrialClock(), now: now, calendar: cal)
        #expect(e == .trial(daysLeft: 7))
        #expect(e.isFull)
        // A bad stored key doesn't block the trial.
        let bad = Entitlement.resolve(licence: .failure(.damaged), revoked: nil, trial: TrialClock(), now: now, calendar: cal)
        #expect(bad == .trial(daysLeft: 7))
    }

    @Test func freeTrialEnded() {
        #expect(Entitlement.resolve(licence: nil, revoked: nil, trial: usedUp, now: now, calendar: cal) == .free(.trialEnded))
        #expect(Entitlement.resolve(licence: .failure(.notAKey), revoked: nil, trial: usedUp, now: now, calendar: cal) == .free(.trialEnded))
        #expect(!Entitlement.free(.trialEnded).isFull)
    }

    @Test func revoked() throws {
        let i = try info()
        let r = list([i.kid])
        #expect(Entitlement.resolve(licence: .success(i), revoked: r, trial: usedUp, now: now, calendar: cal) == .free(.revoked))
        // Trial still on: the user stays in the trial.
        #expect(Entitlement.resolve(licence: .success(i), revoked: r, trial: TrialClock(), now: now, calendar: cal) == .trial(daysLeft: 7))
    }

    @Test func expiredWithGrace() throws {
        let day: TimeInterval = 86_400
        let i = try info(type: "corporate", exp: now.addingTimeInterval(-13 * day))
        #expect(Entitlement.resolve(licence: .success(i), revoked: nil, trial: usedUp, now: now, calendar: cal) == .licensed(i))
        let old = try info(type: "corporate", exp: now.addingTimeInterval(-15 * day))
        #expect(Entitlement.resolve(licence: .success(old), revoked: nil, trial: usedUp, now: now, calendar: cal) == .free(.expired))
        #expect(!i.isExpired(now: now) && old.isExpired(now: now))
        #expect(try !info().isExpired(now: now))
        #expect(Entitlement.resolve(licence: .success(old), revoked: nil, trial: TrialClock(), now: now, calendar: cal) == .trial(daysLeft: 7))
        // Revoked wins over expired.
        #expect(Entitlement.resolve(licence: .success(old), revoked: list([old.kid]), trial: usedUp, now: now, calendar: cal) == .free(.revoked))
    }

    @Test func gates() {
        let full: [Entitlement] = [.trial(daysLeft: 3), .licensed(try! info())]
        for e in full {
            for f in Feature.allCases { #expect(e.allows(f)) }
            #expect(e.effective(CheckLevel.spelling) == .spelling)
            #expect(e.effective(AppMode.casual) == .casual)
            #expect(e.effective(AppMode.on) == .on)
            #expect(e.effectiveCasual(true))
            #expect(e.effectiveAutomaticCheck(true))
        }
        for reason in [FreeReason.trialEnded, .revoked, .expired] {
            let e = Entitlement.free(reason)
            for f in Feature.allCases { #expect(!e.allows(f)) }
            #expect(e.effective(CheckLevel.spelling) == .full)
            #expect(e.effective(CheckLevel.grammar) == .full)
            #expect(e.effective(AppMode.on) == .manual)
            #expect(e.effective(AppMode.casual) == .manual)
            #expect(e.effective(AppMode.manual) == .manual)
            #expect(e.effective(AppMode.off) == .off)
            #expect(!e.effectiveCasual(true))
            #expect(!e.effectiveAutomaticCheck(true))
            #expect(!e.effective(AppMode.casual).allowsAutoCheck)
        }
    }

    @Test func titlesAndMessages() {
        #expect(Feature.allCases.allSatisfy { !$0.title.isEmpty })
        #expect(FreeReason.revoked.message == LicenceText.revoked)
        #expect(FreeReason.trialEnded.message.hasPrefix("Meboki is now in free mode."))
    }
}
