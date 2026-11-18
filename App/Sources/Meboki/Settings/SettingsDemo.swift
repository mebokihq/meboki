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

        let licence = LicenceDemo.manager(state: licenceState, defaults: defaults)
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
        DemoSnapshot.scheduleIfRequested(c.debugWindow)
    }
}
#endif
