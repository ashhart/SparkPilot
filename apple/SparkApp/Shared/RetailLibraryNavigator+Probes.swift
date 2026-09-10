import Foundation
import SparkCore
import SparkLibrary

/// One reachability probe per entry, so overlapping callers cannot write their results out of order.
@MainActor
final class RetailEntryProbes {
    private var running: [String: (generation: Int, task: Task<Bool, Never>)] = [:]
    private var newest: [String: Int] = [:]
    private var sequence = 0

    /// Begin a generation for an entry; every older probe of it stops being the newest evidence.
    func begin(_ entryID: String) -> Int {
        sequence &+= 1
        newest[entryID] = sequence
        return sequence
    }

    /// True while this probe is still the newest one the entry has been asked for.
    func isCurrent(_ entryID: String, generation: Int) -> Bool {
        newest[entryID] == generation
    }

    /// The probe already running for this entry, for a caller that should join rather than race it.
    func inFlight(_ entryID: String) -> Task<Bool, Never>? {
        running[entryID]?.task
    }

    func hold(_ task: Task<Bool, Never>, for entryID: String, generation: Int) {
        running[entryID] = (generation, task)
    }

    func finish(_ entryID: String, generation: Int) {
        guard running[entryID]?.generation == generation else { return }
        running[entryID] = nil
    }

    /// Forget an entry, so a removed card leaves no probe and no generation behind.
    func forget(_ entryID: String) {
        running[entryID]?.task.cancel()
        running[entryID] = nil
        newest[entryID] = nil
    }
}

extension RetailLibraryNavigator {
    /// Probe one saved entry; a second caller joins the probe already running instead of racing it.
    func probeEntry(_ entryID: String) async -> Bool {
        if let running = probes.inFlight(entryID) { return await running.value }
        let generation = probes.begin(entryID)
        let task = Task { @MainActor [weak self] in
            guard let self, let entry = library.entry(id: entryID),
                let route = entry.preferredRoute
            else { return false }
            if let coordinator = entry.coordinatorNodeID,
                entry.member(nodeID: coordinator)?.routes.contains(where: {
                    $0.kind == .privateOverlay
                }) == true
            {
                return await authenticateEntryRoute(
                    entryID: entryID,
                    initialRoute: route,
                    probeGeneration: generation
                ) != nil
            }
            return await authenticateProbe(
                entryID: entryID,
                route: route,
                generation: generation
            )
        }
        probes.hold(task, for: entryID, generation: generation)
        let result = await task.value
        probes.finish(entryID, generation: generation)
        return result
    }

    /// Reachability is only written by the newest probe; an older answer is no longer evidence.
    func markReachable(
        entryID: String,
        generation: Int,
        nodeID: SparkNodeID,
        route: CachedRoute
    ) {
        guard probes.isCurrent(entryID, generation: generation) else { return }
        library.markReachable(entryID: entryID, nodeID: nodeID, route: route, at: now())
    }

    func markUnreachable(
        entryID: String,
        generation: Int,
        nodeID: SparkNodeID? = nil,
        route: CachedRoute? = nil
    ) {
        guard probes.isCurrent(entryID, generation: generation) else { return }
        guard let nodeID, let route else {
            library.markUnreachable(entryID: entryID, at: now())
            return
        }
        library.markUnreachable(entryID: entryID, nodeID: nodeID, route: route, at: now())
    }

    func markIdentityMismatch(entryID: String, generation: Int, presented: SparkNodeID) {
        guard probes.isCurrent(entryID, generation: generation) else { return }
        library.markIdentityMismatch(entryID: entryID, presented: presented, at: now())
    }
}
