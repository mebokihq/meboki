import Foundation

/// One-time move of data left by builds from before the rename to Meboki (bundle ID `dev.local.proofreader`):
/// settings, downloaded models, the practice note and logs. Runs before anything reads them (`main.swift`), only
/// in the bundled app, so a debug binary never moves the real data. Never overwrites: a step whose target already
/// exists is skipped. API keys are moved lazily by `APIKeyStore` (reading the old Keychain item may prompt).
enum LegacyMigration {
    static let legacyBundleID = "dev.local.proofreader"
    private static let doneKey = "migratedFromProofreader"

    static func run() {
        guard Bundle.main.bundleIdentifier == "dev.local.meboki" else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }

        if let old = defaults.persistentDomain(forName: legacyBundleID), !old.isEmpty {
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
