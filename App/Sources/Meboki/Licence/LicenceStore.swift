import Foundation
import MebokiCore

/// The licence key and the revoked list as plain files next to the models (PLAN.md §6 "App-side licensing").
/// The key is signed, not secret, so a file survives a reinstall and can be copied to another Mac by hand.
struct LicenceStore {
    let directory: URL

    static let standard: LicenceStore = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return LicenceStore(directory: base.appendingPathComponent("Meboki", isDirectory: true))
    }()

    private var keyURL: URL { directory.appendingPathComponent("licence.key") }
    private var revokedURL: URL { directory.appendingPathComponent("revoked.json") }

    /// The stored key text, nil when there is none.
    func loadKey() -> String? {
        guard let data = try? Data(contentsOf: keyURL) else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Writes the key with mode 0600. Returns an error message, or nil.
    func saveKey(_ key: String) -> String? { write(Data(key.utf8), to: keyURL) }

    func removeKey() { try? FileManager.default.removeItem(at: keyURL) }

    /// The stored revoked list, parsed and verified again (a file that no longer verifies is ignored).
    func loadRevoked() -> RevokedList? {
        guard let data = try? Data(contentsOf: revokedURL) else { return nil }
        return RevokedList.parse(data)
    }

    /// Stores the verified body as downloaded.
    func saveRevoked(_ body: Data) { _ = write(body, to: revokedURL) }

    func removeRevoked() { try? FileManager.default.removeItem(at: revokedURL) }

    private func write(_ data: Data, to url: URL) -> String? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
