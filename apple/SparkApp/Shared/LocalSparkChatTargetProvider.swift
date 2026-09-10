import Foundation
import Observation
import SparkAPI
import SparkCore
import SparkLanguageModel
import SparkLibrary
import SparkSecurity
import SparkTransport

/// Reads the grant one Spark holds for this device, so a guest's picker matches what the owner shared.
public typealias GuestGrantReader = @MainActor (LibraryEntry) async -> GuestGrantReading

@MainActor
public final class LocalSparkChatTargetProvider: SparkChatTargetProviding {
    public typealias TrustLookup = @Sendable (String) -> NodeTrust?

    private let library: SparkLibrary
    private let trustLookup: TrustLookup
    private let now: @Sendable () -> Date
    private let evidenceProvider: SignedCrossTargetModelLibraryProvider
    private let guestAccess: GuestAccessRegistry
    private let guestGrantReader: GuestGrantReader
    private var lastInventoryRefresh: Date?

    public init(
        library: SparkLibrary,
        trustLookup: @escaping TrustLookup = StoredNodeTrust.reader,
        now: @escaping @Sendable () -> Date = Date.init,
        runtimeResolver: ModelLibraryRuntimeResolver? = nil,
        guestAccess: GuestAccessRegistry = .shared,
        guestGrantReader: GuestGrantReader? = nil
    ) {
        self.library = library
        self.trustLookup = trustLookup
        self.now = now
        self.guestAccess = guestAccess
        let resolver =
            runtimeResolver ?? { entry in
                try SignedCrossTargetModelLibraryProvider.productionRuntime(entry: entry)
            }
        self.guestGrantReader = guestGrantReader ?? Self.grantReader(resolver: resolver)
        evidenceProvider = SignedCrossTargetModelLibraryProvider(
            library: library,
            now: now,
            runtimeResolver: resolver
        )
    }

    public func refresh() async {
        await evidenceProvider.refreshChatEvidence()
        if lastInventoryRefresh.map({ now().timeIntervalSince($0) >= 30 }) ?? true {
            lastInventoryRefresh = now()
            await refreshInstalledModels()
            await refreshGuestGrants()
        }
    }

    /// Every Spark this device joined as a guest is asked what the owner shared; the answer narrows the picker.
    private func refreshGuestGrants() async {
        let pending = library.entries.compactMap { entry in
            guestNodeID(for: entry).map { (entry, $0) }
        }
        guard !pending.isEmpty else { return }
        let readings = await withTaskGroup(
            of: (String, GuestGrantReading).self,
            returning: [(String, GuestGrantReading)].self
        ) { group in
            for (entry, node) in pending {
                group.addTask { (node, await self.guestGrantReader(entry)) }
            }
            var results: [(String, GuestGrantReading)] = []
            for await result in group { results.append(result) }
            return results
        }
        guard !Task.isCancelled else { return }
        for (node, reading) in readings { guestAccess.apply(reading, toNode: node) }
    }

    private func guestNodeID(for entry: LibraryEntry) -> String? {
        guard let nodeID = entry.coordinatorNodeID else { return nil }
        let key = nodeID.rawValue.uuidString.lowercased()
        guard trustLookup(key)?.localDeviceRole == "guest" else { return nil }
        return key
    }

    /// The owner's allow-list for a Spark this device is a guest of; nil leaves the picker alone.
    private func allowedModels(for entry: LibraryEntry) -> [String]? {
        guestNodeID(for: entry).flatMap { guestAccess.allowedModels(forNode: $0) }
    }

    private static func grantReader(
        resolver: @escaping ModelLibraryRuntimeResolver
    ) -> GuestGrantReader {
        { entry in
            guard let connection = try? resolver(entry),
                let reader = connection.runtime as? any OwnSharedAccessProviding
            else { return .unknown }
            do {
                let record = try await reader.ownSharedAccess(route: connection.route)
                return .shared(record.allowedModels)
            } catch let error as APIError
                where error.statusCode == 404 || error.code == "ROLE_FORBIDDEN"
            {
                return .notAGuest
            } catch {
                return .unknown
            }
        }
    }

    public func refreshInstalledModels() async {
        _ = try? await evidenceProvider.fetchSnapshot()
    }

    public func voiceTargets() -> [SparkVoiceTarget] {
        library.entries.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }.compactMap { entry in
            guard entry.issue != .identityMismatch, let node = entry.coordinatorNodeID,
                let route = entry.connectRoute?.baseURL,
                let trust = trustLookup(node.rawValue.uuidString.lowercased())
            else { return nil }
            return SparkVoiceTarget(
                id: entry.id,
                displayName: entry.displayName,
                nodeID: node,
                clusterID: entry.clusterID,
                route: route,
                tlsFingerprint: trust.tlsFingerprint,
                authorityFingerprint: trust.authorityFingerprint
            )
        }
    }

    public func catalogue() -> SparkChatTargetCatalogue {
        var targets: [SparkChatTarget] = []
        var unavailable: [SparkChatUnavailableTarget] = []

        for entry in library.entries.sorted(by: {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }) {
            let outcome = target(for: entry)
            switch outcome {
            case .success(let target): targets.append(target)
            case .failure(let reason):
                unavailable.append(
                    SparkChatUnavailableTarget(
                        name: entry.displayName,
                        reason: reason,
                        id: entry.id
                    )
                )
            }
        }

        return SparkChatTargetCatalogue(
            targets: targets,
            pairedTargetCount: library.entries.count,
            unavailableTargets: unavailable,
            installedTargets: library.entries.flatMap { installedTargets(for: $0) }
        )
    }

    /// Cached model names are display-only; sending requires fresh catalogue evidence.
    public func rememberedTargets() -> [SparkChatTarget] {
        library.entries.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }.compactMap { entry in
            guard entry.issue == nil, let nodeID = entry.coordinatorNodeID,
                let route = entry.connectRoute?.baseURL,
                let trust = trustLookup(nodeID.rawValue.uuidString.lowercased()),
                let snapshot = library.operationalSnapshot(for: entry.id, at: now()),
                snapshot.connectionState != .identityMismatch,
                let inference = snapshot.activeInference,
                [.ready, .idle].contains(inference.state),
                let identity = inference.modelIdentity,
                allowedModels(for: entry).map({ $0.contains(identity.modelID) }) ?? true
            else { return nil }
            return SparkChatTarget(
                id: entry.id,
                displayName: entry.displayName,
                nodeID: nodeID,
                clusterID: entry.clusterID,
                route: route,
                tlsFingerprint: trust.tlsFingerprint,
                authorityFingerprint: trust.authorityFingerprint,
                modelID: identity.modelID,
                modelName: Self.ownerFacingModelName(
                    for: identity,
                    placements: snapshot.placements
                ),
                contextLength: inference.contextLength,
                visionSupported: snapshot.placements.first { $0.identity == identity }?
                    .technicalDetails.visionSupported,
                connection: snapshot.connectionState
            )
        }
    }

    private func installedTargets(for entry: LibraryEntry) -> [SparkChatTarget] {
        guard entry.issue == nil, let nodeID = entry.coordinatorNodeID,
            let route = entry.connectRoute?.baseURL,
            let trust = trustLookup(nodeID.rawValue.uuidString.lowercased()),
            let snapshot = library.operationalSnapshot(for: entry.id, at: now()),
            [.connectedDirect, .connectedWiFi, .connectedRemote].contains(snapshot.connectionState),
            snapshot.evidence.inference.state == .current
        else { return [] }
        let allowed = allowedModels(for: entry)
        return snapshot.placements.filter { placement in
            [.installed, .running, .starting].contains(placement.state)
                && placement.evidence.state == .current
                && allowed.map { $0.contains(placement.identity.modelID) } ?? true
        }.map { placement in
            SparkChatTarget(
                id: entry.id,
                displayName: entry.displayName,
                nodeID: nodeID,
                clusterID: entry.clusterID,
                route: route,
                tlsFingerprint: trust.tlsFingerprint,
                authorityFingerprint: trust.authorityFingerprint,
                modelID: placement.identity.modelID,
                modelName: placement.displayName,
                visionSupported: placement.technicalDetails.visionSupported,
                connection: snapshot.connectionState
            )
        }
    }

    static func ownerFacingModelName(
        for identity: ModelPlacementIdentity,
        placements: [ModelPlacementSnapshot]
    ) -> String {
        placements.first(where: { $0.identity == identity })?.displayName
            ?? String(localized: "Active model")
    }

    private func target(for entry: LibraryEntry) -> Result<
        SparkChatTarget, SparkChatUnavailableReason
    > {
        guard entry.issue != .identityMismatch else { return .failure(.identityMismatch) }
        guard let nodeID = entry.coordinatorNodeID,
            let route = entry.connectRoute?.baseURL
        else {
            return .failure(.routeUnavailable)
        }
        guard let trust = trustLookup(nodeID.rawValue.uuidString.lowercased()) else {
            return .failure(.authenticationUnavailable)
        }
        guard let snapshot = library.operationalSnapshot(for: entry.id, at: now()) else {
            return .failure(.offline)
        }
        guard snapshot.connectionState != .identityMismatch else {
            return .failure(.identityMismatch)
        }
        let usableConnections: Set<TargetConnectionState> = [
            .connectedDirect, .connectedWiFi, .connectedRemote,
        ]
        guard snapshot.connectionState != .offlineCached else { return .failure(.offline) }
        guard usableConnections.contains(snapshot.connectionState),
            snapshot.evidence.inference.state == .current
        else {
            return .failure(.checkingStatus)
        }
        if snapshot.activeInference?.state == .loading { return .failure(.modelLoading) }
        guard let inference = snapshot.activeInference,
            [.ready, .idle].contains(inference.state),
            let modelIdentity = inference.modelIdentity
        else {
            return .failure(.noActiveModel)
        }
        if let allowed = allowedModels(for: entry), !allowed.contains(modelIdentity.modelID) {
            return .failure(.notShared)
        }
        let modelName = Self.ownerFacingModelName(
            for: modelIdentity,
            placements: snapshot.placements
        )
        return .success(
            SparkChatTarget(
                id: entry.id,
                displayName: entry.displayName,
                nodeID: nodeID,
                clusterID: entry.clusterID,
                route: route,
                tlsFingerprint: trust.tlsFingerprint,
                authorityFingerprint: trust.authorityFingerprint,
                modelID: modelIdentity.modelID,
                modelName: modelName,
                contextLength: inference.contextLength,
                visionSupported: snapshot.placements.first {
                    $0.identity == modelIdentity && $0.evidence.state == .current
                }?.technicalDetails.visionSupported,
                connection: snapshot.connectionState
            )
        )
    }
}
