import Foundation
import Testing
import SparkCore
import SparkLibrary

// MARK: - Offline state

@MainActor
@Test func pendingProbeShowsConnectingWithoutPersistingReachability() throws {
    let store = try libraryStoreTestMakeStore()
    let first = SparkLibrary(store: store)
    first.load()
    let outcome = first.reconcile(
        target(node: 1, displayName: "spark-a1b2", routes: [route(host: "spark-a1b2.local")])
    )

    let relaunched = SparkLibrary(store: store)
    relaunched.load()
    relaunched.markConnecting(entryID: outcome.entry.id)
    #expect(relaunched.entry(id: outcome.entry.id)?.connectionState == .connecting)

    let whileChecking = SparkLibrary(store: store)
    whileChecking.load()
    #expect(
        whileChecking.entry(id: outcome.entry.id)?.connectionState == .offlineCached,
        "checking is session state, not persisted reachability"
    )

    relaunched.clearConnecting(entryID: outcome.entry.id)
    #expect(relaunched.entry(id: outcome.entry.id)?.connectionState == .offlineCached)
}

@MainActor
@Test func failedProbeMarksTheCardOfflineButKeepsCachedMetadata() throws {
    let library = try libraryStoreTestMakeLibrary()
    let outcome = library.reconcile(
        target(node: 1, displayName: "spark-a1b2", routes: [route(host: "spark-a1b2.local")])
    )

    library.markUnreachable(entryID: outcome.entry.id)

    let entry = library.entry(id: outcome.entry.id)
    #expect(entry?.connectionState == .offlineCached)
    #expect(entry?.members[0].reachable == false)
    #expect(entry?.cachedAt != nil)
    #expect(entry?.members[0].routes.isEmpty == false, "cached routes remain for offline use")
}

@MainActor
@Test func successfulProbeMarksTheCardReachable() throws {
    let library = try libraryStoreTestMakeLibrary()
    let outcome = library.reconcile(
        target(node: 1, displayName: "spark-a1b2", routes: [route(host: "spark-a1b2.local")])
    )
    library.markUnreachable(entryID: outcome.entry.id)

    library.markReachable(
        entryID: outcome.entry.id,
        nodeID: libraryNodeID(1),
        route: route(host: "spark-a1b2.local")
    )

    let entry = library.entry(id: outcome.entry.id)
    #expect(entry?.connectionState == .connectedWiFi)
    #expect(entry?.members[0].reachable == true)
}

@MainActor
@Test func disablingAnAppManagedRouteForgetsOnlyThatTransportAndPersists() throws {
    let store = try libraryStoreTestMakeStore()
    let library = SparkLibrary(store: store)
    library.load()
    let outcome = library.reconcile(
        target(
            node: 1,
            displayName: "spark-a1b2",
            routes: [
                route(host: "spark-a1b2.local"),
                route(host: "100.96.4.2", kind: .privateOverlay, interface: "tailscale"),
            ]
        )
    )

    library.removeRoutes(
        entryID: outcome.entry.id,
        nodeID: libraryNodeID(1),
        kind: .privateOverlay
    )

    let remaining = try #require(library.entry(id: outcome.entry.id)?.members.first)
    #expect(remaining.routes.map(\.kind) == [.localWiFi])
    #expect(!remaining.reachable, "removing the live route requires a fresh local probe")

    let reloaded = SparkLibrary(store: store)
    reloaded.load()
    #expect(reloaded.entry(id: outcome.entry.id)?.members.first?.routes.map(\.kind) == [.localWiFi])
}

// MARK: - Identity mismatch recovery

@MainActor
@Test func authenticatedIdentityMismatchBlocksTheCardUntilRemoved() throws {
    let library = try libraryStoreTestMakeLibrary()
    let outcome = library.reconcile(
        target(node: 1, displayName: "spark-a1b2", routes: [route(host: "spark-a1b2.local")])
    )

    library.markIdentityMismatch(entryID: outcome.entry.id, presented: libraryNodeID(2))

    var entry = library.entry(id: outcome.entry.id)
    #expect(entry?.issue == .identityMismatch)
    #expect(entry?.connectionState == .identityMismatch)

    // Keep identity-mismatched cards blocked during generic unreachable updates.
    library.markUnreachable(entryID: outcome.entry.id)
    entry = library.entry(id: outcome.entry.id)
    #expect(entry?.issue == .identityMismatch)

    // Owner recovery: remove the stale local card.
    library.remove(entryID: outcome.entry.id)
    #expect(library.entry(id: outcome.entry.id) == nil)
}

@MainActor
@Test func removingOneCardLeavesTheOthersUntouched() throws {
    let store = try libraryStoreTestMakeStore()
    let library = SparkLibrary(store: store)
    library.load()
    library.reconcile(
        target(node: 1, displayName: "spark-a1b2", routes: [route(host: "spark-a1b2.local")])
    )
    library.reconcile(
        target(node: 2, displayName: "spark-c3d4", routes: [route(host: "spark-c3d4.local")])
    )

    library.remove(nodeID: libraryNodeID(1))

    #expect(library.entries.count == 1)
    #expect(library.entry(containing: libraryNodeID(2)) != nil)

    let reloaded = SparkLibrary(store: store)
    reloaded.load()
    #expect(reloaded.entries.count == 1, "deletion is persisted")
    #expect(reloaded.entry(containing: libraryNodeID(1)) == nil)
    #expect(reloaded.entry(containing: libraryNodeID(2)) != nil)
}

// MARK: - Cluster behaviour through the model

@MainActor
@Test func workerOnlyClusterStaysOfflineEvenWhenProbedViaTheWorker() throws {
    let library = try libraryStoreTestMakeLibrary()
    let outcome = library.reconcile(
        target(
            node: 2,
            cluster: 9,
            name: "Worker Node",
            role: .worker,
            displayName: "spark-b2c3",
            routes: [route(host: "spark-b2c3.local")]
        )
    )

    // A successful worker probe does not make a leaderless cluster usable.
    library.markReachable(
        entryID: outcome.entry.id,
        nodeID: libraryNodeID(2),
        route: route(host: "spark-b2c3.local")
    )

    let entry = library.entry(id: outcome.entry.id)
    #expect(entry?.coordinatorNodeID == nil)
    #expect(entry?.connectionState == .offlineCached)
    #expect(entry?.preferredRoute == nil)
}

@MainActor
@Test func deletingAClusterCardIsLocalOnly() throws {
    let library = try libraryStoreTestMakeLibrary()
    _ = library.reconcile(
        target(
            node: 1,
            cluster: 1,
            name: "Cluster One",
            role: .leader,
            displayName: "spark-a1b2",
            routes: [route(host: "spark-a1b2.local")]
        )
    )

    library.remove(clusterID: libraryClusterID(1))

    #expect(library.entries.isEmpty)
    #expect(library.remove(clusterID: libraryClusterID(1)) == nil, "second delete is a no-op")
}
