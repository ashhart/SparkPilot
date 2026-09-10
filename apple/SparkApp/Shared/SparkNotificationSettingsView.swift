import Foundation
import Observation
import SparkCore
import SparkLibrary
import SwiftUI
import UserNotifications

public struct SparkNotificationSettingsView: View {
    @Bindable private var model: SparkNotificationModel
    @State private var isChanging = false

    public init(model: SparkNotificationModel) {
        self.model = model
    }

    public var body: some View {
        Form {
            if !model.currentAlerts.isEmpty {
                Section("Your Sparks") {
                    ForEach(model.currentAlerts, id: \.identifier) { alert in
                        alertRow(alert)
                    }
                }
            }
            if !model.harnessUpdates.isEmpty {
                Section("Coding agent updates") {
                    ForEach(model.harnessUpdates, id: \.identifier) { alert in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(alert.title).font(.headline)
                            Text(alert.body).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                Toggle(
                    "Useful notifications",
                    isOn: Binding(
                        get: { model.isEnabled },
                        set: { enabled in
                            isChanging = true
                            Task {
                                await model.setEnabled(enabled)
                                isChanging = false
                            }
                        }
                    )
                )
                .disabled(isChanging)
            } footer: {
                notificationPrivacyCopy
            }
            if model.authorization == .denied {
                Section {
                    Text("Notifications are blocked in System Settings.")
                        .foregroundStyle(.secondary)
                }
            }
            if let error = model.errorMessage {
                Section {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Notifications")
        .task { await model.prepare() }
    }

    private func alertRow(_ alert: SparkLocalNotification) -> some View {
        Button {
            NotificationCenter.default.post(
                name: .sparkNotificationOpened,
                object: SparkNotificationDestination.home(targetID: alert.targetID)
            )
        } label: {
            Label(alert.title, systemImage: "exclamationmark.circle")
        }
    }

    private var notificationPrivacyCopy: Text {
        #if os(iOS)
            Text(
                "SparkPilot checks while it is open, when you return, and when iPhone or iPad gives it background time. Background alerts are not guaranteed. Prompts, responses, file names, hostnames, and network addresses stay out."
            )
        #else
            Text(
                "SparkPilot checks while it is open and whenever you return. Prompts, responses, file names, hostnames, and network addresses stay out."
            )
        #endif
    }
}
