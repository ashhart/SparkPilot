import Foundation
import Observation
import SparkCore
import SparkLibrary
import SwiftUI
import UserNotifications

public final class SparkNotificationResponseDelegate: NSObject, UNUserNotificationCenterDelegate,
    @unchecked Sendable
{
    public static let shared = SparkNotificationResponseDelegate()

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        []
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let content = response.notification.request.content
        let targetID = content.userInfo["target_id"] as? String ?? ""
        guard !targetID.isEmpty else { return }
        let destination = SparkNotificationDestination.resolve(
            category: content.categoryIdentifier,
            action: response.actionIdentifier,
            targetID: targetID,
            operationID: content.userInfo["operation_id"] as? String,
            serviceID: content.userInfo["service_id"] as? String,
            projectID: content.userInfo["project_id"] as? String,
            changeID: content.userInfo["change_id"] as? String
        )
        await MainActor.run {
            NotificationCenter.default.post(
                name: .sparkNotificationOpened,
                object: destination
            )
        }
    }
}

public actor SystemSparkNotificationDelivery: SparkNotificationDelivering {
    public init() {}

    public func authorization() async -> SparkNotificationAuthorization {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: .allowed
        case .denied: .denied
        case .notDetermined: .unknown
        @unknown default: .unknown
        }
    }

    public func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    public func registerCategories() async {
        let center = UNUserNotificationCenter.current()
        center.delegate = SparkNotificationResponseDelegate.shared
        center.setNotificationCategories(
            Set(
                SparkNotificationCategories.all.map { category in
                    UNNotificationCategory(
                        identifier: category.identifier,
                        actions: category.actions.map { action in
                            UNNotificationAction(
                                identifier: action.identifier,
                                title: action.title,
                                options: [.foreground]
                            )
                        },
                        intentIdentifiers: []
                    )
                }
            )
        )
    }

    public func deliver(_ notification: SparkLocalNotification) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.categoryIdentifier = notification.category
        content.userInfo = [
            "target_id": notification.targetID,
            "operation_id": notification.operationID ?? "",
            "service_id": notification.serviceID ?? "",
            "project_id": notification.projectID ?? "",
            "change_id": notification.changeID ?? "",
        ]
        try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: notification.identifier,
                content: content,
                trigger: nil
            )
        )
    }
}
