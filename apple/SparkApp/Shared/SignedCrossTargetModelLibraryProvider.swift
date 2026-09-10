import Foundation
import Observation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity

// MARK: - Signed production provider

public protocol CrossTargetModelLibraryDataProviding: Sendable {
    @MainActor
    func fetchSnapshot() async throws -> CrossTargetModelLibrarySnapshot
}

public struct ModelLibraryRuntimeConnection: Sendable {
    public let route: URL
    public let expectedNodeID: SparkNodeID
    public let expectedClusterID: SparkClusterID?
    public let expectedAuthorityFingerprint: String
    public let runtime: any SparkRuntimeReading
    public let serviceSettings: (any ModelServiceSettingsReading)?

    public init(
        route: URL,
        expectedNodeID: SparkNodeID,
        expectedClusterID: SparkClusterID?,
        expectedAuthorityFingerprint: String,
        runtime: any SparkRuntimeReading,
        serviceSettings: (any ModelServiceSettingsReading)? = nil
    ) {
        self.route = route
        self.expectedNodeID = expectedNodeID
        self.expectedClusterID = expectedClusterID
        self.expectedAuthorityFingerprint = expectedAuthorityFingerprint
        self.runtime = runtime
        self.serviceSettings = serviceSettings
    }
}

public typealias ModelLibraryRuntimeResolver =

    @MainActor @Sendable (LibraryEntry) throws -> ModelLibraryRuntimeConnection

enum ModelLibraryOperationalSnapshotAdapter {
    static func evidence(
        from snapshot: TargetOperationalSnapshot,
        catalogue: ModelCatalogue? = nil,
        services: ModelServiceTargetSnapshot? = nil
    ) -> ModelLibraryTargetEvidence {
        let topology: ModelLibraryTargetTopology
        switch snapshot.identity {
        case .node:
            topology = ModelLibraryTargetTopology(
                kind: .standalone,
                memberCount: max(snapshot.members.count, 1),
                reachableMemberCount: snapshot.members.count(where: \.reachable)
            )
        case .cluster:
            let memberCount = snapshot.members.count
            let reachableMemberCount = snapshot.members.count(where: \.reachable)
            topology = ModelLibraryTargetTopology(
                kind: .cluster,
                memberCount: memberCount,
                reachableMemberCount: reachableMemberCount,
                state: memberCount > 1 && reachableMemberCount == memberCount
                    ? "ready"
                    : "degraded"
            )
        }

        let freshness = freshness(snapshot.evidence)
        var catalogueByIdentity: [ModelPlacementIdentity: SparkModel] = [:]
        for model in catalogue?.items ?? [] {
            guard let revision = model.recipeRevision, !revision.isEmpty else { continue }
            let identity = ModelPlacementIdentity(modelID: model.id, recipeRevision: revision)
            if catalogueByIdentity[identity] == nil {
                catalogueByIdentity[identity] = model
            }
        }
        let recipes = snapshot.placements.map { placement in
            let model = catalogueByIdentity[placement.identity]
            return ModelLibraryRecipeEvidence(
                modelID: placement.identity.modelID,
                displayName: placement.displayName,
                summary: model?.description,
                recipeRevision: placement.identity.recipeRevision,
                sourceRevision: placement.technicalDetails.sourceRevision,
                installState: installState(for: placement),
                downloadBytes: model?.totalBytes,
                capabilities: Set(
                    model?.capabilities.compactMap { key, enabled in enabled ? key : nil } ?? []
                ),
                rawFit: model?.fit,
                profiles: model?.profiles.map {
                    ModelLibraryProfileEvidence(
                        id: $0.id,
                        name: $0.displayName,
                        expectedPeakBytes: $0.expectedPeakBytes,
                        isSafe: $0.safe,
                        maxModelLength: $0.maxModelLength,
                        maxSequences: $0.maxSequences
                    )
                } ?? [],
                operationalState: placement.state
            )
        }

        return ModelLibraryTargetEvidence(
            id: snapshot.identity.description,
            name: snapshot.displayName,
            connectionLabel: ModelLibraryTargetEvidence.connectionLabel(
                for: snapshot.connectionState
            ),
            topology: topology,
            freshness: freshness,
            availableMemoryBytes: snapshot.unifiedMemory?.availableBytes,
            runtimeVersion: snapshot.runtime.version,
            activeModelID: snapshot.activeInference?.modelIdentity?.modelID,
            activeModelIdentity: snapshot.activeInference?.modelIdentity,
            activeInferenceState: snapshot.activeInference?.state,
            recipes: recipes,
            services: services
        )
    }

    private static func freshness(
        _ evidence: TargetEvidenceFreshness
    ) -> ModelLibraryEvidenceFreshness {
        let required = [evidence.inventory, evidence.memory]
        guard required.allSatisfy({ $0.state != .missing }) else { return .unavailable }
        guard let observedAt = required.compactMap(\.observedAt).min() else {
            return .unavailable
        }
        return required.allSatisfy { $0.state == .current }
            ? .current(observedAt: observedAt)
            : .stale(observedAt: observedAt)
    }

    private static func installState(
        for placement: ModelPlacementSnapshot
    ) -> SparkModelInstallState? {
        if placement.blockers.contains(where: { $0.code == "model.recipe_unverified" }) {
            return .unverified
        }
        return switch placement.state {
        case .available: .available
        case .downloading: .downloading
        case .installed, .starting, .running, .stopping: .installed
        case .failed: .failed
        case .incompatible: .incompatible
        case .unknown: nil
        }
    }
}

private struct ModelLibraryLiveRead: Sendable {
    let evidence: TargetOperationalEvidence
    let catalogue: ModelCatalogue
    let services: ModelServiceTargetSnapshot
}

@MainActor
public final class SignedCrossTargetModelLibraryProvider: CrossTargetModelLibraryDataProviding,
    @unchecked Sendable
{
    private let library: SparkLibrary
    private let runtimeResolver: ModelLibraryRuntimeResolver
    private let visibilityPolicy: ModelLibraryVisibilityPolicy
    private let now: @Sendable () -> Date

    public init(
        library: SparkLibrary,
        visibilityPolicy: ModelLibraryVisibilityPolicy = .standard,
        now: @escaping @Sendable () -> Date = Date.init,
        runtimeResolver: ModelLibraryRuntimeResolver? = nil
    ) {
        self.library = library
        self.visibilityPolicy = visibilityPolicy
        self.now = now
        self.runtimeResolver =
            runtimeResolver ?? { entry in
                try Self.productionRuntime(entry: entry)
            }
    }

    /// Publishes fresh inference and reachability independently so slower catalogue or service reads cannot delay chat readiness.
    public func refreshChatEvidence() async {
        await withTaskGroup(of: Void.self) { group in
            for entry in library.entries {
                group.addTask { await self.refreshChatEvidence(for: entry) }
            }
        }
    }

    private func refreshChatEvidence(for entry: LibraryEntry) async {
        guard !Task.isCancelled, entry.issue == nil,
            let connection = try? runtimeResolver(entry)
        else { return }
        let health: Health
        do {
            health = try await connection.runtime.health(route: connection.route)
        } catch {
            guard chatReadStillApplies(to: entry) else { return }
            library.markUnreachable(entryID: entry.id, at: now())
            return
        }
        guard chatReadStillApplies(to: entry) else { return }
        guard health.nodeID == connection.expectedNodeID else {
            library.markIdentityMismatch(entryID: entry.id, presented: health.nodeID, at: now())
            return
        }
        let healthObservedAt = now()
        library.recordOperationalEvidence(
            TargetOperationalEvidence(
                identity: entry.logicalKey,
                respondingNodeID: connection.expectedNodeID,
                health: TimedOperationalEvidence(health, observedAt: healthObservedAt)
            ),
            for: entry.id,
            at: healthObservedAt
        )

        do {
            let status = try await connection.runtime.status(route: connection.route)
            guard chatReadStillApplies(to: entry) else { return }
            do {
                try Self.validateIdentity(health: health, status: status, connection: connection)
            } catch {
                library.markIdentityMismatch(
                    entryID: entry.id,
                    presented: status.identity.nodeID,
                    at: now()
                )
                return
            }
            let statusObservedAt = now()
            library.recordOperationalEvidence(
                TargetOperationalEvidence(
                    identity: entry.logicalKey,
                    respondingNodeID: connection.expectedNodeID,
                    status: TimedOperationalEvidence(status, observedAt: statusObservedAt)
                ),
                for: entry.id,
                at: statusObservedAt
            )
        } catch {
            // Keep inference evidence stale and sending disabled until authenticated status succeeds, even if health proves reachability.
        }
    }

    private func chatReadStillApplies(to entry: LibraryEntry) -> Bool {
        guard !Task.isCancelled, let current = library.entry(id: entry.id) else { return false }
        return current.issue == nil && current.logicalKey == entry.logicalKey
            && current.coordinatorNodeID == entry.coordinatorNodeID
            && current.preferredRoute?.baseURL == entry.preferredRoute?.baseURL
            && current.clusterID == entry.clusterID
    }

    public func fetchSnapshot() async throws -> CrossTargetModelLibrarySnapshot {
        let observedAt = now()
        let entries = library.entries.sorted { $0.id < $1.id }

        var prepared: [(LibraryEntry, ModelLibraryRuntimeConnection)] = []
        for entry in entries {
            do {
                prepared.append((entry, try runtimeResolver(entry)))
            } catch {
                continue
            }
        }

        let reads = await withTaskGroup(
            of: (String, ModelLibraryLiveRead?).self,
            returning: [String: ModelLibraryLiveRead].self
        ) { group in
            for (entry, connection) in prepared {
                group.addTask {
                    let evidence = try? await Self.read(
                        entry: entry,
                        connection: connection,
                        observedAt: observedAt
                    )
                    return (entry.id, evidence)
                }
            }
            var results: [String: ModelLibraryLiveRead] = [:]
            for await (id, evidence) in group {
                if let evidence { results[id] = evidence }
            }
            return results
        }

        // Cancellation provides no reachability evidence, so leave cached target state unchanged instead of marking Sparks unreachable.
        try Task.checkCancellation()

        var evidence: [ModelLibraryTargetEvidence] = []
        for entry in library.entries.sorted(by: { $0.id < $1.id }) {
            let operationalSnapshot: TargetOperationalSnapshot?
            let liveCatalogue: ModelCatalogue?
            if let live = reads[entry.id] {
                operationalSnapshot = library.recordOperationalEvidence(
                    live.evidence,
                    for: entry.id,
                    at: observedAt
                )
                liveCatalogue = live.catalogue
            } else {
                library.markUnreachable(entryID: entry.id, at: observedAt)
                operationalSnapshot = library.operationalSnapshot(
                    for: entry.id,
                    at: observedAt
                )
                liveCatalogue = nil
            }

            if let operationalSnapshot {
                evidence.append(
                    ModelLibraryOperationalSnapshotAdapter.evidence(
                        from: operationalSnapshot,
                        catalogue: liveCatalogue,
                        services: reads[entry.id]?.services
                    )
                )
            } else {
                evidence.append(.unavailable(for: entry))
            }
        }

        return CrossTargetModelLibraryAggregator.snapshot(
            targets: evidence,
            generatedAt: observedAt,
            visibilityPolicy: visibilityPolicy
        )
    }

    static func productionRuntime(
        entry: LibraryEntry
    ) throws -> ModelLibraryRuntimeConnection {
        try productionRuntime(entry: entry, trustReader: StoredNodeTrust.reader) { nodeID, trust in
            let signer = try DeviceIdentityStore.loadOrCreateSigner(nodeID: nodeID.rawValue)
            return try SparkAPIClient.pinned(to: trust.tlsFingerprint, signer: signer)
        }
    }

    static func productionRuntime(
        entry: LibraryEntry,
        trustReader: @Sendable (String) -> NodeTrust?,
        clientProvider: (SparkNodeID, NodeTrust) throws -> any SparkRuntimeReading
    ) throws -> ModelLibraryRuntimeConnection {
        guard entry.issue == nil,
            let nodeID = entry.coordinatorNodeID,
            let route = entry.connectRoute?.baseURL,
            let trust = trustReader(nodeID.rawValue.uuidString.lowercased())
        else {
            throw ModelLibraryProviderError.authenticatedRouteUnavailable
        }
        let runtime = try clientProvider(nodeID, trust)
        return ModelLibraryRuntimeConnection(
            route: route,
            expectedNodeID: nodeID,
            expectedClusterID: entry.clusterID,
            expectedAuthorityFingerprint: trust.authorityFingerprint,
            runtime: runtime,
            serviceSettings: runtime as? any ModelServiceSettingsReading
        )
    }

    private static func read(
        entry: LibraryEntry,
        connection: ModelLibraryRuntimeConnection,
        observedAt: Date
    ) async throws -> ModelLibraryLiveRead {
        async let loadedHealth = connection.runtime.health(route: connection.route)
        async let loadedStatus = connection.runtime.status(route: connection.route)
        async let loadedCatalogue = connection.runtime.models(route: connection.route)
        async let loadedCapabilities = try? connection.runtime.capabilities(route: connection.route)
        async let loadedWorkloads = try? connection.runtime.workloads(route: connection.route)
        async let loadedOpenWebUI = try? connection.runtime.openWebUIStatus(route: connection.route)
        async let loadedCatalogueStatus = try? connection.runtime.catalogueStatus(
            route: connection.route
        )
        async let loadedOperations = try? readOperations(connection: connection)
        async let loadedSettings = try? connection.serviceSettings?.sparkSettings(
            route: connection.route
        )

        let health = try await loadedHealth
        let status = try await loadedStatus
        let catalogue = try await loadedCatalogue
        let serviceEvidence = await (
            capabilities: loadedCapabilities,
            workloads: loadedWorkloads,
            openWebUI: loadedOpenWebUI,
            catalogueStatus: loadedCatalogueStatus,
            operations: loadedOperations,
            settings: loadedSettings
        )

        try validateIdentity(health: health, status: status, connection: connection)

        return ModelLibraryLiveRead(
            evidence: TargetOperationalEvidence(
                identity: entry.logicalKey,
                respondingNodeID: connection.expectedNodeID,
                health: TimedOperationalEvidence(health, observedAt: observedAt),
                status: TimedOperationalEvidence(status, observedAt: observedAt),
                inventory: TimedOperationalEvidence(catalogue, observedAt: observedAt),
                operations: serviceEvidence.operations.map {
                    TimedOperationalEvidence($0, observedAt: observedAt)
                }
            ),
            catalogue: catalogue,
            services: ModelServiceDashboardAdapter.snapshot(
                observedAt: observedAt,
                runtimeVersion: health.runtimeVersion,
                runtimeHealthy: health.isOK,
                capabilities: serviceEvidence.capabilities,
                workloads: serviceEvidence.workloads,
                openWebUI: serviceEvidence.openWebUI,
                settings: serviceEvidence.settings ?? nil,
                catalogueStatus: serviceEvidence.catalogueStatus,
                catalogueRecipeCount: catalogue.items.count
            )
        )
    }

    private static func validateIdentity(
        health: Health,
        status: SparkStatus,
        connection: ModelLibraryRuntimeConnection
    ) throws {
        guard health.nodeID == connection.expectedNodeID,
            status.identity.nodeID == connection.expectedNodeID,
            status.identity.authorityFingerprint.lowercased()
                == connection.expectedAuthorityFingerprint.lowercased()
        else {
            throw ModelLibraryProviderError.identityMismatch
        }
        if let expectedClusterID = connection.expectedClusterID {
            guard status.identity.clusterID == expectedClusterID,
                status.cluster?.id == expectedClusterID
            else {
                throw ModelLibraryProviderError.topologyMismatch
            }
        } else if status.identity.clusterID != nil {
            throw ModelLibraryProviderError.topologyMismatch
        }

    }

    private static func readOperations(
        connection: ModelLibraryRuntimeConnection
    ) async throws -> [SparkAPI.Operation] {
        var cursor: String?
        var seenCursors = Set<String>()
        var seenOperationIDs = Set<UUID>()
        var operations: [SparkAPI.Operation] = []
        var pageCount = 0
        repeat {
            let page = try await connection.runtime.operations(
                route: connection.route,
                limit: 200,
                cursor: cursor
            )
            pageCount += 1
            for operation in page.items where seenOperationIDs.insert(operation.id).inserted {
                operations.append(operation)
            }
            guard let next = page.nextCursor else { return operations }
            guard pageCount < 10 else {
                throw ModelLibraryProviderError.operationHistoryIncomplete
            }
            guard seenCursors.insert(next).inserted else {
                throw ModelLibraryProviderError.operationCursorLoop
            }
            cursor = next
        } while true
    }
}

private enum ModelLibraryProviderError: Error {
    case authenticatedRouteUnavailable
    case identityMismatch
    case topologyMismatch
    case operationCursorLoop
    case operationHistoryIncomplete
}
