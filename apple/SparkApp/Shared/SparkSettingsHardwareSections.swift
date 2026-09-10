import Foundation
import SparkAPI
import SparkCore
import SparkDesignSystem
import SwiftUI

struct SparkSettingsBluetoothSection: View {
    @Bindable var model: SparkSettingsModel

    var body: some View {
        SettingsCard(
            title: String(localized: "Bluetooth"),
            symbol: "wave.3.right",
            help: String(
                localized: "Control the radio and explicitly approve nearby devices before pairing."
            )
        ) {
            if model.settings?.bluetooth.available == true {
                Toggle(
                    "Bluetooth radio",
                    isOn: Binding(
                        get: { model.bluetoothPowered },
                        set: { value in Task { await model.setBluetoothPowered(value) } }
                    )
                )
                Button("Scan for Devices") { Task { await model.scanBluetooth() } }
                    .buttonStyle(.bordered)
                ForEach(model.settings?.bluetooth.nearbyDevices ?? [], id: \.address) { device in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(device.name)
                            Text(device.address)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(
                            device.paired ? String(localized: "Remove") : String(localized: "Pair")
                        ) {
                            Task {
                                await model.bluetoothDevice(device.address, pair: !device.paired)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            } else {
                Label("Bluetooth is unavailable on this Spark.", systemImage: "wave.3.right.slash")
                    .foregroundStyle(.secondary)
            }
        }

    }
}

struct SparkSettingsPowerSection: View {
    @Bindable var model: SparkSettingsModel

    var body: some View {
        SettingsCard(
            title: String(localized: "Power and thermal"),
            symbol: "gauge.with.dots.needle.50percent",
            help: String(
                localized: "Choose a cooler CPU setting or an available NVIDIA power profile."
            )
        ) {
            if let profile = model.settings?.powerProfile, profile.available {
                Picker(
                    "Power profile",
                    selection: Binding(
                        get: { model.selectedPowerModeID ?? profile.currentModeId ?? -1 },
                        set: { value in if value >= 0 { Task { await model.setPowerMode(value) } } }
                    )
                ) {
                    if profile.currentModeId == nil { Text("Current custom setting").tag(-1) }
                    ForEach(profile.modes, id: \.modeId) { mode in
                        Text(friendlyPowerName(mode.name)).tag(mode.modeId)
                    }
                }
                Text(
                    profile.modes.contains(where: { $0.modeId >= 200 })
                        ? "Cooler caps CPU speed at 75% of its original limit; Quiet uses 50%; Automatic restores that limit. Your GPU stays unchanged."
                        : "A cooler profile can reduce sustained temperature and fan noise."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if let temperature =
                    model.liveTelemetry?.accelerator.temperatureCelsius
                    ?? profile.temperatureCelsius
                {
                    LabeledContent(
                        "Temperature",
                        value: Measurement(value: temperature, unit: UnitTemperature.celsius)
                            .formatted(.measurement(width: .narrow, usage: .weather))
                    )
                    if model.sustainedHeatNeedsAttention {
                        Label(
                            "This Spark has stayed hot; consider a cooler setting and check ventilation.",
                            systemImage: "thermometer.high"
                        )
                        .foregroundStyle(.orange)
                    }
                }
                if let draw = model.liveTelemetry?.accelerator.powerDrawWatts
                    ?? profile.powerDrawWatts
                {
                    let livePowerLimit = model.liveTelemetry?.accelerator.powerLimitWatts
                    let limitValue =
                        livePowerLimit
                        ?? profile.powerLimitWatts
                    let limit =
                        limitValue.map {
                            String(localized: .powerLimit(watts(($0), places: 0)))
                        } ?? ""
                    LabeledContent("Power", value: watts(draw, places: 1) + limit)
                }
            } else {
                Text("Power profiles are not reported by this Spark.")
                    .foregroundStyle(.secondary)
            }
        }

    }
    private func friendlyPowerName(_ raw: String) -> String {
        switch raw {
        case "CPU Automatic": return String(localized: "Automatic")
        case "CPU Cooler": return String(localized: "Cooler")
        case "CPU Quiet": return String(localized: "Quiet")
        default: break
        }
        let name = raw.replacingOccurrences(of: "MODE_", with: "").replacingOccurrences(
            of: "_",
            with: " "
        )
        if name.localizedCaseInsensitiveContains("MAX") {
            return String(localized: .powerProfileMax(name.capitalized))
        }
        if name.localizedCaseInsensitiveContains("QUIET") {
            return String(localized: .powerProfileQuiet(name.capitalized))
        }
        return String(localized: .powerProfileBalanced(name.capitalized))
    }
}
