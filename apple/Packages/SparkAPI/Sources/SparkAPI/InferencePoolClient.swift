import Foundation
import SparkSecurity

/// Use node-authoritative independent-request pools without treating URLs as authority or creating distributed-model clusters.
extension SparkAPIClient {
    public func inferencePools(route base: URL) async throws -> GeneratedAPI.InferencePoolList {
        try await get(endpoint(base, "api", "v1", "inference", "pools"))
    }

    public func inferenceNodeCapabilities(
        route base: URL
    ) async throws -> GeneratedAPI.NodeCapabilitySnapshot {
        try await get(endpoint(base, "api", "v1", "inference", "node-capabilities"))
    }

    public func previewInferencePool(
        route base: URL,
        request: GeneratedAPI.PoolPolicyPreviewRequest,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.PoolPolicyPreview {
        try await post(
            endpoint(base, "api", "v1", "inference", "pools", "preview"),
            body: request,
            idempotencyKey: idempotencyKey
        )
    }

    public func applyInferencePool(
        route base: URL,
        request: GeneratedAPI.ApplyPoolPolicyRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> GeneratedAPI.InferencePoolPolicy {
        try await post(
            endpoint(base, "api", "v1", "inference", "pools", "apply"),
            body: request,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }

    public func createInferenceRouterGrant(
        route base: URL,
        request: GeneratedAPI.CreateRouterGrantRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> GeneratedAPI.RouterGrant {
        try await post(
            endpoint(base, "api", "v1", "inference", "router-grants"),
            body: request,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }

    public func revokeInferenceRouterGrant(
        route base: URL,
        grantID: UUID,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> GeneratedAPI.RevokeRouterGrantResult {
        try await post(
            endpoint(base, "api", "v1", "inference", "router-grants", grantID.uuidString, "revoke"),
            body: Optional<EmptyRequestBody>.none,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }

    public func reserveInferenceCapacity(
        route base: URL,
        request: GeneratedAPI.ReserveInferenceRequest,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.AdmissionReservation {
        try await post(
            endpoint(base, "api", "v1", "inference", "reservations"),
            body: request,
            idempotencyKey: idempotencyKey
        )
    }

    public func inferenceReservation(
        route base: URL,
        reservationID: UUID
    ) async throws -> GeneratedAPI.AdmissionReservation {
        try await get(
            endpoint(base, "api", "v1", "inference", "reservations", reservationID.uuidString)
        )
    }

    public func cancelInferenceReservation(
        route base: URL,
        reservationID: UUID,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.AdmissionReservation {
        try await post(
            endpoint(
                base,
                "api",
                "v1",
                "inference",
                "reservations",
                reservationID.uuidString,
                "cancel"
            ),
            body: Optional<EmptyRequestBody>.none,
            idempotencyKey: idempotencyKey
        )
    }
}
