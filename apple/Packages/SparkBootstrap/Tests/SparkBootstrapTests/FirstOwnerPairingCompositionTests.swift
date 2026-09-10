import CryptoKit
import Foundation
@_spi(SparkTestSupport) import SparkAPI
import SparkSecurity
@_spi(SparkTestSupport) @_spi(SparkInternal) import SparkTransport
import Testing

@_spi(SparkTestSupport) @testable import SparkBootstrap

// MARK: - Success

@Test func aSuccessfulClaimRecordsTrustAndClearsTheStagedCopy() async throws {
    let scenario = try makePairingCompositionScenario()
    let trust = try await pairingCompositionTestPairing(scenario).claim(
        scenario.bootstrap,
        route: pairingCompositionTestRoute
    )

    #expect(trust.nodeID == scenario.bootstrap.nodeID)
    #expect(trust.tlsFingerprint == pairingCompositionTestNodePin)
    #expect(trust.authorityFingerprint == scenario.bootstrap.authorityFingerprint)
    #expect(try scenario.store.trust(forNode: trust.nodeID) == trust)
    #expect(
        try scenario.store.staged(forNode: trust.nodeID) == nil,
        "the staged copy is promoted, not left behind"
    )
}

@Test func theChallengeIsRequestedBeforeTheClaim() async throws {
    let scenario = try makePairingCompositionScenario()
    _ = try await pairingCompositionTestPairing(scenario).claim(
        scenario.bootstrap,
        route: pairingCompositionTestRoute
    )
    #expect(
        scenario.node.paths == ["/api/v1/pairing/challenge", "/api/v1/pairing/claim"],
        "a claim sent before a challenge would be signing bytes the node never issued"
    )
}

@Test func theClaimCarriesAProofOverTheChallengeTheNodeIssued() async throws {
    let scenario = try makePairingCompositionScenario()
    _ = try await pairingCompositionTestPairing(scenario).claim(
        scenario.bootstrap,
        route: pairingCompositionTestRoute
    )

    let body = scenario.node.claimBody
    #expect(body["device_id"] as? String == scenario.deviceIdentifier)
    #expect(body["challenge_id"] as? String == scenario.node.challengeIdentifier)

    // Verify device proof against the lowercase identifier bytes reconstructed by the runtime.
    let proof = ChallengeProof(
        challengeBytes: scenario.node.challengeBytes,
        invitationID: "d0483950-f543-443e-819b-78d06b620186",
        deviceID: scenario.deviceIdentifier,
        nodeID: scenario.bootstrap.nodeID
    )
    let signature = try #require(Base64URL.decode(body["challenge_signature"] as? String ?? ""))
    let spki = try #require(Data(base64Encoded: body["device_public_key_spki"] as? String ?? ""))
    let key = try P256.Signing.PublicKey(derRepresentation: spki)
    #expect(
        key.isValidSignature(
            try P256.Signing.ECDSASignature(rawRepresentation: signature),
            for: proof.signingData
        )
    )
}

@Test func aPresenceRegistrationSignsOneCanonicalMessageWithBothKeys() async throws {
    let scenario = try makePairingCompositionScenario()
    let presence = PairingCompositionTestPairingPresenceAuthorizer()
    _ = try await pairingCompositionTestPairing(scenario, userPresenceAuthorizer: presence).claim(
        scenario.bootstrap,
        route: pairingCompositionTestRoute
    )

    let body = scenario.node.claimBody
    let presenceSPKI = try #require(
        Data(base64Encoded: body["presence_public_key_spki"] as? String ?? "")
    )
    let presenceKey = try P256.Signing.PublicKey(derRepresentation: presenceSPKI)
    let fingerprint = SHA256Hex.of(presenceKey.x963Representation)
    let binding = try PairingPresenceBinding(
        challengeBase64URL: Base64URL.encode(scenario.node.challengeBytes),
        invitationID: UUID(uuidString: "d0483950-f543-443e-819b-78d06b620186")!,
        deviceID: scenario.deviceID,
        nodeID: UUID(uuidString: scenario.bootstrap.nodeID)!,
        presenceKeyFingerprint: fingerprint
    )
    let challengeSignature = try P256.Signing.ECDSASignature(
        rawRepresentation: try #require(
            Base64URL.decode(body["challenge_signature"] as? String ?? "")
        )
    )
    let presenceSignature = try P256.Signing.ECDSASignature(
        rawRepresentation: try #require(
            Base64URL.decode(body["presence_key_signature"] as? String ?? "")
        )
    )
    let deviceSPKI = try #require(
        Data(base64Encoded: body["device_public_key_spki"] as? String ?? "")
    )
    let deviceKey = try P256.Signing.PublicKey(derRepresentation: deviceSPKI)

    #expect(deviceKey.isValidSignature(challengeSignature, for: binding.signatureInput))
    #expect(presenceKey.isValidSignature(presenceSignature, for: binding.signatureInput))
    #expect(await presence.authorizationCount == 1)
}

@Test func aPresenceGrantFingerprintMismatchNeverPromotesTrust() async throws {
    let scenario = try makePairingCompositionScenario()
    scenario.node.corruptPresenceFingerprint = true

    await #expect(throws: (any Error).self) {
        _ = try await pairingCompositionTestPairing(
            scenario,
            userPresenceAuthorizer: PairingCompositionTestPairingPresenceAuthorizer()
        ).claim(scenario.bootstrap, route: pairingCompositionTestRoute)
    }

    #expect(try scenario.store.trust(forNode: scenario.bootstrap.nodeID) == nil)
    #expect(try scenario.store.staged(forNode: scenario.bootstrap.nodeID) == nil)
}

@Test func declinedPairingPresenceSendsNoClaim() async throws {
    let scenario = try makePairingCompositionScenario()

    await #expect(throws: FirstOwnerPairingError.userPresenceDeclined) {
        _ = try await pairingCompositionTestPairing(
            scenario,
            userPresenceAuthorizer: PairingCompositionTestPairingPresenceAuthorizer(
                outcome: .decline
            )
        ).claim(scenario.bootstrap, route: pairingCompositionTestRoute)
    }

    #expect(scenario.node.paths == ["/api/v1/pairing/challenge"])
    #expect(try scenario.store.trust(forNode: scenario.bootstrap.nodeID) == nil)
}

@Test func unavailablePairingPresenceSendsNoClaim() async throws {
    let scenario = try makePairingCompositionScenario()

    await #expect(throws: FirstOwnerPairingError.userPresenceUnavailable) {
        _ = try await pairingCompositionTestPairing(
            scenario,
            userPresenceAuthorizer: PairingCompositionTestPairingPresenceAuthorizer(
                outcome: .unavailable
            )
        ).claim(scenario.bootstrap, route: pairingCompositionTestRoute)
    }

    #expect(scenario.node.paths == ["/api/v1/pairing/challenge"])
    #expect(try scenario.store.trust(forNode: scenario.bootstrap.nodeID) == nil)
}

@Test func additionalDeviceClaimsAlsoRegisterPresence() async throws {
    let scenario = try makePairingCompositionScenario(role: "developer")
    scenario.node.grantRole = "developer"
    let invitation = try PairingInvitationPayload(json: scenario.bootstrap.invitation)
        .rawInvitation
    let package = AdditionalDevicePairingPackage(
        nodeName: scenario.bootstrap.nodeName,
        tlsFingerprint: scenario.bootstrap.tlsFingerprint,
        authorityPublicKey: scenario.bootstrap.authorityPublicKey,
        invitation: invitation
    )

    _ = try await pairingCompositionTestPairing(
        scenario,
        userPresenceAuthorizer: PairingCompositionTestPairingPresenceAuthorizer()
    ).claim(package, route: pairingCompositionTestRoute)

    #expect(scenario.node.claimBody["presence_public_key_spki"] != nil)
    #expect(scenario.node.claimBody["presence_key_signature"] != nil)
}
