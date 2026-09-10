import Foundation
import SparkAPI
import SparkCore

/// Pairs a successful endpoint response with its authenticated completion time.
public struct TimedOperationalEvidence<Value: Sendable>: Sendable {
    public let value: Value
    public let observedAt: Date

    public init(_ value: Value, observedAt: Date) {
        self.value = value
        self.observedAt = observedAt
    }
}

/// Version evidence from the verified runtime release channel.
public struct RuntimeReleaseEvidence: Hashable, Sendable {
    public let availableVersion: String
    public let minimumSupportedVersion: String?
    public let observedAt: Date

    public init(
        availableVersion: String,
        minimumSupportedVersion: String? = nil,
        observedAt: Date
    ) {
        self.availableVersion = availableVersion
        self.minimumSupportedVersion = minimumSupportedVersion
        self.observedAt = observedAt
    }
}

/// Binds endpoint evidence to one pinned target identity with independent timestamps so slow reads cannot freshen unrelated data.
public struct TargetOperationalEvidence: Sendable {
    public let identity: SparkTargetIdentity
    public let respondingNodeID: SparkNodeID
    public let health: TimedOperationalEvidence<Health>?
    public let status: TimedOperationalEvidence<SparkStatus>?
    public let inventory: TimedOperationalEvidence<ModelCatalogue>?
    public let inference: TimedOperationalEvidence<ActiveInference>?
    public let operations: TimedOperationalEvidence<[SparkAPI.Operation]>?
    public let release: RuntimeReleaseEvidence?

    public init(
        identity: SparkTargetIdentity,
        respondingNodeID: SparkNodeID,
        health: TimedOperationalEvidence<Health>? = nil,
        status: TimedOperationalEvidence<SparkStatus>? = nil,
        inventory: TimedOperationalEvidence<ModelCatalogue>? = nil,
        inference: TimedOperationalEvidence<ActiveInference>? = nil,
        operations: TimedOperationalEvidence<[SparkAPI.Operation]>? = nil,
        release: RuntimeReleaseEvidence? = nil
    ) {
        self.identity = identity
        self.respondingNodeID = respondingNodeID
        self.health = health
        self.status = status
        self.inventory = inventory
        self.inference = inference
        self.operations = operations
        self.release = release
    }

    fileprivate var latestContact: Date? {
        [
            health?.observedAt,
            status?.observedAt,
            inventory?.observedAt,
            inference?.observedAt,
            operations?.observedAt,
        ].compactMap { $0 }.max()
    }
}

public struct TargetOperationalSnapshotComposer: Sendable {
    public let freshnessPolicy: OperationalFreshnessPolicy

    public init(freshnessPolicy: OperationalFreshnessPolicy = .standard) {
        self.freshnessPolicy = freshnessPolicy
    }

    /// Merges current evidence with cached values only when logical identity matches.
    public func compose(
        entry: LibraryEntry,
        evidence: TargetOperationalEvidence,
        at date: Date
    ) -> TargetOperationalSnapshot {
        guard identityMatches(entry: entry, evidence: evidence) else {
            return cachedSnapshot(
                entry: entry,
                at: date,
                forcedConnection: .identityMismatch,
                extraBlocker: OperationalNotice(
                    code: "target.identity_mismatch",
                    message: String(
                        localized: "The responding Spark has a different logical identity."
                    )
                )
            )
        }
        return assemble(entry: entry, evidence: evidence, at: date)
    }

    /// Marks retained evidence stale for offline or identity-blocked entries without implying a successful probe.
    public func cachedSnapshot(entry: LibraryEntry, at date: Date) -> TargetOperationalSnapshot {
        var connection: TargetConnectionState =
            entry.issue == .identityMismatch ? .identityMismatch : map(entry.connectionState)
        if connection != .offlineCached, connection != .identityMismatch,
            connection != .updateRequired,
            let lastContact = entry.cachedOperationalSnapshot?.lastSuccessfulContact
                ?? entry.lastSeen,
            max(0, date.timeIntervalSince(lastContact)) > freshnessPolicy.delayedAfter
        {
            connection = .delayed
        }
        return cachedSnapshot(
            entry: entry,
            at: date,
            forcedConnection: connection,
            extraBlocker: entry.issue == .identityMismatch
                ? OperationalNotice(
                    code: "target.identity_mismatch",
                    message: String(
                        localized: "The saved route presented a different Spark identity."
                    )
                )
                : nil
        )
    }

    private func assemble(
        entry: LibraryEntry,
        evidence: TargetOperationalEvidence,
        at date: Date
    ) -> TargetOperationalSnapshot {
        let cached = entry.cachedOperationalSnapshot
        let lastContact = newest(
            cached?.lastSuccessfulContact,
            entry.lastSeen,
            evidence.latestContact
        )

        var connection = connectedState(for: entry.connectRoute?.kind)
        if let age = lastContact.map({ max(0, date.timeIntervalSince($0)) }),
            age > freshnessPolicy.delayedAfter
        {
            connection = .delayed
        }

        let runtime = runtimeSnapshot(evidence: evidence, cached: cached)
        if runtime.updateState == .required {
            connection = .updateRequired
        }

        let freshness = evidenceFreshness(
            evidence: evidence,
            cached: cached,
            at: date,
            forceStale: false
        )
        let placements = placementSnapshots(
            inventory: evidence.inventory,
            inference: evidence.inference,
            status: evidence.status,
            cached: cached,
            evidenceFreshness: freshness.inventory
        )
        let activeInference = activeInferenceSnapshot(
            evidence: evidence,
            placements: placements,
            cached: cached
        )
        let members = memberSnapshots(
            entry: entry,
            status: evidence.status,
            observedAt: lastContact
        )
        let memory =
            evidence.status.map {
                UnifiedMemorySnapshot(
                    totalBytes: $0.value.system.unifiedMemoryTotalBytes,
                    availableBytes: $0.value.system.unifiedMemoryAvailableBytes,
                    pressure: SparkMemoryPressure(rawValue: $0.value.system.memoryPressure)
                        ?? .unknown
                )
            } ?? cached?.unifiedMemory
        let disk =
            evidence.status.map { DiskCapacitySnapshot(freeBytes: $0.value.system.diskFreeBytes) }
            ?? cached?.disk
        let temperature =
            evidence.status.flatMap { $0.value.system.temperatureCelsius }
            ?? cached?.temperatureCelsius
        let operations =
            evidence.operations.map { operationSnapshots($0.value) }
            ?? cached?.operations ?? []
        let installedCount =
            evidence.inventory.map { catalogue in
                catalogue.value.items.count { $0.installState == .installed }
            } ?? cached?.installedModelCount ?? 0
        let vllmHealth = vllmHealth(evidence: evidence) ?? cached?.vllmHealth ?? .unknown
        let notices = notices(
            connection: connection,
            freshness: freshness,
            runtime: runtime,
            vllmHealth: vllmHealth,
            memory: memory,
            temperatureCelsius: temperature,
            members: members,
            operations: operations,
            unsignedCatalogueItems: evidence.inventory?.value.items.count {
                $0.recipeRevision?.isEmpty != false
            } ?? 0,
            extraBlocker: nil
        )

        return TargetOperationalSnapshot(
            identity: entry.logicalKey,
            displayName: entry.displayName,
            members: members,
            preferredRoute: routeSummary(entry.preferredRoute),
            connectionState: connection,
            lastSuccessfulContact: lastContact,
            evaluatedAt: date,
            evidence: freshness,
            runtime: runtime,
            vllmHealth: vllmHealth,
            unifiedMemory: memory,
            disk: disk,
            installedModelCount: installedCount,
            activeInference: activeInference,
            operations: operations,
            placements: placements,
            warnings: notices.warnings,
            blockers: notices.blockers,
            technicalDetails: technicalDetails(identity: entry.logicalKey, members: members),
            temperatureCelsius: temperature,
            routeInUse: routeSummary(entry.routeInUse)
        )
    }

    private func cachedSnapshot(
        entry: LibraryEntry,
        at date: Date,
        forcedConnection: TargetConnectionState,
        extraBlocker: OperationalNotice?
    ) -> TargetOperationalSnapshot {
        let cached = entry.cachedOperationalSnapshot
        let forceStale = forcedConnection == .offlineCached || forcedConnection == .identityMismatch
        let freshness =
            cached?.evidence.reassessed(at: date, forceStale: forceStale)
            ?? missingFreshness(at: date)
        let members =
            cached?.members.map {
                TargetMemberSnapshot(
                    nodeID: $0.nodeID,
                    displayName: $0.displayName,
                    role: $0.role,
                    reachable: forceStale ? false : $0.reachable,
                    linkHealth: $0.linkHealth,
                    lastSuccessfulContact: $0.lastSuccessfulContact
                )
            } ?? memberSnapshots(entry: entry, status: nil, observedAt: entry.lastSeen)
        let runtime =
            cached?.runtime
            ?? TargetRuntimeSnapshot(version: nil, health: .unknown, updateState: .unknown)
        let vllmHealth = cached?.vllmHealth ?? .unknown
        let memory = cached?.unifiedMemory
        let operations = cached?.operations ?? []
        let placements = (cached?.placements ?? []).map {
            ModelPlacementSnapshot(
                identity: $0.identity,
                displayName: $0.displayName,
                state: $0.state,
                evidence: freshness.inventory,
                technicalDetails: $0.technicalDetails,
                warnings: $0.warnings,
                blockers: $0.blockers
            )
        }
        let notices = notices(
            connection: forcedConnection,
            freshness: freshness,
            runtime: runtime,
            vllmHealth: vllmHealth,
            memory: memory,
            temperatureCelsius: cached?.temperatureCelsius,
            members: members,
            operations: operations,
            unsignedCatalogueItems: 0,
            extraBlocker: extraBlocker
        )

        return TargetOperationalSnapshot(
            identity: entry.logicalKey,
            displayName: entry.displayName,
            members: members,
            preferredRoute: routeSummary(entry.preferredRoute),
            connectionState: forcedConnection,
            lastSuccessfulContact: cached?.lastSuccessfulContact ?? entry.lastSeen,
            evaluatedAt: date,
            evidence: freshness,
            runtime: runtime,
            vllmHealth: vllmHealth,
            unifiedMemory: memory,
            disk: cached?.disk,
            installedModelCount: cached?.installedModelCount ?? 0,
            activeInference: cached?.activeInference,
            operations: operations,
            placements: placements,
            warnings: notices.warnings,
            blockers: notices.blockers,
            technicalDetails: technicalDetails(identity: entry.logicalKey, members: members),
            temperatureCelsius: cached?.temperatureCelsius,
            routeInUse: routeSummary(entry.routeInUse)
        )
    }

    private func identityMatches(
        entry: LibraryEntry,
        evidence: TargetOperationalEvidence
    ) -> Bool {
        guard evidence.identity == entry.logicalKey,
            evidence.respondingNodeID == entry.coordinatorNodeID
        else { return false }
        if let health = evidence.health, health.value.nodeID != evidence.respondingNodeID {
            return false
        }
        if let status = evidence.status {
            guard status.value.identity.nodeID == evidence.respondingNodeID else { return false }
            let statusIdentity: SparkTargetIdentity =
                status.value.identity.clusterID.map {
                    .cluster($0)
                } ?? .node(status.value.identity.nodeID)
            guard statusIdentity == entry.logicalKey else { return false }
            if let reportedCluster = status.value.cluster?.id,
                case .cluster(let expectedCluster) = entry.logicalKey,
                reportedCluster != expectedCluster
            {
                return false
            }
        }
        return true
    }
}
