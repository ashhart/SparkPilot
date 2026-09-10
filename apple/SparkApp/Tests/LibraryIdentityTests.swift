import Foundation
import Network
import SparkAPI
import SparkCore
import SparkDiscovery
import SparkLibrary
import Testing
@testable import SparkAppComposition

// MARK: - Same-host attacker cannot replace a stored node

@MainActor
@Test func sameHostAttackerCannotReplaceAStoredNode() async throws {
    // Return a different authenticated full node ID from the host stored for a paired card.
    let model = try compositionLibraryTestMakeModel(
        resolver: CompositionLibraryTestFakeIdentityResolver(
            .failure(.nodeMismatch(presented: compositionLibraryTestCompositionNodeID(2)))
        )
    )
    model.library.reconcile(compositionLibraryTestSeedTarget(node: 1, host: "spark-a1b2.local"))
    let entryID = model.library.entries[0].id

    let task = model.openLibraryEntry(entryID)
    await task?.value

    let card = model.library.entry(id: entryID)
    #expect(card?.issue == .identityMismatch, "the stored card is blocked for review")
    #expect(
        card?.standaloneNodeID == compositionLibraryTestCompositionNodeID(1),
        "the stored node identity is never swapped"
    )
    #expect(model.library.entry(containing: compositionLibraryTestCompositionNodeID(1)) != nil)
    #expect(
        model.library.entry(containing: compositionLibraryTestCompositionNodeID(2)) == nil,
        "the attacker node is never added"
    )
    #expect(model.library.entries.count == 1)
}

@MainActor
@Test func authenticatedProbeEnforcesTheStoredIdentityEvenIfTheResolverSlipped() async throws {
    let model = try compositionLibraryTestMakeModel(
        resolver: CompositionLibraryTestFakeIdentityResolver(
            .success(
                compositionLibraryTestAuthenticated(compositionLibraryTestIdentityJSON(node: 2))
            )
        )
    )
    model.library.reconcile(compositionLibraryTestSeedTarget(node: 1, host: "spark-a1b2.local"))
    let entryID = model.library.entries[0].id

    let task = model.openLibraryEntry(entryID)
    await task?.value

    let card = model.library.entry(id: entryID)
    #expect(card?.issue == .identityMismatch)
    #expect(model.library.entry(containing: compositionLibraryTestCompositionNodeID(1)) != nil)
}

@MainActor
@Test func unauthenticatedProbeLeavesTheCardOfflineCached() async throws {
    let model = try compositionLibraryTestMakeModel(
        resolver: CompositionLibraryTestFakeIdentityResolver(.failure(.pinRejected))
    )
    model.library.reconcile(compositionLibraryTestSeedTarget(node: 1, host: "spark-a1b2.local"))
    let entryID = model.library.entries[0].id

    let task = model.openLibraryEntry(entryID)
    await task?.value

    let card = model.library.entry(id: entryID)
    #expect(
        card?.connectionState == .offlineCached,
        "an unauthenticated probe downgrades, never upgrades"
    )
    #expect(card?.issue == nil)
    #expect(card?.standaloneNodeID == compositionLibraryTestCompositionNodeID(1))
}

@MainActor
@Test func dashboardStaysClosedUntilAuthenticationCompletes() async throws {
    let model = RetailOnboardingModel(
        library: SparkLibrary(store: try SwiftDataLibraryStore()),
        identityResolver: CompositionLibraryTestDelayedIdentityResolver(
            try compositionLibraryTestAuthenticated(compositionLibraryTestIdentityJSON(node: 1))
        )
    )
    model.library.reconcile(compositionLibraryTestSeedTarget(node: 1, host: "spark-a1b2.local"))
    let entryID = model.library.entries[0].id

    let task = model.openLibraryEntry(entryID)
    #expect(model.dashboardModel == nil, "no dashboard is published before the resolver returns")

    await task?.value

    #expect(model.dashboardModel != nil, "the dashboard appears only after a successful match")
    #expect(model.library.entry(id: entryID)?.connectionState == .connectedWiFi)
}

@MainActor
@Test(arguments: [
    AuthenticatedIdentityError.unbound,
    AuthenticatedIdentityError.pinRejected,
    AuthenticatedIdentityError.nodeMismatch(presented: compositionLibraryTestCompositionNodeID(2)),
])
func dashboardStaysClosedOnEveryAuthenticationFailure(
    _ failure: AuthenticatedIdentityError
) async throws {
    let model = RetailOnboardingModel(
        library: SparkLibrary(store: try SwiftDataLibraryStore()),
        identityResolver: CompositionLibraryTestFakeIdentityResolver(.failure(failure))
    )
    model.library.reconcile(compositionLibraryTestSeedTarget(node: 1, host: "spark-a1b2.local"))
    let entryID = model.library.entries[0].id

    let task = model.openLibraryEntry(entryID)
    await task?.value

    #expect(model.dashboardModel == nil, "no dashboard on \(failure)")
    let card = model.library.entry(id: entryID)
    switch failure {
    case .nodeMismatch:
        #expect(card?.issue == .identityMismatch)
    case .pinRejected:
        #expect(card?.connectionState == .offlineCached)
    case .unbound:
        #expect(card?.issue == nil)
        #expect(
            card?.connectionState == .connectedWiFi,
            "unbound is not auth evidence; the session state stays untouched"
        )
    }
}

@MainActor
@Test func dashboardStaysClosedOnGenericFailure() async throws {
    let model = RetailOnboardingModel(
        library: SparkLibrary(store: try SwiftDataLibraryStore()),
        identityResolver: CompositionLibraryTestGenericThrowingResolver()
    )
    model.library.reconcile(compositionLibraryTestSeedTarget(node: 1, host: "spark-a1b2.local"))
    let entryID = model.library.entries[0].id

    let task = model.openLibraryEntry(entryID)
    await task?.value

    #expect(model.dashboardModel == nil)
    #expect(model.library.entry(id: entryID)?.connectionState == .offlineCached)
    #expect(
        model.library.entry(id: entryID)?.standaloneNodeID
            == compositionLibraryTestCompositionNodeID(1)
    )
}
