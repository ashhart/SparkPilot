import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing
@testable import SparkAppComposition

actor DashboardTestLifecycleRuntime: SparkRuntimeReading {
    private(set) var installPreviewCalls: [(String, UUID)] = []
    private(set) var lastInstallPreviewRequest: GeneratedAPI.InstallModelPreviewRequest?
    private(set) var loadPreviewCalls: [(GeneratedAPI.LoadModelPreviewRequest, UUID)] = []
    private(set) var stopPreviewKeys: [UUID] = []
    private(set) var removePreviewCalls: [(String, UUID)] = []
    private(set) var installKeys: [UUID] = []
    private(set) var installRequests: [GeneratedAPI.InstallModelRequest] = []
    private(set) var loadCalls: [(GeneratedAPI.LoadModelRequest, UUID)] = []
    private(set) var unloadCalls: [(GeneratedAPI.StopModelRequest, UUID)] = []
    private(set) var removeCalls: [(String, GeneratedAPI.RemoveModelRequest, UUID)] = []
    private(set) var polledOperationIDs: [UUID] = []
    private(set) var operationListCalls = 0

    var failFirstInstall: Bool
    var installAPIError: APIError?
    var failOperationPolling: Bool
    let failReads: Bool
    var operationResponses: [SparkAPI.Operation]
    var listedOperations: [SparkAPI.Operation]
    var activeModelID: String?
    let previewHasBlocker: Bool
    var nextApplyError: APIError?
    let multipleProfiles: Bool
    let memoryLimitedProfiles: Set<String>
    var holdNextLoadPreview: Bool
    private var pendingLoadPreview: CheckedContinuation<Void, Never>?
    private var pendingLoadApply: CheckedContinuation<Void, Never>?
    private var holdNextLoadApply: Bool
    private var loadResponses: [SparkAPI.Operation]
    private var recipeRevision = "r1"
    var loadedModelAfterOperation: String?

    func completeLoadAs(_ modelID: String) { loadedModelAfterOperation = modelID }

    init(
        failFirstInstall: Bool = false,
        installAPIError: APIError? = nil,
        failOperationPolling: Bool = false,
        failReads: Bool = false,
        operationResponses: [SparkAPI.Operation] = [],
        listedOperations: [SparkAPI.Operation] = [],
        activeModelID: String? = nil,
        previewHasBlocker: Bool = false,
        nextApplyError: APIError? = nil,
        multipleProfiles: Bool = false,
        holdNextLoadPreview: Bool = false,
        holdNextLoadApply: Bool = false,
        loadResponses: [SparkAPI.Operation] = [],
        memoryLimitedProfiles: Set<String> = []
    ) {
        self.failFirstInstall = failFirstInstall
        self.installAPIError = installAPIError
        self.failOperationPolling = failOperationPolling
        self.failReads = failReads
        self.operationResponses = operationResponses
        self.listedOperations = listedOperations
        self.activeModelID = activeModelID
        self.previewHasBlocker = previewHasBlocker
        self.nextApplyError = nextApplyError
        self.multipleProfiles = multipleProfiles
        self.holdNextLoadPreview = holdNextLoadPreview
        self.holdNextLoadApply = holdNextLoadApply
        self.loadResponses = loadResponses
        self.memoryLimitedProfiles = memoryLimitedProfiles
    }

    func capabilities(route: URL) async throws -> SparkCapabilities {
        SparkCapabilities(
            apiVersion: 1,
            features: [
                "container_runtime": true,
                "signed_catalogue": true,
            ]
        )
    }

    func health(route: URL) async throws -> Health {
        if failReads { throw URLError(.notConnectedToInternet) }
        return try dashboardTestDashboardDecode(
            #"{"api_version":1,"node_id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","runtime_version":"0.1.0","status":"ok"}"#
        )
    }

    func status(route: URL) async throws -> SparkStatus {
        if failReads { throw URLError(.notConnectedToInternet) }
        return try dashboardTestDashboardDecode(
            #"{"api_version":1,"node":{"node_id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","cluster_id":null,"name":"My Spark","role":"standalone","authority_fingerprint":"abc","runtime_version":"0.1.0","dgx_os_version":"7.0"},"cluster":null,"system":{"unified_memory_total_bytes":137438953472,"unified_memory_available_bytes":68719476736,"memory_pressure":"normal","cpu_utilisation":0.2,"disk_free_bytes":900000000000,"uptime_seconds":120,"temperature_celsius":48},"inference":{"state":"unloaded","model_id":null,"profile_id":null,"active_requests":0,"queue_depth":0,"tokens_per_second":null,"time_to_first_token_ms":null}}"#
        )
    }

    func models(route: URL) async throws -> ModelCatalogue {
        if failReads { throw URLError(.notConnectedToInternet) }
        let base =
            #"{"items":[{"id":"open/model-8b","display_name":"Model 8B","description":"Small local model","recipe_revision":"r1","source_revision":"s1","install_state":"installed","total_bytes":8000000000,"capabilities":{"chat":true},"fit":"ready","profiles":[{"id":"unsafe","display_name":"Large","max_model_length":65536,"max_sequences":4,"expected_peak_bytes":120000000000,"measured_peak_bytes":null,"safe":false},{"id":"balanced","display_name":"Balanced","max_model_length":32768,"max_sequences":4,"expected_peak_bytes":12000000000,"measured_peak_bytes":null,"safe":true}]}],"next_cursor":null}"#
        let extra =
            #"{"id":"long","display_name":"Long context","max_model_length":262144,"max_sequences":2,"expected_peak_bytes":96000000000,"measured_peak_bytes":null,"safe":true},"#
        let json =
            multipleProfiles
            ? base.replacingOccurrences(of: #""profiles":["#, with: #""profiles":["# + extra) : base
        return try dashboardTestDashboardDecode(
            json.replacingOccurrences(
                of: #""recipe_revision":"r1""#,
                with: "\"recipe_revision\":\"\(recipeRevision)\""
            )
        )
    }

    func changeRecipeRevision(to revision: String) { recipeRevision = revision }

    func activeInference(route: URL) async throws -> ActiveInference {
        if failReads { throw URLError(.notConnectedToInternet) }
        let state = activeModelID == nil ? "unloaded" : "ready"
        let model = activeModelID.map { "\"\($0)\"" } ?? "null"
        return try dashboardTestDashboardDecode(
            """
            {"state":"\(state)","model_id":\(model),"profile_id":null,"context_length":null,"active_requests":0,"queue_depth":0,"tokens_per_second":null,"time_to_first_token_ms":null}
            """
        )
    }

    func previewInstallModel(
        route: URL,
        modelID: String,
        request: GeneratedAPI.InstallModelPreviewRequest,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview {
        installPreviewCalls.append((modelID, idempotencyKey))
        lastInstallPreviewRequest = request
        return try lifecyclePreview(action: "install", blocked: previewHasBlocker)
    }

    func installModel(
        route: URL,
        modelID: String,
        request: GeneratedAPI.InstallModelRequest,
        idempotencyKey: UUID
    ) async throws -> SparkAPI.Operation {
        installKeys.append(idempotencyKey)
        installRequests.append(request)
        if let error = nextApplyError {
            nextApplyError = nil
            throw error
        }
        if failFirstInstall {
            failFirstInstall = false
            throw URLError(.networkConnectionLost)
        }
        if let error = installAPIError {
            installAPIError = nil
            throw error
        }
        return try dashboardTestLifecycleOperation(
            kind: "model.install",
            state: "queued",
            progress: 0
        )
    }

    func previewLoadModel(
        route: URL,
        request: GeneratedAPI.LoadModelPreviewRequest,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview {
        loadPreviewCalls.append((request, idempotencyKey))
        if holdNextLoadPreview {
            holdNextLoadPreview = false
            await withCheckedContinuation { pendingLoadPreview = $0 }
        }
        var preview = try lifecyclePreview(
            action: request.replaceActive == true ? "replace" : "load",
            blocked: previewHasBlocker
        )
        if memoryLimitedProfiles.contains(request.profileId) {
            preview.blockers = try dashboardTestDashboardDecode(
                #"[{"code":"MODEL_INSUFFICIENT_MEMORY","owner_explanation":"This profile does not fit.","recovery_action":"Choose a smaller profile."}]"#
            )
        }
        return preview
    }

    func hasPendingLoadPreview() -> Bool { pendingLoadPreview != nil }

    func finishLoadPreview() {
        pendingLoadPreview?.resume()
        pendingLoadPreview = nil
    }

    func hasPendingLoadApply() -> Bool { pendingLoadApply != nil }

    func finishLoadApply() {
        pendingLoadApply?.resume()
        pendingLoadApply = nil
    }

    func loadModel(
        route: URL,
        request: GeneratedAPI.LoadModelRequest,
        idempotencyKey: UUID
    ) async throws -> SparkAPI.Operation {
        loadCalls.append((request, idempotencyKey))
        if holdNextLoadApply {
            holdNextLoadApply = false
            await withCheckedContinuation { pendingLoadApply = $0 }
        }
        if !loadResponses.isEmpty { return loadResponses.removeFirst() }
        if let error = nextApplyError {
            nextApplyError = nil
            throw error
        }
        return try dashboardTestLifecycleOperation(
            kind: "model.load",
            state: "succeeded",
            progress: 1
        )
    }

    func previewUnloadModel(
        route: URL,
        request: GeneratedAPI.StopModelPreviewRequest,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview {
        stopPreviewKeys.append(idempotencyKey)
        return try lifecyclePreview(action: "stop", blocked: previewHasBlocker)
    }

    func unloadModel(
        route: URL,
        request: GeneratedAPI.StopModelRequest,
        idempotencyKey: UUID
    ) async throws -> SparkAPI.Operation {
        unloadCalls.append((request, idempotencyKey))
        if let error = nextApplyError {
            nextApplyError = nil
            throw error
        }
        return try dashboardTestLifecycleOperation(
            kind: "model.unload",
            state: "succeeded",
            progress: 1
        )
    }

    func previewRemoveModel(
        route: URL,
        modelID: String,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview {
        removePreviewCalls.append((modelID, idempotencyKey))
        return try lifecyclePreview(action: "remove", blocked: previewHasBlocker)
    }

    func removeModel(
        route: URL,
        modelID: String,
        request: GeneratedAPI.RemoveModelRequest,
        idempotencyKey: UUID,
        userPresence: String?
    ) async throws -> SparkAPI.Operation {
        removeCalls.append((modelID, request, idempotencyKey))
        if let error = nextApplyError {
            nextApplyError = nil
            throw error
        }
        return try dashboardTestLifecycleOperation(
            kind: "model.remove",
            state: "succeeded",
            progress: 1
        )
    }

    func operation(route: URL, id: UUID) async throws -> SparkAPI.Operation {
        polledOperationIDs.append(id)
        if failOperationPolling {
            failOperationPolling = false
            throw URLError(.networkConnectionLost)
        }
        if !operationResponses.isEmpty {
            let operation = operationResponses.removeFirst()
            if operation.state == .succeeded, operation.kind == "model.load",
                let loadedModelAfterOperation
            {
                activeModelID = loadedModelAfterOperation
            }
            return operation
        }
        return try dashboardTestLifecycleOperation(
            kind: "model.install",
            state: "succeeded",
            progress: 1
        )
    }

    func operations(route: URL, limit: Int, cursor: String?) async throws -> OperationPage {
        operationListCalls += 1
        return OperationPage(items: listedOperations)
    }
}

func dashboardTestDashboardDecode<Value: Decodable>(_ json: String) throws -> Value {
    try JSONDecoder().decode(Value.self, from: Data(json.utf8))
}

func lifecyclePreview(
    action: String,
    blocked: Bool = false,
    clusterMembers: String = "[]",
    reinstallRequired: Bool = false,
    activeEngine: String = "null",
    profileFailureCode: String? = nil
) throws -> GeneratedAPI.ModelActionPreview {
    let blockers =
        blocked
        ? #"[{"code":"DISK_LOW","owner_explanation":"Free some storage on this Spark.","recovery_action":"Remove an unused download."}]"#
        : "[]"
    let profileFailureCodeJSON = profileFailureCode.map { "\"\($0)\"" } ?? "null"
    return try dashboardTestDashboardDecode(
        """
        {
          "preview_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          "action":"\(action)",
          "target":{"node_id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","cluster_id":null},
          "recipe":null,
          "evidence":{
            "download_bytes":6000000000,
            "locally_reusable_bytes":2000000000,
            "required_disk_bytes":6000000000,
            "disk_free_bytes":900000000000,
            "expected_disk_free_after_bytes":894000000000,
            "required_memory_bytes":12000000000,
            "available_memory_bytes":68719476736,
            "expected_memory_headroom_bytes":56719476736,
            "profile_failure_code":\(profileFailureCodeJSON),
            "active_inference_available":true,
            "engine_transitioning":false,
            "active_engine":\(activeEngine),
            "cluster_membership_available":true,
            "cluster":{"cluster_id":null,"state":"standalone","members":\(clusterMembers)}
          },
          "evidence_timestamps":{"system_observed_at":"2026-08-28T12:00:00Z"},
          "consequences":{
            "model_to_stop":null,
            "profile_to_stop":null,
            "route_withdrawal":false,
            "service_interruption":"none",
            "files_removed":[],
            "reinstall_required":\(reinstallRequired)
          },
          "blockers":\(blockers),
          "warnings":[],
          "issued_at":"2026-08-28T12:00:00Z",
          "expires_at":"2026-08-28T12:05:00Z"
        }
        """
    )
}

func dashboardTestLifecycleOperation(
    kind: String,
    state: String,
    progress: Double?,
    stage: String? = nil,
    errorCode: String? = nil
) throws -> SparkAPI.Operation {
    let progressJSON = progress.map { String($0) } ?? "null"
    let stageJSON = stage.map { "\"\($0)\"" } ?? "null"
    let errorJSON = errorCode.map { "\"\($0)\"" } ?? "null"
    return try dashboardTestDashboardDecode(
        """
        {"id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","kind":"\(kind)","state":"\(state)","progress":\(progressJSON),"stage":\(stageJSON),"error_code":\(errorJSON),"cancellable":true}
        """
    )
}
