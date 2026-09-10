import Foundation
@_spi(SparkTestSupport) import SparkAPI
import SparkBootstrap
import SparkCore
import SparkDesignSystem
import SparkDiscovery
import SparkLibrary
import SparkSecurity
@_spi(SparkTestSupport) import SparkTransport
import Testing
@testable import SparkAppComposition

@MainActor
@Test func composedNetworkSettingsStayUsableWhenOnlyLiveTelemetryIsMissing() async throws {
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        telemetryMode: .routeMissing
    )
    let model = try settingsCompositionTestComposedModel(runtime: runtime)
    try await settingsCompositionTestOpenComposedDashboard(model)

    let settings = try #require(model.settingsModel)
    await settings.refresh()

    #expect(settings.settings != nil)
    #expect(settings.wifi?.networks.first?.ssid == "Workshop WiFi")
    #expect(settings.liveTelemetry == nil)
    #expect(!settings.runtimeUpgradeRequired)
}

@MainActor
@Test func composedDashboardStillLoadsLiveTelemetryWhenItsSummaryIsUnavailable() async throws {
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        summaryAvailable: false,
        telemetryMode: .available
    )
    let model = try settingsCompositionTestComposedModel(runtime: runtime)
    try await settingsCompositionTestOpenComposedDashboard(model)

    let dashboard = try #require(model.dashboardModel)
    await dashboard.refresh()

    #expect(dashboard.telemetryIsLive)
    #expect(dashboard.gpuTelemetry == "64%")
    #expect(await runtime.telemetryReads() == 1)
}

@MainActor
@Test func composedOldRuntimeOffersTheBundledUpgradeInsteadOfGenericFailure() async throws {
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        settingsRoutesAvailable: false,
        telemetryMode: .routeMissing
    )
    let model = try settingsCompositionTestComposedModel(runtime: runtime)
    try await settingsCompositionTestOpenComposedDashboard(model)

    let settings = try #require(model.settingsModel)
    await settings.refresh()

    #expect(settings.settings == nil)
    #expect(settings.runtimeUpgradeRequired)
    #expect(settings.canInstallBundledRuntime)
    #expect(settings.errorMessage == nil)
}

@MainActor
@Test func aSlowWifiScanDoesNotBlankTheOtherSettings() async throws {
    // Load supplementary network scans independently so slow scans cannot hide available appliance settings.
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        telemetryMode: .available,
        wifiScanFails: true
    )
    let model = try settingsCompositionTestComposedModel(
        runtime: runtime,
        runtimeInstaller: SettingsCompositionTestUpdateIdentityInstaller(releaseID: "dev-0.1.0")
    )
    try await settingsCompositionTestOpenComposedDashboard(model)

    let settings = try #require(model.settingsModel)
    await settings.refresh()

    #expect(settings.settings != nil)
    #expect(settings.storage != nil)
    #expect(settings.wifi == nil)
    #expect(settings.wifiScanUnavailable)
    #expect(settings.errorMessage == nil)
    #expect(!settings.runtimeUpgradeRequired)
}

@MainActor
@Test func composedSettingsExposeNetworkAndSafePowerProfilesWithHeatGuidance() async throws {
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        telemetryMode: .available,
        telemetryTemperature: 86
    )
    let model = try settingsCompositionTestComposedModel(runtime: runtime)
    try await settingsCompositionTestOpenComposedDashboard(model)

    let settings = try #require(model.settingsModel)
    _ = try #require(model.networkStatusModel)
    await settings.refresh()
    await settings.refresh()
    await settings.refresh()

    #expect(settings.settings?.powerProfile.modes.map(\.modeId) == [0, 1])
    #expect(settings.settings?.powerProfile.modes.map(\.name) == ["Balanced", "MODE_QUIET"])
    // 86 °C is above the guard's shipped hot threshold; 80 °C is only warm.
    #expect(settings.liveTelemetry?.accelerator.temperatureCelsius == 86)
    #expect(settings.sustainedHeatNeedsAttention)
}

@Test func sparkAPIClientTelemetryDispatchesThroughTheDashboardRequirement() async throws {
    let client = SparkAPIClient(transport: SettingsCompositionTestTelemetryFixtureTransport())
    let runtime: any SparkRuntimeReading = client

    let telemetry = try await runtime.telemetry(
        route: URL(string: "https://spark-workshop.local:7443")!
    )

    #expect(telemetry.nodeID == settingsCompositionTestSettingsTelemetryNodeID)
    #expect(telemetry.accelerator.utilisation == 0.64)
}
