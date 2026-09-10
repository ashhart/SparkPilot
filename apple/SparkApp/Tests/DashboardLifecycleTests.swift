import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing
@testable import SparkAppComposition

@Test func enginePreparationAndStartupStagesUseOwnerFacingCopy() {
    #expect(
        SparkDashboardOwnerPresentation.operationStageLabel(
            "preparing_engine_image",
            action: .load
        ) == "Preparing the inference engine"
    )
    #expect(
        SparkDashboardOwnerPresentation.operationStageLabel("starting", action: .load)
            == "Starting the model"
    )
    #expect(
        SparkDashboardOwnerPresentation.operationStageLabel("draining_previous", action: .load)
            == "Finishing requests on the current model"
    )
    #expect(
        SparkDashboardOwnerPresentation.operationStageLabel("stopping_previous", action: .load)
            == "Stopping the current model"
    )
    #expect(
        SparkDashboardOwnerPresentation.operationStageLabel("serving_probe", action: .load)
            == "Checking the model responds"
    )
    #expect(
        SparkDashboardOwnerPresentation.operationStageLabel(
            "verifying_memory_recovery",
            action: .unload
        ) == "Checking memory was released"
    )
    #expect(
        SparkDashboardOwnerPresentation.operationStageLabel(
            "restoring_previous_engine",
            action: .load
        ) == "Restoring the previous model"
    )
    #expect(
        SparkDashboardOwnerPresentation.operationStageLabel(
            "verifying_previous_engine",
            action: .load
        ) == "Checking the previous model"
    )

    let imagePreparation = ModelLifecycleState(
        action: .load,
        operation: try? dashboardTestLifecycleOperation(
            kind: "model.load",
            state: "running",
            progress: 0.30,
            stage: "preparing_engine_image"
        ),
        errorMessage: nil
    )
    #expect(
        imagePreparation.progressAccessibilityLabel(modelName: "Compact 8B")
            == "Compact 8B, Preparing the inference engine"
    )
    #expect(
        imagePreparation.operation.flatMap(SparkDashboardOwnerPresentation.determinateProgress)
            == nil
    )
    let measuredDownload = try? dashboardTestLifecycleOperation(
        kind: "model.install",
        state: "running",
        progress: 0.42,
        stage: "downloading"
    )
    #expect(measuredDownload.flatMap(SparkDashboardOwnerPresentation.determinateProgress) == 0.42)
}

@MainActor
@Test func installPollsTheDurableOperationToCompletion() async throws {
    let runtime = DashboardTestLifecycleRuntime(
        operationResponses: [
            try dashboardTestLifecycleOperation(
                kind: "model.install",
                state: "running",
                progress: 0.5,
                stage: "downloading"
            ),
            try dashboardTestLifecycleOperation(
                kind: "model.install",
                state: "succeeded",
                progress: 1,
                stage: "verified"
            ),
        ]
    )
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        operationStore: DashboardTestTestOperationStore(),
        operationDelay: { _ in }
    )

    await model.prepareInstall(modelID: "open/model-8b")
    #expect(await runtime.installKeys.isEmpty)
    await model.applyConfirmation()

    let state = try #require(model.lifecycleState(for: "open/model-8b"))
    #expect(state.action == .install)
    #expect(state.operation?.state == .succeeded)
    #expect(state.operation?.progress == 1)
    #expect(state.operation?.stage == "verified")
    #expect(state.errorMessage == nil)
    #expect(await runtime.polledOperationIDs.count == 2)
    let previewKey = try #require(await runtime.installPreviewCalls.first?.1)
    let applyKey = try #require(await runtime.installKeys.first)
    #expect(applyKey == previewKey)
    #expect(
        await runtime.installRequests.first?.acceptedPreviewDigest
            == String(repeating: "a", count: 64)
    )
}

@MainActor
@Test func terminalModelFailureCanBeReviewedAndRetried() async throws {
    let runtime = DashboardTestLifecycleRuntime(
        operationResponses: [
            try dashboardTestLifecycleOperation(
                kind: "model.install",
                state: "failed",
                progress: 0.4,
                stage: "downloading",
                errorCode: "DOWNLOAD_FAILED"
            )
        ]
    )
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        operationStore: DashboardTestTestOperationStore(),
        operationDelay: { _ in }
    )

    await model.refresh()
    await model.prepareInstall(modelID: "open/model-8b")
    await model.applyConfirmation()

    #expect(
        model.lifecycleState(for: "open/model-8b")?.recoveryAction == .retryTerminalFailure
    )
    await model.refreshPreview(modelID: "open/model-8b")
    #expect(model.pendingConfirmation != nil)
    #expect(await runtime.installPreviewCalls.count == 2)
}

@MainActor
@Test func gatedDownloadAuthenticationFailureHasConcreteRecoveryCopy() async throws {
    let runtime = DashboardTestLifecycleRuntime(
        operationResponses: [
            try dashboardTestLifecycleOperation(
                kind: "model.install",
                state: "failed",
                progress: 0,
                stage: "downloading",
                errorCode: "provider manifest request returned 401 Unauthorized"
            )
        ]
    )
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        operationStore: DashboardTestTestOperationStore(),
        operationDelay: { _ in }
    )

    await model.prepareInstall(
        modelID: "open/model-8b",
        providerCredentialID: "63e82da2-7fb7-4b4b-9584-4a528000ac94"
    )
    await model.applyConfirmation()

    #expect(
        model.lifecycleState(for: "open/model-8b")?.errorMessage
            == "Hugging Face rejected the saved token. Replace it under Hugging Face access, then retry."
    )
}

@MainActor
@Test func installRetryReusesTheLogicalActionKeyAfterTransportFailure() async throws {
    let runtime = DashboardTestLifecycleRuntime(failFirstInstall: true)
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        operationStore: DashboardTestTestOperationStore(),
        operationDelay: { _ in }
    )

    await model.prepareInstall(modelID: "open/model-8b")
    await model.applyConfirmation()
    #expect(model.lifecycleState(for: "open/model-8b")?.errorMessage != nil)
    await model.retryIncompleteOperation(modelID: "open/model-8b")

    let keys = await runtime.installKeys
    #expect(keys.count == 2)
    #expect(keys[0] == keys[1])
    #expect(model.lifecycleState(for: "open/model-8b")?.operation?.state == .succeeded)
}

@MainActor
@Test func singleSafeProfileStartRequiresExplicitReplacement() async throws {
    let runtime = DashboardTestLifecycleRuntime(activeModelID: "open/other-model")
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        operationStore: DashboardTestTestOperationStore(),
        operationDelay: { _ in }
    )
    await model.refresh()

    await model.prepareLoad(modelID: "open/model-8b", replaceActive: false)
    #expect(await runtime.loadPreviewCalls.isEmpty)
    #expect(await runtime.loadCalls.isEmpty)

    await model.prepareLoad(modelID: "open/model-8b", replaceActive: true)
    #expect(model.pendingConfirmation?.preview.action == .replace)
    #expect(await runtime.loadCalls.isEmpty)
    await model.applyConfirmation()

    let calls = await runtime.loadCalls
    let request = try #require(calls.first?.0)
    #expect(request.modelId == "open/model-8b")
    #expect(request.profileId == "balanced")
    #expect(request.replaceActive == true)
    #expect(model.lifecycleState(for: "open/model-8b")?.operation?.state == .succeeded)
}

@MainActor
@Test func loadPreviewMustBeAcceptedBeforeARegularStart() async throws {
    let runtime = DashboardTestLifecycleRuntime()
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        operationStore: DashboardTestTestOperationStore(),
        operationDelay: { _ in }
    )
    await model.refresh()

    await model.prepareLoad(modelID: "open/model-8b", replaceActive: false)

    let previewCall = try #require(await runtime.loadPreviewCalls.first)
    let confirmation = try #require(model.pendingConfirmation)
    #expect(confirmation.preview.action == .load)
    #expect(confirmation.preview.evidence.downloadBytes == 6_000_000_000)
    #expect(confirmation.preview.evidence.locallyReusableBytes == 2_000_000_000)
    #expect(await runtime.loadCalls.isEmpty)

    await model.applyConfirmation()

    let applyCall = try #require(await runtime.loadCalls.first)
    #expect(applyCall.1 == previewCall.1)
    #expect(applyCall.0.acceptedPreviewDigest == confirmation.preview.previewDigest)
    #expect(applyCall.0.replaceActive == false)
}

@MainActor
@Test func libraryManagementRevalidatesThenUsesTheExistingLoadPreview() async throws {
    let runtime = DashboardTestLifecycleRuntime()
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        operationStore: DashboardTestTestOperationStore(),
        operationDelay: { _ in }
    )

    let opened = await model.prepareLibraryManagement(
        modelID: "open/model-8b",
        action: .load
    )

    #expect(opened)
    #expect(model.requestedModelID == "open/model-8b")
    #expect(model.pendingConfirmation?.lifecycleAction == .load)
    #expect(model.pendingConfirmation?.preview.action == .load)
    #expect(await runtime.loadPreviewCalls.count == 1)
    #expect(await runtime.loadCalls.isEmpty, "the Library cannot bypass owner confirmation")
}
