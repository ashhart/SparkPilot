import CryptoKit
import Foundation

/// Persist separate certificate and authority-key trust learned through the verified pairing handoff.
public struct NodeTrust: Sendable, Equatable, Codable {
    /// Key node trust by the full UUID rather than Bonjour's short discovery hint.
    public let nodeID: String
    public let nodeName: String
    /// SHA-256 of the local API's leaf certificate, lowercase hex.
    public let tlsFingerprint: String
    /// SHA-256 of the Ed25519 owner-authority public key, lowercase hex.
    public let authorityFingerprint: String
    /// Retain the lowercase Ed25519 authority key so future invitations can be verified offline.
    public let authorityPublicKey: String
    /// When this device paired with the node.
    public let pairedAt: Date
    /// Recover missing legacy grant roles from the authenticated device list.
    public let localDeviceRole: String?

    public init(
        nodeID: String,
        nodeName: String,
        tlsFingerprint: String,
        authorityFingerprint: String,
        authorityPublicKey: String,
        pairedAt: Date,
        localDeviceRole: String? = nil
    ) {
        self.nodeID = nodeID
        self.nodeName = nodeName
        self.tlsFingerprint = tlsFingerprint
        self.authorityFingerprint = authorityFingerprint
        self.authorityPublicKey = authorityPublicKey
        self.pairedAt = pairedAt
        self.localDeviceRole = localDeviceRole
    }
}

public enum NodeTrustError: Error, Equatable, Sendable {
    /// Reject changed recorded certificates until the owner explicitly removes the trust record.
    case fingerprintChanged(nodeID: String, expected: String, presented: String)
    /// Reject changed pairing authorities independently of certificate continuity.
    case authorityChanged(nodeID: String, expected: String, presented: String)
    case malformedFingerprint(String)
    /// Reject ambiguous advertisements when multiple paired nodes share the short Bonjour hint.
    case ambiguousDiscoveryHint(hint: String, nodeIDs: [String])
    /// Reject a stored authority key that does not hash to its accompanying fingerprint.
    case authorityKeyDoesNotMatchFingerprint(
        nodeID: String,
        fingerprint: String,
        computed: String
    )
    /// Report corrupt stored trust rather than treating it as absent.
    case unreadableRecord(nodeID: String, detail: String)
    case storeUnavailable(String)
}

/// Protect integrity-critical node trust in Keychain under each full node identifier.
public struct NodeTrustStore: Sendable {
    /// Keep node-trust records separate from the device-key service namespace.
    public static let service = "app.spark.node-trust"
    /// Store pending pairing trust separately so it cannot be mistaken for an accepted grant.
    public static let stagingService = "app.spark.node-trust.staged"

    private let store: any SecureStore
    private let now: @Sendable () -> Date

    public init(
        store: any SecureStore = KeychainStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.now = now
    }

    public func trust(forNode nodeID: String) throws -> NodeTrust? {
        try decode(service: Self.service, account: nodeID)
    }

    /// Validate stored identity consistency on every read and fail closed on corruption.
    private func decode(service: String, account: String) throws -> NodeTrust? {
        let data: Data?
        do {
            data = try store.data(service: service, account: account)
        } catch {
            throw NodeTrustError.storeUnavailable("\(error)")
        }
        guard let data else { return nil }
        let node: NodeTrust
        do {
            node = try JSONDecoder().decode(NodeTrust.self, from: data)
        } catch {
            throw NodeTrustError.unreadableRecord(nodeID: account, detail: "\(error)")
        }
        try validate(node)
        return node
    }

    /// Record completed pairing without overwriting a different stored certificate pin.
    public func remember(_ node: NodeTrust) throws {
        try validate(node)

        if let existing = try trust(forNode: node.nodeID) {
            guard existing.tlsFingerprint == node.tlsFingerprint else {
                throw NodeTrustError.fingerprintChanged(
                    nodeID: node.nodeID,
                    expected: existing.tlsFingerprint,
                    presented: node.tlsFingerprint
                )
            }
            guard existing.authorityFingerprint == node.authorityFingerprint,
                existing.authorityPublicKey == node.authorityPublicKey
            else {
                throw NodeTrustError.authorityChanged(
                    nodeID: node.nodeID,
                    expected: existing.authorityFingerprint,
                    presented: node.authorityFingerprint
                )
            }
        }

        do {
            let data = try JSONEncoder().encode(node)
            try store.set(data, service: Self.service, account: node.nodeID)
        } catch {
            throw NodeTrustError.storeUnavailable("\(error)")
        }
    }

    /// Stage trust before the irreversible claim while keeping pending records invisible to ordinary paired-node lookups.
    public func stage(_ node: NodeTrust) throws {
        try validate(node)
        // A staged record must never overwrite a confirmed one.
        if let existing = try trust(forNode: node.nodeID) {
            guard existing.tlsFingerprint == node.tlsFingerprint else {
                throw NodeTrustError.fingerprintChanged(
                    nodeID: node.nodeID,
                    expected: existing.tlsFingerprint,
                    presented: node.tlsFingerprint
                )
            }
            guard existing.authorityFingerprint == node.authorityFingerprint else {
                throw NodeTrustError.authorityChanged(
                    nodeID: node.nodeID,
                    expected: existing.authorityFingerprint,
                    presented: node.authorityFingerprint
                )
            }
            return
        }
        do {
            let data = try JSONEncoder().encode(node)
            try store.set(data, service: Self.stagingService, account: node.nodeID)
        } catch {
            throw NodeTrustError.storeUnavailable("\(error)")
        }
    }

    /// Validate staged trust before returning material that can become an active pin.
    public func staged(forNode nodeID: String) throws -> NodeTrust? {
        try decode(service: Self.stagingService, account: nodeID)
    }

    /// Promote a staged record once the node has accepted the claim.
    @discardableResult
    public func commitStaged(nodeID: String) throws -> NodeTrust {
        guard let staged = try staged(forNode: nodeID) else {
            throw NodeTrustError.storeUnavailable("no staged trust for node \(nodeID)")
        }
        try remember(staged)
        // Do not fail an accepted pairing solely because redundant staging cleanup fails.
        try? store.delete(service: Self.stagingService, account: nodeID)
        return staged
    }

    /// Discard a staged record after a claim that did not happen.
    public func discardStaged(nodeID: String) throws {
        do {
            try store.delete(service: Self.stagingService, account: nodeID)
        } catch {
            throw NodeTrustError.storeUnavailable("\(error)")
        }
    }

    /// Forget a node. The deliberate act that a changed identity requires.
    public func forget(nodeID: String) throws {
        do {
            try store.delete(service: Self.service, account: nodeID)
            try store.delete(service: Self.stagingService, account: nodeID)
        } catch {
            throw NodeTrustError.storeUnavailable("\(error)")
        }
    }

    /// The pin to give a session for this node, if there is one.
    public func pin(forNode nodeID: String) throws -> String? {
        guard let node = try trust(forNode: nodeID) else { return nil }
        return node.tlsFingerprint
    }

    /// Fail enumeration on any corrupt trust record so discovery ambiguity cannot disappear silently.
    public func pairedNodes() throws -> [NodeTrust] {
        let accounts: [String]
        do {
            accounts = try store.accounts(service: Self.service)
        } catch {
            throw NodeTrustError.storeUnavailable("\(error)")
        }
        return try accounts.compactMap { try decode(service: Self.service, account: $0) }
    }

    /// Resolve an unauthenticated Bonjour prefix only when exactly one paired full node ID matches.
    public func trust(matchingDiscoveryHint hint: String) throws -> NodeTrust? {
        let needle = hint.lowercased()
        guard !needle.isEmpty else { return nil }
        let matches = try pairedNodes().filter { $0.nodeID.lowercased().hasPrefix(needle) }
        switch matches.count {
        case 0: return nil
        case 1: return matches[0]
        default:
            throw NodeTrustError.ambiguousDiscoveryHint(
                hint: hint,
                nodeIDs: matches.map(\.nodeID).sorted()
            )
        }
    }

    private func validate(_ node: NodeTrust) throws {
        guard isFingerprint(node.tlsFingerprint) else {
            throw NodeTrustError.malformedFingerprint(node.tlsFingerprint)
        }
        guard isFingerprint(node.authorityFingerprint) else {
            throw NodeTrustError.malformedFingerprint(node.authorityFingerprint)
        }
        // Reject reused authority and TLS fingerprints because the fields represent different key material.
        guard node.tlsFingerprint != node.authorityFingerprint else {
            throw NodeTrustError.malformedFingerprint(
                "the TLS and authority fingerprints are the same value"
            )
        }
        guard isFingerprint(node.authorityPublicKey) else {
            throw NodeTrustError.malformedFingerprint(node.authorityPublicKey)
        }

        // Verify the stored authority key hashes to its fingerprint before allowing future invitation verification.
        guard let keyBytes = Data(hexString: node.authorityPublicKey) else {
            throw NodeTrustError.malformedFingerprint(node.authorityPublicKey)
        }
        let computed = SHA256.hash(data: keyBytes)
            .map { String(format: "%02x", $0) }
            .joined()
        guard computed == node.authorityFingerprint.lowercased() else {
            throw NodeTrustError.authorityKeyDoesNotMatchFingerprint(
                nodeID: node.nodeID,
                fingerprint: node.authorityFingerprint,
                computed: computed
            )
        }
    }

    private func isFingerprint(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isNumber || ("a"..."f").contains($0) }
    }
}

extension Data {
    /// Bytes from lowercase or uppercase hex, or nil if it is not hex.
    init?(hexString: String) {
        let characters = Array(hexString)
        guard characters.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(characters.count / 2)
        var index = 0
        while index < characters.count {
            guard let byte = UInt8(String(characters[index...(index + 1)]), radix: 16) else {
                return nil
            }
            bytes.append(byte)
            index += 2
        }
        self.init(bytes)
    }
}
