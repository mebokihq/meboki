import Foundation

/// The signed list of refunded or cancelled key IDs (PLAN.md §6 "Licence delivery" item 7).
/// Body: `{"payload": base64url(JSON {v, issued, kids}), "sig": base64url(Ed25519 over the payload bytes)}`.
public struct RevokedList: Sendable, Equatable {
    public let issued: Date
    public let kids: Set<String>
    /// The body as downloaded, to store and parse again at launch.
    public let raw: Data

    public init(issued: Date, kids: Set<String>, raw: Data) {
        self.issued = issued
        self.kids = kids
        self.raw = raw
    }

    public func contains(_ kid: String) -> Bool { kids.contains(kid) }

    /// Verifies `body` with the production key and, when `sandboxAllowed`, the test-payment key (the list the site
    /// serves while it takes test payments).
    public static func parse(_ body: Data, sandboxAllowed: Bool = LicenceKey.acceptsSandboxKeys) -> RevokedList? {
        if let list = parse(body, publicKey: LicenceKey.productionPublicKey) { return list }
        return sandboxAllowed ? parse(body, publicKey: LicenceKey.sandboxPublicKey) : nil
    }

    /// Verifies `body` with `publicKey` (raw 32 bytes). Nil when the body, the signature or the payload is bad,
    /// or the version is above 1.
    public static func parse(_ body: Data, publicKey: Data) -> RevokedList? {
        guard let env = try? JSONDecoder().decode(Envelope.self, from: body),
              let payload = Base64URL.decode(env.payload), let sig = Base64URL.decode(env.sig),
              Ed25519.verify(signature: sig, message: payload, publicKey: publicKey),
              let p = try? JSONDecoder().decode(Payload.self, from: payload),
              p.v == 1, let issued = ISODate.parse(p.issued) else { return nil }
        return RevokedList(issued: issued, kids: Set(p.kids), raw: body)
    }

    /// Keeps the newest list: a nil or older `candidate` never replaces `current`.
    public static func newer(current: RevokedList?, candidate: RevokedList?) -> RevokedList? {
        guard let candidate else { return current }
        guard let current else { return candidate }
        return candidate.issued > current.issued ? candidate : current
    }

    private struct Envelope: Decodable { let payload: String; let sig: String }
    private struct Payload: Decodable { let v: Int; let issued: String; let kids: [String] }
}
