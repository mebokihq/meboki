#if DEBUG
import AppKit
import Combine
import MebokiCore

/// DEBUG `--settings-demo`: the real Settings window with the HTML reference's sample state, for comparing
/// with the `app-*` screenshots. Uses its own `UserDefaults` suite and fake model states; never activates.
@MainActor
enum SettingsDemo {
    private static var controller: SettingsWindowController?
    private static var subscriptions: Set<AnyCancellable> = []

    /// `--licence-state <trial|trialFresh|lastDay|free|licensed|revoked>`.
    private static func applyLicenceState(_ state: String, to licence: LicenceManager) {
        let cal = Calendar.current
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

    static func show(pane: SettingsPane, dark: Bool, recording: Bool, bubble: Bool, licenceState: String? = nil) {
        let suite = "dev.local.meboki.settings-demo"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults)
        settings.popupStyle = bubble ? .bubble : .card
        settings.checkedApps = ["com.apple.Safari": "Safari", "com.google.Chrome": "Google Chrome",
                                "com.apple.Notes": "Notes", "com.tinyspeck.slackmacgap": "Slack",
                                "com.apple.MobileSMS": "Messages", "com.apple.Terminal": "Terminal",
                                "com.apple.dt.Xcode": "Xcode"]
        settings.appModes = ["com.tinyspeck.slackmacgap": .casual, "com.apple.MobileSMS": .casual,
                             "com.apple.Terminal": .off]

        let store = ModelStore()
        store.demoInstalled = [Catalog.gemma4E4B.id]
        store.demoSet(Catalog.gemma4E2B, .downloading(written: 1_510_000_000, total: Catalog.gemma4E2B.bytes))

        // Own licence state: a temp folder, the demo defaults and a demo Keychain service, so the real trial and
        // licence are never read or written. No network.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("meboki-licence-demo")
        try? FileManager.default.removeItem(at: dir)
        let licence = LicenceManager(licenceStore: LicenceStore(directory: dir),
                                     trialStore: TrialStore(defaults: defaults, service: "dev.local.meboki.trial.demo"),
                                     defaults: defaults, fetchEnabled: false, observeSystem: false)
        applyLicenceState(licenceState ?? "trial", to: licence)
        settings.entitlement = licence.entitlement
        licence.transitions.sink { settings.entitlement = $0.to }.store(in: &subscriptions)

        let model = SettingsModel(pane: pane, selectedModelID: Catalog.gemma4E4B.id, licence: licence)
        model.launchAtLogin = true
        let c = SettingsWindowController(model: model, settings: settings, store: store)
        controller = c
        c.show(activate: false)
        model.recording = recording
        if let w = c.debugWindow {
            w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            w.orderFrontRegardless()
            print("settings window \(w.windowNumber)")
            fflush(stdout)
        }
    }
}
#endif
