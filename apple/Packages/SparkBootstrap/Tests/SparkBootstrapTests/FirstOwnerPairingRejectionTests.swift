import CryptoKit
import Foundation
@_spi(SparkTestSupport) import SparkAPI
import SparkSecurity
@_spi(SparkTestSupport) @_spi(SparkInternal) import SparkTransport
import Testing

@_spi(SparkTestSupport) @testable import SparkBootstrap

// MARK: - Refusals

@Test func aTransportPinnedToSomethingElseStopsThePairing() async throws {
    // Reject mismatched pins returned by the SPI transport factory.
    let scenario = try makePairingCompositionScenario()
    let wrong = String(repeating: "d", count: 64)
    await #expect(
        throws: FirstOwnerPairingError.transportNotPinnedToNode(
            expected: pairingCompositionTestNodePin,
            found: wrong
        )
    ) {
        _ = try await pairingCompositionTestPairing(scenario, pinOverride: wrong).claim(
            scenario.bootstrap,
            route: pairingCompositionTestRoute
        )
    }
    #expect(scenario.node.paths.isEmpty, "nothing was sent")
    #expect(try scenario.store.trust(forNode: scenario.bootstrap.nodeID) == nil)
    #expect(try scenario.store.staged(forNode: scenario.bootstrap.nodeID) == nil)
}

@Test func aRefusedCertificateIsReportedAsSuchAndLeavesNothingStaged() async throws {
    let scenario = try makePairingCompositionScenario()
    let pairingCompositionTestPairing = FirstOwnerPairing(
        signer: scenario.signer,
        deviceID: scenario.deviceID,
        deviceName: "Owner iPhone",
        platform: "ios",
        trustStore: scenario.store,
        testTransportFactory: { pin in
            StubPinnedTransport(pin: pin) { _ in
                throw PinnedTransportError.certificateRejected(host: "spark.local")
            }
        },
        now: { Date(timeIntervalSince1970: 1_787_000_000) }
    )
    await #expect(throws: (any Error).self) {
        _ = try await pairingCompositionTestPairing.claim(
            scenario.bootstrap,
            route: pairingCompositionTestRoute
        )
    }
    #expect(try scenario.store.trust(forNode: scenario.bootstrap.nodeID) == nil)
    #expect(try scenario.store.staged(forNode: scenario.bootstrap.nodeID) == nil)
}

@Test func aRefusedClaimDiscardsTheStagedTrust() async throws {
    let scenario = try makePairingCompositionScenario()
    scenario.node.claimStatus = 409
    await #expect(throws: (any Error).self) {
        _ = try await pairingCompositionTestPairing(scenario).claim(
            scenario.bootstrap,
            route: pairingCompositionTestRoute
        )
    }
    #expect(try scenario.store.trust(forNode: scenario.bootstrap.nodeID) == nil)
    #expect(
        try scenario.store.staged(forNode: scenario.bootstrap.nodeID) == nil,
        "a claim the node refused must not leave this device looking half paired"
    )
}

@Test func aGrantNamingAnotherDeviceIsRejected() async throws {
    let scenario = try makePairingCompositionScenario()
    scenario.node.grantDeviceID = "11111111-2222-3333-4444-555555555555"
    await #expect(throws: (any Error).self) {
        _ = try await pairingCompositionTestPairing(scenario).claim(
            scenario.bootstrap,
            route: pairingCompositionTestRoute
        )
    }
    #expect(try scenario.store.trust(forNode: scenario.bootstrap.nodeID) == nil)
    #expect(try scenario.store.staged(forNode: scenario.bootstrap.nodeID) == nil)
}

@Test func aGrantCarryingADifferentAuthorityIsRejected() async throws {
    // Reject a grant issued under a different authority from the verified handshake.
    let scenario = try makePairingCompositionScenario()
    scenario.node.grantAuthorityCertificate =
        Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
    await #expect(throws: FirstOwnerPairingError.authorityKeyDoesNotMatchFingerprint) {
        _ = try await pairingCompositionTestPairing(scenario).claim(
            scenario.bootstrap,
            route: pairingCompositionTestRoute
        )
    }
    #expect(try scenario.store.trust(forNode: scenario.bootstrap.nodeID) == nil)
}

@Test func aGrantWithATruncatedAuthorityCertificateIsRejected() async throws {
    let scenario = try makePairingCompositionScenario()
    scenario.node.grantAuthorityCertificate = Data([1, 2, 3])
    await #expect(throws: FirstOwnerPairingError.malformedAuthorityCertificate) {
        _ = try await pairingCompositionTestPairing(scenario).claim(
            scenario.bootstrap,
            route: pairingCompositionTestRoute
        )
    }
}

@Test func aGrantForAnotherRoleIsRejected() async throws {
    let scenario = try makePairingCompositionScenario()
    scenario.node.grantRole = "developer"
    await #expect(throws: FirstOwnerPairingError.unexpectedRole("developer")) {
        _ = try await pairingCompositionTestPairing(scenario).claim(
            scenario.bootstrap,
            route: pairingCompositionTestRoute
        )
    }
    #expect(try scenario.store.trust(forNode: scenario.bootstrap.nodeID) == nil)
}

// MARK: - Relaunch

@Test func theDeviceKeySurvivesARelaunchAndTheNodeStaysPinned() async throws {
    // Restore the same device key and node pin after rebuilding pairing objects from persistent storage.
    let scenario = try makePairingCompositionScenario()
    let trust = try await pairingCompositionTestPairing(scenario).claim(
        scenario.bootstrap,
        route: pairingCompositionTestRoute
    )
    let firstKey = scenario.signer.publicKeySPKI

    let reloaded = try SoftwareSigner(
        applicationTag: pairingCompositionTestDeviceKeyTag,
        store: scenario.backing
    )
    #expect(reloaded.publicKeySPKI == firstKey)

    let reloadedStore = NodeTrustStore(store: scenario.backing)
    #expect(try reloadedStore.trust(forNode: trust.nodeID) == trust)
    #expect(try reloadedStore.pin(forNode: trust.nodeID) == pairingCompositionTestNodePin)
}

@Test func aSecondClaimAgainstADifferentCertificateIsRefused() async throws {
    // Refuse changed stored certificates without prompting to overwrite trust.
    let scenario = try makePairingCompositionScenario()
    _ = try await pairingCompositionTestPairing(scenario).claim(
        scenario.bootstrap,
        route: pairingCompositionTestRoute
    )

    let moved = RuntimeBootstrapResult(
        nodeID: scenario.bootstrap.nodeID,
        nodeName: scenario.bootstrap.nodeName,
        authorityFingerprint: scenario.bootstrap.authorityFingerprint,
        authorityPublicKey: scenario.bootstrap.authorityPublicKey,
        tlsFingerprint: String(repeating: "e", count: 64),
        invitationExpiresAt: scenario.bootstrap.invitationExpiresAt,
        invitation: scenario.bootstrap.invitation,
        trustRootSource: scenario.bootstrap.trustRootSource
    )
    await #expect(throws: (any Error).self) {
        _ = try await pairingCompositionTestPairing(scenario).claim(
            moved,
            route: pairingCompositionTestRoute
        )
    }
    #expect(
        try scenario.store.trust(forNode: moved.nodeID)?.tlsFingerprint
            == pairingCompositionTestNodePin,
        "the original pin is intact"
    )
}

// MARK: - The connection the invitation travels over

@Test func anInsecureRouteIsRefusedBeforeAnythingIsSent() async throws {
    // Reject HTTP pairing routes before transmitting invitation or device-key material.
    let scenario = try makePairingCompositionScenario()
    await #expect(throws: FirstOwnerPairingError.insecureRoute("http")) {
        _ = try await pairingCompositionTestPairing(scenario).claim(
            scenario.bootstrap,
            route: URL(string: "http://spark.local:7443")!
        )
    }
    #expect(scenario.node.paths.isEmpty, "nothing was sent")
    #expect(try scenario.store.trust(forNode: scenario.bootstrap.nodeID) == nil)
    #expect(try scenario.store.staged(forNode: scenario.bootstrap.nodeID) == nil)
}

@Test func theProductionPairingPathBuildsItsOwnPinnedTransport() throws {
    // Construct production pin enforcement internally rather than trusting an injected transport's pin property.
    let pairingCompositionTestPairing = FirstOwnerPairing(
        signer: try SoftwareSigner(
            applicationTag: pairingCompositionTestDeviceKeyTag,
            store: InMemoryStore()
        ),
        deviceID: UUID(),
        deviceName: "Owner iPhone",
        platform: "ios",
        userPresenceAuthorizer: PairingCompositionTestPairingPresenceAuthorizer(),
        trustStore: NodeTrustStore(store: InMemoryStore())
    )
    // Compile the shipping initializer without any caller-supplied transport.
    _ = pairingCompositionTestPairing
}

@Test func aTransportFactoryThatCannotBuildATransportFailsTheClaim() async throws {
    // Report invalid pin construction without falling back to an unpinned connection.
    let scenario = try makePairingCompositionScenario()
    let pairingCompositionTestPairing = FirstOwnerPairing(
        signer: scenario.signer,
        deviceID: scenario.deviceID,
        deviceName: "Owner iPhone",
        platform: "ios",
        trustStore: scenario.store,
        testTransportFactory: { pin in try URLSessionPinnedTransport(pin: String(pin.dropLast())) },
        now: { Date(timeIntervalSince1970: 1_787_000_000) }
    )
    await #expect(throws: (any Error).self) {
        _ = try await pairingCompositionTestPairing.claim(
            scenario.bootstrap,
            route: pairingCompositionTestRoute
        )
    }
    #expect(try scenario.store.trust(forNode: scenario.bootstrap.nodeID) == nil)
    #expect(try scenario.store.staged(forNode: scenario.bootstrap.nodeID) == nil)
}
