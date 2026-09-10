import Foundation
import SparkSecurity

/// Persist confirmed SSH trust in Keychain because it governs where administrator credentials may be sent.
public struct KeychainHostKeyStore: HostKeyStore {
    /// Use a host-key service namespace distinct from device keys and node trust.
    public static let service = "app.spark.ssh-host-keys"

    private let store: any SecureStore

    public init(store: any SecureStore = KeychainStore()) {
        self.store = store
    }

    public func fingerprint(forHost host: String) throws -> SSHHostKeyFingerprint? {
        guard let data = try store.data(service: Self.service, account: normalise(host)) else {
            return nil
        }
        return try JSONDecoder().decode(StoredFingerprint.self, from: data).asFingerprint
    }

    public func remember(_ fingerprint: SSHHostKeyFingerprint, forHost host: String) throws {
        let data = try JSONEncoder().encode(StoredFingerprint(fingerprint))
        try store.set(data, service: Self.service, account: normalise(host))
    }

    public func forget(host: String) throws {
        try store.delete(service: Self.service, account: normalise(host))
    }

    /// Normalize case-insensitive hostnames so one Spark cannot acquire conflicting host-key records.
    private func normalise(_ host: String) -> String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private struct StoredFingerprint: Codable {
        let keyType: String
        let value: String

        init(_ fingerprint: SSHHostKeyFingerprint) {
            self.keyType = fingerprint.keyType
            self.value = fingerprint.value
        }

        var asFingerprint: SSHHostKeyFingerprint {
            SSHHostKeyFingerprint(keyType: keyType, value: value)
        }
    }
}
