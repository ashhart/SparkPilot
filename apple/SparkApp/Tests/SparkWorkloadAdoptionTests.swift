import Foundation
import SparkAPI
import SparkSecurity
import Testing
@testable import SparkAppComposition

private let adoptedWorkloadID = String(repeating: "a", count: 64)

private final class WorkloadPresenceSession: UserPresenceProofSigning, @unchecked Sendable {
    let keyInfo = UserPresenceKeyInfo(publicKeySPKI: Data([1]), protection: .softwareTestOnly)

    func proof(for request: UserPresenceCanonicalRequest) async throws -> UserPresenceProof {
        throw UserPresenceProofError.signingFailed
    }
}

private actor WorkloadPresenceAuthorizer: UserPresenceAuthorizing {
    private var count = 0

    func keyInfo() async throws -> UserPresenceKeyInfo {
        UserPresenceKeyInfo(publicKeySPKI: Data([1]), protection: .softwareTestOnly)
    }

    func authorize(localizedReason: String) async throws -> any UserPresenceProofSigning {
        count += 1
        return WorkloadPresenceSession()
    }

    func authorizationCount() -> Int { count }
}

private actor WorkloadRuntime: SparkRuntimeReading {
    struct AdoptionCall: Equatable, Sendable {
        let workloadID: String
        let modelID: String
        let profileID: String
        let digest: String
    }

    var adoptionPreview = workloadPreview(action: "workload.adopt")
    var relinquishPreview = workloadPreview(action: "workload.relinquish")
    var adoptionError: APIError?
    private(set) var adoptionCalls: [AdoptionCall] = []
    private(set) var relinquished: [String] = []

    func health(route: URL) async throws -> Health { throw PendingRuntimeError.unconfigured }
    func status(route: URL) async throws -> SparkStatus { throw PendingRuntimeError.unconfigured }
    func models(route: URL) async throws -> ModelCatalogue {
        throw PendingRuntimeError.unconfigured
    }
    func activeInference(route: URL) async throws -> ActiveInference {
        throw PendingRuntimeError.unconfigured
    }

    func previewWorkloadAdoption(
        route: URL,
        workloadID: String,
        request: GeneratedAPI.WorkloadAdoptionPreviewRequest,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview {
        adoptionPreview
    }

    func adoptWorkload(
        route: URL,
        workloadID: String,
        request: GeneratedAPI.WorkloadAdoptionRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        if let adoptionError { throw adoptionError }
        adoptionCalls.append(
            AdoptionCall(
                workloadID: workloadID,
                modelID: request.modelId,
                profileID: request.profileId,
                digest: request.acceptedPreviewDigest
            )
        )
        return fixtureOperation(state: "succeeded")
    }

    func previewWorkloadRelinquish(
        route: URL,
        workloadID: String,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview {
        relinquishPreview
    }

    func relinquishWorkload(
        route: URL,
        workloadID: String,
        request: GeneratedAPI.WorkloadRelinquishRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> GeneratedAPI.RelinquishWorkloadResponse200 {
        relinquished.append(workloadID)
        return .init(
            workloadId: workloadID,
            ownership: .externalObserved,
            containerChanged: false
        )
    }

    func calls() -> ([AdoptionCall], [String]) { (adoptionCalls, relinquished) }

    func failAdoption(_ error: APIError) { adoptionError = error }
    func setAdoptionPreview(_ preview: GeneratedAPI.ModelActionPreview) {
        adoptionPreview = preview
    }
}

private func workloadPreview(
    action: String,
    blockers: String = "[]"
) -> GeneratedAPI.ModelActionPreview {
    let digest = String(repeating: "a", count: 64)
    let evidence = String(repeating: "b", count: 64)
    let json = """
        {
          "preview_digest":"\(digest)","action":"\(action)",
          "target":{"node_id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","cluster_id":null},"recipe":null,
          "evidence":{
            "external_workload_id":"\(adoptedWorkloadID)",
            "external_workload_evidence_digest":"\(evidence)",
            "external_workload_healthy":true,
            "active_inference_available":true,"engine_transitioning":false,
            "cluster_membership_available":false,"cluster_membership_source":null,"cluster":null
          },
          "evidence_timestamps":{"system_observed_at":"2026-08-31T12:00:00Z"},
          "consequences":{"model_to_stop":null,"profile_to_stop":null,
            "route_withdrawal":false,"service_interruption":"none",
            "files_removed":[],"reinstall_required":false},
          "blockers":\(blockers),"warnings":[],
          "issued_at":"2026-08-31T12:00:00Z","expires_at":"2026-08-31T12:05:00Z"
        }
        """
    return try! JSONDecoder().decode(
        GeneratedAPI.ModelActionPreview.self,
        from: Data(json.utf8)
    )
}

private func fixtureOperation(state: String) -> SparkAPI.Operation {
    let json = """
        {"id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","kind":"workload.adopt",
         "state":"\(state)","progress":1,"stage":"ready","error_code":null,
         "cancellable":false}
        """
    return try! JSONDecoder().decode(SparkAPI.Operation.self, from: Data(json.utf8))
}

private func installedModel() -> SparkModel {
    let json = """
        {"id":"example/model","display_name":"Example Model","description":null,
         "recipe_revision":"r1","source_revision":"s1","source_provider":"huggingface",
         "gated":false,"install_state":"installed","total_bytes":1024,
         "capabilities":{},"fit":"fits","profiles":[{
           "id":"balanced","display_name":"Balanced","max_model_length":16384,
           "max_sequences":4,"expected_peak_bytes":1024,"measured_peak_bytes":null,
           "safe":true,"idle_policy":null,"supported_idle_policies":null}]}
        """
    return try! JSONDecoder().decode(SparkModel.self, from: Data(json.utf8))
}

@MainActor
@Test func exactAdoptionUsesReviewedRecipeProfileDigestAndFreshPresence() async {
    let runtime = WorkloadRuntime()
    let presence = WorkloadPresenceAuthorizer()
    let model = SparkWorkloadOwnershipModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        userPresenceAuthorizer: presence,
        operationDelay: { _ in }
    )
    let selected = installedModel()

    await model.prepareAdoption(
        workloadID: adoptedWorkloadID,
        workloadName: "existing-vllm",
        model: selected,
        profile: selected.profiles[0]
    )
    #expect(model.pendingConfirmation?.canApply == true)
    #expect(await model.apply())

    let calls = await runtime.calls().0
    #expect(
        calls == [
            .init(
                workloadID: adoptedWorkloadID,
                modelID: "example/model",
                profileID: "balanced",
                digest: String(repeating: "a", count: 64)
            )
        ]
    )
    #expect(await presence.authorizationCount() == 1)
    #expect(model.pendingConfirmation == nil)
}

@MainActor
@Test func blockedAdoptionCannotSendTheOwnershipMutation() async {
    let runtime = WorkloadRuntime()
    await runtime.setAdoptionPreview(
        workloadPreview(
            action: "workload.adopt",
            blockers:
                "[{\"code\":\"ARGUMENTS_MISMATCH\",\"owner_explanation\":\"Arguments differ.\",\"recovery_action\":null}]"
        )
    )
    let selected = installedModel()
    let model = SparkWorkloadOwnershipModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        userPresenceAuthorizer: WorkloadPresenceAuthorizer()
    )

    await model.prepareAdoption(
        workloadID: adoptedWorkloadID,
        workloadName: "spoofed-name",
        model: selected,
        profile: selected.profiles[0]
    )
    #expect(model.pendingConfirmation?.canApply == false)
    #expect(!(await model.apply()))
    #expect(await runtime.calls().0.isEmpty)
}

@MainActor
@Test func stalePreviewKeepsTheWorkloadExternalAndRequiresANewReview() async {
    let runtime = WorkloadRuntime()
    await runtime.failAdoption(
        APIError(.local(message: "stale"), statusCode: 409, code: "PREVIEW_STALE")
    )
    let selected = installedModel()
    let model = SparkWorkloadOwnershipModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        userPresenceAuthorizer: WorkloadPresenceAuthorizer()
    )
    await model.prepareAdoption(
        workloadID: adoptedWorkloadID,
        workloadName: "existing-vllm",
        model: selected,
        profile: selected.profiles[0]
    )

    #expect(!(await model.apply()))
    #expect(model.pendingConfirmation == nil)
    #expect(model.errorMessage?.contains("changed after review") == true)
}

@MainActor
@Test func relinquishRemovesOnlyOwnershipAndNeverReportsAContainerChange() async {
    let runtime = WorkloadRuntime()
    let model = SparkWorkloadOwnershipModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        userPresenceAuthorizer: WorkloadPresenceAuthorizer()
    )

    await model.prepareRelinquish(
        workloadID: adoptedWorkloadID,
        workloadName: "existing-vllm"
    )
    #expect(await model.apply())
    #expect(await runtime.calls().1 == [adoptedWorkloadID])
}
