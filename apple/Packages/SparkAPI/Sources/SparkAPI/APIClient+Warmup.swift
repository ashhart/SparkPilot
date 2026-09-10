import Foundation
import SparkSecurity

extension SparkAPIClient {
    public func warmups(route base: URL) async throws -> WarmupCollection {
        try await get(base.appendingPathComponent("api/v1/inference/warmups"))
    }

    public func previewWarmup(
        route base: URL,
        request: WarmupRequest,
        idempotencyKey: UUID = UUID()
    ) async throws -> WarmupPreview {
        try await post(
            base.appendingPathComponent("api/v1/inference/warmups/preview"),
            body: request,
            idempotencyKey: idempotencyKey
        )
    }

    public func createWarmup(
        route base: URL,
        request: WarmupRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> WarmupSchedule {
        try await post(
            base.appendingPathComponent("api/v1/inference/warmups"),
            body: request,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }

    public func disableWarmup(
        route base: URL,
        scheduleID: UUID,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> WarmupSchedule {
        try await post(
            base.appendingPathComponent(
                "api/v1/inference/warmups/\(scheduleID.uuidString.lowercased())/disable"
            ),
            body: Optional<[String: String]>.none,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }
}
