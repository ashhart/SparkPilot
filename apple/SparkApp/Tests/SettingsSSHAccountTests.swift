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

// MARK: - The Spark account a runtime install signs in with

/// Never prefill an SSH account that this device has not learned from its owner.
@MainActor
@Test func runtimeInstallNeverOffersAGuessedSparkAccount() async throws {
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        telemetryMode: .routeMissing
    )
    let model = try settingsCompositionTestComposedModel(runtime: runtime)
    try await settingsCompositionTestOpenComposedDashboard(model)

    let settings = try #require(model.settingsModel)
    #expect(
        settings.administratorUsername.isEmpty,
        "the install form proposed \"\(settings.administratorUsername)\" for a Spark this device never set up"
    )
}

/// Persist the successful setup account so Settings can reuse it after relaunch.
@MainActor
@Test func theAccountFromSetupReachesSettingsAndSurvivesRelaunch() async throws {
    let store = MemoryLibraryStore()
    let runtime = SettingsCompositionTestPartiallyAvailableCompositionRuntime(
        telemetryMode: .routeMissing
    )
    let model = try settingsCompositionTestComposedModel(runtime: runtime, store: store)
    model.administratorUsername = "workshop-owner"
    try await settingsCompositionTestOpenComposedDashboard(model)

    #expect(model.settingsModel?.administratorUsername == "workshop-owner")
    #expect(model.library.entries.first?.administratorUsername == "workshop-owner")

    // Reload the persisted library with no in-memory setup state to simulate app relaunch.
    let entryID = try #require(model.library.entries.first?.id)
    let reloaded = SparkLibrary(store: store)
    reloaded.load()
    let relaunched = RetailOnboardingModel(
        library: reloaded,
        identityResolver: SettingsCompositionTestSettingsTelemetryIdentityResolver(),
        savedRouteDiscovery: SettingsCompositionTestStaticEmptySavedRouteDiscovery(),
        runtime: runtime
    )
    #expect(relaunched.administratorUsername == nil)
    let reopened = try #require(relaunched.openLibraryEntry(entryID))
    await reopened.value

    #expect(
        relaunched.settingsModel?.administratorUsername == "workshop-owner",
        "the account made during setup was forgotten across a relaunch"
    )
}

/// Discovery must preserve the locally remembered account because network advertisements cannot supply it.
@MainActor
@Test func rediscoveringASparkKeepsTheRememberedAccount() async throws {
    let store = MemoryLibraryStore()
    let library = SparkLibrary(store: store)
    let route = CachedRoute(
        baseURL: URL(string: "https://spark-workshop.local:7443")!,
        kind: .localWiFi
    )
    let target = AuthenticatedTarget(
        nodeID: settingsCompositionTestSettingsTelemetryNodeID,
        clusterID: nil,
        name: "Workshop Spark",
        role: .standalone,
        authorityFingerprint: "authority-a",
        displayName: "Workshop Spark",
        routes: [route]
    )
    library.reconcile(target)
    let entryID = try #require(library.entries.first?.id)
    library.recordAdministratorUsername("workshop-owner", for: entryID)

    library.reconcile(target)

    #expect(
        library.entries.first?.administratorUsername == "workshop-owner",
        "seeing the Spark again erased the account it was set up with"
    )
}

/// Remember only nonblank account names established by a successful login.
@MainActor
@Test func onlyAUsableAccountNameIsRemembered() async throws {
    let library = SparkLibrary(store: MemoryLibraryStore())
    library.reconcile(
        AuthenticatedTarget(
            nodeID: settingsCompositionTestSettingsTelemetryNodeID,
            clusterID: nil,
            name: "Workshop Spark",
            role: .standalone,
            authorityFingerprint: "authority-a",
            displayName: "Workshop Spark",
            routes: [
                CachedRoute(
                    baseURL: URL(string: "https://spark-workshop.local:7443")!,
                    kind: .localWiFi
                )
            ]
        )
    )
    let entryID = try #require(library.entries.first?.id)

    #expect(library.recordAdministratorUsername("   ", for: entryID) == false)
    #expect(library.entries.first?.administratorUsername == nil)

    #expect(library.recordAdministratorUsername("  workshop-owner  ", for: entryID))
    #expect(library.entries.first?.administratorUsername == "workshop-owner")
    #expect(
        library.recordAdministratorUsername("workshop-owner", for: entryID) == false,
        "an unchanged name should not cost a write"
    )
}

// MARK: - Network status interface ordering

/// Present the owner's network interfaces before container bridges and loopback interfaces.
@Test func networkStatusPutsTheOwnersInterfacesFirst() {
    func interfaceStatus(
        name: String,
        type: String,
        state: String = "connected"
    ) -> NetworkInterfaceStatus {
        NetworkInterfaceStatus(
            name: name,
            type: type,
            state: state,
            connectionName: nil,
            macAddress: nil,
            mtu: nil,
            linkSpeedMbps: nil,
            addresses: [],
            gateway: nil,
            dnsServers: [],
            wifiSSID: nil,
            wifiSignalPercent: nil,
            internet: InternetReachability(
                reachable: false,
                gatewayReachable: nil,
                dnsReachable: nil,
                checkedAt: Date(timeIntervalSince1970: 0)
            )
        )
    }

    let split = SparkNetworkInterfaces.split([
        interfaceStatus(name: "br-0e9bb2ae03da", type: "bridge"),
        interfaceStatus(name: "docker0", type: "bridge"),
        interfaceStatus(name: "lo", type: "loopback"),
        interfaceStatus(name: "wlP9s9", type: "wifi"),
        interfaceStatus(name: "enp1s0", type: "ethernet", state: "disconnected"),
    ])

    #expect(split.ownersOwn.map(\.name) == ["wlP9s9", "enp1s0"])
    #expect(split.plumbing.map(\.name) == ["br-0e9bb2ae03da", "docker0", "lo"])
}
