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
@Test func successfulWifiHandoffNeedsExplicitKeepAfterFreshStableHostnameVerification() async {
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        telemetryMode: .routeMissing,
        networkMode: .succeeds
    )
    // Use fresh Bonjour resolution and a new pinned connection even when the post-mutation URL text is unchanged.
    let stableRoute = URL(string: "https://spark-workshop.local:7443")!
    let settings = await settingsCompositionTestNetworkSettingsModel(
        runtime: runtime,
        candidateRoutes: [stableRoute]
    )

    await settings.connectSelectedWifi()

    #expect(settings.wifiPassword.isEmpty)
    #expect(await runtime.confirmationRoutes().isEmpty)
    #expect(await runtime.handoffIdentityRoutes() == [stableRoute])
    #expect(settings.pendingNetworkChange?.canKeep == true)

    await settings.keepNetworkChanges()

    #expect(await runtime.confirmationRoutes() == [stableRoute])
    #expect(settings.pendingNetworkChange == nil)
    #expect(settings.successMessage == "Network changes kept.")
}

@MainActor
@Test func manualLanIpv4VerifiesTheTypedAddressBeforeOfferingKeep() async {
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        telemetryMode: .routeMissing,
        networkMode: .succeeds
    )
    let settings = await settingsCompositionTestNetworkSettingsModel(
        runtime: runtime,
        candidateRoutes: []
    )
    settings.lanAddress = "192.168.100.63"
    settings.lanPrefixLength = 24
    settings.lanGateway = "192.168.100.1"
    settings.lanDNSServers = "1.1.1.1, 8.8.8.8"

    await settings.applyManualLanIpv4()

    let candidate = URL(string: "https://192.168.100.63:7443")!
    #expect(await runtime.handoffIdentityRoutes() == [candidate])
    #expect(settings.pendingNetworkChange?.verifiedRoute == candidate)
    #expect(settings.pendingNetworkChange?.canKeep == true)
}

@MainActor
@Test func keptNetworkRoutePropagatesAcrossCompositionAndSurvivesRelaunch() async throws {
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        telemetryMode: .routeMissing,
        networkMode: .succeeds
    )
    let store = MemoryLibraryStore()
    let newRoute = URL(string: "https://spark-new-route.local:7443")!
    let model = try settingsCompositionTestComposedModel(
        runtime: runtime,
        store: store,
        savedRouteDiscovery: SettingsCompositionTestStaticSettingsRouteDiscovery(routes: [newRoute]
        ),
        settingsUserPresenceAuthorizer: SettingsCompositionTestSettingsPresenceAuthorizer()
    )
    try await settingsCompositionTestOpenComposedDashboard(model)

    let entryID = try #require(model.library.entries.first?.id)
    let settings = try #require(model.settingsModel)
    await settings.refresh()
    settings.selectedWifiSSID = "Workshop WiFi"
    settings.wifiPassword = "correct horse battery staple"
    await settings.connectSelectedWifi()
    await settings.keepNetworkChanges()

    #expect(model.library.entries.count == 1)
    #expect(model.library.entry(id: entryID)?.preferredRoute?.baseURL == newRoute)
    #expect(model.dashboardModel?.route == newRoute)
    #expect(model.settingsModel?.route == newRoute)

    let relaunched = RetailOnboardingModel(
        library: SparkLibrary(store: store),
        identityResolver: SettingsCompositionTestSettingsTelemetryIdentityResolver(),
        savedRouteDiscovery: SettingsCompositionTestStaticEmptySavedRouteDiscovery(),
        runtime: runtime
    )
    let reopened = try #require(relaunched.openLibraryEntry(entryID))
    await reopened.value

    #expect(relaunched.library.entries.count == 1)
    #expect(relaunched.dashboardModel?.route == newRoute)
}

@MainActor
@Test func wrongWifiPasswordNeverOffersKeepOrSendsNetworkResolution() async {
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        telemetryMode: .routeMissing,
        networkMode: .wrongPassword
    )
    let settings = await settingsCompositionTestNetworkSettingsModel(
        runtime: runtime,
        candidateRoutes: []
    )

    await settings.connectSelectedWifi()

    #expect(settings.pendingNetworkChange == nil)
    #expect(settings.errorMessage == "That Wi-Fi password is wrong. Check it and try again.")
    #expect(await runtime.confirmationRoutes().isEmpty)
    #expect(await runtime.rollbackRoutes().isEmpty)
}

@MainActor
@Test func candidateRouteIdentityMismatchFailsClosedWithoutConfirmation() async {
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        telemetryMode: .routeMissing,
        networkMode: .candidateIdentityMismatch
    )
    let candidate = URL(string: "https://spark-candidate.local:7443")!
    let settings = await settingsCompositionTestNetworkSettingsModel(
        runtime: runtime,
        candidateRoutes: [candidate]
    )

    await settings.connectSelectedWifi()

    #expect(settings.pendingNetworkChange?.canKeep == false)
    #expect(settings.errorMessage?.contains("different Spark") == true)
    #expect(await runtime.confirmationRoutes().isEmpty)
    #expect(await runtime.rollbackRoutes().isEmpty)
}

@MainActor
@Test func ownerCanRequestImmediateRollbackOverTheVerifiedCandidateRoute() async {
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        telemetryMode: .routeMissing,
        networkMode: .succeeds
    )
    let candidate = URL(string: "https://spark-new-route.local:7443")!
    let settings = await settingsCompositionTestNetworkSettingsModel(
        runtime: runtime,
        candidateRoutes: [candidate]
    )
    await settings.connectSelectedWifi()

    await settings.rollbackNetworkChanges()

    #expect(await runtime.rollbackRoutes() == [candidate])
    #expect(await runtime.confirmationRoutes().isEmpty)
    #expect(settings.pendingNetworkChange == nil)
    #expect(settings.successMessage == "Previous network restored.")
}

@MainActor
@Test func candidateRouteTimeoutLeavesTheServerFailsafePending() async {
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        telemetryMode: .routeMissing,
        networkMode: .succeeds
    )
    let settings = await settingsCompositionTestNetworkSettingsModel(
        runtime: runtime,
        candidateRoutes: []
    )

    await settings.connectSelectedWifi()

    #expect(settings.pendingNetworkChange?.canKeep == false)
    #expect(settings.errorMessage?.contains("restore its previous network automatically") == true)
    #expect(await runtime.confirmationRoutes().isEmpty)
    #expect(await runtime.rollbackRoutes().isEmpty)
}

@MainActor
@Test func cancelledHandoffLeavesTheServerFailsafePending() async {
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        telemetryMode: .routeMissing,
        networkMode: .succeeds
    )
    let settings = await settingsCompositionTestNetworkSettingsModel(
        runtime: runtime,
        candidateRoutes: [],
        attempts: 2,
        delay: { _ in throw CancellationError() }
    )

    await settings.connectSelectedWifi()

    #expect(settings.pendingNetworkChange?.canKeep == false)
    #expect(settings.errorMessage?.contains("Setup stopped") == true)
    #expect(await runtime.confirmationRoutes().isEmpty)
    #expect(await runtime.rollbackRoutes().isEmpty)
}

@MainActor
@Test func cancellationFromTheHandoffRequestStopsPollingWithoutAFalseTrustFailure() async {
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        telemetryMode: .routeMissing,
        networkMode: .handoffCancellation
    )
    let candidate = URL(string: "https://spark-candidate.local:7443")!
    let settings = await settingsCompositionTestNetworkSettingsModel(
        runtime: runtime,
        candidateRoutes: [candidate],
        attempts: 2
    )

    await settings.connectSelectedWifi()

    #expect(settings.pendingNetworkChange?.canKeep == false)
    #expect(settings.errorMessage?.contains("Setup stopped") == true)
    #expect(await runtime.handoffIdentityRoutes() == [candidate])
    #expect(await runtime.confirmationRoutes().isEmpty)
}

@MainActor
@Test func networkHandoffReusesOneFreshIdentityCheckerAcrossPollingAttempts() async {
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        telemetryMode: .routeMissing,
        networkMode: .handoffUnavailable
    )
    let candidate = URL(string: "https://spark-candidate.local:7443")!
    let settings = await settingsCompositionTestNetworkSettingsModel(
        runtime: runtime,
        candidateRoutes: [candidate],
        attempts: 3
    )

    await settings.connectSelectedWifi()

    #expect(await runtime.handoffCheckerCreations() == 1)
    #expect(await runtime.handoffIdentityRoutes() == [candidate, candidate, candidate])
    #expect(settings.pendingNetworkChange?.canKeep == false)
}
