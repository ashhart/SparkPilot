import Foundation
import Network
import SparkAPI
import SparkBootstrap
import SparkCore
import SparkDiscovery
import SparkSecurity
import Testing

@testable import SparkAppComposition

/// Failure cleanup must not mark the unfinished pairing step ready or erase its failure state.
@MainActor
@Test func aFailureAtOwnerBootstrapNeverReportsPairingReady() async throws {
    struct Failure: Error {}
    let pairing = FirstOwnerFlowTestFakePairingService()
    let model = await firstOwnerFlowTestModelReadyToInstall(
        installer: FirstOwnerFlowTestReportingInstaller(
            announced: firstOwnerFlowTestCommandsUpToOwnerBootstrap,
            failure: Failure()
        ),
        pairingService: pairing
    )
    let preparation = RetailOnboardingPreparationModel()
    model.administratorPassword = "hunter2"

    await model.performPrimaryAction(preparation: preparation)

    let pairingRow = try #require(preparation.runtime.first { $0.id == "local-pairing" })
    #expect(
        pairingRow.status != .ready,
        "a failed install reported owner pairing as Ready"
    )
    #expect(
        preparation.runtime.contains { $0.status == .failed },
        "a failed install left no failed step"
    )
    #expect(model.state.issue == .runtimeInstallFailed)
    #expect(await pairing.callCount == 0)
}

/// Cleanup announcements must not imply that unfinished installation steps succeeded.
@MainActor
@Test func noStepReadsReadyBeyondWhereAFailedInstallActuallyGot() async throws {
    struct Failure: Error {}
    // Stop after package installation before helper, runtime and pairing steps execute.
    let model = await firstOwnerFlowTestModelReadyToInstall(
        installer: FirstOwnerFlowTestReportingInstaller(
            announced: [
                .prepareWorkDirectory, .verifyDigest, .verifyDetachedSignature,
                .verifyAgainstInstalledTrustRoot, .installPackage, .enablePrivilegedHelper,
            ],
            failure: Failure()
        ),
        pairingService: FirstOwnerFlowTestFakePairingService()
    )
    let preparation = RetailOnboardingPreparationModel()
    model.administratorPassword = "hunter2"

    await model.performPrimaryAction(preparation: preparation)

    let ready = Set(preparation.runtime.filter { $0.status == .ready }.map(\.id))
    #expect(
        !ready.contains("spark-runtime"),
        "the runtime was reported Ready though enableRuntime never started"
    )
    #expect(
        !ready.contains("local-pairing"),
        "owner pairing was reported Ready though it was never reached"
    )
    #expect(preparation.runtime.contains { $0.status == .failed })
}

/// Marks every step ready only when installation succeeds, independently of cleanup announcements.
@MainActor
@Test func aSuccessfulInstallStillReportsEveryStepReady() async throws {
    let model = await firstOwnerFlowTestModelReadyToInstall(
        installer: FirstOwnerFlowTestReportingInstaller(
            announced: firstOwnerFlowTestCommandsUpToOwnerBootstrap
        ),
        pairingService: FirstOwnerFlowTestFakePairingService()
    )
    let preparation = RetailOnboardingPreparationModel()
    model.administratorPassword = "hunter2"

    await model.performPrimaryAction(preparation: preparation)

    #expect(preparation.runtime.allSatisfy { $0.status == .ready })
    #expect(model.state.phase == .securing)
}
