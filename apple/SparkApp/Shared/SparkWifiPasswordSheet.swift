import Foundation
import SparkAPI
import SparkCore
import SparkDesignSystem
import SwiftUI

struct SparkWifiPasswordSheet: View {
    @Bindable var model: SparkSettingsModel

    var body: some View {
        NavigationStack {
            Form {
                if let ssid = model.selectedWifiSSID,
                    let network = model.wifi?.networks.first(where: { $0.ssid == ssid })
                {
                    Section {
                        LabeledContent("Network", value: ssid)
                        LabeledContent("Security", value: network.security.rawValue.uppercased())
                        if network.security != .open {
                            PasswordField(
                                title: String(localized: "Wi-Fi password"),
                                text: $model.wifiPassword,
                                reveals: $model.revealsWifiPassword
                            )
                        }
                        if network.security == .enterprise {
                            Text(
                                "Enterprise Wi-Fi needs identity and certificate fields that this version does not collect yet."
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    } footer: {
                        Text(
                            "The password is sent directly to this Spark and is never stored in the app’s cache."
                        )
                    }
                }
            }
            .navigationTitle("Join Wi-Fi")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.selectedWifiSSID = nil
                        model.wifiPassword = ""
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Join") { Task { await model.connectSelectedWifi() } }
                        .disabled(wifiJoinDisabled)
                }
            }
        }
        .presentationDetents([.medium])

    }
    private var wifiJoinDisabled: Bool {
        guard let ssid = model.selectedWifiSSID,
            let network = model.wifi?.networks.first(where: { $0.ssid == ssid })
        else { return true }
        return network.security == .enterprise
            || (network.security != .open && model.wifiPassword.count < 8)
    }
}
