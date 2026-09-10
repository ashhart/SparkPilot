import Foundation
import SparkAPI
import SparkCore
import SparkDesignSystem
import SwiftUI

struct SparkSettingsRuntimeUpgradeSection: View {
    @Bindable var model: SparkSettingsModel

    var body: some View {
        SettingsCard(
            title: String(localized: "Install SparkPilot features"),
            symbol: "arrow.down.app",
            help: String(
                localized:
                    "Installs the signed Spark Runtime required by this version of SparkPilot."
            )
        ) {
            if model.runtimePasswordFallbackRequired {
                Text(model.passwordFallbackExplanation)
                    .foregroundStyle(.secondary)
                #if os(iOS)
                    TextField("Spark username", text: $model.administratorUsername)
                        .sparkField()
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(model.activeMutation != nil)
                #else
                    TextField("Spark username", text: $model.administratorUsername)
                        .sparkField()
                        .textContentType(.username)
                        .disabled(model.activeMutation != nil)
                #endif
                PasswordField(
                    title: String(localized: "Spark password"),
                    text: $model.administratorPassword,
                    reveals: $model.revealsAdministratorPassword
                )
                .disabled(model.activeMutation != nil)
            } else {
                Text(
                    "SparkPilot will use this device's paired administrator approval to install the signed runtime."
                )
                .foregroundStyle(.secondary)
            }
            if let stage = model.runtimeUpgradeStage {
                RuntimeUpgradeProgressView(stage: stage)
            }
            Button(
                model.runtimePasswordFallbackRequired
                    ? String(localized: "Install Runtime") : String(localized: "Update Spark")
            ) {
                Task {
                    if model.runtimePasswordFallbackRequired {
                        await model.installRequiredRuntime()
                    } else {
                        await model.repairRequiredRuntime()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                model.activeMutation != nil
                    || (model.runtimePasswordFallbackRequired
                        && (model.administratorUsername.isEmpty
                            || model.administratorPassword.isEmpty))
            )
            if model.runtimePasswordFallbackRequired {
                Text(
                    "The password stays in memory only for this install and is cleared afterwards."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }

    }
}

struct SparkSettingsUpdatesSection: View {
    @Bindable var model: SparkSettingsModel
    var powerControl: SparkPowerControlModel? = nil

    var body: some View {
        SettingsCard(
            title: String(localized: "Software updates"),
            symbol: "arrow.triangle.2.circlepath",
            help: String(
                localized:
                    "Check OS packages, firmware and the signed Spark Runtime release channel."
            )
        ) {
            if let updates = model.settings?.softwareUpdates {
                LabeledContent("OS packages", value: updateCount(updates.systemPackagesAvailable))
                LabeledContent("Firmware", value: updateCount(updates.firmwareUpdatesAvailable))
                LabeledContent(
                    "Runtime",
                    value: model.runtimeUpdateAvailable
                        ? (model.bundledRuntimeReleaseID ?? String(localized: "Update available"))
                        : model.runtimeVersionIsKnown
                            ? String(localized: "Current")
                            : String(localized: "Status unavailable")
                )
                if updates.rebootRequired {
                    Label("A restart is required.", systemImage: "arrow.clockwise.circle.fill")
                        .foregroundStyle(.orange)
                    Text(
                        SparkSettingsUpdatesPresentation.restartDetail(
                            primary: primaryAction(updates)
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                if !model.updateStatusIsCurrent {
                    Text("Showing the last known update status. Refresh to check the connection.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Check for Updates") {
                    Task { await model.checkForUpdates() }
                }
                .buttonStyle(.bordered)
                .disabled(model.isLoading || model.activeMutation != nil)
                if let stage = model.runtimeUpgradeStage {
                    RuntimeUpgradeProgressView(stage: stage)
                }
                // Keep runtime updates separate so queued OS packages cannot block or fail them.
                if model.runtimeUpdateAvailable {
                    Button("Update Runtime") {
                        Task { await model.repairRequiredRuntime() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isLoading || model.activeMutation != nil)
                    .accessibilityHint(
                        "Installs only the signed Spark Runtime bundled with SparkPilot."
                    )
                }
                if model.runtimeUpdateAvailable && model.hasSystemUpdates {
                    Button("Install All Signed Updates") {
                        Task { await model.installAvailableUpdates() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.canInstallAvailableUpdates)
                } else if primaryAction(updates) == .restart, let powerControl {
                    // Nothing is left to install; the restart is what finishes the update.
                    Button("Restart Spark") {
                        powerControl.request(.reboot)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        model.isLoading || model.activeMutation != nil || powerControl.isSubmitting
                    )
                    .modifier(SparkPowerConfirmation(model: powerControl))
                    if let message = powerControl.successMessage ?? powerControl.errorMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                } else if model.hasSystemUpdates {
                    Button("Install Signed Updates") {
                        Task { await model.installAvailableUpdates() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canInstallAvailableUpdates)
                }
            }
        }

    }
    private func primaryAction(_ updates: GeneratedAPI.SoftwareUpdateStatus)
        -> SparkSettingsUpdatesPresentation.PrimaryAction
    {
        SparkSettingsUpdatesPresentation.primaryAction(
            systemPackages: updates.systemPackagesAvailable,
            firmware: updates.firmwareUpdatesAvailable,
            runtimeUpdateAvailable: model.runtimeUpdateAvailable || model.canInstallBundledRuntime,
            rebootRequired: updates.rebootRequired,
            canRestart: powerControl != nil
        )
    }
    private func updateCount(_ count: Int?) -> String {
        count.flatMap { $0 >= 0 ? $0 : nil }.map {
            $0 == 0 ? String(localized: "Current") : String(localized: .updatesAvailable($0))
        }
            ?? String(localized: "Check unavailable")
    }
}
