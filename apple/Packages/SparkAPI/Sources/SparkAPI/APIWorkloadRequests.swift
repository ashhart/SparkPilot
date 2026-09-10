import Foundation
import SparkCore
import SparkSecurity
@_spi(SparkInternal) @_spi(SparkTestSupport) import SparkTransport

extension SparkAPIClient {
    /// Observe existing workloads without changing their state (§29.6).
    public func workloads(route base: URL) async throws -> GeneratedAPI.WorkloadInventory {
        try await get(endpoint(base, "api", "v1", "workloads"))
    }

    public func previewWorkloadAdoption(
        route base: URL,
        workloadID: String,
        request: GeneratedAPI.WorkloadAdoptionPreviewRequest,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview {
        try await post(
            endpoint(base, "api", "v1", "workloads", workloadID, "adoption", "preview"),
            body: request,
            idempotencyKey: idempotencyKey
        )
    }

    public func adoptWorkload(
        route base: URL,
        workloadID: String,
        request: GeneratedAPI.WorkloadAdoptionRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> Operation {
        try await post(
            endpoint(base, "api", "v1", "workloads", workloadID, "adopt"),
            body: request,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }

    public func previewWorkloadRelinquish(
        route base: URL,
        workloadID: String,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview {
        try await post(
            endpoint(base, "api", "v1", "workloads", workloadID, "relinquish", "preview"),
            body: NoBody?.none,
            idempotencyKey: idempotencyKey
        )
    }

    public func relinquishWorkload(
        route base: URL,
        workloadID: String,
        request: GeneratedAPI.WorkloadRelinquishRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> GeneratedAPI.RelinquishWorkloadResponse200 {
        try await post(
            endpoint(base, "api", "v1", "workloads", workloadID, "relinquish"),
            body: request,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence,
            timeoutInterval: 60
        )
    }
}
