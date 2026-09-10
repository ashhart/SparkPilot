import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing
@testable import SparkAppComposition

@MainActor
@Test func gatedDownloadUsesTheSelectedCredentialForPreviewAndApply() async throws {
    let credentialID = "63e82da2-7fb7-4b4b-9584-4a528000ac94"
    let runtime = DashboardTestLifecycleRuntime()
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        operationStore: DashboardTestTestOperationStore(),
        operationDelay: { _ in }
    )

    await model.prepareInstall(
        modelID: "open/model-8b",
        providerCredentialID: credentialID
    )

    #expect(await runtime.lastInstallPreviewRequest?.providerCredentialId == credentialID)
    let confirmation = try #require(model.pendingConfirmation)
    #expect(confirmation.retryRequest.providerCredentialID == credentialID)
    #expect(await runtime.installKeys.isEmpty)
    await model.applyConfirmation()
    #expect(await runtime.installRequests.first?.providerCredentialId == credentialID)
}

@MainActor
@Test func blockedPreviewDisablesApplyAndSendsNoMutation() async throws {
    let runtime = DashboardTestLifecycleRuntime(previewHasBlocker: true)
    let store = DashboardTestTestOperationStore()
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        operationStore: store,
        operationDelay: { _ in }
    )

    await model.prepareInstall(modelID: "open/model-8b")

    let confirmation = try #require(model.pendingConfirmation)
    #expect(!confirmation.canApply)
    #expect(confirmation.preview.blockers.first?.ownerExplanation.contains("storage") == true)
    await model.applyConfirmation()
    #expect(await runtime.installKeys.isEmpty)
    #expect(store.storedRecords.isEmpty)
}

@MainActor
@Test func ownerPresentationSummarisesClusterDatesReinstallAndActiveReservation() throws {
    let nodeID = "123e4567-e89b-42d3-a456-426614174000"
    let members =
        """
        [{"node_id":"\(nodeID)","role":"leader","reachable":true,"reachability_source":"runtime_cache"}]
        """
    let activeEngine =
        """
        {"state":"ready","model_id":"open/other","profile_id":"balanced","recipe_revision":"r1","source_revision":"s1","recipe_digest":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","signature_key_id":"key-1","active_requests":2,"reserved_memory_bytes":12000000000}
        """
    let preview = try lifecyclePreview(
        action: "remove",
        clusterMembers: members,
        reinstallRequired: true,
        activeEngine: activeEngine
    )
    let confirmation = ModelActionConfirmation(
        idempotencyKey: UUID(),
        modelID: "open/model-8b",
        lifecycleAction: .remove,
        retryRequest: ModelOperationRetryRequest(
            acceptedPreviewDigest: preview.previewDigest
        ),
        preview: preview
    )

    #expect(confirmation.clusterSummary == "1 of 1 ready · 1 leader, 0 workers")
    #expect(confirmation.clusterSummary?.contains(nodeID) == false)
    #expect(confirmation.evidenceDateText != preview.evidenceTimestamps.systemObservedAt)
    #expect(confirmation.expiryDateText != preview.expiresAt)
    #expect(confirmation.reinstallSummary?.contains("downloaded again") == true)
    #expect(preview.evidence.activeEngine?.reservedMemoryBytes == 12_000_000_000)
}

@Test func previewProgressAndRecoveryActionsHaveOwnerFacingAccessibilityLabels() throws {
    let preview = try lifecyclePreview(action: "load")
    let confirmation = ModelActionConfirmation(
        idempotencyKey: UUID(),
        modelID: "open/model-8b",
        lifecycleAction: .load,
        retryRequest: ModelOperationRetryRequest(
            acceptedPreviewDigest: preview.previewDigest
        ),
        preview: preview
    )
    let lifecycle = ModelLifecycleState(
        action: .load,
        operation: try dashboardTestLifecycleOperation(
            kind: "model.load",
            state: "running",
            progress: 0.42,
            stage: "health_check"
        ),
        errorMessage: nil,
        recoveryAction: .retryStatus
    )

    #expect(confirmation.applyAccessibilityLabel == "Apply model start")
    #expect(confirmation.cancelAccessibilityLabel == "Cancel this model action review")
    #expect(
        lifecycle.progressAccessibilityLabel(modelName: "Compact 8B")
            == "Compact 8B, Loading the model, 42 percent"
    )
    #expect(
        ModelOperationRecoveryAction.retryStatus.accessibilityLabel(modelName: "Compact 8B")
            == "Check operation status for Compact 8B"
    )
    #expect(
        ModelOperationRecoveryAction.retryIncompleteOperation.accessibilityLabel(
            modelName: "Compact 8B"
        ) == "Retry the unfinished action for Compact 8B"
    )
    #expect(
        ModelOperationRecoveryAction.refreshPreview.accessibilityLabel(modelName: "Compact 8B")
            == "Review the action for Compact 8B again"
    )
    #expect(
        ModelOperationRecoveryAction.retryTerminalFailure.accessibilityLabel(
            modelName: "Compact 8B"
        ) == "Retry the failed action for Compact 8B"
    )
}

@Test func dashboardUsesPlainLanguageForTheModelService() {
    #expect(SparkDashboardOwnerPresentation.overviewTitle == "Overview")
    #expect(
        SparkDashboardOwnerPresentation.overviewSubtitle
            == "Health, models and services on this DGX Spark."
    )
    #expect(SparkDashboardOwnerPresentation.modelServiceTitle == "Model service")
    #expect(!SparkDashboardOwnerPresentation.modelServiceTitle.lowercased().contains("vllm"))

    let modelJSON =
        """
        {
          "items": [{
            "id": "open/model-8b",
            "display_name": "Compact 8B",
            "description": null,
            "recipe_revision": "r1",
            "source_revision": "s1",
            "install_state": "installed",
            "total_bytes": 8000000000,
            "capabilities": {"chat": true},
            "fit": "ready",
            "profiles": []
          }],
          "next_cursor": null
        }
        """
    let models = try? JSONDecoder().decode(
        ModelCatalogue.self,
        from: Data(modelJSON.utf8)
    ).items

    #expect(
        SparkDashboardOwnerPresentation.activeModelDetail(
            activeModelID: "open/model-8b",
            models: models ?? []
        ) == "Compact 8B"
    )
    #expect(
        SparkDashboardOwnerPresentation.activeModelDetail(
            activeModelID: "open/unlisted-model",
            models: models ?? []
        ) == "A model is active"
    )
    #expect(
        SparkDashboardOwnerPresentation.activeModelDetail(activeModelID: nil, models: models ?? [])
            == "No active model"
    )
}

@Test func unfinishedActionsDoNotExposeMachineModelIdentifiers() {
    let modelID = "open/model-8b"
    for action in [
        ModelLifecycleAction.install,
        .load,
        .unload,
        .remove,
    ] {
        let title = SparkDashboardOwnerPresentation.unfinishedActionTitle(action)
        #expect(!title.localizedCaseInsensitiveContains(modelID))
        #expect(!title.isEmpty)
    }
}

@Test func dashboardRequiresAnActionableRuntimeUpdateNotice() throws {
    let notice = try #require(
        SparkDashboardOwnerPresentation.runtimeUpdateNotice(canInstallBundledRuntime: true)
    )

    #expect(notice.title == "Runtime update required")
    #expect(notice.actionTitle == "Update Spark")
    #expect(
        SparkDashboardOwnerPresentation.runtimeUpdateNotice(canInstallBundledRuntime: false) == nil
    )
}

/// Translate the runtime's emergency pressure level into descriptive owner-facing copy.
@Test func memoryPressureReadsAsPressureNotAnAlarm() {
    #expect(SparkTelemetryPresentation.memoryPressureWord("normal") == "Normal")
    #expect(SparkTelemetryPresentation.memoryPressureWord("warning") == "Elevated")
    #expect(SparkTelemetryPresentation.memoryPressureWord("critical") == "High")
    #expect(SparkTelemetryPresentation.memoryPressureWord("emergency") == "Very high")
    #expect(SparkTelemetryPresentation.memoryPressureWord("") == "Unreported")
    #expect(
        !SparkTelemetryPresentation.memoryPressureWord("emergency")
            .lowercased()
            .contains("emergency")
    )
}

/// Explain that only the owner can perform a safety review.
@Test func refusedSafetyReviewSaysWhoCanDoIt() {
    let forbidden = SparkDashboardModel.profileReenableFailureMessage(
        APIError(.reported, statusCode: 403, code: "ROLE_FORBIDDEN", diagnosticDetail: "HTTP 403")
    )
    #expect(forbidden.contains("owner"))
    #expect(!forbidden.contains("403"))

    let bare = SparkDashboardModel.profileReenableFailureMessage(
        APIError(.unexpectedStatus, statusCode: 403, diagnosticDetail: "HTTP 403")
    )
    #expect(!bare.contains("HTTP 403"))

    let explained = SparkDashboardModel.profileReenableFailureMessage(
        APIError(
            .reported,
            statusCode: 409,
            code: "CONFLICT",
            diagnosticDetail: "The profile was re-enabled already."
        )
    )
    #expect(explained.contains("CONFLICT"))
    #expect(!explained.contains("re-enabled already"))
}

func dashboardTestPresentationConfirmation(
    _ preview: GeneratedAPI.ModelActionPreview
) -> ModelActionConfirmation {
    ModelActionConfirmation(
        idempotencyKey: UUID(),
        modelID: "open/model-8b",
        lifecycleAction: .load,
        retryRequest: ModelOperationRetryRequest(acceptedPreviewDigest: preview.previewDigest),
        preview: preview
    )
}

@Test func modelPreviewShowsTheMemoryDeficitInsteadOfZeroHeadroom() throws {
    var preview = try lifecyclePreview(action: "load", blocked: true)
    preview.evidence.requiredMemoryBytes = 110_000_000_000
    preview.evidence.availableMemoryBytes = 123_890_000_000
    preview.evidence.systemReserveBytes = 23_622_320_128
    preview.evidence.expectedMemoryHeadroomBytes = 0
    let confirmation = dashboardTestPresentationConfirmation(preview)
    #expect(confirmation.memoryBalanceLabel == "Memory shortfall")
    #expect(confirmation.memoryBalanceBytes == 9_732_320_128)
    #expect(!confirmation.canApply)
    #expect(confirmation.preview == preview)

    preview.evidence.requiredMemoryBytes = 96_945_270_784
    preview.evidence.expectedMemoryHeadroomBytes = 3_322_409_088
    #expect(
        dashboardTestPresentationConfirmation(preview).memoryBalanceLabel == "Expected headroom"
    )
    #expect(dashboardTestPresentationConfirmation(preview).memoryBalanceBytes == 3_322_409_088)

    preview.evidence.systemReserveBytes = nil
    preview.evidence.expectedMemoryHeadroomBytes = nil
    #expect(dashboardTestPresentationConfirmation(preview).memoryBalanceBytes == nil)
}

@Test(arguments: [
    "2026-08-28T12:00:00Z",
    "2026-08-28T12:00:00.123Z",
    "2026-08-28T12:00:00.123456789Z",
    "2026-08-28T13:00:00.123456789+01:00",
])
func modelPreviewPresentsFractionalRuntimeEvidenceAndExpiryDates(timestamp: String) throws {
    var preview = try lifecyclePreview(action: "load")
    preview.evidenceTimestamps.systemObservedAt = timestamp
    preview.expiresAt = timestamp.replacingOccurrences(of: ":00:00", with: ":05:00")
    let confirmation = dashboardTestPresentationConfirmation(preview)
    let evidence = Date(timeIntervalSince1970: 1_787_918_400)
    #expect(
        confirmation.evidenceDateText == evidence.formatted(date: .abbreviated, time: .shortened)
    )
    #expect(
        confirmation.expiryDateText
            == evidence.addingTimeInterval(300).formatted(date: .abbreviated, time: .shortened)
    )
}

@Test func modelPreviewPreservesUnavailableDatesForMalformedEvidence() throws {
    var preview = try lifecyclePreview(action: "load")
    preview.evidenceTimestamps.systemObservedAt = "not a timestamp"
    preview.expiresAt = "2026-08-28T12:05:00"
    let confirmation = dashboardTestPresentationConfirmation(preview)
    #expect(confirmation.evidenceDateText == "Time unavailable")
    #expect(confirmation.expiryDateText == "Time unavailable")
}

@Test func singleSparkPreviewOmitsEmptyStandaloneClusterSummary() throws {
    var preview = try lifecyclePreview(action: "load")
    #expect(dashboardTestPresentationConfirmation(preview).clusterSummary == nil)
    preview.evidence.cluster = nil
    #expect(dashboardTestPresentationConfirmation(preview).clusterSummary == nil)
}

@Test func clusterTargetWithMissingMembersRemainsVisibleForReview() throws {
    var preview = try lifecyclePreview(action: "load")
    preview.target.clusterId = "123e4567-e89b-42d3-a456-426614174000"
    preview.evidence.cluster?.clusterId = preview.target.clusterId
    preview.evidence.cluster?.state = "forming"
    #expect(dashboardTestPresentationConfirmation(preview).clusterSummary != nil)
}

/// ADR-043: the review names the parts behind the reservation and what would fit right now.
@Test func modelPreviewBreaksTheReservationDownAndNamesTheLargestContextThatFitsNow() throws {
    var preview = try lifecyclePreview(action: "load", blocked: false)
    preview.evidence.requiredMemoryBytes = 45_877_489_664
    preview.evidence.weightBytes = 24_000_000_000
    preview.evidence.kvCacheBytes = 12_884_901_888
    preview.evidence.stateBytes = 402_653_184
    preview.evidence.engineOverheadBytes = 8_589_934_592
    preview.evidence.maxContextNow = 1_048_576
    preview.evidence.maxSequencesNow = 64
    let profile = try JSONDecoder().decode(
        SparkModelProfile.self,
        from: Data(
            #"{"id":"agent-256k","display_name":"Agent 256K · 16 requests","max_model_length":262144,"max_sequences":16,"expected_peak_bytes":45877489664,"measured_peak_bytes":null,"safe":true}"#
                .utf8
        )
    )
    let confirmation = ModelActionConfirmation(
        idempotencyKey: UUID(),
        modelID: "nvidia/nemotron-3.5-lightning-30b-a3b-nvfp4",
        lifecycleAction: .load,
        retryRequest: ModelOperationRetryRequest(acceptedPreviewDigest: preview.previewDigest),
        preview: preview,
        profile: profile
    )
    #expect(confirmation.contextCacheBytes == 13_287_555_072)
    #expect(confirmation.contextCacheDetail == "262,144 tokens × 16 requests")
    #expect(
        confirmation.largestContextNowLine
            == "Largest context that fits now: 1,048,576 tokens at 64 requests"
    )

    // Without the preset the cache row stands alone, and an older Spark reports no breakdown at all.
    let unnamed = dashboardTestPresentationConfirmation(preview)
    #expect(unnamed.contextCacheBytes == 13_287_555_072)
    #expect(unnamed.contextCacheDetail == nil)
    preview.evidence.kvCacheBytes = nil
    preview.evidence.maxContextNow = nil
    let older = dashboardTestPresentationConfirmation(preview)
    #expect(older.contextCacheBytes == nil)
    #expect(older.contextCacheDetail == nil)
    #expect(older.largestContextNowLine == nil)
}
