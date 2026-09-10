import Foundation
import Network
import SparkAPI
import SparkCore
import SparkDiscovery
import SparkLibrary
import Testing
@testable import SparkAppComposition

@MainActor
@Test func openingBDuringAProbeCannotPublishALate() async throws {
    let model = RetailOnboardingModel(
        library: SparkLibrary(store: try SwiftDataLibraryStore()),
        identityResolver: CompositionLibraryTestRouteKeyedIdentityResolver(
            [
                "spark-a1b2.local": try compositionLibraryTestAuthenticated(
                    compositionLibraryTestIdentityJSON(node: 1)
                ),
                "spark-c3d4.local": try compositionLibraryTestAuthenticated(
                    compositionLibraryTestIdentityJSON(node: 3)
                ),
            ],
            slowHost: "spark-a1b2.local"
        )
    )
    model.library.reconcile(compositionLibraryTestSeedTarget(node: 1, host: "spark-a1b2.local"))
    model.library.reconcile(compositionLibraryTestSeedTarget(node: 3, host: "spark-c3d4.local"))
    let idA = model.library.entry(containing: compositionLibraryTestCompositionNodeID(1))!.id
    let idB = model.library.entry(containing: compositionLibraryTestCompositionNodeID(3))!.id

    let taskA = model.openLibraryEntry(idA)  // slow
    let taskB = model.openLibraryEntry(idB)  // fast; supersedes A
    await taskB?.value
    #expect(model.dashboardModel?.route.host == "spark-c3d4.local")

    await taskA?.value
    #expect(
        model.dashboardModel?.route.host == "spark-c3d4.local",
        "the superseded A probe must not publish a late dashboard"
    )
}

@MainActor
@Test func removingACardDuringAuthenticationCannotOpenIt() async throws {
    let model = RetailOnboardingModel(
        library: SparkLibrary(store: try SwiftDataLibraryStore()),
        identityResolver: CompositionLibraryTestRouteKeyedIdentityResolver(
            [
                "spark-a1b2.local": try compositionLibraryTestAuthenticated(
                    compositionLibraryTestIdentityJSON(node: 1)
                )
            ],
            slowHost: "spark-a1b2.local"
        )
    )
    model.library.reconcile(compositionLibraryTestSeedTarget(node: 1, host: "spark-a1b2.local"))
    let entryID = model.library.entries[0].id

    let task = model.openLibraryEntry(entryID)
    model.removeLibraryEntry(entryID)  // cancels the probe and removes the card

    await task?.value
    #expect(model.dashboardModel == nil, "a removed card can never open")
    #expect(model.library.entries.isEmpty)
}

@MainActor
@Test func closingDashboardDuringAuthenticationStaysInTheLibrary() async throws {
    let model = RetailOnboardingModel(
        library: SparkLibrary(store: try SwiftDataLibraryStore()),
        identityResolver: CompositionLibraryTestRouteKeyedIdentityResolver(
            [
                "spark-a1b2.local": try compositionLibraryTestAuthenticated(
                    compositionLibraryTestIdentityJSON(node: 1)
                )
            ],
            slowHost: "spark-a1b2.local"
        )
    )
    model.library.reconcile(compositionLibraryTestSeedTarget(node: 1, host: "spark-a1b2.local"))
    let entryID = model.library.entries[0].id

    let task = model.openLibraryEntry(entryID)
    model.closeDashboard()

    await task?.value
    #expect(model.dashboardModel == nil, "backing out stays on Your Sparks")
    #expect(!model.isAddingSpark)
    let card = model.library.entry(id: entryID)
    #expect(card != nil, "the card remains in the library")
    #expect(
        card?.connectionState == .connectedWiFi,
        "cancelling a probe is not reachability evidence; the session state is untouched"
    )
    #expect(card?.issue == nil)
    #expect(model.openingLibraryEntryID == nil)
    #expect(
        model.libraryOpenFailure == nil,
        "a cancelled manual open must not leave failure feedback"
    )
}

@MainActor
@Test func startingAddSparkDuringAuthenticationStaysInSetup() async throws {
    let model = RetailOnboardingModel(
        library: SparkLibrary(store: try SwiftDataLibraryStore()),
        identityResolver: CompositionLibraryTestRouteKeyedIdentityResolver(
            [
                "spark-a1b2.local": try compositionLibraryTestAuthenticated(
                    compositionLibraryTestIdentityJSON(node: 1)
                )
            ],
            slowHost: "spark-a1b2.local"
        )
    )
    model.library.reconcile(compositionLibraryTestSeedTarget(node: 1, host: "spark-a1b2.local"))
    let entryID = model.library.entries[0].id

    let task = model.openLibraryEntry(entryID)
    model.startAddingSpark()  // cancels the probe and enters the add flow

    await task?.value
    #expect(model.isAddingSpark, "Add Spark stays in the setup flow")
    #expect(model.dashboardModel == nil, "no late dashboard escapes into setup")
}

@MainActor
@Test func cancelledProbeSurfacingURLErrorCannotMarkTheCardOffline() async throws {
    let model = RetailOnboardingModel(
        library: SparkLibrary(store: try SwiftDataLibraryStore()),
        identityResolver: CompositionLibraryTestCancelIgnoringURLErrorResolver()
    )
    model.library.reconcile(compositionLibraryTestSeedTarget(node: 1, host: "spark-a1b2.local"))
    let entryID = model.library.entries[0].id

    let task = model.openLibraryEntry(entryID)
    model.closeDashboard()  // cancels the probe

    await task?.value

    let card = model.library.entry(id: entryID)
    #expect(model.dashboardModel == nil)
    #expect(
        card?.connectionState == .connectedWiFi,
        "a cancelled probe surfacing URLError.cancelled never marks the card offline"
    )
    #expect(card?.issue == nil)
    #expect(card?.reachableMemberCount == 1)
    #expect(model.openingLibraryEntryID == nil)
    #expect(model.libraryOpenFailure == nil)
}

@MainActor
@Test func blockedIdentityMismatchCardCannotProbeOrPublish() async throws {
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

    let task = model.openLibraryEntry(entryID)

    #expect(task == nil, "a blocked card cannot even start a probe")
    #expect(model.dashboardModel == nil, "a blocked card can never publish a dashboard")
    let card = model.library.entry(id: entryID)
    #expect(card?.issue == .identityMismatch)
    #expect(card?.canOpen == false)
    #expect(card?.connectionState == .identityMismatch)
}
