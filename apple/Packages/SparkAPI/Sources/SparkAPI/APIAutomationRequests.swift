import Foundation
import SparkSecurity

/// The Spark's own recurring work, and what its model may read on the internet.
extension SparkAPIClient {
    public func listAutomations(route base: URL) async throws -> GeneratedAPI.AutomationList {
        try await get(endpoint(base, "api", "v1", "automations"))
    }

    public func createAutomation(
        route base: URL,
        request: GeneratedAPI.AutomationRequest,
        idempotencyKey: UUID = UUID(),
        userPresence: (any UserPresenceProofSigning)? = nil
    ) async throws -> GeneratedAPI.Automation {
        guard let userPresence else {
            return try await post(
                endpoint(base, "api", "v1", "automations"),
                body: request,
                idempotencyKey: idempotencyKey
            )
        }
        return try await post(
            endpoint(base, "api", "v1", "automations"),
            body: request,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }

    public func updateAutomation(
        route base: URL,
        id: String,
        request: GeneratedAPI.AutomationUpdateRequest,
        idempotencyKey: UUID = UUID(),
        userPresence: (any UserPresenceProofSigning)? = nil
    ) async throws -> GeneratedAPI.Automation {
        let url = endpoint(base, "api", "v1", "automations", id)
        guard let userPresence else {
            return try await mutation(
                method: "PATCH",
                url: url,
                body: request,
                idempotencyKey: idempotencyKey,
                userPresence: nil
            )
        }
        return try await presenceMutation(
            method: "PATCH",
            url: url,
            body: request,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }

    public func deleteAutomation(
        route base: URL,
        id: String,
        idempotencyKey: UUID = UUID()
    ) async throws -> GeneratedAPI.AutomationList {
        try await mutation(
            method: "DELETE",
            url: endpoint(base, "api", "v1", "automations", id),
            body: Optional<GeneratedAPI.AutomationUpdateRequest>.none,
            idempotencyKey: idempotencyKey,
            userPresence: nil
        )
    }

    public func runAutomation(
        route base: URL,
        id: String,
        idempotencyKey: UUID = UUID()
    ) async throws -> Operation {
        try await post(
            endpoint(base, "api", "v1", "automations", id, "run"),
            body: Optional<GeneratedAPI.AutomationUpdateRequest>.none,
            idempotencyKey: idempotencyKey
        )
    }

    public func listAutomationRuns(
        route base: URL,
        id: String
    ) async throws -> GeneratedAPI.AutomationRunList {
        try await get(endpoint(base, "api", "v1", "automations", id, "runs"))
    }

    public func getWebAccessSettings(route base: URL) async throws -> GeneratedAPI.WebAccessSettings
    {
        try await get(endpoint(base, "api", "v1", "web", "settings"))
    }

    public func setWebAccessSettings(
        route base: URL,
        request: GeneratedAPI.WebAccessSettingsRequest,
        idempotencyKey: UUID = UUID(),
        userPresence: any UserPresenceProofSigning
    ) async throws -> Operation {
        try await presenceMutation(
            method: "PUT",
            url: endpoint(base, "api", "v1", "web", "settings"),
            body: request,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }

    public func createWebAnswer(
        route base: URL,
        request: GeneratedAPI.WebAnswerRequest,
        timeoutInterval: TimeInterval = 300
    ) async throws -> GeneratedAPI.WebAnswer {
        try await post(
            endpoint(base, "api", "v1", "web", "answer"),
            body: request,
            idempotencyKey: UUID(),
            timeoutInterval: timeoutInterval
        )
    }
}
