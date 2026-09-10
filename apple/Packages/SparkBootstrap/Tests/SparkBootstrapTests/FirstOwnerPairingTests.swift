import CryptoKit
import Foundation
import SparkSecurity
@_spi(SparkTestSupport) @_spi(SparkInternal) import SparkTransport
import Testing

@_spi(SparkTestSupport) @testable import SparkBootstrap

/// Verify the runtime-produced bootstrap invitation fixture through independent Swift canonicalization.

private func fixtureData(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil) else {
        Issue.record("missing fixture \(name)")
        throw CocoaError(.fileNoSuchFile)
    }
    return try Data(contentsOf: url)
}

private func realBootstrapReport() throws -> JSONValue {
    try JSONValue.parse(try fixtureData("bootstrap-report.json"))
}

private func member(_ report: JSONValue, _ key: String) throws -> String {
    try #require(report.objectValue?[key]?.stringValue)
}

private struct PresenceCanonicalFixture: Decodable {
    struct FixtureCase: Decodable {
        struct Input: Decodable {
            let challenge: String?
            let method: String?
            let pathAndQuery: String?
            let timestamp: String?
            let nonce: String?
            let contentSHA256: String?
            let invitationID: String?
            let deviceID: String
            let nodeID: String?
            let presenceKeyFingerprint: String

            enum CodingKeys: String, CodingKey {
                case challenge
                case method
                case pathAndQuery = "path_and_query"
                case timestamp
                case nonce
                case contentSHA256 = "content_sha256"
                case invitationID = "invitation_id"
                case deviceID = "device_id"
                case nodeID = "node_id"
                case presenceKeyFingerprint = "presence_key_fingerprint"
            }
        }

        let input: Input
        let canonical: String
    }

    let cases: [FixtureCase]
}

// MARK: - The cross-language invitation signature

@Test func swiftVerifiesAnInvitationTheRustRuntimeSigned() throws {
    let report = try realBootstrapReport()
    let publicKey = try #require(Data(hex: try member(report, "authority_public_key")))
    let authority = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
    let invitation = try PairingInvitationPayload(
        json: try #require(report.objectValue?["invitation"])
    )

    // Verify runtime-produced signatures and canonical bytes through the independent Swift implementation.
    try invitation.verify(under: authority)
}

@Test func theInvitationCanonicalFormKeepsTheNullSignatureMember() throws {
    // Retain signature:null in invitation signing bytes while omitting absent optional endpoints.
    let report = try realBootstrapReport()
    let invitation = try PairingInvitationPayload(
        json: try #require(report.objectValue?["invitation"])
    )
    let canonical = String(decoding: invitation.canonicalBytes, as: UTF8.self)

    #expect(canonical.hasSuffix("\"signature\":null}"))
    #expect(canonical.hasPrefix("{\"version\":1,\"node_id\":"))
    // Declaration order, not sorted: `node_id` precedes `authority_fingerprint`.
    let nodeIndex = try #require(canonical.range(of: "\"node_id\""))
    let authorityIndex = try #require(canonical.range(of: "\"authority_fingerprint\""))
    #expect(nodeIndex.lowerBound < authorityIndex.lowerBound)
    // Absent optionals are omitted rather than encoded as null.
    #expect(!canonical.contains("cluster_id"))
    #expect(!canonical.contains("local_endpoint"))
}

@Test func aTamperedInvitationFieldBreaksTheSignature() throws {
    let report = try realBootstrapReport()
    let publicKey = try #require(Data(hex: try member(report, "authority_public_key")))
    let authority = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)

    var invitationMembers = try #require(report.objectValue?["invitation"]?.objectValue)
    // Tamper with an invitation role to verify its grant scope is signed.
    invitationMembers["role"] = .string("administrator")
    let tampered = try PairingInvitationPayload(json: .object(invitationMembers))

    #expect(throws: FirstOwnerPairingError.invitationSignatureInvalid) {
        try tampered.verify(under: authority)
    }
}

@Test func anInvitationForAnotherNodeBreaksTheSignature() throws {
    let report = try realBootstrapReport()
    let publicKey = try #require(Data(hex: try member(report, "authority_public_key")))
    let authority = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)

    var invitationMembers = try #require(report.objectValue?["invitation"]?.objectValue)
    invitationMembers["node_id"] = .string("00000000-0000-4000-8000-000000000000")
    let redirected = try PairingInvitationPayload(json: .object(invitationMembers))

    #expect(throws: FirstOwnerPairingError.invitationSignatureInvalid) {
        try redirected.verify(under: authority)
    }
}

@Test func anInvitationSignedByAnotherAuthorityIsRefused() throws {
    let report = try realBootstrapReport()
    let invitation = try PairingInvitationPayload(
        json: try #require(report.objectValue?["invitation"])
    )
    let impostor = Curve25519.Signing.PrivateKey().publicKey

    #expect(throws: FirstOwnerPairingError.invitationSignatureInvalid) {
        try invitation.verify(under: impostor)
    }
}

@Test func theReportsKeyHashesToTheFingerprintItAlsoCarries() throws {
    // Verify the invitation signature using the transferred authority key.
    let report = try realBootstrapReport()
    let publicKey = try #require(Data(hex: try member(report, "authority_public_key")))
    #expect(SHA256Hex.of(publicKey) == (try member(report, "authority_fingerprint")))

    // Keep the TLS certificate pin distinct from the signing-authority fingerprint.
    let tls = try member(report, "tls_fingerprint")
    #expect(tls != (try member(report, "authority_fingerprint")))
    #expect(tls.count == 64)
}

// MARK: - The device's signed challenge proof

@Test func theSignedDeviceIdentifierIsLowercase() throws {
    // Use lowercase UUID bytes in device signatures to match Rust canonicalization.
    let deviceID = UUID(uuidString: "8ADF6E19-1E1F-4A2C-9A62-4B3E9E2E0C11")!
    let proof = ChallengeProof(
        challengeBytes: Data([1, 2, 3]),
        invitationID: "d0483950-f543-443e-819b-78d06b620186",
        deviceID: deviceID.uuidString.lowercased(),
        nodeID: "ca890ed7-7c8c-4b2c-9218-b77ef24f569a"
    )
    let material = String(decoding: proof.signingData.dropFirst(3), as: UTF8.self)
    #expect(material.contains("8adf6e19-1e1f-4a2c-9a62-4b3e9e2e0c11"))
    #expect(!material.contains("8ADF6E19"))
}

@Test func theProofBindsTheChallengeInvitationDeviceAndNode() {
    // Bind signatures to every challenge, invitation, device and node identifier.
    let base = ChallengeProof(
        challengeBytes: Data([9, 9, 9]),
        invitationID: "invitation",
        deviceID: "device",
        nodeID: "node"
    )
    let variants = [
        ChallengeProof(
            challengeBytes: Data([8, 8, 8]),
            invitationID: "invitation",
            deviceID: "device",
            nodeID: "node"
        ),
        ChallengeProof(
            challengeBytes: Data([9, 9, 9]),
            invitationID: "other",
            deviceID: "device",
            nodeID: "node"
        ),
        ChallengeProof(
            challengeBytes: Data([9, 9, 9]),
            invitationID: "invitation",
            deviceID: "other",
            nodeID: "node"
        ),
        ChallengeProof(
            challengeBytes: Data([9, 9, 9]),
            invitationID: "invitation",
            deviceID: "device",
            nodeID: "other"
        ),
    ]
    for variant in variants {
        #expect(variant.signingData != base.signingData)
    }
}

@Test func pairingPresenceCanonicalMatchesTheCrossLanguageFixture() throws {
    let fixture = try JSONDecoder().decode(
        PresenceCanonicalFixture.self,
        from: fixtureData("pairing-presence-key-canonicalization.json")
    )
    let testCase = try #require(fixture.cases.first)
    let input = testCase.input
    let invitationID = try #require(input.invitationID)
    let nodeID = try #require(input.nodeID)
    let binding = try PairingPresenceBinding(
        challengeBase64URL: try #require(input.challenge),
        invitationID: try #require(UUID(uuidString: invitationID)),
        deviceID: try #require(UUID(uuidString: input.deviceID)),
        nodeID: try #require(UUID(uuidString: nodeID)),
        presenceKeyFingerprint: input.presenceKeyFingerprint
    )

    #expect(String(decoding: binding.signatureInput, as: UTF8.self) == testCase.canonical)
}

@Test func presenceEnrollmentCanonicalMatchesTheCrossLanguageFixture() throws {
    let fixture = try JSONDecoder().decode(
        PresenceCanonicalFixture.self,
        from: fixtureData("presence-key-enrollment-canonicalization.json")
    )
    let testCase = try #require(fixture.cases.first)
    let input = testCase.input
    let nodeID = try #require(input.nodeID)
    let binding = try PresenceKeyEnrollmentBinding(
        method: try #require(input.method),
        pathAndQuery: try #require(input.pathAndQuery),
        timestamp: try #require(input.timestamp),
        nonce: try #require(input.nonce),
        contentSHA256: try #require(input.contentSHA256),
        deviceID: try #require(UUID(uuidString: input.deviceID)),
        presenceKeyFingerprint: input.presenceKeyFingerprint,
        nodeID: try #require(UUID(uuidString: nodeID))
    )

    #expect(String(decoding: binding.signatureInput, as: UTF8.self) == testCase.canonical)
}

// MARK: - Invitation policy

private func report(
    role: String = "owner",
    expiresAt: String = "2099-01-01T00:00:00Z"
) throws -> (RuntimeBootstrapResult, Curve25519.Signing.PrivateKey) {
    let authority = Curve25519.Signing.PrivateKey()
    let nodeID = "ca890ed7-7c8c-4b2c-9218-b77ef24f569a"
    var members: [String: JSONValue] = [
        "version": .integer(1),
        "node_id": .string(nodeID),
        "authority_fingerprint": .string(SHA256Hex.of(authority.publicKey.rawRepresentation)),
        "invitation_id": .string("d0483950-f543-443e-819b-78d06b620186"),
        "nonce": .string("_gauBKJ2S7qD4YEg3YXkJLJ9pVCy4rc-PV4yJSGP3_Q"),
        "role": .string(role),
        "expires_at": .string(expiresAt),
    ]
    // Canonicalization writes signature:null independently of the placeholder needed to parse the fixture.
    members["signature"] = .string(String(repeating: "A", count: 86))
    let unsigned: PairingInvitationPayload = try PairingInvitationPayload(json: .object(members))
    let canonical: Data = unsigned.canonicalBytes
    let signature: Data = try authority.signature(for: canonical)
    let encoded: String = Base64URL.encode(signature)
    members["signature"] = .string(encoded)

    let result = RuntimeBootstrapResult(
        nodeID: nodeID,
        nodeName: "Spark",
        authorityFingerprint: SHA256Hex.of(authority.publicKey.rawRepresentation),
        authorityPublicKey: authority.publicKey.rawRepresentation.hexString,
        tlsFingerprint: String(repeating: "c", count: 64),
        invitationExpiresAt: expiresAt,
        invitation: .object(members),
        trustRootSource: .supplied
    )
    return (result, authority)
}

private func pairing(
    trustStore: NodeTrustStore,
    now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_787_000_000) }
) throws -> FirstOwnerPairing {
    FirstOwnerPairing(
        signer: SoftwareSigner(),
        deviceID: UUID(uuidString: "8ADF6E19-1E1F-4A2C-9A62-4B3E9E2E0C11")!,
        deviceName: "Owner iPhone",
        platform: "ios",
        trustStore: trustStore,
        testTransportFactory: { pin in
            // Never reached: every test here fails before a request is made.
            StubPinnedTransport(pin: pin) { _ in
                Issue.record("a request was made after a check should have stopped it")
                throw PinnedTransportError.unreachable("unreachable")
            }
        },
        now: now
    )
}

@Test func aSubstitutedAuthorityKeyStopsPairingBeforeAnyRequest() async throws {
    var (result, _) = try report()
    result = RuntimeBootstrapResult(
        nodeID: result.nodeID,
        nodeName: result.nodeName,
        authorityFingerprint: result.authorityFingerprint,
        // Somebody else's key, with the node's fingerprint left in place.
        authorityPublicKey: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation.hexString,
        tlsFingerprint: result.tlsFingerprint,
        invitationExpiresAt: result.invitationExpiresAt,
        invitation: result.invitation,
        trustRootSource: result.trustRootSource
    )

    let store = NodeTrustStore(store: InMemoryStore())
    await #expect(throws: FirstOwnerPairingError.authorityKeyDoesNotMatchFingerprint) {
        _ = try await pairing(trustStore: store).claim(
            result,
            route: URL(string: "https://spark.local:7443")!
        )
    }
    #expect(try store.trust(forNode: result.nodeID) == nil, "nothing was trusted")
}

@Test func anExpiredInvitationIsRefused() async throws {
    let (result, _) = try report(expiresAt: "2026-01-01T00:00:00Z")
    let store = NodeTrustStore(store: InMemoryStore())
    await #expect(throws: FirstOwnerPairingError.invitationExpired("2026-01-01T00:00:00Z")) {
        _ = try await pairing(trustStore: store).claim(
            result,
            route: URL(string: "https://spark.local:7443")!
        )
    }
}

@Test func anInvitationForAnotherRoleIsRefused() async throws {
    let (result, _) = try report(role: "developer")
    let store = NodeTrustStore(store: InMemoryStore())
    await #expect(throws: FirstOwnerPairingError.notAnOwnerInvitation("developer")) {
        _ = try await pairing(trustStore: store).claim(
            result,
            route: URL(string: "https://spark.local:7443")!
        )
    }
}

@Test func nothingIsTrustedUntilAClaimSucceeds() async throws {
    // Do not retain active trust after a refused pairing claim.
    let (result, _) = try report(expiresAt: "2026-01-01T00:00:00Z")
    let backing = InMemoryStore()
    let store = NodeTrustStore(store: backing)
    _ = try? await pairing(trustStore: store).claim(
        result,
        route: URL(string: "https://spark.local:7443")!
    )
    #expect(try store.trust(forNode: result.nodeID) == nil)
}
