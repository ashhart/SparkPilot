import Foundation
import Observation
import SparkCore
import SparkLibrary
import SwiftUI
import UserNotifications

public enum SparkNotificationPlanner {
    public static func notifications(
        previous: [String: SparkNotificationObservation],
        current: [String: SparkNotificationObservation]
    ) -> [SparkLocalNotification] {
        current.keys.sorted().flatMap { targetID -> [SparkLocalNotification] in
            guard let currentTarget = current[targetID] else {
                return []
            }
            guard let oldTarget = previous[targetID] else {
                return initialNotifications(for: currentTarget)
            }
            var planned = connectionNotifications(from: oldTarget, to: currentTarget)
            planned += operationNotifications(from: oldTarget, to: currentTarget)
            planned += noticeNotifications(from: oldTarget, to: currentTarget)
            return planned
        }
    }

    private static func initialNotifications(
        for target: SparkNotificationObservation
    ) -> [SparkLocalNotification] {
        // Fresh hardware warnings count even if older than this launch; cached or finished ones do not.
        let initialCodes =
            target.connectionState.isConnected
            ? target.noticeCodes
            : target.noticeCodes.intersection([
                "runtime.update_available", "runtime.update_required",
            ])
        guard !initialCodes.isEmpty else { return [] }
        let baseline = SparkNotificationObservation(
            targetID: target.targetID,
            connectionState: target.connectionState,
            operations: target.operations,
            noticeCodes: target.noticeCodes.subtracting(initialCodes)
        )
        return noticeNotifications(from: baseline, to: target)
    }

    private static func connectionNotifications(
        from old: SparkNotificationObservation,
        to new: SparkNotificationObservation
    ) -> [SparkLocalNotification] {
        if old.connectionState.isConnected, new.connectionState == .offlineCached {
            return [
                SparkLocalNotification(
                    identifier: "\(new.targetID).offline",
                    title: String(localized: "A Spark is offline"),
                    body: String(localized: "Open SparkPilot to check its connection."),
                    category: "SPARK_HEALTH",
                    targetID: new.targetID
                )
            ]
        }
        if old.connectionState == .offlineCached, new.connectionState.isConnected {
            return [
                SparkLocalNotification(
                    identifier: "\(new.targetID).recovered",
                    title: String(localized: "A Spark is back online"),
                    body: String(localized: "Live status and private AI are available again."),
                    category: "SPARK_HEALTH",
                    targetID: new.targetID
                )
            ]
        }
        return []
    }

    private static func operationNotifications(
        from old: SparkNotificationObservation,
        to new: SparkNotificationObservation
    ) -> [SparkLocalNotification] {
        let previous = Dictionary(uniqueKeysWithValues: old.operations.map { ($0.id, $0.state) })
        return new.operations.compactMap { operation in
            guard operation.kind != "automation.run" || operation.notificationRequested == true
            else { return nil }
            guard operation.state.isTerminal else { return nil }
            if let oldState = previous[operation.id] {
                guard !oldState.isTerminal else { return nil }
            } else {
                // Scheduled work often starts and finishes while the phone is asleep.
                guard operation.kind == "automation.run", let previousCheck = old.observedAt,
                    let finished = operation.completedAt, finished > previousCheck
                else { return nil }
            }
            let operationID = operation.id.rawValue.uuidString.lowercased()
            switch operation.state {
            case .succeeded:
                return SparkLocalNotification(
                    identifier: "\(new.targetID).operation.\(operationID).succeeded",
                    title: operation.kind.successTitle,
                    body: String(localized: "Open Activity to see the result."),
                    category: "SPARK_OPERATION",
                    targetID: new.targetID,
                    operationID: operationID
                )
            case .failed:
                return SparkLocalNotification(
                    identifier: "\(new.targetID).operation.\(operationID).failed",
                    title: String(localized: "A Spark task needs attention"),
                    body: String(
                        localized: "Open Activity to review the failure and retry safely."
                    ),
                    category: "SPARK_OPERATION",
                    targetID: new.targetID,
                    operationID: operationID
                )
            case .cancelled:
                return SparkLocalNotification(
                    identifier: "\(new.targetID).operation.\(operationID).cancelled",
                    title: String(localized: "A Spark task was cancelled"),
                    body: String(localized: "Open Activity for details."),
                    category: "SPARK_OPERATION",
                    targetID: new.targetID,
                    operationID: operationID
                )
            default:
                return nil
            }
        }
    }

    private static func noticeNotifications(
        from old: SparkNotificationObservation,
        to new: SparkNotificationObservation
    ) -> [SparkLocalNotification] {
        let newCodes = new.noticeCodes.subtracting(old.noticeCodes)
        return newCodes.sorted().compactMap { code in
            let presentation: (String, String)? =
                switch code {
                case "memory.pressure_warning", "memory.pressure_blocking":
                    (
                        String(localized: "Spark memory needs attention"),
                        String(localized: "Open SparkPilot before starting more model work.")
                    )
                case "node.thermal_warning":
                    (
                        String(localized: "A Spark is running hot"),
                        String(localized: "Open SparkPilot to check its temperature and power.")
                    )
                case "cluster.degraded":
                    (
                        String(localized: "A cluster link is degraded"),
                        String(localized: "Open SparkPilot to check its members and links.")
                    )
                case "inference.failed", "runtime.degraded":
                    (
                        String(localized: "Private AI needs attention"),
                        String(localized: "Open SparkPilot to inspect health and recovery.")
                    )
                case "runtime.update_available", "runtime.update_required":
                    (
                        String(localized: "A verified Spark update is available"),
                        String(localized: "Open SparkPilot to review it.")
                    )
                case "target.identity_mismatch":
                    (
                        String(localized: "A Spark identity changed"),
                        String(localized: "SparkPilot blocked the connection. Open it to review.")
                    )
                default:
                    nil
                }
            guard let presentation else { return nil }
            return SparkLocalNotification(
                identifier: "\(new.targetID).notice.\(code)",
                title: presentation.0,
                body: presentation.1,
                category: "SPARK_HEALTH",
                targetID: new.targetID
            )
        }
    }
}

public enum SparkInferenceNotificationHealth: String, Equatable, Sendable {
    case healthy
    case unhealthy
    case unknown
}

public enum SparkInferenceNotificationMemoryPressure: String, Equatable, Sendable {
    case normal
    case warning
    case critical
    case emergency
    case unknown

    fileprivate var needsAttention: Bool {
        switch self {
        case .warning, .critical, .emergency: true
        case .normal, .unknown: false
        }
    }
}

public struct SparkInferenceNotificationObservation: Equatable, Sendable {
    public let targetID: String
    public let health: SparkInferenceNotificationHealth
    public let queueDepth: Int?
    public let memoryPressure: SparkInferenceNotificationMemoryPressure

    public init(
        targetID: String,
        health: SparkInferenceNotificationHealth,
        queueDepth: Int?,
        memoryPressure: SparkInferenceNotificationMemoryPressure
    ) {
        self.targetID = targetID
        self.health = health
        self.queueDepth = queueDepth
        self.memoryPressure = memoryPressure
    }
}

public enum SparkInferenceNotificationPlanner {
    static let backedUpQueueDepth = 4

    public static func notifications(
        from old: SparkInferenceNotificationObservation?,
        to new: SparkInferenceNotificationObservation
    ) -> [SparkLocalNotification] {
        guard let old else { return [] }
        var notifications: [SparkLocalNotification] = []
        if old.health != .unhealthy, new.health == .unhealthy {
            notifications.append(
                healthNotification(
                    targetID: new.targetID,
                    identifier: "inference-unhealthy",
                    title: String(localized: "Private AI needs attention"),
                    body: String(
                        localized: "Open SparkPilot to inspect inference health and recovery."
                    )
                )
            )
        } else if old.health == .unhealthy, new.health == .healthy {
            notifications.append(
                healthNotification(
                    targetID: new.targetID,
                    identifier: "inference-recovered",
                    title: String(localized: "Private AI recovered"),
                    body: String(localized: "The inference service is healthy again.")
                )
            )
        }

        let oldQueueIsBackedUp = (old.queueDepth ?? 0) >= backedUpQueueDepth
        let newQueueIsBackedUp = (new.queueDepth ?? 0) >= backedUpQueueDepth
        if !oldQueueIsBackedUp, newQueueIsBackedUp {
            notifications.append(
                healthNotification(
                    targetID: new.targetID,
                    identifier: "inference-queue",
                    title: String(localized: "Inference requests are queued"),
                    body: String(localized: "Open SparkPilot to check live capacity and memory.")
                )
            )
        } else if oldQueueIsBackedUp, new.queueDepth == 0 {
            notifications.append(
                healthNotification(
                    targetID: new.targetID,
                    identifier: "inference-queue-cleared",
                    title: String(localized: "Inference queue cleared"),
                    body: String(localized: "Queued work has finished processing.")
                )
            )
        }

        if !old.memoryPressure.needsAttention, new.memoryPressure.needsAttention {
            notifications.append(
                healthNotification(
                    targetID: new.targetID,
                    identifier: "inference-memory",
                    title: String(localized: "Spark memory needs attention"),
                    body: String(localized: "Open SparkPilot before starting more model work.")
                )
            )
        }
        return notifications
    }

    private static func healthNotification(
        targetID: String,
        identifier: String,
        title: String,
        body: String
    ) -> SparkLocalNotification {
        SparkLocalNotification(
            identifier: "\(targetID).\(identifier)",
            title: title,
            body: body,
            category: "SPARK_HEALTH",
            targetID: targetID
        )
    }
}

extension SparkConnectionState {
    var isConnected: Bool {
        switch self {
        case .connectedWiFi, .connectedDirect, .connectedRemote: true
        default: false
        }
    }
}

extension SparkOperationState {
    fileprivate var isTerminal: Bool {
        switch self {
        case .cancelled, .succeeded, .failed: true
        default: false
        }
    }
}

extension String {
    fileprivate var successTitle: String {
        let value = lowercased()
        if value.contains("automation") {
            return String(localized: "An automation finished")
        }
        if value.contains("download") || value.contains("install") {
            return String(localized: "A model download finished")
        }
        if value.contains("unload") {
            return String(localized: "A model was unloaded")
        }
        if value.contains("load") {
            return String(localized: "A model is ready")
        }
        if value.contains("update") {
            return String(localized: "A Spark update finished")
        }
        return String(localized: "A Spark task finished")
    }
}
