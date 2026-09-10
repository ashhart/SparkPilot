import Foundation
import SparkCore
import SparkLibrary
import Testing

@testable import SparkAppComposition

// MARK: - Live model

@MainActor
@Test func fleetModelReadsTheLocalLibraryAndKeepsFiltersAcrossReads() {
    let store = MemoryLibraryStore()
    let library = SparkLibrary(store: store, now: { FleetPresentationTestFleetFixtures.now })
    let node = FleetPresentationTestFleetFixtures.nodeID(31)
    library.reconcile(
        AuthenticatedTarget(
            nodeID: node,
            clusterID: nil,
            name: "Studio Spark",
            role: .standalone,
            authorityFingerprint: nil,
            displayName: "studio-spark",
            routes: [
                CachedRoute(
                    baseURL: URL(string: "https://studio-spark.local:7443")!,
                    kind: .localWiFi
                )
            ],
            reachedAt: FleetPresentationTestFleetFixtures.now
        )
    )

    let fleet = FleetModel(library: library, now: { FleetPresentationTestFleetFixtures.now })
    #expect(fleet.presentation.cards.map(\.name) == ["Studio Spark"])

    fleet.query.searchText = "nothing"
    #expect(fleet.presentation.content == .filteredEmpty(totalCount: 1))
    // Reading again does not reset what the owner typed.
    #expect(fleet.query.searchText == "nothing")

    fleet.clearFilters()
    #expect(fleet.presentation.cards.count == 1)
}

@MainActor
@Test func fleetModelSelectionSurvivesReadsAndIsDroppedWhenTheCardGoes() {
    let library = SparkLibrary(
        store: MemoryLibraryStore(),
        now: { FleetPresentationTestFleetFixtures.now }
    )
    let node = FleetPresentationTestFleetFixtures.nodeID(32)
    library.reconcile(
        AuthenticatedTarget(
            nodeID: node,
            clusterID: nil,
            name: "Loft Spark",
            role: .standalone,
            authorityFingerprint: nil,
            displayName: "loft-spark",
            routes: [
                CachedRoute(
                    baseURL: URL(string: "https://loft-spark.local:7443")!,
                    kind: .localWiFi
                )
            ],
            reachedAt: FleetPresentationTestFleetFixtures.now
        )
    )

    let fleet = FleetModel(library: library, now: { FleetPresentationTestFleetFixtures.now })
    let id = SparkTargetIdentity.node(node).description
    fleet.query.connection = .connected
    fleet.selectedID = id
    #expect(fleet.selectedDetails?.title == "Loft Spark")
    // Opening details leaves the filter selection exactly as it was.
    #expect(fleet.query.connection == .connected)
    #expect(fleet.presentation.cards.count == 1)

    fleet.beginCheck(id)
    #expect(fleet.presentation.cards.first?.connection.isChecking == true)
    fleet.endCheck(id)
    #expect(fleet.presentation.cards.first?.connection.isChecking == false)

    fleet.forget(id)
    #expect(fleet.selectedID == nil)
    #expect(fleet.selectedDetails == nil)
}

@MainActor
@Test func anOfflineSparkStaysInTheFleetAfterRelaunch() {
    let store = MemoryLibraryStore()
    let node = FleetPresentationTestFleetFixtures.nodeID(33)
    let first = SparkLibrary(store: store, now: { FleetPresentationTestFleetFixtures.now })
    first.reconcile(
        AuthenticatedTarget(
            nodeID: node,
            clusterID: nil,
            name: "Garage Spark",
            role: .standalone,
            authorityFingerprint: nil,
            displayName: "garage-spark",
            routes: [
                CachedRoute(
                    baseURL: URL(string: "https://garage-spark.local:7443")!,
                    kind: .localWiFi
                )
            ],
            reachedAt: FleetPresentationTestFleetFixtures.now
        )
    )
    #expect(
        FleetModel(library: first, now: { FleetPresentationTestFleetFixtures.now }).presentation
            .cards.count == 1
    )

    // Reloaded cards must downgrade reachability until a fresh authenticated read succeeds.
    let relaunched = SparkLibrary(store: store, now: { FleetPresentationTestFleetFixtures.now })
    relaunched.load()
    let fleet = FleetModel(library: relaunched, now: { FleetPresentationTestFleetFixtures.now })
    let card = fleet.presentation.cards.first

    #expect(card?.name == "Garage Spark")
    #expect(card?.connection.label == "Offline · showing saved state")
    // Removal survives the relaunch too, so a stale card is never stuck.
    #expect(card?.actions.contains(.remove) == true)
}

@Test func aMissingSnapshotComposesAnEntryOnlyAccountInsteadOfNothing() {
    let node = FleetPresentationTestFleetFixtures.nodeID(40)
    let entry = LibraryEntry(
        logicalKey: .node(node),
        name: "Unread Spark",
        members: [
            LibraryMember(
                nodeID: node,
                name: "Unread Spark",
                role: .standalone,
                routes: [
                    CachedRoute(
                        baseURL: URL(string: "https://unread-spark.local:7443")!,
                        kind: .localWiFi
                    )
                ]
            )
        ]
    )

    let target = FleetTargetInput(
        entry: entry,
        snapshot: nil,
        at: FleetPresentationTestFleetFixtures.now
    )
    let card = FleetPresentationBuilder.card(for: target, isChecking: false)

    #expect(target.id == entry.id)
    #expect(card.name == "Unread Spark")
    #expect(card.lastContact == "Unknown")
    #expect(card.availableMemory == "Unknown")
    #expect(card.activeModel == "Unknown")
    #expect(card.installedModels == "Unknown")
    #expect(card.membership == "Single Spark")
    #expect(card.actions == [.open, .checkAgain, .remove])
}

/// Reconcile one authenticated standalone target into `library`.
@MainActor
func fleetPresentationTestAddSpark(
    to library: SparkLibrary,
    seed: UInt8,
    name: String,
    host: String
) -> String {
    let node = FleetPresentationTestFleetFixtures.nodeID(seed)
    library.reconcile(
        AuthenticatedTarget(
            nodeID: node,
            clusterID: nil,
            name: name,
            role: .standalone,
            authorityFingerprint: nil,
            displayName: host,
            routes: [
                CachedRoute(baseURL: URL(string: "https://\(host).local:7443")!, kind: .localWiFi)
            ],
            reachedAt: FleetPresentationTestFleetFixtures.now
        )
    )
    return SparkTargetIdentity.node(node).description
}

@MainActor
@Test func aPairedSparkWithNoOperationalSnapshotStaysVisibleWithUnknownValues() {
    let library = SparkLibrary(
        store: MemoryLibraryStore(),
        now: { FleetPresentationTestFleetFixtures.now }
    )
    let id = fleetPresentationTestAddSpark(
        to: library,
        seed: 41,
        name: "Fresh Spark",
        host: "fresh-spark"
    )

    // Nothing has assembled operational evidence for this entry yet.
    #expect(library.entries.first?.cachedOperationalSnapshot == nil)

    let fleet = FleetModel(library: library, now: { FleetPresentationTestFleetFixtures.now })
    let card = fleet.presentation.cards.first

    // A paired Spark is never dropped for want of an operational snapshot.
    #expect(fleet.presentation.cards.count == library.entries.count)
    #expect(card?.id == id)
    #expect(card?.name == "Fresh Spark")
    // Its operational fields say Unknown rather than inventing a healthy zero.
    #expect(card?.availableMemory == "Unknown")
    #expect(card?.activeModel == "Unknown")
    #expect(card?.installedModels == "Unknown")
    // Preserve open and local-remove actions for saved reachable targets.
    #expect(card?.actions == [.open, .checkAgain, .remove])
    fleet.selectedID = id
    #expect(fleet.selectedDetails?.title == "Fresh Spark")
}

@MainActor
@Test func everyLibraryEntryProducesACardWhateverItsState() {
    let library = SparkLibrary(
        store: MemoryLibraryStore(),
        now: { FleetPresentationTestFleetFixtures.now }
    )
    let routed = fleetPresentationTestAddSpark(
        to: library,
        seed: 42,
        name: "Routed Spark",
        host: "routed-spark"
    )
    let blocked = fleetPresentationTestAddSpark(
        to: library,
        seed: 43,
        name: "Blocked Spark",
        host: "blocked-spark"
    )
    library.markIdentityMismatch(
        entryID: blocked,
        presented: FleetPresentationTestFleetFixtures.nodeID(99),
        at: FleetPresentationTestFleetFixtures.now
    )

    let presentation = FleetModel(library: library, now: { FleetPresentationTestFleetFixtures.now })
        .presentation

    #expect(presentation.totalCount == library.entries.count)
    #expect(Set(presentation.cards.map(\.id)) == [routed, blocked])
    // Keep identity-blocked cards visible with only their valid recovery action.
    let blockedCard = presentation.cards.first { $0.id == blocked }
    #expect(blockedCard?.connection.label == "Identity changed")
    #expect(blockedCard?.actions == [.remove])
}

@MainActor
@Test func fleetModelSurfacesSessionOnlyStorage() {
    let library = SparkLibrary(
        store: MemoryLibraryStore(),
        now: { FleetPresentationTestFleetFixtures.now },
        storageStatusOverride: "the library store could not be opened"
    )
    let fleet = FleetModel(library: library, now: { FleetPresentationTestFleetFixtures.now })

    #expect(fleet.presentation.storageNotice != nil)
    #expect(fleet.presentation.content == .empty)
}

// MARK: - Navigation wiring

@Test func iPadNamesTheHomeDestinationFleetWhileIPhoneKeepsHome() {
    #expect(AppleNavigationSection.home.title(for: .pad) == "Home")
    #expect(AppleNavigationSection.home.title(for: .phone) == "Home")
    #expect(AppleNavigationSection.home.symbol(for: .pad) == "square.grid.2x2")
    #expect(AppleNavigationSection.home.symbol(for: .phone) == "house")
    // Wide comparison destinations use names that match their content.
    #expect(AppleNavigationSection.models.title(for: .pad) == "Models")
    #expect(AppleNavigationSection.activity.title(for: .pad) == "Activity")
    #expect(AppleNavigationSection.activity.symbol(for: .pad) == "clock.arrow.circlepath")
    #expect(AppleNavigationSection.activity.title(for: .phone) == "Activity")
    #expect(
        AppleNavigationSection.activity.symbol(for: .phone) == "clock.arrow.circlepath"
    )
    #expect(!AppleNavigationPlan.showsWorkloads(in: .activity, on: .pad))
    #expect(!AppleNavigationPlan.showsWorkloads(in: .activity, on: .phone))
    #expect(!AppleNavigationPlan.showsWorkloads(in: .models, on: .pad))
    #expect(AppleNavigationPlan.showsModelLibrary(in: .models, on: .phone))
    #expect(AppleNavigationPlan.showsModelLibrary(in: .models, on: .pad))
    #expect(
        AppleNavigationPlan.sidebarSections
            == [.home, .chats, .projects, .models, .clusters, .automations, .activity, .settings]
    )
    #expect(AppleNavigationPlan.phoneTabs == [.home, .chats, .activity, .more])
    #expect(AppleNavigationPlan.phoneMoreSections.contains(.clusters))
}

/// UX-13: a single Spark gets one Filter menu, not four pickers.
@Test func fleetFiltersExpandOnlyForTwoOrMoreSparks() {
    #expect(!FleetFilterPresentation.showsExpandedFilters(totalCount: 0))
    #expect(!FleetFilterPresentation.showsExpandedFilters(totalCount: 1))
    #expect(FleetFilterPresentation.showsExpandedFilters(totalCount: 2))
}

@Test func unpairedNavigationKeepsHelpAndHidesAdvancedDestinations() {
    for engineeringMode in [false, true] {
        #expect(
            AppleNavigationPlan.visibleSections(
                AppleNavigationPlan.sidebarSections,
                hasSparks: false,
                engineeringMode: engineeringMode
            ) == [.home, .chats, .settings]
        )
        #expect(
            AppleNavigationPlan.visibleSections(
                AppleNavigationPlan.phoneMoreSections,
                hasSparks: false,
                engineeringMode: engineeringMode
            ) == [.settings]
        )
    }
    #expect(
        AppleNavigationPlan.visibleSections(
            AppleNavigationPlan.sidebarSections,
            hasSparks: true,
            engineeringMode: false
        ).contains(.models)
    )
    #expect(
        !AppleNavigationPlan.visibleSections(
            AppleNavigationPlan.sidebarSections,
            hasSparks: true,
            engineeringMode: false
        ).contains(.projects)
    )
}

@Test func engineeringModePromotesDevelopWithoutLosingActivity() {
    #expect(
        AppleNavigationPlan.phoneTabs(engineeringMode: true) == [.home, .chats, .projects, .more]
    )
    #expect(
        AppleNavigationPlan.phoneTabs(engineeringMode: false) == [.home, .chats, .activity, .more]
    )
    #expect(AppleNavigationPlan.phoneMoreSections(engineeringMode: true).contains(.activity))
    #expect(!AppleNavigationPlan.phoneMoreSections(engineeringMode: true).contains(.projects))
    #expect(AppleNavigationPlan.phoneSelection(.projects, engineeringMode: false) == .activity)
    #expect(AppleNavigationPlan.phoneSelection(.activity, engineeringMode: true) == .projects)
    #expect(AppleNavigationPlan.phoneSelection(.more, engineeringMode: true) == .more)
}
