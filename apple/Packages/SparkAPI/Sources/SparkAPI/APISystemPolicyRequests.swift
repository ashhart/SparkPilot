import Foundation
import SparkCore
import SparkSecurity
@_spi(SparkInternal) @_spi(SparkTestSupport) import SparkTransport

extension SparkAPIClient {
    public func setPowerProfile(
        route base: URL,
        modeID: Int,
        idempotencyKey: UUID = UUID(),
        userPresence: any UserPresenceProofSigning
    ) async throws -> Operation {
        try await post(
            endpoint(base, "api", "v1", "system", "power-profile"),
            body: GeneratedAPI.SetPowerProfileRequest(modeId: modeID),
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }

    public func installSoftwareUpdates(
        route base: URL,
        request: GeneratedAPI.InstallSoftwareUpdatesRequest,
        idempotencyKey: UUID = UUID(),
        userPresence: any UserPresenceProofSigning
    ) async throws -> Operation {
        try await post(
            endpoint(base, "api", "v1", "system", "updates"),
            body: request,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence,
            timeoutInterval: 120
        )
    }

    public func checkSoftwareUpdates(
        route base: URL,
        idempotencyKey: UUID = UUID(),
        userPresence: any UserPresenceProofSigning
    ) async throws -> Operation {
        try await post(
            endpoint(base, "api", "v1", "system", "updates", "check"),
            body: NoBody?.none,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence,
            timeoutInterval: 120
        )
    }

    public func configureSystemTime(
        route base: URL,
        request: GeneratedAPI.ConfigureSystemTimeRequest,
        idempotencyKey: UUID = UUID(),
        userPresence: any UserPresenceProofSigning
    ) async throws -> Operation {
        try await post(
            endpoint(base, "api", "v1", "system", "time"),
            body: request,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }

    public func updateMemoryGuard(
        route base: URL,
        request: GeneratedAPI.MemoryGuardSettings,
        idempotencyKey: UUID = UUID(),
        userPresence: any UserPresenceProofSigning
    ) async throws -> Operation {
        try await post(
            endpoint(base, "api", "v1", "settings", "memory-guard"),
            body: request,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }

    public func updateModelIdlePolicy(
        route base: URL,
        request: GeneratedAPI.ModelIdlePolicySettings,
        idempotencyKey: UUID = UUID(),
        userPresence: any UserPresenceProofSigning
    ) async throws -> Operation {
        try await post(
            endpoint(base, "api", "v1", "settings", "model-idle"),
            body: request,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }

    public func updateTelemetryConsent(
        route base: URL,
        request: GeneratedAPI.TelemetryConsentSettings,
        idempotencyKey: UUID = UUID(),
        userPresence: any UserPresenceProofSigning
    ) async throws -> Operation {
        try await post(
            endpoint(base, "api", "v1", "settings", "telemetry"),
            body: request,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }

    public func cleanStorage(
        route base: URL,
        request: GeneratedAPI.StorageCleanupRequest,
        idempotencyKey: UUID = UUID(),
        userPresence: any UserPresenceProofSigning
    ) async throws -> Operation {
        try await post(
            endpoint(base, "api", "v1", "storage", "cleanup"),
            body: request,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }

    /// `POST /api/v1/power/reboot` — accepted owner power operation (202).
    public func rebootSpark(
        route base: URL,
        idempotencyKey: UUID = UUID(),
        userPresence: any UserPresenceProofSigning
    ) async throws -> Operation {
        try await post(
            base.appendingPathComponent("api/v1/power/reboot"),
            body: NoBody?.none,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }

    /// `POST /api/v1/power/shutdown` — accepted owner power operation (202).
    public func shutdownSpark(
        route base: URL,
        idempotencyKey: UUID = UUID(),
        userPresence: any UserPresenceProofSigning
    ) async throws -> Operation {
        try await post(
            base.appendingPathComponent("api/v1/power/shutdown"),
            body: NoBody?.none,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }

    /// `POST /api/v1/system/hostname` — accepted owner hostname change (202).
    public func setSparkHostname(
        route base: URL,
        hostname: String,
        idempotencyKey: UUID = UUID(),
        userPresence: any UserPresenceProofSigning
    ) async throws -> Operation {
        try await post(
            base.appendingPathComponent("api/v1/system/hostname"),
            body: GeneratedAPI.SetHostnameRequest(hostname: hostname),
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }
}
