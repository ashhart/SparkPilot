import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import Testing

@testable import SparkAppComposition

/// Fixtures shared by the notification test files; internal so both files see them.

let notificationOperationID = SparkOperationID(
    rawValue: UUID(uuidString: "a2944316-f58d-43cc-8725-ae351e782a58")!
)

func notificationOperation(
    state: SparkOperationState,
    kind: String = "model.install"
) -> TargetOperationSnapshot {
    TargetOperationSnapshot(
        id: notificationOperationID,
        kind: kind,
        state: state,
        progress: state == .succeeded ? 1 : 0.5,
        stage: nil,
        errorCode: state == .failed ? "PRIVATE_INTERNAL_FAILURE" : nil,
        cancellable: !state.isTerminalForNotificationTest
    )
}

func notificationObservation(
    connection: SparkConnectionState = .connectedWiFi,
    operations: [TargetOperationSnapshot] = [],
    notices: Set<String> = []
) -> SparkNotificationObservation {
    SparkNotificationObservation(
        targetID: "node:a647b28d-f6ae-4cbc-adf1-f117436a4aaa",
        connectionState: connection,
        operations: operations,
        noticeCodes: notices
    )
}

func planned(
    from old: SparkNotificationObservation?,
    to new: SparkNotificationObservation
) -> [SparkLocalNotification] {
    SparkNotificationPlanner.notifications(
        previous: old.map { [$0.targetID: $0] } ?? [:],
        current: [new.targetID: new]
    )
}

actor NotificationDeliverySpy: SparkNotificationDelivering {
    var notifications: [SparkLocalNotification] = []

    func authorization() async -> SparkNotificationAuthorization { .allowed }
    func requestAuthorization() async throws -> Bool { true }
    func registerCategories() async {}
    func deliver(_ notification: SparkLocalNotification) async throws {
        notifications.append(notification)
    }

    func delivered() -> [SparkLocalNotification] { notifications }
}

@MainActor
final class NotificationBackgroundSchedulerSpy: SparkNotificationBackgroundScheduling {
    private(set) var scheduled = 0
    private(set) var cancelled = 0

    func schedule() { scheduled += 1 }
    func cancel() { cancelled += 1 }
}

actor NotificationRemoteRegistrarSpy: SparkRemoteNotificationRegistering {
    var registrations = 0

    func register() async { registrations += 1 }
    func registrationCount() -> Int { registrations }
}

func notificationEntry(
    operationState: SparkOperationState,
    connection: SparkConnectionState = .connectedWiFi,
    operationsAreCurrent: Bool = true,
    runtimeUpdateState: SparkRuntimeUpdateState = .current,
    notices: [OperationalNotice] = []
) -> LibraryEntry {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let observedAt = operationsAreCurrent ? now : now.addingTimeInterval(-120)
    let freshness = OperationalEvidenceFreshness(
        observedAt: observedAt,
        evaluatedAt: now,
        staleAfter: 15
    )
    let nodeID = SparkNodeID(
        rawValue: UUID(uuidString: "a647b28d-f6ae-4cbc-adf1-f117436a4aaa")!
    )
    let member = LibraryMember(
        nodeID: nodeID,
        name: "Private Spark Name",
        role: .standalone,
        authorityFingerprint: "authority",
        routes: [],
        lastSeen: now,
        reachable: connection != .offlineCached
    )
    let snapshot = TargetOperationalSnapshot(
        identity: .node(nodeID),
        displayName: "Private Spark Name",
        members: [],
        preferredRoute: nil,
        connectionState: connection == .offlineCached ? .offlineCached : .connectedWiFi,
        lastSuccessfulContact: observedAt,
        evaluatedAt: now,
        evidence: TargetEvidenceFreshness(
            health: freshness,
            inventory: freshness,
            memory: freshness,
            inference: freshness,
            operations: freshness
        ),
        runtime: TargetRuntimeSnapshot(
            version: "0.4.0",
            health: .healthy,
            updateState: runtimeUpdateState
        ),
        vllmHealth: .ready,
        unifiedMemory: nil,
        disk: nil,
        installedModelCount: 0,
        activeInference: nil,
        operations: [notificationOperation(state: operationState)],
        placements: [],
        warnings: notices,
        blockers: [],
        technicalDetails: TargetTechnicalDetails(
            logicalIdentity: SparkTargetIdentity.node(nodeID).description,
            memberNodeIDs: [nodeID]
        )
    )
    return LibraryEntry(
        logicalKey: .node(nodeID),
        name: "Private Spark Name",
        members: [member],
        connectionState: connection,
        lastSeen: now,
        cachedAt: now,
        cachedOperationalSnapshot: snapshot
    )
}
