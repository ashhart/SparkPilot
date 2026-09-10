import Foundation
import SparkAPI
import SparkCore
import SparkDesignSystem
import SparkLibrary
import SwiftUI

struct SparkDashboardSettingsPanel: View {
    let identitySettingsModel: SparkIdentitySettingsModel?
    let settingsModel: SparkSettingsModel?
    let networkStatusModel: SparkNetworkStatusModel?
    let remoteAccessModel: RemoteAccessModel?
    let deviceManagementModel: DeviceManagementModel?
    let powerControlModel: SparkPowerControlModel?
    let refresh: () async -> Void

    var body: some View {
        SparkDashboardPage(refresh: refresh) {
            if let identitySettingsModel {
                SparkIdentitySettingsCard(model: identitySettingsModel)
            }
            if let settingsModel {
                // Keep each settings concern one navigation level below the dashboard.
                SparkSettingsGroupRows(
                    context: SparkSettingsContext(
                        settings: settingsModel,
                        networkStatus: networkStatusModel,
                        remoteAccess: remoteAccessModel,
                        powerControl: powerControlModel
                    )
                )
            } else if let networkStatusModel {
                // Older runtimes with network status alone still expose that page.
                NavigationLink {
                    SparkNetworkStatusView(model: networkStatusModel)
                } label: {
                    SparkSettingsCardRowLabel(
                        title: String(localized: "Network"),
                        detail: String(
                            localized:
                                "Interfaces, addresses, link speed and internet reachability"
                        ),
                        symbol: "network"
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open network status")
            }
            if let deviceManagementModel {
                deviceAccess(model: deviceManagementModel)
            }
            if let powerControlModel {
                SparkPowerControlsView(model: powerControlModel)
            }
        }
        .navigationTitle("Settings")
    }
    private func deviceAccess(model: DeviceManagementModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Access")
                .font(.title2.bold())
            NavigationLink {
                DeviceManagementView(model: model)
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "laptopcomputer.and.iphone")
                        .font(.title2)
                        .frame(width: 38, height: 38)
                        .background(Color.accentColor.opacity(0.1), in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Paired devices")
                            .font(.headline)
                        Text("Review and revoke access to this Spark.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .padding()
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Manage paired devices")
            .accessibilityHint("Opens the devices that can access this Spark.")
            .accessibilityIdentifier("spark.dashboard.device-management")
        }
    }
}
