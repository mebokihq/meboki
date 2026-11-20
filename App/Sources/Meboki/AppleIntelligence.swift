import AppKit
import MebokiCore

/// Apple's built-in model for the app (PLAN.md §3 "Apple Intelligence"): its availability, its corrector and
/// the way to its System Settings pane. Everything that touches `FoundationModels` is behind `#available`,
/// so the app runs unchanged on macOS 14 and 15.
@MainActor
enum AppleIntelligence {
    /// Settings › Models and onboarding use this ID for the built-in row (it is not a `Catalog` model).
    static let id = "apple"

    /// The availability now. DEBUG: `--apple-model <state>` or `MEBOKI_APPLE_MODEL=<state>` forces it
    /// (available, notEnabled, modelNotReady, deviceNotEligible, osTooOld), in the real app and the demos.
    static func current() -> AppleModelAvailability {
        #if DEBUG
        if let forced { return forced }
        #endif
        return AppleModelAvailability.system()
    }

    #if DEBUG
    static let forced: AppleModelAvailability? = {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--apple-model"), i + 1 < args.count {
            return AppleModelAvailability(rawValue: args[i + 1])
        }
        return ProcessInfo.processInfo.environment["MEBOKI_APPLE_MODEL"].flatMap(AppleModelAvailability.init(rawValue:))
    }()
    #endif

    /// The macOS can run the model at all. False on macOS 14/15 even when DEBUG forces "available": a check then
    /// fails with a message instead of calling into a framework that isn't there.
    static var canRun: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return true }
        #endif
        return false
    }

    /// A fresh client for one check, or nil where the model can't run.
    static func corrector() -> (any Corrector)? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return AppleModelClient() }
        #endif
        return nil
    }

    static func prewarm(system: String) {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { AppleModelClient.prewarm(system: system) }
        #endif
    }

    /// System Settings › Apple Intelligence & Siri.
    static func openSettings() {
        let pane = URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!
        if !NSWorkspace.shared.open(pane) {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
        }
    }

    /// The short status of the built-in row (design_code.md §8.3).
    static func statusText(_ a: AppleModelAvailability, inUse: Bool) -> String {
        switch a {
        case .available: inUse ? "In use" : "Built in · no download"
        case .notEnabled: "Turn on Apple Intelligence in System Settings"
        case .modelNotReady: "macOS is still preparing the model"
        case .deviceNotEligible: "Not supported on this Mac"
        case .osTooOld: "Needs macOS 26"
        }
    }

    /// A toast or status line for a check that can't run on Apple's model.
    static func notReadyTitle(_ a: AppleModelAvailability) -> String {
        switch a {
        case .available, .osTooOld: "Apple Intelligence needs macOS 26."
        case .notEnabled: "Apple Intelligence is off."
        case .modelNotReady: "Apple Intelligence is still getting ready."
        case .deviceNotEligible: "Apple Intelligence isn't supported on this Mac."
        }
    }

    /// One short status line ("Apple Intelligence is off") for the popover and the right-click menu.
    static func shortStatus(_ a: AppleModelAvailability) -> String {
        switch a {
        case .available: "Ready"
        case .notEnabled: "Apple Intelligence is off"
        case .modelNotReady: "Apple Intelligence is getting ready"
        case .deviceNotEligible: "Apple Intelligence not supported here"
        case .osTooOld: "Apple Intelligence needs macOS 26"
        }
    }
}
