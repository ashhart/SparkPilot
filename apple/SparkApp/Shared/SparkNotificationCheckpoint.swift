import Foundation
import SparkCore

struct SparkNotificationCheckpoint: Codable {
    var observations: [String: SparkNotificationCheckpointObservation]
    var deliveredIdentifiers: [String]
    var actionable: SparkActionableNotificationCheckpoint? = nil

    static let empty = SparkNotificationCheckpoint(observations: [:], deliveredIdentifiers: [])
}

struct SparkNotificationCheckpointObservation: Codable {
    let targetID: String
    let connectionState: SparkConnectionState
    let operations: [SparkNotificationCheckpointOperation]
    let noticeCodes: Set<String>
    let observedAt: Date?

    init(_ observation: SparkNotificationObservation) {
        targetID = observation.targetID
        connectionState = observation.connectionState
        operations = observation.operations.map(SparkNotificationCheckpointOperation.init)
        noticeCodes = observation.noticeCodes
        observedAt = observation.observedAt
    }

    var observation: SparkNotificationObservation {
        SparkNotificationObservation(
            targetID: targetID,
            connectionState: connectionState,
            operations: operations.map(\.snapshot),
            noticeCodes: noticeCodes,
            observedAt: observedAt
        )
    }
}

struct SparkNotificationCheckpointOperation: Codable {
    let id: UUID
    let kind: String
    let state: SparkOperationState

    init(_ operation: TargetOperationSnapshot) {
        id = operation.id.rawValue
        kind = operation.kind
        state = operation.state
    }

    var snapshot: TargetOperationSnapshot {
        TargetOperationSnapshot(
            id: SparkOperationID(rawValue: id),
            kind: kind,
            state: state,
            progress: nil,
            stage: nil,
            errorCode: nil,
            cancellable: false
        )
    }
}
