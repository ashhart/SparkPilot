import CryptoKit
import Foundation

/// Require first-sighting host-key confirmation and reject changed recorded keys until explicit trust removal (§11.4).
public struct SSHHostKeyFingerprint: Sendable, Equatable, Hashable {
    /// The key type as SSH names it, for example `ssh-ed25519`.
    public let keyType: String
    /// Encode SHA-256 of the raw SSH public-key blob as unpadded base64, matching ssh-keygen.
    public let value: String

    public init(keyType: String, value: String) {
        self.keyType = keyType
        self.value = value
    }

    /// Compute the fingerprint of an SSH public key blob.
    public init(keyType: String, publicKeyBlob: Data) {
        self.keyType = keyType
        self.value = Data(SHA256.hash(data: publicKeyBlob)).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
    }

    /// Show the OpenSSH-compatible fingerprint the owner can compare with the Spark.
    public var displayString: String { "SHA256:\(value)" }
}

/// Where confirmed host keys are remembered between launches.
public protocol HostKeyStore: Sendable {
    func fingerprint(forHost host: String) throws -> SSHHostKeyFingerprint?
    func remember(_ fingerprint: SSHHostKeyFingerprint, forHost host: String) throws
    func forget(host: String) throws
}

/// How the owner is asked to confirm a first sighting.
public protocol HostKeyConfirming: Sendable {
    /// Return true only if a person looked at the fingerprint and accepted it.
    func confirmFirstUse(host: String, fingerprint: SSHHostKeyFingerprint) async -> Bool
}

public enum HostKeyDecision: Sendable, Equatable {
    /// Already known and unchanged.
    case known
    /// New, and the owner accepted it.
    case confirmed
}

public enum HostKeyError: Error, Equatable, Sendable {
    /// Reject changed recorded host keys without an in-place confirmation override.
    case changed(host: String, expected: SSHHostKeyFingerprint, presented: SSHHostKeyFingerprint)
    /// The owner declined, or was never asked.
    case declined(host: String, fingerprint: SSHHostKeyFingerprint)
    case storeUnavailable(String)
}

/// Applies first-use confirmation and rejects changed host keys.
public struct HostKeyPolicy: Sendable {
    private let store: any HostKeyStore
    private let confirmer: any HostKeyConfirming

    public init(store: any HostKeyStore, confirmer: any HostKeyConfirming) {
        self.store = store
        self.confirmer = confirmer
    }

    public func decide(
        host: String,
        presented: SSHHostKeyFingerprint
    ) async throws -> HostKeyDecision {
        let recorded: SSHHostKeyFingerprint?
        do {
            recorded = try store.fingerprint(forHost: host)
        } catch {
            throw HostKeyError.storeUnavailable("\(error)")
        }

        if let recorded {
            guard recorded == presented else {
                throw HostKeyError.changed(host: host, expected: recorded, presented: presented)
            }
            return .known
        }

        guard await confirmer.confirmFirstUse(host: host, fingerprint: presented) else {
            throw HostKeyError.declined(host: host, fingerprint: presented)
        }
        do {
            try store.remember(presented, forHost: host)
        } catch {
            throw HostKeyError.storeUnavailable("\(error)")
        }
        return .confirmed
    }
}

/// A keychain-free store for tests and previews.
public final class InMemoryHostKeyStore: HostKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: SSHHostKeyFingerprint] = [:]

    public init(entries: [String: SSHHostKeyFingerprint] = [:]) {
        self.entries = entries
    }

    public func fingerprint(forHost host: String) throws -> SSHHostKeyFingerprint? {
        lock.lock()
        defer { lock.unlock() }
        return entries[host]
    }

    public func remember(_ fingerprint: SSHHostKeyFingerprint, forHost host: String) throws {
        lock.lock()
        defer { lock.unlock() }
        entries[host] = fingerprint
    }

    public func forget(host: String) throws {
        lock.lock()
        defer { lock.unlock() }
        entries.removeValue(forKey: host)
    }
}
