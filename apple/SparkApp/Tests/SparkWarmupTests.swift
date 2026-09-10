import Foundation
import SparkAPI
import SparkSecurity
import Testing
@testable import SparkAppComposition

private func decodeWarmup<T: Decodable>(_ value: Any, as type: T.Type = T.self) throws -> T {
    try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
}
private let warmupNode = UUID(uuidString: "00000000-0000-4000-8000-000000000020")!
private func warmupRecord(state: String = "pending", code: String = "WARMUP_SCHEDULED") throws
    -> WarmupSchedule
{
    try decodeWarmup([
        "id": "00000000-0000-4000-8000-000000000021", "node_id": warmupNode.uuidString,
        "model_id": "model", "profile_id": "balanced", "due_at": 4_000_000_000,
        "expires_at": 4_000_000_600, "state": state, "result_code": code,
        "operation_id": NSNull(), "created_at": 3_999_999_000, "updated_at": 3_999_999_000,
    ])
}
private func warmupReview(
    _ request: WarmupRequest,
    modelID: String? = nil,
    expires: String = "2099-09-04T12:05:00.123456Z",
    blocked: Bool = false
) throws -> WarmupPreview {
    try decodeWarmup([
        "due_at": request.dueAt, "expires_at": request.dueAt + 600,
        "review": [
            "preview_digest": String(repeating: "a", count: 64), "action": "warmup",
            "target": ["node_id": warmupNode.uuidString, "cluster_id": NSNull()],
            "recipe": [
                "model_id": modelID ?? request.modelID, "recipe_revision": "revision",
                "source_revision": "commit", "recipe_digest": String(repeating: "b", count: 64),
                "signature_key_id": "root", "profile_id": request.profileID,
            ],
            "evidence": [
                "active_inference_available": true, "engine_transitioning": false,
                "cluster_membership_available": true,
            ],
            "evidence_timestamps": ["system_observed_at": "2099-09-04T12:00:00Z"],
            "consequences": [
                "model_to_stop": NSNull(), "profile_to_stop": NSNull(), "route_withdrawal": false,
                "service_interruption": "none", "files_removed": [], "reinstall_required": false,
            ],
            "blockers": blocked
                ? [
                    [
                        "code": "MODEL_PROFILE_UNSAFE", "owner_explanation": "Unsafe profile",
                        "recovery_action": "Review the profile",
                    ]
                ] : [],
            "warnings": [
                [
                    "code": "WARMUP_IDLE_ONLY", "owner_explanation": "Skip when busy.",
                    "recovery_action": NSNull(),
                ]
            ],
            "issued_at": "2099-09-04T12:00:00Z", "expires_at": expires,
        ],
    ])
}

@MainActor private final class WarmupProviderFixture: SparkWarmupProviding {
    var listingError = false
    var responseModelID: String?
    var blocked = false
    var failsFirstCreate = false
    var created: [(WarmupRequest, UUID)] = []
    var disabled: [UUID] = []
    func models() async throws -> [SparkModel] {
        [
            try decodeWarmup([
                "id": "model", "display_name": "My model", "install_state": "installed",
                "capabilities": ["chat": true],
                "profiles": [
                    [
                        "id": "balanced", "display_name": "Balanced", "max_model_length": 32000,
                        "max_sequences": 4, "expected_peak_bytes": 20_000_000_000, "safe": true,
                    ]
                ],
            ])
        ]
    }
    func schedules() async throws -> WarmupCollection {
        if listingError { throw APIError(.local(message: "Forbidden"), code: "ROLE_FORBIDDEN") }
        return try decodeWarmup(["items": [], "max_pending": 8, "observed_at": 3_999_999_000])
    }
    func preview(_ request: WarmupRequest) async throws -> WarmupPreview {
        try warmupReview(request, modelID: responseModelID, blocked: blocked)
    }
    func create(_ request: WarmupRequest, key: UUID, presence: any UserPresenceProofSigning)
        async throws -> WarmupSchedule
    {
        created.append((request, key))
        if failsFirstCreate && created.count == 1 { throw URLError(.networkConnectionLost) }
        return try warmupRecord()
    }
    func disable(_ id: UUID, key: UUID, presence: any UserPresenceProofSigning) async throws
        -> WarmupSchedule
    {
        disabled.append(id)
        return try warmupRecord(state: "disabled", code: "WARMUP_DISABLED_BY_OWNER")
    }
}
private final class WarmupPresenceSession: UserPresenceProofSigning, @unchecked Sendable {
    private let signer = SoftwareSigner()
    lazy var keyInfo = UserPresenceKeyInfo(
        publicKeySPKI: signer.publicKeySPKI,
        protection: .softwareTestOnly
    )
    func proof(for request: UserPresenceCanonicalRequest) async throws -> UserPresenceProof {
        try UserPresenceProof.sign(request) { try signer.sign($0) }
    }
}
private actor WarmupPresenceFixture: UserPresenceAuthorizing {
    private let session = WarmupPresenceSession()
    var requests = 0
    func keyInfo() async throws -> UserPresenceKeyInfo { session.keyInfo }
    func authorize(localizedReason: String) async throws -> any UserPresenceProofSigning {
        requests += 1
        return session
    }
}

@Test @MainActor
func warmupReviewPinsSelectionAndRequiresFreshPresenceWhileRetryingSameRequest() async throws {
    let provider = WarmupProviderFixture()
    provider.failsFirstCreate = true
    let presence = WarmupPresenceFixture()
    let model = SparkWarmupModel(provider: provider, authorizer: presence)
    await model.refresh()
    #expect(model.canReview)
    await model.prepareReview()
    #expect(model.canConfirm())
    await model.confirm()
    #expect(model.review != nil)
    #expect(model.errorMessage != nil)
    await model.confirm()
    #expect(model.review == nil)
    #expect(provider.created.count == 2)
    #expect(provider.created[0].1 == provider.created[1].1)
    #expect(provider.created[0].0 == provider.created[1].0)
    #expect(provider.created[0].0.acceptedPreviewDigest == String(repeating: "a", count: 64))
    #expect(await presence.requests == 2)
}

@Test @MainActor
func warmupChangingTimeDiscardsReviewAndMismatchedOrUnsafeReviewCannotConfirm() async {
    let provider = WarmupProviderFixture()
    let model = SparkWarmupModel(provider: provider)
    await model.refresh()
    await model.prepareReview()
    #expect(model.review != nil)
    model.dueDate = model.dueDate.addingTimeInterval(60)
    #expect(model.review == nil)
    #expect(!model.canConfirm())
    provider.responseModelID = "different-model"
    await model.prepareReview()
    #expect(model.review == nil)
    #expect(model.errorMessage != nil)
    provider.responseModelID = nil
    provider.blocked = true
    await model.prepareReview()
    #expect(model.review != nil)
    #expect(!model.canConfirm())
    #expect(provider.created.isEmpty)
}

@Test @MainActor
func warmupNonOwnerGetsNoEditableOrCachedControls() async {
    let provider = WarmupProviderFixture()
    let model = SparkWarmupModel(provider: provider)
    await model.refresh()
    #expect(model.canReview)
    provider.listingError = true
    await model.refresh()
    #expect(!model.canReview)
    #expect(model.models.isEmpty)
    #expect(model.schedules.isEmpty)
    #expect(model.errorMessage == "Only a Spark owner can schedule or manage warm-ups.")
}

@Test @MainActor
func warmupDisableIsPendingOnlyAndHistoryRemainsHonest() async throws {
    let provider = WarmupProviderFixture()
    let presence = WarmupPresenceFixture()
    let model = SparkWarmupModel(provider: provider, authorizer: presence)
    let pending = try warmupRecord()
    await model.disable(try warmupRecord(state: "running"))
    #expect(provider.disabled.isEmpty)
    await model.disable(pending)
    #expect(provider.disabled == [pending.id])
    #expect(await presence.requests == 1)
    #expect(
        try warmupRecord(state: "skipped", code: "MODEL_INSUFFICIENT_MEMORY").statusDescription
            .contains("memory")
    )
    #expect(try warmupRecord(state: "interrupted").statusDescription.contains("restart"))
}

@Test @MainActor
func warmupConfirmationExpiresWhenItsScheduledTimePasses() async {
    let provider = WarmupProviderFixture()
    let model = SparkWarmupModel(provider: provider)
    let due = Date().addingTimeInterval(60)
    model.dueDate = due
    await model.refresh()
    await model.prepareReview()
    #expect(model.canConfirm(at: due.addingTimeInterval(-1)))
    #expect(!model.canConfirm(at: due))
    #expect(!model.canConfirm(at: due.addingTimeInterval(1)))
    #expect(provider.created.isEmpty)
}
