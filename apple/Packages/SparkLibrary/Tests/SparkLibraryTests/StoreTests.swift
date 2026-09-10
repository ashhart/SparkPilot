import Foundation
import SwiftData
import Testing
import SparkLibrary

// MARK: - Store behaviour

@MainActor
@Test func emptyStoreLoadsEmpty() throws {
    let store = try SwiftDataLibraryStore()
    #expect(try store.load().isEmpty)
}

@MainActor
@Test func inMemoryStoreRoundTripsEntriesInOrder() throws {
    let store = try SwiftDataLibraryStore()
    let library =
        reconcile(
            target(node: 1, displayName: "spark-a1b2", routes: [route(host: "spark-a1b2.local")]),
            into: []
        ).library
        + reconcile(
            target(node: 2, displayName: "spark-c3d4", routes: [route(host: "spark-c3d4.local")]),
            into: []
        ).library

    try store.save(library)

    let loaded = try store.load()
    #expect(loaded == library)
    #expect(loaded.map(\.id) == [nodeKey(1), nodeKey(2)])
}

@MainActor
@Test func fileBackedStoreSurvivesRelaunch() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("spark-library-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("library.store")

    var saved = reconcile(
        target(node: 1, displayName: "spark-a1b2", routes: [route(host: "spark-a1b2.local")]),
        into: []
    ).library

    // Save in a first "launch".
    try SwiftDataLibraryStore(url: url).save(saved)

    // Relaunch from a brand-new store/container on the same file.
    let reloaded = try SwiftDataLibraryStore(url: url).load()
    saved[0].connectionState = reloaded[0].connectionState  // load() will downgrade below
    #expect(reloaded.count == 1)
    #expect(reloaded[0].id == nodeKey(1))
    #expect(reloaded[0].standaloneNodeID == libraryNodeID(1))
    #expect(reloaded[0].members[0].routes == saved[0].members[0].routes, "cached metadata survives")

    try FileManager.default.removeItem(at: directory)
}

@MainActor
@Test func saveReplacesTheWholeSetInsteadOfAppending() throws {
    let store = try SwiftDataLibraryStore()
    try store.save(
        reconcile(
            target(node: 1, displayName: "spark-a1b2", routes: [route(host: "spark-a1b2.local")]),
            into: []
        ).library
    )

    // Replace an existing logical-key record on later save without duplicating it.
    try store.save(
        reconcile(
            target(node: 1, displayName: "spark-a1b2", routes: [route(host: "172.16.10.5")]),
            into: []
        ).library
    )

    let loaded = try store.load()
    #expect(loaded.count == 1)
    #expect(loaded[0].members[0].routes.count == 1, "the slot was updated, not appended")
    #expect(loaded[0].members[0].routes.first?.baseURL.host == "172.16.10.5")
}

// MARK: - Uniqueness invariant (one card per logical key)

@MainActor
@Test func uniqueLogicalKeyCollapsesConcurrentDuplicates() throws {
    // Enforce one logical record when concurrent ModelContexts insert the same key.
    let schema = Schema([LibraryEntryRecord.self])
    let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: schema, configurations: [configuration])

    let key = nodeKey(1)
    let contextA = ModelContext(container)
    let contextB = ModelContext(container)
    contextA.insert(LibraryEntryRecord(logicalKey: key, sortIndex: 0, payload: Data("a".utf8)))
    contextB.insert(LibraryEntryRecord(logicalKey: key, sortIndex: 1, payload: Data("b".utf8)))
    try contextA.save()
    try contextB.save()

    let fetched = try ModelContext(container).fetch(FetchDescriptor<LibraryEntryRecord>())
    #expect(fetched.count == 1, "the unique logical key prevents duplicate cards")
}

// MARK: - No CloudKit mirroring

/// CloudKitDatabase is not Equatable; inspect its backing flags.
private func isCloudKitNone(_ configuration: ModelConfiguration) -> Bool {
    let mirror = Mirror(reflecting: configuration.cloudKitDatabase)
    var none = false
    var automatic = false
    for child in mirror.children {
        switch child.label {
        case "_none":
            none = (child.value as? Bool) ?? false
        case "_automatic":
            automatic = (child.value as? Bool) ?? false
        default:
            break
        }
    }
    return none && !automatic
}

@MainActor
@Test func cloudKitMirroringIsExplicitlyDisabledForBothStores() throws {
    let memory = SwiftDataLibraryStore.makeConfiguration(url: nil)
    #expect(isCloudKitNone(memory), "memory store never opts into CloudKit")

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("spark-library-nocloudkit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let disk = SwiftDataLibraryStore.makeConfiguration(
        url: directory.appendingPathComponent("library.store")
    )
    #expect(isCloudKitNone(disk), "disk store never opts into CloudKit")
}
