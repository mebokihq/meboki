#if DEBUG
import AppKit
import MebokiCore

/// DEBUG demos (`--settings-demo`, `--onboarding-demo`, `--popover-demo`, `--trial-ended-demo`): a licence manager
/// with its own temp folder, defaults and Keychain service, forced into one state. Never reads or writes the
/// real trial or key, never uses the network.
@MainActor
enum LicenceDemo {
    /// `--licence-state <trial|trialFresh|lastDay|free|licensed|revoked>`, or nil for the default (trial, 4 days left).
    static func state(from args: [String]) -> String? {
        args.firstIndex(of: "--licence-state").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }

    static func manager(state: String?, defaults: UserDefaults) -> LicenceManager {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("meboki-licence-demo")
        try? FileManager.default.removeItem(at: dir)
        // Older demo builds kept a Keychain item here; demos use none now.
        TrialStore.removeKeychainItem(service: "com.meboki.app.trial.demo")
        let licence = LicenceManager(licenceStore: LicenceStore(directory: dir),
                                     trialStore: TrialStore(defaults: defaults, service: "com.meboki.app.trial.demo",
                                                            keychain: false),
                                     defaults: defaults, fetchEnabled: false, observeSystem: false,
                                     joinKeychain: false)
        apply(state ?? "trial", to: licence)
        return licence
    }

    static func apply(_ state: String, to licence: LicenceManager) {
        let cal = Calendar.licenceDays
        func past(_ n: Int) -> [String] {
            (1...max(n, 1)).prefix(n).map { TrialClock.dayString(Date().addingTimeInterval(-Double($0) * 86_400), calendar: cal) }
        }
        let today = TrialClock.dayString(Date(), calendar: cal)
        let used7 = TrialClock(days: past(7), lastSeen: today)
        switch state {
        case "trialFresh": licence.debugForce(.trial(daysLeft: 7), trial: TrialClock(lastSeen: today))
        case "lastDay":
            licence.debugForce(.trial(daysLeft: 1), trial: TrialClock(days: past(6) + [today], lastSeen: today))
        case "free": licence.debugForce(.free(.trialEnded), trial: used7)
        case "revoked": licence.debugForce(.free(.revoked), trial: used7)
        case "licensed":
            let info = LicenceInfo(kid: "DEMO", email: "maya@example.com", type: .personal, seats: 1,
                                   issued: Date().addingTimeInterval(-9 * 86_400), expires: nil,
                                   key: "MEBOKI-eyJ2IjoxLCJraWQiOiJERU1PIn0.ZGVtby1zaWduYXR1cmUtbm90LWEtcmVhbC1rZXk")
            licence.debugForce(.licensed(info), trial: TrialClock(days: past(3), lastSeen: today))
        default:
            licence.debugForce(.trial(daysLeft: 4), trial: TrialClock(days: past(3), lastSeen: today))
        }
    }
}

/// With `MEBOKI_DEMO_SNAPSHOT=<file.png>` the demos draw their window into that file after a moment and quit. It
/// works while the screen is locked, where `screencapture` can't see windows (the glass blur isn't drawn).
@MainActor
enum DemoSnapshot {
    static func scheduleIfRequested(_ window: NSWindow?, after delay: TimeInterval = 1.2) {
        guard let path = ProcessInfo.processInfo.environment["MEBOKI_DEMO_SNAPSHOT"], let window else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let view = window.contentView?.superview ?? window.contentView else { exit(2) }
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { print("snapshot: bounds \(view.bounds) \(window.frame)"); exit(3) }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { exit(4) }
            try? png.write(to: URL(fileURLWithPath: path))
            exit(0)
        }
    }
}

/// DEBUG `--trial-ended-demo [--revoked|--expired] [--dark]`: the notice window, shown without activating.
@MainActor
enum TrialEndedDemo {
    private static var controller: TrialEndedWindowController?

    static func show(variant: LicenceNoticeVariant, dark: Bool) {
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let c = TrialEndedWindowController(variant: variant, hotkey: "⌃⌥G", actions: LicenceNoticeActions())
        controller = c
        let before = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?"
        c.show()
        // Focus check for the stage report: who is frontmost right after the window came up, and a moment later.
        print("frontmost before: \(before)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            print("frontmost after: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")")
            print("meboki active: \(NSApp.isActive), key window: \(NSApp.keyWindow != nil)")
            fflush(stdout)
        }
        DemoSnapshot.scheduleIfRequested(c.debugWindow)
        print("trial-ended window \(c.windowNumber)")
        fflush(stdout)
    }
}

/// DEBUG `--popover-demo [--licence-state …] [--dark] [--app-name N] [--use-apple [--apple-model <state>]]`: the
/// menu-bar popover under a fake status item; `--use-apple` shows Apple's built-in model in the model row.
@MainActor
enum PopoverDemo {
    private static var panel: PopoverPanel?
    private static var licence: LicenceManager?

    static func show(licenceState: String?, dark: Bool) {
        let suite = "com.meboki.app.popover-demo"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults)
        let lic = LicenceDemo.manager(state: licenceState, defaults: defaults)
        settings.entitlement = lic.entitlement
        settings.underlineAsYouType = true
        settings.checkLevel = .grammar
        licence = lic
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let p = PopoverPanel(settings: settings, licence: lic)
        let m = Catalog.gemma4E4B
        p.model.status = PopoverStatus(kind: .ready, text: "Ready")
        p.model.modelID = m.id
        p.model.modelName = m.shortName
        p.model.peakMemoryGB = m.peakMemoryGB
        p.model.paragraphSeconds = m.paragraphSeconds
        p.model.ramGB = 16
        if CommandLine.arguments.contains("--use-apple") {
            let a = AppleIntelligence.current() == .osTooOld && AppleIntelligence.forced == nil ? .available
                : AppleIntelligence.current()
            p.model.modelID = AppleIntelligence.id
            p.model.modelName = AppleModel.displayName
            p.model.builtIn = true
            p.model.status = a.isAvailable ? PopoverStatus(kind: .ready, text: "Ready · \(AppleModel.displayName)")
                : PopoverStatus(kind: .error, text: AppleIntelligence.shortStatus(a))
        }
        p.model.appName = "Notes"
        p.model.appBundleID = "com.apple.Notes"
        panel = p
        let screen = NSScreen.main
        let f = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        p.show(under: CGRect(x: f.midX, y: f.maxY - 24, width: 28, height: 24), screen: screen)
        DemoSnapshot.scheduleIfRequested(p.debugWindow)
        print("popover window \(p.windowNumber)")
        fflush(stdout)
    }
}
#endif
