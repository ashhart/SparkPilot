import CryptoKit
import Foundation
@_spi(SparkTestSupport) import SparkAPI
import SparkSecurity
@_spi(SparkTestSupport) import SparkTransport

/// Verify authority, invitation and challenge before claiming over pinned HTTPS, staging trust first for durable recovery.
public struct FirstOwnerPairing: Sendable {
    /// Keep transport injection behind SPI tests because only the concrete production transport enforces the claimed pin.
    public typealias TransportFactory = @Sendable (String) throws -> any PinnedHTTPTransport

    private let signer: any SendableDeviceSigning
    private let deviceID: UUID
    private let deviceName: String
    private let platform: String
    private let userPresenceAuthorizer: (any UserPresenceAuthorizing)?
    private let trustStore: NodeTrustStore
    private let transportFactory: TransportFactory?
    private let now: @Sendable () -> Date

    /// Construct the production pinned transport internally so callers cannot substitute a session.
    public init(
        signer: any SendableDeviceSigning,
        deviceID: UUID,
        deviceName: String,
        platform: String,
        userPresenceAuthorizer: any UserPresenceAuthorizing,
        trustStore: NodeTrustStore = NodeTrustStore(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.signer = signer
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.platform = platform
        self.userPresenceAuthorizer = userPresenceAuthorizer
        self.trustStore = trustStore
        self.transportFactory = nil
        self.now = now
    }

    /// Use SPI access control to prevent shipping callers from selecting the stub transport initializer.
    @_spi(SparkTestSupport)
    public init(
        signer: any SendableDeviceSigning,
        deviceID: UUID,
        deviceName: String,
        platform: String,
        testUserPresenceAuthorizer: (any UserPresenceAuthorizing)? = nil,
        trustStore: NodeTrustStore = NodeTrustStore(),
        testTransportFactory: @escaping TransportFactory,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.signer = signer
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.platform = platform
        self.userPresenceAuthorizer = testUserPresenceAuthorizer
        self.trustStore = trustStore
        self.transportFactory = testTransportFactory
        self.now = now
    }

    /// Return the successfully claimed node trust record after durable storage.
    @discardableResult
    public func claim(
        _ bootstrap: RuntimeBootstrapResult,
        route: URL
    ) async throws -> NodeTrust {
        try await claim(bootstrap, route: route, expectedRole: "owner")
    }

    /// Claim an owner-transferred invitation using the supplied trust material and its runtime-supported role.
    @discardableResult
    public func claim(
        _ package: AdditionalDevicePairingPackage,
        route: URL
    ) async throws -> NodeTrust {
        try await claim(
            package.bootstrapResult(),
            route: route,
            expectedRole: package.invitation.role
        )
    }

    private func claim(
        _ bootstrap: RuntimeBootstrapResult,
        route: URL,
        expectedRole: String
    ) async throws -> NodeTrust {
        // Verify the authority key against the trusted fingerprint.
        guard let authorityKeyBytes = Data(hex: bootstrap.authorityPublicKey),
            authorityKeyBytes.count == 32
        else {
            throw FirstOwnerPairingError.malformedAuthorityKey
        }
        guard SHA256Hex.of(authorityKeyBytes) == bootstrap.authorityFingerprint else {
            throw FirstOwnerPairingError.authorityKeyDoesNotMatchFingerprint
        }
        let authorityKey: Curve25519.Signing.PublicKey
        do {
            authorityKey = try Curve25519.Signing.PublicKey(rawRepresentation: authorityKeyBytes)
        } catch {
            throw FirstOwnerPairingError.malformedAuthorityKey
        }

        // Verify that the invitation was signed by the established authority.
        let invitation = try PairingInvitationPayload(json: bootstrap.invitation)
        try invitation.verify(under: authorityKey)
        guard invitation.nodeID == bootstrap.nodeID else {
            throw FirstOwnerPairingError.invitationForAnotherNode(
                expected: bootstrap.nodeID,
                found: invitation.nodeID
            )
        }
        guard invitation.role == expectedRole else {
            if expectedRole == "owner" {
                throw FirstOwnerPairingError.notAnOwnerInvitation(invitation.role)
            }
            throw FirstOwnerPairingError.unexpectedRole(invitation.role)
        }
        guard invitation.authorityFingerprint == bootstrap.authorityFingerprint else {
            throw FirstOwnerPairingError.authorityKeyDoesNotMatchFingerprint
        }
        guard let expiry = RFC3339.date(from: invitation.expiresAt) else {
            throw FirstOwnerPairingError.malformedInvitation("expires_at is not RFC 3339")
        }
        guard expiry > now() else {
            throw FirstOwnerPairingError.invitationExpired(invitation.expiresAt)
        }
        guard let invitationID = UUID(uuidString: invitation.invitationID) else {
            throw FirstOwnerPairingError.malformedInvitation("invitation_id is not a UUID")
        }
        guard let nodeID = UUID(uuidString: bootstrap.nodeID) else {
            throw FirstOwnerPairingError.malformedInvitation("node_id is not a UUID")
        }

        // Reject non-HTTPS routes before sending the invitation over the pinned connection.
        guard route.scheme?.lowercased() == "https" else {
            throw FirstOwnerPairingError.insecureRoute(route.scheme ?? "none")
        }
        let client: PairingClient
        if let transportFactory {
            // Assert stub pin wiring only; a test double's reported pin does not prove transport security.
            let transport: any PinnedHTTPTransport
            do {
                transport = try transportFactory(bootstrap.tlsFingerprint)
            } catch {
                throw FirstOwnerPairingError.transportUnavailable("\(error)")
            }
            guard transport.pin == bootstrap.tlsFingerprint else {
                throw FirstOwnerPairingError.transportNotPinnedToNode(
                    expected: bootstrap.tlsFingerprint,
                    found: transport.pin
                )
            }
            client = PairingClient(transport: transport)
        } else {
            // Construct the production client directly from the trusted installation TLS fingerprint.
            do {
                client = try PairingClient(pin: bootstrap.tlsFingerprint)
            } catch {
                throw FirstOwnerPairingError.transportUnavailable("\(error)")
            }
        }

        // Verify the challenge and its envelope signature before claiming.
        let challenge: PairingChallengeResponse
        do {
            challenge = try await client.challenge(
                route: route,
                invitationID: invitationID,
                devicePublicKeySPKI: signer.publicKeySPKI
            )
        } catch {
            throw FirstOwnerPairingError.challengeFailed("\(error)")
        }
        try verify(challenge: challenge, under: authorityKey, bootstrap: bootstrap)

        guard let challengeBytes = Base64URL.decode(challenge.challenge),
            !challengeBytes.isEmpty
        else {
            throw FirstOwnerPairingError.malformedChallenge("challenge is not base64url")
        }
        guard let challengeID = UUID(uuidString: challenge.challengeID) else {
            throw FirstOwnerPairingError.malformedChallenge("challenge_id is not a UUID")
        }

        // Bind device-key proof to this challenge, invitation, device and node to prevent cross-context replay.
        _ = challengeID

        // Lowercase the device UUID once for both signed material and claim JSON to match Rust canonical bytes.
        let deviceIdentifier = deviceID.uuidString.lowercased()
        let presenceRegistration: PresenceRegistration?
        if let userPresenceAuthorizer {
            let session: any UserPresenceProofSigning
            do {
                session = try await userPresenceAuthorizer.authorize(
                    localizedReason: String(
                        localized: .confirmAddingDevice(to: bootstrap.nodeName)
                    )
                )
            } catch UserPresenceAuthorizationError.declined {
                throw FirstOwnerPairingError.userPresenceDeclined
            } catch UserPresenceAuthorizationError.unavailable {
                throw FirstOwnerPairingError.userPresenceUnavailable
            } catch UserPresenceAuthorizationError.keyUnavailable {
                throw FirstOwnerPairingError.userPresenceKeyUnavailable
            } catch {
                throw FirstOwnerPairingError.userPresenceKeyUnavailable
            }
            do {
                let fingerprint = try session.keyInfo.pairingFingerprint()
                let binding = try PairingPresenceBinding(
                    challengeBase64URL: Base64URL.encode(challengeBytes),
                    invitationID: invitationID,
                    deviceID: deviceID,
                    nodeID: nodeID,
                    presenceKeyFingerprint: fingerprint
                )
                presenceRegistration = PresenceRegistration(
                    publicKeySPKI: session.keyInfo.publicKeySPKI.base64EncodedString(),
                    fingerprint: fingerprint,
                    binding: binding,
                    signature: Base64URL.encode(
                        try await session.signPairingBinding(binding)
                    )
                )
            } catch {
                throw FirstOwnerPairingError.userPresenceKeyUnavailable
            }
        } else {
            presenceRegistration = nil
        }

        let challengeSignature: Data
        do {
            if let presenceRegistration {
                challengeSignature = try signer.sign(presenceRegistration.binding.signatureInput)
            } else {
                let proof = ChallengeProof(
                    challengeBytes: challengeBytes,
                    invitationID: invitation.invitationID,
                    deviceID: deviceIdentifier,
                    nodeID: bootstrap.nodeID
                )
                challengeSignature = try signer.sign(proof.signingData)
            }
        } catch {
            throw FirstOwnerPairingError.deviceKeyUnavailable("\(error)")
        }

        // Claim only after invitation and challenge verification.
        let claim = PairingClaimRequest(
            invitation: invitation.rawInvitation,
            challengeID: challenge.challengeID,
            deviceID: deviceIdentifier,
            deviceName: deviceName,
            platform: platform,
            devicePublicKeySPKI: signer.publicKeySPKI.base64EncodedString(),
            presencePublicKeySPKI: presenceRegistration?.publicKeySPKI,
            challengeSignature: Base64URL.encode(challengeSignature),
            presenceKeySignature: presenceRegistration?.signature
        )

        // Persist staged trust before the irreversible claim so a later Keychain failure remains recoverable.
        let trust = NodeTrust(
            nodeID: bootstrap.nodeID,
            nodeName: bootstrap.nodeName,
            tlsFingerprint: bootstrap.tlsFingerprint,
            authorityFingerprint: bootstrap.authorityFingerprint,
            authorityPublicKey: bootstrap.authorityPublicKey,
            pairedAt: now(),
            localDeviceRole: invitation.rawInvitation.role
        )
        do {
            try trustStore.stage(trust)
        } catch {
            throw FirstOwnerPairingError.trustStoreUnavailable("\(error)")
        }

        let granted: PairingClaimResponse
        do {
            granted = try await client.claim(route: route, request: claim)
        } catch {
            // Remove uncommitted trust after refusal without masking the original claim error if cleanup fails.
            try? trustStore.discardStaged(nodeID: bootstrap.nodeID)
            throw FirstOwnerPairingError.claimFailed("\(error)")
        }

        // Accept only a grant naming the device whose key this claim registered.
        do {
            try validate(
                granted: granted,
                deviceID: deviceIdentifier,
                expectedRole: expectedRole,
                authorityKeyBytes: authorityKeyBytes,
                expectedPresenceFingerprint: presenceRegistration?.fingerprint
            )
        } catch {
            try? trustStore.discardStaged(nodeID: bootstrap.nodeID)
            throw error
        }

        // Only now is the node trusted for the future.
        do {
            return try trustStore.commitStaged(nodeID: bootstrap.nodeID)
        } catch {
            throw FirstOwnerPairingError.trustStoreUnavailable("\(error)")
        }
    }

    /// Require the grant's authority_certificate to match the Ed25519 authority that signed the invitation and challenge.
    private func validate(
        granted: PairingClaimResponse,
        deviceID: String,
        expectedRole: String,
        authorityKeyBytes: Data,
        expectedPresenceFingerprint: String?
    ) throws {
        guard granted.device.role == expectedRole else {
            throw FirstOwnerPairingError.unexpectedRole(granted.device.role)
        }
        guard granted.device.id.lowercased() == deviceID else {
            throw FirstOwnerPairingError.grantForAnotherDevice(
                expected: deviceID,
                found: granted.device.id
            )
        }
        guard let certificate = Data(base64Encoded: granted.authorityCertificate),
            certificate.count == 32
        else {
            throw FirstOwnerPairingError.malformedAuthorityCertificate
        }
        guard constantTimeEquals(certificate, authorityKeyBytes) else {
            throw FirstOwnerPairingError.authorityKeyDoesNotMatchFingerprint
        }
        guard RFC3339.date(from: granted.issuedAt) != nil else {
            throw FirstOwnerPairingError.malformedGrant("issued_at is not RFC 3339")
        }
        if let expectedPresenceFingerprint {
            guard let found = granted.presenceKeyFingerprint else {
                throw FirstOwnerPairingError.presenceKeyFingerprintMissing
            }
            guard found == expectedPresenceFingerprint else {
                throw FirstOwnerPairingError.presenceKeyFingerprintMismatch(
                    expected: expectedPresenceFingerprint,
                    found: found
                )
            }
        }
    }

    /// Verify the authority signature over challenge_id, challenge, expires_at and fingerprint joined by newlines.
    private func verify(
        challenge: PairingChallengeResponse,
        under authorityKey: Curve25519.Signing.PublicKey,
        bootstrap: RuntimeBootstrapResult
    ) throws {
        guard challenge.authorityFingerprint == bootstrap.authorityFingerprint else {
            throw FirstOwnerPairingError.authorityKeyDoesNotMatchFingerprint
        }
        let canonical = [
            challenge.challengeID,
            challenge.challenge,
            challenge.expiresAt,
            challenge.authorityFingerprint,
        ].joined(separator: "\n")

        guard let signature = Base64URL.decode(challenge.signature), signature.count == 64 else {
            throw FirstOwnerPairingError.malformedChallenge("signature is not 64 base64url bytes")
        }
        guard authorityKey.isValidSignature(signature, for: Data(canonical.utf8)) else {
            throw FirstOwnerPairingError.challengeSignatureInvalid
        }
        guard let expiry = RFC3339.date(from: challenge.expiresAt), expiry > now() else {
            throw FirstOwnerPairingError.challengeExpired(challenge.expiresAt)
        }
    }
}

private struct PresenceRegistration: Sendable {
    let publicKeySPKI: String
    let fingerprint: String
    let binding: PairingPresenceBinding
    let signature: String
}

public enum FirstOwnerPairingError: Error, Equatable, Sendable {
    case malformedAuthorityKey
    /// Reject an authority key whose hash differs from the reported fingerprint.
    case authorityKeyDoesNotMatchFingerprint
    case malformedInvitation(String)
    case invitationSignatureInvalid
    case invitationForAnotherNode(expected: String, found: String)
    case notAnOwnerInvitation(String)
    case invitationExpired(String)
    case challengeFailed(String)
    case malformedChallenge(String)
    case challengeSignatureInvalid
    case challengeExpired(String)
    case deviceKeyUnavailable(String)
    case userPresenceDeclined
    case userPresenceUnavailable
    case userPresenceKeyUnavailable
    case presenceKeyFingerprintMissing
    case presenceKeyFingerprintMismatch(expected: String, found: String)
    case claimFailed(String)
    case unexpectedRole(String)
    /// The grant names a device other than this one.
    case grantForAnotherDevice(expected: String, found: String)
    /// `authority_certificate` is not a 32-byte Ed25519 public key.
    case malformedAuthorityCertificate
    case malformedGrant(String)
    /// Reject a test transport whose reported pin differs from the node certificate expected by pairing.
    case transportNotPinnedToNode(expected: String, found: String)
    /// Report failure to construct a pinned transport, including malformed fingerprints.
    case transportUnavailable(String)
    /// The route is not https, so there would be no certificate to pin to.
    case insecureRoute(String)
    case trustStoreUnavailable(String)
}

/// Compare key bytes without early exit at the first mismatch.
private func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var difference: UInt8 = 0
    for (a, b) in zip(lhs, rhs) { difference |= a ^ b }
    return difference == 0
}
