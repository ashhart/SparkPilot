import Foundation
import SparkSecurity

extension SparkAPIClient {
    public func household(route base: URL) async throws -> GeneratedAPI.HouseholdSnapshot {
        try await get(endpoint(base, "api", "v1", "household", "notes"))
    }

    public func saveHouseholdNote(
        route base: URL,
        request: GeneratedAPI.HouseholdNoteRequest,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.HouseholdChange {
        try await post(
            endpoint(base, "api", "v1", "household", "notes"),
            body: request,
            idempotencyKey: idempotencyKey
        )
    }

    public func setHouseholdMember(
        route base: URL,
        request: GeneratedAPI.HouseholdMemberRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> GeneratedAPI.HouseholdChange {
        try await post(
            endpoint(base, "api", "v1", "household", "members"),
            body: request,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }
}
