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

struct SettingsCompositionTestSettingsNetworkHandoffChecker: NetworkHandoffIdentityChecking {
    let runtime: SettingsCompositionTestPartiallyAvailableCompositionRuntime

    func identity(route: URL) async throws -> SparkIdentity {
        try await runtime.networkHandoffIdentity(route: route)
    }
}

@MainActor
func settingsCompositionTestComposedModel(
    runtime: SettingsCompositionTestPartiallyAvailableCompositionRuntime,
    store: MemoryLibraryStore = MemoryLibraryStore(),
    savedRouteDiscovery: any SavedSparkRouteDiscovering =
        SettingsCompositionTestStaticEmptySavedRouteDiscovery(),
    runtimeInstaller: any RuntimeBootstrapInstalling = PendingRuntimeBootstrapInstaller(),
    settingsUserPresenceAuthorizer: any UserPresenceAuthorizing =
        SystemUserPresenceAuthorizer()
) throws -> RetailOnboardingModel {
    let library = SparkLibrary(store: store)
    let route = CachedRoute(
        baseURL: URL(string: "https://spark-workshop.local:7443")!,
        kind: .localWiFi
    )
    library.reconcile(
        AuthenticatedTarget(
            nodeID: settingsCompositionTestSettingsTelemetryNodeID,
            clusterID: nil,
            name: "Workshop Spark",
            role: .standalone,
            authorityFingerprint: "authority-a",
            displayName: "Workshop Spark",
            routes: [route]
        )
    )
    return RetailOnboardingModel(
        runtimeInstaller: runtimeInstaller,
        library: library,
        identityResolver: SettingsCompositionTestSettingsTelemetryIdentityResolver(),
        savedRouteDiscovery: savedRouteDiscovery,
        runtime: runtime,
        settingsUserPresenceAuthorizer: settingsUserPresenceAuthorizer
    )
}

struct SettingsCompositionTestStaticEmptySavedRouteDiscovery: SavedSparkRouteDiscovering {
    func candidateRoutes() async -> [URL] { [] }
}

struct SettingsCompositionTestStaticSettingsRouteDiscovery: SavedSparkRouteDiscovering {
    let routes: [URL]

    func candidateRoutes() async -> [URL] { routes }
}

struct SettingsCompositionTestUpdateIdentityInstaller: RuntimeBootstrapInstalling {
    let releaseID: String

    func availableRuntimeUpdateReleaseID() async throws -> String { releaseID }

    func prepareRuntimeUpdate() async throws -> RuntimeUpdateBundle {
        RuntimeUpdateBundle(
            releaseID: releaseID,
            manifest: Data("manifest".utf8),
            package: Data("package".utf8),
            detachedSignature: Data("signature".utf8)
        )
    }

    func install(
        on target: BootstrapSpark,
        administratorPassword: String
    ) async throws -> RuntimeBootstrapResult {
        throw RuntimeBootstrapError.notConfigured
    }
}

struct SettingsCompositionTestFailingRuntimeUpgradeInstaller: RuntimeBootstrapInstalling {
    let failure: BootstrapSSHError

    func install(
        on target: BootstrapSpark,
        administratorPassword: String
    ) async throws -> RuntimeBootstrapResult {
        throw failure
    }

    func upgrade(
        on target: BootstrapSpark,
        administratorUsername: String?,
        administratorPassword: String,
        progress: @escaping @Sendable (BootstrapCommand) -> Void
    ) async throws {
        throw failure
    }
}

struct SettingsCompositionTestMissingNetworkStatusRuntime: SparkNetworkStatusReading {
    func networkInterfaces(route: URL) async throws -> NetworkInterfacesSnapshot {
        throw APIError(
            .local(message: "The network interface route is not installed."),
            statusCode: 404,
            code: "NOT_FOUND"
        )
    }
}

@MainActor
func settingsCompositionTestNetworkSettingsModel(
    runtime: SettingsCompositionTestPartiallyAvailableCompositionRuntime,
    candidateRoutes: [URL],
    attempts: Int = 1,
    delay: @escaping @Sendable (Duration) async throws -> Void = { _ in }
) async -> SparkSettingsModel {
    let model = SparkSettingsModel(
        route: URL(string: "https://spark-workshop.local:7443")!,
        runtime: runtime,
        userPresenceAuthorizer: SettingsCompositionTestSettingsPresenceAuthorizer(),
        networkRouteDiscovery: SettingsCompositionTestStaticSettingsRouteDiscovery(
            routes: candidateRoutes
        ),
        networkPollAttempts: attempts,
        networkPollDelay: delay
    )
    await model.refresh()
    model.selectedWifiSSID = "Workshop WiFi"
    model.wifiPassword = "correct horse battery staple"
    return model
}

@MainActor
func settingsCompositionTestOpenComposedDashboard(_ model: RetailOnboardingModel) async throws {
    let entryID = try #require(model.library.entries.first?.id)
    let task = try #require(model.openLibraryEntry(entryID))
    await task.value
    _ = try #require(model.dashboardModel)
}
