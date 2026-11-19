import Foundation
import MebokiCore
import Security

/// BYOK API keys, one per cloud provider, in the login Keychain only (PLAN.md §6 "No secrets in the client").
/// Never in `UserDefaults`, logs or the app bundle. The item is owned by the app's code signature
/// that saved it, so reading it doesn't prompt.
enum APIKeyStore {
    private static let service = "com.meboki.app.api-key"

    /// The services of older builds (`LegacyMigration`), newest first. A key found there is copied to `service`.
    private static let legacyServices = ["dev.local.meboki.api-key", "dev.local.proofreader.api-key"]

    private static func query(_ provider: CloudProvider, service: String = service) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: provider.rawValue]
    }

    static func key(for provider: CloudProvider) -> String? {
        if let key = read(query(provider)) { return key }
        // Older builds signed with another identifier own the old item, so this read may ask for the
        // keychain password once; after the copy, the new item is ours and reads don't prompt.
        for legacy in legacyServices {
            guard let old = read(query(provider, service: legacy)) else { continue }
            _ = save(old, for: provider)
            return old
        }
        return nil
    }

    private static func read(_ base: [String: Any]) -> String? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        let key = String(decoding: data, as: UTF8.self)
        return key.isEmpty ? nil : key
    }

    static func hasKey(_ provider: CloudProvider) -> Bool { key(for: provider) != nil }

    /// Saves or replaces the key. Returns an error message, or nil.
    static func save(_ key: String, for provider: CloudProvider) -> String? {
        let data = Data(key.utf8)
        let update = SecItemUpdate(query(provider) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return nil }
        guard update == errSecItemNotFound else { return message(update) }
        var add = query(provider)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "Meboki \(provider.name) API key"
        let status = SecItemAdd(add as CFDictionary, nil)
        return status == errSecSuccess ? nil : message(status)
    }

    static func remove(_ provider: CloudProvider) {
        SecItemDelete(query(provider) as CFDictionary)
        for legacy in legacyServices {  // or `key(for:)` copies it back
            SecItemDelete(query(provider, service: legacy) as CFDictionary)
        }
    }

    private static func message(_ status: OSStatus) -> String {
        "Keychain: " + ((SecCopyErrorMessageString(status, nil) as String?) ?? "error \(status)")
    }
}
