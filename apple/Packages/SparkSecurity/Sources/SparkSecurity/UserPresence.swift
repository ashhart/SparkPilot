import CryptoKit
import Foundation

/// How the separate user-presence key is protected on this Apple device.
public enum UserPresenceKeyProtection: String, Codable, Sendable, Equatable {
    case secureEnclaveUserPresence = "secure_enclave_user_presence"
    case keychainUserPresence = "keychain_user_presence"
    case softwareTestOnly = "software_test_only"

    public var isHardwareBacked: Bool {
        self == .secureEnclaveUserPresence
    }
}

public struct UserPresenceKeyInfo: Sendable, Equatable {
    public let publicKeySPKI: Data
    public let protection: UserPresenceKeyProtection

    public init(publicKeySPKI: Data, protection: UserPresenceKeyProtection) {
        self.publicKeySPKI = publicKeySPKI
        self.protection = protection
    }

    public var isHardwareBacked: Bool { protection.isHardwareBacked }
    public var publicKeySPKIBase64: String { publicKeySPKI.base64EncodedString() }

    /// Derive presence-key identity from the canonical parsed P-256 point rather than caller-controlled DER.
    public func pairingFingerprint() throws -> String {
        let key: P256.Signing.PublicKey
        do {
            key = try P256.Signing.PublicKey(derRepresentation: publicKeySPKI)
        } catch {
            throw UserPresenceProofError.invalidPublicKey
        }
        let point = key.x963Representation
        guard point.count == 65, point.first == 0x04 else {
            throw UserPresenceProofError.invalidPublicKey
        }
        return SHA256.hash(data: point).map { String(format: "%02x", $0) }.joined()
    }
}

/// The one-use authorization returned after local user-presence succeeds.
public protocol UserPresenceProofSigning: Sendable {
    var keyInfo: UserPresenceKeyInfo { get }
    func proof(for request: UserPresenceCanonicalRequest) async throws -> UserPresenceProof
    /// Sign the one pairing-registration binding authorized by this session.
    func signPairingBinding(_ binding: PairingPresenceBinding) async throws -> Data
    /// Sign the authenticated set-once enrollment request for an older grant.
    func signPresenceKeyEnrollment(
        _ binding: PresenceKeyEnrollmentBinding
    ) async throws -> Data
}

extension UserPresenceProofSigning {
    public func signPairingBinding(_ binding: PairingPresenceBinding) async throws -> Data {
        throw UserPresenceProofError.signingFailed
    }

    public func signPresenceKeyEnrollment(
        _ binding: PresenceKeyEnrollmentBinding
    ) async throws -> Data {
        throw UserPresenceProofError.signingFailed
    }
}

/// Starts the Apple-owned Face ID, Touch ID, or device-passcode interaction.
public protocol UserPresenceAuthorizing: Sendable {
    func keyInfo() async throws -> UserPresenceKeyInfo
    func authorize(localizedReason: String) async throws -> any UserPresenceProofSigning
}

/// Bind presence-key registration to the exact UTF-8 message signed by both device and presence keys.
public struct PairingPresenceBinding: Sendable, Equatable {
    public let challengeBase64URL: String
    public let invitationID: UUID
    public let deviceID: UUID
    public let nodeID: UUID
    public let presenceKeyFingerprint: String

    public init(
        challengeBase64URL: String,
        invitationID: UUID,
        deviceID: UUID,
        nodeID: UUID,
        presenceKeyFingerprint: String
    ) throws {
        guard !challengeBase64URL.isEmpty,
            !challengeBase64URL.contains("="),
            Base64URL.decode(challengeBase64URL).map(Base64URL.encode) == challengeBase64URL,
            presenceKeyFingerprint.count == 64,
            presenceKeyFingerprint.utf8.allSatisfy({
                (48...57).contains($0) || (97...102).contains($0)
            })
        else {
            throw UserPresenceProofError.invalidPairingBinding
        }
        self.challengeBase64URL = challengeBase64URL
        self.invitationID = invitationID
        self.deviceID = deviceID
        self.nodeID = nodeID
        self.presenceKeyFingerprint = presenceKeyFingerprint
    }

    public var signatureInput: Data {
        Data(
            [
                "SPARK-PAIRING-PRESENCE1",
                challengeBase64URL,
                invitationID.uuidString.lowercased(),
                deviceID.uuidString.lowercased(),
                nodeID.uuidString.lowercased(),
                presenceKeyFingerprint,
            ]
            .joined(separator: "\n").utf8
        )
    }
}

/// Carry compatibility registration proof in a header so both signatures bind the final body digest without a signature cycle.
public struct PresenceKeyEnrollmentBinding: Sendable, Equatable {
    public let method: String
    public let pathAndQuery: String
    public let timestamp: String
    public let nonce: String
    public let contentSHA256: String
    public let nodeID: UUID
    public let deviceID: UUID
    public let presenceKeyFingerprint: String

    public init(
        method: String,
        pathAndQuery: String,
        timestamp: String,
        nonce: String,
        contentSHA256: String,
        deviceID: UUID,
        presenceKeyFingerprint: String,
        nodeID: UUID
    ) throws {
        guard !method.isEmpty,
            !pathAndQuery.isEmpty,
            ISO8601DateFormatter().date(from: timestamp) != nil,
            !nonce.isEmpty,
            contentSHA256.count == 64,
            contentSHA256.utf8.allSatisfy({
                (48...57).contains($0) || (97...102).contains($0)
            }),
            presenceKeyFingerprint.count == 64,
            presenceKeyFingerprint.utf8.allSatisfy({
                (48...57).contains($0) || (97...102).contains($0)
            })
        else {
            throw UserPresenceProofError.invalidPairingBinding
        }
        self.method = method
        self.pathAndQuery = pathAndQuery
        self.timestamp = timestamp
        self.nonce = nonce
        self.contentSHA256 = contentSHA256
        self.nodeID = nodeID
        self.deviceID = deviceID
        self.presenceKeyFingerprint = presenceKeyFingerprint
    }

    public var signatureInput: Data {
        Data(
            [
                "SPARK-PRESENCE-ENROLL2",
                method.uppercased(),
                pathAndQuery,
                timestamp,
                nonce,
                contentSHA256,
                deviceID.uuidString.lowercased(),
                presenceKeyFingerprint,
                nodeID.uuidString.lowercased(),
            ]
            .joined(separator: "\n").utf8
        )
    }
}

/// Repeat every SPARK2 replay field in presence-proof bytes to bind approval to one request.
public struct UserPresenceCanonicalRequest: Sendable, Equatable {
    public let method: String
    public let pathAndQuery: String
    public let timestamp: String
    public let nonce: String
    public let bodyHashHex: String
    public let deviceID: String
    public let nodeID: UUID
    public let expiresAt: String

    public init(
        method: String,
        pathAndQuery: String,
        timestamp: String,
        nonce: String,
        bodyHashHex: String,
        deviceID: String,
        expiresAt: String,
        nodeID: UUID
    ) throws {
        guard let issued = Self.parse(timestamp),
            let expiry = Self.parse(expiresAt),
            expiry.timeIntervalSince(issued) > 0,
            expiry.timeIntervalSince(issued) <= 60
        else {
            throw UserPresenceProofError.invalidExpiry
        }
        self.method = method
        self.pathAndQuery = pathAndQuery
        self.timestamp = timestamp
        self.nonce = nonce
        self.bodyHashHex = bodyHashHex
        self.deviceID = deviceID
        self.nodeID = nodeID
        self.expiresAt = expiresAt
    }

    public var signatureInput: Data {
        Data(
            [
                "SPARK-PRESENCE2",
                method.uppercased(),
                pathAndQuery,
                timestamp,
                nonce,
                bodyHashHex,
                deviceID,
                expiresAt,
                nodeID.uuidString.lowercased(),
            ]
            .joined(separator: "\n").utf8
        )
    }

    private static func parse(_ value: String) -> Date? {
        ISO8601DateFormatter().date(from: value)
    }
}

/// Version 2 wire value for `X-Spark-User-Presence`.
public struct UserPresenceProof: Codable, Sendable, Equatable {
    public let version: Int
    public let expiresAt: String
    public let signature: String

    public init(version: Int = 2, expiresAt: String, signature: String) throws {
        guard version == 2 else { throw UserPresenceProofError.unsupportedVersion }
        guard ISO8601DateFormatter().date(from: expiresAt) != nil else {
            throw UserPresenceProofError.invalidExpiry
        }
        guard Base64URL.decode(signature)?.count == 64 else {
            throw UserPresenceProofError.invalidSignature
        }
        self.version = version
        self.expiresAt = expiresAt
        self.signature = signature
    }

    public static func sign(
        _ request: UserPresenceCanonicalRequest,
        signingKey: (Data) throws -> Data
    ) throws -> UserPresenceProof {
        try UserPresenceProof(
            expiresAt: request.expiresAt,
            signature: Base64URL.encode(try signingKey(request.signatureInput))
        )
    }

    public init(headerValue: String) throws {
        guard let encoded = Base64URL.decode(headerValue),
            let decoded = try? JSONDecoder().decode(UserPresenceProof.self, from: encoded)
        else {
            throw UserPresenceProofError.invalidHeader
        }
        try self.init(
            version: decoded.version,
            expiresAt: decoded.expiresAt,
            signature: decoded.signature
        )
    }

    public func headerValue() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return Base64URL.encode(try encoder.encode(self))
    }

    enum CodingKeys: String, CodingKey {
        case version
        case expiresAt = "expires_at"
        case signature
    }
}

public enum UserPresenceProofError: Error, Sendable, Equatable {
    case invalidExpiry
    case invalidHeader
    case invalidSignature
    case invalidPublicKey
    case invalidPairingBinding
    case sessionConsumed
    case unsupportedVersion
    case signingFailed
}

public enum UserPresenceAuthorizationError: Error, Sendable, Equatable {
    case declined
    case unavailable
    case keyUnavailable
}

extension UserPresenceAuthorizationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .declined:
            String(localized: "User presence was cancelled.")
        case .unavailable:
            String(localized: "Face ID, Touch ID, or a device passcode is not available.")
        case .keyUnavailable:
            String(localized: "The user-presence signing key is unavailable.")
        }
    }
}
