import Foundation
import Testing
import SparkCore
import SparkLibrary

/// A durable store whose reads and writes fail.
@MainActor
struct LibraryStoreTestFailingDurableStore: SparkLibraryStoring {
    let isDurable = true
    enum StoreError: Error { case failed }
    func load() throws -> [LibraryEntry] { throw StoreError.failed }
    func save(_ entries: [LibraryEntry]) throws { throw StoreError.failed }
}

@MainActor
struct LibraryStoreTestWriteFailingDurableStore: SparkLibraryStoring {
    let isDurable = true
    enum StoreError: Error { case failed }
    func load() throws -> [LibraryEntry] { [] }
    func save(_ entries: [LibraryEntry]) throws { throw StoreError.failed }
}

@MainActor
func libraryStoreTestLibraryNodeIDs(_ library: SparkLibrary) -> [SparkNodeID] {
    library.entries.compactMap(\.standaloneNodeID).sorted {
        $0.rawValue.uuidString < $1.rawValue.uuidString
    }
}

/// A durable store that loads fine but cannot be written.
@MainActor
struct LibraryStoreTestLoadOKWriteFailStore: SparkLibraryStoring {
    let isDurable = true
    let loaded: [LibraryEntry]

    func load() throws -> [LibraryEntry] { loaded }

    func save(_ entries: [LibraryEntry]) throws {
        throw LibraryStoreTestWriteFailingDurableStore.StoreError.failed
    }
}
