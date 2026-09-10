import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import Testing

private enum OperationalSnapshotFixtures {
    static let now = Date(timeIntervalSince1970: 1_788_000_000)
    static let observedAt = now.addingTimeInterval(-5)
    static let nodeID = libraryNodeID(101)
    static let otherNodeID = libraryNodeID(999)
    static let clusterID = libraryClusterID(202)
    static let workerID = libraryNodeID(102)

    static let policy = OperationalFreshnessPolicy(
        health: 15,
        inventory: 60,
        memory: 15,
        inference: 15,
        operations: 15,
        delayedAfter: 30
    )

    static var composer: TargetOperationalSnapshotComposer {
        TargetOperationalSnapshotComposer(freshnessPolicy: policy)
    }

    static func standaloneEntry(host: String = "spark-a.local") -> LibraryEntry {
        var preferredRoute = route(host: host)
        preferredRoute.lastSuccess = observedAt
        return LibraryEntry(
            logicalKey: .node(nodeID),
            name: "Studio Spark",
            members: [
                LibraryMember(
                    nodeID: nodeID,
                    name: "Studio Spark",
                    role: .standalone,
                    routes: [preferredRoute],
                    lastSeen: observedAt,
                    reachable: true
                )
            ],
            connectionState: .connectedWiFi,
            lastSeen: observedAt,
            cachedAt: observedAt
        )
    }

    static func clusterEntry() -> LibraryEntry {
        var preferredRoute = route(host: "cluster-leader.local", kind: .directEthernet)
        preferredRoute.lastSuccess = observedAt
        return LibraryEntry(
            logicalKey: .cluster(clusterID),
            name: "Studio Cluster",
            members: [
                LibraryMember(
                    nodeID: nodeID,
                    name: "Leader",
                    role: .leader,
                    routes: [preferredRoute],
                    lastSeen: observedAt,
                    reachable: true
                ),
                LibraryMember(
                    nodeID: workerID,
                    name: "Worker",
                    role: .worker,
                    lastSeen: observedAt,
                    reachable: true
                ),
            ],
            connectionState: .connectedDirect,
            lastSeen: observedAt,
            cachedAt: observedAt
        )
    }

    static func evidence(
        identity: SparkTargetIdentity? = nil,
        respondingNodeID: SparkNodeID? = nil,
        healthStatus: String = "ok",
        runtimeVersion: String = "1.0.0",
        inferenceState: String = "ready",
        releaseVersion: String = "1.0.0",
        cluster: Bool = false
    ) throws -> TargetOperationalEvidence {
        let targetIdentity = identity ?? (cluster ? .cluster(clusterID) : .node(nodeID))
        let responder = respondingNodeID ?? nodeID
        return TargetOperationalEvidence(
            identity: targetIdentity,
            respondingNodeID: responder,
            health: TimedOperationalEvidence(
                try decodeHealth(
                    nodeID: responder,
                    status: healthStatus,
                    runtimeVersion: runtimeVersion
                ),
                observedAt: observedAt
            ),
            status: TimedOperationalEvidence(
                try decodeStatus(
                    nodeID: responder,
                    runtimeVersion: runtimeVersion,
                    inferenceState: inferenceState,
                    cluster: cluster
                ),
                observedAt: observedAt
            ),
            inventory: TimedOperationalEvidence(try decodeCatalogue(), observedAt: observedAt),
            inference: TimedOperationalEvidence(
                try decodeInference(state: inferenceState),
                observedAt: observedAt
            ),
            operations: TimedOperationalEvidence(try decodeOperations(), observedAt: observedAt),
            release: RuntimeReleaseEvidence(
                availableVersion: releaseVersion,
                observedAt: observedAt
            )
        )
    }

    static func snapshots() throws -> [String: TargetOperationalSnapshot] {
        let onlineEntry = standaloneEntry()
        let onlineEvidence = try evidence()
        let online = composer.compose(entry: onlineEntry, evidence: onlineEvidence, at: now)

        var delayedEntry = onlineEntry
        delayedEntry.cachedOperationalSnapshot = online
        let delayed = composer.cachedSnapshot(entry: delayedEntry, at: now.addingTimeInterval(40))

        var offlineEntry = delayedEntry
        offlineEntry.connectionState = .offlineCached
        offlineEntry.members[0].reachable = false
        let offline = composer.cachedSnapshot(entry: offlineEntry, at: now.addingTimeInterval(5))

        let mismatch = composer.compose(
            entry: delayedEntry,
            evidence: try evidence(
                identity: .node(otherNodeID),
                respondingNodeID: otherNodeID
            ),
            at: now.addingTimeInterval(5)
        )
        let updateAvailable = composer.compose(
            entry: onlineEntry,
            evidence: try evidence(releaseVersion: "1.1.0"),
            at: now
        )
        let degradedCluster = composer.compose(
            entry: clusterEntry(),
            evidence: try evidence(
                healthStatus: "degraded",
                inferenceState: "failed",
                cluster: true
            ),
            at: now
        )
        return [
            "online": online,
            "delayed": delayed,
            "offline": offline,
            "identityMismatch": mismatch,
            "updateAvailable": updateAvailable,
            "degradedCluster": degradedCluster,
        ]
    }

    static func decodeHealth(
        nodeID: SparkNodeID,
        status: String,
        runtimeVersion: String
    ) throws -> Health {
        try decode(
            """
            {
              "status": "\(status)",
              "api_version": 1,
              "runtime_version": "\(runtimeVersion)",
              "node_id": "\(nodeID.rawValue.uuidString)"
            }
            """
        )
    }

    static func decodeStatus(
        nodeID: SparkNodeID,
        runtimeVersion: String,
        inferenceState: String,
        cluster: Bool
    ) throws -> SparkStatus {
        let clusterIDValue = cluster ? "\"\(clusterID.rawValue.uuidString)\"" : "null"
        let role = cluster ? "leader" : "standalone"
        let clusterValue =
            cluster
            ? """
            {
              "id": "\(clusterID.rawValue.uuidString)",
              "name": "Studio Cluster",
              "state": "degraded",
              "members": [
                {
                  "node_id": "\(nodeID.rawValue.uuidString)",
                  "name": "Leader",
                  "role": "leader",
                  "reachable": true,
                  "qsfp_health": "healthy"
                },
                {
                  "node_id": "\(workerID.rawValue.uuidString)",
                  "name": "Worker",
                  "role": "worker",
                  "reachable": false,
                  "qsfp_health": "failed"
                }
              ]
            }
            """
            : "null"
        return try decode(
            """
            {
              "api_version": 1,
              "node": {
                "node_id": "\(nodeID.rawValue.uuidString)",
                "cluster_id": \(clusterIDValue),
                "name": "Runtime name",
                "role": "\(role)",
                "authority_fingerprint": "authority",
                "tls_fingerprint": null,
                "runtime_version": "\(runtimeVersion)",
                "dgx_os_version": "7.2"
              },
              "cluster": \(clusterValue),
              "system": {
                "unified_memory_total_bytes": 137438953472,
                "unified_memory_available_bytes": 34359738368,
                "memory_pressure": "\(cluster ? "warning" : "normal")",
                "cpu_utilisation": 0.25,
                "disk_free_bytes": 90000000000,
                "uptime_seconds": 3600,
                "temperature_celsius": 51.0
              },
              "inference": {
                "state": "\(inferenceState)",
                "model_id": "models/active",
                "profile_id": "balanced",
                "active_requests": 2,
                "queue_depth": 1,
                "tokens_per_second": 32.5,
                "time_to_first_token_ms": 220.0
              }
            }
            """
        )
    }

    static func decodeCatalogue() throws -> ModelCatalogue {
        try decode(
            """
            {
              "items": [
                \(catalogueItem(id: "models/active", name: "Active Model", state: "installed")),
                \(catalogueItem(id: "models/cold", name: "Cold Model", state: "installed")),
                \(catalogueItem(id: "models/available", name: "Available Model", state: "available")),
                \(catalogueItem(id: "models/download", name: "Download Model", state: "downloading")),
                \(catalogueItem(id: "models/failed", name: "Failed Model", state: "failed")),
                \(catalogueItem(id: "models/incompatible", name: "Incompatible Model", state: "incompatible")),
                \(catalogueItem(id: "models/unknown", name: "Unverified Model", state: "unverified"))
              ],
              "next_cursor": null
            }
            """
        )
    }

    static func catalogueItem(id: String, name: String, state: String) -> String {
        """
        {
          "id": "\(id)",
          "display_name": "\(name)",
          "description": null,
          "recipe_revision": "recipe-v1",
          "source_revision": "source-v1",
          "install_state": "\(state)",
          "total_bytes": 1000,
          "capabilities": {"chat": true},
          "fit": "fits",
          "profiles": []
        }
        """
    }

    static func decodeInference(state: String) throws -> ActiveInference {
        try decode(
            """
            {
              "state": "\(state)",
              "model_id": "models/active",
              "profile_id": "balanced",
              "context_length": 32768,
              "active_requests": 2,
              "queue_depth": 1,
              "tokens_per_second": 32.5,
              "time_to_first_token_ms": 220.0
            }
            """
        )
    }

    static func decodeOperations() throws -> [SparkAPI.Operation] {
        try decode(
            """
            [
              {
                "id": "22222222-0000-4000-8000-000000000001",
                "kind": "model.install",
                "state": "running",
                "progress": 0.5,
                "stage": "download",
                "error_code": null,
                "cancellable": true
              }
            ]
            """
        )
    }

    static func decode<Value: Decodable>(_ json: String) throws -> Value {
        try JSONDecoder().decode(Value.self, from: Data(json.utf8))
    }
}

@Test func operationalFixtureCoversEveryRequiredTargetCondition() throws {
    let snapshots = try OperationalSnapshotFixtures.snapshots()
    #expect(
        Set(snapshots.keys) == [
            "online", "delayed", "offline", "identityMismatch", "updateAvailable",
            "degradedCluster",
        ]
    )

    let online = try #require(snapshots["online"])
    #expect(online.identity == .node(OperationalSnapshotFixtures.nodeID))
    #expect(online.displayName == "Studio Spark")
    #expect(online.connectionState == .connectedWiFi)
    #expect(online.preferredRoute?.host == "spark-a.local")
    #expect(online.lastSuccessfulContact == OperationalSnapshotFixtures.observedAt)
    #expect(online.evidenceAge == 5)
    #expect(online.evidence.health.state == .current)
    #expect(online.evidence.inventory.state == .current)
    #expect(online.evidence.memory.state == .current)
    #expect(online.evidence.operations.state == .current)
    #expect(online.runtime.version == "1.0.0")
    #expect(online.runtime.health == .healthy)
    #expect(online.runtime.updateState == .current)
    #expect(online.vllmHealth == .ready)
    #expect(online.unifiedMemory?.availableBytes == 34_359_738_368)
    #expect(online.disk?.freeBytes == 90_000_000_000)
    #expect(online.installedModelCount == 2)
    #expect(online.activeInference?.activeRequests == 2)
    #expect(online.operations.count == 1)
    #expect(online.placements.count == 7)
    #expect(online.technicalDetails.logicalIdentity == online.identity.description)

    let delayed = try #require(snapshots["delayed"])
    #expect(delayed.connectionState == .delayed)
    #expect(delayed.evidence.health.state == .stale)
    #expect(delayed.evidence.inventory.state == .current)
    #expect(delayed.warnings.contains { $0.code == "target.delayed" })

    let offline = try #require(snapshots["offline"])
    #expect(offline.connectionState == .offlineCached)
    #expect(offline.evidence.health.state == .stale)
    #expect(offline.evidence.inventory.state == .stale)
    #expect(offline.evidence.memory.state == .stale)
    #expect(offline.evidence.operations.state == .stale)
    #expect(offline.unifiedMemory == online.unifiedMemory)
    #expect(offline.disk == online.disk)
    #expect(offline.installedModelCount == online.installedModelCount)
    #expect(offline.placements.map(\.identity) == online.placements.map(\.identity))

    let mismatch = try #require(snapshots["identityMismatch"])
    #expect(mismatch.connectionState == .identityMismatch)
    #expect(mismatch.lastSuccessfulContact == online.lastSuccessfulContact)
    #expect(mismatch.unifiedMemory == online.unifiedMemory)
    #expect(mismatch.blockers.contains { $0.code == "target.identity_mismatch" })

    let update = try #require(snapshots["updateAvailable"])
    #expect(update.runtime.updateState == .available)
    #expect(update.runtime.availableVersion == "1.1.0")
    #expect(update.warnings.contains { $0.code == "runtime.update_available" })

    let cluster = try #require(snapshots["degradedCluster"])
    #expect(cluster.identity == .cluster(OperationalSnapshotFixtures.clusterID))
    #expect(cluster.members.count == 2)
    #expect(cluster.members.contains { !$0.reachable })
    #expect(cluster.runtime.health == .degraded)
    #expect(cluster.vllmHealth == .failed)
    #expect(cluster.warnings.contains { $0.code == "cluster.degraded" })
    #expect(cluster.warnings.contains { $0.code == "runtime.degraded" })
}

@Test func placementMappingCoversEveryOperationalState() throws {
    let fixtures = OperationalSnapshotFixtures.self
    let online = fixtures.composer.compose(
        entry: fixtures.standaloneEntry(),
        evidence: try fixtures.evidence(),
        at: fixtures.now
    )
    let starting = fixtures.composer.compose(
        entry: fixtures.standaloneEntry(),
        evidence: try fixtures.evidence(inferenceState: "loading"),
        at: fixtures.now
    )
    let stopping = fixtures.composer.compose(
        entry: fixtures.standaloneEntry(),
        evidence: try fixtures.evidence(inferenceState: "unloading"),
        at: fixtures.now
    )
    let states = Set(
        online.placements.map(\.state)
            + starting.placements.map(\.state)
            + stopping.placements.map(\.state)
    )

    #expect(states == Set(ModelPlacementState.allCases))
    #expect(
        online.placements.first { $0.state == .unknown }?.blockers.contains {
            $0.code == "model.recipe_unverified"
        } == true
    )
}

@Test func routeChangesNeverChangeSnapshotIdentity() throws {
    let fixtures = OperationalSnapshotFixtures.self
    let evidence = try fixtures.evidence()
    let first = fixtures.composer.compose(
        entry: fixtures.standaloneEntry(host: "spark-a.local"),
        evidence: evidence,
        at: fixtures.now
    )
    let moved = fixtures.composer.compose(
        entry: fixtures.standaloneEntry(host: "192.0.2.44"),
        evidence: evidence,
        at: fixtures.now
    )

    #expect(first.identity == moved.identity)
    #expect(first.preferredRoute?.host == "spark-a.local")
    #expect(moved.preferredRoute?.host == "192.0.2.44")
    #expect(first.technicalDetails.logicalIdentity == moved.technicalDetails.logicalIdentity)
}

@MainActor
@Test func libraryPersistsCachedTruthAndReturnsItStaleAfterRelaunch() throws {
    let fixtures = OperationalSnapshotFixtures.self
    let store = MemoryLibraryStore()
    try store.save([fixtures.standaloneEntry()])
    let firstLibrary = SparkLibrary(
        store: store,
        operationalSnapshotComposer: fixtures.composer
    )
    firstLibrary.load()
    let recorded = try #require(
        firstLibrary.recordOperationalEvidence(
            try fixtures.evidence(),
            for: fixtures.standaloneEntry().id,
            at: fixtures.now
        )
    )
    #expect(recorded.installedModelCount == 2)

    let relaunched = SparkLibrary(
        store: store,
        operationalSnapshotComposer: fixtures.composer
    )
    relaunched.load()
    let offline = try #require(
        relaunched.operationalSnapshot(
            for: fixtures.standaloneEntry().id,
            at: fixtures.now.addingTimeInterval(120)
        )
    )

    #expect(offline.connectionState == .offlineCached)
    #expect(offline.installedModelCount == recorded.installedModelCount)
    #expect(offline.unifiedMemory == recorded.unifiedMemory)
    #expect(offline.placements.map(\.identity) == recorded.placements.map(\.identity))
    #expect(offline.evidence.inventory.state == .stale)
}

@MainActor
@Test func identityMismatchIsPersistedWithoutAcceptingNewEvidence() throws {
    let fixtures = OperationalSnapshotFixtures.self
    let store = MemoryLibraryStore()
    var entry = fixtures.standaloneEntry()
    entry.cachedOperationalSnapshot = fixtures.composer.compose(
        entry: entry,
        evidence: try fixtures.evidence(),
        at: fixtures.now
    )
    try store.save([entry])
    let library = SparkLibrary(store: store, operationalSnapshotComposer: fixtures.composer)
    library.load()

    let mismatch = try #require(
        library.recordOperationalEvidence(
            try fixtures.evidence(
                identity: .node(fixtures.otherNodeID),
                respondingNodeID: fixtures.otherNodeID,
                runtimeVersion: "9.9.9"
            ),
            for: entry.id,
            at: fixtures.now.addingTimeInterval(5)
        )
    )

    #expect(mismatch.runtime.version == "1.0.0")
    #expect(library.entry(id: entry.id)?.issue == .identityMismatch)
    #expect(library.entry(id: entry.id)?.connectionState == .identityMismatch)
}
