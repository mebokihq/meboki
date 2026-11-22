#if DEBUG
import AppKit
import Combine
import MebokiCore

/// DEBUG `--settings-demo`: the real Settings window with the HTML reference's sample state, for comparing
/// with the `app-*` screenshots. Uses its own `UserDefaults` suite and fake model states; never activates.
/// Apple's built-in model: `--apple-model available|notEnabled|modelNotReady|deviceNotEligible|osTooOld` sets the
/// row's state (default: what this Mac says), `--use-apple` makes it the model in use.
@MainActor
enum SettingsDemo {
    private static var controller: SettingsWindowController?
    private static var subscriptions: Set<AnyCancellable> = []

    static func show(pane: SettingsPane, dark: Bool, recording: Bool, bubble: Bool, licenceState: String? = nil) {
        let suite = "com.meboki.app.settings-demo"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults)
        settings.popupStyle = bubble ? .bubble : .card
        // `--tone vivid|eased|muted|dusty` (raw values: current, eased, muted, dusty).
        if let i = CommandLine.arguments.firstIndex(of: "--tone"), i + 1 < CommandLine.arguments.count {
            let name = CommandLine.arguments[i + 1]
            settings.colorTone = ColorTone(rawValue: name == "vivid" ? "current" : name) ?? .muted
        }
        // `--popup-opacity 0…1`: Settings › Appearance › Popup opacity.
        if let i = CommandLine.arguments.firstIndex(of: "--popup-opacity"), i + 1 < CommandLine.arguments.count,
           let o = Double(CommandLine.arguments[i + 1]) {
            settings.popupOpacity = min(1, max(0, o))
        }
        // `--underline-curve 0…1`: Settings › Appearance › Wave.
        if let i = CommandLine.arguments.firstIndex(of: "--underline-curve"), i + 1 < CommandLine.arguments.count,
           let c = Double(CommandLine.arguments[i + 1]) {
            settings.underlineCurve = min(1, max(0, c))
        }
        // `--size 800x500`: open at that window size (still clamped to the minimum and the screen).
        if let i = CommandLine.arguments.firstIndex(of: "--size"), i + 1 < CommandLine.arguments.count {
            let parts = CommandLine.arguments[i + 1].split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { settings.settingsWindowSize = CGSize(width: parts[0], height: parts[1]) }
        }
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
        model.appleModel = AppleIntelligence.current()
        if CommandLine.arguments.contains("--use-apple") { settings.modelSource = .apple }
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
