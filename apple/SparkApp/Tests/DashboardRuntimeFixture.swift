import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing
@testable import SparkAppComposition

actor DashboardTestFakeRuntimeReader: SparkRuntimeReading, DeviceManagementProviding {
    /// Use nil when operation listing is unsupported, matching the protocol's throwing default.
    private let listedOperations: [SparkAPI.Operation]?
    private(set) var operationListCalls = 0
    private var telemetryCallCount = 0
    private let reportsOptionalTelemetry: Bool
    /// When set, every telemetry read fails this way, the way a Spark refuses a role it does not show telemetry to.
    private let telemetryFailure: (any Error)?
    private let statusMemoryPressure: String
    private let telemetryMemoryPressure: String
    private let containerRuntime: Bool
    private let signedCatalogue: Bool
    private let optionalServices: Bool
    private let catalogueRefresh: Bool
    private let profileReenable: Bool
    /// Use nil when workload observation is unsupported, matching the protocol's throwing default.
    private let workloadInventory: GeneratedAPI.WorkloadInventory?
    private let advertisesWorkloadInventory: Bool
    /// Distinguish role-based read refusal from transport failure.
    private let refusesWorkloadInventory: Bool
    private let cancelRefresh: Bool
    private let presenceEnrollmentStatusCode: Int?
    private var presenceEnrollmentKeys: [UUID] = []
    private var openWebUIInstalled = false
    private var openWebUIOwnershipVerified: Bool?
    private var openWebUIRepairAvailable: Bool?
    private var openWebUIRepairCount = 0
    private var lastOpenWebUIInstall: GeneratedAPI.InstallOpenWebUIRequest?
    private var lastOpenWebUIRemoval: GeneratedAPI.RemoveOpenWebUIRequest?
    private var catalogueWasRefreshed = false
    private var lastCatalogueRefresh: GeneratedAPI.CatalogueRefreshRequest?
    private var cataloguePollCount = 0
    private var profileWasReenabled = false
    private var lastProfileReenable:
        (
            modelID: String, profileID: String, request: GeneratedAPI.ReenableModelProfileRequest,
            key: UUID
        )?
    private var profileReenableKeys: [UUID] = []
    private var profilePollCount = 0
    private var failFirstProfileReenable: Bool
    private let profileReenableFails: Bool

    init(
        reportsOptionalTelemetry: Bool = true,
        telemetryFailure: (any Error)? = nil,
        containerRuntime: Bool = true,
        signedCatalogue: Bool = true,
        optionalServices: Bool = false,
        catalogueRefresh: Bool = false,
        profileReenable: Bool = false,
        failFirstProfileReenable: Bool = false,
        profileReenableFails: Bool = false,
        workloadInventory: GeneratedAPI.WorkloadInventory? = nil,
        advertisesWorkloadInventory: Bool = false,
        refusesWorkloadInventory: Bool = false,
        cancelRefresh: Bool = false,
        presenceEnrollmentStatusCode: Int? = nil,
        listedOperations: [SparkAPI.Operation]? = nil,
        statusMemoryPressure: String = "normal",
        telemetryMemoryPressure: String = "normal"
    ) {
        self.listedOperations = listedOperations
        self.reportsOptionalTelemetry = reportsOptionalTelemetry
        self.telemetryFailure = telemetryFailure
        self.containerRuntime = containerRuntime
        self.signedCatalogue = signedCatalogue
        self.optionalServices = optionalServices
        self.catalogueRefresh = catalogueRefresh
        self.profileReenable = profileReenable
        self.failFirstProfileReenable = failFirstProfileReenable
        self.profileReenableFails = profileReenableFails
        self.workloadInventory = workloadInventory
        self.advertisesWorkloadInventory = advertisesWorkloadInventory
        self.refusesWorkloadInventory = refusesWorkloadInventory
        self.cancelRefresh = cancelRefresh
        self.presenceEnrollmentStatusCode = presenceEnrollmentStatusCode
        self.statusMemoryPressure = statusMemoryPressure
        self.telemetryMemoryPressure = telemetryMemoryPressure
    }

    func operations(route: URL, limit: Int, cursor: String?) async throws -> OperationPage {
        operationListCalls += 1
        guard let listedOperations else { throw PendingRuntimeError.unconfigured }
        return OperationPage(items: listedOperations)
    }

    func capabilities(route: URL) async throws -> SparkCapabilities {
        SparkCapabilities(
            apiVersion: 1,
            features: [
                "container_runtime": containerRuntime,
                "signed_catalogue": signedCatalogue,
                "optional_service_recipes": optionalServices,
                "open_webui_service": optionalServices,
                "open_webui_ports": optionalServices,
                "signed_catalogue_refresh": catalogueRefresh,
                "model_profile_reenable": profileReenable,
                "workload_inventory": advertisesWorkloadInventory,
                "workload_adoption": false,
            ]
        )
    }

    func workloads(route: URL) async throws -> GeneratedAPI.WorkloadInventory {
        if refusesWorkloadInventory {
            throw APIError(
                .local(message: "this role does not hold the required capability"),
                statusCode: 403,
                code: "ROLE_FORBIDDEN"
            )
        }
        guard let workloadInventory else { throw PendingRuntimeError.unconfigured }
        return workloadInventory
    }

    func openWebUIStatus(route: URL) async throws -> GeneratedAPI.OptionalServiceStatus {
        guard optionalServices else { throw PendingRuntimeError.unconfigured }
        return GeneratedAPI.OptionalServiceStatus(
            id: .openWebui,
            displayName: .openWebUI,
            ownershipVerified: openWebUIOwnershipVerified,
            repairAvailable: openWebUIRepairAvailable,
            state: openWebUIInstalled ? .healthy : .notInstalled,
            installed: openWebUIInstalled,
            running: openWebUIInstalled,
            healthy: openWebUIInstalled,
            installedImageDigest: openWebUIInstalled ? "sha256:verified" : nil,
            availableRevision: "open-webui-r1",
            availableVersion: "0.6.32",
            updateAvailable: false,
            accessPath: openWebUIInstalled ? "/services/open-webui/" : nil,
            accessPort: 7444,
            accessTls: true,
            inferenceGateway: .init(
                scopes: [.modelsRead, .chatCompletionsCreate],
                healthy: openWebUIInstalled,
                port: 18081,
                loopbackOnly: true
            ),
            recovery: nil
        )
    }

    func installOpenWebUI(
        route: URL,
        request: GeneratedAPI.InstallOpenWebUIRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        guard optionalServices else { throw PendingRuntimeError.unconfigured }
        if presenceEnrollmentStatusCode != nil {
            throw APIError(
                .local(message: "This Apple device has no registered presence key."),
                statusCode: 403,
                code: "USER_PRESENCE_NOT_REGISTERED"
            )
        }
        lastOpenWebUIInstall = request
        openWebUIInstalled = true
        return try completedOpenWebUIOperation(kind: "service.open_webui.install")
    }

    func openWebUIAccess(
        route: URL,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.OptionalServiceAccess {
        guard openWebUIInstalled else { throw PendingRuntimeError.unconfigured }
        return .init(accessPath: "/services/open-webui/")
    }

    func updateOpenWebUI(
        route: URL,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        guard openWebUIInstalled else { throw PendingRuntimeError.unconfigured }
        return try completedOpenWebUIOperation(kind: "service.open_webui.update")
    }

    func removeOpenWebUI(
        route: URL,
        request: GeneratedAPI.RemoveOpenWebUIRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        guard openWebUIInstalled else { throw PendingRuntimeError.unconfigured }
        lastOpenWebUIRemoval = request
        openWebUIInstalled = false
        return try completedOpenWebUIOperation(kind: "service.open_webui.remove")
    }

    func recordedOpenWebUIInstall() -> GeneratedAPI.InstallOpenWebUIRequest? {
        lastOpenWebUIInstall
    }

    func configureOpenWebUIRepair(ownership: Bool?, available: Bool?) {
        openWebUIInstalled = true
        openWebUIOwnershipVerified = ownership
        openWebUIRepairAvailable = available
    }

    func repairOpenWebUI(
        route: URL,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        openWebUIRepairCount += 1
        openWebUIRepairAvailable = false
        return try completedOpenWebUIOperation(kind: "service.open_webui.repair")
    }

    func recordedOpenWebUIRepairs() -> Int { openWebUIRepairCount }

    func recordedOpenWebUIRemoval() -> GeneratedAPI.RemoveOpenWebUIRequest? {
        lastOpenWebUIRemoval
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
        throw APIError(
            .local(message: "Presence enrollment failed."),
            statusCode: presenceEnrollmentStatusCode,
            code: "PRESENCE_KEY_REJECTED"
        )
    }

    func recordedPresenceEnrollmentKeys() -> [UUID] { presenceEnrollmentKeys }

    func catalogueStatus(route: URL) async throws -> GeneratedAPI.CatalogueStatus {
        guard catalogueRefresh else { throw PendingRuntimeError.unconfigured }
        return .init(
            source: .deviceLocalSignedSnapshot,
            refreshAvailable: true,
            recipeCount: catalogueWasRefreshed ? 2 : 1,
            currentDigest: String(repeating: catalogueWasRefreshed ? "b" : "a", count: 64),
            signatureKeyId: "spark-catalogue-root",
            previousSnapshotAvailable: catalogueWasRefreshed,
            lastRefreshedAt: catalogueWasRefreshed ? "2026-08-29T20:00:00Z" : nil,
            activeEngineUnaffected: true
        )
    }

    func previewCatalogueRefresh(
        route: URL,
        request: GeneratedAPI.CatalogueRefreshPreviewRequest,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview {
        guard catalogueRefresh else { throw PendingRuntimeError.unconfigured }
        return try lifecyclePreview(action: "catalogue.refresh")
    }

    func refreshCatalogue(
        route: URL,
        request: GeneratedAPI.CatalogueRefreshRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        guard catalogueRefresh else { throw PendingRuntimeError.unconfigured }
        lastCatalogueRefresh = request
        cataloguePollCount = 0
        return try dashboardTestLifecycleOperation(
            kind: "catalogue.refresh",
            state: "running",
            progress: 0.15,
            stage: "validating_signature"
        )
    }

    func previewReenableModelProfile(
        route: URL,
        modelID: String,
        profileID: String,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview {
        guard profileReenable else { throw PendingRuntimeError.unconfigured }
        return try lifecyclePreview(
            action: "profile.reenable",
            profileFailureCode: "MEMORY_GUARD_EMERGENCY"
        )
    }

    func reenableModelProfile(
        route: URL,
        modelID: String,
        profileID: String,
        request: GeneratedAPI.ReenableModelProfileRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        guard profileReenable else { throw PendingRuntimeError.unconfigured }
        profileReenableKeys.append(idempotencyKey)
        lastProfileReenable = (modelID, profileID, request, idempotencyKey)
        if failFirstProfileReenable {
            failFirstProfileReenable = false
            throw URLError(.networkConnectionLost)
        }
        profilePollCount = 1
        return try dashboardTestLifecycleOperation(
            kind: "model.profile.reenable",
            state: "running",
            progress: nil,
            stage: "reviewing_profile"
        )
    }

    func operation(route: URL, id: UUID) async throws -> SparkAPI.Operation {
        if profileReenable, profilePollCount > 0 {
            profilePollCount += 1
            if profileReenableFails {
                return try dashboardTestLifecycleOperation(
                    kind: "model.profile.reenable",
                    state: "failed",
                    progress: 1,
                    stage: "profile_reenable_failed",
                    errorCode: "MODEL_PROFILE_REENABLE_FAILED"
                )
            }
            profileWasReenabled = true
            return try dashboardTestLifecycleOperation(
                kind: "model.profile.reenable",
                state: "succeeded",
                progress: 1,
                stage: "profile_reenabled"
            )
        }
        guard catalogueRefresh else { throw PendingRuntimeError.unconfigured }
        cataloguePollCount += 1
        if cataloguePollCount == 1 {
            return try dashboardTestLifecycleOperation(
                kind: "catalogue.refresh",
                state: "running",
                progress: 0.70,
                stage: "promoting_snapshot"
            )
        }
        catalogueWasRefreshed = true
        return try dashboardTestLifecycleOperation(
            kind: "catalogue.refresh",
            state: "succeeded",
            progress: 1,
            stage: "catalogue_ready"
        )
    }

    func recordedCatalogueRefresh() -> GeneratedAPI.CatalogueRefreshRequest? {
        lastCatalogueRefresh
    }

    func cataloguePolls() -> Int { cataloguePollCount }

    func recordedProfileReenable() -> (
        modelID: String, profileID: String, request: GeneratedAPI.ReenableModelProfileRequest,
        key: UUID
    )? {
        lastProfileReenable
    }

    func profilePolls() -> Int { profilePollCount }

    func recordedProfileReenableKeys() -> [UUID] { profileReenableKeys }

    private func completedOpenWebUIOperation(kind: String) throws -> SparkAPI.Operation {
        try JSONDecoder().decode(
            SparkAPI.Operation.self,
            from: Data(
                """
                {"id":"\(UUID().uuidString.lowercased())","kind":"\(kind)","state":"succeeded","progress":1,"stage":"ready","error_code":null,"cancellable":false}
                """.utf8
            )
        )
    }

    func health(route: URL) async throws -> Health {
        if cancelRefresh { throw CancellationError() }
        return try decode(
            #"{"api_version":1,"node_id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","runtime_version":"0.1.0","status":"ok"}"#
        )
    }

    func status(route: URL) async throws -> SparkStatus {
        if cancelRefresh { throw CancellationError() }
        return try decode(
            #"{"api_version":1,"node":{"node_id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","cluster_id":null,"name":"My Spark","role":"standalone","authority_fingerprint":"abc","runtime_version":"0.1.0","dgx_os_version":"7.0"},"cluster":null,"system":{"unified_memory_total_bytes":137438953472,"unified_memory_available_bytes":68719476736,"memory_pressure":"\#(statusMemoryPressure)","cpu_utilisation":0.2,"disk_free_bytes":900000000000,"uptime_seconds":120,"temperature_celsius":48},"inference":{"state":"ready","model_id":"open/model-8b","profile_id":"balanced","active_requests":0,"queue_depth":0,"tokens_per_second":42.5,"time_to_first_token_ms":210}}"#
        )
    }

    func models(route: URL) async throws -> ModelCatalogue {
        if cancelRefresh { throw CancellationError() }
        let safe = profileWasReenabled ? "true" : "false"
        return try decode(
            """
            {"items":[{"id":"open/model-8b","display_name":"Model 8B","description":"Small local model","recipe_revision":"r1","source_revision":"s1","install_state":"installed","total_bytes":8000000000,"capabilities":{"chat":true},"fit":"ready","profiles":[{"id":"large","display_name":"Large context","max_model_length":65536,"max_sequences":4,"expected_peak_bytes":120000000000,"measured_peak_bytes":118000000000,"safe":\(safe)}]}],"next_cursor":null}
            """
        )
    }

    func activeInference(route: URL) async throws -> ActiveInference {
        if cancelRefresh { throw CancellationError() }
        return try decode(
            #"{"state":"ready","model_id":"open/model-8b","profile_id":"balanced","context_length":32768,"active_requests":0,"queue_depth":0,"tokens_per_second":42.5,"time_to_first_token_ms":210}"#
        )
    }

    func telemetry(route: URL) async throws -> TelemetrySnapshot {
        telemetryCallCount += 1
        if let telemetryFailure { throw telemetryFailure }
        if !reportsOptionalTelemetry {
            return try decode(
                #"{"api_version":1,"observed_at":"2026-08-29T00:15:00Z","node_id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","node_name":"My Spark","system":{"cpu_utilisation":0.27,"load_average_1m":1.4,"unified_memory_total_bytes":137438953472,"unified_memory_available_bytes":68719476736,"unified_memory_used_bytes":68719476736,"memory_pressure":"\#(telemetryMemoryPressure)","memory_psi_some_avg10":null,"memory_psi_full_avg10":null,"temperature_celsius":54,"power_state":"normal","uptime_seconds":120},"accelerator":{"utilisation":0.64,"temperature_celsius":55,"power_draw_watts":49.5,"power_limit_watts":140,"memory_used_bytes":null,"memory_total_bytes":null},"storage":{"total_bytes":1000000000000,"free_bytes":400000000000,"used_bytes":600000000000},"usage":{"day":"2026-08-29","requests":12,"failures":1,"prompt_tokens":500,"cached_prompt_tokens":100,"generated_tokens":250,"reasoning_tokens":50,"total_tokens":800},"inference":{"state":"ready","model_id":"open/model-8b","profile_id":"balanced","context_length":32768,"active_requests":2,"queue_depth":null,"tokens_per_second":42.5,"time_to_first_token_ms":210}}"#
            )
        }
        return try decode(
            #"{"api_version":1,"observed_at":"2026-08-29T00:15:00Z","node_id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","node_name":"My Spark","system":{"cpu_utilisation":0.27,"load_average_1m":1.4,"unified_memory_total_bytes":137438953472,"unified_memory_available_bytes":68719476736,"unified_memory_used_bytes":68719476736,"memory_pressure":"\#(telemetryMemoryPressure)","memory_psi_some_avg10":0.12,"memory_psi_full_avg10":0.02,"temperature_celsius":54,"power_state":"normal","uptime_seconds":120},"accelerator":{"utilisation":0.64,"temperature_celsius":55,"power_draw_watts":49.5,"power_limit_watts":140,"memory_used_bytes":25769803776,"memory_total_bytes":137438953472},"storage":{"total_bytes":1000000000000,"free_bytes":400000000000,"used_bytes":600000000000},"usage":{"day":"2026-08-29","requests":12,"failures":1,"prompt_tokens":500,"cached_prompt_tokens":100,"generated_tokens":250,"reasoning_tokens":50,"total_tokens":800},"inference":{"state":"ready","model_id":"open/model-8b","profile_id":"balanced","context_length":32768,"active_requests":2,"queue_depth":1,"tokens_per_second":42.5,"time_to_first_token_ms":210}}"#
        )
    }

    func telemetryCalls() -> Int { telemetryCallCount }

    private func decode<Value: Decodable>(_ json: String) throws -> Value {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Value.self, from: Data(json.utf8))
    }
}
