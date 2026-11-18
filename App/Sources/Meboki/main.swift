import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)  // menu-bar only, no Dock icon
    #if DEBUG
    // `.build/debug/Meboki --gallery`: only the design component gallery, no hotkey, model or server.
    if CommandLine.arguments.contains("--gallery") {
        DesignGallery.show(activate: false)
        print("gallery window \(DesignGallery.windowNumber)")
        fflush(stdout)
        app.run()
        return
    }
    // `.build/debug/Meboki --demo-popups`: the real card and toast windows with sample content, placed
    // around a fake field in the middle of the main screen. Never takes the keyboard. Prints window numbers.
    // `.build/debug/Meboki --settings-demo [pane] [--dark] [--recording] [--bubble]
    // [--licence-state trial|trialFresh|lastDay|free|licensed|revoked]`: only the Settings
    // window with sample state (its own defaults suite), shown without activating. Prints its window number.
    if let i = CommandLine.arguments.firstIndex(of: "--settings-demo") {
        let args = CommandLine.arguments
        let pane = args.indices.contains(i + 1) ? SettingsPane(rawValue: args[i + 1]) : nil
        SettingsDemo.show(pane: pane ?? .general, dark: args.contains("--dark"),
                          recording: args.contains("--recording"), bubble: args.contains("--bubble"),
                          licenceState: args.firstIndex(of: "--licence-state").flatMap {
                              args.indices.contains($0 + 1) ? args[$0 + 1] : nil })
        app.run()
        return
    }
    // `.build/debug/Meboki --onboarding-demo [welcome|access|model|tryIt|popup|done] [--dark] [--trusted]
    // [--downloading]`: only the onboarding window with sample state, shown without activating.
    if let i = CommandLine.arguments.firstIndex(of: "--onboarding-demo") {
        let args = CommandLine.arguments
        let name = args.indices.contains(i + 1) ? args[i + 1] : ""
        let step = OnboardingStep.allCases.first { "\($0)" == name } ?? .welcome
        OnboardingDemo.show(step: step, dark: args.contains("--dark"), trusted: args.contains("--trusted"),
                            downloading: args.contains("--downloading"))
        app.run()
        return
    }
    // `.build/debug/Meboki --contrast-probe`: glass over flat backdrops, for contrast measurements (§11).
    if CommandLine.arguments.contains("--contrast-probe") {
        ContrastProbe.show()
        app.run()
        return
    }
    // `.build/debug/Meboki --probe-field <bundle id> [word …] [--select word]`: what the text adapter sees
    // in that app's focused field (FieldProbe.swift). Prints and exits.
    if CommandLine.arguments.contains("--probe-field") {
        FieldProbe.run(CommandLine.arguments)
        return
    }
    // `.build/debug/Meboki --licence-status`: the entitlement this Mac has now (read-only), then exits.
    // `.build/debug/Meboki --verify-licence <key>`: what the key says (email, seats, kid), then exits. Stores nothing.
    if CommandLine.arguments.contains("--licence-status") || CommandLine.arguments.contains("--verify-licence") {
        LicenceCLI.run(CommandLine.arguments)
        return
    }
    if CommandLine.arguments.contains("--demo-popups") {
        DemoPopups.show()
        app.run()
        return
    }
    #endif
    LegacyMigration.run()  // before AppDelegate reads settings, models or logs
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
