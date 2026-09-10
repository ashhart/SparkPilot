import Foundation
import SparkCore
import SparkLibrary
import Testing

@testable import SparkAppComposition

/// Verifies that probe failures increment the specific route's counter and affect subsequent route ordering.

private func demotionNodeID(_ value: UInt64) -> SparkNodeID {
    SparkNodeID(
        rawValue: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llx", value))!
    )
}

private actor RefusingResolver: AuthenticatedIdentityResolving {
    func resolveIdentity(
        route: URL,
        expectedNodeID: SparkNodeID?
    ) async throws -> AuthenticatedIdentity {
        throw AuthenticatedIdentityError.pinRejected
    }
}

/// A Spark remembered on both a direct cable and Wi-Fi, cable first.
@MainActor
private func libraryWithTwoRoutes() -> (SparkLibrary, String) {
    let library = SparkLibrary(store: MemoryLibraryStore())
    let entry = library.reconcile(
        AuthenticatedTarget(
            nodeID: demotionNodeID(1),
            clusterID: nil,
            name: "Spark",
            role: .standalone,
            authorityFingerprint: "fp123",
            displayName: "spark-a1b2",
            routes: [
                CachedRoute(
                    baseURL: URL(string: "https://spark-direct.local:7443")!,
                    kind: .directEthernet,
                    interfaceName: "en5"
                ),
                CachedRoute(
                    baseURL: URL(string: "https://spark-a1b2.local:7443")!,
                    kind: .localWiFi,
                    interfaceName: "en0"
                ),
            ]
        )
    ).entry
    return (library, entry.id)
}

@MainActor
@Test func aProbeFailureIsChargedToTheRouteItUsed() async {
    let (library, entryID) = libraryWithTwoRoutes()
    let model = RetailOnboardingModel(library: library, identityResolver: RefusingResolver())

    await model.updateFromProbe(entryID: entryID)

    let member = library.entry(id: entryID)?.members.first
    let direct = member?.routes.first { $0.kind == .directEthernet }
    #expect(direct?.consecutiveFailures == 1, "the route that was tried carries the failure")
    let wifi = member?.routes.first { $0.kind == .localWiFi }
    #expect(wifi?.consecutiveFailures == 0, "a route nobody tried is not blamed")
}

@MainActor
@Test func aCableThatKeepsFailingStopsBeingTheRouteEveryRequestTries() async {
    // Demote a nonfunctional cable without deleting its route or requiring physical disconnection.
    let (library, entryID) = libraryWithTwoRoutes()
    let model = RetailOnboardingModel(library: library, identityResolver: RefusingResolver())

    #expect(library.entry(id: entryID)?.preferredRoute?.kind == .directEthernet)

    for _ in 0..<3 {
        await model.updateFromProbe(entryID: entryID)
    }

    let entry = library.entry(id: entryID)
    #expect(entry?.preferredRoute?.kind == .localWiFi, "three failures demote the cable")
    #expect(
        entry?.members.first?.routes.contains { $0.kind == .directEthernet } == true,
        "the cable is demoted, not forgotten"
    )
}

@MainActor
@Test func demotionSurvivesReloadingTheLibraryFromDisk() async {
    // Persist route failure counters across app relaunches.
    let store = MemoryLibraryStore()
    let library = SparkLibrary(store: store)
    let entry = library.reconcile(
        AuthenticatedTarget(
            nodeID: demotionNodeID(2),
            clusterID: nil,
            name: "Spark",
            role: .standalone,
            authorityFingerprint: "fp123",
            displayName: "spark-b",
            routes: [
                CachedRoute(
                    baseURL: URL(string: "https://spark-direct.local:7443")!,
                    kind: .directEthernet,
                    interfaceName: "en5"
                ),
                CachedRoute(
                    baseURL: URL(string: "https://spark-b.local:7443")!,
                    kind: .localWiFi,
                    interfaceName: "en0"
                ),
            ]
        )
    ).entry
    let model = RetailOnboardingModel(library: library, identityResolver: RefusingResolver())
    for _ in 0..<3 {
        await model.updateFromProbe(entryID: entry.id)
    }

    let reloaded = SparkLibrary(store: store)
    reloaded.load()

    #expect(reloaded.entry(id: entry.id)?.preferredRoute?.kind == .localWiFi)
}

@MainActor
@Test func aRouteAnsweringForAnotherIdentityStopsBeingPreferred() {
    // Demote routes presenting another node while retaining transport pinning as the connection's trust boundary.
    let library = SparkLibrary(store: MemoryLibraryStore())
    let entry = library.reconcile(
        AuthenticatedTarget(
            nodeID: demotionNodeID(4),
            clusterID: nil,
            name: "Spark",
            role: .standalone,
            authorityFingerprint: "fp123",
            displayName: "spark-c",
            routes: [
                CachedRoute(
                    baseURL: URL(string: "https://spark-c.local:7443")!,
                    kind: .localWiFi,
                    interfaceName: "en0",
                    peerFingerprint: "aaaa",
                    lastSuccess: Date()
                )
            ]
        )
    ).entry

    // A cable appears, and it answers for something else.
    _ = library.reconcile(
        AuthenticatedTarget(
            nodeID: demotionNodeID(4),
            clusterID: nil,
            name: "Spark",
            role: .standalone,
            authorityFingerprint: "fp123",
            displayName: "spark-c",
            routes: [
                CachedRoute(
                    baseURL: URL(string: "https://spark-direct.local:7443")!,
                    kind: .directEthernet,
                    interfaceName: "en5",
                    peerFingerprint: "bbbb"
                )
            ]
        )
    )

    let refreshed = library.entry(id: entry.id)
    #expect(
        refreshed?.preferredRoute?.kind == .localWiFi,
        "a contradicted cable does not take the front from a proven Wi-Fi route"
    )
    #expect(
        refreshed?.members.first?.routes.contains { $0.kind == .directEthernet } == true,
        "the evidence is kept"
    )
}
