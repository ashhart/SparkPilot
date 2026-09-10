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
public final class SparkSettingsModel {
    public private(set) var settings: GeneratedAPI.SparkSettingsSnapshot?
    public private(set) var wifi: GeneratedAPI.WifiNetworksSnapshot?
    /// Marks the displayed Wi-Fi list as cached when the latest scan fails.
    public private(set) var wifiScanUnavailable = false
    public private(set) var storage: GeneratedAPI.StorageBreakdown?
    public private(set) var catalogue: ModelCatalogue?
    public private(set) var liveTelemetry: TelemetrySnapshot?
    public private(set) var isLoading = false

    private let operations: SparkSettingsOperationCoordinator
    private let network: SparkSettingsNetworkController
    private let upgrade: SparkSettingsRuntimeUpgrade
    private let policy: SparkSettingsPolicyController
    @ObservationIgnored private let runtime: any SparkSettingsManaging
    @ObservationIgnored private let runtimeInstaller: (any RuntimeBootstrapInstalling)?
    @ObservationIgnored private var hasLoaded = false
    private var hotSampleCount = 0
    public var activeMutation: String? { operations.activeMutation }
    public var errorMessage: String? {
        operations.errorMessage ?? operations.softwareUpdateRecoveryMessage
    }
    public var successMessage: String? {
        guard operations.softwareUpdateRecoveryMessage == nil else { return nil }
        if settings?.softwareUpdates.rebootRequired == true,
            operations.lastOperation?.kind.hasPrefix("system.software_update") == true
        {
            return nil
        }
        return operations.successMessage
    }
    public var hasSystemUpdates: Bool { policy.hasSystemUpdates }
    public var hasAvailableUpdates: Bool { policy.hasAvailableUpdates }
    public private(set) var updateStatusIsCurrent = false
    public private(set) var runtimeVersionIsKnown = false
    public var canInstallAvailableUpdates: Bool {
        updateStatusIsCurrent && !isLoading && activeMutation == nil
            && !operations.hasPendingSoftwareUpdate && hasAvailableUpdates
    }
    public var lastOperation: SparkAPI.Operation? { operations.lastOperation }
    public var route: URL { operations.route }
    public var runtimeUpgradeRequired: Bool { upgrade.runtimeUpgradeRequired }
    public var bundledRuntimeReleaseID: String? { upgrade.bundledRuntimeReleaseID }
    public var runtimeUpdateAvailable: Bool { upgrade.runtimeUpdateAvailable }
    public var runtimeUpgradeProgress: String? { upgrade.runtimeUpgradeProgress }
    public var runtimePasswordFallbackRequired: Bool { upgrade.runtimePasswordFallbackRequired }
    public var signedRuntimeUpdateSupported: Bool? { upgrade.signedRuntimeUpdateSupported }
    public var runtimeUpgradeStage: RuntimeUpgradeStage? { upgrade.runtimeUpgradeStage }
    public var administratorUsername: String {
        get { upgrade.administratorUsername }
        set { upgrade.administratorUsername = newValue }
    }
    public var administratorPassword: String {
        get { upgrade.administratorPassword }
        set { upgrade.administratorPassword = newValue }
    }
    public var revealsAdministratorPassword: Bool {
        get { upgrade.revealsAdministratorPassword }
        set { upgrade.revealsAdministratorPassword = newValue }
    }
    public var selectedWifiSSID: String? {
        get { network.selectedWifiSSID }
        set { network.selectedWifiSSID = newValue }
    }
    public var wifiPassword: String {
        get { network.wifiPassword }
        set { network.wifiPassword = newValue }
    }
    public var revealsWifiPassword: Bool {
        get { network.revealsWifiPassword }
        set { network.revealsWifiPassword = newValue }
    }
    public var travelSSID: String {
        get { network.travelSSID }
        set { network.travelSSID = newValue }
    }
    public var travelPassword: String {
        get { network.travelPassword }
        set { network.travelPassword = newValue }
    }
    public var revealsTravelPassword: Bool {
        get { network.revealsTravelPassword }
        set { network.revealsTravelPassword = newValue }
    }
    public var lanAddress: String {
        get { network.lanAddress }
        set { network.lanAddress = newValue }
    }
    public var lanPrefixLength: Int {
        get { network.lanPrefixLength }
        set { network.lanPrefixLength = newValue }
    }
    public var lanGateway: String {
        get { network.lanGateway }
        set { network.lanGateway = newValue }
    }
    public var lanDNSServers: String {
        get { network.lanDNSServers }
        set { network.lanDNSServers = newValue }
    }
    public var pendingNetworkChange: PendingSparkNetworkChange? { network.pendingNetworkChange }
    public var warningGiB: Int {
        get { policy.warningGiB }
        set { policy.warningGiB = newValue }
    }
    public var criticalGiB: Int {
        get { policy.criticalGiB }
        set { policy.criticalGiB = newValue }
    }
    public var emergencyGiB: Int {
        get { policy.emergencyGiB }
        set { policy.emergencyGiB = newValue }
    }
    public var timezone: String {
        get { policy.timezone }
        set { policy.timezone = newValue }
    }
    public var ntpEnabled: Bool {
        get { policy.ntpEnabled }
        set { policy.ntpEnabled = newValue }
    }
    public var functionalTelemetry: Bool {
        get { policy.functionalTelemetry }
        set { policy.functionalTelemetry = newValue }
    }
    public var technicalTelemetry: Bool {
        get { policy.technicalTelemetry }
        set { policy.technicalTelemetry = newValue }
    }
    public var cleanPartialDownloads: Bool {
        get { policy.cleanPartialDownloads }
        set { policy.cleanPartialDownloads = newValue }
    }
    public var cleanUnusedBlobs: Bool {
        get { policy.cleanUnusedBlobs }
        set { policy.cleanUnusedBlobs = newValue }
    }
    public var cleanStoppedContainers: Bool {
        get { policy.cleanStoppedContainers }
        set { policy.cleanStoppedContainers = newValue }
    }
    public var cleanUnusedImages: Bool {
        get { policy.cleanUnusedImages }
        set { policy.cleanUnusedImages = newValue }
    }

    public init(
        route: URL,
        runtime: any SparkSettingsManaging,
        runtimeInstaller: (any RuntimeBootstrapInstalling)? = nil,
        administratorUsername: String? = nil,
        userPresenceAuthorizer: any UserPresenceAuthorizing = SystemUserPresenceAuthorizer(),
        networkRouteDiscovery: (any SavedSparkRouteDiscovering)? = nil,
        networkPollAttempts: Int = 240,
        networkPollDelay: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        onKeptNetworkRoute: (@MainActor (URL, SparkIdentity) -> Void)? = nil,
        onAdministratorUsernameConfirmed: (@MainActor (String) -> Void)? = nil
    ) {
        self.runtime = runtime
        self.runtimeInstaller = runtimeInstaller
        let operations = SparkSettingsOperationCoordinator(
            route: route,
            runtime: runtime,
            authorizer: userPresenceAuthorizer
        )
        let network = SparkSettingsNetworkController(
            runtime: runtime,
            operations: operations,
            discovery: networkRouteDiscovery
                ?? BonjourSavedSparkRouteDiscovery(discovery: BootstrapDiscoveryService()),
            attempts: max(1, networkPollAttempts),
            delay: networkPollDelay,
            onKeptNetworkRoute: onKeptNetworkRoute
        )
        let upgrade = SparkSettingsRuntimeUpgrade(
            runtime: runtime,
            installer: runtimeInstaller,
            operations: operations,
            username: administratorUsername,
            onAdministratorUsernameConfirmed: onAdministratorUsernameConfirmed
        )
        let policy = SparkSettingsPolicyController(
            runtime: runtime,
            installer: runtimeInstaller,
            operations: operations,
            upgrade: upgrade
        )
        self.operations = operations
        self.network = network
        self.upgrade = upgrade
        self.policy = policy
        operations.pendingNetworkChange = { [weak network] in network?.pendingNetworkChange }
        operations.clearOptimisticState = { [weak self] in self?.clearOptimisticState() }
        operations.refresh = { [weak self] in await self?.refresh() }
        network.snapshot = { [weak self] in self?.settings }
        network.wifi = { [weak self] in self?.wifi }
        network.refresh = { [weak self] in await self?.refresh() }
        network.clearAllOptimisticState = { [weak self] in self?.clearOptimisticState() }
        upgrade.refresh = { [weak self] in await self?.refresh() }
        policy.snapshot = { [weak self] in self?.settings }
    }
    public var directEthernetEnabled: Bool { network.directEthernetEnabled }
    public var travelEnabled: Bool { network.travelEnabled }
    public var bluetoothPowered: Bool { policy.bluetoothPowered }
    public var canInstallBundledRuntime: Bool { upgrade.canInstallBundledRuntime }
    public var passwordFallbackExplanation: String { upgrade.passwordFallbackExplanation }
    public var canApplyManualLanIpv4: Bool { network.canApplyManualLanIpv4 }
    public var selectedPowerModeID: Int? {
        get { policy.selectedPowerModeID }
        set { policy.selectedPowerModeID = newValue }
    }

    public func loadIfNeeded() async {
        if hasLoaded {
            await refresh()
            return
        }
        hasLoaded = true
        if let cached = await DeviceLocalSparkSettingsCache.shared.load(route: route) {
            settings = cached.settings
            wifi = cached.wifi
            storage = cached.storage
            policy.syncDrafts(from: cached.settings)
        }
        await refresh()
    }

    public func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        updateStatusIsCurrent = false
        operations.errorMessage = nil
        if operations.activeMutation == nil { operations.successMessage = nil }
        await operations.reconcileSoftwareUpdate()
        var settingsFailureNeedsRuntimeCheck = false
        defer { isLoading = false }
        do {
            // Load appliance settings independently so a slow or failed Wi-Fi scan cannot blank usable controls.
            async let settings = runtime.sparkSettings(route: route)
            async let wifi: GeneratedAPI.WifiNetworksSnapshot? =
                try? runtime.wifiNetworks(route: route)
            async let storage: GeneratedAPI.StorageBreakdown? =
                try? runtime.storageBreakdown(route: route)
            let loadedSettings = try await settings
            let additions = await (wifi, storage)
            self.settings = loadedSettings
            updateStatusIsCurrent = true
            if let loadedWifi = additions.0 {
                self.wifi = loadedWifi
            }
            wifiScanUnavailable = additions.0 == nil
            if let loadedStorage = additions.1 {
                self.storage = loadedStorage
            }
            policy.syncDrafts(from: loadedSettings)
            clearOptimisticState()
            upgrade.runtimeUpgradeRequired = false
            await DeviceLocalSparkSettingsCache.shared.save(
                CachedSparkSettings(
                    settings: loadedSettings,
                    wifi: self.wifi,
                    storage: self.storage
                ),
                route: route
            )
        } catch let error as APIError where error.statusCode == 404 {
            upgrade.runtimeUpgradeRequired = runtimeInstaller != nil
            operations.errorMessage =
                upgrade.runtimeUpgradeRequired
                ? nil
                : String(
                    localized:
                        "This Spark needs a newer Spark Runtime before these settings are available."
                )
        } catch {
            if Task.isCancelled || SparkSettingsFailurePresentation.isCancellation(error) { return }
            settingsFailureNeedsRuntimeCheck =
                SparkSettingsFailurePresentation.mayIndicateMissingSettingsRoutes(error)
            operations.errorMessage = String(
                localized: "Spark settings are unavailable. Check the connection and try again."
            )
        }

        // Load catalogue and telemetry as optional additions without disabling settings supported by older runtimes.
        async let loadedCatalogue: ModelCatalogue? = try? runtime.models(route: route)
        async let loadedTelemetry: TelemetrySnapshot? = try? runtime.telemetry(route: route)
        async let loadedIdentity: SparkIdentity? = try? runtime.identity(route: route)
        async let loadedCapabilities: SparkCapabilities? = try? runtime.capabilities(route: route)
        async let bundledReleaseID: String? = try? runtimeInstaller?
            .availableRuntimeUpdateReleaseID()
        let supplemental = await (
            loadedCatalogue,
            loadedTelemetry,
            loadedIdentity,
            loadedCapabilities,
            bundledReleaseID
        )
        catalogue = supplemental.0
        if let telemetry = supplemental.1 {
            acceptTelemetry(telemetry)
        }
        runtimeVersionIsKnown = supplemental.2 != nil
        upgrade.bundledRuntimeReleaseID = supplemental.4
        upgrade.runtimeUpdateAvailable = SparkSettingsFailurePresentation.release(
            supplemental.4,
            differsFromInstalledVersion: supplemental.2?.runtimeVersion
        )
        if let capabilities = supplemental.3 {
            upgrade.signedRuntimeUpdateSupported = capabilities.isEnabled("signed_runtime_update")
        }
        if let capabilities = supplemental.3,
            !capabilities.isEnabled("signed_runtime_update"),
            SparkSettingsFailurePresentation.releaseCanReplace(
                supplemental.4,
                installedVersion: supplemental.2?.runtimeVersion
            )
        {
            upgrade.runtimeUpgradeRequired = true
        }
        // Treat status-less failures from a current signed-update-capable runtime as connection errors rather than requiring reinstallation.
        if settingsFailureNeedsRuntimeCheck,
            supplemental.2 != nil,
            supplemental.4 != nil,
            !SparkSettingsFailurePresentation.runtimeIsCurrent(
                capabilities: supplemental.3,
                bundledReleaseID: supplemental.4,
                installedVersion: supplemental.2?.runtimeVersion
            )
        {
            upgrade.runtimeUpgradeRequired = true
            operations.errorMessage = nil
        }
    }

    public func refreshLiveTelemetry() async {
        guard let telemetry = try? await runtime.telemetry(route: route) else { return }
        acceptTelemetry(telemetry)
    }

    public var sustainedHeatNeedsAttention: Bool {
        hotSampleCount >= 3
    }

    private func acceptTelemetry(_ telemetry: TelemetrySnapshot) {
        liveTelemetry = telemetry
        let celsius = telemetry.accelerator.temperatureCelsius ?? 0
        if SparkThermalReading.needsAttention(
            SparkThermalReading.state(reported: nil, celsius: celsius)
        ) {
            hotSampleCount += 1
        } else {
            hotSampleCount = 0
        }
    }
    private func clearOptimisticState() {
        network.optimisticDirectEthernet = nil
        network.optimisticTravelEnabled = nil
        policy.optimisticBluetoothPowered = nil
        policy.optimisticPowerModeID = nil
    }
    public func installRequiredRuntime() async { await self.upgrade.installRequiredRuntime() }
    public func repairRequiredRuntime() async { await self.upgrade.repairRequiredRuntime() }
    public func connectSelectedWifi() async { await self.network.connectSelectedWifi() }
    public func forgetWifi(_ ssid: String) async { await self.network.forgetWifi(ssid) }
    public func applyManualLanIpv4() async { await self.network.applyManualLanIpv4() }
    public func setDirectEthernet(_ enabled: Bool) async {
        await self.network.setDirectEthernet(enabled)
    }
    public func setTravelAccessPoint(_ enabled: Bool) async {
        await self.network.setTravelAccessPoint(enabled)
    }
    public func keepNetworkChanges() async { await self.network.keepNetworkChanges() }
    public func rollbackNetworkChanges() async { await self.network.rollbackNetworkChanges() }
    public func setBluetoothPowered(_ enabled: Bool) async {
        await self.policy.setBluetoothPowered(enabled)
    }
    public func bluetoothDevice(_ address: String, pair: Bool) async {
        await self.policy.bluetoothDevice(address, pair: pair)
    }
    public func scanBluetooth() async { await self.policy.scanBluetooth() }
    public func setPowerMode(_ modeID: Int) async { await self.policy.setPowerMode(modeID) }
    public func installAvailableUpdates() async {
        guard canInstallAvailableUpdates else { return }
        await policy.installAvailableUpdates()
    }
    public func checkForUpdates() async { await self.policy.checkForUpdates() }
    public func saveMemoryGuard() async { await self.policy.saveMemoryGuard() }
    public func saveIdlePolicy(
        modelID: String,
        profileID: String,
        policy: GeneratedAPI.ModelIdlePolicySettingsIdlePolicy,
        idleTimeoutSeconds: Int? = nil
    ) async {
        await self.policy.saveIdlePolicy(
            modelID: modelID,
            profileID: profileID,
            policy: policy,
            idleTimeoutSeconds: idleTimeoutSeconds
        )
    }
    public func saveTime() async { await self.policy.saveTime() }
    public func saveTelemetryConsent() async { await self.policy.saveTelemetryConsent() }
    public func cleanStorage() async { await self.policy.cleanStorage() }
}
