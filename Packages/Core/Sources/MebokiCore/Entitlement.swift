import Foundation

/// A feature that needs a licence once the trial is over (PLAN.md §6 "App-side licensing", Gates).
public enum Feature: String, CaseIterable, Sendable {
    case automaticCheck, popupStyles, checkLevel, checkFor, casualMode, appModes

    /// Line for the "What a licence adds" list.
    public var title: String {
        switch self {
        case .automaticCheck: "Underlines as you type"
        case .popupStyles: "Bubble and island popups"
        case .checkLevel: "Check level"
        case .checkFor: "Check for"
        case .casualMode: "Casual mode"
        case .appModes: "Per-app On and Casual"
        }
    }
}

/// Why the app is in free mode.
public enum FreeReason: Sendable, Equatable {
    case trialEnded, revoked, expired

    public var message: String {
        switch self {
        case .trialEnded: LicenceText.trialEnded
        case .revoked: LicenceText.revoked
        case .expired: LicenceText.expired
        }
    }
}

extension LicenceInfo {
    /// A corporate key past its end date plus the grace period. Personal keys never expire.
    public func isExpired(now: Date) -> Bool {
        guard let exp = expires else { return false }
        return now > exp.addingTimeInterval(Double(Entitlement.expiryGraceDays) * 86_400)
    }
}

/// What the user gets right now. Pure: the app feeds it the stored licence, the revoked list and the trial.
public enum Entitlement: Sendable, Equatable {
    case licensed(LicenceInfo)
    case trial(daysLeft: Int)
    case free(FreeReason)

    /// Licensed or in the trial: every feature is on.
    public var isFull: Bool {
        if case .free = self { return false }
        return true
    }

    /// Corporate keys get 14 days after `exp` before they stop.
    public static let expiryGraceDays = 14

    /// - `licence`: result of `LicenceKey.verify` on the stored key, nil when none is stored.
    /// - A valid licence that isn't revoked or expired is `licensed`. A revoked or expired one, or none, is the
    ///   trial while it is on, otherwise free mode (reason: revoked, expired, or trialEnded).
    public static func resolve(licence: Result<LicenceInfo, LicenceError>?, revoked: RevokedList?, trial: TrialClock,
                               now: Date, calendar: Calendar) -> Entitlement {
        var reason = FreeReason.trialEnded
        if case .success(let info)? = licence {
            if revoked?.contains(info.kid) == true {
                reason = .revoked
            } else if info.isExpired(now: now) {
                reason = .expired
            } else {
                return .licensed(info)
            }
        }
        if trial.isActive(now: now, calendar: calendar) {
            return .trial(daysLeft: trial.daysLeft(now: now, calendar: calendar))
        }
        return .free(reason)
    }

    public func allows(_ feature: Feature) -> Bool { isFull }

    // MARK: Effective settings (the stored values stay untouched)

    /// Check level and Check for are one setting (`CheckLevel`): free mode uses the default, `full`.
    public func effective(_ level: CheckLevel) -> CheckLevel {
        allows(.checkLevel) ? level : .full
    }

    /// Per-app mode: On and Casual act as Manual in free mode; Manual and Off are unchanged.
    public func effective(_ mode: AppMode) -> AppMode {
        guard !allows(.appModes) else { return mode }
        switch mode {
        case .on, .casual: return .manual
        case .manual, .off: return mode
        }
    }

    /// The "Casual mode in chat apps" switch: off in free mode.
    public func effectiveCasual(_ casual: Bool) -> Bool {
        allows(.casualMode) ? casual : false
    }

    /// "Underline as you type": off in free mode (the hotkey review still works).
    public func effectiveAutomaticCheck(_ on: Bool) -> Bool {
        allows(.automaticCheck) ? on : false
    }
}
