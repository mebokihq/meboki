import Foundation
import MebokiCore
import LocalAuthentication
import Security

/// The trial clock, kept twice (PLAN.md §6 "Trial storage"): a login Keychain item (survives deleting the app and
/// its preferences) and `UserDefaults`. A read joins both; a write updates both. A Keychain failure never blocks.
///
/// The Keychain can stall for as long as it likes (a locked login keychain waits for the user), so the app never
/// touches it on the main thread: it starts from `readLocal()`, asks for `readKept` in the background and joins
/// the answer when it comes. Keychain writes are queued the same way.
struct TrialStore {
    /// Every Keychain call of the app runs here, in order.
    static let queue = DispatchQueue(label: "dev.local.meboki.trial-keychain", qos: .utility)

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
    /// False (demos): the Keychain is never read, written or erased.
    let keychain: Bool

    init(defaults: UserDefaults = .standard, service: String = TrialStore.defaultService, interactive: Bool = true,
         keychain: Bool = true) {
        self.defaults = defaults
        self.service = service
        self.interactive = interactive
        self.keychain = keychain
    }

    private static let daysKey = "trialDays"
    private static let lastDayKey = "trialLastDay"
    private static let account = "trial"

    /// The `UserDefaults` copy only. Never blocks.
    func readLocal() -> TrialClock {
        TrialClock(days: defaults.stringArray(forKey: Self.daysKey) ?? [],
                   lastSeen: defaults.string(forKey: Self.lastDayKey))
    }

    /// Both copies joined, waiting at most `timeout` seconds for the Keychain (command-line status only, never
    /// the app's main thread). `timedOut`: the Keychain didn't answer and only the local copy is returned.
    func read(timeout: TimeInterval) -> (clock: TrialClock, timedOut: Bool) {
        let local = readLocal()
        guard keychain else { return (local, false) }
        let box = Box()
        let service = service, interactive = interactive
        Self.queue.async {
            box.set(Self.kept(service: service, interactive: interactive))
        }
        guard box.wait(timeout) else { return (local, true) }
        return (box.value.map { local.merged(with: $0) } ?? local, false)
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private let sem = DispatchSemaphore(value: 0)
        private var kept: TrialClock?
        var value: TrialClock? { lock.lock(); defer { lock.unlock() }; return kept }
        func set(_ c: TrialClock?) { lock.lock(); kept = c; lock.unlock(); sem.signal() }
        func wait(_ t: TimeInterval) -> Bool { sem.wait(timeout: .now() + t) == .success }
    }

    /// Deletes a Keychain item of a (demo) service, in the background.
    static func removeKeychainItem(service: String) {
        queue.async { SecItemDelete(query(service) as CFDictionary) }
    }

    /// Reads the Keychain copy in the background and hands it over on the main queue (nil: none, or no access).
    func readKept(_ done: @escaping @MainActor (TrialClock?) -> Void) {
        guard keychain else { DispatchQueue.main.async { MainActor.assumeIsolated { done(nil) } }; return }
        let service = service, interactive = interactive
        Self.queue.async {
            let kept = Self.kept(service: service, interactive: interactive)
            DispatchQueue.main.async { MainActor.assumeIsolated { done(kept) } }
        }
    }

    /// `UserDefaults` at once, the Keychain in the background.
    func write(_ clock: TrialClock) {
        defaults.set(clock.days, forKey: Self.daysKey)
        if let last = clock.lastSeen { defaults.set(last, forKey: Self.lastDayKey) }
        guard keychain, let data = try? JSONEncoder().encode(clock) else { return }
        let service = service
        Self.queue.async { Self.writeKeychain(data, service: service) }
    }

    /// Forgets the trial in both places (debug reset).
    func erase() {
        defaults.removeObject(forKey: Self.daysKey)
        defaults.removeObject(forKey: Self.lastDayKey)
        guard keychain else { return }
        let service = service
        Self.queue.async { SecItemDelete(Self.query(service) as CFDictionary) }
    }

    private static func query(_ service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func kept(service: String, interactive: Bool) -> TrialClock? {
        readKeychain(service: service, interactive: interactive)
            .flatMap { try? JSONDecoder().decode(TrialClock.self, from: $0) }
    }

    private static func readKeychain(service: String, interactive: Bool) -> Data? {
        var q = query(service)
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

    private static func writeKeychain(_ data: Data, service: String) {
        let update = SecItemUpdate(query(service) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard update == errSecItemNotFound else { return }
        var add = query(service)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Meboki trial"
        SecItemAdd(add as CFDictionary, nil)
    }
}
