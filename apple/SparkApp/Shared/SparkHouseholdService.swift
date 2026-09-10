import Foundation
import SparkAPI
import SparkSecurity

protocol SparkHouseholdProviding: Sendable {
    func snapshot() async throws -> GeneratedAPI.HouseholdSnapshot
    func save(_ request: GeneratedAPI.HouseholdNoteRequest, key: UUID) async throws
    func setMember(_ request: GeneratedAPI.HouseholdMemberRequest, key: UUID) async throws
}

/// Each read and mutation authenticates the original Spark, even if its route is reused.
struct SparkHouseholdService: SparkHouseholdProviding {
    let target: SparkChatTarget

    private func client() async throws -> SparkAPIClient {
        try await SparkVoiceService().client(for: SparkVoiceTarget(target))
    }

    func snapshot() async throws -> GeneratedAPI.HouseholdSnapshot {
        try await client().household(route: target.route)
    }

    func save(_ request: GeneratedAPI.HouseholdNoteRequest, key: UUID) async throws {
        _ = try await client().saveHouseholdNote(
            route: target.route,
            request: request,
            idempotencyKey: key
        )
    }

    func setMember(_ request: GeneratedAPI.HouseholdMemberRequest, key: UUID) async throws {
        let api = try await client()
        let authorizer = SystemUserPresenceAuthorizer()
        let reason = String(
            localized: "Confirm who can read and add household notes on your Spark."
        )
        let proof = try await authorizer.authorize(localizedReason: reason)
        do {
            _ = try await api.setHouseholdMember(
                route: target.route,
                request: request,
                idempotencyKey: key,
                userPresence: proof
            )
        } catch {
            guard (error as? APIError)?.code == "USER_PRESENCE_NOT_REGISTERED" else { throw error }
            let enrollment = try await authorizer.authorize(localizedReason: reason)
            _ = try await api.enrollPresenceKey(
                route: target.route,
                idempotencyKey: UUID(),
                userPresence: enrollment
            )
            let retry = try await authorizer.authorize(localizedReason: reason)
            _ = try await api.setHouseholdMember(
                route: target.route,
                request: request,
                idempotencyKey: key,
                userPresence: retry
            )
        }
    }
}
