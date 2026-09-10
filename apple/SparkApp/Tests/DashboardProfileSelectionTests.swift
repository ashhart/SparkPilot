import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing
@testable import SparkAppComposition

@MainActor
@Test func multiProfileStartWaitsForTheOwnersExplicitChoice() async throws {
    let runtime = DashboardTestLifecycleRuntime(multipleProfiles: true)
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
    #expect(model.pendingConfirmation == nil)
}

@MainActor
@Test(arguments: ["balanced", "long"])
func chosenProfileLimitsDriveBothPreviewAndAppliedLoad(profileID: String) async throws {
    let runtime = DashboardTestLifecycleRuntime(multipleProfiles: true)
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        operationStore: DashboardTestTestOperationStore(),
        operationDelay: { _ in }
    )
    await model.refresh()
    await model.prepareLoad(modelID: "open/model-8b", replaceActive: false)
    let choice = try #require(model.pendingLoadConfiguration)
    #expect(choice.profiles.contains { $0.id == "unsafe" && !$0.safe })
    await model.previewLoadConfiguration(profileID: profileID)
    let confirmation = try #require(model.pendingConfirmation)
    let previewCall = try #require(await runtime.loadPreviewCalls.first)
    #expect(previewCall.0.profileId == profileID)
    #expect(confirmation.retryRequest.profileID == profileID)
    #expect(confirmation.profile?.maxModelLength == (profileID == "long" ? 262_144 : 32_768))
    #expect(confirmation.profile?.maxSequences == (profileID == "long" ? 2 : 4))
    #expect(model.pendingLoadConfiguration == nil)
    #expect(await runtime.loadCalls.isEmpty)
    await model.applyConfirmation()
    let applied = try #require(await runtime.loadCalls.first)
    #expect(applied.0.profileId == profileID)
    #expect(applied.1 == previewCall.1)
    #expect(applied.0.acceptedPreviewDigest == confirmation.preview.previewDigest)
}

@MainActor
@Test func unavailableAndUnknownProfileChoicesCannotRequestAPreview() async throws {
    let runtime = DashboardTestLifecycleRuntime(multipleProfiles: true)
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        operationStore: DashboardTestTestOperationStore(),
        operationDelay: { _ in }
    )
    await model.refresh()
    await model.prepareLoad(modelID: "open/model-8b", replaceActive: false)
    for profileID in ["unsafe", "missing"] {
        await model.previewLoadConfiguration(profileID: profileID)
        await model.prepareLoad(
            modelID: "open/model-8b",
            replaceActive: false,
            profileID: profileID
        )
    }
    #expect(await runtime.loadPreviewCalls.isEmpty)
    #expect(await runtime.loadCalls.isEmpty)
    #expect(model.pendingConfirmation == nil)
}

@MainActor
@Test func staleReviewKeepsTheChosenProfileWhenRequestingFreshEvidence() async throws {
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
    await model.refresh()
    await model.prepareLoad(modelID: "open/model-8b", replaceActive: false)
    await model.previewLoadConfiguration(profileID: "balanced")
    await model.applyConfirmation()
    #expect(model.lifecycleState(for: "open/model-8b")?.recoveryAction == .refreshPreview)
    await model.refreshPreview(modelID: "open/model-8b")
    #expect(await runtime.loadPreviewCalls.map { $0.0.profileId } == ["balanced", "balanced"])
    #expect(model.pendingConfirmation?.profile?.id == "balanced")
}

@MainActor
@Test func changingProfileRequiresAnotherPreviewBeforeApplying() async throws {
    let runtime = DashboardTestLifecycleRuntime(multipleProfiles: true)
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        operationStore: DashboardTestTestOperationStore(),
        operationDelay: { _ in }
    )
    await model.refresh()
    await model.prepareLoad(modelID: "open/model-8b", replaceActive: false)
    await model.previewLoadConfiguration(profileID: "balanced")
    let first = try #require(model.pendingConfirmation)
    await model.changeLoadProfile()
    #expect(model.pendingConfirmation == nil)
    #expect(model.pendingLoadConfiguration != nil)
    await model.applyConfirmation()
    #expect(await runtime.loadCalls.isEmpty)
    await model.previewLoadConfiguration(profileID: "long")
    let changed = try #require(model.pendingConfirmation)
    #expect(changed.idempotencyKey != first.idempotencyKey)
    #expect(changed.profile?.id == "long")
    await model.applyConfirmation()
    #expect(await runtime.loadCalls.first?.0.profileId == "long")
}

@MainActor
@Test func cancelledProfilePreviewCannotReplaceANewerChoice() async throws {
    let runtime = DashboardTestLifecycleRuntime(multipleProfiles: true, holdNextLoadPreview: true)
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        operationStore: DashboardTestTestOperationStore(),
        operationDelay: { _ in }
    )
    await model.refresh()
    await model.prepareLoad(modelID: "open/model-8b", replaceActive: false)
    let stale = Task { await model.previewLoadConfiguration(profileID: "long") }
    while !(await runtime.hasPendingLoadPreview()) { await Task.yield() }
    model.cancelConfirmation()
    await model.prepareLoad(modelID: "open/model-8b", replaceActive: false, profileID: "balanced")
    let current = try #require(model.pendingConfirmation)
    await runtime.finishLoadPreview()
    await stale.value
    #expect(model.pendingConfirmation?.id == current.id)
    #expect(model.pendingConfirmation?.profile?.id == "balanced")
    #expect(!model.isPreparingConfirmation)
    #expect(await runtime.loadCalls.isEmpty)
}

@MainActor
@Test func cancelledModelLoadRetryUsesANewPreviewAndSubmissionKey() async throws {
    let runtime = DashboardTestLifecycleRuntime(
        loadResponses: [
            try dashboardTestLifecycleOperation(
                kind: "model.load",
                state: "failed",
                progress: nil,
                errorCode: "OPERATION_CANCELLED"
            ),
            try dashboardTestLifecycleOperation(
                kind: "model.load",
                state: "succeeded",
                progress: 1
            ),
        ]
    )
    let store = DashboardTestTestOperationStore()
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        operationStore: store,
        operationDelay: { _ in }
    )
    await model.refresh()
    await model.prepareLoad(modelID: "open/model-8b", replaceActive: false)
    let firstKey = try #require(model.pendingConfirmation?.idempotencyKey)
    await model.applyConfirmation()
    #expect(model.lifecycleState(for: "open/model-8b")?.technicalErrorCode == "OPERATION_CANCELLED")
    #expect(model.lifecycleState(for: "open/model-8b")?.recoveryAction == .retryTerminalFailure)
    #expect(try store.records(for: model.targetID).isEmpty)

    await model.refreshPreview(modelID: "open/model-8b")
    let secondKey = try #require(model.pendingConfirmation?.idempotencyKey)
    #expect(secondKey != firstKey)
    #expect(await runtime.loadCalls.count == 1)
    await model.applyConfirmation()

    #expect(await runtime.loadPreviewCalls.map { $0.1 } == [firstKey, secondKey])
    #expect(await runtime.loadCalls.map { $0.1 } == [firstKey, secondKey])
    #expect(model.lifecycleState(for: "open/model-8b")?.operation?.state == .succeeded)
    #expect(model.lifecycleState(for: "open/model-8b")?.errorMessage == nil)
    #expect(try store.records(for: model.targetID).isEmpty)
}

@MainActor
@Test func dismissingTheReviewAndStoppingMonitorsDoesNotCancelAnAppliedLoad() async throws {
    let runtime = DashboardTestLifecycleRuntime(holdNextLoadApply: true)
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        operationStore: DashboardTestTestOperationStore(),
        operationDelay: { _ in }
    )
    await model.refresh()
    await model.prepareLoad(modelID: "open/model-8b", replaceActive: false)
    let key = try #require(model.pendingConfirmation?.idempotencyKey)
    let apply = Task { await model.applyConfirmation() }
    for _ in 0..<2_000 {
        if await runtime.hasPendingLoadApply() { break }
        await Task.yield()
    }
    #expect(await runtime.hasPendingLoadApply())
    model.cancelConfirmation()
    model.stopMonitoring()
    #expect(model.pendingConfirmation == nil)
    await runtime.finishLoadApply()
    await apply.value

    #expect(await runtime.loadCalls.map { $0.1 } == [key])
    #expect(model.lifecycleState(for: "open/model-8b")?.operation?.state == .succeeded)
    #expect(model.lifecycleState(for: "open/model-8b")?.errorMessage == nil)
}

@Test(arguments: [nil, "open/other-model"] as [String?], [false, true]) @MainActor
func signedChatLaunchUsesFreshRuntimeStateAndOnlySafePresets(
    activeModel: String?,
    memoryLimited: Bool
) async throws {
    let node = SparkNodeID(rawValue: UUID(uuidString: "63e82da2-7fb7-4b4b-9584-4a528000ac94")!)
    let route = URL(string: "https://launch-fixture.example:7443")!
    let library = SparkLibrary(store: MemoryLibraryStore())
    library.reconcile(
        AuthenticatedTarget(
            nodeID: node,
            clusterID: nil,
            name: "Fixture Spark",
            role: .standalone,
            authorityFingerprint: "abc",
            displayName: "Fixture Spark",
            routes: [CachedRoute(baseURL: route, kind: .localWiFi)],
            reachedAt: Date()
        )
    )
    let runtime = DashboardTestLifecycleRuntime(
        activeModelID: activeModel,
        multipleProfiles: true,
        memoryLimitedProfiles: memoryLimited ? ["long"] : []
    )
    let target = SparkChatTarget(
        id: SparkTargetIdentity.node(node).description,
        displayName: "Fixture Spark",
        nodeID: node,
        route: route,
        tlsFingerprint: String(repeating: "a", count: 64),
        authorityFingerprint: "abc",
        modelID: "open/model-8b",
        modelName: "Model 8B"
    )
    let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
    let launcher = SignedSparkModelLauncher(
        library: library,
        defaults: defaults,
        runtimeResolver: { _ in
            ModelLibraryRuntimeConnection(
                route: route,
                expectedNodeID: node,
                expectedClusterID: nil,
                expectedAuthorityFingerprint: "abc",
                runtime: runtime
            )
        },
        operationStore: DashboardTestTestOperationStore()
    )
    let plan = try await launcher.prepare(target: target, profileID: nil)
    let request = try #require(await runtime.loadPreviewCalls.last?.0)
    #expect(request.profileId == (memoryLimited ? "balanced" : "long"))
    #expect(request.replaceActive == (activeModel != nil))
    #expect(plan.requiresApproval == (activeModel != nil))
    #expect(await runtime.loadCalls.isEmpty)
    #expect(
        plan.confirmation?.retryRequest.acceptedPreviewDigest
            == plan.confirmation?.preview.previewDigest
    )
    launcher.discard(plan)
    let quickLaunch = SparkQuickLaunchModel(launcher: launcher) { [target] }
    await quickLaunch.refresh()
    #expect(quickLaunch.selectedProfileID == (memoryLimited ? "balanced" : "long"))
    #expect(await runtime.loadCalls.isEmpty)
    if memoryLimited {
        let explicit = try await launcher.prepare(target: target, profileID: "long")
        #expect(explicit.confirmation?.canApply == false)
        #expect(await runtime.loadPreviewCalls.last?.0.profileId == "long")
        launcher.discard(explicit)
    }
}
