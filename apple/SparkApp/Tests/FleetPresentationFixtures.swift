import Foundation
import SparkCore
import SparkLibrary
import Testing

@testable import SparkAppComposition

// Uses fixed-time snapshots to exercise Fleet states without a network, live clock or view.
enum FleetPresentationTestFleetFixtures {
    static let now = Date(timeIntervalSince1970: 1_788_000_000)

    static func nodeID(_ seed: UInt8) -> SparkNodeID {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[15] = seed
        bytes[0] = 0x11
        return SparkNodeID(rawValue: UUID(uuid: uuid(from: bytes)))
    }

    static func clusterID(_ seed: UInt8) -> SparkClusterID {
        var bytes = [UInt8](repeating: 0, count: 16)
        bytes[15] = seed
        bytes[0] = 0x22
        return SparkClusterID(rawValue: UUID(uuid: uuid(from: bytes)))
    }

    private static func uuid(from bytes: [UInt8]) -> uuid_t {
        (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        )
    }

    static func freshness(
        observedAt: Date?,
        at date: Date = now,
        forceStale: Bool = false
    ) -> TargetEvidenceFreshness {
        let value = OperationalEvidenceFreshness(
            observedAt: observedAt,
            evaluatedAt: date,
            staleAfter: 60,
            forceStale: forceStale
        )
        return TargetEvidenceFreshness(
            health: value,
            inventory: value,
            memory: value,
            inference: value,
            operations: value
        )
    }

    static func placement(
        modelID: String,
        name: String,
        state: ModelPlacementState
    ) -> ModelPlacementSnapshot {
        let identity = ModelPlacementIdentity(modelID: modelID, recipeRevision: "rev-1")
        return ModelPlacementSnapshot(
            identity: identity,
            displayName: name,
            state: state,
            evidence: OperationalEvidenceFreshness(
                observedAt: now.addingTimeInterval(-5),
                evaluatedAt: now,
                staleAfter: 60
            ),
            technicalDetails: ModelPlacementTechnicalDetails(
                modelID: modelID,
                recipeRevision: "rev-1",
                sourceRevision: nil
            )
        )
    }

    /// A healthy standalone Spark with a model loaded and serving.
    static func online(
        name: String = "Studio Spark",
        seed: UInt8 = 1,
        placements: [ModelPlacementSnapshot] = [
            placement(modelID: "m-8b", name: "Compact 8B", state: .running)
        ],
        installedModelCount: Int = 3,
        inference: SparkInferenceState = .ready,
        updateState: SparkRuntimeUpdateState = .current,
        warnings: [OperationalNotice] = [],
        blockers: [OperationalNotice] = [],
        temperatureCelsius: Double? = nil
    ) -> TargetOperationalSnapshot {
        let node = nodeID(seed)
        return TargetOperationalSnapshot(
            identity: .node(node),
            displayName: name,
            members: [
                TargetMemberSnapshot(
                    nodeID: node,
                    displayName: name,
                    role: .standalone,
                    reachable: true,
                    linkHealth: "healthy",
                    lastSuccessfulContact: now.addingTimeInterval(-5)
                )
            ],
            preferredRoute: PreferredRouteSummary(
                kind: .localWiFi,
                host: "studio-spark.local",
                port: 7_443,
                interfaceName: "en0",
                lastSuccessfulAt: now.addingTimeInterval(-5),
                isMetered: false
            ),
            connectionState: .connectedWiFi,
            lastSuccessfulContact: now.addingTimeInterval(-5),
            evaluatedAt: now,
            evidence: freshness(observedAt: now.addingTimeInterval(-5)),
            runtime: TargetRuntimeSnapshot(
                version: "1.4.0",
                health: .healthy,
                updateState: updateState
            ),
            vllmHealth: .ready,
            unifiedMemory: UnifiedMemorySnapshot(
                totalBytes: 128_000_000_000,
                availableBytes: 62_100_000_000,
                pressure: .normal
            ),
            disk: DiskCapacitySnapshot(freeBytes: 900_000_000_000),
            installedModelCount: installedModelCount,
            activeInference: ActiveInferenceSnapshot(
                state: inference,
                modelIdentity: placements.first?.identity,
                profileID: "balanced",
                activeRequests: 1,
                queueDepth: 0,
                tokensPerSecond: 42,
                timeToFirstTokenMilliseconds: 180
            ),
            operations: [],
            placements: placements,
            warnings: warnings,
            blockers: blockers,
            technicalDetails: TargetTechnicalDetails(
                logicalIdentity: SparkTargetIdentity.node(node).description,
                memberNodeIDs: [node]
            ),
            temperatureCelsius: temperatureCelsius
        )
    }

    /// A Spark that has not answered for a while but is still contactable.
    static func delayed(name: String = "Loft Spark", seed: UInt8 = 2)
        -> TargetOperationalSnapshot
    {
        let base = online(name: name, seed: seed)
        return rebuilt(
            base,
            connectionState: .delayed,
            lastSuccessfulContact: now.addingTimeInterval(-300),
            warnings: [
                OperationalNotice(
                    code: "target.delayed",
                    message: "The latest authenticated response is delayed."
                )
            ]
        )
    }

    /// Retain last authenticated values while marking every evidence class stale for offline targets.
    static func offline(name: String = "Garage Spark", seed: UInt8 = 3)
        -> TargetOperationalSnapshot
    {
        let base = online(name: name, seed: seed)
        return rebuilt(
            base,
            connectionState: .offlineCached,
            lastSuccessfulContact: now.addingTimeInterval(-7_200),
            evidence: freshness(observedAt: now.addingTimeInterval(-7_200), forceStale: true),
            warnings: [
                OperationalNotice(
                    code: "target.offline",
                    message: "Showing the last authenticated state while the target is offline."
                )
            ]
        )
    }

    /// A saved route that now authenticates as a different Spark.
    static func identityMismatch(name: String = "Desk Spark", seed: UInt8 = 4)
        -> TargetOperationalSnapshot
    {
        let base = online(name: name, seed: seed)
        return rebuilt(
            base,
            connectionState: .identityMismatch,
            lastSuccessfulContact: now.addingTimeInterval(-600),
            evidence: freshness(observedAt: now.addingTimeInterval(-600), forceStale: true),
            blockers: [
                OperationalNotice(
                    code: "target.identity_mismatch",
                    message: "The saved route presented a different Spark identity."
                )
            ]
        )
    }

    /// Models a saved target with no authenticated operational reading.
    static func withoutEvidence(name: String = "New Spark", seed: UInt8 = 5)
        -> TargetOperationalSnapshot
    {
        let node = nodeID(seed)
        return TargetOperationalSnapshot(
            identity: .node(node),
            displayName: name,
            members: [
                TargetMemberSnapshot(
                    nodeID: node,
                    displayName: name,
                    role: .standalone,
                    reachable: false
                )
            ],
            preferredRoute: nil,
            connectionState: .offlineCached,
            lastSuccessfulContact: nil,
            evaluatedAt: now,
            evidence: freshness(observedAt: nil),
            runtime: TargetRuntimeSnapshot(version: nil, health: .unknown, updateState: .unknown),
            vllmHealth: .unknown,
            unifiedMemory: nil,
            disk: nil,
            installedModelCount: 0,
            activeInference: nil,
            operations: [],
            placements: [],
            warnings: [],
            blockers: [],
            technicalDetails: TargetTechnicalDetails(
                logicalIdentity: SparkTargetIdentity.node(node).description,
                memberNodeIDs: [node]
            )
        )
    }

    /// A two-node logical cluster with one member unreachable.
    static func degradedCluster(name: String = "Studio Cluster", seed: UInt8 = 6)
        -> TargetOperationalSnapshot
    {
        let cluster = clusterID(seed)
        let leader = nodeID(10 + seed)
        let worker = nodeID(20 + seed)
        return TargetOperationalSnapshot(
            identity: .cluster(cluster),
            displayName: name,
            members: [
                TargetMemberSnapshot(
                    nodeID: leader,
                    displayName: "Coordinator",
                    role: .leader,
                    reachable: true,
                    linkHealth: "healthy",
                    lastSuccessfulContact: now.addingTimeInterval(-5)
                ),
                TargetMemberSnapshot(
                    nodeID: worker,
                    displayName: "Worker One",
                    role: .worker,
                    reachable: false,
                    linkHealth: "degraded",
                    lastSuccessfulContact: now.addingTimeInterval(-900)
                ),
            ],
            preferredRoute: PreferredRouteSummary(
                kind: .directEthernet,
                host: "cluster-leader.local",
                port: 7_443,
                interfaceName: "en1",
                lastSuccessfulAt: now.addingTimeInterval(-5),
                isMetered: false
            ),
            connectionState: .connectedDirect,
            lastSuccessfulContact: now.addingTimeInterval(-5),
            evaluatedAt: now,
            evidence: freshness(observedAt: now.addingTimeInterval(-5)),
            runtime: TargetRuntimeSnapshot(
                version: "1.4.0",
                health: .healthy,
                updateState: .available
            ),
            vllmHealth: .ready,
            unifiedMemory: UnifiedMemorySnapshot(
                totalBytes: 256_000_000_000,
                availableBytes: 40_000_000_000,
                pressure: .normal
            ),
            disk: DiskCapacitySnapshot(freeBytes: 1_800_000_000_000),
            installedModelCount: 5,
            activeInference: ActiveInferenceSnapshot(
                state: .unloaded,
                modelIdentity: nil,
                profileID: nil,
                activeRequests: 0,
                queueDepth: 0,
                tokensPerSecond: nil,
                timeToFirstTokenMilliseconds: nil
            ),
            operations: [],
            placements: [placement(modelID: "m-70b", name: "Wide 70B", state: .installed)],
            warnings: [
                OperationalNotice(
                    code: "cluster.degraded",
                    message: "One or more cluster members or links are degraded."
                )
            ],
            blockers: [],
            technicalDetails: TargetTechnicalDetails(
                logicalIdentity: SparkTargetIdentity.cluster(cluster).description,
                memberNodeIDs: [leader, worker]
            )
        )
    }

    /// The route a Spark away from home answers on, so a card has a tailnet path to name.
    static let tailnetRoute = PreferredRouteSummary(
        kind: .privateOverlay,
        host: "spark-example.tail1234.ts.net",
        port: 7_443,
        interfaceName: nil,
        lastSuccessfulAt: now.addingTimeInterval(-5),
        isMetered: false
    )

    /// A Spark reached over the tailnet rather than on the local network.
    static func overTailscale(name: String = "Loft Spark", seed: UInt8 = 4)
        -> TargetOperationalSnapshot
    {
        rebuilt(
            online(name: name, seed: seed),
            preferredRoute: tailnetRoute,
            connectionState: .connectedRemote
        )
    }

    /// Rebuilds immutable operational snapshots with selected fields replaced for each test.
    static func rebuilt(
        _ snapshot: TargetOperationalSnapshot,
        identity: SparkTargetIdentity? = nil,
        preferredRoute: PreferredRouteSummary? = nil,
        connectionState: TargetConnectionState? = nil,
        lastSuccessfulContact: Date?? = nil,
        evidence: TargetEvidenceFreshness? = nil,
        warnings: [OperationalNotice]? = nil,
        blockers: [OperationalNotice]? = nil,
        operations: [TargetOperationSnapshot]? = nil
    ) -> TargetOperationalSnapshot {
        TargetOperationalSnapshot(
            identity: identity ?? snapshot.identity,
            displayName: snapshot.displayName,
            members: snapshot.members,
            preferredRoute: preferredRoute ?? snapshot.preferredRoute,
            connectionState: connectionState ?? snapshot.connectionState,
            lastSuccessfulContact: lastSuccessfulContact ?? snapshot.lastSuccessfulContact,
            evaluatedAt: snapshot.evaluatedAt,
            evidence: evidence ?? snapshot.evidence,
            runtime: snapshot.runtime,
            vllmHealth: snapshot.vllmHealth,
            unifiedMemory: snapshot.unifiedMemory,
            disk: snapshot.disk,
            installedModelCount: snapshot.installedModelCount,
            activeInference: snapshot.activeInference,
            operations: operations ?? snapshot.operations,
            placements: snapshot.placements,
            warnings: warnings ?? snapshot.warnings,
            blockers: blockers ?? snapshot.blockers,
            technicalDetails: snapshot.technicalDetails,
            temperatureCelsius: snapshot.temperatureCelsius
        )
    }

    static func input(
        _ snapshot: TargetOperationalSnapshot,
        canOpen: Bool = true,
        hasIdentityIssue: Bool = false,
        isExternallyConfiguredCluster: Bool = false
    ) -> FleetTargetInput {
        FleetTargetInput(
            id: snapshot.identity.description,
            snapshot: snapshot,
            canOpen: canOpen,
            hasIdentityIssue: hasIdentityIssue,
            isExternallyConfiguredCluster: isExternallyConfiguredCluster
        )
    }
}
