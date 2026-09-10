import Foundation
import Network
import SparkAPI
import SparkCore
import SparkDiscovery
import SparkLibrary
import Testing
@testable import SparkAppComposition

// MARK: - Local deletion

@MainActor
@Test func removingACardIsLocalOnlyAndPersisted() async throws {
    let store = try SwiftDataLibraryStore()
    let model = RetailOnboardingModel(
        library: SparkLibrary(store: store),
        identityResolver: CompositionLibraryTestFakeIdentityResolver(.failure(.unbound))
    )
    model.library.reconcile(compositionLibraryTestSeedTarget(node: 1, host: "spark-a1b2.local"))
    model.library.reconcile(compositionLibraryTestSeedTarget(node: 3, host: "spark-e5f6.local"))
    let removedID = model.library.entry(containing: compositionLibraryTestCompositionNodeID(1))!.id

    model.removeLibraryEntry(removedID)

    #expect(model.library.entries.count == 1)
    #expect(
        model.library.entry(containing: compositionLibraryTestCompositionNodeID(3)) != nil,
        "the other card is untouched"
    )

    let reloaded = SparkLibrary(store: store)
    reloaded.load()
    #expect(reloaded.entries.count == 1, "deletion is persisted across relaunch")
    #expect(reloaded.entry(containing: compositionLibraryTestCompositionNodeID(1)) == nil)
}

// MARK: - Removal and retry recovery

@MainActor
@Test func setupFailureStaysActionableWithoutOpeningOrMinting() async throws {
    let store = try SwiftDataLibraryStore()
    let model = RetailOnboardingModel(
        library: SparkLibrary(store: store),
        identityResolver: CompositionLibraryTestFakeIdentityResolver(.failure(.unbound))
    )
    model.machineName = "spark-a1b2"

    await model.completeSetup()

    #expect(model.state.issue == .identityUnavailable, "the flow stays actionable")
    #expect(model.dashboardModel == nil, "no dashboard is opened before authentication")
    #expect(model.library.entries.isEmpty, "no unverified card is minted")

    // Retry returns the flow to the verification phase and clears the issue.
    model.retry()
    #expect(model.state.issue == nil)
    #expect(model.state.phase == .ready, "retry re-attempts verification at .ready")
}

@MainActor
@Test func unboundProbeNeverLosesASavedSpark() async throws {
    let store = try SwiftDataLibraryStore()
    let model = RetailOnboardingModel(
        library: SparkLibrary(store: store),
        identityResolver: CompositionLibraryTestFakeIdentityResolver(.failure(.unbound))
    )
    model.library.reconcile(compositionLibraryTestSeedTarget(node: 1, host: "spark-a1b2.local"))
    let entryID = model.library.entries[0].id

    let task = model.openLibraryEntry(entryID)
    await task?.value

    #expect(
        model.library.entry(id: entryID)?.standaloneNodeID
            == compositionLibraryTestCompositionNodeID(1),
        "the saved Spark survives the probe"
    )
    #expect(
        model.library.entry(id: entryID)?.issue != .identityMismatch,
        "unbound is not identity evidence"
    )
    #expect(model.library.entries.count == 1)
}

@MainActor
@Test func defaultResolverKeepsCardsAcrossRestart() throws {
    let store = try SwiftDataLibraryStore()
    let first = RetailOnboardingModel(
        library: SparkLibrary(store: store),
        identityResolver: CompositionLibraryTestFakeIdentityResolver(.failure(.unbound))
    )
    first.library.reconcile(compositionLibraryTestSeedTarget(node: 1, host: "spark-a1b2.local"))
    first.library.reconcile(compositionLibraryTestSeedTarget(node: 3, host: "spark-e5f6.local"))

    // Reload the production library without allowing deferred probes to alter saved state.
    let restarted = RetailOnboardingModel(library: SparkLibrary(store: store))
    #expect(restarted.library.entries.count == 2, "cards survive restart")
    #expect(restarted.library.entry(containing: compositionLibraryTestCompositionNodeID(1)) != nil)
    #expect(restarted.library.entry(containing: compositionLibraryTestCompositionNodeID(3)) != nil)
}

@MainActor
@Test func removalWorksForCardsWithoutRoutes() throws {
    let store = try SwiftDataLibraryStore()
    let model = RetailOnboardingModel(
        library: SparkLibrary(store: store),
        identityResolver: CompositionLibraryTestFakeIdentityResolver(.failure(.unbound))
    )
    // A worker-only cluster card has no coordinator route.
    model.library.reconcile(
        AuthenticatedTarget(
            nodeID: compositionLibraryTestCompositionNodeID(2),
            clusterID: SparkClusterID(
                rawValue: compositionLibraryTestCompositionNodeID(9).rawValue
            ),
            name: "Worker Node",
            role: .worker,
            authorityFingerprint: "fp",
            displayName: "spark-b2c3",
            routes: []
        )
    )
    #expect(model.library.entries[0].canOpen == false)

    model.removeLibraryEntry(model.library.entries[0].id)

    #expect(model.library.entries.isEmpty, "removal works even with no usable route")
}

@MainActor
@Test func closeDashboardReturnsToTheLibrary() async throws {
    let model = try compositionLibraryTestMakeModel(
        resolver: CompositionLibraryTestFakeIdentityResolver(
            .success(
                compositionLibraryTestAuthenticated(compositionLibraryTestIdentityJSON(node: 1))
            )
        )
    )
    model.library.reconcile(compositionLibraryTestSeedTarget(node: 1, host: "spark-a1b2.local"))
    let task = model.openLibraryEntry(model.library.entries[0].id)
    await task?.value
    #expect(model.dashboardModel != nil)

    model.closeDashboard()

    #expect(model.dashboardModel == nil)
    #expect(!model.isAddingSpark)
    #expect(model.library.entries.count == 1, "the card remains in the library")
}

@MainActor
@Test func manualSavedSparkOpenShowsFailureAndSuccessfulRetryClearsIt() async throws {
    let resolver = CompositionLibraryTestRecoveringOpenResolver(
        identity: try compositionLibraryTestAuthenticated(
            compositionLibraryTestIdentityJSON(node: 1)
        )
    )
    let model = try compositionLibraryTestMakeModel(resolver: resolver)
    model.library.reconcile(compositionLibraryTestSeedTarget(node: 1, host: "spark-a1b2.local"))
    let entryID = try #require(model.library.entries.first?.id)
    let attempt = try #require(model.openLibraryEntry(entryID))
    #expect(model.openingLibraryEntryID == entryID)
    await attempt.value
    #expect(model.openingLibraryEntryID == nil)
    #expect(model.dashboardModel == nil)
    #expect(model.libraryOpenFailure?.entryID == entryID)
    #expect(model.libraryOpenFailure?.reason == .authentication)
    #expect(model.library.entry(id: entryID)?.connectionState == .offlineCached)
    await resolver.allowAuthentication()
    let retry = try #require(model.openLibraryEntry(entryID))
    #expect(model.libraryOpenFailure == nil)
    await retry.value
    #expect(model.dashboardModel != nil)
    #expect(model.libraryOpenFailure == nil)
    #expect(model.openingLibraryEntryID == nil)
}

@MainActor
@Test func backgroundSavedSparkFailureDoesNotPublishManualOpenFeedback() async throws {
    let model = try compositionLibraryTestMakeModel(
        resolver: CompositionLibraryTestGenericThrowingResolver()
    )
    model.library.reconcile(compositionLibraryTestSeedTarget(node: 1, host: "spark-a1b2.local"))
    let entryID = try #require(model.library.entries.first?.id)
    #expect(await model.updateFromProbe(entryID: entryID) == false)
    #expect(model.libraryOpenFailure == nil)
    #expect(model.openingLibraryEntryID == nil)
    await model.refreshSavedSparks()
    #expect(model.libraryOpenFailure == nil)
    #expect(model.openingLibraryEntryID == nil)
}
