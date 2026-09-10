import Foundation
import SparkCore
import Testing

@testable import SparkLibrary

/// The card and every new session follow the route that answered last, even when a local route outranks it.

private func routeInUseNode(_ value: UInt64) -> SparkNodeID {
    SparkNodeID(
        rawValue: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llx", value))!
    )
}

private func route(_ host: String, kind: SparkTransportKind, lastSuccess: Date?) -> CachedRoute {
    CachedRoute(
        baseURL: URL(string: "https://\(host):7443")!,
        kind: kind,
        interfaceName: kind == .privateOverlay ? "tailscale" : "en0",
        lastSuccess: lastSuccess
    )
}

@MainActor
private func seeded(routes: [CachedRoute]) -> (SparkLibrary, LibraryEntry) {
    let library = SparkLibrary(store: MemoryLibraryStore())
    let entry = library.reconcile(
        AuthenticatedTarget(
            nodeID: routeInUseNode(1),
            clusterID: nil,
            name: "Spark",
            role: .standalone,
            authorityFingerprint: "fp",
            displayName: "spark-example",
            routes: routes
        )
    ).entry
    return (library, entry)
}

@MainActor
@Test func theRouteThatAnsweredLastIsTheRouteInUseEvenWhenALocalRouteOutranksIt() {
    let earlier = Date(timeIntervalSince1970: 1_000)
    let later = Date(timeIntervalSince1970: 2_000)
    let (_, entry) = seeded(routes: [
        route("spark-example.local", kind: .localWiFi, lastSuccess: earlier),
        route("spark-example.tail1234.ts.net", kind: .privateOverlay, lastSuccess: later),
    ])

    #expect(entry.preferredRoute?.kind == .localWiFi, "rank order still prefers the local route")
    #expect(entry.routeInUse?.kind == .privateOverlay)
    #expect(entry.routeInUse?.baseURL.host == "spark-example.tail1234.ts.net")
    #expect(entry.connectRoute?.kind == .privateOverlay)
}

@MainActor
@Test func beforeAnyContactTheConnectRouteIsTheBestRememberedOne() {
    let (_, entry) = seeded(routes: [
        route("spark-example.local", kind: .localWiFi, lastSuccess: nil),
        route("spark-example.tail1234.ts.net", kind: .privateOverlay, lastSuccess: nil),
    ])

    #expect(entry.routeInUse == nil)
    #expect(entry.connectRoute?.kind == .localWiFi)
}

@MainActor
@Test func connectionStateAndSnapshotFollowTheRouteInUse() {
    let (library, entry) = seeded(routes: [
        route("spark-example.local", kind: .localWiFi, lastSuccess: Date(timeIntervalSince1970: 1_000))
    ])
    let overlay = route("spark-example.tail1234.ts.net", kind: .privateOverlay, lastSuccess: nil)
    library.markReachable(
        entryID: entry.id,
        nodeID: routeInUseNode(1),
        route: overlay,
        at: Date(timeIntervalSince1970: 3_000)
    )

    let refreshed = library.entry(id: entry.id)
    #expect(refreshed?.connectionState == .connectedRemote)
    let snapshot = library.operationalSnapshot(
        for: entry.id,
        at: Date(timeIntervalSince1970: 3_001)
    )
    #expect(snapshot?.routeInUse?.kind == .privateOverlay)
    #expect(snapshot?.routeInUse?.host == "spark-example.tail1234.ts.net")
    #expect(snapshot?.preferredRoute?.kind == .localWiFi)
    #expect(snapshot?.connectionState == .connectedRemote)
}
