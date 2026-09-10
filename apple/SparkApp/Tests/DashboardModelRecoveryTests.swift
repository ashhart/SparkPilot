import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing
@testable import SparkAppComposition

@MainActor
@Test func exactSignedRecoveryProfileKeepsItsTargetThroughPreviewAndApply() async throws {
    let runtime = DashboardTestLifecycleRuntime(multipleProfiles: true)
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        operationStore: DashboardTestTestOperationStore(),
        operationDelay: { _ in }
    )
    let nodeID = "63e82da2-7fb7-4b4b-9584-4a528000ac94"
    let clusterID = "11111111-2222-4333-8444-555555555555"

    let prepared = await model.prepareVerifiedLoad(
        modelID: "open/model-8b",
        profileID: "balanced",
        expectedRecipeRevision: "r1",
        targetNodeID: nodeID,
        targetClusterID: clusterID
    )

    #expect(prepared)
    let preview = try #require(await runtime.loadPreviewCalls.first?.0)
    #expect(preview.modelId == "open/model-8b")
    #expect(preview.profileId == "balanced")
    #expect(preview.target?.nodeId == nodeID)
    #expect(preview.target?.clusterId == clusterID)
    #expect(await runtime.loadCalls.isEmpty)
    let acceptedDigest = try #require(model.pendingConfirmation?.preview.previewDigest)

    #expect(!model.canChangeLoadProfile)
    await model.changeLoadProfile()
    #expect(model.pendingLoadConfiguration == nil)
    #expect(model.pendingConfirmation?.retryRequest.targetClusterID == clusterID)
    #expect(model.pendingConfirmation?.retryRequest.profileID == "balanced")

    await model.applyConfirmation()

    let apply = try #require(await runtime.loadCalls.first?.0)
    #expect(apply.target?.nodeId == nodeID)
    #expect(apply.target?.clusterId == clusterID)
    #expect(apply.acceptedPreviewDigest == acceptedDigest)
}

@MainActor
@Test func exactRecoveryRefusesAChangedSignedRecipeRevision() async {
    let runtime = DashboardTestLifecycleRuntime()
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        operationStore: DashboardTestTestOperationStore(),
        operationDelay: { _ in }
    )

    let prepared = await model.prepareVerifiedLoad(
        modelID: "open/model-8b",
        profileID: "balanced",
        expectedRecipeRevision: "different-revision",
        targetNodeID: dashboardTestDashboardCoordinatorID,
        targetClusterID: nil
    )

    #expect(!prepared)
    #expect(await runtime.loadPreviewCalls.isEmpty)
    #expect(await runtime.loadCalls.isEmpty)
}

@MainActor
@Test(arguments: [false, true])
func staleClusterReviewKeepsItsExactTargetAndProfile(afterRelaunch: Bool) async throws {
    let runtime = DashboardTestLifecycleRuntime(
        nextApplyError: APIError(
            .local(message: "review changed"),
            statusCode: 409,
            code: "PREVIEW_STALE"
        ),
        multipleProfiles: true
    )
    let store = DashboardTestTestOperationStore()
    let route = URL(string: "https://spark.local:7443")!
    let nodeID = "63e82da2-7fb7-4b4b-9584-4a528000ac94"
    let clusterID = "11111111-2222-4333-8444-555555555555"
    let model = SparkDashboardModel(
        route: route,
        runtime: runtime,
        operationStore: store,
        operationDelay: { _ in }
    )
    let firstKey: UUID
    if afterRelaunch {
        firstKey = UUID()
        try store.save(
            ModelOperationRecoveryRecord(
                targetID: route.absoluteString,
                modelID: "open/model-8b",
                action: .load,
                idempotencyKey: firstKey,
                retryRequest: ModelOperationRetryRequest(
                    recipeRevision: "r1",
                    profileID: "balanced",
                    replaceActive: false,
                    targetNodeID: nodeID,
                    targetClusterID: clusterID,
                    acceptedPreviewDigest: String(repeating: "a", count: 64)
                )
            )
        )
        await model.retryIncompleteOperation(modelID: "open/model-8b")
    } else {
        let prepared = await model.prepareVerifiedLoad(
            modelID: "open/model-8b",
            profileID: "balanced",
            expectedRecipeRevision: "r1",
            targetNodeID: nodeID,
            targetClusterID: clusterID
        )
        #expect(prepared)
        firstKey = try #require(model.pendingConfirmation?.idempotencyKey)
        await model.applyConfirmation()
    }
    #expect(store.storedRecords.isEmpty)
    #expect(model.lifecycleState(for: "open/model-8b")?.recoveryAction == .refreshPreview)
    await model.refreshPreview(modelID: "open/model-8b")
    #expect(model.pendingLoadConfiguration == nil)
    let refreshed = try #require(model.pendingConfirmation)
    #expect(refreshed.idempotencyKey != firstKey)
    #expect(refreshed.retryRequest.recipeRevision == "r1")
    #expect(refreshed.retryRequest.profileID == "balanced")
    #expect(refreshed.retryRequest.targetNodeID == nodeID)
    #expect(refreshed.retryRequest.targetClusterID == clusterID)
    #expect(await runtime.loadCalls.count == 1, "fresh evidence still needs owner confirmation")
    let preview = try #require(await runtime.loadPreviewCalls.last?.0)
    #expect(preview.profileId == "balanced")
    #expect(preview.target?.nodeId == nodeID)
    #expect(preview.target?.clusterId == clusterID)
    await model.applyConfirmation()
    let applied = try #require(await runtime.loadCalls.last?.0)
    #expect(applied.profileId == "balanced")
    #expect(applied.target?.nodeId == nodeID)
    #expect(applied.target?.clusterId == clusterID)
    #expect(await runtime.loadCalls.last?.1 == refreshed.idempotencyKey)
}

@MainActor
@Test func staleClusterReviewRefusesAChangedRecipeRevision() async throws {
    let runtime = DashboardTestLifecycleRuntime(
        nextApplyError: APIError(
            .local(message: "review changed"),
            statusCode: 409,
            code: "PREVIEW_STALE"
        ),
        multipleProfiles: true
    )
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        operationStore: DashboardTestTestOperationStore(),
        operationDelay: { _ in }
    )
    #expect(
        await model.prepareVerifiedLoad(
            modelID: "open/model-8b",
            profileID: "balanced",
            expectedRecipeRevision: "r1",
            targetNodeID: "63e82da2-7fb7-4b4b-9584-4a528000ac94",
            targetClusterID: "11111111-2222-4333-8444-555555555555"
        )
    )
    await model.applyConfirmation()
    await runtime.changeRecipeRevision(to: "r2")
    await model.refreshPreview(modelID: "open/model-8b")
    #expect(model.pendingLoadConfiguration == nil)
    #expect(model.pendingConfirmation == nil)
    #expect(model.lifecycleState(for: "open/model-8b")?.errorMessage != nil)
    #expect(await runtime.loadPreviewCalls.count == 1)
    #expect(await runtime.loadCalls.count == 1)
}

@MainActor
@Test func libraryManagementRefusesAStaleActionAfterRefreshingTheTarget() async {
    let runtime = DashboardTestLifecycleRuntime()
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        operationStore: DashboardTestTestOperationStore(),
        operationDelay: { _ in }
    )

    let opened = await model.prepareLibraryManagement(
        modelID: "open/model-8b",
        action: .install
    )

    #expect(!opened, "the target now reports this model as installed")
    #expect(await runtime.installPreviewCalls.isEmpty)
    #expect(await runtime.installKeys.isEmpty)
}

@MainActor
@Test func libraryManagementUsesTheExistingUnloadPreviewForTheActiveModel() async {
    let runtime = DashboardTestLifecycleRuntime(activeModelID: "open/model-8b")
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        operationStore: DashboardTestTestOperationStore(),
        operationDelay: { _ in }
    )

    let opened = await model.prepareLibraryManagement(
        modelID: "open/model-8b",
        action: .unload
    )

    #expect(opened)
    #expect(model.pendingConfirmation?.lifecycleAction == .unload)
    #expect(await runtime.stopPreviewKeys.count == 1)
    #expect(await runtime.unloadCalls.isEmpty, "the Library cannot bypass owner confirmation")
}

@MainActor
@Test func invalidatedApplyResponsesRequireANewPreview() async throws {
    for code in [
        "PREVIEW_STALE",
        "PREVIEW_EXPIRED",
        "PREVIEW_NOT_FOUND",
        "PREVIEW_ACTION_MISMATCH",
    ] {
        let store = DashboardTestTestOperationStore()
        let runtime = DashboardTestLifecycleRuntime(
            nextApplyError: APIError(.local(message: "review changed"), statusCode: 409, code: code)
        )
        let model = SparkDashboardModel(
            route: URL(string: "https://spark.local:7443")!,
            runtime: runtime,
            operationStore: store,
            operationDelay: { _ in }
        )

        await model.prepareInstall(modelID: "open/model-8b")
        await model.applyConfirmation()

        #expect(model.pendingConfirmation == nil)
        #expect(model.lifecycleState(for: "open/model-8b")?.recoveryAction == .refreshPreview)
        #expect(store.storedRecords.isEmpty)
        #expect(await runtime.installKeys.count == 1)

        await model.refreshPreview(modelID: "open/model-8b")
        #expect(model.pendingConfirmation != nil)
        #expect(await runtime.installPreviewCalls.count == 2)
        #expect(await runtime.installKeys.count == 1)
    }
}

@MainActor
@Test func alreadyAcceptedPreviewClearsRecoveryAndRequiresFreshReview() async throws {
    let store = DashboardTestTestOperationStore()
    let runtime = DashboardTestLifecycleRuntime(
        nextApplyError: APIError(
            .local(message: "this review was already used"),
            statusCode: 409,
            code: "PREVIEW_ALREADY_ACCEPTED"
        )
    )
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        operationStore: store,
        operationDelay: { _ in }
    )

    await model.prepareInstall(modelID: "open/model-8b")
    await model.applyConfirmation()

    #expect(store.storedRecords.isEmpty)
    #expect(model.lifecycleState(for: "open/model-8b")?.recoveryAction == .refreshPreview)
    #expect(model.pendingConfirmation == nil)
    #expect(await runtime.installKeys.count == 1)
}

@MainActor
@Test func unloadAndRemoveReachTheirSeparateRuntimeMutations() async throws {
    let activeRuntime = DashboardTestLifecycleRuntime(activeModelID: "open/model-8b")
    let activeModel = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: activeRuntime,
        operationStore: DashboardTestTestOperationStore(),
        operationDelay: { _ in }
    )
    await activeModel.refresh()
    await activeModel.prepareStopActiveModel()
    #expect(await activeRuntime.unloadCalls.isEmpty)
    await activeModel.applyConfirmation()
    #expect(await activeRuntime.unloadCalls.count == 1)
    let stopPreviewKey = try #require(await activeRuntime.stopPreviewKeys.first)
    let stopApply = try #require(await activeRuntime.unloadCalls.first)
    #expect(stopApply.1 == stopPreviewKey)
    #expect(stopApply.0.acceptedPreviewDigest == String(repeating: "a", count: 64))

    let idleRuntime = DashboardTestLifecycleRuntime()
    let idleModel = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: idleRuntime,
        operationStore: DashboardTestTestOperationStore(),
        operationDelay: { _ in }
    )
    await idleModel.refresh()
    await idleModel.prepareRemove(modelID: "open/model-8b")
    let removalPreview = try #require(idleModel.pendingConfirmation?.preview)
    #expect(removalPreview.consequences.filesRemoved.isEmpty)
    #expect(removalPreview.consequences.reinstallRequired == false)
    #expect(await idleRuntime.removeCalls.isEmpty)
    await idleModel.applyConfirmation()
    let removal = try #require(await idleRuntime.removeCalls.first)
    #expect(removal.0 == "open/model-8b")
    #expect(removal.1.acceptedPreviewDigest == removalPreview.previewDigest)
    let removalPreviewKey = await idleRuntime.removePreviewCalls.first?.1
    #expect(removal.2 == removalPreviewKey)
}
