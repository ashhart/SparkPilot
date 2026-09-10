import Foundation
import Network
import SparkAPI
import SparkCore
import SparkDiscovery
import SparkLibrary
import Testing
@testable import SparkAppComposition

@MainActor
@Test func aSavedTailscaleIPConnectsAfterRelaunchWithoutLocalOrMagicDNS() async throws {
    let store = MemoryLibraryStore()
    let library = SparkLibrary(store: store)
    let entry = library.reconcile(compositionLibraryTestSeedTarget(node: 1, host: "spark.local"))
        .entry
    library.markUnreachable(entryID: entry.id)
    let identity = try compositionLibraryTestAuthenticated(
        compositionLibraryTestIdentityJSON(node: 1)
    )
    let offline = CompositionLibraryTestRouteSensitiveIdentityResolver(
        workingHost: "unavailable.invalid",
        identity: identity
    )
    let registration = LibraryRemoteAccessRouteRegistration(
        library: library,
        identityResolver: offline,
        targetID: entry.id
    )
    let status = RemoteStatus(
        enabled: true,
        mode: .privateOverlay,
        health: .healthy,
        hostname: "spark.example.ts.net",
        privateOverlayAddress: "100.96.4.2"
    )
    let remote = RemoteAccessModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: AppShellTestFakeRemote(status: status),
        routeRegistration: registration
    )
    await remote.refresh()
    #expect(!remote.isPrivateRouteVerified)
    #expect(library.entry(id: entry.id)?.members.first?.reachable == false)
    let remembered = try #require(
        library.entry(id: entry.id)?.members.first?.routes.filter { $0.kind == .privateOverlay }
    )
    #expect(
        Set(remembered.compactMap { $0.baseURL.host }) == ["spark.example.ts.net", "100.96.4.2"]
    )
    #expect(remembered.allSatisfy { $0.lastSuccess == nil })

    let restored = SparkLibrary(store: store)
    restored.load()
    let online = CompositionLibraryTestRouteSensitiveIdentityResolver(
        workingHost: "100.96.4.2",
        identity: identity
    )
    let app = RetailOnboardingModel(
        library: restored,
        identityResolver: online,
        savedRouteDiscovery: CompositionLibraryTestStaticSavedSparkRouteDiscovery(routes: [])
    )
    #expect(await app.updateFromProbe(entryID: entry.id))
    #expect(restored.entry(id: entry.id)?.connectionState == .connectedRemote)
    #expect(restored.entry(id: entry.id)?.routeInUse?.baseURL.host == "100.96.4.2")
}

@MainActor
@Test func privateOverlayRegistrationPinsThenCachesAndDisableForgetsOnlyThatRoute() async throws {
    let library = SparkLibrary(store: try SwiftDataLibraryStore())
    library.load()
    let added = library.reconcile(
        compositionLibraryTestSeedTarget(node: 1, host: "spark-a1b2.local")
    )
    let resolver = CompositionLibraryTestRouteSensitiveIdentityResolver(
        workingHost: "100.96.4.2",
        identity: try compositionLibraryTestAuthenticated(
            compositionLibraryTestIdentityJSON(node: 1, name: "My Spark")
        )
    )
    let registration = LibraryRemoteAccessRouteRegistration(
        library: library,
        identityResolver: resolver,
        targetID: added.entry.id
    )
    let localRoute = try #require(added.entry.preferredRoute?.baseURL)

    try await registration.registerPrivateOverlay(
        hostname: "100.96.4.2",
        basedOn: localRoute
    )

    #expect(await resolver.hosts() == ["100.96.4.2"])
    #expect(
        library.entry(id: added.entry.id)?.members.first?.routes.contains {
            $0.kind == .privateOverlay && $0.baseURL.host == "100.96.4.2"
        } == true
    )

    registration.unregisterPrivateOverlay(currentRoute: localRoute)

    let member = try #require(library.entry(id: added.entry.id)?.members.first)
    #expect(member.routes.map(\.kind) == [.localWiFi])
    #expect(member.reachable, "the local route carried the successful disable request")
}

@MainActor
@Test func nonTailscalePrivateAddressIsNeverCachedAsAnOverlay() async throws {
    let library = SparkLibrary(store: try SwiftDataLibraryStore())
    library.load()
    let added = library.reconcile(
        compositionLibraryTestSeedTarget(node: 1, host: "spark-a1b2.local")
    )
    let resolver = CompositionLibraryTestRouteSensitiveIdentityResolver(
        workingHost: "192.168.1.20",
        identity: try compositionLibraryTestAuthenticated(
            compositionLibraryTestIdentityJSON(node: 1, name: "My Spark")
        )
    )
    let registration = LibraryRemoteAccessRouteRegistration(
        library: library,
        identityResolver: resolver,
        targetID: added.entry.id
    )

    await #expect(throws: PrivateOverlayRouteRegistrationError.self) {
        try await registration.registerPrivateOverlay(
            hostname: "192.168.1.20",
            basedOn: URL(string: "https://spark-a1b2.local:7443")!
        )
    }

    #expect(await resolver.hosts().isEmpty)
    #expect(library.entry(id: added.entry.id)?.members.first?.routes.count == 1)
}

// MARK: - Setup completion

@MainActor
@Test func authenticatedSetupAddsACardWithoutRemovingExistingOnes() async throws {
    let model = try compositionLibraryTestMakeModel(
        resolver: CompositionLibraryTestFakeIdentityResolver(
            .success(
                compositionLibraryTestAuthenticated(
                    compositionLibraryTestIdentityJSON(node: 2, name: "Second Spark")
                )
            )
        )
    )
    // An entry from an earlier pairing already exists in the library.
    model.library.reconcile(compositionLibraryTestSeedTarget(node: 1, host: "spark-a1b2.local"))
    let existing = model.library.entries[0]

    model.machineName = "spark-c3d4"
    model.startAddingSpark()
    #expect(model.isAddingSpark)

    let route = URL(string: "https://spark-c3d4.local:7443")!
    model.recordCompletedSetup(
        route: route,
        authenticated: try compositionLibraryTestAuthenticated(
            compositionLibraryTestIdentityJSON(node: 2, name: "Second Spark")
        )
    )

    #expect(!model.isAddingSpark, "adding a Spark returns to the library")
    #expect(model.dashboardModel != nil, "the new card opens")
    #expect(model.library.entries.count == 2)
    #expect(
        model.library.entry(containing: compositionLibraryTestCompositionNodeID(1))?.id
            == existing.id,
        "the existing entry is retained, never reset"
    )
    #expect(model.library.entry(containing: compositionLibraryTestCompositionNodeID(2)) != nil)
}

@MainActor
@Test func setupStaysProvisionalWithoutAnAuthenticatedIdentity() async throws {
    let store = try SwiftDataLibraryStore()
    let model = RetailOnboardingModel(
        library: SparkLibrary(store: store),
        identityResolver: CompositionLibraryTestFakeIdentityResolver(.failure(.unbound))
    )
    model.machineName = "spark-a1b2"

    await model.completeSetup()

    #expect(model.library.entries.isEmpty, "no card is minted from unverified setup metadata")
    #expect(model.dashboardModel == nil, "no dashboard is opened before authentication")
    #expect(model.state.issue == .identityUnavailable, "the flow stays actionable")
    #expect(!model.isAddingSpark)
}

@MainActor
@Test func authenticatedSetupOpensTheExistingCardOfAKnownSpark() async throws {
    let model = try compositionLibraryTestMakeModel(
        resolver: CompositionLibraryTestFakeIdentityResolver(
            .success(
                compositionLibraryTestAuthenticated(compositionLibraryTestIdentityJSON(node: 1))
            )
        )
    )
    model.library.reconcile(compositionLibraryTestSeedTarget(node: 1, host: "spark-a1b2.local"))
    model.machineName = "spark-a1b2"

    let route = URL(string: "https://spark-a1b2.local:7443")!
    model.recordCompletedSetup(
        route: route,
        authenticated: try compositionLibraryTestAuthenticated(
            compositionLibraryTestIdentityJSON(node: 1)
        )
    )

    #expect(model.library.entries.count == 1, "re-adding a known Spark opens its existing card")
    #expect(model.library.entry(containing: compositionLibraryTestCompositionNodeID(1)) != nil)
}

// MARK: - Opening a saved card

@MainActor
@Test func openingAKnownSparkReusesItsCardWithoutDuplicating() async throws {
    let model = try compositionLibraryTestMakeModel(
        resolver: CompositionLibraryTestFakeIdentityResolver(
            .success(
                compositionLibraryTestAuthenticated(compositionLibraryTestIdentityJSON(node: 1))
            )
        )
    )
    model.library.reconcile(compositionLibraryTestSeedTarget(node: 1, host: "spark-a1b2.local"))
    let entryID = model.library.entries[0].id

    let first = model.openLibraryEntry(entryID)
    await first?.value
    let second = model.openLibraryEntry(entryID)
    await second?.value

    #expect(model.library.entries.count == 1)
    #expect(model.dashboardModel != nil)
    #expect(model.dashboardModel?.route.host == "spark-a1b2.local")
}

@MainActor
@Test func authenticatedProbeMarksTheCardReachable() async throws {
    let model = try compositionLibraryTestMakeModel(
        resolver: CompositionLibraryTestFakeIdentityResolver(
            .success(
                compositionLibraryTestAuthenticated(compositionLibraryTestIdentityJSON(node: 1))
            )
        )
    )
    model.library.reconcile(compositionLibraryTestSeedTarget(node: 1, host: "spark-a1b2.local"))
    model.library.markUnreachable(entryID: model.library.entries[0].id)
    let entryID = model.library.entries[0].id

    let task = model.openLibraryEntry(entryID)
    await task?.value

    let card = model.library.entry(id: entryID)
    #expect(
        card?.connectionState == .connectedWiFi,
        "reachability upgrades only after an authenticated probe"
    )
    #expect(card?.members[0].reachable == true)
}

@MainActor
@Test func appActivationReauthenticatesReachableSavedSparks() async throws {
    let store = try SwiftDataLibraryStore()
    let firstLaunch = RetailOnboardingModel(
        library: SparkLibrary(store: store),
        identityResolver: CompositionLibraryTestFakeIdentityResolver(.failure(.unbound))
    )
    firstLaunch.library.reconcile(
        compositionLibraryTestSeedTarget(node: 1, host: "spark-a1b2.local")
    )

    let relaunched = RetailOnboardingModel(
        library: SparkLibrary(store: store),
        identityResolver: CompositionLibraryTestFakeIdentityResolver(
            .success(
                try compositionLibraryTestAuthenticated(compositionLibraryTestIdentityJSON(node: 1))
            )
        )
    )
    let entryID = try #require(relaunched.library.entries.first?.id)
    #expect(relaunched.library.entry(id: entryID)?.connectionState == .offlineCached)

    await relaunched.refreshSavedSparks()

    #expect(relaunched.library.entry(id: entryID)?.connectionState == .connectedWiFi)
    #expect(relaunched.library.entry(id: entryID)?.members.first?.reachable == true)
}

@MainActor
@Test func appActivationRecoversAStaleHostnameThroughAuthenticatedLocalDiscovery() async throws {
    let stale = "Spark-8cd8b1ab.local"
    let working = "spark-example.local"
    let identity = try compositionLibraryTestAuthenticated(
        compositionLibraryTestIdentityJSON(node: 1)
    )
    let resolver = CompositionLibraryTestRouteSensitiveIdentityResolver(
        workingHost: working,
        identity: identity
    )
    let model = RetailOnboardingModel(
        library: SparkLibrary(store: try SwiftDataLibraryStore()),
        identityResolver: resolver,
        savedRouteDiscovery: CompositionLibraryTestStaticSavedSparkRouteDiscovery(
            routes: [URL(string: "https://\(working):7443")!]
        )
    )
    model.library.reconcile(compositionLibraryTestSeedTarget(node: 1, host: stale))
    let entryID = try #require(model.library.entries.first?.id)
    model.library.markUnreachable(entryID: entryID)

    await model.refreshSavedSparks()

    let recovered = try #require(model.library.entry(id: entryID))
    #expect(recovered.connectionState == .connectedWiFi)
    #expect(recovered.preferredRoute?.baseURL.host == working)
    #expect(await resolver.hosts() == [stale, working])
}

@Test func recoveredRouteChangesOnlyTheAddressAndPreservesTheTrustHintAndSlot() throws {
    let saved = CachedRoute(
        slotID: RouteSlot(kind: .localWiFi, scope: "en0"),
        baseURL: URL(string: "https://stale.local:7443")!,
        kind: .localWiFi,
        interfaceName: "en0",
        peerFingerprint: String(repeating: "a", count: 64),
        lastSuccess: Date(timeIntervalSince1970: 10),
        isMetered: true
    )

    let candidate = SavedSparkRouteRecovery.candidate(
        baseURL: URL(string: "https://working.local:7443")!,
        savedRoute: saved
    )

    #expect(candidate.baseURL.host == "working.local")
    #expect(candidate.slotID == saved.slotID)
    #expect(candidate.kind == saved.kind)
    #expect(candidate.interfaceName == saved.interfaceName)
    #expect(candidate.peerFingerprint == saved.peerFingerprint)
    #expect(candidate.isMetered == saved.isMetered)
    #expect(candidate.lastSuccess == nil)
}

@Test func localRouteDoesNotDuplicateAnExistingLocalSuffix() throws {
    let route = try #require(SparkAppRoute.localRoute(host: "spark-example.local"))

    #expect(route.host == "spark-example.local")
}

@MainActor
@Test func foregroundRefreshKeepsALastKnownOnlineCardOnlineWhileChecking() async throws {
    let model = RetailOnboardingModel(
        library: SparkLibrary(store: try SwiftDataLibraryStore()),
        identityResolver: CompositionLibraryTestDelayedIdentityResolver(
            try compositionLibraryTestAuthenticated(compositionLibraryTestIdentityJSON(node: 1))
        )
    )
    model.library.reconcile(compositionLibraryTestSeedTarget(node: 1, host: "spark-a1b2.local"))
    let entryID = try #require(model.library.entries.first?.id)
    #expect(model.library.entry(id: entryID)?.connectionState == .connectedWiFi)

    let refresh = Task { await model.refreshSavedSparks() }
    await Task.yield()

    #expect(
        model.library.entry(id: entryID)?.connectionState == .connectedWiFi,
        "foregrounding must not replace a last-known online state with Connecting"
    )

    await refresh.value
    #expect(model.library.entry(id: entryID)?.connectionState == .connectedWiFi)
}

@MainActor
@Test func appActivationRefreshesAnOpenDashboardInsteadOfLeavingItConnecting() async throws {
    let runtime = CompositionLibraryTestActivationRuntime()
    let model = RetailOnboardingModel(
        library: SparkLibrary(store: try SwiftDataLibraryStore()),
        identityResolver: CompositionLibraryTestFakeIdentityResolver(
            .success(
                try compositionLibraryTestAuthenticated(compositionLibraryTestIdentityJSON(node: 1))
            )
        ),
        runtime: runtime
    )
    model.library.reconcile(compositionLibraryTestSeedTarget(node: 1, host: "spark-a1b2.local"))
    let entryID = try #require(model.library.entries.first?.id)
    let open = try #require(model.openLibraryEntry(entryID))
    await open.value
    let dashboard = try #require(model.dashboardModel)
    #expect(dashboard.runtimeVersion == nil)

    await model.refreshSavedSparks()

    #expect(
        dashboard.runtimeVersion == "0.1.0",
        "foreground activation must replace Connecting with the live runtime version"
    )
    #expect(await runtime.healthReadCount() == 1)
}

@MainActor
@Test func aTailscaleNameIsCachedAsAnOverlayRouteAfterPinnedVerification() async throws {
    let identity = try compositionLibraryTestAuthenticated(
        compositionLibraryTestIdentityJSON(node: 1)
    )
    let library = SparkLibrary(store: MemoryLibraryStore())
    let entry = library.reconcile(
        compositionLibraryTestSeedTarget(node: 1, host: "spark-example.local")
    )
    .entry
    let registration = LibraryRemoteAccessRouteRegistration(
        library: library,
        identityResolver: CompositionLibraryTestFakeIdentityResolver(.success(identity)),
        targetID: entry.id
    )

    try await registration.registerPrivateOverlay(
        hostname: "spark-example.tail1234.ts.net",
        basedOn: URL(string: "https://spark-example.local:7443")!
    )

    let overlay = library.entry(id: entry.id)?.members.first?.routes.first {
        $0.kind == .privateOverlay
    }
    #expect(overlay?.baseURL.absoluteString == "https://spark-example.tail1234.ts.net:7443")
    #expect(library.entry(id: entry.id)?.routeInUse?.kind == .privateOverlay)

    await #expect(throws: PrivateOverlayRouteRegistrationError.self) {
        try await registration.registerPrivateOverlay(
            hostname: "spark.evil.example",
            basedOn: URL(string: "https://spark-example.local:7443")!
        )
    }
}

@MainActor
@Test func optionalSetupNamePersistsWithoutChangingSparkIdentityOrOtherLabels() throws {
    let store = MemoryLibraryStore()
    let library = SparkLibrary(store: store)
    let existing = library.reconcile(
        compositionLibraryTestSeedTarget(node: 1, host: "spark-one.local")
    ).entry
    library.setCustomLabel("Study Spark", for: existing.id)
    let model = RetailOnboardingModel(library: library)
    model.setupCustomLabel = "  Family Spark  "
    let route = URL(string: "https://spark-two.local:7443")!
    let identity = try compositionLibraryTestAuthenticated(
        compositionLibraryTestIdentityJSON(node: 2)
    )
    let result = try #require(model.recordCompletedSetup(route: route, authenticated: identity))
    let entry = try #require(library.entry(id: result.entry.id))
    #expect(entry.displayName == "Family Spark")
    #expect(entry.coordinatorNodeID == compositionLibraryTestCompositionNodeID(2))
    #expect(entry.preferredRoute?.baseURL == route)
    #expect(library.entry(id: existing.id)?.displayName == "Study Spark")
    let restored = SparkLibrary(store: store)
    restored.load()
    #expect(restored.entry(id: entry.id)?.displayName == "Family Spark")
    model.setupCustomLabel = "   "
    model.recordCompletedSetup(route: route, authenticated: identity)
    #expect(library.entry(id: entry.id)?.displayName == "Family Spark")
    model.setupCustomLabel = String(repeating: "a", count: 130)
    #expect(model.setupCustomLabel.count == 120)
    model.cancelAddingSpark()
    #expect(model.setupCustomLabel.isEmpty)
}

@MainActor
@Test func aSetupNameIsNeverSavedBeforeIdentityIsAuthenticated() async throws {
    let library = SparkLibrary(store: MemoryLibraryStore())
    let model = RetailOnboardingModel(
        library: library,
        identityResolver: CompositionLibraryTestFakeIdentityResolver(.failure(.unbound))
    )
    model.machineName = "spark.local"
    model.setupCustomLabel = "Family Spark"
    await model.completeSetup()
    #expect(library.entries.isEmpty)
    #expect(model.state.issue == .identityUnavailable)
}

@MainActor
@Test func aFailedOptionalNameSaveIsReportedWithoutDiscardingThePairedSpark() throws {
    let store = SetupLabelFailingStore()
    let model = RetailOnboardingModel(library: SparkLibrary(store: store))
    model.setupCustomLabel = "Family Spark"
    let result = try #require(
        model.recordCompletedSetup(
            route: URL(string: "https://spark.local:7443")!,
            authenticated: try compositionLibraryTestAuthenticated(
                compositionLibraryTestIdentityJSON(node: 1)
            )
        )
    )
    #expect(model.setupLabelSaveFailed)
    #expect(model.library.entry(id: result.entry.id) != nil)
    let restored = SparkLibrary(store: store)
    restored.load()
    #expect(restored.entry(id: result.entry.id) != nil)
    #expect(restored.entry(id: result.entry.id)?.customLabel == nil)
}

@MainActor
private final class SetupLabelFailingStore: SparkLibraryStoring {
    var entries: [LibraryEntry] = []
    let isDurable = true
    func load() -> [LibraryEntry] { entries }
    func save(_ entries: [LibraryEntry]) throws {
        if entries.contains(where: { $0.customLabel != nil }) {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        self.entries = entries
    }
}

@MainActor
@Test func tailscaleIPv6AndIPv4HaveSeparateRememberedRoutes() throws {
    let identity = try compositionLibraryTestAuthenticated(
        compositionLibraryTestIdentityJSON(node: 1)
    )
    let library = SparkLibrary(store: MemoryLibraryStore())
    let entry = library.reconcile(compositionLibraryTestSeedTarget(node: 1, host: "spark.local"))
        .entry
    let registration = LibraryRemoteAccessRouteRegistration(
        library: library,
        identityResolver: CompositionLibraryTestFakeIdentityResolver(.success(identity)),
        targetID: entry.id
    )
    let local = URL(string: "https://spark.local:7443")!
    registration.rememberPrivateOverlay(hostname: "100.96.4.2", basedOn: local)
    registration.rememberPrivateOverlay(hostname: "fd7a:115c:a1e0::1234", basedOn: local)
    registration.rememberPrivateOverlay(hostname: "fd12:3456::1", basedOn: local)
    let routes =
        library.entry(id: entry.id)?.members.first?.routes.filter { $0.kind == .privateOverlay }
        ?? []
    #expect(routes.count == 2)
    #expect(routes.contains { $0.baseURL.absoluteString == "https://[fd7a:115c:a1e0::1234]:7443" })
    #expect(!routes.contains { $0.baseURL.absoluteString.contains("fd12") })
}
