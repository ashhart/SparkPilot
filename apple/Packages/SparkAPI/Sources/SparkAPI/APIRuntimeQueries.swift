import Foundation
import SparkCore
import SparkSecurity
@_spi(SparkInternal) @_spi(SparkTestSupport) import SparkTransport

extension SparkAPIClient {
    public func health(route base: URL) async throws -> Health {
        try await get(base.appendingPathComponent("api/v1/health"))
    }

    public func identity(route base: URL) async throws -> SparkIdentity {
        try await get(base.appendingPathComponent("api/v1/identity"))
    }

    /// Build a fresh pinned client per network handoff so route probes cannot reuse pre-change connection state.
    public func makeNetworkHandoffIdentityChecker() async throws
        -> any NetworkHandoffIdentityChecking
    {
        try SparkAPIClient.pinned(to: transport.pin, signer: signer)
    }

    public func status(route base: URL) async throws -> SparkStatus {
        try await get(base.appendingPathComponent("api/v1/status"))
    }

    /// Gate optional controls on capabilities the runtime explicitly reports.
    public func capabilities(route base: URL) async throws -> SparkCapabilities {
        try await get(base.appendingPathComponent("api/v1/capabilities"))
    }

    public func telemetry(route base: URL) async throws -> TelemetrySnapshot {
        try await get(base.appendingPathComponent("api/v1/telemetry"))
    }

    /// Read runtime telemetry history with server-clamped limits and rejected inverted ranges.
    public func telemetryHistory(
        route base: URL,
        from: Date? = nil,
        to: Date? = nil,
        limit: Int? = nil
    ) async throws -> GeneratedAPI.TelemetryHistory {
        var components = URLComponents(
            url: base.appendingPathComponent("api/v1/telemetry/history"),
            resolvingAgainstBaseURL: false
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var items: [URLQueryItem] = []
        if let from {
            items.append(URLQueryItem(name: "from", value: formatter.string(from: from)))
        }
        if let to { items.append(URLQueryItem(name: "to", value: formatter.string(from: to))) }
        if let limit { items.append(URLQueryItem(name: "limit", value: String(limit))) }
        components?.queryItems = items.isEmpty ? nil : items
        guard let url = components?.url else {
            throw APIError(.malformedRequestURL, diagnosticDetail: "telemetry history URL")
        }
        return try await get(url)
    }

    public func networkInterfaces(route base: URL) async throws -> NetworkInterfacesSnapshot {
        try await get(
            base.appendingPathComponent("api/v1/network/interfaces"),
            timeoutInterval: Self.applianceReadTimeout
        )
    }

    /// Allow hardware appliance commands longer than the presence timeout because Wi-Fi scans take five to eight seconds.
    static let applianceReadTimeout: TimeInterval = 30

    public func sparkSettings(route base: URL) async throws -> GeneratedAPI.SparkSettingsSnapshot {
        try await get(
            endpoint(base, "api", "v1", "settings"),
            timeoutInterval: Self.applianceReadTimeout
        )
    }

    public func wifiNetworks(route base: URL) async throws -> GeneratedAPI.WifiNetworksSnapshot {
        try await get(
            endpoint(base, "api", "v1", "network", "wifi"),
            timeoutInterval: Self.applianceReadTimeout
        )
    }

    public func storageBreakdown(route base: URL) async throws -> GeneratedAPI.StorageBreakdown {
        try await get(
            endpoint(base, "api", "v1", "storage"),
            timeoutInterval: Self.applianceReadTimeout
        )
    }

    public func diagnosticsCatalogue(
        route base: URL
    ) async throws -> GeneratedAPI.DiagnosticsCatalogue {
        try await get(endpoint(base, "api", "v1", "diagnostics"))
    }

    /// Export a redacted support bundle without a replay key so its contents are not persisted in the operation database (§46).
    public func exportDiagnostics(
        route base: URL,
        request: GeneratedAPI.DiagnosticsExportRequest,
        userPresence: any UserPresenceProofSigning
    ) async throws -> GeneratedAPI.DiagnosticsBundle {
        // Collecting a redacted bundle takes longer than the three-second presence probe allows.
        try await postWithoutReplayKey(
            endpoint(base, "api", "v1", "diagnostics", "export"),
            body: request,
            userPresence: userPresence,
            timeoutInterval: 90
        )
    }
}
