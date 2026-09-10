import Foundation
import SparkCore
import SparkLibrary

extension RetailLibraryNavigator {
    /// Local routes in rank order first, then the Spark's remembered Tailscale routes.
    static func candidateRoutes(
        for entry: LibraryEntry,
        startingWith initial: CachedRoute?
    ) -> (local: [CachedRoute], remote: [CachedRoute]) {
        guard let coordinator = entry.coordinatorNodeID,
            let member = entry.member(nodeID: coordinator)
        else { return (initial.map { [$0] } ?? [], []) }
        var local = member.routes.filter { !isRemote($0.kind) }
        if let initial, !isRemote(initial.kind) {
            local.removeAll { $0.slotID == initial.slotID }
            local.insert(initial, at: 0)
        }
        let remote = member.routes.filter { isRemote($0.kind) }
        return (local, remote)
    }

    static func isRemote(_ kind: SparkTransportKind) -> Bool {
        kind == .privateOverlay
    }

    /// The first route that answers: the Spark's own network, then a changed local address, then Tailscale.
    func authenticateEntryRoute(
        entryID: String,
        initialRoute: CachedRoute? = nil,
        excluding excluded: URL? = nil,
        probeGeneration: Int? = nil,
        onFailure: (@MainActor (SavedSparkOpenFailure.Reason) -> Void)? = nil
    ) async -> CachedRoute? {
        guard let entry = library.entry(id: entryID) else { return nil }
        // Asking again supersedes any probe of this entry already in flight.
        let generation = probeGeneration ?? probes.begin(entryID)
        let candidates = Self.candidateRoutes(for: entry, startingWith: initialRoute)
        let keep = { (route: CachedRoute) in
            excluded.map { !RetailRouteComparison.sameRoute(route.baseURL, $0) } ?? true
        }
        let ranked = candidates.local.filter(keep)
        let local = ranked.isEmpty ? [initialRoute].compactMap { $0 }.filter(keep) : ranked
        let remote = candidates.remote.filter(keep)
        guard !local.isEmpty || !remote.isEmpty else { return nil }

        for route in local {
            if await authenticateProbe(
                entryID: entryID,
                route: route,
                generation: generation,
                onFailure: onFailure
            ) {
                return route
            }
            guard !Task.isCancelled, library.entry(id: entryID)?.issue == nil else { return nil }
        }

        // The Spark may have a new local address; Bonjour hints are tried before leaving the network.
        if let savedRoute = local.first {
            let hints = await savedRouteDiscovery.candidateRoutes()
            guard !Task.isCancelled else { return nil }
            for baseURL in hints
            where !local.contains(where: { RetailRouteComparison.sameRoute($0.baseURL, baseURL) }) {
                let candidate = SavedSparkRouteRecovery.candidate(
                    baseURL: baseURL,
                    savedRoute: savedRoute
                )
                let answered = await authenticateProbe(
                    entryID: entryID,
                    route: candidate,
                    generation: generation,
                    onFailure: onFailure
                )
                if answered { return candidate }
                guard !Task.isCancelled, library.entry(id: entryID)?.issue == nil else {
                    return nil
                }
            }
        }

        for route in remote {
            if await authenticateProbe(
                entryID: entryID,
                route: route,
                generation: generation,
                onFailure: onFailure
            ) {
                return route
            }
            guard !Task.isCancelled, library.entry(id: entryID)?.issue == nil else { return nil }
        }
        return nil
    }
}
