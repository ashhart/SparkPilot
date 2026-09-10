import CryptoKit
import Foundation
@_spi(SparkTestSupport) import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
@_spi(SparkTestSupport) import SparkTransport
import Testing
@testable import SparkAppComposition

actor ExternalClusterTestManagedTransactionRecorder {
    private var paths: [String] = []

    func record(_ path: String) { paths.append(path) }
    func recordedPaths() -> [String] { paths }
}

final class ExternalClusterTestMemoryManagedClusterJournal:
    ManagedClusterTransactionJournaling, @unchecked Sendable
{
    private let lock = NSLock()
    private var record: ManagedClusterTransactionJournalRecord?
    private var history: [ManagedClusterTransactionJournalRecord] = []

    init(_ record: ManagedClusterTransactionJournalRecord? = nil) {
        self.record = record
    }

    func load() throws -> ManagedClusterTransactionJournalRecord? {
        lock.lock()
        defer { lock.unlock() }
        return record
    }

    func save(_ record: ManagedClusterTransactionJournalRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        self.record = record
        history.append(record)
    }

    func remove() throws {
        lock.lock()
        defer { lock.unlock() }
        record = nil
    }

    func savedHistory() -> [ManagedClusterTransactionJournalRecord] {
        lock.lock()
        defer { lock.unlock() }
        return history
    }
}

actor ExternalClusterTestManagedLaunchOrderRecorder {
    private var nodeIDs: [UUID] = []

    func record(_ nodeID: UUID) { nodeIDs.append(nodeID) }
    func recordedNodeIDs() -> [UUID] { nodeIDs }
}
