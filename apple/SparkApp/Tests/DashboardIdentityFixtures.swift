import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing
@testable import SparkAppComposition

actor DashboardTestMutableIdentityRuntime: SparkRuntimeReading {
    private var nodeID: String
    private var authorityFingerprint: String
    private var clusterID: String?
    private var nodeName: String
    private var modelID: String
    private(set) var routes: [URL] = []

    init(
        nodeID: String,
        authorityFingerprint: String = "authority-a",
        clusterID: String? = nil,
        nodeName: String = "My Spark",
        modelID: String = "open/good-model"
    ) {
        self.nodeID = nodeID
        self.authorityFingerprint = authorityFingerprint
        self.clusterID = clusterID
        self.nodeName = nodeName
        self.modelID = modelID
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

    func replaceIdentity(
        nodeID: String,
        authorityFingerprint: String,
        nodeName: String,
        modelID: String
    ) {
        self.nodeID = nodeID
        self.authorityFingerprint = authorityFingerprint
        self.nodeName = nodeName
        self.modelID = modelID
    }

    func health(route: URL) async throws -> Health {
        routes.append(route)
        return try dashboardTestDashboardDecode(
            """
            {"api_version":1,"node_id":"\(nodeID)","runtime_version":"0.1.0","status":"ok"}
            """
        )
    }

    func status(route: URL) async throws -> SparkStatus {
        let clusterJSON = clusterID.map { "\"\($0)\"" } ?? "null"
        let clusterStatus =
            clusterID.map {
                """
                {"id":"\($0)","name":"My Cluster","state":"healthy","members":[{"node_id":"\(nodeID)","name":"\(nodeName)","role":"leader","reachable":true,"qsfp_health":"healthy"}]}
                """
            } ?? "null"
        return try dashboardTestDashboardDecode(
            """
            {"api_version":1,"node":{"node_id":"\(nodeID)","cluster_id":\(clusterJSON),"name":"\(nodeName)","role":"standalone","authority_fingerprint":"\(authorityFingerprint)","runtime_version":"0.1.0","dgx_os_version":null},"cluster":\(clusterStatus),"system":{"unified_memory_total_bytes":137438953472,"unified_memory_available_bytes":68719476736,"memory_pressure":"normal","cpu_utilisation":0.2,"disk_free_bytes":900000000000,"uptime_seconds":120,"temperature_celsius":48},"inference":{"state":"ready","model_id":"\(modelID)","profile_id":null,"active_requests":0,"queue_depth":0,"tokens_per_second":1,"time_to_first_token_ms":1}}
            """
        )
    }

    func models(route: URL) async throws -> ModelCatalogue {
        try dashboardTestDashboardDecode(
            """
            {"items":[{"id":"\(modelID)","display_name":"\(nodeName) model","description":null,"recipe_revision":"r1","source_revision":"s1","install_state":"installed","total_bytes":1,"capabilities":{"chat":true},"fit":"ready","profiles":[]}],"next_cursor":null}
            """
        )
    }

    func activeInference(route: URL) async throws -> ActiveInference {
        try dashboardTestDashboardDecode(
            """
            {"state":"ready","model_id":"\(modelID)","profile_id":null,"context_length":1024,"active_requests":0,"queue_depth":0,"tokens_per_second":1,"time_to_first_token_ms":1}
            """
        )
    }
}

let dashboardTestDashboardCoordinatorID = "63e82da2-7fb7-4b4b-9584-4a528000ac94"

let dashboardTestDashboardAttackerID = "00000000-0000-4000-8000-000000000007"

func dashboardTestDashboardNodeID(_ value: String) -> SparkNodeID {
    SparkNodeID(rawValue: UUID(uuidString: value)!)
}

func dashboardTestDashboardCachedSnapshot(at date: Date) -> TargetOperationalSnapshot {
    let nodeID = dashboardTestDashboardNodeID(dashboardTestDashboardCoordinatorID)
    let fresh = OperationalEvidenceFreshness(
        observedAt: date,
        evaluatedAt: date,
        staleAfter: 60
    )
    let evidence = TargetEvidenceFreshness(
        health: fresh,
        inventory: fresh,
        memory: fresh,
        inference: fresh,
        operations: fresh
    )
    let modelIdentity = ModelPlacementIdentity(modelID: "open/cached-model", recipeRevision: "r1")
    return TargetOperationalSnapshot(
        identity: .node(nodeID),
        displayName: "Cached Spark",
        members: [
            TargetMemberSnapshot(
                nodeID: nodeID,
                displayName: "Cached Spark",
                role: .standalone,
                reachable: true,
                lastSuccessfulContact: date
            )
        ],
        preferredRoute: nil,
        connectionState: .offlineCached,
        lastSuccessfulContact: date,
        evaluatedAt: date,
        evidence: evidence,
        runtime: TargetRuntimeSnapshot(
            version: "0.4.0",
            health: .healthy,
            updateState: .current
        ),
        vllmHealth: .ready,
        unifiedMemory: UnifiedMemorySnapshot(
            totalBytes: 128_000_000_000,
            availableBytes: 64_000_000_000,
            pressure: .normal
        ),
        disk: nil,
        installedModelCount: 1,
        activeInference: ActiveInferenceSnapshot(
            state: .ready,
            modelIdentity: modelIdentity,
            profileID: "balanced",
            activeRequests: 0,
            queueDepth: 0,
            tokensPerSecond: nil,
            timeToFirstTokenMilliseconds: nil
        ),
        operations: [],
        placements: [
            ModelPlacementSnapshot(
                identity: modelIdentity,
                displayName: "Cached Model",
                state: .running,
                evidence: fresh,
                technicalDetails: ModelPlacementTechnicalDetails(
                    modelID: modelIdentity.modelID,
                    recipeRevision: modelIdentity.recipeRevision,
                    sourceRevision: "s1"
                )
            )
        ],
        warnings: [],
        blockers: [],
        technicalDetails: TargetTechnicalDetails(
            logicalIdentity: SparkTargetIdentity.node(nodeID).description,
            memberNodeIDs: [nodeID]
        )
    )
}
