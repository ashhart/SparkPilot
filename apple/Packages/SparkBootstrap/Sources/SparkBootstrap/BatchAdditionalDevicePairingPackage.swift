import CryptoKit
import Foundation
import SparkSecurity

/// Bind every batch claim to the owner-approved local device ID and public-key fingerprint without copying private keys.
public struct BatchPairingParticipantIdentity: Codable, Equatable, Sendable {
    public let deviceID: UUID
    public let displayName: String
    public let platform: String
    public let publicKeyFingerprint: String

    public init(
        deviceID: UUID,
        displayName: String,
        platform: String,
        publicKeyFingerprint: String
    ) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.platform = platform
        self.publicKeyFingerprint = publicKeyFingerprint
    }

    public init(
        deviceID: UUID,
        displayName: String,
        platform: String,
        publicKeySPKI: Data
    ) throws {
        let key: P256.Signing.PublicKey
        do {
            key = try P256.Signing.PublicKey(derRepresentation: publicKeySPKI)
        } catch {
            throw BatchAdditionalDevicePairingPackageError.invalidParticipantIdentity
        }
        self.init(
            deviceID: deviceID,
            displayName: displayName,
            platform: platform,
            publicKeyFingerprint: SHA256.hash(data: key.x963Representation)
                .map { String(format: "%02x", $0) }
                .joined()
        )
    }

    fileprivate func validate() throws {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...120).contains(name.count), ["ios", "ipados", "macos"].contains(platform),
            BatchPairingPayloadCodec.isLowercaseHexDigest(publicKeyFingerprint)
        else {
            throw BatchAdditionalDevicePairingPackageError.invalidParticipantIdentity
        }
    }

    private enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case displayName = "display_name"
        case platform
        case publicKeyFingerprint = "public_key_fingerprint"
    }
}

/// Share only a short-lived public recipient identity that expires before the returned invitation batch.
public struct BatchPairingRecipientRequest: Codable, Equatable, Sendable {
    public static let route = "pair-batch-request/"
    public static let schemePrefix = PairingLinkScheme.mint(route)
    public static let currentVersion = 1
    public static let lifetime: TimeInterval = 600

    public let version: Int
    public let requestID: UUID
    public let recipient: BatchPairingParticipantIdentity
    public let createdAt: Date
    public let expiresAt: Date

    public init(
        requestID: UUID = UUID(),
        recipient: BatchPairingParticipantIdentity,
        createdAt: Date = Date(),
        expiresAt: Date? = nil
    ) {
        version = Self.currentVersion
        self.requestID = requestID
        self.recipient = recipient
        self.createdAt = createdAt
        self.expiresAt = expiresAt ?? createdAt.addingTimeInterval(Self.lifetime)
    }

    public init(payload: String, now: Date = Date()) throws {
        self = try BatchPairingPayloadCodec.decode(
            payload,
            route: Self.route,
            as: Self.self
        )
        try validate(now: now)
    }

    public func payload(now: Date = Date()) throws -> String {
        try validate(now: now)
        return try BatchPairingPayloadCodec.encode(self, route: Self.route)
    }

    public func validate(now: Date = Date()) throws {
        guard version == Self.currentVersion else {
            throw BatchAdditionalDevicePairingPackageError.unsupportedVersion
        }
        try recipient.validate()
        guard createdAt <= expiresAt,
            expiresAt.timeIntervalSince(createdAt) <= Self.lifetime,
            now < expiresAt
        else {
            throw BatchAdditionalDevicePairingPackageError.expiredRecipientRequest
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case recipient
        case createdAt = "created_at"
        case expiresAt = "expires_at"
    }
}

/// One independently issued invitation inside a local batch handoff.
public struct BatchAdditionalDevicePairingTarget: Codable, Equatable, Sendable, Identifiable {
    public let nodeID: String
    public let issuerDeviceID: UUID
    public let package: AdditionalDevicePairingPackage

    public var id: String { nodeID.lowercased() }

    public init(
        nodeID: String,
        issuerDeviceID: UUID,
        package: AdditionalDevicePairingPackage
    ) {
        self.nodeID = nodeID
        self.issuerDeviceID = issuerDeviceID
        self.package = package
    }

    private enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case issuerDeviceID = "issuer_device_id"
        case package
    }
}

/// Treat the bounded batch as independently signed per-Spark invitations rather than a cross-node transaction.
public struct BatchAdditionalDevicePairingPackage: Codable, Equatable, Sendable {
    public static let route = "pair-batch/"
    public static let schemePrefix = PairingLinkScheme.mint(route)
    public static let currentVersion = 1
    public static let minimumTargets = 2
    public static let maximumTargets = 16

    public let version: Int
    public let batchID: UUID
    public let issuer: BatchPairingParticipantIdentity
    public let recipient: BatchPairingParticipantIdentity
    public let role: String
    public let targets: [BatchAdditionalDevicePairingTarget]

    public init(
        batchID: UUID = UUID(),
        issuer: BatchPairingParticipantIdentity,
        recipient: BatchPairingParticipantIdentity,
        role: String,
        targets: [BatchAdditionalDevicePairingTarget]
    ) {
        version = Self.currentVersion
        self.batchID = batchID
        self.issuer = issuer
        self.recipient = recipient
        self.role = role
        self.targets = targets
    }

    public init(payload: String, now: Date = Date()) throws {
        self = try BatchPairingPayloadCodec.decode(
            payload,
            route: Self.route,
            as: Self.self
        )
        try validate(now: now, requireLiveInvitations: true)
    }

    public func payload(now: Date = Date()) throws -> String {
        try validate(now: now, requireLiveInvitations: true)
        return try BatchPairingPayloadCodec.encode(self, route: Self.route)
    }

    public func validate(
        now: Date = Date(),
        requireLiveInvitations: Bool = true
    ) throws {
        guard version == Self.currentVersion else {
            throw BatchAdditionalDevicePairingPackageError.unsupportedVersion
        }
        try issuer.validate()
        try recipient.validate()
        guard issuer.deviceID != recipient.deviceID,
            issuer.publicKeyFingerprint != recipient.publicKeyFingerprint
        else {
            throw BatchAdditionalDevicePairingPackageError.sameIssuerAndRecipient
        }
        guard role == "administrator" || role == "user" else {
            throw BatchAdditionalDevicePairingPackageError.invalidRole
        }
        guard (Self.minimumTargets...Self.maximumTargets).contains(targets.count) else {
            throw BatchAdditionalDevicePairingPackageError.invalidTargetCount
        }

        var nodeIDs = Set<String>()
        var invitationIDs = Set<String>()
        for target in targets {
            let nodeID = target.nodeID.lowercased()
            guard UUID(uuidString: nodeID) != nil,
                target.package.invitation.nodeID.lowercased() == nodeID
            else {
                throw BatchAdditionalDevicePairingPackageError.targetIdentityMismatch
            }
            guard target.issuerDeviceID == issuer.deviceID else {
                throw BatchAdditionalDevicePairingPackageError.mixedIssuers
            }
            guard
                target.package.invitation.issuedByDeviceID?.lowercased()
                    == issuer.deviceID.uuidString.lowercased()
            else {
                throw BatchAdditionalDevicePairingPackageError.mixedIssuers
            }
            guard
                target.package.invitation.recipientDeviceID?.lowercased()
                    == recipient.deviceID.uuidString.lowercased(),
                target.package.invitation.recipientPublicKeyFingerprint
                    == recipient.publicKeyFingerprint
            else {
                throw BatchAdditionalDevicePairingPackageError.mixedRecipients
            }
            guard target.package.invitation.role == role else {
                throw BatchAdditionalDevicePairingPackageError.mixedRoles
            }
            _ = try target.package.bootstrapResult()
            try target.package.verifyInvitationSignature()
            if requireLiveInvitations, !target.package.isLocallyPlausible(now: now) {
                throw BatchAdditionalDevicePairingPackageError.expiredInvitation(nodeID: nodeID)
            }
            guard nodeIDs.insert(nodeID).inserted else {
                throw BatchAdditionalDevicePairingPackageError.duplicateNode(nodeID)
            }
            let invitationID = target.package.invitation.invitationID.lowercased()
            guard invitationIDs.insert(invitationID).inserted else {
                throw BatchAdditionalDevicePairingPackageError.duplicateInvitation(invitationID)
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case batchID = "batch_id"
        case issuer, recipient, role, targets
    }
}

public enum BatchPairingTargetPhase: String, Codable, Equatable, Sendable {
    case pending
    case pairing
    case paired
    case failed
    case revoking
    case revoked
    case revocationFailed = "revocation_failed"
}

/// Durable, per-Spark progress for a batch received by this Apple device.
public struct BatchPairingTargetProgress: Codable, Equatable, Sendable, Identifiable {
    public let target: BatchAdditionalDevicePairingTarget
    public var phase: BatchPairingTargetPhase
    public var lastError: String?
    public var updatedAt: Date

    public var id: String { target.id }

    public init(
        target: BatchAdditionalDevicePairingTarget,
        phase: BatchPairingTargetPhase = .pending,
        lastError: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.target = target
        self.phase = phase
        self.lastError = lastError
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case target, phase
        case lastError = "last_error"
        case updatedAt = "updated_at"
    }
}

public struct BatchPairingProgress: Codable, Equatable, Sendable, Identifiable {
    public static let currentVersion = 1

    public let version: Int
    public let batchID: UUID
    public let issuer: BatchPairingParticipantIdentity
    public let recipient: BatchPairingParticipantIdentity
    public let role: String
    public var targets: [BatchPairingTargetProgress]
    public let createdAt: Date
    public var updatedAt: Date

    public var id: UUID { batchID }

    public init(package: BatchAdditionalDevicePairingPackage, now: Date = Date()) {
        version = Self.currentVersion
        batchID = package.batchID
        issuer = package.issuer
        recipient = package.recipient
        role = package.role
        targets = package.targets.map { BatchPairingTargetProgress(target: $0, updatedAt: now) }
        createdAt = now
        updatedAt = now
    }

    public var pairedCount: Int { targets.count { $0.phase == .paired } }
    public var failedCount: Int {
        targets.count { $0.phase == .failed || $0.phase == .revocationFailed }
    }
    public var isComplete: Bool {
        targets.allSatisfy { $0.phase == .paired || $0.phase == .revoked }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case batchID = "batch_id"
        case issuer, recipient, role, targets
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

public protocol BatchPairingProgressStoring: Sendable {
    func load(batchID: UUID) throws -> BatchPairingProgress?
    func save(_ progress: BatchPairingProgress) throws
    func remove(batchID: UUID) throws
    func all() throws -> [BatchPairingProgress]
}

/// Store invitation-bearing progress only in this-device Keychain storage.
public struct SecureBatchPairingProgressStore: BatchPairingProgressStoring {
    public static let service = "com.sparkpilot.batch-pairing-progress"

    private let store: any SecureStore
    private let service: String

    public init(
        store: any SecureStore = KeychainStore(),
        service: String = Self.service
    ) {
        self.store = store
        self.service = service
    }

    public func load(batchID: UUID) throws -> BatchPairingProgress? {
        guard let data = try store.data(service: service, account: account(batchID)) else {
            return nil
        }
        let progress = try JSONDecoder().decode(BatchPairingProgress.self, from: data)
        guard progress.version == BatchPairingProgress.currentVersion,
            progress.batchID == batchID
        else {
            throw BatchAdditionalDevicePairingPackageError.corruptProgress
        }
        return progress
    }

    public func save(_ progress: BatchPairingProgress) throws {
        guard progress.version == BatchPairingProgress.currentVersion else {
            throw BatchAdditionalDevicePairingPackageError.corruptProgress
        }
        try store.set(
            try JSONEncoder().encode(progress),
            service: service,
            account: account(progress.batchID)
        )
    }

    public func remove(batchID: UUID) throws {
        try store.delete(service: service, account: account(batchID))
    }

    public func all() throws -> [BatchPairingProgress] {
        try store.accounts(service: service).map { value in
            guard let id = UUID(uuidString: value), let record = try load(batchID: id) else {
                throw BatchAdditionalDevicePairingPackageError.corruptProgress
            }
            return record
        }
    }

    private func account(_ batchID: UUID) -> String { batchID.uuidString.lowercased() }
}

public enum BatchAdditionalDevicePairingPackageError: Error, Equatable, Sendable {
    case notABatchPayload
    case malformedEncoding
    case malformedPackage
    case payloadTooLarge
    case unsupportedVersion
    case invalidParticipantIdentity
    case expiredRecipientRequest
    case sameIssuerAndRecipient
    case invalidRole
    case invalidTargetCount
    case targetIdentityMismatch
    case mixedIssuers
    case mixedRecipients
    case mixedRoles
    case expiredInvitation(nodeID: String)
    case duplicateNode(String)
    case duplicateInvitation(String)
    case corruptProgress
}

private enum BatchPairingPayloadCodec {
    static let maximumEncodedBytes = 256 * 1_024

    static func encode<T: Encodable>(_ value: T, route: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= maximumEncodedBytes else {
            throw BatchAdditionalDevicePairingPackageError.payloadTooLarge
        }
        return PairingLinkScheme.mint(route) + base64URLEncode(data)
    }

    static func decode<T: Decodable>(_ payload: String, route: String, as: T.Type) throws -> T {
        guard let encoded = PairingLinkScheme.body(of: payload, route: route) else {
            throw BatchAdditionalDevicePairingPackageError.notABatchPayload
        }
        guard encoded.utf8.count <= maximumEncodedBytes * 2,
            let data = base64URLDecode(encoded)
        else {
            throw BatchAdditionalDevicePairingPackageError.malformedEncoding
        }
        guard data.count <= maximumEncodedBytes else {
            throw BatchAdditionalDevicePairingPackageError.payloadTooLarge
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw BatchAdditionalDevicePairingPackageError.malformedPackage
        }
    }

    static func isLowercaseHexDigest(_ value: String) -> Bool {
        value.count == 64
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ value: String) -> Data? {
        var base64 =
            value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }
}
