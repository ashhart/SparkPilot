import Foundation
import SwiftData

/// Persists Codable entry payloads under unique namespaced keys with CloudKit mirroring disabled.
@Model
public final class LibraryEntryRecord {
    @Attribute(.unique) public var logicalKey: String
    public var sortIndex: Int
    public var payload: Data

    public init(logicalKey: String, sortIndex: Int, payload: Data) {
        self.logicalKey = logicalKey
        self.sortIndex = sortIndex
        self.payload = payload
    }
}

/// Binds persistence to the main actor required by SwiftData contexts while keeping value models actor-independent.
@MainActor
public protocol SparkLibraryStoring {
    /// Load previously saved entries, preserving stored order.
    func load() throws -> [LibraryEntry]
    /// Replaces the persisted entry set while preserving one card per logical key.
    func save(_ entries: [LibraryEntry]) throws
    /// Reports session-only storage when durable opening or writes fail instead of implying empty persistent state.
    var isDurable: Bool { get }
}

/// Stores non-secret SwiftData payloads locally or in memory, with CloudKit disabled and authoritative trust kept in Keychain.
@MainActor
public struct SwiftDataLibraryStore: SparkLibraryStoring {
    private let container: ModelContainer
    /// URL-backed stores survive relaunch; in-memory preview and test stores do not.
    public let isDurable: Bool

    public init(url: URL? = nil) throws {
        self.isDurable = url != nil
        let schema = Schema([LibraryEntryRecord.self])
        self.container = try ModelContainer(
            for: schema,
            configurations: [Self.makeConfiguration(url: url)]
        )
    }

    /// Exposes a testable store configuration with CloudKit mirroring explicitly disabled.
    public static func makeConfiguration(url: URL? = nil) -> ModelConfiguration {
        let schema = Schema([LibraryEntryRecord.self])
        if let url {
            return ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        }
        return ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: true,
            cloudKitDatabase: .none
        )
    }

    public func load() throws -> [LibraryEntry] {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<LibraryEntryRecord>(
            sortBy: [SortDescriptor(\LibraryEntryRecord.sortIndex)]
        )
        let records = try context.fetch(descriptor)
        return try records.map {
            try LibraryPayloadMigration.decode($0.payload)
        }
    }

    public func save(_ entries: [LibraryEntry]) throws {
        let context = ModelContext(container)
        let existing = try context.fetch(FetchDescriptor<LibraryEntryRecord>())
        for record in existing {
            context.delete(record)
        }
        let encoder = JSONEncoder()
        for (index, entry) in entries.enumerated() {
            let payload = try encoder.encode(entry)
            context.insert(
                LibraryEntryRecord(logicalKey: entry.id, sortIndex: index, payload: payload)
            )
        }
        try context.save()
    }
}

/// Provides non-durable memory storage for previews, tests and recovery when SwiftData is unavailable.
@MainActor
public final class MemoryLibraryStore: SparkLibraryStoring {
    public let isDurable = false

    private var entries: [LibraryEntry] = []

    public init() {}

    public func load() throws -> [LibraryEntry] {
        entries
    }

    public func save(_ entries: [LibraryEntry]) throws {
        self.entries = entries
    }
}
