import Foundation
import SparkCore
import SparkTransport

extension LibraryReconciler {

    // MARK: - Lookup

    /// Find the card (and member index) that holds a node id.
    public static func find(
        nodeID: SparkNodeID,
        in entries: [LibraryEntry]
    ) -> (entry: LibraryEntry, memberIndex: Int)? {
        for entry in entries {
            if let index = entry.members.firstIndex(where: { $0.nodeID == nodeID }) {
                return (entry, index)
            }
        }
        return nil
    }

    public static func find(
        clusterID: SparkClusterID,
        in entries: [LibraryEntry]
    ) -> LibraryEntry? {
        entries.first { $0.clusterID == clusterID }
    }

    /// Blocks a saved hostname slot only when it authenticates as another full node ID.
    public static func hostnameRebindConflict(
        target: AuthenticatedTarget,
        in entries: [LibraryEntry]
    ) -> LibraryEntry? {
        let host = normalizedDisplayName(target.displayName)
        guard !host.isEmpty else { return nil }
        for entry in entries {
            for member in entry.members where member.nodeID != target.nodeID {
                guard let savedHost = member.hostname, !savedHost.isEmpty else { continue }
                if normalizedDisplayName(savedHost) == host {
                    return entry
                }
            }
        }
        return nil
    }

    /// Normalises hostnames by trimming, lowercasing and removing a trailing .local suffix.
    public static func normalizedDisplayName(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = trimmed.lowercased()
        if lowercased.hasSuffix(".local") {
            return String(lowercased.dropLast(".local".count))
        }
        return lowercased
    }

    // MARK: - Routes

    /// Updates endpoints within stable route slots while retaining separate direct and Wi-Fi routes.
    static func mergedRoutes(
        existing: [CachedRoute],
        seen: [CachedRoute],
        establishedIdentity: String? = nil
    ) -> [CachedRoute] {
        var bySlot: [RouteSlot: CachedRoute] = [:]
        for route in existing {
            bySlot[route.slotID] = route
        }
        for route in seen {
            let slot = route.slotID
            guard let current = bySlot[slot] else {
                bySlot[slot] = route
                continue
            }
            let refresh = route.lastSuccess ?? current.lastSuccess
            let succeeded = route.lastSuccess != nil
            bySlot[slot] = CachedRoute(
                id: current.id,
                slotID: slot,
                baseURL: route.baseURL,
                kind: route.kind,
                interfaceName: route.interfaceName ?? current.interfaceName,
                peerFingerprint: route.peerFingerprint ?? current.peerFingerprint,
                lastSuccess: refresh ?? current.lastSuccess,
                isMetered: route.isMetered || current.isMetered,
                // Clear failure history after a successful contact so recovered routes regain their priority.
                consecutiveFailures: succeeded
                    ? 0
                    : Swift.max(route.consecutiveFailures, current.consecutiveFailures)
            )
        }
        return bySlot.values
            .sorted { lhs, rhs in
                let left = rank(of: lhs, establishedIdentity: establishedIdentity)
                let right = rank(of: rhs, establishedIdentity: establishedIdentity)
                if left != right { return left < right }
                // Prefer unmetered routes only within a rank so cost cannot reorder transport classes.
                if lhs.isMetered != rhs.isMetered { return !lhs.isMetered }
                return (lhs.lastSuccess ?? .distantPast) > (rhs.lastSuccess ?? .distantPast)
            }
            .prefix(Self.maximumCachedRoutes)
            .map { $0 }
    }

    /// Ranks remembered routes using cached evidence while leaving authoritative trust checks to transport pinning against the Keychain.
    public static func rank(
        of route: CachedRoute,
        establishedIdentity: String?
    ) -> RouteRank {
        // Absent cached fingerprints do not demote paired local routes because their authoritative pins live in the Keychain.
        let identityForClass =
            route.peerFingerprint ?? establishedIdentity ?? Self.pinnedByPairing

        return RouteScorer().rankPart(
            of: SparkRoute(
                id: route.id,
                nodeID: SparkNodeID(rawValue: UUID()),
                baseURL: route.baseURL,
                kind: route.kind,
                interfaceName: route.interfaceName,
                validatedIdentityFingerprint: identityForClass,
                isMetered: route.isMetered,
                lastSuccess: route.lastSuccess
            ),
            expectedFingerprint: establishedIdentity,
            failures: route.consecutiveFailures
        )
    }

    /// Marks paired local-route class when no cached fingerprint exists; this value is never a credential.
    private static let pinnedByPairing = "paired"

    /// Derives the observed fingerprint from the most recent successful contact, with no contradiction before first authentication.
    public static func establishedIdentity(of member: LibraryMember) -> String? {
        member.routes
            .filter { $0.lastSuccess != nil }
            .max { ($0.lastSuccess ?? .distantPast) < ($1.lastSuccess ?? .distantPast) }?
            .peerFingerprint
    }

    static let maximumCachedRoutes = 12

    /// Derives card connectivity through its coordinator; worker-only clusters have no usable route.
    public static func connectionState(for entry: LibraryEntry) -> SparkConnectionState {
        if entry.issue == .identityMismatch {
            return .identityMismatch
        }
        guard let coordinator = entry.coordinatorNodeID,
            let member = entry.member(nodeID: coordinator),
            member.reachable,
            let route = member.routeInUse ?? member.routes.first
        else { return .offlineCached }
        return connectionState(forRouteKind: route.kind)
    }

    static func connectionState(for members: [LibraryMember]) -> SparkConnectionState {
        guard members.contains(where: { $0.role == .leader }),
            let leader = members.first(where: { $0.role == .leader }),
            leader.reachable,
            let route = leader.routeInUse ?? leader.routes.first
        else { return .offlineCached }
        return connectionState(forRouteKind: route.kind)
    }

    static func connectionState(forRouteKind kind: SparkTransportKind?) -> SparkConnectionState {
        guard let kind else { return .offlineCached }
        switch kind {
        case .directEthernet: return .connectedDirect
        case .localWiFi: return .connectedWiFi
        case .privateOverlay: return .connectedRemote
        }
    }
}
