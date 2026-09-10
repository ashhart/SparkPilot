import Foundation
import Network
import SparkAPI
import SparkCore
import SparkDiscovery
import SparkLibrary
import Testing
@testable import SparkAppComposition

// MARK: - Find Nearby routing

@MainActor
@Test func discoveredPairedSparkOpensItsExistingCard() async throws {
    let model = RetailOnboardingModel(
        library: SparkLibrary(store: try SwiftDataLibraryStore()),
        identityResolver: CompositionLibraryTestFakeIdentityResolver(
            .success(
                try compositionLibraryTestAuthenticated(compositionLibraryTestIdentityJSON(node: 1))
            )
        )
    )
    model.library.reconcile(compositionLibraryTestSeedTarget(node: 1, host: "spark-a1b2.local"))
    let discovered = DiscoveredSpark(
        id: "spark-a1b2",
        displayName: "Spark-a1b2",
        endpoint: .service(
            name: "Spark-a1b2._spark-runtime._tcp",
            type: "_spark-runtime._tcp",
            domain: "local.",
            interface: nil
        ),
        interface: nil,
        shortNodeID: "a1b2c3d4"
    )

    let probe = model.handleDiscovered(discovered)
    #expect(probe != nil, "a saved card with the same hostname slot opens the paired path")
    await probe?.value

    #expect(model.dashboardModel?.route.host == "spark-a1b2.local")
    #expect(
        model.dashboardModel?.expectedIdentity
            == SparkDashboardIdentityExpectation(
                coordinatorNodeID: compositionLibraryTestCompositionNodeID(1),
                authorityFingerprint: "fp",
                clusterID: nil
            ),
        "the dashboard keeps validating against the trusted selected entry"
    )
    #expect(!model.isAddingSpark)
    #expect(model.library.entries.count == 1, "no duplicate card is created")
}

@MainActor
@Test func discoveredUnpairedRuntimeStartsPairingKeepingTheEndpoint() async throws {
    let model = try compositionLibraryTestMakeModel(
        resolver: CompositionLibraryTestFakeIdentityResolver(.failure(.unbound))
    )
    let endpoint = NWEndpoint.service(
        name: "Spark-c3d4._spark-runtime._tcp",
        type: "_spark-runtime._tcp",
        domain: "local.",
        interface: nil
    )
    let discovered = DiscoveredSpark(
        id: "spark-c3d4",
        displayName: "Spark-c3d4",
        endpoint: endpoint,
        interface: nil,
        shortNodeID: "c3d4e5f6"
    )

    let probe = model.handleDiscovered(discovered)

    #expect(probe == nil, "an unknown runtime starts additional-device pairing")
    #expect(!model.isAddingSpark, "an installed runtime never enters factory setup")
    #expect(model.state.phase == .connectToSpark)
    #expect(model.pairingDeviceTarget?.displayName == "Spark-c3d4")
    #expect(
        model.selectedDiscoveryCandidate?.endpoint == endpoint,
        "the exact Bonjour endpoint survives for the pinned pairing resolver"
    )
    #expect(model.selectedDiscoveryCandidate?.shortNodeID == "c3d4e5f6")
}

@MainActor
@Test func handledDiscoveredClearsStaleCandidateOnThePairedPath() async throws {
    let model = RetailOnboardingModel(
        library: SparkLibrary(store: try SwiftDataLibraryStore()),
        identityResolver: CompositionLibraryTestFakeIdentityResolver(
            .success(
                try compositionLibraryTestAuthenticated(compositionLibraryTestIdentityJSON(node: 1))
            )
        )
    )
    model.library.reconcile(compositionLibraryTestSeedTarget(node: 1, host: "spark-a1b2.local"))
    let discovered = DiscoveredSpark(
        id: "spark-a1b2",
        displayName: "Spark-a1b2",
        endpoint: .service(
            name: "Spark-a1b2._spark-runtime._tcp",
            type: "_spark-runtime._tcp",
            domain: "local.",
            interface: nil
        ),
        interface: nil,
        shortNodeID: "a1b2c3d4"
    )
    // Simulate a stale candidate from an earlier unpaired selection.
    model.selectedDiscoveryCandidate = discovered

    let probe = model.handleDiscovered(discovered)
    await probe?.value

    #expect(probe != nil)
    #expect(
        model.selectedDiscoveryCandidate == nil,
        "the paired path drops the discovery candidate"
    )
    #expect(model.dashboardModel != nil)
}

// MARK: - Discovered blocked-card routing

@MainActor
@Test func discoveringABlockedCardDoesNotStartAddFlowOrProbe() async throws {
    let model = RetailOnboardingModel(
        library: SparkLibrary(store: try SwiftDataLibraryStore()),
        identityResolver: CompositionLibraryTestFakeIdentityResolver(
            .success(
                try compositionLibraryTestAuthenticated(compositionLibraryTestIdentityJSON(node: 1))
            )
        )
    )
    model.library.reconcile(compositionLibraryTestSeedTarget(node: 1, host: "spark-a1b2.local"))
    let entryID = model.library.entries[0].id
    model.library.markIdentityMismatch(
        entryID: entryID,
        presented: compositionLibraryTestCompositionNodeID(2)
    )
    let discovered = DiscoveredSpark(
        id: "spark-a1b2",
        displayName: "Spark-a1b2",
        endpoint: .service(
            name: "Spark-a1b2._spark-runtime._tcp",
            type: "_spark-runtime._tcp",
            domain: "local.",
            interface: nil
        ),
        interface: nil,
        shortNodeID: "a1b2c3d4"
    )

    let probe = model.handleDiscovered(discovered)

    #expect(probe == nil, "a blocked known card never probes")
    #expect(!model.isAddingSpark, "no add sheet/setup begins")
    #expect(
        !model.shouldPresentDiscoveryAddSheet(probe: probe),
        "the add-sheet predicate must not fire for a blocked known card"
    )
    #expect(model.dashboardModel == nil, "no dashboard publishes")
    #expect(model.selectedDiscoveryCandidate == nil, "the known path drops the candidate")
    #expect(model.library.entry(id: entryID)?.issue == .identityMismatch, "the card stays blocked")
}

@MainActor
@Test func addSheetPredicateOnlyFiresForUnknownTargets() async throws {
    let endpoint = NWEndpoint.service(
        name: "Spark-c3d4._spark-runtime._tcp",
        type: "_spark-runtime._tcp",
        domain: "local.",
        interface: nil
    )
    let discovered = DiscoveredSpark(
        id: "spark-c3d4",
        displayName: "Spark-c3d4",
        endpoint: endpoint,
        interface: nil,
        shortNodeID: "c3d4e5f6"
    )

    // Unknown runtime: handleDiscovered enters Pair This Device, so the sheet fires.
    let model = RetailOnboardingModel(
        library: SparkLibrary(store: try SwiftDataLibraryStore()),
        identityResolver: CompositionLibraryTestFakeIdentityResolver(.failure(.unbound))
    )
    let probe = model.handleDiscovered(discovered)
    #expect(probe == nil)
    #expect(!model.isAddingSpark)
    #expect(model.pairingDeviceTarget != nil)
    #expect(model.shouldPresentDiscoveryAddSheet(probe: probe), "unknown target presents the sheet")
    model.cancelAddingSpark()

    // Blocked known card from a clean library → no sheet, ever.
    let other = RetailOnboardingModel(
        library: SparkLibrary(store: try SwiftDataLibraryStore()),
        identityResolver: CompositionLibraryTestFakeIdentityResolver(
            .success(
                try compositionLibraryTestAuthenticated(compositionLibraryTestIdentityJSON(node: 1))
            )
        )
    )
    other.library.reconcile(compositionLibraryTestSeedTarget(node: 1, host: "spark-a1b2.local"))
    let blockedID = other.library.entries[0].id
    other.library.markIdentityMismatch(
        entryID: blockedID,
        presented: compositionLibraryTestCompositionNodeID(7)
    )
    let blockedDiscovery = DiscoveredSpark(
        id: "spark-a1b2",
        displayName: "Spark-a1b2",
        endpoint: endpoint,
        interface: nil,
        shortNodeID: "a1b2c3d4"
    )
    let blockedProbe = other.handleDiscovered(blockedDiscovery)
    #expect(blockedProbe == nil)
    #expect(!other.isAddingSpark)
    #expect(
        !other.shouldPresentDiscoveryAddSheet(probe: blockedProbe),
        "a blocked known card never opens the add sheet"
    )
}
