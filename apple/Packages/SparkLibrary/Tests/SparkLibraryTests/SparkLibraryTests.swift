import Foundation
import Testing
import SparkCore
import SparkLibrary

// MARK: - Automatic persistence

@MainActor
@Test func reconcilerPersistsAutomatically() throws {
    let store = try libraryStoreTestMakeStore()
    let library = SparkLibrary(store: store)
    library.load()
    library.reconcile(
        target(node: 1, displayName: "spark-a1b2", routes: [route(host: "spark-a1b2.local")])
    )

    // Re-reading from the same store must see what reconcile wrote.
    let reloaded = SparkLibrary(store: store)
    reloaded.load()
    #expect(reloaded.entries.count == 1)
    #expect(reloaded.entries.first?.standaloneNodeID == libraryNodeID(1))
}

@MainActor
@Test func mutatorsPersistWithoutAnExplicitSaveCall() throws {
    let store = try libraryStoreTestMakeStore()
    let library = SparkLibrary(store: store)
    library.load()
    let outcome = library.reconcile(
        target(node: 1, displayName: "spark-a1b2", routes: [route(host: "spark-a1b2.local")])
    )
    library.markIdentityMismatch(entryID: outcome.entry.id, presented: libraryNodeID(2))
    let removed = library.remove(entryID: outcome.entry.id)
    #expect(removed != nil)

    let reloaded = SparkLibrary(store: store)
    reloaded.load()
    #expect(reloaded.entries.isEmpty, "remove persisted too")
}

@MainActor
@Test func customLabelSurvivesReportedNameRefreshAndRelaunch() throws {
    let store = try libraryStoreTestMakeStore()
    let library = SparkLibrary(store: store)
    library.load()
    let added = library.reconcile(
        target(
            node: 1,
            name: "DGX Spark",
            displayName: "spark-a1b2",
            routes: [route(host: "spark-a1b2.local")]
        )
    )

    #expect(library.setCustomLabel("Workshop Spark", for: added.entry.id))
    #expect(library.entry(id: added.entry.id)?.displayName == "Workshop Spark")

    library.reconcile(
        target(
            node: 1,
            name: "Spark reported a new name",
            displayName: "spark-a1b2",
            routes: [route(host: "spark-a1b2.local")]
        )
    )
    #expect(library.entry(id: added.entry.id)?.name == "Spark reported a new name")
    #expect(library.entry(id: added.entry.id)?.displayName == "Workshop Spark")

    let reloaded = SparkLibrary(store: store)
    reloaded.load()
    #expect(reloaded.entry(id: added.entry.id)?.displayName == "Workshop Spark")
}

@MainActor
@Test func clearingCustomLabelReturnsToReportedNameAndHostnamePersists() throws {
    let store = try libraryStoreTestMakeStore()
    let library = SparkLibrary(store: store)
    library.load()
    let added = library.reconcile(
        target(node: 1, name: "DGX Spark", displayName: "spark-a1b2")
    )

    #expect(library.setCustomLabel("spark1", for: added.entry.id))
    #expect(
        library.recordHostname("spark1", for: added.entry.id, nodeID: libraryNodeID(1))
    )
    #expect(library.setCustomLabel("", for: added.entry.id))

    let reloaded = SparkLibrary(store: store)
    reloaded.load()
    #expect(reloaded.entry(id: added.entry.id)?.displayName == "DGX Spark")
    #expect(reloaded.entry(id: added.entry.id)?.members.first?.hostname == "spark1")
}

// MARK: - Survives relaunch

@MainActor
@Test func librarySurvivesRelaunchWithoutDuplicates() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("spark-library-model-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("library.store")

    let firstLaunch = try libraryStoreTestMakeLibrary(url: url)
    firstLaunch.reconcile(
        target(node: 1, displayName: "spark-a1b2", routes: [route(host: "spark-a1b2.local")])
    )
    firstLaunch.reconcile(
        target(node: 2, displayName: "spark-c3d4", routes: [route(host: "spark-c3d4.local")])
    )

    let secondLaunch = try libraryStoreTestMakeLibrary(url: url)
    #expect(secondLaunch.entries.count == 2, "cards survive relaunch")

    // Opening the same spark again must not append a third card.
    secondLaunch.reconcile(
        target(node: 1, displayName: "spark-a1b2", routes: [route(host: "spark-a1b2.local")])
    )
    #expect(secondLaunch.entries.count == 2)
    #expect(secondLaunch.entry(containing: libraryNodeID(1)) != nil)

    try FileManager.default.removeItem(at: directory)
}

@MainActor
@Test func relaunchDowngradesConnectedStateToOfflineCached() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("spark-library-offline-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("library.store")

    let library = try libraryStoreTestMakeLibrary(url: url)
    let outcome = library.reconcile(
        target(node: 1, displayName: "spark-a1b2", routes: [route(host: "spark-a1b2.local")])
    )
    #expect(outcome.entry.connectionState == .connectedWiFi, "live while the session is open")

    let second = try libraryStoreTestMakeLibrary(url: url)
    #expect(
        second.entries[0].connectionState == .offlineCached,
        "reachability is never assumed after relaunch"
    )
    #expect(second.entries[0].members[0].reachable == false)

    try FileManager.default.removeItem(at: directory)
}

// MARK: - Storage status

@MainActor
@Test func memoryStoreIsReportedSessionOnly() {
    let library = SparkLibrary(store: MemoryLibraryStore())
    #expect(library.storageStatus.isSessionOnly)
}

@MainActor
@Test func durableStoreFailureCannotMasqueradeAsPersistent() throws {
    let failing = LibraryStoreTestFailingDurableStore()
    let library = SparkLibrary(store: failing)

    // Report durable read failure as session-only operation rather than an empty persistent library.
    library.load()
    #expect(library.storageStatus.isSessionOnly)
    #expect(library.entries.isEmpty)

    // A durable store whose writes fail gets reported session-only too.
    let writeFailing = LibraryStoreTestWriteFailingDurableStore()
    let other = SparkLibrary(store: writeFailing)
    other.reconcile(
        target(node: 1, displayName: "spark-a1b2", routes: [route(host: "spark-a1b2.local")])
    )
    #expect(other.storageStatus.isSessionOnly)
    #expect(other.entries.count == 1, "entries still work in memory while storage is broken")
}

@MainActor
@Test func recoveryBindsADurableStoreWithoutLosingEntries() throws {
    let memory = MemoryLibraryStore()
    let library = SparkLibrary(store: memory)
    library.reconcile(
        target(node: 1, displayName: "spark-a1b2", routes: [route(host: "spark-a1b2.local")])
    )
    #expect(library.storageStatus.isSessionOnly)

    library.recoverDurableStorage {
        try? SwiftDataLibraryStore(
            url: FileManager.default.temporaryDirectory
                .appendingPathComponent("recovery-\(UUID().uuidString).store")
        )
    }

    #expect(library.storageStatus == .persistent)
    #expect(library.entries.count == 1, "nothing added this session is lost")
}
