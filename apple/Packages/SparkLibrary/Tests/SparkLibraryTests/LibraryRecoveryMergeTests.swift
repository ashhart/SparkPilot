import Foundation
import Testing
import SparkCore
import SparkLibrary

// MARK: - Same-key recovery reconciliation

@MainActor
@Test func recoveryMergesSameKeyEntriesKeepingMembersRoutesAndStickyMismatch() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("spark-library-merge-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("library.store")
    defer { try? FileManager.default.removeItem(at: directory) }

    // Persist a cluster fixture with an extra worker, route and identity mismatch.
    let disk = SparkLibrary(store: try SwiftDataLibraryStore(url: url))
    disk.reconcile(
        target(
            node: 1,
            cluster: 5,
            name: "Cluster Five",
            role: .leader,
            displayName: "disk-a",
            routes: [route(host: "disk-a.local", kind: .localWiFi, interface: "en0")],
            authorityFingerprint: "fpA"
        )
    )
    disk.reconcile(
        target(
            node: 2,
            cluster: 5,
            name: "Worker W",
            role: .worker,
            displayName: "disk-w",
            routes: [route(host: "disk-w.local", kind: .localWiFi, interface: "en0")],
            authorityFingerprint: "fpW"
        )
    )
    let clusterKey = disk.entries[0].id
    disk.markIdentityMismatch(entryID: clusterKey, presented: libraryNodeID(99))

    // Merge a session fixture with a changed leader route and an additional worker.
    let sessionStore = MemoryLibraryStore()
    let session = SparkLibrary(store: sessionStore)
    session.reconcile(
        target(
            node: 1,
            cluster: 5,
            name: "Cluster Five",
            role: .leader,
            displayName: "sess-a",
            routes: [route(host: "sess-a.local", kind: .localWiFi, interface: "en0")],
            authorityFingerprint: "fpA"
        )
    )
    session.reconcile(
        target(
            node: 3,
            cluster: 5,
            name: "Worker V",
            role: .worker,
            displayName: "sess-v",
            routes: [route(host: "sess-v.local", kind: .localWiFi, interface: "en0")],
            authorityFingerprint: "fpV"
        )
    )

    session.recoverDurableStorage {
        try? SwiftDataLibraryStore(url: url)
    }
    #expect(session.storageStatus == .persistent)
    #expect(session.entries.count == 1, "one cluster card, reconciled")

    let merged = session.entries[0]
    #expect(
        merged.members.map(\.nodeID).sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
            == [libraryNodeID(1), libraryNodeID(2), libraryNodeID(3)],
        "all members survive the union"
    )
    #expect(merged.issue == .identityMismatch, "the persisted mismatch stays sticky")
    #expect(merged.connectionState == .identityMismatch)

    let leader = merged.member(nodeID: libraryNodeID(1))
    #expect(leader?.hostname == "sess-a", "session observation wins for the matching node")
    #expect(
        leader?.routes.first?.baseURL.host == "sess-a.local",
        "the session update replaces the slot's endpoint in place"
    )
    #expect(
        merged.member(nodeID: libraryNodeID(2))?.routes.first?.baseURL.host == "disk-w.local",
        "disk-only route survives"
    )

    // Relaunch retains the same merged card.
    let relaunched = SparkLibrary(store: try SwiftDataLibraryStore(url: url))
    relaunched.load()
    #expect(relaunched.entries.count == 1)
    #expect(relaunched.entries[0].members.count == 3)
    #expect(relaunched.entries[0].issue == .identityMismatch)
}

@MainActor
@Test func recoveryFailsClosedWhenTheSameNodeHasDifferentAuthorityFingerprints() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("spark-library-fpconflict-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("library.store")
    defer { try? FileManager.default.removeItem(at: directory) }

    let disk = SparkLibrary(store: try SwiftDataLibraryStore(url: url))
    disk.reconcile(
        target(
            node: 1,
            cluster: 6,
            name: "Cluster Six",
            role: .leader,
            displayName: "disk-a",
            routes: [route(host: "disk-a.local")],
            authorityFingerprint: "fpA"
        )
    )

    let session = SparkLibrary(store: MemoryLibraryStore())
    session.reconcile(
        target(
            node: 1,
            cluster: 6,
            name: "Cluster Six",
            role: .leader,
            displayName: "sess-a",
            routes: [route(host: "sess-a.local")],
            authorityFingerprint: "fpB"
        )
    )
    #expect(session.entries[0].issue == nil, "neither copy alone is blocked")

    session.recoverDurableStorage {
        try? SwiftDataLibraryStore(url: url)
    }

    #expect(session.storageStatus == .persistent)
    #expect(
        session.entries[0].issue == .identityMismatch,
        "two different non-empty fingerprints fail closed to identityMismatch"
    )
    #expect(session.entries[0].connectionState == .identityMismatch)
}

// MARK: - Failover seeding

@MainActor
@Test func failoverSeedsSessionSnapshotSoALaterLoadCannotEraseIt() {
    let library = SparkLibrary(store: LibraryStoreTestFailingDurableStore())
    // Session entries exist before the durable store fails to load.
    library.reconcile(
        target(node: 1, displayName: "spark-a1b2", routes: [route(host: "spark-a1b2.local")])
    )
    #expect(library.entries.count == 1)

    library.load()  // durable read fails → fail over to a SEEDED session store
    #expect(library.storageStatus.isSessionOnly)
    #expect(library.entries.count == 1, "the failed load keeps the session snapshot")

    library.load()  // a second load from the session store must not erase them
    #expect(library.entries.count == 1, "session entries survive a second load")
}

// MARK: - Disjoint cluster-member recovery

@MainActor
@Test func recoveryWithCompetingLeadersFailsClosedWhilePreservingMembersAndRoutes() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("spark-library-leaders-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("library.store")
    defer { try? FileManager.default.removeItem(at: directory) }

    // Disk copy: leader A.
    let disk = SparkLibrary(store: try SwiftDataLibraryStore(url: url))
    disk.reconcile(
        target(
            node: 1,
            cluster: 7,
            name: "Cluster Seven",
            role: .leader,
            displayName: "disk-a",
            routes: [route(host: "disk-a.local")],
            authorityFingerprint: "fpA"
        )
    )
    // Session copy: SAME cluster, but leader B (disjoint member).
    let session = SparkLibrary(store: MemoryLibraryStore())
    session.reconcile(
        target(
            node: 8,
            cluster: 7,
            name: "Cluster Seven",
            role: .leader,
            displayName: "sess-b",
            routes: [route(host: "sess-b.local")],
            authorityFingerprint: "fpB"
        )
    )

    session.recoverDurableStorage {
        try? SwiftDataLibraryStore(url: url)
    }
    #expect(session.storageStatus == .persistent)
    let merged = session.entries[0]
    #expect(
        Set(merged.members.map(\.nodeID)) == [libraryNodeID(1), libraryNodeID(8)],
        "both members are preserved"
    )
    #expect(merged.members.count(where: { $0.role == .leader }) == 2)
    #expect(
        merged.issue == .identityMismatch,
        "competing leaders fail closed instead of guessing a coordinator"
    )
    #expect(LibraryReconciler.connectionState(for: merged) == .identityMismatch)
    #expect(merged.canOpen == false, "no usable open path remains")
}

@Test func blockedCardCannotOpenEvenWithAUsableRoute() {
    let outcome = reconcile(
        target(node: 1, displayName: "spark-a1b2", routes: [route(host: "spark-a1b2.local")]),
        into: []
    )
    var entry = outcome.entry
    entry.issue = .identityMismatch

    #expect(entry.preferredRoute != nil, "a route exists")
    #expect(entry.canOpen == false, "identityMismatch blocks the open path independent of UI")
}
