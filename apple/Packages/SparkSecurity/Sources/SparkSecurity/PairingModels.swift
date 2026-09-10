import Foundation

// Keep challenge and claim public-narrow while the claim proves possession of the registering device key (§15.3–15.4).

public struct PairingInvitation: Codable, Sendable, Equatable {
    public var version: Int
    public var nodeID: String
    public var authorityFingerprint: String
    public var invitationID: String
    public var nonce: String
    public var issuedByDeviceID: String?
    public var recipientDeviceID: String?
    public var recipientPublicKeyFingerprint: String?
    public var role: String
    public var expiresAt: String
    public var signature: String?
    public var clusterID: String?
    public var localEndpoint: String?
    public var remoteEndpoint: String?
    public var joinCode: String?
    /// Version 2. The Spark's own name, signed, so a link cannot claim to be a different Spark.
    public var nodeName: String?
    /// Version 2. The TLS leaf pin the joining device must see.
    public var tlsFingerprint: String?
    /// Version 2. The Spark's MagicDNS name, present only when the owner has remote access on.
    public var remoteHostname: String?
    /// Version 2. The guest limits this invitation grants.
    public var sharedAccess: SharedAccessSummary?

    public init(
        version: Int,
        nodeID: String,
        authorityFingerprint: String,
        invitationID: String,
        nonce: String,
        issuedByDeviceID: String? = nil,
        recipientDeviceID: String? = nil,
        recipientPublicKeyFingerprint: String? = nil,
        role: String,
        expiresAt: String,
        signature: String? = nil,
        clusterID: String? = nil,
        localEndpoint: String? = nil,
        remoteEndpoint: String? = nil,
        joinCode: String? = nil,
        nodeName: String? = nil,
        tlsFingerprint: String? = nil,
        remoteHostname: String? = nil,
        sharedAccess: SharedAccessSummary? = nil
    ) {
        self.version = version
        self.nodeID = nodeID
        self.authorityFingerprint = authorityFingerprint
        self.invitationID = invitationID
        self.nonce = nonce
        self.issuedByDeviceID = issuedByDeviceID
        self.recipientDeviceID = recipientDeviceID
        self.recipientPublicKeyFingerprint = recipientPublicKeyFingerprint
        self.role = role
        self.expiresAt = expiresAt
        self.signature = signature
        self.clusterID = clusterID
        self.localEndpoint = localEndpoint
        self.remoteEndpoint = remoteEndpoint
        self.joinCode = joinCode
        self.nodeName = nodeName
        self.tlsFingerprint = tlsFingerprint
        self.remoteHostname = remoteHostname
        self.sharedAccess = sharedAccess
    }

    /// Version 2 invitations carry the routes, the pin and the guest limits; version 1 payloads stay valid.
    public static let supportedVersions: Set<Int> = [1, 2]

    /// Whether this invitation is a shared-access invitation for a friend's device.
    public var isSharedAccess: Bool { role == "guest" }

    enum CodingKeys: String, CodingKey {
        case version
        case nodeID = "node_id"
        case clusterID = "cluster_id"
        case localEndpoint = "local_endpoint"
        case remoteEndpoint = "remote_endpoint"
        case authorityFingerprint = "authority_fingerprint"
        case invitationID = "invitation_id"
        case nonce
        case issuedByDeviceID = "issued_by_device_id"
        case recipientDeviceID = "recipient_device_id"
        case recipientPublicKeyFingerprint = "recipient_public_key_fingerprint"
        case role
        case expiresAt = "expires_at"
        case signature
        case joinCode = "join_code"
        case nodeName = "node_name"
        case tlsFingerprint = "tls_fingerprint"
        case remoteHostname = "remote_hostname"
        case sharedAccess = "shared_access"
    }
}

public struct PairingChallengeResponse: Codable, Sendable {
    public let challengeID: String
    public let challenge: String  // base64url
    public let expiresAt: String
    public let authorityFingerprint: String
    public let signature: String

    enum CodingKeys: String, CodingKey {
        case challengeID = "challenge_id"
        case challenge
        case expiresAt = "expires_at"
        case authorityFingerprint = "authority_fingerprint"
        case signature
    }
}

public struct PairingClaimRequest: Encodable, Sendable {
    public let invitation: PairingInvitation
    public let challengeID: String
    public let deviceID: String
    public let deviceName: String
    public let platform: String
    public let devicePublicKeySPKI: String  // standard base64
    public let presencePublicKeySPKI: String?  // standard base64, separate key
    public let challengeSignature: String  // base64url r||s
    public let presenceKeySignature: String?  // base64url r||s

    public init(
        invitation: PairingInvitation,
        challengeID: String,
        deviceID: String,
        deviceName: String,
        platform: String,
        devicePublicKeySPKI: String,
        presencePublicKeySPKI: String? = nil,
        challengeSignature: String,
        presenceKeySignature: String? = nil
    ) {
        self.invitation = invitation
        self.challengeID = challengeID
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.platform = platform
        self.devicePublicKeySPKI = devicePublicKeySPKI
        self.presencePublicKeySPKI = presencePublicKeySPKI
        self.challengeSignature = challengeSignature
        self.presenceKeySignature = presenceKeySignature
    }

    enum CodingKeys: String, CodingKey {
        case invitation
        case challengeID = "challenge_id"
        case deviceID = "device_id"
        case deviceName = "device_name"
        case platform
        case devicePublicKeySPKI = "device_public_key_spki"
        case presencePublicKeySPKI = "presence_public_key_spki"
        case challengeSignature = "challenge_signature"
        case presenceKeySignature = "presence_key_signature"
    }
}

public struct PairingClaimResponse: Decodable, Sendable {
    public let device: GrantedDevice
    public let authorityCertificate: String
    public let issuedAt: String
    public let presenceKeyFingerprint: String?

    enum CodingKeys: String, CodingKey {
        case device
        case authorityCertificate = "authority_certificate"
        case issuedAt = "issued_at"
        case presenceKeyFingerprint = "presence_key_fingerprint"
    }
}

public struct GrantedDevice: Decodable, Sendable {
    public let id: String
    public let displayName: String
    public let platform: String
    public let role: String

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case platform
        case role
    }
}

/// The device-signed challenge proof (`challenge || invitation_id || device_id || node_id`).
public struct ChallengeProof {
    public let challengeBytes: Data
    public let invitationID: String
    public let deviceID: String
    public let nodeID: String

    public init(
        challengeBytes: Data,
        invitationID: String,
        deviceID: String,
        nodeID: String
    ) {
        self.challengeBytes = challengeBytes
        self.invitationID = invitationID
        self.deviceID = deviceID
        self.nodeID = nodeID
    }

    public var signingData: Data {
        var data = Data()
        data.append(challengeBytes)
        data.append(Data(invitationID.utf8))
        data.append(Data(deviceID.utf8))
        data.append(Data(nodeID.utf8))
        return data
    }
}
