import Foundation
import Network
import SparkAPI
import SparkBootstrap
import SparkCore
import SparkDiscovery
import SparkSecurity
import Testing

@testable import SparkAppComposition

// MARK: - Relaunch

@Test func theDeviceKeySurvivesARelaunch() throws {
    // Reuse the granted device key across relaunch so paired requests remain signed by the established identity.
    let store = InMemoryStore()
    let first = try DeviceKeyFactory.makeSigner(store: store)
    let second = try DeviceKeyFactory.makeSigner(store: store)
    #expect(first.publicKeySPKI == second.publicKeySPKI)

    // The constructed signer must remain usable by the API client.
    let signer = try DeviceIdentityStore.loadOrCreateSigner(
        nodeID: UUID(),
        defaults: UserDefaults(suiteName: "spark.tests.relaunch")!,
        store: store
    )
    let request = URLRequest(url: URL(string: "https://spark-a1b2.local:7443/api/v1/status")!)
    let authorised = try signer.authorize(request, body: Data())
    #expect(authorised.value(forHTTPHeaderField: "X-Spark-Signature") != nil)
    #expect(authorised.value(forHTTPHeaderField: "X-Spark-Device-ID") != nil)
}

@Test func theTrustLearnedByPairingSurvivesARelaunch() throws {
    let backing = InMemoryStore()
    let trust = NodeTrust(
        nodeID: firstOwnerFlowTestNodeID,
        nodeName: "spark-a1b2",
        tlsFingerprint: firstOwnerFlowTestTlsFingerprint,
        authorityFingerprint: firstOwnerFlowTestAuthorityFingerprint,
        authorityPublicKey: String(repeating: "c", count: 64),
        pairedAt: Date(timeIntervalSince1970: 1_787_000_000)
    )
    try NodeTrustStore(store: backing).remember(trust)

    // A fresh store over the same backing, as the next launch would build.
    let reloaded = try NodeTrustStore(store: backing).pin(forNode: firstOwnerFlowTestNodeID)
    #expect(reloaded == firstOwnerFlowTestTlsFingerprint, "the next launch can still pin")
}

// MARK: - What the owner sees after pairing

@MainActor
@Test func theDashboardOpensOnTheRoutePairingSucceededOver() async throws {
    // The first dashboard must reuse the pinned pairing route instead of reconstructing an unverified address.
    let pairing = FirstOwnerFlowTestFakePairingService()
    let model = await firstOwnerFlowTestModelReadyToInstall(
        installer: FirstOwnerFlowTestFakeInstaller(),
        pairingService: pairing,
        runtime: FirstOwnerFlowTestReadinessRuntime()
    )
    model.administratorPassword = "hunter2"
    await model.performPrimaryAction()
    await model.pairFirstOwner()

    let claimed = try #require(await pairing.receivedRoute)
    #expect(model.pairedRouteURL == claimed)

    // Walk the remaining phases to the point where the dashboard is built.
    let preparation = RetailOnboardingPreparationModel()
    await model.checkAIServices(preparation: preparation)
    await model.performPrimaryAction(preparation: preparation)
    #expect(model.state.phase == .ready)
    // Continuing after the required checks opens the first model on the paired Spark.

    let dashboard = try #require(model.dashboardModel)
    #expect(dashboard.route == claimed)
    #expect(dashboard.requestedModelID == preparation.firstModelID)
    #expect(dashboard.requestedModelID != nil)
    #expect(model.library.entries.count == 1)
    let saved = try #require(model.library.entries.first)
    #expect(saved.coordinatorNodeID?.rawValue.uuidString.lowercased() == firstOwnerFlowTestNodeID)
    #expect(saved.preferredRoute?.baseURL == claimed)
    #expect(saved.preferredRoute?.peerFingerprint == firstOwnerFlowTestTlsFingerprint)
    #expect(saved.members.first?.authorityFingerprint == firstOwnerFlowTestAuthorityFingerprint)
}

@MainActor
@Test func aPairingThatNeverSucceededLeavesNoDashboard() async throws {
    let pairing = FirstOwnerFlowTestFakePairingService(
        failure: FirstOwnerPairingError.claimFailed("refused")
    )
    let model = await firstOwnerFlowTestModelReadyToInstall(
        installer: FirstOwnerFlowTestFakeInstaller(),
        pairingService: pairing,
        runtime: FirstOwnerFlowTestReadinessRuntime()
    )
    model.administratorPassword = "hunter2"
    await model.performPrimaryAction()
    await model.pairFirstOwner()

    #expect(model.pairedNode == nil)
    #expect(model.pairedRouteURL == nil)
    #expect(model.dashboardModel == nil, "no pin, no dashboard")
}

@MainActor
@Test func aSignerThatWillNotLoadStopsTheDashboardAndSaysSo() async throws {
    // Surface device-key failures rather than constructing an unsigned dashboard client.
    let pairing = FirstOwnerFlowTestFakePairingService()
    let model = await firstOwnerFlowTestModelReadyToInstall(
        installer: FirstOwnerFlowTestFakeInstaller(),
        pairingService: pairing,
        runtime: FirstOwnerFlowTestReadinessRuntime(),
        signerProvider: { firstOwnerFlowTestNodeID in
            throw FirstOwnerFlowTestUnavailableSignerError()
        }
    )
    model.administratorPassword = "hunter2"
    await model.performPrimaryAction()
    await model.pairFirstOwner()

    let preparation = RetailOnboardingPreparationModel()
    await model.checkAIServices(preparation: preparation)
    await model.performPrimaryAction(preparation: preparation)
    #expect(model.state.phase == .ready)

    #expect(model.dashboardModel == nil, "no signer, no dashboard")
    let detail = try #require(model.dashboardFailureDetail)
    #expect(detail.contains("signing key"), "the owner is told what is wrong: \(detail)")

    // Report post-install identity failure separately from successful installation and pairing.
    #expect(model.state.issue == .deviceKeyUnavailable)
    #expect(model.state.issue != .pairingFailed)
    #expect(model.state.issue != .runtimeInstallFailed)

    // Verify that the error detail reaches the presentation rendered by the view.
    #expect(model.failureDetail == detail)
}

@MainActor
@Test func aPairingFailuresReasonIsAlsoWhatTheViewWouldShow() async throws {
    // Show specific pairing recovery guidance instead of a generic failure for every cause.
    let pairing = FirstOwnerFlowTestFakePairingService(
        failure: FirstOwnerPairingError.invitationExpired("2026")
    )
    let model = await firstOwnerFlowTestModelReadyToInstall(
        installer: FirstOwnerFlowTestFakeInstaller(),
        pairingService: pairing,
        runtime: FirstOwnerFlowTestReadinessRuntime()
    )
    model.administratorPassword = "hunter2"
    await model.performPrimaryAction()
    await model.pairFirstOwner()

    #expect(model.state.issue == .pairingFailed)
    let detail = try #require(model.failureDetail)
    #expect(detail == model.pairingFailureDetail)
    #expect(detail.contains("expired"), "the specific reason, not the canned copy: \(detail)")
}

@MainActor
@Test func thereIsNoDetailWhenThereIsNoIssue() async throws {
    let pairing = FirstOwnerFlowTestFakePairingService()
    let model = await firstOwnerFlowTestModelReadyToInstall(
        installer: FirstOwnerFlowTestFakeInstaller(),
        pairingService: pairing,
        runtime: FirstOwnerFlowTestReadinessRuntime()
    )
    model.administratorPassword = "hunter2"
    await model.performPrimaryAction()
    await model.pairFirstOwner()
    #expect(model.state.issue == nil)
    #expect(model.failureDetail == nil)
}

@MainActor
@Test func aWorkingSignerProducesTheDashboard() async throws {
    // Exercise the successful dashboard transition to ensure the failure test is not satisfied by an unreachable path.
    let pairing = FirstOwnerFlowTestFakePairingService()
    let model = await firstOwnerFlowTestModelReadyToInstall(
        installer: FirstOwnerFlowTestFakeInstaller(),
        pairingService: pairing,
        runtime: FirstOwnerFlowTestReadinessRuntime()
    )
    model.administratorPassword = "hunter2"
    await model.performPrimaryAction()
    await model.pairFirstOwner()

    let preparation = RetailOnboardingPreparationModel()
    await model.checkAIServices(preparation: preparation)
    await model.performPrimaryAction(preparation: preparation)

    #expect(model.dashboardModel != nil)
    #expect(model.dashboardFailureDetail == nil)
}
