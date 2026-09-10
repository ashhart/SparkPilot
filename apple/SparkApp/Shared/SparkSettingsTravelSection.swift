import Foundation
import SparkAPI
import SparkCore
import SparkDesignSystem
import SwiftUI

struct SparkSettingsTravelSection: View {
    @Bindable var model: SparkSettingsModel

    var body: some View {
        SettingsCard(
            title: String(localized: "Travel hotspot"),
            symbol: "wifi.router",
            help:
                String(
                    localized:
                        "Creates a protected SparkPilot hotspot for local inference away from your main network."
                )
        ) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        model.travelEnabled
                            ? String(localized: "Available offline") : String(localized: "Off")
                    )
                    .font(.headline)
                    Text("Run local inference anywhere without sharing internet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if !model.travelEnabled {
                TextField("Hotspot name", text: $model.travelSSID)
                    .sparkField()
                PasswordField(
                    title: String(localized: "Hotspot password"),
                    text: $model.travelPassword,
                    reveals: $model.revealsTravelPassword
                )
            } else if let status = model.settings?.travelAccessPoint {
                LabeledContent(
                    "Name",
                    value: status.ssid ?? String(localized: "SparkPilot hotspot")
                )
                LabeledContent("Security", value: status.security.rawValue.uppercased())
                if let ssid = status.ssid, !model.travelPassword.isEmpty {
                    TravelQRCode(ssid: ssid, password: model.travelPassword)
                    PasswordField(
                        title: String(localized: "Hotspot password"),
                        text: $model.travelPassword,
                        reveals: $model.revealsTravelPassword
                    )
                }
            }
            Button(
                model.travelEnabled
                    ? String(localized: "Turn Off Travel Hotspot")
                    : String(localized: "Turn On Travel Hotspot")
            ) {
                Task { await model.setTravelAccessPoint(!model.travelEnabled) }
            }
            .buttonStyle(.borderedProminent)
        }

    }
}
