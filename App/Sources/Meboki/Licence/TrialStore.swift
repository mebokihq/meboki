import Foundation
import MebokiCore
import LocalAuthentication
import Security

/// The trial clock, kept twice (PLAN.md §6 "Trial storage"): a login Keychain item (survives deleting the app and
/// its preferences) and `UserDefaults`. A read joins both; a write updates both. A Keychain failure never blocks.
struct TrialStore {
    /// The real service; builds that aren't the installed app (a `swift build` binary) get their own suffix, so
    /// a debug run never touches the installed app's trial.
    static var defaultService: String {
        let real = "dev.local.meboki.trial"
        return Bundle.main.bundleIdentifier == "dev.local.meboki" ? real : real + ".debug"
    }

    let defaults: UserDefaults
    let service: String
    /// False: a Keychain read never shows a prompt (it just fails), for command-line status.
    let interactive: Bool

    init(defaults: UserDefaults = .standard, service: String = TrialStore.defaultService, interactive: Bool = true) {
        self.defaults = defaults
        self.service = service
        self.interactive = interactive
    }

    private static let daysKey = "trialDays"
    private static let lastDayKey = "trialLastDay"
    private static let account = "trial"

    func read() -> TrialClock {
        let local = TrialClock(days: defaults.stringArray(forKey: Self.daysKey) ?? [],
                               lastSeen: defaults.string(forKey: Self.lastDayKey))
        guard let data = readKeychain(), let kept = try? JSONDecoder().decode(TrialClock.self, from: data) else {
            return local
        }
        return local.merged(with: kept)
    }

    func write(_ clock: TrialClock) {
        defaults.set(clock.days, forKey: Self.daysKey)
        if let last = clock.lastSeen { defaults.set(last, forKey: Self.lastDayKey) }
        guard let data = try? JSONEncoder().encode(clock) else { return }
        writeKeychain(data)
    }

    /// Forgets the trial in both places (debug reset).
    func erase() {
        defaults.removeObject(forKey: Self.daysKey)
        defaults.removeObject(forKey: Self.lastDayKey)
        SecItemDelete(query() as CFDictionary)
    }

    private func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: Self.account]
    }

    private func readKeychain() -> Data? {
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        if !interactive {
            let context = LAContext()
            context.interactionNotAllowed = true
            q[kSecUseAuthenticationContext as String] = context
        }
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    private func writeKeychain(_ data: Data) {
        let update = SecItemUpdate(query() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard update == errSecItemNotFound else { return }
        var add = query()
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Meboki trial"
        SecItemAdd(add as CFDictionary, nil)
    }
}
