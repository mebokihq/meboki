import Foundation

/// One-time moves of data left by older builds. Runs before anything reads them (`main.swift`), only in the
/// bundled app, so a debug binary never moves the real data. Never overwrites: a key or file that already
/// exists is kept.
///
/// - Bundle ID `dev.local.meboki` (local builds before the release bundle ID `com.meboki.app`): its settings.
///   Files live in folders named after the app (`Application Support/Meboki`, `Logs/Meboki`), so they stay put.
/// - Bundle ID `dev.local.proofreader` (builds from before the rename to Meboki): settings, downloaded models,
///   the practice note and logs.
///
/// API keys are moved lazily by `APIKeyStore` (reading an old Keychain item may prompt once). The trial's
/// Keychain copy isn't read from the old service (that read could prompt); its `UserDefaults` copy comes over
/// with the settings and is written to the new Keychain service on the next trial update.
enum LegacyMigration {
    static let bundleID = "com.meboki.app"
    static let devBundleID = "dev.local.meboki"
    static let proofreaderBundleID = "dev.local.proofreader"
    private static let doneKey = "migratedFromDevLocal"

    static func run() {
        guard Bundle.main.bundleIdentifier == bundleID else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }

        // Newest first: a key set by both old builds takes the `dev.local.meboki` value.
        for legacy in [devBundleID, proofreaderBundleID] {
            guard let old = defaults.persistentDomain(forName: legacy), !old.isEmpty else { continue }
            for (key, value) in old where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }

        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let logs = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs")
        move(support.appendingPathComponent("Proofreader"), to: support.appendingPathComponent("Meboki"))
        move(support.appendingPathComponent("Meboki/Proofreader Practice.txt"),
             to: support.appendingPathComponent("Meboki/Meboki Practice.txt"))
        move(logs.appendingPathComponent("Proofreader"), to: logs.appendingPathComponent("Meboki"))
        move(logs.appendingPathComponent("Meboki/proofreader.log"), to: logs.appendingPathComponent("Meboki/meboki.log"))

        defaults.set(true, forKey: doneKey)
    }

    private static func move(_ from: URL, to: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { return }
        try? fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.moveItem(at: from, to: to)
    }
}
