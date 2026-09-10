import Foundation
import Network
import SparkAPI
import SparkBootstrap
import SparkCore
import SparkDiscovery
import SparkSecurity
import Testing

@testable import SparkAppComposition

// MARK: - Success

@MainActor
@Test func aSuccessfulInstallPairsAndReachesTheStarterModel() async throws {
    let installer = FirstOwnerFlowTestFakeInstaller()
    let pairing = FirstOwnerFlowTestFakePairingService()
    let model = await firstOwnerFlowTestModelReadyToInstall(
        installer: installer,
        pairingService: pairing
    )
    let preparation = RetailOnboardingPreparationModel()
    #expect(model.state.phase == .runtimeInstall)

    model.administratorPassword = "hunter2"
    await model.performPrimaryAction(preparation: preparation)
    #expect(model.state.phase == .securing, "install advances to securing")
    #expect(preparation.runtime.allSatisfy { $0.status == .ready })

    // The phase drives itself; the root view calls this on entering .securing.
    await model.pairFirstOwner()

    #expect(model.state.phase == .starterModel, "pairing advances past securing")
    #expect(model.state.issue == nil)
    #expect(await pairing.callCount == 1)

    let trust = try #require(model.pairedNode)
    #expect(trust.nodeID == firstOwnerFlowTestNodeID)
    #expect(trust.tlsFingerprint == firstOwnerFlowTestTlsFingerprint)
    #expect(trust.authorityFingerprint == firstOwnerFlowTestAuthorityFingerprint)
}

@MainActor
@Test func theAdministratorPasswordIsGoneOncePairingSucceeds() async throws {
    let installer = FirstOwnerFlowTestFakeInstaller()
    let pairing = FirstOwnerFlowTestFakePairingService()
    let model = await firstOwnerFlowTestModelReadyToInstall(
        installer: installer,
        pairingService: pairing
    )

    model.administratorPassword = "correct-horse-battery-staple"
    await model.performPrimaryAction()

    // Retain the SSH credential during installation and erase it after successful owner pairing.
    #expect(!model.administratorPassword.isEmpty, "held while pairing still needs it")
    #expect(await installer.receivedPassword == "correct-horse-battery-staple")

    await model.pairFirstOwner()
    #expect(model.administratorPassword.isEmpty, "discarded once pairing succeeded")
}

@MainActor
@Test func pairingUsesTheLocalRouteForTheDiscoveredMachine() async throws {
    let pairing = FirstOwnerFlowTestFakePairingService()
    let model = await firstOwnerFlowTestModelReadyToInstall(
        installer: FirstOwnerFlowTestFakeInstaller(),
        pairingService: pairing
    )
    model.administratorPassword = "hunter2"
    await model.performPrimaryAction()
    await model.pairFirstOwner()

    let route = try #require(await pairing.receivedRoute)
    #expect(route.scheme == "https")
    #expect(route.host == "spark-a1b2.local")
    #expect(route.port == 7443)
}

// MARK: - The node's identity does not check out

@MainActor
@Test func aFingerprintMismatchStopsPairingAndSaysWhy() async throws {
    let pairing = FirstOwnerFlowTestFakePairingService(
        failure: FirstOwnerPairingError.authorityKeyDoesNotMatchFingerprint
    )
    let model = await firstOwnerFlowTestModelReadyToInstall(
        installer: FirstOwnerFlowTestFakeInstaller(),
        pairingService: pairing
    )
    model.administratorPassword = "hunter2"
    await model.performPrimaryAction()
    await model.pairFirstOwner()

    #expect(model.state.issue == .pairingFailed)
    #expect(model.pairedNode == nil, "nothing was trusted")
    #expect(model.administratorPassword.isEmpty, "the credential is not kept across a failure")

    // Identity mismatch must prevent a retry that would send the invitation to the same impostor.
    let detail = try #require(model.pairingFailureDetail)
    #expect(detail.contains("did not check out"))
    #expect(detail.contains("Do not continue"))
}

@MainActor
@Test func anInvitationSignedByTheWrongKeyIsReportedAsTampering() async throws {
    let pairing = FirstOwnerFlowTestFakePairingService(
        failure: FirstOwnerPairingError.invitationSignatureInvalid
    )
    let model = await firstOwnerFlowTestModelReadyToInstall(
        installer: FirstOwnerFlowTestFakeInstaller(),
        pairingService: pairing
    )
    model.administratorPassword = "hunter2"
    await model.performPrimaryAction()
    await model.pairFirstOwner()

    let detail = try #require(model.pairingFailureDetail)
    #expect(detail.contains("not signed by the Spark itself"))
    #expect(model.state.issue == .pairingFailed)
}

// MARK: - A refused claim

@MainActor
@Test func aRefusedClaimIsRecoverableAndRetryDrivesPairingAgain() async throws {
    let pairing = FirstOwnerFlowTestFakePairingService(
        failure: FirstOwnerPairingError.claimFailed("HTTP 500")
    )
    let model = await firstOwnerFlowTestModelReadyToInstall(
        installer: FirstOwnerFlowTestFakeInstaller(),
        pairingService: pairing
    )
    model.administratorPassword = "hunter2"
    await model.performPrimaryAction()
    await model.pairFirstOwner()

    #expect(model.state.issue == .pairingFailed)
    #expect(model.state.phase == .securing)

    // Retry must clear the issue, restore securing state and drive another pairing attempt.
    model.retry()
    #expect(model.state.issue == nil)
    #expect(model.state.phase == .securing)
    #expect(model.pairingFailureDetail == nil)

    #expect(
        await firstOwnerFlowTestSettles { await pairing.callCount >= 2 },
        "retry never re-drove pairing"
    )
}

@MainActor
@Test func anExpiredInvitationExplainsThatAReinstallIsNeeded() async throws {
    let installer = FirstOwnerFlowTestFakeInstaller()
    let pairing = FirstOwnerFlowTestFakePairingService(
        failure: FirstOwnerPairingError.invitationExpired("2026-01-01T00:00:00Z")
    )
    let model = await firstOwnerFlowTestModelReadyToInstall(
        installer: installer,
        pairingService: pairing
    )
    let preparation = RetailOnboardingPreparationModel()
    model.administratorPassword = "hunter2"
    await model.performPrimaryAction(preparation: preparation)
    await model.pairFirstOwner()

    let detail = try #require(model.pairingFailureDetail)
    #expect(detail.contains("expired"))
    #expect(model.retryActionTitle == "Install Again")
    #expect(model.administratorPassword == "hunter2", "kept in memory for the reinstall")

    model.retry(preparation: preparation)

    // Wait for reinstall entry and the resulting securing phase before asserting recovery.
    #expect(
        await firstOwnerFlowTestSettles {
            await installer.callCount == 2 && model.state.phase == .securing
        },
        "the reinstall never finished and returned to securing"
    )
    #expect(await installer.receivedPassword == "hunter2")
    #expect(model.state.issue == nil)
}

@MainActor
@Test func anExpiredInvitationWithoutACredentialReturnsToThePasswordScreen() async throws {
    let installer = FirstOwnerFlowTestFakeInstaller()
    let pairing = FirstOwnerFlowTestFakePairingService(
        failure: FirstOwnerPairingError.invitationExpired("2026-01-01T00:00:00Z")
    )
    let model = await firstOwnerFlowTestModelReadyToInstall(
        installer: installer,
        pairingService: pairing
    )
    model.administratorPassword = "hunter2"
    await model.performPrimaryAction()
    await model.pairFirstOwner()

    // Request missing session credentials after relaunch instead of submitting an empty password.
    model.administratorPassword = ""
    model.retry()

    #expect(model.state.phase == .runtimeInstall)
    #expect(model.state.issue == nil)
    #expect(await installer.callCount == 1)
}

@MainActor
@Test func aFailedInstallNeverReachesPairing() async throws {
    struct Failure: Error {}
    let pairing = FirstOwnerFlowTestFakePairingService()
    let model = await firstOwnerFlowTestModelReadyToInstall(
        installer: FirstOwnerFlowTestFakeInstaller(failure: Failure()),
        pairingService: pairing
    )
    let preparation = RetailOnboardingPreparationModel()
    model.administratorPassword = "hunter2"
    await model.performPrimaryAction(preparation: preparation)

    #expect(model.state.issue == .runtimeInstallFailed)
    #expect(
        model.administratorPassword == "hunter2",
        "kept for the retry; the Spark did not reject it"
    )
    #expect(await pairing.callCount == 0)
    #expect(preparation.runtime.contains { $0.status == .failed })

    // Pairing cannot begin before installation supplies its result.
    await model.pairFirstOwner()
    #expect(await pairing.callCount == 0)
}
