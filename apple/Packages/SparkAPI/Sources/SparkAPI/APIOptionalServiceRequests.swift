import Foundation
import SparkCore
import SparkSecurity
@_spi(SparkInternal) @_spi(SparkTestSupport) import SparkTransport

extension SparkAPIClient {
    public func optionalServices(
        route base: URL
    ) async throws -> GeneratedAPI.OptionalServiceList {
        try await get(endpoint(base, "api", "v1", "services"))
    }

    public func openWebUIStatus(
        route base: URL
    ) async throws -> GeneratedAPI.OptionalServiceStatus {
        try await get(endpoint(base, "api", "v1", "services", "open-webui"))
    }

    public func installOpenWebUI(
        route base: URL,
        request: GeneratedAPI.InstallOpenWebUIRequest,
        idempotencyKey: UUID = UUID(),
        userPresence: any UserPresenceProofSigning
    ) async throws -> Operation {
        try await post(
            endpoint(base, "api", "v1", "services", "open-webui", "install"),
            body: request,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence,
            timeoutInterval: 120
        )
    }

    public func updateOpenWebUI(
        route base: URL,
        idempotencyKey: UUID = UUID(),
        userPresence: any UserPresenceProofSigning
    ) async throws -> Operation {
        try await post(
            endpoint(base, "api", "v1", "services", "open-webui", "update"),
            body: NoBody?.none,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence,
            timeoutInterval: 120
        )
    }

    public func repairOpenWebUI(
        route base: URL,
        idempotencyKey: UUID = UUID(),
        userPresence: any UserPresenceProofSigning
    ) async throws -> Operation {
        try await post(
            endpoint(base, "api", "v1", "services", "open-webui", "repair"),
            body: NoBody?.none,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence,
            timeoutInterval: 120
        )
    }

    public func removeOpenWebUI(
        route base: URL,
        request: GeneratedAPI.RemoveOpenWebUIRequest,
        idempotencyKey: UUID = UUID(),
        userPresence: any UserPresenceProofSigning
    ) async throws -> Operation {
        try await post(
            endpoint(base, "api", "v1", "services", "open-webui", "remove"),
            body: request,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence,
            timeoutInterval: 120
        )
    }

    public func openWebUIAccess(
        route base: URL,
        idempotencyKey: UUID = UUID()
    ) async throws -> GeneratedAPI.OptionalServiceAccess {
        try await post(
            endpoint(base, "api", "v1", "services", "open-webui", "access"),
            body: NoBody?.none,
            idempotencyKey: idempotencyKey,
            timeoutInterval: 60
        )
    }
}
