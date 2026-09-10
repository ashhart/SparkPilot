import Foundation
import SparkCore
import SparkTransport
import Testing

@testable import SparkLibrary

/// Exercise shared route scoring for failures, metering and identity evidence while preserving stable card identity.

private let pin = "a1b2c3d4e5f60718293a4b5c6d7e8f90"
private let otherPin = "ffffffffffffffffffffffffffffffff"

private func cached(
    _ host: String,
    kind: SparkTransportKind,
    interface: String? = nil,
    fingerprint: String? = pin,
    metered: Bool = false,
    failures: Int = 0,
    lastSuccess: Date? = nil
) -> CachedRoute {
    var components = URLComponents()
    components.scheme = "https"
    components.host = host
    components.port = 7443
    return CachedRoute(
        baseURL: components.url!,
        kind: kind,
        interfaceName: interface,
        peerFingerprint: fingerprint,
        lastSuccess: lastSuccess,
        isMetered: metered,
        consecutiveFailures: failures
    )
}

private func ordered(
    _ routes: [CachedRoute],
    identity: String? = pin
) -> [CachedRoute] {
    LibraryReconciler.mergedRoutes(existing: routes, seen: [], establishedIdentity: identity)
}

// MARK: - Default route ordering

@Test func aWiredRouteStillOutranksWiFiAndOverlay() {
    // Apply the shared default route priority from §13.2.
    let result = ordered([
        cached("100.64.0.2", kind: .privateOverlay),
        cached("spark.local", kind: .localWiFi, interface: "en0"),
        cached("spark-direct.local", kind: .directEthernet, interface: "en5"),
    ])
    #expect(
        result.map(\.kind) == [.directEthernet, .localWiFi, .privateOverlay]
    )
}

@Test func aRememberedRouteKeepsItsWiredClassWithoutACachedFingerprint() {
    // Keep unprobed remembered routes in their transport class rather than treating missing evidence as unpinned failure.
    let result = ordered(
        [
            cached("spark.local", kind: .localWiFi, interface: "en0", fingerprint: nil),
            cached("spark-direct.local", kind: .directEthernet, interface: "en5", fingerprint: nil),
        ],
        identity: nil
    )
    #expect(result.first?.kind == .directEthernet)
    #expect(
        LibraryReconciler.rank(of: result[0], establishedIdentity: nil) == .directEthernetPinned
    )
}

// MARK: - Failure demotion

@Test func aRouteThatKeepsFailingLosesToAHealthierOne() {
    // Demote a connected cable route that no longer carries traffic.
    let result = ordered([
        cached("spark-direct.local", kind: .directEthernet, interface: "en5", failures: 3),
        cached("spark.local", kind: .localWiFi, interface: "en0"),
    ])
    #expect(result.first?.kind == .localWiFi, "three failures must demote the wired route")
}

@Test func oneOrTwoFailuresAreNotEnoughToGiveUpOnAWiredRoute() {
    // Tolerate one lost probe without flapping route priority.
    for failures in 0...2 {
        let result = ordered([
            cached(
                "spark-direct.local",
                kind: .directEthernet,
                interface: "en5",
                failures: failures
            ),
            cached("spark.local", kind: .localWiFi, interface: "en0"),
        ])
        #expect(result.first?.kind == .directEthernet, "\(failures) failures must not demote")
    }
}

@Test func aDemotedRouteIsStillRememberedRatherThanDiscarded() {
    // Retain demoted routes so a repaired physical connection can recover without rediscovery.
    let result = ordered([
        cached("spark-direct.local", kind: .directEthernet, interface: "en5", failures: 9),
        cached("spark.local", kind: .localWiFi, interface: "en0"),
    ])
    #expect(result.count == 2)
    #expect(result.contains { $0.kind == .directEthernet })
}

// MARK: - Metered avoidance

@Test func anUnmeteredPathWinsWhenNothingElseSeparatesTwoRoutes() {
    // Prefer unmetered paths when otherwise equivalent overlay routes compete (§13.2).
    let result = ordered([
        cached("metered.example", kind: .privateOverlay, interface: "wwan0", metered: true),
        cached("free.example", kind: .privateOverlay, interface: "utun0", metered: false),
    ])
    #expect(result.first?.baseURL.host() == "free.example")
}

@Test func meteredAvoidanceNeverOutranksTheWiredPreference() {
    // Keep transport-class priority ahead of metering preference (§13.2).
    let result = ordered([
        cached("100.96.4.2", kind: .privateOverlay, metered: false),
        cached("spark-direct.local", kind: .directEthernet, interface: "en5", metered: true),
    ])
    #expect(result.first?.kind == .directEthernet)
}

// MARK: - Identity

@Test func aRouteAnsweringForADifferentIdentityIsNeverPreferred() {
    // Deprioritize contradictory route evidence while leaving authoritative trust to transport pinning and Keychain.
    let result = ordered(
        [
            cached(
                "impostor.local",
                kind: .directEthernet,
                interface: "en5",
                fingerprint: otherPin
            ),
            cached("spark.local", kind: .localWiFi, interface: "en0", fingerprint: pin),
        ],
        identity: pin
    )
    #expect(result.first?.baseURL.host() == "spark.local")
    #expect(result.last?.baseURL.host() == "impostor.local")
}

@Test func aContradictedRouteIsRankedRejectedRatherThanQuietlyDeprioritised() {
    // Use library evidence for ordering without creating a second trust gate.
    let rank = LibraryReconciler.rank(
        of: cached(
            "impostor.local",
            kind: .directEthernet,
            interface: "en5",
            fingerprint: otherPin
        ),
        establishedIdentity: pin
    )
    #expect(rank == .rejected)
    #expect(!rank.isUsable)
}

@Test func aRouteThatHasNotBeenIdentifiedYetIsNotTreatedAsContradicted() {
    // Treat an unobserved fingerprint as missing evidence, not an identity mismatch.
    let rank = LibraryReconciler.rank(
        of: cached("new.local", kind: .localWiFi, interface: "en0", fingerprint: nil),
        establishedIdentity: pin
    )
    #expect(rank.isUsable)
}

@Test func withNoEstablishedIdentityNoRouteIsRejected() {
    // Before the first authenticated contact there is nothing to contradict.
    let result = ordered(
        [
            cached("a.local", kind: .localWiFi, interface: "en0", fingerprint: pin),
            cached("b.local", kind: .directEthernet, interface: "en5", fingerprint: otherPin),
        ],
        identity: nil
    )
    #expect(
        result.allSatisfy {
            LibraryReconciler.rank(of: $0, establishedIdentity: nil).isUsable
        }
    )
    #expect(result.first?.kind == .directEthernet)
}

@Test func aContradictedRouteIsKeptSoTheCardCanStillReportIt() {
    // Retain mismatch evidence for presentation while transport independently refuses the connection.
    let contradicted = cached(
        "impostor.local",
        kind: .directEthernet,
        interface: "en5",
        fingerprint: otherPin
    )
    let result = ordered([contradicted], identity: pin)
    #expect(result.count == 1)
    #expect(result.first?.baseURL.host() == "impostor.local")
}

// MARK: - Identity-preserving route changes

@Test func aSlotChangingItsAddressKeepsItsIdentityAndItsFailureHistory() {
    // Update mutable endpoints without changing identity or clearing existing failure evidence (§13.1).
    let existing = [
        cached("spark.local", kind: .localWiFi, interface: "en0", failures: 4)
    ]
    let seen = [cached("192.0.2.44", kind: .localWiFi, interface: "en0")]
    let merged = LibraryReconciler.mergedRoutes(
        existing: existing,
        seen: seen,
        establishedIdentity: pin
    )

    #expect(merged.count == 1, "an address change is the same slot")
    #expect(merged.first?.baseURL.host() == "192.0.2.44")
    #expect(merged.first?.id == existing[0].id, "the same route, moved")
    #expect(merged.first?.consecutiveFailures == 4)
}

@Test func aSuccessfulObservationHealsASlotsFailureHistory() {
    // Clear failure penalties after a route succeeds again.
    let existing = [
        cached("spark.local", kind: .localWiFi, interface: "en0", failures: 6)
    ]
    let seen = [
        cached("spark.local", kind: .localWiFi, interface: "en0", lastSuccess: Date())
    ]
    let merged = LibraryReconciler.mergedRoutes(
        existing: existing,
        seen: seen,
        establishedIdentity: pin
    )
    #expect(merged.first?.consecutiveFailures == 0)
}

@Test func aCardWhoseEveryRouteIsContradictedStillOffersOne() {
    // Continue reaching the transport trust check when all remembered routes contradict current identity evidence.
    let result = ordered(
        [
            cached("a.local", kind: .localWiFi, interface: "en0", fingerprint: otherPin),
            cached("b.local", kind: .directEthernet, interface: "en5", fingerprint: otherPin),
        ],
        identity: pin
    )
    #expect(result.count == 2)
    #expect(result.first != nil, "ordering must not empty the list")
    #expect(
        result.allSatisfy { LibraryReconciler.rank(of: $0, establishedIdentity: pin) == .rejected }
    )
}

@Test func routesStayBoundedWhateverTheOrdering() {
    let many = (0..<40).map {
        cached("host-\($0).local", kind: .privateOverlay, interface: "utun\($0)")
    }
    #expect(ordered(many).count == LibraryReconciler.maximumCachedRoutes)
}

// MARK: - Recording the evidence demotion runs on

@MainActor
@Test func aFailedProbeIsRecordedAgainstTheRouteThatFailed() async throws {
    // Record failures against the attempted route so demotion can accumulate real evidence.
    let library = SparkLibrary(store: MemoryLibraryStore(), now: { Date() })
    let node = libraryNodeID(1)
    let wired = cached("spark-direct.local", kind: .directEthernet, interface: "en5")
    _ = library.reconcile(
        target(node: 1, routes: [wired, cached("spark.local", kind: .localWiFi, interface: "en0")])
    )
    let entryID = try #require(library.entries.first?.id)

    for _ in 0..<3 {
        library.markUnreachable(entryID: entryID, nodeID: node, route: wired, at: Date())
    }

    let member = try #require(library.entry(id: entryID)?.member(nodeID: node))
    let direct = try #require(member.routes.first { $0.kind == .directEthernet })
    #expect(direct.consecutiveFailures == 3)
    // Recorded failures must change route priority.
    #expect(member.routes.first?.kind == .localWiFi)
}

@MainActor
@Test func aSuccessfulProbeClearsThatRoutesFailures() async throws {
    let library = SparkLibrary(store: MemoryLibraryStore(), now: { Date() })
    let node = libraryNodeID(2)
    let wired = cached("spark-direct.local", kind: .directEthernet, interface: "en5")
    _ = library.reconcile(target(node: 2, routes: [wired]))
    let entryID = try #require(library.entries.first?.id)

    for _ in 0..<4 {
        library.markUnreachable(entryID: entryID, nodeID: node, route: wired, at: Date())
    }
    library.markReachable(entryID: entryID, nodeID: node, route: wired, at: Date())

    let member = try #require(library.entry(id: entryID)?.member(nodeID: node))
    #expect(member.routes.first?.consecutiveFailures == 0)
    #expect(member.routes.first?.kind == .directEthernet, "a healed route returns to the front")
}

@MainActor
@Test func aFailureWithNoNamedRouteBlamesNoRoute() async throws {
    // Do not charge card-level or pre-route failures to an unrelated first-choice route.
    let library = SparkLibrary(store: MemoryLibraryStore(), now: { Date() })
    let node = libraryNodeID(3)
    _ = library.reconcile(
        target(
            node: 3,
            routes: [cached("spark-direct.local", kind: .directEthernet, interface: "en5")]
        )
    )
    let entryID = try #require(library.entries.first?.id)

    library.markUnreachable(entryID: entryID, at: Date())

    let member = try #require(library.entry(id: entryID)?.member(nodeID: node))
    #expect(member.routes.first?.consecutiveFailures == 0)
    #expect(member.reachable == false, "the member is still marked unreachable")
}
