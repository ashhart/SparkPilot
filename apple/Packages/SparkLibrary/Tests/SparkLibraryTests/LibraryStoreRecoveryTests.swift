import Foundation
import Testing
import SparkCore
import SparkLibrary

// MARK: - Data integrity under recovery

@MainActor
@Test func durableLoadFailureFailsOverToSessionStoreBeforeAnyWrite() {
    let failing = LibraryStoreTestFailingDurableStore()
    let library = SparkLibrary(store: failing)
    library.load()
    #expect(library.storageStatus.isSessionOnly)

    // Persist later mutations only to the memory failover store after durable-store corruption.
    library.reconcile(
        target(node: 1, displayName: "spark-a1b2", routes: [route(host: "spark-a1b2.local")])
    )
    #expect(library.entries.count == 1)
    #expect(
        library.persistError == nil,
        "writes went to the session failover, not the corrupt store"
    )
    #expect(library.storageStatus.isSessionOnly)
}

@MainActor
@Test func recoveryUnionsDiskOnlyAndSessionOnlyCardsAndSurvivesRelaunch() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("spark-library-union-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("library.store")
    defer { try? FileManager.default.removeItem(at: directory) }

    // Disk already holds one Spark from a previous session.
    let disk = SparkLibrary(store: try SwiftDataLibraryStore(url: url))
    disk.reconcile(
        target(node: 1, displayName: "spark-a1b2", routes: [route(host: "spark-a1b2.local")])
    )

    // Keep new library mutations session-only when opening the durable store fails.
    let session = SparkLibrary(store: MemoryLibraryStore())
    session.reconcile(
        target(node: 3, displayName: "spark-e5f6", routes: [route(host: "spark-e5f6.local")])
    )

    // Recovery binds the disk store again and must keep BOTH cards.
    session.recoverDurableStorage {
        try? SwiftDataLibraryStore(url: url)
    }
    #expect(session.storageStatus == .persistent)
    #expect(
        libraryStoreTestLibraryNodeIDs(session) == [libraryNodeID(1), libraryNodeID(3)],
        "disk-only and session-only cards both survive recovery"
    )

    // Relaunch from the same file: both cards are still there.
    let relaunched = SparkLibrary(store: try SwiftDataLibraryStore(url: url))
    relaunched.load()
    #expect(
        libraryStoreTestLibraryNodeIDs(relaunched) == [libraryNodeID(1), libraryNodeID(3)],
        "both cards survive relaunch"
    )
}

@MainActor
@Test func recoveryRemainsSessionOnlyWhenTheReplacementCannotBeRead() {
    let session = SparkLibrary(store: MemoryLibraryStore())
    session.reconcile(
        target(node: 3, displayName: "spark-e5f6", routes: [route(host: "spark-e5f6.local")])
    )
    let before = session.entries

    session.recoverDurableStorage { LibraryStoreTestFailingDurableStore() }

    #expect(session.storageStatus.isSessionOnly)
    #expect(session.entries == before, "the session snapshot is never discarded")
}

@MainActor
@Test func recoveryRemainsSessionOnlyWhenTheReplacementSaveFails() {
    let diskOnly = reconcile(
        target(node: 1, displayName: "spark-a1b2", routes: [route(host: "spark-a1b2.local")]),
        into: []
    ).library
    let session = SparkLibrary(store: MemoryLibraryStore())
    session.reconcile(
        target(node: 3, displayName: "spark-e5f6", routes: [route(host: "spark-e5f6.local")])
    )
    let before = session.entries

    session.recoverDurableStorage {
        LibraryStoreTestLoadOKWriteFailStore(loaded: diskOnly)
    }

    #expect(session.storageStatus.isSessionOnly)
    #expect(session.entries == before, "a failed commit keeps the session snapshot")
}
