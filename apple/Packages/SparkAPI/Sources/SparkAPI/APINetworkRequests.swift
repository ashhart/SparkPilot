import Foundation
import SparkCore
import SparkSecurity
@_spi(SparkInternal) @_spi(SparkTestSupport) import SparkTransport

extension SparkAPIClient {
    public func connectWifi(
        route base: URL,
        request: GeneratedAPI.ConnectWifiRequest,
        idempotencyKey: UUID = UUID(),
        userPresence: any UserPresenceProofSigning
    ) async throws -> Operation {
        try await post(
            endpoint(base, "api", "v1", "network", "wifi"),
            body: request,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence,
            timeoutInterval: 120
        )
    }

    public func forgetWifi(
        route base: URL,
        request: GeneratedAPI.ForgetWifiRequest,
        idempotencyKey: UUID = UUID(),
        userPresence: any UserPresenceProofSigning
    ) async throws -> Operation {
        try await post(
            endpoint(base, "api", "v1", "network", "wifi", "forget"),
            body: request,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }

    public func configureLanIpv4(
        route base: URL,
        request: GeneratedAPI.ConfigureLanIpv4Request,
        idempotencyKey: UUID = UUID(),
        userPresence: any UserPresenceProofSigning
    ) async throws -> Operation {
        try await post(
            endpoint(base, "api", "v1", "network", "ethernet", "ipv4"),
            body: request,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }

    public func confirmNetworkChange(
        route base: URL,
        configurationID: UUID,
        idempotencyKey: UUID = UUID(),
        userPresence: any UserPresenceProofSigning
    ) async throws -> Operation {
        try await post(
            endpoint(
                base,
                "api",
                "v1",
                "network",
                "changes",
                configurationID.uuidString.lowercased(),
                "confirm"
            ),
            body: NoBody?.none,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }

    public func rollbackNetworkChange(
        route base: URL,
        configurationID: UUID,
        idempotencyKey: UUID = UUID(),
        userPresence: any UserPresenceProofSigning
    ) async throws -> Operation {
        try await post(
            endpoint(
                base,
                "api",
                "v1",
                "network",
                "changes",
                configurationID.uuidString.lowercased(),
                "rollback"
            ),
            body: NoBody?.none,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }

    public func configureDirectEthernet(
        route base: URL,
        enabled: Bool,
        idempotencyKey: UUID = UUID(),
        userPresence: any UserPresenceProofSigning
    ) async throws -> Operation {
        try await post(
            endpoint(base, "api", "v1", "network", "direct-profile"),
            body: GeneratedAPI.ConfigureDirectProfileRequest(enabled: enabled),
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }

    public func configureTravelAccessPoint(
        route base: URL,
        request: GeneratedAPI.ConfigureTravelAccessPointRequest,
        idempotencyKey: UUID = UUID(),
        userPresence: any UserPresenceProofSigning
    ) async throws -> Operation {
        try await post(
            endpoint(base, "api", "v1", "network", "travel-ap"),
            body: request,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence,
            timeoutInterval: 120
        )
    }

    public func configureBluetooth(
        route base: URL,
        request: GeneratedAPI.ConfigureBluetoothRequest,
        idempotencyKey: UUID = UUID(),
        userPresence: any UserPresenceProofSigning
    ) async throws -> Operation {
        try await post(
            endpoint(base, "api", "v1", "system", "bluetooth"),
            body: request,
            idempotencyKey: idempotencyKey,
            userPresence: userPresence
        )
    }
}
