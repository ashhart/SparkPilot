import Foundation
@_spi(SparkTestSupport) import SparkAPI
import SparkBootstrap
import SparkCore
import SparkDesignSystem
import SparkDiscovery
import SparkLibrary
import SparkSecurity
@_spi(SparkTestSupport) import SparkTransport
import Testing
@testable import SparkAppComposition

actor SettingsCompositionTestPartiallyAvailableCompositionRuntime:
    SparkRuntimeReading, SparkNetworkStatusReading, SparkSettingsManaging,
    DeviceManagementProviding
{
    enum TelemetryMode: Sendable {
        case available
        case routeMissing
    }

    enum NetworkMode: Sendable {
        case unused
        case succeeds
        case wrongPassword
        case candidateIdentityMismatch
        case handoffCancellation
        case handoffUnavailable
        case presenceEnrollmentRejected
        case presenceEnrollmentUnavailable
    }

    enum RuntimeUpdateMode: Sendable {
        case unused
        case succeeds
        case missing
        case schedulingBackendFailure
        case leaseExpired
        case refusedByTheSpark
    }

    private let runtimeVersion: String
    private let summaryAvailable: Bool
    private var settingsRoutesAvailable: Bool
    private let settingsRoutesFailAsTransport: Bool
    private let telemetryMode: TelemetryMode
    private let telemetryTemperature: Double
    private let networkMode: NetworkMode
    private let runtimeUpdateMode: RuntimeUpdateMode
    private let publishesSignedRuntimeUpdateCapability: Bool
    private let wifiScanFails: Bool
    private var softwareUpdates: GeneratedAPI.SoftwareUpdateStatus?
    private var telemetryReadCount = 0
    private var networkConfirmationRoutes: [URL] = []
    private var networkRollbackRoutes: [URL] = []
    private var networkHandoffIdentityRoutes: [URL] = []
    private var networkHandoffCheckerCreations = 0
    private var presenceEnrollmentKeys: [UUID] = []
    private var runtimeUpdateRequests: [GeneratedAPI.InstallSoftwareUpdatesRequest] = []

    init(
        runtimeVersion: String = "0.1.0",
        summaryAvailable: Bool = true,
        settingsRoutesAvailable: Bool = true,
        settingsRoutesFailAsTransport: Bool = false,
        telemetryMode: TelemetryMode,
        telemetryTemperature: Double = 55,
        networkMode: NetworkMode = .unused,
        runtimeUpdateMode: RuntimeUpdateMode = .unused,
        publishesSignedRuntimeUpdateCapability: Bool = true,
        wifiScanFails: Bool = false,
        softwareUpdates: GeneratedAPI.SoftwareUpdateStatus? = nil
    ) {
        self.runtimeVersion = runtimeVersion
        self.softwareUpdates = softwareUpdates
        self.summaryAvailable = summaryAvailable
        self.settingsRoutesAvailable = settingsRoutesAvailable
        self.settingsRoutesFailAsTransport = settingsRoutesFailAsTransport
        self.telemetryMode = telemetryMode
        self.telemetryTemperature = telemetryTemperature
        self.networkMode = networkMode
        self.runtimeUpdateMode = runtimeUpdateMode
        self.publishesSignedRuntimeUpdateCapability = publishesSignedRuntimeUpdateCapability
        self.wifiScanFails = wifiScanFails
    }

    func identity(route: URL) async throws -> SparkIdentity {
        if route.host == "spark-candidate.local" {
            switch networkMode {
            case .handoffCancellation:
                throw CancellationError()
            case .handoffUnavailable:
                throw URLError(.cannotConnectToHost)
            default:
                break
            }
        }
        let nodeID =
            networkMode == .candidateIdentityMismatch && route.host == "spark-candidate.local"
            ? "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
            : "63e82da2-7fb7-4b4b-9584-4a528000ac94"
        return try decode(
            """
            {"node_id":"\(nodeID)","cluster_id":null,"name":"Workshop Spark","role":"standalone","authority_fingerprint":"authority-a","tls_fingerprint":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","runtime_version":"\(runtimeVersion)","dgx_os_version":"7.0"}
            """
        )
    }

    func networkHandoffIdentity(route: URL) async throws -> SparkIdentity {
        networkHandoffIdentityRoutes.append(route)
        return try await identity(route: route)
    }

    func makeNetworkHandoffIdentityChecker() async throws
        -> any NetworkHandoffIdentityChecking
    {
        networkHandoffCheckerCreations += 1
        return SettingsCompositionTestSettingsNetworkHandoffChecker(runtime: self)
    }

    func health(route: URL) async throws -> Health {
        guard summaryAvailable else {
            throw SettingsCompositionTestSettingsTelemetryTestError.summaryUnavailable
        }
        return try decode(
            #"{"api_version":1,"node_id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","runtime_version":"0.1.0","status":"ok"}"#
        )
    }

    func capabilities(route: URL) async throws -> SparkCapabilities {
        SparkCapabilities(
            apiVersion: 1,
            features: publishesSignedRuntimeUpdateCapability
                ? ["signed_runtime_update": true]
                : [:]
        )
    }

    func status(route: URL) async throws -> SparkStatus {
        guard summaryAvailable else {
            throw SettingsCompositionTestSettingsTelemetryTestError.summaryUnavailable
        }
        return try decode(
            #"{"api_version":1,"node":{"node_id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","cluster_id":null,"name":"Workshop Spark","role":"standalone","authority_fingerprint":"authority-a","runtime_version":"0.1.0","dgx_os_version":"7.0"},"cluster":null,"system":{"unified_memory_total_bytes":137438953472,"unified_memory_available_bytes":68719476736,"memory_pressure":"normal","cpu_utilisation":0.2,"disk_free_bytes":900000000000,"uptime_seconds":120,"temperature_celsius":48},"inference":{"state":"ready","model_id":null,"profile_id":null,"active_requests":0,"queue_depth":0,"tokens_per_second":null,"time_to_first_token_ms":null}}"#
        )
    }

    func models(route: URL) async throws -> ModelCatalogue {
        guard summaryAvailable else {
            throw SettingsCompositionTestSettingsTelemetryTestError.summaryUnavailable
        }
        return try decode(#"{"items":[],"next_cursor":null}"#)
    }

    func activeInference(route: URL) async throws -> ActiveInference {
        guard summaryAvailable else {
            throw SettingsCompositionTestSettingsTelemetryTestError.summaryUnavailable
        }
        return try decode(
            #"{"state":"unloaded","model_id":null,"profile_id":null,"context_length":null,"active_requests":0,"queue_depth":0,"tokens_per_second":null,"time_to_first_token_ms":null}"#
        )
    }

    func telemetry(route: URL) async throws -> TelemetrySnapshot {
        telemetryReadCount += 1
        guard telemetryMode == .available else {
            throw APIError(
                .local(message: "The telemetry route is not installed."),
                statusCode: 404,
                code: "NOT_FOUND"
            )
        }
        let json =
            #"{"api_version":1,"observed_at":"2026-08-29T12:00:00Z","node_id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","node_name":"Workshop Spark","system":{"cpu_utilisation":0.27,"load_average_1m":1.4,"unified_memory_total_bytes":137438953472,"unified_memory_available_bytes":68719476736,"unified_memory_used_bytes":68719476736,"memory_pressure":"normal","temperature_celsius":54,"power_state":"normal","uptime_seconds":120},"accelerator":{"utilisation":0.64,"temperature_celsius":55,"power_draw_watts":49.5,"power_limit_watts":140},"storage":{"total_bytes":1000000000000,"free_bytes":400000000000,"used_bytes":600000000000},"usage":{"day":"2026-08-29","requests":0,"failures":0,"prompt_tokens":0,"cached_prompt_tokens":0,"generated_tokens":0,"reasoning_tokens":0,"total_tokens":0},"inference":{"state":"unloaded","model_id":null,"profile_id":null,"context_length":null,"active_requests":0,"queue_depth":0,"tokens_per_second":null,"time_to_first_token_ms":null}}"#
            .replacingOccurrences(
                of: #""temperature_celsius":55"#,
                with: #""temperature_celsius":\#(telemetryTemperature)"#
            )
        return try decode(json)
    }

    func networkInterfaces(route: URL) async throws -> NetworkInterfacesSnapshot {
        NetworkInterfacesSnapshot(
            apiVersion: 1,
            observedAt: Date(timeIntervalSince1970: 1_788_000_000),
            interfaces: []
        )
    }

    func sparkSettings(route: URL) async throws -> GeneratedAPI.SparkSettingsSnapshot {
        try requireSettingsRoutes()
        var snapshot: GeneratedAPI.SparkSettingsSnapshot = try decode(
            """
            {
              "api_version": 1,
              "observed_at": "2026-08-29T12:00:00Z",
              "direct_ethernet_enabled": true,
              "travel_access_point": {
                "enabled": false,
                "ssid": null,
                "security": "wpa3",
                "auto_revert_seconds": 60
              },
              "bluetooth": {
                "available": true,
                "powered": false,
                "discovering": false,
                "nearby_devices": []
              },
              "power_profile": {
                "available": true,
                "current_mode_id": 0,
                "current_name": "Balanced",
                "modes": [
                  {"mode_id": 0, "name": "Balanced"},
                  {"mode_id": 1, "name": "MODE_QUIET"}
                ],
                "reboot_required": false,
                "temperature_celsius": 55,
                "power_draw_watts": 49.5,
                "power_limit_watts": 140
              },
              "software_updates": {
                "checked_at": "2026-08-29T12:00:00Z",
                "system_packages_available": 0,
                "firmware_updates_available": 0,
                "runtime_release_id": null,
                "reboot_required": false
              },
              "memory_guard": {
                "warning_available_bytes": 17179869184,
                "critical_available_bytes": 10737418240,
                "emergency_available_bytes": 6442450944
              },
              "model_idle_policies": [],
              "time": {
                "timezone": "Europe/London",
                "ntp_enabled": true,
                "synchronized": true
              },
              "telemetry_consent": {"functional": false, "technical": false}
            }
            """
        )
        if let softwareUpdates { snapshot.softwareUpdates = softwareUpdates }
        return snapshot
    }

    func wifiNetworks(route: URL) async throws -> GeneratedAPI.WifiNetworksSnapshot {
        try requireSettingsRoutes()
        // Model a slow hardware scan that exceeds the transport request timeout.
        if wifiScanFails { throw URLError(.timedOut) }
        return try decode(
            #"{"api_version":1,"observed_at":"2026-08-29T12:00:00Z","networks":[{"ssid":"Workshop WiFi","security":"wpa3","signal_percent":88,"connected":true,"saved":true}]}"#
        )
    }

    func storageBreakdown(route: URL) async throws -> GeneratedAPI.StorageBreakdown {
        try requireSettingsRoutes()
        return GeneratedAPI.StorageBreakdown(
            observedAt: "2026-08-29T12:00:00Z",
            totalBytes: 1_000_000,
            freeBytes: 500_000,
            modelsBytes: 200_000,
            downloadsBytes: 10_000,
            blobsBytes: 100_000,
            containersBytes: 100_000,
            reclaimableBytes: 10_000
        )
    }

    func operation(route: URL, id: UUID) async throws -> SparkAPI.Operation {
        guard runtimeUpdateMode == .leaseExpired else {
            throw SettingsCompositionTestSettingsTelemetryTestError.unused
        }
        softwareUpdates = .init(
            checkedAt: "2026-09-04T23:20:00Z",
            systemPackagesAvailable: 0,
            firmwareUpdatesAvailable: 0,
            runtimeReleaseId: "dev-0.1.0",
            rebootRequired: true
        )
        return try operationFixture(
            kind: "system.software_updates",
            state: "failed",
            errorCode: "OPERATION_LEASE_EXPIRED"
        )
    }

    func connectWifi(
        route: URL,
        request: GeneratedAPI.ConnectWifiRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        switch networkMode {
        case .succeeds, .candidateIdentityMismatch, .handoffCancellation,
            .handoffUnavailable:
            return try operationFixture(kind: "network.wifi.connect")
        case .wrongPassword:
            return try operationFixture(
                kind: "network.wifi.connect",
                state: "failed",
                errorCode: "NETWORK_AUTHENTICATION_FAILED"
            )
        case .presenceEnrollmentRejected, .presenceEnrollmentUnavailable:
            throw APIError(
                .local(message: "This Apple device has no registered presence key."),
                statusCode: 403,
                code: "USER_PRESENCE_NOT_REGISTERED"
            )
        case .unused:
            throw SettingsCompositionTestSettingsTelemetryTestError.unused
        }
    }

    func devices(route: URL) async throws -> [GeneratedAPI.Device] { [] }

    func revokeDevice(
        route: URL,
        deviceID: String,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws {}

    func enrollPresenceKey(
        route: URL,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> String {
        presenceEnrollmentKeys.append(idempotencyKey)
        let status = networkMode == .presenceEnrollmentRejected ? 409 : 503
        throw APIError(
            .local(message: "Presence enrollment failed."),
            statusCode: status,
            code: status == 409 ? "PRESENCE_KEY_REJECTED" : "AUDIT_UNAVAILABLE"
        )
    }

    func forgetWifi(
        route: URL,
        request: GeneratedAPI.ForgetWifiRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        throw SettingsCompositionTestSettingsTelemetryTestError.unused
    }

    func configureLanIpv4(
        route: URL,
        request: GeneratedAPI.ConfigureLanIpv4Request,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        guard networkMode == .succeeds else {
            throw SettingsCompositionTestSettingsTelemetryTestError.unused
        }
        return try operationFixture(kind: "network.lan.ipv4")
    }

    func confirmNetworkChange(
        route: URL,
        configurationID: UUID,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        guard networkMode == .succeeds else {
            throw SettingsCompositionTestSettingsTelemetryTestError.unused
        }
        networkConfirmationRoutes.append(route)
        return try operationFixture(kind: "network.change.confirm")
    }

    func rollbackNetworkChange(
        route: URL,
        configurationID: UUID,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        guard networkMode == .succeeds else {
            throw SettingsCompositionTestSettingsTelemetryTestError.unused
        }
        networkRollbackRoutes.append(route)
        return try operationFixture(kind: "network.change.rollback")
    }

    func configureDirectEthernet(
        route: URL,
        enabled: Bool,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        throw SettingsCompositionTestSettingsTelemetryTestError.unused
    }

    func configureTravelAccessPoint(
        route: URL,
        request: GeneratedAPI.ConfigureTravelAccessPointRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        throw SettingsCompositionTestSettingsTelemetryTestError.unused
    }

    func configureBluetooth(
        route: URL,
        request: GeneratedAPI.ConfigureBluetoothRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        throw SettingsCompositionTestSettingsTelemetryTestError.unused
    }

    func setPowerProfile(
        route: URL,
        modeID: Int,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        throw SettingsCompositionTestSettingsTelemetryTestError.unused
    }

    func installSoftwareUpdates(
        route: URL,
        request: GeneratedAPI.InstallSoftwareUpdatesRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        switch runtimeUpdateMode {
        case .succeeds:
            runtimeUpdateRequests.append(request)
            return try operationFixture(kind: "software.update", state: "succeeded")
        case .missing:
            throw APIError(
                .local(message: "The update route is not installed."),
                statusCode: 404,
                code: "NOT_FOUND"
            )
        case .leaseExpired:
            runtimeUpdateRequests.append(request)
            return try operationFixture(kind: "system.software_updates", state: "running")
        case .schedulingBackendFailure:
            runtimeUpdateRequests.append(request)
            return try operationFixture(
                kind: "system.software_updates",
                state: "failed",
                stage: "runtime_update_scheduling",
                errorCode: "backend_error"
            )
        case .refusedByTheSpark:
            throw APIError(
                .reported,
                statusCode: 409,
                code: "INFERENCE_MUST_BE_UNLOADED",
                diagnosticDetail: "unload the active model before updating this Spark"
            )
        case .unused:
            throw SettingsCompositionTestSettingsTelemetryTestError.unused
        }
    }

    func recordedRuntimeUpdateRequests() -> [GeneratedAPI.InstallSoftwareUpdatesRequest] {
        runtimeUpdateRequests
    }

    func setSettingsRoutesAvailable(_ available: Bool) {
        settingsRoutesAvailable = available
    }

    func checkSoftwareUpdates(
        route: URL,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        try operationFixture(kind: "system.software_update_check")
    }

    func configureSystemTime(
        route: URL,
        request: GeneratedAPI.ConfigureSystemTimeRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        throw SettingsCompositionTestSettingsTelemetryTestError.unused
    }

    func updateMemoryGuard(
        route: URL,
        request: GeneratedAPI.MemoryGuardSettings,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        throw SettingsCompositionTestSettingsTelemetryTestError.unused
    }

    func updateModelIdlePolicy(
        route: URL,
        request: GeneratedAPI.ModelIdlePolicySettings,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        throw SettingsCompositionTestSettingsTelemetryTestError.unused
    }

    func updateTelemetryConsent(
        route: URL,
        request: GeneratedAPI.TelemetryConsentSettings,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        throw SettingsCompositionTestSettingsTelemetryTestError.unused
    }

    func cleanStorage(
        route: URL,
        request: GeneratedAPI.StorageCleanupRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        throw SettingsCompositionTestSettingsTelemetryTestError.unused
    }

    func telemetryReads() -> Int { telemetryReadCount }

    func confirmationRoutes() -> [URL] { networkConfirmationRoutes }

    func rollbackRoutes() -> [URL] { networkRollbackRoutes }

    func handoffIdentityRoutes() -> [URL] { networkHandoffIdentityRoutes }

    func handoffCheckerCreations() -> Int { networkHandoffCheckerCreations }

    func enrollmentKeys() -> [UUID] { presenceEnrollmentKeys }

    private func operationFixture(
        kind: String,
        state: String = "succeeded",
        stage: String? = nil,
        errorCode: String? = nil
    ) throws -> SparkAPI.Operation {
        let encodedStage = stage.map { "\"\($0)\"" } ?? "null"
        let encodedError = errorCode.map { "\"\($0)\"" } ?? "null"
        return try decode(
            """
            {"id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","kind":"\(kind)","state":"\(state)","progress":1,"stage":\(encodedStage),"error_code":\(encodedError),"cancellable":false}
            """
        )
    }

    private func decode<Value: Decodable>(_ json: String) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Value.self, from: Data(json.utf8))
    }

    private func missingSettingsRoute() -> APIError {
        APIError(
            .local(message: "The settings route is not installed."),
            statusCode: 404,
            code: "NOT_FOUND"
        )
    }

    private func requireSettingsRoutes() throws {
        guard !settingsRoutesAvailable else { return }
        if settingsRoutesFailAsTransport {
            throw URLError(.badServerResponse)
        }
        throw missingSettingsRoute()
    }
}
