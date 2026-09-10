import Foundation
import Network
import SparkBootstrap
import SparkDiscovery
import SparkLibrary
import SparkSecurity
import Testing

@testable import SparkAppComposition

private let additionalNodeID = "ca890ed7-7c8c-4b2c-9218-b77ef24f569a"
private let additionalAuthorityFingerprint =
    "c2f480d4dda9f4522b9f6d590011636d904accfe59f12f9d66a0221c2558e3a2"
private let additionalTLSFingerprint = String(repeating: "a", count: 64)

private actor FakeAdditionalDevicePairingService: AdditionalDevicePairingServicing {
    private(set) var calls = 0
    private(set) var route: URL?

    func claim(_ package: AdditionalDevicePairingPackage, route: URL) async throws -> NodeTrust {
        calls += 1
        self.route = route
        return NodeTrust(
            nodeID: package.invitation.nodeID,
            nodeName: package.nodeName,
            tlsFingerprint: package.tlsFingerprint,
            authorityFingerprint: package.invitation.authorityFingerprint,
            authorityPublicKey: package.authorityPublicKey,
            pairedAt: Date(timeIntervalSince1970: 1_787_000_000)
        )
    }
}

private actor FakeJoinCodeRedeemer: PairingJoinCodeRedeeming {
    private(set) var code: String?
    private(set) var route: URL?

    func redeem(code: String, route: URL) async throws -> AdditionalDevicePairingPackage {
        self.code = code
        self.route = route
        return additionalPairingPackage()
    }

    func redeem(code: String, route: URL, trustedFingerprint: String) async throws
        -> AdditionalDevicePairingPackage
    {
        self.code = code
        self.route = route
        return additionalPairingPackage()
    }
}

private func additionalPairingPackage(
    nodeID: String = additionalNodeID
) -> AdditionalDevicePairingPackage {
    AdditionalDevicePairingPackage(
        nodeName: "spark-ca890ed7",
        tlsFingerprint: additionalTLSFingerprint,
        authorityPublicKey: String(repeating: "c", count: 64),
        invitation: PairingInvitation(
            version: 1,
            nodeID: nodeID,
            authorityFingerprint: additionalAuthorityFingerprint,
            invitationID: "63e82da2-7fb7-4b4b-9584-4a528000ac94",
            nonce: "bm9uY2U",
            role: "administrator",
            expiresAt: "2099-01-01T00:00:00Z",
            signature: "c2lnbmF0dXJl",
            localEndpoint: "https://spark-ca890ed7.local:7443"
        )
    )
}

private func additionalDiscoveredSpark(
    shortNodeID: String = "ca890ed7"
) -> DiscoveredSpark {
    DiscoveredSpark(
        id: "spark-ca890ed7",
        displayName: "spark-ca890ed7",
        endpoint: .hostPort(host: "spark-ca890ed7.local", port: 7443),
        interface: nil,
        shortNodeID: shortNodeID
    )
}

@MainActor
@Test func unknownRuntimeAdvertisementOffersPairThisDeviceInsteadOfFactorySetup() throws {
    let model = RetailOnboardingModel(
        library: SparkLibrary(store: try SwiftDataLibraryStore())
    )

    let probe = model.handleDiscovered(additionalDiscoveredSpark())

    #expect(probe == nil)
    #expect(model.pairingDeviceTarget?.displayName == "spark-ca890ed7")
    #expect(!model.isAddingSpark, "an installed runtime must not enter factory setup")
    #expect(model.state.phase == .connectToSpark, "the factory state machine remains untouched")
}

@MainActor
@Test func anInterruptedFirstOwnerSetupCanResumeWithoutAFactoryReset() throws {
    let model = RetailOnboardingModel(
        library: SparkLibrary(store: try SwiftDataLibraryStore())
    )
    let discovered = additionalDiscoveredSpark()
    _ = model.handleDiscovered(discovered)

    model.finishInterruptedFirstOwnerSetup()

    #expect(model.pairingDeviceTarget == nil)
    #expect(model.state.phase == .runtimeInstall)
    #expect(model.isAddingSpark)
    #expect(model.bootstrapTarget?.displayName == discovered.displayName)
    #expect(model.administratorUsername == nil)
    #expect(model.administratorPassword.isEmpty)
}

@MainActor
@Test func scannedInvitationPairsTheSelectedBonjourSparkAndOpensItsCard() async throws {
    let pairing = FakeAdditionalDevicePairingService()
    let model = RetailOnboardingModel(
        additionalDevicePairingService: pairing,
        library: SparkLibrary(store: try SwiftDataLibraryStore()),
        signerProvider: { nodeID in
            SparkRequestSigner(
                deviceID: "test-device",
                nodeID: nodeID,
                signingKey: SoftwareSigner()
            )
        }
    )
    _ = model.handleDiscovered(additionalDiscoveredSpark())

    await model.pairThisDevice(payload: try additionalPairingPackage().qrPayload())

    #expect(await pairing.calls == 1)
    #expect(await pairing.route?.absoluteString == "https://spark-ca890ed7.local:7443")
    #expect(model.pairingDeviceTarget == nil)
    #expect(model.pairingDeviceError == nil)
    #expect(model.library.entries.count == 1)
    #expect(model.dashboardModel?.route.host == "spark-ca890ed7.local")
    #expect(
        model.library.entries.first?.preferredRoute?.peerFingerprint == additionalTLSFingerprint
    )
}

@MainActor
@Test func sixDigitCodePairsAMacWithoutScanningAQRCode() async throws {
    let pairing = FakeAdditionalDevicePairingService()
    let redeemer = FakeJoinCodeRedeemer()
    let model = RetailOnboardingModel(
        additionalDevicePairingService: pairing,
        pairingJoinCodeRedeemer: redeemer,
        library: SparkLibrary(store: try SwiftDataLibraryStore()),
        signerProvider: { nodeID in
            SparkRequestSigner(deviceID: "test-mac", nodeID: nodeID, signingKey: SoftwareSigner())
        }
    )
    _ = model.handleDiscovered(additionalDiscoveredSpark())

    await model.pairThisDevice(joinCode: "381 204")

    #expect(await redeemer.code == "381204")
    #expect(await redeemer.route?.absoluteString == "https://spark-ca890ed7.local:7443")
    #expect(await pairing.calls == 1)
    #expect(model.pairingDeviceError == nil)
    #expect(model.dashboardModel != nil)
}

@MainActor
@Test func invitationForAnotherSparkNeverReachesThePairingService() async throws {
    let pairing = FakeAdditionalDevicePairingService()
    let model = RetailOnboardingModel(
        additionalDevicePairingService: pairing,
        library: SparkLibrary(store: try SwiftDataLibraryStore())
    )
    _ = model.handleDiscovered(additionalDiscoveredSpark())
    let otherNode = "00000000-0000-4000-8000-000000000007"

    await model.pairThisDevice(payload: try additionalPairingPackage(nodeID: otherNode).qrPayload())

    #expect(await pairing.calls == 0)
    #expect(model.dashboardModel == nil)
    #expect(model.library.entries.isEmpty)
    #expect(model.pairingDeviceError?.contains("different Spark") == true)
    #expect(model.pairingDeviceTarget != nil, "the owner can scan the correct invitation")
}

@Test func iPadNavigationIncludesExistingClustersInItsSplitView() {
    #expect(AppleNavigationPlan.layout(for: .pad) == .splitView)
    #expect(
        AppleNavigationPlan.sidebarSections
            == [.home, .chats, .projects, .models, .clusters, .automations, .activity, .settings]
    )
}

@Test func iPhoneNavigationKeepsTheFourPlanTabs() {
    #expect(AppleNavigationPlan.layout(for: .phone) == .tabs)
    #expect(AppleNavigationPlan.phoneTabs == [.home, .chats, .activity, .more])
    #expect(AppleNavigationPlan.phoneMoreSections.contains(.clusters))
}

@MainActor
@Test func joinCodeCannotSendInvitationOrPairWithOnlyADiscoveryFingerprint() async throws {
    let pairing = FakeAdditionalDevicePairingService()
    let redeemer = FakeJoinCodeRedeemer()
    let model = RetailOnboardingModel(
        additionalDevicePairingService: pairing,
        pairingJoinCodeRedeemer: redeemer,
        library: SparkLibrary(store: try SwiftDataLibraryStore())
    )
    _ = model.handleDiscovered(additionalDiscoveredSpark())
    for fingerprint in ["", "aaaaaaaa"] {
        await model.pairThisDevice(joinCode: "381204", trustedFingerprint: fingerprint)
        #expect(await redeemer.code == nil)
        #expect(await pairing.calls == 0)
        #expect(model.library.entries.isEmpty)
    }
}
