import Foundation
import SparkAPI
import SparkCore
import SparkDesignSystem
import SwiftUI

struct SparkSettingsTimeSection: View {
    @Bindable var model: SparkSettingsModel

    var body: some View {
        SettingsCard(
            title: String(localized: "Time and locale"),
            symbol: "clock",
            help: String(
                localized: "Set the Spark timezone and keep its clock synchronized with NTP."
            )
        ) {
            TextField("Timezone, for example Europe/London", text: $model.timezone)
                .sparkField()
            Toggle("Set time automatically", isOn: $model.ntpEnabled)
            LabeledContent(
                "Clock status",
                value: model.settings?.time.synchronized == true
                    ? String(localized: "Synchronized") : String(localized: "Not synchronized")
            )
            Button("Save Time Settings") { Task { await model.saveTime() } }
                .buttonStyle(.bordered)
        }

    }
}

struct SparkSettingsTelemetrySection: View {
    @Bindable var model: SparkSettingsModel

    var body: some View {
        SettingsCard(
            title: String(localized: "Telemetry choices"),
            symbol: "waveform.path.ecg",
            help:
                String(
                    localized:
                        "Choose which local health history and diagnostics SparkPilot may retain; nothing is uploaded."
                )
        ) {
            Toggle("Functional telemetry", isOn: $model.functionalTelemetry)
            Text("Keeps daily inference usage totals locally on this Spark.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Technical diagnostics", isOn: $model.technicalTelemetry)
            Text("Allows a short in-memory diagnostic history. Nothing is uploaded by SparkPilot.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Save Telemetry Choices") { Task { await model.saveTelemetryConsent() } }
                .buttonStyle(.bordered)
        }

    }
}
