import Foundation
import Testing
@testable import MebokiCore

@Suite struct LicenceNoticeTests {
    let none = LicenceNoticeFlags()

    private func info(_ kid: String) -> LicenceInfo {
        LicenceInfo(kid: kid, email: "a@b.c", type: .personal, seats: 1, issued: Date(), expires: nil, key: "MEBOKI-x.y")
    }

    @Test func trialEndedOnce() {
        let n = LicenceNotices.windowNotice(entitlement: .free(.trialEnded), kid: nil, flags: none, onboardingBusy: false)
        #expect(n == .trialEnded)
        let shown = none.marking(.trialEnded)
        #expect(LicenceNotices.windowNotice(entitlement: .free(.trialEnded), kid: nil, flags: shown, onboardingBusy: false) == nil)
    }

    @Test func waitsForOnboarding() {
        #expect(LicenceNotices.windowNotice(entitlement: .free(.trialEnded), kid: nil, flags: none, onboardingBusy: true) == nil)
    }

    @Test func noWindowInTrialOrLicensed() {
        #expect(LicenceNotices.windowNotice(entitlement: .trial(daysLeft: 3), kid: nil, flags: none, onboardingBusy: false) == nil)
        #expect(LicenceNotices.windowNotice(entitlement: .licensed(info("K1")), kid: "K1", flags: none, onboardingBusy: false) == nil)
    }

    @Test func revokedOncePerKey() {
        let n = LicenceNotices.windowNotice(entitlement: .free(.revoked), kid: "K1", flags: none, onboardingBusy: false)
        #expect(n == .revoked(kid: "K1"))
        let f = none.marking(n!)
        #expect(f.trialEndNoticeShown)
        #expect(LicenceNotices.windowNotice(entitlement: .free(.revoked), kid: "K1", flags: f, onboardingBusy: false) == nil)
        // Another key revoked later gets its own notice.
        #expect(LicenceNotices.windowNotice(entitlement: .free(.revoked), kid: "K2", flags: f, onboardingBusy: false) == .revoked(kid: "K2"))
    }

    @Test func expiredNotice() {
        #expect(LicenceNotices.windowNotice(entitlement: .free(.expired), kid: "K3", flags: none, onboardingBusy: false) == .expired(kid: "K3"))
    }

    @Test func trialEndedNeverAfterKeyNotice() {
        // The key notice settled the end of the trial; removing the key later shows nothing more.
        let f = none.marking(.revoked(kid: "K1"))
        #expect(LicenceNotices.windowNotice(entitlement: .free(.trialEnded), kid: nil, flags: f, onboardingBusy: false) == nil)
    }

    @Test func lastDayToast() {
        #expect(LicenceNotices.lastDayToastDue(entitlement: .trial(daysLeft: 1), isLastTrialDay: true, flags: none, onboardingBusy: false))
        #expect(!LicenceNotices.lastDayToastDue(entitlement: .trial(daysLeft: 1), isLastTrialDay: true,
                                                flags: LicenceNoticeFlags(lastDayNoticeShown: true), onboardingBusy: false))
        #expect(!LicenceNotices.lastDayToastDue(entitlement: .trial(daysLeft: 4), isLastTrialDay: false, flags: none, onboardingBusy: false))
        #expect(!LicenceNotices.lastDayToastDue(entitlement: .trial(daysLeft: 1), isLastTrialDay: true, flags: none, onboardingBusy: true))
        #expect(!LicenceNotices.lastDayToastDue(entitlement: .licensed(info("K1")), isLastTrialDay: true, flags: none, onboardingBusy: false))
        #expect(!LicenceNotices.lastDayToastDue(entitlement: .free(.trialEnded), isLastTrialDay: false, flags: none, onboardingBusy: false))
    }
}
