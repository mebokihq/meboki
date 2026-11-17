#if DEBUG
import AppKit
import MebokiCore

/// DEBUG `--onboarding-demo [step] [--dark] [--trusted] [--downloading]`: the real onboarding window with sample
/// state (its own `UserDefaults` suite, fake model states, no server), shown without activating. For screenshots.
@MainActor
enum OnboardingDemo {
    private static var controller: OnboardingWindowController?

    static func show(step: OnboardingStep, dark: Bool, trusted: Bool, downloading: Bool) {
        let suite = "dev.local.meboki.onboarding-demo"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults)
        let args = CommandLine.arguments
        settings.popupStyle = args.contains("--island") ? .island : args.contains("--bubble") ? .bubble : .card

        let store = ModelStore()
        let m = Catalog.recommended
        if downloading {
            store.demoInstalled = []
            store.demoSet(m, .downloading(written: m.bytes * 37 / 100, total: m.bytes))
        } else {
            store.demoInstalled = [m.id]
        }

        let model = OnboardingModel(selectedModelID: m.id)
        model.step = step
        model.trusted = trusted
        model.askedForAccess = !trusted
        model.engine = downloading ? .downloading(m.shortName, fraction: 0.37) : .ready(model: m.shortName, cloud: false)
        if step == .tryIt, !downloading {
            let text = OnboardingModel.sample
            let fixes: [(String, String)] = [("Their", "They're"), ("libary", "library"), ("tomorow", "tomorrow"),
                                             ("dont", "doesn't"), ("were", "where")]
            let ns = text as NSString
            let edits = fixes.map { o, r in Edit(range: ns.range(of: o), original: o, replacement: r) }
            model.tryState = .done(text: text, edits: edits, seconds: 1.3)
        }
        let c = OnboardingWindowController(model: model, settings: settings, store: store)
        controller = c
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        c.show(activate: false)
        print("onboarding window \(c.windowNumber)")
        fflush(stdout)
    }
}
#endif
