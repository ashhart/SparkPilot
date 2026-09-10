import Foundation
import Observation
import CoreImage.CIFilterBuiltins
import Network
import SparkAPI
import SparkBootstrap
import SparkCore
import SparkDesignSystem
import SparkDiscovery
import SparkSecurity
import SwiftUI
@MainActor
@Observable
final class SparkSettingsPolicyController {
    private let runtime: any SparkSettingsManaging
    private let runtimeInstaller: (any RuntimeBootstrapInstalling)?
    private let operations: SparkSettingsOperationCoordinator
    private let upgrade: SparkSettingsRuntimeUpgrade
    var snapshot: () -> GeneratedAPI.SparkSettingsSnapshot? = { nil }
    var optimisticBluetoothPowered: Bool?
    var optimisticPowerModeID: Int?
    var warningGiB = 16
    var criticalGiB = 10
    var emergencyGiB = 6
    var timezone = "Etc/UTC"
    var ntpEnabled = true
    var functionalTelemetry = false
    var technicalTelemetry = false
    var cleanPartialDownloads = true
    var cleanUnusedBlobs = true
    var cleanStoppedContainers = true
    var cleanUnusedImages = false

    init(
        runtime: any SparkSettingsManaging,
        installer: (any RuntimeBootstrapInstalling)?,
        operations: SparkSettingsOperationCoordinator,
        upgrade: SparkSettingsRuntimeUpgrade
    ) {
        self.runtime = runtime
        self.runtimeInstaller = installer
        self.operations = operations
        self.upgrade = upgrade
    }

    var bluetoothPowered: Bool {
        optimisticBluetoothPowered ?? snapshot()?.bluetooth.powered ?? false
    }

    var selectedPowerModeID: Int? {
        get { optimisticPowerModeID ?? snapshot()?.powerProfile.currentModeId }
        set { optimisticPowerModeID = newValue }
    }

    func setBluetoothPowered(_ enabled: Bool) async {
        let key = UUID()
        optimisticBluetoothPowered = enabled
        await operations.perform(
            label: String(localized: "Updating Bluetooth"),
            reason: String(localized: "Confirm changing Bluetooth on this Spark.")
        ) { presence in
            try await self.runtime.configureBluetooth(
                route: self.operations.route,
                request: .init(action: enabled ? .powerOn : .powerOff),
                idempotencyKey: key,
                userPresence: presence
            )
        }
    }

    func bluetoothDevice(_ address: String, pair: Bool) async {
        let key = UUID()
        await operations.perform(
            label: pair
                ? String(localized: "Pairing Bluetooth device")
                : String(localized: "Removing Bluetooth device"),
            reason: pair
                ? String(localized: "Confirm pairing this Bluetooth device with your Spark.")
                : String(localized: "Confirm removing this Bluetooth device from your Spark.")
        ) { presence in
            try await self.runtime.configureBluetooth(
                route: self.operations.route,
                request: .init(action: pair ? .pair : .remove, deviceAddress: address),
                idempotencyKey: key,
                userPresence: presence
            )
        }
    }

    func scanBluetooth() async {
        let key = UUID()
        await operations.perform(
            label: String(localized: "Scanning for Bluetooth devices"),
            reason: String(
                localized: "Confirm scanning for nearby Bluetooth devices from this Spark."
            )
        ) { presence in
            try await self.runtime.configureBluetooth(
                route: self.operations.route,
                request: .init(action: .startDiscovery),
                idempotencyKey: key,
                userPresence: presence
            )
        }
    }

    func setPowerMode(_ modeID: Int) async {
        let key = UUID()
        optimisticPowerModeID = modeID
        await operations.perform(
            label: String(localized: "Changing power profile"),
            reason: String(localized: "Confirm changing this Spark’s power and thermal profile.")
        ) { presence in
            try await self.runtime.setPowerProfile(
                route: self.operations.route,
                modeID: modeID,
                idempotencyKey: key,
                userPresence: presence
            )
        }
    }

    var hasSystemUpdates: Bool {
        guard let updates = snapshot()?.softwareUpdates else { return false }
        return (updates.systemPackagesAvailable ?? 0) > 0
            || (updates.firmwareUpdatesAvailable ?? 0) > 0
    }

    var hasAvailableUpdates: Bool { hasSystemUpdates || upgrade.runtimeUpdateAvailable }

    func installAvailableUpdates() async {
        guard hasAvailableUpdates, let updates = snapshot()?.softwareUpdates else { return }
        let key = UUID()
        await operations.perform(
            label: String(localized: "Installing updates"),
            reason: String(localized: "Confirm installing verified updates on this Spark."),
            waitsThroughReconnect: true,
            softwareUpdateAction: .install
        ) { presence in
            let runtimeBundle: GeneratedAPI.RuntimeReleaseBundle?
            if self.upgrade.runtimeUpdateAvailable, let installer = self.runtimeInstaller {
                let release = try await installer.prepareRuntimeUpdate()
                runtimeBundle = await encodeRuntimeRelease(release)
            } else {
                runtimeBundle = nil
            }
            // Staging survives installation; it is not evidence of an available update.
            let request = GeneratedAPI.InstallSoftwareUpdatesRequest(
                systemPackages: (updates.systemPackagesAvailable ?? 0) > 0,
                firmware: (updates.firmwareUpdatesAvailable ?? 0) > 0,
                runtimeReleaseId: runtimeBundle?.releaseId,
                runtimeReleaseBundle: runtimeBundle
            )
            return try await self.runtime.installSoftwareUpdates(
                route: self.operations.route,
                request: request,
                idempotencyKey: key,
                userPresence: presence
            )
        }
    }

    func checkForUpdates() async {
        let key = UUID()
        await operations.perform(
            label: String(localized: "Checking for updates"),
            reason: String(localized: "Confirm checking this Spark for OS and firmware updates."),
            softwareUpdateAction: .check
        ) { presence in
            try await self.runtime.checkSoftwareUpdates(
                route: self.operations.route,
                idempotencyKey: key,
                userPresence: presence
            )
        }
    }

    func saveMemoryGuard() async {
        let gib = 1_073_741_824
        let key = UUID()
        let request = GeneratedAPI.MemoryGuardSettings(
            warningAvailableBytes: warningGiB * gib,
            criticalAvailableBytes: criticalGiB * gib,
            emergencyAvailableBytes: emergencyGiB * gib
        )
        await operations.perform(
            label: String(localized: "Saving memory guard"),
            reason: String(
                localized: "Confirm changing the memory safety thresholds on this Spark."
            )
        ) { presence in
            try await self.runtime.updateMemoryGuard(
                route: self.operations.route,
                request: request,
                idempotencyKey: key,
                userPresence: presence
            )
        }
    }

    func saveIdlePolicy(
        modelID: String,
        profileID: String,
        policy: GeneratedAPI.ModelIdlePolicySettingsIdlePolicy,
        idleTimeoutSeconds: Int? = nil
    ) async {
        let key = UUID()
        let request = GeneratedAPI.ModelIdlePolicySettings(
            modelId: modelID,
            profileId: profileID,
            idlePolicy: policy,
            idleTimeoutSeconds: idleTimeoutSeconds
        )
        await operations.perform(
            label: String(localized: "Saving idle policy"),
            reason: String(localized: "Confirm changing when this model unloads from memory.")
        ) { presence in
            try await self.runtime.updateModelIdlePolicy(
                route: self.operations.route,
                request: request,
                idempotencyKey: key,
                userPresence: presence
            )
        }
    }

    func saveTime() async {
        let key = UUID()
        let request = GeneratedAPI.ConfigureSystemTimeRequest(
            timezone: timezone,
            ntpEnabled: ntpEnabled
        )
        await operations.perform(
            label: String(localized: "Saving time settings"),
            reason: String(localized: "Confirm changing time settings on this Spark.")
        ) { presence in
            try await self.runtime.configureSystemTime(
                route: self.operations.route,
                request: request,
                idempotencyKey: key,
                userPresence: presence
            )
        }
    }

    func saveTelemetryConsent() async {
        let key = UUID()
        let request = GeneratedAPI.TelemetryConsentSettings(
            functional: functionalTelemetry,
            technical: technicalTelemetry
        )
        await operations.perform(
            label: String(localized: "Saving telemetry choice"),
            reason: String(localized: "Confirm changing telemetry consent on this Spark.")
        ) { presence in
            try await self.runtime.updateTelemetryConsent(
                route: self.operations.route,
                request: request,
                idempotencyKey: key,
                userPresence: presence
            )
        }
    }

    func cleanStorage() async {
        let key = UUID()
        let request = GeneratedAPI.StorageCleanupRequest(
            partialDownloads: cleanPartialDownloads,
            unusedBlobs: cleanUnusedBlobs,
            stoppedContainers: cleanStoppedContainers,
            unusedImages: cleanUnusedImages
        )
        await operations.perform(
            label: String(localized: "Cleaning storage"),
            reason: String(localized: "Confirm removing the selected unused data from this Spark.")
        ) { presence in
            try await self.runtime.cleanStorage(
                route: self.operations.route,
                request: request,
                idempotencyKey: key,
                userPresence: presence
            )
        }
    }

    func syncDrafts(from settings: GeneratedAPI.SparkSettingsSnapshot) {
        let gib = 1_073_741_824
        warningGiB = max(1, settings.memoryGuard.warningAvailableBytes / gib)
        criticalGiB = max(1, settings.memoryGuard.criticalAvailableBytes / gib)
        emergencyGiB = max(1, settings.memoryGuard.emergencyAvailableBytes / gib)
        timezone = settings.time.timezone
        ntpEnabled = settings.time.ntpEnabled
        functionalTelemetry = settings.telemetryConsent.functional
        technicalTelemetry = settings.telemetryConsent.technical
    }
}
