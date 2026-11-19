import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Personal or corporate licence (PLAN.md §6 "Licence delivery").
public enum LicenceType: String, Sendable, Equatable {
    case personal, corporate
}

/// What a verified licence key says. The key is signed, so everything here can be trusted once `LicenceKey.verify`
/// returns it.
public struct LicenceInfo: Sendable, Equatable {
    /// Opaque key ID (hash of the payment), matched against the revoked list.
    public let kid: String
    public let email: String
    public let type: LicenceType
    /// Macs bought. On honour, not enforced.
    public let seats: Int
    public let issued: Date
    /// Corporate keys only.
    public let expires: Date?
    /// The cleaned key text, as stored in the licence file.
    public let key: String
    /// Signed by the test-payment signer (`LicenceKey.sandboxPublicKey`). Only DEBUG builds accept such keys.
    public let sandbox: Bool

    public init(kid: String, email: String, type: LicenceType, seats: Int, issued: Date, expires: Date?, key: String,
                sandbox: Bool = false) {
        self.kid = kid
        self.email = email
        self.type = type
        self.seats = seats
        self.issued = issued
        self.expires = expires
        self.key = key
        self.sandbox = sandbox
    }
}

/// Why a pasted key was rejected. `message` is the line the UI shows.
public enum LicenceError: Error, Sendable, Equatable {
    /// No `MEBOKI-…` key in the text.
    case notAKey
    /// Bad base64, bad signature or unreadable payload: incomplete or changed.
    case damaged
    /// Payload version above what this app reads.
    case newerFormat

    public var message: String {
        switch self {
        case .notAKey: LicenceText.notAKey
        case .damaged: LicenceText.damaged
        case .newerFormat: LicenceText.newerFormat
        }
    }
}

/// Every licence line the user can see, in one place.
public enum LicenceText {
    public static let supportEmail = "support@meboki.com"
    public static let notAKey = "That doesn't look like a Meboki licence key. Copy the whole key from your purchase email, starting with MEBOKI-."
    public static let damaged = "This key is incomplete or was changed. Copy it again from your purchase email."
    public static let newerFormat = "This key needs a newer version of Meboki."
    public static let replaceNote = "A licence is already active on this Mac. Press Activate to replace it."
    public static let revoked = "This licence was refunded or cancelled. Questions: \(supportEmail)"
    public static let expired = "This licence has expired. Renew it to keep the full app."
    public static let trialEnded = "Meboki is now in free mode. Your settings are saved and come back with a licence."
}

/// Licence keys: `MEBOKI-` + base64url(payload JSON) + `.` + base64url(Ed25519 signature over those payload bytes),
/// without padding. Checked offline with the public key (PLAN.md §6 "Licence delivery").
public enum LicenceKey {
    /// Raw 32-byte Ed25519 public key of the licence signer.
    public static let productionPublicKey = Data(base64Encoded: "ePn8wpeQIBVRqJ1pXk0JgibAPbZ9cTGEeGFkijcetig=")!
    /// Raw 32-byte Ed25519 public key of the test-payment signer. Keys bought with test cards are signed with it,
    /// so they never unlock a release build.
    public static let sandboxPublicKey = Data(base64Encoded: "Zv3qqHV8m4sDwJ7EGRWt9DdTxZngNXd/lRes9aiH0Vo=")!

    /// Whether this build accepts keys and revoked lists from the test-payment signer: DEBUG builds only.
    #if DEBUG
    public static let acceptsSandboxKeys = true
    #else
    public static let acceptsSandboxKeys = false
    #endif

    static let prefix = "MEBOKI-"
    /// An Ed25519 signature is 64 bytes, 86 base64url characters.
    static let signatureLength = 86

    /// Pulls the key out of pasted text: finds `MEBOKI-`, drops whitespace and line breaks inside it (mail
    /// clients wrap long lines), and ignores surrounding quotes, angle brackets, a leading label such as
    /// "Licence key:" and any text after the key. Text without a key comes back trimmed and unchanged.
    public static func clean(_ text: String) -> String {
        guard let start = text.range(of: prefix) else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var out = prefix
        var seenDot = false
        var sigChars = 0
        for ch in text[start.upperBound...] {
            if ch.isWhitespace { continue }
            if ch == "." && !seenDot {
                seenDot = true
                out.append(ch)
            } else if Base64URL.isAllowed(ch) {
                if seenDot {
                    if sigChars == signatureLength { break }
                    sigChars += 1
                }
                out.append(ch)
            } else {
                break
            }
        }
        return out
    }

    /// Checks `text` against the production key and, when `sandboxAllowed`, the test-payment key.
    public static func verify(_ text: String, sandboxAllowed: Bool = acceptsSandboxKeys) -> Result<LicenceInfo, LicenceError> {
        let result = verify(text, publicKey: productionPublicKey)
        guard sandboxAllowed, result == .failure(.damaged) else { return result }
        let sandbox = verify(text, publicKey: sandboxPublicKey, sandbox: true)
        return sandbox == .failure(.damaged) ? result : sandbox
    }

    /// Cleans `text`, checks the signature with `publicKey` (raw 32 bytes) and reads the payload.
    /// Revoked and expired are not decided here (`RevokedList`, `Entitlement.resolve`).
    public static func verify(_ text: String, publicKey: Data, sandbox: Bool = false) -> Result<LicenceInfo, LicenceError> {
        let key = clean(text)
        guard key.hasPrefix(prefix) else { return .failure(.notAKey) }
        let body = key.dropFirst(prefix.count)
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return .failure(.notAKey) }
        guard let payload = Base64URL.decode(String(parts[0])),
              let sig = Base64URL.decode(String(parts[1])),
              Ed25519.verify(signature: sig, message: payload, publicKey: publicKey) else { return .failure(.damaged) }
        guard let probe = try? JSONDecoder().decode(Probe.self, from: payload) else { return .failure(.damaged) }
        if probe.v > 1 { return .failure(.newerFormat) }
        guard probe.v == 1, let p = try? JSONDecoder().decode(Payload.self, from: payload),
              let type = LicenceType(rawValue: p.type), let issued = ISODate.parse(p.iat) else { return .failure(.damaged) }
        var expires: Date?
        if let exp = p.exp {
            guard let d = ISODate.parse(exp) else { return .failure(.damaged) }
            expires = d
        }
        return .success(LicenceInfo(kid: p.kid, email: p.email, type: type, seats: p.seats, issued: issued, expires: expires, key: key,
                                      sandbox: sandbox))
    }

    private struct Probe: Decodable { let v: Int }
    private struct Payload: Decodable {
        let v: Int
        let kid: String
        let email: String
        let type: String
        let seats: Int
        let iat: String
        let exp: String?
    }
}

/// Base64url without padding.
enum Base64URL {
    static func isAllowed(_ ch: Character) -> Bool {
        ch.isASCII && (ch.isLetter || ch.isNumber || ch == "-" || ch == "_")
    }

    static func decode(_ s: String) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard b.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "/") }) else { return nil }
        while b.count % 4 != 0 { b.append("=") }
        return Data(base64Encoded: b)
    }
}

/// ISO 8601 as the Worker writes it (`2026-11-18T21:08:01.000Z`); also without fractional seconds.
enum ISODate {
    static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

enum Ed25519 {
    /// Without CryptoKit (non-Apple platforms) verification fails; another platform needs swift-crypto.
    static func verify(signature: Data, message: Data, publicKey: Data) -> Bool {
        #if canImport(CryptoKit)
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
        return key.isValidSignature(signature, for: message)
        #else
        return false
        #endif
    }
}
