import CryptoKit
import Foundation
@_spi(SparkTestSupport) import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
@_spi(SparkTestSupport) import SparkTransport
import Testing
@testable import SparkAppComposition

actor ExternalClusterTestManagedRecoveryOrderRecorder {
    private var events: [String] = []

    func record(_ event: String) { events.append(event) }
    func recordedEvents() -> [String] { events }
}

@MainActor
final class ExternalClusterTestManagedRecoveryLoaderFixture: VerifiedSingleNodeModelLoading {
    private let recorder: ExternalClusterTestManagedRecoveryOrderRecorder
    private(set) var pendingConfirmation: ModelActionConfirmation?
    private(set) var receivedModelID: String?
    private(set) var receivedProfileID: String?
    private(set) var receivedRecipeRevision: String?

    init(recorder: ExternalClusterTestManagedRecoveryOrderRecorder) throws {
        self.recorder = recorder
        pendingConfirmation = try externalClusterTestManagedRecoveryConfirmation()
    }

    func prepareVerifiedLoad(
        modelID: String,
        profileID: String,
        expectedRecipeRevision: String,
        targetNodeID: String,
        targetClusterID: String?
    ) async -> Bool {
        await recorder.record("preview")
        receivedModelID = modelID
        receivedProfileID = profileID
        receivedRecipeRevision = expectedRecipeRevision
        return pendingConfirmation != nil
    }

    func applyPreparedLoad() async -> Bool {
        await recorder.record("apply")
        pendingConfirmation = nil
        return true
    }

    func cancelPreparedLoad() {
        pendingConfirmation = nil
    }
}

func externalClusterTestManagedRecoveryConfirmation() throws -> ModelActionConfirmation {
    let preview = try JSONDecoder().decode(
        GeneratedAPI.ModelActionPreview.self,
        from: Data(
            #"{"preview_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","action":"load","target":{"node_id":"00000000-0000-4000-8000-000000000001","cluster_id":"00000000-0000-4000-8000-000000000099"},"recipe":null,"evidence":{"download_bytes":null,"locally_reusable_bytes":null,"required_disk_bytes":null,"disk_free_bytes":null,"expected_disk_free_after_bytes":null,"required_memory_bytes":1,"available_memory_bytes":2,"expected_memory_headroom_bytes":1,"profile_failure_code":null,"active_inference_available":true,"engine_transitioning":false,"active_engine":null,"cluster_membership_available":true,"cluster":{"cluster_id":"00000000-0000-4000-8000-000000000099","state":"degraded","members":[]}},"evidence_timestamps":{"system_observed_at":"2026-09-01T12:00:00Z"},"consequences":{"model_to_stop":null,"profile_to_stop":null,"route_withdrawal":false,"service_interruption":"none","files_removed":[],"reinstall_required":false},"blockers":[],"warnings":[],"issued_at":"2026-09-01T12:00:00Z","expires_at":"2026-09-01T12:05:00Z"}"#
                .utf8
        )
    )
    return ModelActionConfirmation(
        idempotencyKey: UUID(uuidString: "00000000-0000-4000-8000-000000000077")!,
        modelID: "verified-recipe",
        lifecycleAction: .load,
        retryRequest: ModelOperationRetryRequest(
            profileID: "safe-profile",
            acceptedPreviewDigest: preview.previewDigest
        ),
        preview: preview
    )
}

enum ExternalClusterTestManagedTransactionTestError: Error {
    case malformedRequest
    case scriptedFailure
}
