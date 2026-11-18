import Foundation

/// Which one-time licence notice is due (PLAN.md §6 "App-side licensing" › "Where the user meets the paywall").
/// Pure: the app feeds it the entitlement, the stored flags and whether onboarding is in the way.
public enum LicenceNotice: Sendable, Equatable {
    /// The trial ended: the "Your trial has ended" window.
    case trialEnded
    /// The stored key was refunded or cancelled (`kid`): the "no longer valid" window.
    case revoked(kid: String)
    /// The stored key expired (`kid`): the same window, other wording.
    case expired(kid: String)
}

/// The notice flags the app keeps in its settings.
public struct LicenceNoticeFlags: Sendable, Equatable {
    public var trialEndNoticeShown: Bool
    public var lastDayNoticeShown: Bool
    public var revokedNoticeShownKid: String?

    public init(trialEndNoticeShown: Bool = false, lastDayNoticeShown: Bool = false, revokedNoticeShownKid: String? = nil) {
        self.trialEndNoticeShown = trialEndNoticeShown
        self.lastDayNoticeShown = lastDayNoticeShown
        self.revokedNoticeShownKid = revokedNoticeShownKid
    }

    /// The flags after `notice` was shown. A key notice also settles the trial-end notice: one notice at the end
    /// of the trial, never a second one after the key is removed.
    public func marking(_ notice: LicenceNotice) -> LicenceNoticeFlags {
        var f = self
        f.trialEndNoticeShown = true
        switch notice {
        case .trialEnded: break
        case .revoked(let kid), .expired(let kid): f.revokedNoticeShownKid = kid
        }
        return f
    }
}

public enum LicenceNotices {
    /// The window notice due now, if any. Called at launch, when the entitlement changes and when onboarding
    /// closes; the answer depends only on the current state, so each call is safe to repeat.
    /// - `kid`: the stored key's ID (nil without a key), for the per-key notice.
    /// - `onboardingBusy`: onboarding isn't done or its window is open; nothing shows over it.
    public static func windowNotice(entitlement: Entitlement, kid: String?, flags: LicenceNoticeFlags,
                                    onboardingBusy: Bool) -> LicenceNotice? {
        guard !onboardingBusy, case .free(let reason) = entitlement else { return nil }
        switch reason {
        case .trialEnded:
            return flags.trialEndNoticeShown ? nil : .trialEnded
        case .revoked, .expired:
            guard let kid, flags.revokedNoticeShownKid != kid else { return nil }
            return reason == .revoked ? .revoked(kid: kid) : .expired(kid: kid)
        }
    }

    /// The last-day toast is due: the last trial day, once, and not while onboarding is open. Never for a
    /// licensed user or in free mode.
    public static func lastDayToastDue(entitlement: Entitlement, isLastTrialDay: Bool, flags: LicenceNoticeFlags,
                                       onboardingBusy: Bool) -> Bool {
        guard !onboardingBusy, isLastTrialDay, !flags.lastDayNoticeShown, case .trial = entitlement else { return false }
        return true
    }
}
