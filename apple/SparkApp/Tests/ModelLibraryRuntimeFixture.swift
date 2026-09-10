import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing
@testable import SparkAppComposition

actor ModelLibraryTestModelLibraryRuntimeStub: SparkRuntimeReading {
    let presentedNodeID: String
    let authorityFingerprint: String
    private let operationPages: [OperationPage]?
    private var shouldFail = false
    private var operationPageIndex = 0
    private var requests: [String] = []
    private var pausedStatus: CheckedContinuation<Void, Never>?
    private let pauseStatus: Bool
    private let inferenceState: String
    private let statusClusterID: UUID?
    private let statusFails: Bool

    init(
        presentedNodeID: String,
        authorityFingerprint: String,
        operationPages: [OperationPage]? = nil,
        pauseStatus: Bool = false,
        inferenceState: String = "ready",
        statusClusterID: UUID? = nil,
        statusFails: Bool = false
    ) {
        self.presentedNodeID = presentedNodeID
        self.authorityFingerprint = authorityFingerprint
        self.operationPages = operationPages
        self.pauseStatus = pauseStatus
        self.inferenceState = inferenceState
        self.statusClusterID = statusClusterID
        self.statusFails = statusFails
    }

    func requestedEndpoints() -> [String] { requests }

    func isStatusPaused() -> Bool { pausedStatus != nil }

    func resumeStatus() {
        pausedStatus?.resume()
        pausedStatus = nil
    }

    func setShouldFail(_ value: Bool) {
        shouldFail = value
    }

    func health(route: URL) async throws -> Health {
        requests.append("health")
        try failIfNeeded()
        return try modelLibraryTestLibraryDecode(
            """
            {"api_version":1,"node_id":"\(presentedNodeID)","runtime_version":"0.2.0","status":"ok"}
            """
        )
    }

    func status(route: URL) async throws -> SparkStatus {
        requests.append("status")
        if pauseStatus { await withCheckedContinuation { pausedStatus = $0 } }
        if statusFails { throw URLError(.timedOut) }
        try failIfNeeded()
        let clusterJSON = statusClusterID.map { "\"\($0.uuidString)\"" } ?? "null"
        return try modelLibraryTestLibraryDecode(
            """
            {"api_version":1,"node":{"node_id":"\(presentedNodeID)","cluster_id":\(clusterJSON),"name":"Studio Spark","role":"standalone","authority_fingerprint":"\(authorityFingerprint)","runtime_version":"0.2.0"},"cluster":null,"system":{"unified_memory_total_bytes":128000000000,"unified_memory_available_bytes":64000000000,"memory_pressure":"normal","cpu_utilisation":0.1,"disk_free_bytes":500000000000,"uptime_seconds":120,"temperature_celsius":40},"inference":{"state":"\(inferenceState)","model_id":"spark/model-8b","profile_id":"balanced","active_requests":0,"queue_depth":0,"tokens_per_second":20,"time_to_first_token_ms":100}}
            """
        )
    }

    func models(route: URL) async throws -> ModelCatalogue {
        requests.append("models")
        try failIfNeeded()
        return try modelLibraryTestLibraryDecode(
            """
            {"items":[{"id":"spark/model-8b","display_name":"Model 8B","description":"Compact","recipe_revision":"2026.08.1","source_revision":"source-r1","install_state":"installed","total_bytes":8000000000,"capabilities":{"chat":true},"fit":"ready","profiles":[{"id":"balanced","display_name":"Balanced","max_model_length":32768,"max_sequences":4,"expected_peak_bytes":12000000000,"safe":true}]}],"next_cursor":null}
            """
        )
    }

    func activeInference(route: URL) async throws -> ActiveInference {
        requests.append("inference")
        return try modelLibraryTestLibraryDecode(
            #"{"state":"ready","model_id":"spark/model-8b","profile_id":"balanced","context_length":8192,"active_requests":0,"queue_depth":0,"tokens_per_second":20,"time_to_first_token_ms":100}"#
        )
    }

    func operations(route: URL, limit: Int, cursor: String?) async throws -> OperationPage {
        requests.append("operations")
        try failIfNeeded()
        if let operationPages {
            let page = operationPages[min(operationPageIndex, operationPages.count - 1)]
            operationPageIndex += 1
            return page
        }
        return try modelLibraryTestLibraryDecode(
            """
            {"items":[{"id":"a2944316-f58d-43cc-8725-ae351e782a58","kind":"model.install","state":"running","progress":0.5,"stage":"downloading","error_code":null,"cancellable":true}],"next_cursor":null}
            """
        )
    }

    func capabilities(route: URL) async throws -> SparkCapabilities {
        requests.append("capabilities")
        throw URLError(.timedOut)
    }

    func workloads(route: URL) async throws -> GeneratedAPI.WorkloadInventory {
        requests.append("workloads")
        throw URLError(.timedOut)
    }

    func openWebUIStatus(route: URL) async throws -> GeneratedAPI.OptionalServiceStatus {
        requests.append("openWebUI")
        throw URLError(.timedOut)
    }

    func catalogueStatus(route: URL) async throws -> GeneratedAPI.CatalogueStatus {
        requests.append("catalogueStatus")
        throw URLError(.timedOut)
    }

    private func failIfNeeded() throws {
        if shouldFail { throw URLError(.notConnectedToInternet) }
    }
}
