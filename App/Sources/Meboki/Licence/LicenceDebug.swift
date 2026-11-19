#if DEBUG
import CryptoKit
import Foundation
import Security

/// DEBUG: the licence manager's clock (`LicenceManager.shared`), real time plus an offset kept across launches.
enum DebugClock {
    private static let key = "debugClockOffset"

    static var offset: TimeInterval {
        get { UserDefaults.standard.double(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static var now: Date { Date().addingTimeInterval(offset) }
}

/// DEBUG: signs test licence keys and revoked lists with the test-payment key, which DEBUG builds trust
/// (`LicenceKey.acceptsSandboxKeys`). The private key is read from the login Keychain (an item only the
/// developer's Mac has); it is never in the source. Release builds don't contain this.
enum DebugSigner {
    typealias Key = Curve25519.Signing.PrivateKey

    static let service = "meboki"
    static let account = "app-license-sandbox-private-key"

    enum Failure: Error, CustomStringConvertible {
        case noKey(OSStatus)
        case badKey

        var description: String {
            switch self {
            case .noKey(let s): "Test signing key not found in the Keychain (\(service) / \(account), status \(s))"
            case .badKey: "Test signing key in the Keychain is not an Ed25519 PKCS8 key"
            }
        }
    }

    nonisolated(unsafe) private static var cached: Curve25519.Signing.PrivateKey?
    private static let lock = NSLock()

    /// Reads the key off the main thread (the Keychain may ask the user) and calls back on the main thread.
    static func withKey(_ done: @escaping @MainActor (Result<Curve25519.Signing.PrivateKey, Failure>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = loadKey()
            DispatchQueue.main.async { MainActor.assumeIsolated { done(result) } }
        }
    }

    private static func loadKey() -> Result<Curve25519.Signing.PrivateKey, Failure> {
        lock.lock(); defer { lock.unlock() }
        if let cached { return .success(cached) }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return .failure(.noKey(status)) }
        // Stored as base64 text of the PKCS8 DER; an Ed25519 PKCS8 is 48 bytes ending in the 32-byte seed.
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let der = Data(base64Encoded: text), der.count == 48,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: der.suffix(32)) else { return .failure(.badKey) }
        cached = key
        return .success(key)
    }

    /// A key in the Worker's format. Field order as the Worker writes it (v, kid, email, type, seats, iat[, exp]).
    static func licence(with key: Curve25519.Signing.PrivateKey, issued: Date, corporateExpiry: Date? = nil) -> String {
        let kid = "DBG" + String((0..<13).map { _ in Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567").randomElement()! })
        var json = #"{"v":1,"kid":"\#(kid)","email":"debug@example.com","type":"\#(corporateExpiry == nil ? "personal" : "corporate")","seats":\#(corporateExpiry == nil ? 1 : 5),"iat":"\#(iso(issued))""#
        if let exp = corporateExpiry { json += #","exp":"\#(iso(exp))""# }
        json += "}"
        return "MEBOKI-" + signed(Data(json.utf8), with: key)
    }

    /// A revoked list in the Worker's format.
    static func revokedList(kids: [String], issued: Date, with key: Curve25519.Signing.PrivateKey) -> Data {
        let payload = try! JSONSerialization.data(withJSONObject: ["v": 1, "issued": iso(issued), "kids": kids.sorted()] as [String: Any],
                                                  options: [.sortedKeys])
        let parts = signed(payload, with: key).split(separator: ".")
        return Data(#"{"payload":"\#(parts[0])","sig":"\#(parts[1])"}"#.utf8)
    }

    /// base64url(payload) + "." + base64url(signature).
    private static func signed(_ payload: Data, with key: Curve25519.Signing.PrivateKey) -> String {
        let sig = try! key.signature(for: payload)
        return b64url(payload) + "." + b64url(sig)
    }

    private static func b64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
}
#endif
