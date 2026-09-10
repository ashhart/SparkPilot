import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing
@testable import SparkAppComposition

@MainActor
@Test func uncertainSubmissionSurvivesRelaunchAndReusesItsIdempotencyKey() async throws {
    let store = DashboardTestTestOperationStore()
    let firstRuntime = DashboardTestLifecycleRuntime(failFirstInstall: true)
    let firstModel = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: firstRuntime,
        targetID: "node:spark-a",
        operationStore: store,
        operationDelay: { _ in }
    )

    await firstModel.refresh()
    await firstModel.prepareInstall(modelID: "open/model-8b")
    await firstModel.applyConfirmation()

    let saved = try #require(store.storedRecords.first)
    #expect(saved.operationID == nil)
    #expect(saved.retryRequest?.recipeRevision == "r1")
    #expect(
        saved.retryRequest?.acceptedPreviewDigest
            == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    )
    #expect(
        firstModel.lifecycleState(for: "open/model-8b")?.recoveryAction
            == .retryIncompleteOperation
    )

    let relaunchedRuntime = DashboardTestLifecycleRuntime()
    let relaunchedModel = SparkDashboardModel(
        route: URL(string: "https://spark-new-route.local:7443")!,
        runtime: relaunchedRuntime,
        targetID: "node:spark-a",
        operationStore: store,
        operationDelay: { _ in }
    )
    await relaunchedModel.recoverPendingOperations()
    #expect(
        relaunchedModel.lifecycleState(for: "open/model-8b")?.recoveryAction
            == .retryIncompleteOperation
    )

    await relaunchedModel.retryIncompleteOperation(modelID: "open/model-8b")

    let firstKey = try #require(await firstRuntime.installKeys.first)
    let retriedKey = try #require(await relaunchedRuntime.installKeys.first)
    #expect(retriedKey == firstKey)
    #expect(await firstRuntime.installRequests.first?.recipeRevision == "r1")
    #expect(await relaunchedRuntime.installRequests.first?.recipeRevision == "r1")
    let firstRequest = await firstRuntime.installRequests.first
    let replayedRequest = await relaunchedRuntime.installRequests.first
    #expect(firstRequest == replayedRequest)
    #expect(relaunchedModel.lifecycleState(for: "open/model-8b")?.operation?.state == .succeeded)
    #expect(store.storedRecords.isEmpty)
}

@MainActor
@Test func relaunchListsAndResumesKnownDurableOperationWithoutResubmitting() async throws {
    let operationID = UUID(uuidString: "63e82da2-7fb7-4b4b-9584-4a528000ac94")!
    let record = ModelOperationRecoveryRecord(
        targetID: "node:spark-a",
        modelID: "open/model-8b",
        action: .install,
        idempotencyKey: UUID(),
        operationID: operationID
    )
    let running = try dashboardTestLifecycleOperation(
        kind: "model.install",
        state: "running",
        progress: 0.5,
        stage: "downloading"
    )
    let succeeded = try dashboardTestLifecycleOperation(
        kind: "model.install",
        state: "succeeded",
        progress: 1,
        stage: "verified"
    )
    let store = DashboardTestTestOperationStore(records: [record])
    let runtime = DashboardTestLifecycleRuntime(
        operationResponses: [succeeded],
        listedOperations: [running]
    )
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        targetID: "node:spark-a",
        operationStore: store,
        operationDelay: { _ in }
    )

    await model.recoverPendingOperations()
    for _ in 0..<20 where model.lifecycleState(for: "open/model-8b")?.operation?.state != .succeeded
    {
        await Task.yield()
    }

    #expect(await runtime.operationListCalls == 1)
    #expect(await runtime.installKeys.isEmpty)
    #expect(await runtime.polledOperationIDs == [operationID])
    #expect(model.lifecycleState(for: "open/model-8b")?.operation?.state == .succeeded)
    #expect(store.storedRecords.isEmpty)
}

@MainActor
@Test func notificationOperationFocusFindsItsModelRecoveryRecord() {
    let operationID = UUID(uuidString: "73e82da2-7fb7-4b4b-9584-4a528000ac94")!
    let record = ModelOperationRecoveryRecord(
        targetID: "node:spark-a",
        modelID: "open/model-8b",
        action: .install,
        idempotencyKey: UUID(),
        operationID: operationID
    )
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: DashboardTestFakeRuntimeReader(),
        targetID: "node:spark-a",
        operationStore: DashboardTestTestOperationStore(records: [record])
    )

    model.requestOperationFocus(SparkOperationID(rawValue: operationID))

    #expect(model.requestedModelID == "open/model-8b")
}

@MainActor
@Test func relaunchImmediatelyRendersDurableInstallStageAndHonestProgress() async throws {
    let operationID = UUID(uuidString: "63e82da2-7fb7-4b4b-9584-4a528000ac94")!
    let record = ModelOperationRecoveryRecord(
        targetID: "node:spark-a",
        modelID: "open/model-8b",
        action: .install,
        idempotencyKey: UUID(),
        operationID: operationID
    )
    let running = try dashboardTestLifecycleOperation(
        kind: "model.install",
        state: "running",
        progress: 0.5,
        stage: "downloading"
    )
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: DashboardTestLifecycleRuntime(listedOperations: [running]),
        targetID: "node:spark-a",
        operationStore: DashboardTestTestOperationStore(records: [record]),
        operationDelay: { _ in try await Task.sleep(for: .seconds(60)) }
    )

    await model.recoverPendingOperations()

    let state = try #require(model.lifecycleState(for: "open/model-8b"))
    #expect(state.operation?.stage == "downloading")
    #expect(state.operation.flatMap(SparkDashboardOwnerPresentation.determinateProgress) == 0.5)
    #expect(
        state.progressAccessibilityLabel(modelName: "Model 8B")
            == "Model 8B, Downloading, 50 percent"
    )
    model.stopMonitoring()
}

@MainActor
@Test func resumedUnmeasuredInstallStageNeverInventsAPercentage() async throws {
    let operationID = UUID(uuidString: "63e82da2-7fb7-4b4b-9584-4a528000ac94")!
    let record = ModelOperationRecoveryRecord(
        targetID: "node:spark-a",
        modelID: "open/model-8b",
        action: .install,
        idempotencyKey: UUID(),
        operationID: operationID
    )
    let materialising = try dashboardTestLifecycleOperation(
        kind: "model.install",
        state: "running",
        progress: nil,
        stage: "materialising"
    )
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: DashboardTestLifecycleRuntime(listedOperations: [materialising]),
        targetID: "node:spark-a",
        operationStore: DashboardTestTestOperationStore(records: [record]),
        operationDelay: { _ in try await Task.sleep(for: .seconds(60)) }
    )

    await model.recoverPendingOperations()

    let state = try #require(model.lifecycleState(for: "open/model-8b"))
    #expect(state.operation?.stage == "materialising")
    #expect(state.operation.flatMap(SparkDashboardOwnerPresentation.determinateProgress) == nil)
    #expect(
        state.progressAccessibilityLabel(modelName: "Model 8B")
            == "Model 8B, Finishing the download"
    )
    model.stopMonitoring()
}

@MainActor
@Test func recoveryRecordsStayBoundToTheirStableTarget() async throws {
    let operationID = UUID(uuidString: "63e82da2-7fb7-4b4b-9584-4a528000ac94")!
    let own = ModelOperationRecoveryRecord(
        targetID: "node:spark-a",
        modelID: "open/model-a",
        action: .install,
        idempotencyKey: UUID(),
        retryRequest: ModelOperationRetryRequest(
            acceptedPreviewDigest: String(repeating: "a", count: 64)
        )
    )
    let other = ModelOperationRecoveryRecord(
        targetID: "node:spark-b",
        modelID: "open/model-b",
        action: .load,
        idempotencyKey: UUID(),
        operationID: operationID
    )
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: DashboardTestLifecycleRuntime(),
        targetID: "node:spark-a",
        operationStore: DashboardTestTestOperationStore(records: [own, other]),
        operationDelay: { _ in }
    )

    await model.recoverPendingOperations()

    #expect(model.lifecycleState(for: "open/model-a")?.recoveryAction == .retryIncompleteOperation)
    #expect(model.lifecycleState(for: "open/model-b") == nil)
}

@MainActor
@Test func offlineRelaunchStillPresentsTheSavedRecoveryAction() async throws {
    let record = ModelOperationRecoveryRecord(
        targetID: "node:spark-a",
        modelID: "open/model-8b",
        action: .install,
        idempotencyKey: UUID(),
        retryRequest: ModelOperationRetryRequest(recipeRevision: "r1")
    )
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: DashboardTestLifecycleRuntime(failReads: true),
        targetID: "node:spark-a",
        operationStore: DashboardTestTestOperationStore(records: [record]),
        operationDelay: { _ in }
    )

    await model.refresh()

    #expect(model.errorMessage != nil)
    #expect(model.lifecycleState(for: "open/model-8b")?.recoveryAction == .refreshPreview)
    #expect(model.unlistedModelIDsNeedingRecovery == ["open/model-8b"])
}

@MainActor
@Test func serverErrorKeepsTheRecoveryRecordAndStableKey() async throws {
    let store = DashboardTestTestOperationStore()
    let runtime = DashboardTestLifecycleRuntime(
        installAPIError: APIError(.local(message: "server response was lost"), statusCode: 500)
    )
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        targetID: "node:spark-a",
        operationStore: store,
        operationDelay: { _ in }
    )

    await model.prepareInstall(modelID: "open/model-8b")
    await model.applyConfirmation()
    let savedKey = try #require(store.storedRecords.first?.idempotencyKey)
    #expect(model.lifecycleState(for: "open/model-8b")?.recoveryAction == .retryIncompleteOperation)

    await model.retryIncompleteOperation(modelID: "open/model-8b")

    #expect(await runtime.installKeys == [savedKey, savedKey])
    #expect(model.lifecycleState(for: "open/model-8b")?.operation?.state == .succeeded)
    #expect(store.storedRecords.isEmpty)
}

@MainActor
@Test func failedOperationIDSaveLeavesAReplayableKeyOnlyRecord() async throws {
    let store = DashboardTestTestOperationStore(failAttachedSave: true)
    let firstRuntime = DashboardTestLifecycleRuntime(failOperationPolling: true)
    let firstModel = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: firstRuntime,
        targetID: "node:spark-a",
        operationStore: store,
        operationDelay: { _ in }
    )

    await firstModel.prepareInstall(modelID: "open/model-8b")
    await firstModel.applyConfirmation()

    let keyOnlyRecord = try #require(store.storedRecords.first)
    #expect(keyOnlyRecord.operationID == nil)
    #expect(
        firstModel.lifecycleState(for: "open/model-8b")?.recoveryAction
            == .retryIncompleteOperation
    )

    store.failAttachedSave = false
    let relaunchedRuntime = DashboardTestLifecycleRuntime()
    let relaunchedModel = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: relaunchedRuntime,
        targetID: "node:spark-a",
        operationStore: store,
        operationDelay: { _ in }
    )
    await relaunchedModel.recoverPendingOperations()
    await relaunchedModel.retryIncompleteOperation(modelID: "open/model-8b")

    #expect(await firstRuntime.installKeys == [keyOnlyRecord.idempotencyKey])
    #expect(await relaunchedRuntime.installKeys == [keyOnlyRecord.idempotencyKey])
    #expect(store.storedRecords.isEmpty)
}

@MainActor
@Test func userDefaultsRecoveryStoreCanBeReopened() throws {
    let suiteName = "SparkDashboardModelTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let original = ModelOperationRecoveryRecord(
        targetID: "node:spark-a",
        modelID: "open/model-8b",
        action: .remove,
        idempotencyKey: UUID(),
        operationID: UUID(),
        retryRequest: ModelOperationRetryRequest(
            acceptedPreviewDigest: String(repeating: "a", count: 64)
        )
    )

    try UserDefaultsModelOperationRecoveryStore(defaults: defaults).save(original)
    let reopened = UserDefaultsModelOperationRecoveryStore(defaults: defaults)

    #expect(try reopened.records(for: "node:spark-a") == [original])
}

/// Regression: dashboard refresh must not replace live download progress with a reconnect notice.
@MainActor
@Test func aRefreshDoesNotStampReconnectOverADownloadThatIsBeingWatched() async throws {
    let operationID = UUID(uuidString: "7c0e2a44-2b0c-4a4d-9f1a-3b6a5f0d1e21")!
    let record = ModelOperationRecoveryRecord(
        targetID: "node:spark-a",
        modelID: "nvidia/nemotron-lightning",
        action: .install,
        idempotencyKey: UUID(),
        operationID: operationID
    )
    let running = try dashboardTestLifecycleOperation(
        kind: "model.install",
        state: "running",
        progress: 0.01,
        stage: "downloading"
    )
    let store = DashboardTestTestOperationStore(records: [record])
    let runtime = DashboardTestLifecycleRuntime(
        operationResponses: Array(repeating: running, count: 200),
        listedOperations: [running]
    )
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        targetID: "node:spark-a",
        operationStore: store,
        operationDelay: { _ in try await Task.sleep(for: .milliseconds(20)) }
    )
    await model.recoverPendingOperations()
    for _ in 0..<20
    where model.lifecycleState(for: "nvidia/nemotron-lightning")?.operation?.state != .running {
        await Task.yield()
    }
    #expect(model.lifecycleState(for: "nvidia/nemotron-lightning")?.operation?.state == .running)

    // What every dashboard refresh does first, while the monitor is still polling.
    await model.recoverPendingOperations(queryRuntime: false)

    let state = model.lifecycleState(for: "nvidia/nemotron-lightning")
    #expect(state?.errorMessage == nil, "the live download keeps its progress, no reconnect notice")
    #expect(state?.recoveryAction == nil)
    #expect(state?.operation?.progress == 0.01)
}
