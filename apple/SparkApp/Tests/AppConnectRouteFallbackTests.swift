import Foundation
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing

@testable import SparkAppComposition

/// Connect tries the Spark's own network first and falls back to its Tailscale route on its own.

private let localHost = "spark-example.local"
private let tailscaleHost = "spark-example.tail1234.ts.net"

/// Answers only for the hosts it is told to, recording every host it was asked about in order.
private actor ConnectFallbackResolver: AuthenticatedIdentityResolving {
    private var answering: Set<String>
    private let identity: AuthenticatedIdentity
    private var asked: [String] = []

    init(answering: Set<String>, identity: AuthenticatedIdentity) {
        self.answering = answering
        self.identity = identity
    }

    func stopAnswering(_ host: String) {
        answering.remove(host)
        asked.removeAll()
    }

    func resolveIdentity(route: URL, expectedNodeID: SparkNodeID?) async throws
        -> AuthenticatedIdentity
    {
        let host = route.host() ?? ""
        asked.append(host)
        guard answering.contains(host) else { throw AuthenticatedIdentityError.pinRejected }
        return identity
    }

    func hosts() -> [String] { asked }
}

@MainActor
private func seededModel(
    answering: Set<String>
) throws -> (RetailOnboardingModel, String, ConnectFallbackResolver) {
    let identity = try compositionLibraryTestAuthenticated(
        compositionLibraryTestIdentityJSON(node: 1)
    )
    let resolver = ConnectFallbackResolver(answering: answering, identity: identity)
    let model = RetailOnboardingModel(
        library: SparkLibrary(store: MemoryLibraryStore()),
        identityResolver: resolver,
        savedRouteDiscovery: CompositionLibraryTestStaticSavedSparkRouteDiscovery(routes: []),
        runtime: CompositionLibraryTestActivationRuntime()
    )
    let entry = model.library.reconcile(
        AuthenticatedTarget(
            nodeID: compositionLibraryTestCompositionNodeID(1),
            clusterID: nil,
            name: "My Spark",
            role: .standalone,
            authorityFingerprint: "fp",
            displayName: "spark-example",
            routes: [
                CachedRoute(
                    baseURL: URL(string: "https://\(localHost):7443")!,
                    kind: .localWiFi,
                    interfaceName: "en0"
                ),
                CachedRoute(
                    baseURL: URL(string: "https://\(tailscaleHost):7443")!,
                    kind: .privateOverlay,
                    interfaceName: "tailscale"
                ),
            ]
        )
    ).entry
    return (model, entry.id, resolver)
}

@MainActor
@Test func connectFallsBackToTheTailscaleRouteWhenTheLocalRouteDoesNotAnswer() async throws {
    let (model, entryID, _) = try seededModel(answering: [tailscaleHost])

    await model.openLibraryEntry(entryID)?.value

    #expect(model.libraryOpenFailure == nil)
    #expect(
        model.dashboardModel?.route.host() == tailscaleHost,
        "the session opens on the route that answered"
    )
    let entry = try #require(model.library.entry(id: entryID))
    #expect(entry.connectionState == .connectedRemote)
    #expect(entry.routeInUse?.kind == .privateOverlay)
    #expect(
        entry.preferredRoute?.kind == .localWiFi,
        "rank order is unchanged; the local route is only demoted by repeated failure"
    )
    let path = SparkConnectionPath.resolve(
        entry: entry,
        activeRouteURL: model.dashboardModel?.route
    )
    #expect(path?.label == "Over Tailscale")
    #expect(path?.host == tailscaleHost)
}

@MainActor
@Test func connectTriesTheLocalRouteFirstAndNeverBothersTailscaleWhenItAnswers() async throws {
    let (model, entryID, resolver) = try seededModel(answering: [localHost, tailscaleHost])

    await model.openLibraryEntry(entryID)?.value

    #expect(await resolver.hosts() == [localHost])
    #expect(model.dashboardModel?.route.host() == localHost)
    let entry = try #require(model.library.entry(id: entryID))
    #expect(entry.connectionState == .connectedWiFi)
    let path = SparkConnectionPath.resolve(
        entry: entry,
        activeRouteURL: model.dashboardModel?.route
    )
    #expect(path?.label == "On your network")
    #expect(path?.host == nil, "the local path does not repeat the local address")
}

@MainActor
@Test func aFailedLocalRouteIsChargedAndTheTailscaleRouteIsTriedLast() async throws {
    let (model, entryID, resolver) = try seededModel(answering: [])

    await model.openLibraryEntry(entryID)?.value

    #expect(await resolver.hosts() == [localHost, tailscaleHost])
    #expect(model.libraryOpenFailure?.reason == .unavailable)
    let member = try #require(model.library.entry(id: entryID)?.members.first)
    #expect(member.routes.first { $0.kind == .localWiFi }?.consecutiveFailures == 1)
    #expect(member.routes.first { $0.kind == .privateOverlay }?.consecutiveFailures == 1)
    #expect(model.library.entry(id: entryID)?.connectionState == .offlineCached)
}

@MainActor
@Test func aBackgroundRefreshAlsoReachesTheSparkOverTailscale() async throws {
    let (model, entryID, _) = try seededModel(answering: [tailscaleHost])
    model.library.markUnreachable(entryID: entryID)

    await model.refreshSavedSparks()

    let entry = try #require(model.library.entry(id: entryID))
    #expect(entry.connectionState == .connectedRemote)
    #expect(entry.routeInUse?.baseURL.host() == tailscaleHost)
}

@MainActor
@Test func aCardReachabilityProbeFallsBackToTailscaleImmediately() async throws {
    let (model, entryID, resolver) = try seededModel(answering: [tailscaleHost])
    #expect(await model.updateFromProbe(entryID: entryID))
    #expect(await resolver.hosts() == [localHost, tailscaleHost])
    #expect(model.library.entry(id: entryID)?.connectionState == .connectedRemote)
}

/// PLAN 38.4: failure of a status call triggers immediate alternate-route evaluation.
@MainActor
@Test func aFailedStatusCallEvaluatesTheOtherRoutesAtOnce() async throws {
    let (model, entryID, resolver) = try seededModel(answering: [localHost, tailscaleHost])
    await model.openLibraryEntry(entryID)?.value
    let dashboard = try #require(model.dashboardModel)
    #expect(dashboard.route.host() == localHost)

    await resolver.stopAnswering(localHost)
    await dashboard.onStatusFailure?()

    #expect(
        await resolver.hosts() == [tailscaleHost],
        "the route that just failed is not the first thing tried again"
    )
    let entry = try #require(model.library.entry(id: entryID))
    #expect(entry.routeInUse?.baseURL.host() == tailscaleHost)
    #expect(entry.connectionState == .connectedRemote)
    #expect(model.dashboardModel !== dashboard)
    #expect(model.dashboardModel?.route.host() == tailscaleHost)
    #expect(model.dashboardModel?.onStatusFailure != nil)
}

@MainActor
@Test func modelAndChatInventoryUseTheAuthenticatedTailscaleRoute() async throws {
    let (model, entryID, _) = try seededModel(answering: [tailscaleHost])
    await model.openLibraryEntry(entryID)?.value
    let entry = try #require(model.library.entry(id: entryID))
    #expect(entry.preferredRoute?.baseURL.host() == localHost)
    let node = try #require(entry.coordinatorNodeID)
    let trust = NodeTrust(
        nodeID: node.rawValue.uuidString.lowercased(),
        nodeName: "My Spark",
        tlsFingerprint: String(repeating: "a", count: 64),
        authorityFingerprint: "fp",
        authorityPublicKey: String(repeating: "b", count: 64),
        pairedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let connection = try SignedCrossTargetModelLibraryProvider.productionRuntime(
        entry: entry,
        trustReader: { $0 == trust.nodeID ? trust : nil },
        clientProvider: { receivedNode, received in
            #expect(receivedNode == node)
            #expect(received == trust)
            return CompositionLibraryTestActivationRuntime()
        }
    )
    #expect(connection.route.host() == tailscaleHost)
    #expect(connection.expectedNodeID == node)
    #expect(connection.expectedAuthorityFingerprint == trust.authorityFingerprint)
}

@MainActor
@Test func aClosedDashboardCannotBeReopenedByItsOldFailoverHook() async throws {
    let (model, entryID, resolver) = try seededModel(answering: [localHost, tailscaleHost])
    await model.openLibraryEntry(entryID)?.value
    let hook = try #require(model.dashboardModel?.onStatusFailure)
    model.closeDashboard()
    await resolver.stopAnswering(localHost)

    await hook()

    #expect(model.dashboardModel == nil)
    #expect(await resolver.hosts().isEmpty)
}

@MainActor
@Test func aNewlyOnboardedDashboardCanMoveStraightToTailscale() async throws {
    let (model, entryID, resolver) = try seededModel(answering: [localHost, tailscaleHost])
    let identity = try compositionLibraryTestAuthenticated(
        compositionLibraryTestIdentityJSON(node: 1)
    )
    let route = try #require(model.library.entry(id: entryID)?.preferredRoute?.baseURL)
    let outcome = try #require(model.recordCompletedSetup(route: route, authenticated: identity))
    #expect(outcome.entry.id == entryID)
    let hook = try #require(model.dashboardModel?.onStatusFailure)
    await resolver.stopAnswering(localHost)

    await hook()

    #expect(model.dashboardModel?.route.host() == tailscaleHost)
    #expect(model.library.entry(id: entryID)?.connectionState == .connectedRemote)
}

/// The evaluation is only worth doing while the entry is still trusted.
@MainActor
@Test func anIdentityMismatchStopsTheFailoverRatherThanTryingEveryAddress() async throws {
    let (model, entryID, resolver) = try seededModel(answering: [localHost, tailscaleHost])
    await model.openLibraryEntry(entryID)?.value
    let dashboard = try #require(model.dashboardModel)
    model.library.markIdentityMismatch(
        entryID: entryID,
        presented: compositionLibraryTestCompositionNodeID(2),
        at: Date(timeIntervalSince1970: 1_700_000_000)
    )

    await resolver.stopAnswering(localHost)
    await dashboard.onStatusFailure?()

    #expect(await resolver.hosts().isEmpty)
}

@MainActor
private final class FailoverCallCount {
    var value = 0
}

/// Wiring the hook is not enough: the dashboard's own failure path has to call it.
@MainActor
@Test func aDashboardStatusFailureCallsTheRouteFailoverHook() async {
    let calls = FailoverCallCount()
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: DashboardTestLifecycleRuntime(failReads: true),
        operationStore: DashboardTestTestOperationStore()
    )
    model.onStatusFailure = { calls.value += 1 }

    await model.refresh()

    #expect(model.errorMessage?.contains("could not be reached") == true)
    #expect(calls.value == 1)
}
