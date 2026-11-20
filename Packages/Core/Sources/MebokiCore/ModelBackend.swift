import Foundation

/// Where checks run (Settings › Models): a downloaded model through `llama-server`, Apple's built-in model,
/// or a cloud model with the user's own key (BYOK). Stored as its raw value (`modelSource`).
public enum ModelSource: String, CaseIterable, Sendable {
    case local, apple, cloud

    /// The text stays on this Mac (local and Apple): the automatic check and live review may run.
    public var onDevice: Bool { self != .cloud }
}

/// The backend a check uses, chosen from the settings and what this Mac has (PLAN.md §3 "Apple Intelligence").
/// One pure rule instead of `usingCloud` branches in each caller; `AppDelegate` turns `.local`, `.apple` and
/// `.cloud` into a `Corrector`.
public enum ModelBackend: Equatable, Sendable {
    /// The selected local model through `llama-server` (it may still be loading).
    case local
    case apple
    case cloud
    /// Nothing can check right now; the UI says why. Never a silent switch to another source.
    case unusable(Reason)

    public enum Reason: Equatable, Sendable {
        /// The selected local model isn't downloaded.
        case noLocalModel
        /// Apple's model is selected but can't answer.
        case apple(AppleModelAvailability)
        /// The cloud provider has no saved key.
        case noCloudKey
    }

    public static func choose(source: ModelSource, apple: AppleModelAvailability, localInstalled: Bool,
                              cloudKey: Bool) -> ModelBackend {
        switch source {
        case .local: localInstalled ? .local : .unusable(.noLocalModel)
        case .apple: apple.isAvailable ? .apple : .unusable(.apple(apple))
        case .cloud: cloudKey ? .cloud : .unusable(.noCloudKey)
        }
    }

    /// The source a fresh install starts with, or nil to keep today's default (the recommended local model).
    /// Fresh means nothing was ever chosen: no stored model, no stored source, onboarding never finished.
    /// Then Apple's model is the default when it can answer and `appleIsDefault` (a catalog constant) allows.
    /// An existing user's choice never changes.
    public static func freshInstallSource(storedSource: String?, storedModelID: String?, onboardingDone: Bool,
                                          apple: AppleModelAvailability, appleIsDefault: Bool) -> ModelSource? {
        guard appleIsDefault, storedSource == nil, storedModelID == nil, !onboardingDone, apple.isAvailable else {
            return nil
        }
        return .apple
    }
}
