import Foundation
import Network
import SparkAPI
import SparkBootstrap
import SparkCore
import SparkDiscovery
import SparkSecurity
import Testing

@testable import SparkAppComposition

@MainActor
@Test func pairedSetupChecksRuntimeVLLMAndTheSignedCatalogueLocally() async throws {
    let model = await firstOwnerFlowTestModelReadyToInstall(
        installer: FirstOwnerFlowTestFakeInstaller(),
        pairingService: FirstOwnerFlowTestFakePairingService(),
        runtime: FirstOwnerFlowTestReadinessRuntime()
    )
    let preparation = RetailOnboardingPreparationModel()
    model.administratorPassword = "hunter2"
    await model.performPrimaryAction()
    await model.pairFirstOwner()

    await model.checkAIServices(preparation: preparation)

    #expect(model.state.phase == .starterModel)
    #expect(preparation.ai.first { $0.id == "runtime-health" }?.status == .ready)
    #expect(preparation.ai.first { $0.id == "vllm" }?.status == .ready)
    #expect(
        preparation.ai.first { $0.id == "vllm" }?.title == "Running models"
    )
    #expect(
        preparation.ai.first { $0.id == "vllm" }?.detail
            == "Your Spark can download and run models."
    )
    #expect(preparation.ai.first { $0.id == "catalogue" }?.status == .ready)
    #expect(preparation.ai.first { $0.id == "open-webui" }?.status == .unavailable)
    #expect(
        preparation.ai.first { $0.id == "open-webui" }?.detail
            == "This runtime does not publish a verified Open WebUI recipe"
    )
    #expect(preparation.ai.first { $0.id == "nemotron" }?.status == .unavailable)
}

@MainActor
@Test func onboardingDefersVerifiedOpenWebUIInstallUntilSetupCompletes() async throws {
    let model = await firstOwnerFlowTestModelReadyToInstall(
        installer: FirstOwnerFlowTestFakeInstaller(),
        pairingService: FirstOwnerFlowTestFakePairingService(),
        runtime: FirstOwnerFlowTestReadinessRuntime(optionalServices: true)
    )
    let preparation = RetailOnboardingPreparationModel()
    model.administratorPassword = "hunter2"
    await model.performPrimaryAction()
    await model.pairFirstOwner()

    await model.checkAIServices(preparation: preparation)

    #expect(preparation.ai.first { $0.id == "open-webui" }?.status == .unavailable)
    #expect(
        preparation.ai.first { $0.id == "open-webui" }?.detail
            == "Available to install from this Spark after setup"
    )
}

@MainActor
@Test func onboardingNeverReportsVLLMReadyWithoutContainerRuntimeCapability() async throws {
    let model = await firstOwnerFlowTestModelReadyToInstall(
        installer: FirstOwnerFlowTestFakeInstaller(),
        pairingService: FirstOwnerFlowTestFakePairingService(),
        runtime: FirstOwnerFlowTestReadinessRuntime(containerRuntime: false)
    )
    let preparation = RetailOnboardingPreparationModel()
    model.administratorPassword = "hunter2"
    await model.performPrimaryAction()
    await model.pairFirstOwner()

    await model.checkAIServices(preparation: preparation)

    #expect(preparation.ai.first { $0.id == "vllm" }?.status == .unavailable)
    #expect(
        preparation.ai.first { $0.id == "vllm" }?.detail
            == "Update the Spark software before running models."
    )
}

@MainActor
@Test func pairingWithoutAServiceFailsRatherThanStalling() async throws {
    // Ensure the securing phase always has a driver that can complete or fail it.
    let model = await firstOwnerFlowTestModelReadyToInstall(
        installer: FirstOwnerFlowTestFakeInstaller(),
        pairingService: nil
    )
    model.administratorPassword = "hunter2"
    await model.performPrimaryAction()
    #expect(model.state.phase == .securing)

    await model.pairFirstOwner()
    #expect(model.state.issue == .pairingFailed, "it fails visibly instead of hanging")
}

@MainActor
@Test func failedRequiredChecksCannotFinishPairedSetup() async throws {
    let model = await firstOwnerFlowTestModelReadyToInstall(
        installer: FirstOwnerFlowTestFakeInstaller(),
        pairingService: FirstOwnerFlowTestFakePairingService(),
        runtime: FirstOwnerFlowTestReadinessRuntime(containerRuntime: false)
    )
    let preparation = RetailOnboardingPreparationModel()
    model.administratorPassword = "test-password"
    await model.performPrimaryAction()
    await model.pairFirstOwner()
    await model.checkAIServices(preparation: preparation)
    await model.performPrimaryAction(preparation: preparation)
    #expect(model.state.phase == .starterModel)
    #expect(model.dashboardModel == nil)
}
