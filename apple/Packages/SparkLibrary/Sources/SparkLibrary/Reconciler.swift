import Foundation
import SparkCore
import SparkTransport

/// Carries identity verified by the runtime transport and validated routes, excluding untrusted discovery TXT metadata.
public struct AuthenticatedTarget: Sendable, Equatable {
    public let nodeID: SparkNodeID
    public let clusterID: SparkClusterID?
    /// Friendly name from the identity document (e.g. "My Spark").
    public let name: String
    public let role: SparkNodeRole
    public let authorityFingerprint: String?
    /// Host/instance name observed at the moment of reachability.
    public let displayName: String
    public let routes: [CachedRoute]
    public let reachedAt: Date

    public init(
        nodeID: SparkNodeID,
        clusterID: SparkClusterID?,
        name: String,
        role: SparkNodeRole,
        authorityFingerprint: String?,
        displayName: String,
        routes: [CachedRoute],
        reachedAt: Date = Date()
    ) {
        self.nodeID = nodeID
        self.clusterID = clusterID
        self.name = name
        self.role = role
        self.authorityFingerprint = authorityFingerprint
        self.displayName = displayName
        self.routes = routes
        self.reachedAt = reachedAt
    }
}

/// What a reconciliation pass did to the library (§10.6, §10.8).
public enum ReconciliationEffect: Sendable, Equatable {
    /// A brand-new card (standalone or cluster) was created.
    case added
    /// Updates an existing card's routes, name and reachability in place.
    case updated
    /// The identity was already present; the card opened without change.
    case openedExisting
    /// A member record of an existing cluster was added or refreshed.
    case clusterMemberUpdated
    /// Moves a node between standalone and cluster topology using authenticated identity evidence.
    case topologyChanged
    /// Blocks a saved card when its bound route authenticates as another node.
    case identityChanged
}

public struct ReconciliationOutcome: Sendable, Equatable {
    /// Identifies the new, existing or identity-blocked card resolved by reconciliation.
    public let entry: LibraryEntry
    public let effect: ReconciliationEffect
    /// The resulting library after reconciliation.
    public let library: [LibraryEntry]

    public init(entry: LibraryEntry, effect: ReconciliationEffect, library: [LibraryEntry]) {
        self.entry = entry
        self.effect = effect
        self.library = library
    }
}

/// Reconciles cards by stable identity with atomic topology changes and an injected clock for deterministic blocking evidence.
public struct LibraryReconciler: Sendable {
    let now: @Sendable () -> Date

    public init() {
        now = Date.init
    }

    public init(now: @escaping @Sendable () -> Date) {
        self.now = now
    }

    public func reconcile(
        target: AuthenticatedTarget,
        into entries: [LibraryEntry]
    ) -> ReconciliationOutcome {
        var library = entries

        // Refresh or move topology for an already authenticated node.
        if let found = Self.find(nodeID: target.nodeID, in: library) {
            return reconcileKnownNode(target: target, found: found, library: &library)
        }

        // Resolve the reported cluster identity before adding its member.
        if let clusterID = target.clusterID {
            if let cluster = Self.find(clusterID: clusterID, in: library) {
                return reconcileNewClusterMember(
                    target: target,
                    cluster: cluster,
                    library: &library
                )
            }
            // Block an unknown cluster only when a saved hostname slot authenticates as a different node.
            if let blocked = Self.hostnameRebindConflict(target: target, in: library) {
                return blockIdentityChange(blocked: blocked, library: &library)
            }
            return createCluster(target: target, library: &library)
        }

        // Create a standalone card only after existing identities have been excluded.
        if let blocked = Self.hostnameRebindConflict(target: target, in: library) {
            return blockIdentityChange(blocked: blocked, library: &library)
        }
        return createStandalone(target: target, library: &library)
    }

    // MARK: - Known node

    private func reconcileKnownNode(
        target: AuthenticatedTarget,
        found: (entry: LibraryEntry, memberIndex: Int),
        library: inout [LibraryEntry]
    ) -> ReconciliationOutcome {
        guard found.entry.kind == .standalone else {
            // Refresh standalone member recovery routes without dissolving their device-local external grouping or duplicating cards.
            if found.entry.externalClusterRegistration != nil,
                target.clusterID == nil
            {
                let updated = updatingMember(
                    of: found.entry,
                    nodeID: target.nodeID,
                    target: target
                )
                let at = library.firstIndex { $0.id == found.entry.id }!
                library[at] = updated
                let effect: ReconciliationEffect =
                    updated == found.entry ? .openedExisting : .clusterMemberUpdated
                return finish(updated, effect: effect, library: &library)
            }
            // Cluster member. Same cluster → refresh the member in place.
            if found.entry.clusterID == target.clusterID {
                let updated = updatingMember(of: found.entry, nodeID: target.nodeID, target: target)
                let at = library.firstIndex { $0.id == found.entry.id }!
                library[at] = updated
                let effect: ReconciliationEffect =
                    updated == found.entry ? .openedExisting : .clusterMemberUpdated
                return finish(updated, effect: effect, library: &library)
            }
            // Move the authenticated node to its newly reported cluster without treating the topology change as an identity mismatch.
            return moveNode(target: target, library: &library)
        }

        // Standalone node that reports a cluster → joined/linked a cluster.
        if target.clusterID != nil {
            return moveNode(target: target, library: &library)
        }

        // Plain standalone refresh: merge routes, names, reachability.
        let at = library.firstIndex { $0.id == found.entry.id }!
        let before = library[at]
        let updated = updatingMember(of: before, nodeID: target.nodeID, target: target)
        let effect: ReconciliationEffect = updated == before ? .openedExisting : .updated
        library[at] = updated
        return finish(updated, effect: effect, library: &library)
    }

    // MARK: - New node for a known cluster

    private func reconcileNewClusterMember(
        target: AuthenticatedTarget,
        cluster: LibraryEntry,
        library: inout [LibraryEntry]
    ) -> ReconciliationOutcome {
        let before = cluster
        let updated = addingMember(to: cluster, target: target)
        guard updated != before else {
            return finish(updated, effect: .openedExisting, library: &library)
        }
        let at = library.firstIndex { $0.id == cluster.id }!
        library[at] = updated
        return finish(updated, effect: .clusterMemberUpdated, library: &library)
    }

    // MARK: - Topology moves

    /// Atomically removes a node from its prior card and adds it to the authenticated destination cluster.
    private func moveNode(
        target: AuthenticatedTarget,
        library: inout [LibraryEntry]
    ) -> ReconciliationOutcome {
        if let found = Self.find(nodeID: target.nodeID, in: library) {
            let at = library.firstIndex { $0.id == found.entry.id }!
            if found.entry.kind == .standalone {
                library.remove(at: at)
            } else {
                var cluster = library[at]
                cluster.members.removeAll { $0.nodeID == target.nodeID }
                // Keep external registration member IDs aligned with card members when a node changes groups.
                if let registration = cluster.externalClusterRegistration {
                    cluster.externalClusterRegistration =
                        registration.removingMember(target.nodeID)
                }
                if cluster.members.isEmpty {
                    library.remove(at: at)
                } else {
                    library[at] = cluster
                }
            }
        }

        guard let clusterID = target.clusterID else {
            // No target cluster: the node is standalone again.
            let created = Self.makeStandalone(target: target)
            library.append(created)
            return finish(created, effect: .topologyChanged, library: &library)
        }

        if let cluster = Self.find(clusterID: clusterID, in: library) {
            let updated = addingMember(to: cluster, target: target)
            let at = library.firstIndex { $0.id == cluster.id }!
            library[at] = updated
            return finish(updated, effect: .topologyChanged, library: &library)
        }
        let created = Self.makeCluster(target: target)
        library.append(created)
        return finish(created, effect: .topologyChanged, library: &library)
    }

    // MARK: - New cards

    private func createStandalone(
        target: AuthenticatedTarget,
        library: inout [LibraryEntry]
    ) -> ReconciliationOutcome {
        let entry = Self.makeStandalone(target: target)
        library.append(entry)
        return finish(entry, effect: .added, library: &library)
    }

    private func createCluster(
        target: AuthenticatedTarget,
        library: inout [LibraryEntry]
    ) -> ReconciliationOutcome {
        let entry = Self.makeCluster(target: target)
        library.append(entry)
        return finish(entry, effect: .added, library: &library)
    }

    // MARK: - Identity change recovery (authenticated evidence only)

    private func blockIdentityChange(
        blocked: LibraryEntry,
        library: inout [LibraryEntry]
    ) -> ReconciliationOutcome {
        guard let at = library.firstIndex(where: { $0.id == blocked.id }) else {
            // The colliding card is not present (race); do not fabricate one.
            return ReconciliationOutcome(
                entry: blocked,
                effect: .identityChanged,
                library: library
            )
        }
        var marked = library[at]
        marked.issue = .identityMismatch
        marked.connectionState = .identityMismatch
        marked.cachedAt = now()
        library[at] = marked
        return finish(marked, effect: .identityChanged, library: &library)
    }

    private func finish(
        _ entry: LibraryEntry,
        effect: ReconciliationEffect,
        library: inout [LibraryEntry]
    ) -> ReconciliationOutcome {
        ReconciliationOutcome(entry: entry, effect: effect, library: library)
    }

    private func updatingMember(
        of entry: LibraryEntry,
        nodeID: SparkNodeID,
        target: AuthenticatedTarget
    ) -> LibraryEntry {
        var updated = entry
        updated.members = entry.members.map { member in
            guard member.nodeID == nodeID else { return member }
            var refreshed = member
            refreshed.name = target.name.isEmpty ? member.name : target.name
            refreshed.role = target.role
            if let fingerprint = target.authorityFingerprint,
                !fingerprint.isEmpty
            {
                refreshed.authorityFingerprint = fingerprint
            }
            refreshed.routes = Self.mergedRoutes(
                existing: member.routes,
                seen: target.routes,
                establishedIdentity: Self.establishedIdentity(of: member)
            )
            refreshed.lastSeen = target.reachedAt
            refreshed.reachable = true
            if !target.displayName.isEmpty {
                refreshed.hostname = target.displayName
            }
            return refreshed
        }
        updated.name = target.name.isEmpty ? updated.name : target.name
        if entry.externalClusterRegistration != nil {
            updated.name = entry.name
        }
        updated.lastSeen = target.reachedAt
        updated.cachedAt = target.reachedAt
        updated.connectionState = Self.connectionState(for: updated)
        return updated
    }

    private func addingMember(to cluster: LibraryEntry, target: AuthenticatedTarget) -> LibraryEntry
    {
        var updated = cluster
        if let index = updated.members.firstIndex(where: { $0.nodeID == target.nodeID }) {
            var refreshed = updated.members[index]
            refreshed.name = target.name.isEmpty ? refreshed.name : target.name
            refreshed.role = target.role
            refreshed.authorityFingerprint = target.authorityFingerprint
            refreshed.routes = Self.mergedRoutes(
                existing: refreshed.routes,
                seen: target.routes,
                establishedIdentity: Self.establishedIdentity(of: refreshed)
            )
            refreshed.lastSeen = target.reachedAt
            refreshed.reachable = true
            if !target.displayName.isEmpty {
                refreshed.hostname = target.displayName
            }
            updated.members[index] = refreshed
        } else {
            updated.members.append(
                LibraryMember(
                    nodeID: target.nodeID,
                    name: target.name.isEmpty ? target.displayName : target.name,
                    role: target.role,
                    authorityFingerprint: target.authorityFingerprint,
                    hostname: target.displayName.isEmpty ? nil : target.displayName,
                    routes: Self.mergedRoutes(existing: [], seen: target.routes),
                    lastSeen: target.reachedAt,
                    reachable: true
                )
            )
        }
        updated.name = target.name.isEmpty ? updated.name : target.name
        updated.lastSeen = target.reachedAt
        updated.cachedAt = target.reachedAt
        // Coordinator first, then other members by name, for stable detail UI.
        updated.members.sort { lhs, rhs in
            if lhs.role == rhs.role {
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return lhs.role == .leader
        }
        updated.connectionState = Self.connectionState(for: updated)
        return updated
    }

    static func makeStandalone(target: AuthenticatedTarget) -> LibraryEntry {
        let member = LibraryMember(
            nodeID: target.nodeID,
            name: target.name.isEmpty ? target.displayName : target.name,
            role: .standalone,
            authorityFingerprint: target.authorityFingerprint,
            hostname: target.displayName.isEmpty ? nil : target.displayName,
            routes: Self.mergedRoutes(existing: [], seen: target.routes),
            lastSeen: target.reachedAt,
            reachable: !target.routes.isEmpty
        )
        let name = target.name.isEmpty ? target.displayName : target.name
        return LibraryEntry(
            logicalKey: .node(target.nodeID),
            name: name,
            members: [member],
            connectionState: Self.connectionState(forRouteKind: target.routes.first?.kind),
            lastSeen: target.reachedAt,
            cachedAt: target.reachedAt
        )
    }

    static func makeCluster(target: AuthenticatedTarget) -> LibraryEntry {
        let member = LibraryMember(
            nodeID: target.nodeID,
            name: target.name.isEmpty ? target.displayName : target.name,
            role: target.role,
            authorityFingerprint: target.authorityFingerprint,
            hostname: target.displayName.isEmpty ? nil : target.displayName,
            routes: Self.mergedRoutes(existing: [], seen: target.routes),
            lastSeen: target.reachedAt,
            reachable: !target.routes.isEmpty
        )
        let name = target.name.isEmpty ? target.displayName : target.name
        precondition(
            target.clusterID != nil,
            "createCluster requires a cluster id (route: \(target.displayName))"
        )
        return LibraryEntry(
            logicalKey: .cluster(target.clusterID!),
            name: name,
            members: [member],
            connectionState: Self.connectionState(for: [member]),
            lastSeen: target.reachedAt,
            cachedAt: target.reachedAt
        )
    }
}
