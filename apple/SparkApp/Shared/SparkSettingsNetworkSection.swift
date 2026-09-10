import Foundation
import SparkAPI
import SparkCore
import SparkDesignSystem
import SwiftUI

struct SparkSettingsNetworkSection: View {
    @Bindable var model: SparkSettingsModel
    @Binding var pendingWifiForget: String?

    var body: some View {
        SettingsCard(
            title: String(localized: "Wi-Fi"),
            symbol: "wifi",
            help: String(
                localized: "Join, forget and inspect the wireless networks visible to this Spark."
            )
        ) {
            if let pending = model.pendingNetworkChange {
                VStack(alignment: .leading, spacing: 10) {
                    Label(
                        pending.canKeep
                            ? String(localized: "New route verified")
                            : String(localized: "Checking the new route"),
                        systemImage: pending.canKeep
                            ? "checkmark.shield.fill" : "arrow.trianglehead.2.clockwise.rotate.90"
                    )
                    .font(.headline)
                    if pending.canKeep {
                        Text(
                            "SparkPilot reached the same paired Spark over the new route. Keep the change only if this Apple device can still reach it."
                        )
                    } else {
                        Text(
                            "Nothing has been kept yet. If SparkPilot cannot verify the same paired Spark, its safety timer restores the previous network."
                        )
                    }
                    HStack {
                        if pending.canKeep {
                            Button("Keep Changes") {
                                Task { await model.keepNetworkChanges() }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        Button("Undo Now", role: .destructive) {
                            Task { await model.rollbackNetworkChanges() }
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding(12)
                .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                Divider()
            }
            if let networks = model.wifi?.networks, !networks.isEmpty {
                ForEach(networks, id: \.ssid) { network in
                    HStack(spacing: 12) {
                        Image(
                            systemName: "wifi",
                            variableValue: Double(min(100, max(0, network.signalPercent))) / 100
                        )
                        .foregroundStyle(network.connected ? .green : .secondary)
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(network.ssid)
                                .font(.headline)
                            Text(wifiSubtitle(network))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if network.connected {
                            Label("Connected", systemImage: "checkmark.circle.fill")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.green)
                        } else {
                            Button("Join") { model.selectedWifiSSID = network.ssid }
                                .buttonStyle(.bordered)
                                .disabled(network.security == .enterprise)
                        }
                        if network.saved, !network.connected {
                            Button(role: .destructive) {
                                pendingWifiForget = network.ssid
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(
                                String(localized: .forgetNetwork(network.ssid))
                            )
                        }
                    }
                    .padding(.vertical, 4)
                    if network.ssid != networks.last?.ssid { Divider() }
                }
            } else if model.wifiScanUnavailable {
                Label(
                    "The Spark's Wi-Fi scan did not finish. Refresh to scan again.",
                    systemImage: "wifi.exclamationmark"
                )
                .foregroundStyle(.secondary)
            } else {
                Text("No Wi-Fi networks are visible.")
                    .foregroundStyle(.secondary)
            }
            Divider()
            Toggle(
                "Direct Ethernet fallback",
                isOn: Binding(
                    get: { model.directEthernetEnabled },
                    set: { value in Task { await model.setDirectEthernet(value) } }
                )
            )
            Text("Uses a private link-local profile without changing your LAN settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Text("Main Ethernet")
                .font(.headline)
            Text(
                "Set a fixed LAN address for the active ordinary Ethernet connection. SparkPilot never changes the cluster fabric."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            TextField("IPv4 address", text: $model.lanAddress)
                .sparkField()
            Stepper(
                .prefixLength(model.lanPrefixLength),
                value: $model.lanPrefixLength,
                in: 1...30
            )
            TextField("Gateway", text: $model.lanGateway)
                .sparkField()
            TextField("DNS servers, separated by commas", text: $model.lanDNSServers)
                .sparkField()
            Text(
                "The Spark restores the previous profile after 30 seconds unless this device reaches the same paired Spark at the new address and you tap Keep Changes."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Button("Apply Manual IPv4") {
                Task { await model.applyManualLanIpv4() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canApplyManualLanIpv4 || model.activeMutation != nil)
        }

    }
    private func wifiSubtitle(_ network: GeneratedAPI.WifiNetwork) -> String {
        [
            network.security.rawValue.uppercased(),
            "\(network.signalPercent)%",
            network.saved ? String(localized: "Saved") : nil,
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }
}
