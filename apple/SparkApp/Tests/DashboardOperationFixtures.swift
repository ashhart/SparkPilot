import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing
@testable import SparkAppComposition

@MainActor
final class DashboardTestTestOperationStore: ModelOperationRecoveryStoring {
    var storedRecords: [ModelOperationRecoveryRecord]
    var failAttachedSave: Bool

    init(
        records: [ModelOperationRecoveryRecord] = [],
        failAttachedSave: Bool = false
    ) {
        storedRecords = records
        self.failAttachedSave = failAttachedSave
    }

    func records(for targetID: String) throws -> [ModelOperationRecoveryRecord] {
        storedRecords.filter { $0.targetID == targetID }
    }

    func save(_ record: ModelOperationRecoveryRecord) throws {
        if failAttachedSave, record.operationID != nil {
            throw TestStoreError.writeFailed
        }
        storedRecords.removeAll { $0.storageKey == record.storageKey }
        storedRecords.append(record)
    }

    func remove(_ record: ModelOperationRecoveryRecord) throws {
        storedRecords.removeAll { $0.storageKey == record.storageKey }
    }

    private enum TestStoreError: Error {
        case writeFailed
    }
}

@MainActor
final class DashboardTestTestTelemetryCache: SparkTelemetryCaching {
    var snapshots: [String: TelemetrySnapshot] = [:]

    func load(targetID: String) throws -> TelemetrySnapshot? {
        snapshots[targetID]
    }

    func save(_ snapshot: TelemetrySnapshot, targetID: String) throws {
        snapshots[targetID] = snapshot
    }
}

actor DashboardTestOneTelemetryTick {
    private var waits = 0
    private var intervals: [Duration] = []

    func wait(_ interval: Duration) throws {
        intervals.append(interval)
        waits += 1
        if waits > 1 { throw CancellationError() }
    }

    func recordedIntervals() -> [Duration] { intervals }
}

final class DashboardTestDashboardPresenceSession: UserPresenceProofSigning, @unchecked Sendable {
    let keyInfo = UserPresenceKeyInfo(publicKeySPKI: Data([1]), protection: .softwareTestOnly)

    func proof(for request: UserPresenceCanonicalRequest) async throws -> UserPresenceProof {
        throw UserPresenceProofError.signingFailed
    }
}

actor DashboardTestDashboardPresenceAuthorizer: UserPresenceAuthorizing {
    private var authorizationCount = 0

    func keyInfo() async throws -> UserPresenceKeyInfo {
        UserPresenceKeyInfo(publicKeySPKI: Data([1]), protection: .softwareTestOnly)
    }

    func authorize(localizedReason: String) async throws -> any UserPresenceProofSigning {
        authorizationCount += 1
        return DashboardTestDashboardPresenceSession()
    }

    func count() -> Int { authorizationCount }
}
