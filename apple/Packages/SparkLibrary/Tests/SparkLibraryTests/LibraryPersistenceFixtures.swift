import Foundation
import Testing
import SparkCore
import SparkLibrary

// MARK: - Helpers

/// Share one in-memory store across library instances when testing persistence reloads.
@MainActor
func libraryStoreTestMakeStore() throws -> SwiftDataLibraryStore {
    try SwiftDataLibraryStore()
}

@MainActor
func libraryStoreTestMakeLibrary(url: URL? = nil) throws -> SparkLibrary {
    let store = try SwiftDataLibraryStore(url: url)
    let library = SparkLibrary(store: store)
    library.load()
    return library
}
