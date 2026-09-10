import Foundation
import Observation
import SparkCore
import SparkLibrary
import SwiftUI
import UserNotifications

public enum SparkNotificationAuthorization: String, Equatable, Sendable {
    case unknown
    case denied
    case allowed
}

public enum SparkNotificationDestination: Equatable, Sendable {
    case service(targetID: String, serviceID: String)
    case projectChange(targetID: String, projectID: String, changeID: String)
    case home(targetID: String)
    case activity(targetID: String)
    case operation(targetID: String, operationID: String)

    public static func resolve(
        category: String,
        action: String,
        targetID: String,
        operationID: String?,
        serviceID: String? = nil,
        projectID: String? = nil,
        changeID: String? = nil
    ) -> SparkNotificationDestination {
        if let projectID, let changeID, UUID(uuidString: projectID) != nil,
            UUID(uuidString: changeID) != nil
        {
            return .projectChange(
                targetID: targetID,
                projectID: projectID.lowercased(),
                changeID: changeID.lowercased()
            )
        }
        if serviceID == "open-webui" {
            return .service(targetID: targetID, serviceID: "open-webui")
        }
        if let operationID, !operationID.isEmpty {
            return .operation(targetID: targetID, operationID: operationID.lowercased())
        }
        if category == "SPARK_OPERATION" || action == "OPEN_ACTIVITY" {
            return .activity(targetID: targetID)
        }
        return .home(targetID: targetID)
    }
}

public struct SparkNotificationOperationRoute: Equatable, Identifiable, Sendable {
    public let targetID: String
    public let operationID: SparkOperationID

    public init?(targetID: String, operationID: String) {
        guard let id = UUID(uuidString: operationID) else { return nil }
        self.targetID = targetID
        self.operationID = SparkOperationID(rawValue: id)
    }

    public var id: String {
        "\(targetID):\(operationID.rawValue.uuidString.lowercased())"
    }
}

extension Notification.Name {
    public static let sparkNotificationOpened = Notification.Name("sparkpilot.notification.opened")
    public static let sparkInferenceObservation = Notification.Name(
        "sparkpilot.inference.observation"
    )
}

/// One button on a delivered notification.
public struct SparkNotificationAction: Equatable, Sendable {
    /// What the response delegate switches on. Never shown.
    public let identifier: String
    /// What the reader sees on the button.
    public let title: String
}

/// One notification category, and the actions it offers.
public struct SparkNotificationCategory: Equatable, Sendable {
    public let identifier: String
    public let actions: [SparkNotificationAction]
}

/// Declares notification categories as testable values so action-title copy is covered by SparkNotificationCategoryCopyTests.
public enum SparkNotificationCategories {
    public static let operation = "SPARK_OPERATION"
    public static let health = "SPARK_HEALTH"

    public static var all: [SparkNotificationCategory] {
        [
            SparkNotificationCategory(
                identifier: operation,
                actions: [
                    SparkNotificationAction(
                        identifier: "OPEN_ACTIVITY",
                        title: String(localized: "Review Task")
                    )
                ]
            ),
            SparkNotificationCategory(
                identifier: health,
                actions: [
                    SparkNotificationAction(
                        identifier: "OPEN_SPARK",
                        title: String(localized: "Open Spark")
                    )
                ]
            ),
        ]
    }
}

public struct SparkLocalNotification: Codable, Equatable, Sendable {
    public let identifier: String
    public let title: String
    public let body: String
    public let category: String
    public let targetID: String
    public let operationID: String?
    public let serviceID: String?
    public let projectID: String?
    public let changeID: String?

    public init(
        identifier: String,
        title: String,
        body: String,
        category: String,
        targetID: String,
        operationID: String? = nil,
        serviceID: String? = nil,
        projectID: String? = nil,
        changeID: String? = nil
    ) {
        self.identifier = identifier
        self.title = title
        self.body = body
        self.category = category
        self.targetID = targetID
        self.operationID = operationID
        self.serviceID = serviceID
        self.projectID = projectID
        self.changeID = changeID
    }
}

public protocol SparkNotificationDelivering: Sendable {
    func authorization() async -> SparkNotificationAuthorization
    func requestAuthorization() async throws -> Bool
    func registerCategories() async
    func deliver(_ notification: SparkLocalNotification) async throws
}

public struct SparkNotificationObservation: Equatable, Sendable {
    public let targetID: String
    public let connectionState: SparkConnectionState
    public let operations: [TargetOperationSnapshot]
    public let noticeCodes: Set<String>
    public let observedAt: Date?

    public init(
        targetID: String,
        connectionState: SparkConnectionState,
        operations: [TargetOperationSnapshot],
        noticeCodes: Set<String>,
        observedAt: Date? = nil
    ) {
        self.targetID = targetID
        self.connectionState = connectionState
        self.operations = operations
        self.noticeCodes = noticeCodes
        self.observedAt = observedAt
    }
}
