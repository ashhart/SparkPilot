import Foundation
import SparkCore
import SparkLibrary
import Testing

@testable import SparkAppComposition

// MARK: - Search and filters

@Test func searchMatchesFriendlyNameCaseAndDiacriticInsensitively() {
    let targets = [
        FleetPresentationTestFleetFixtures.input(
            FleetPresentationTestFleetFixtures.online(name: "Café Spark")
        ),
        FleetPresentationTestFleetFixtures.input(
            FleetPresentationTestFleetFixtures.offline(name: "Garage Spark")
        ),
    ]

    let presentation = FleetPresentationBuilder.build(
        targets: targets,
        query: FleetQuery(searchText: "cafe")
    )

    #expect(presentation.cards.map(\.name) == ["Café Spark"])
    #expect(presentation.visibleCount == 1)
    #expect(presentation.totalCount == 2)
}

@Test func searchAlsoMatchesClusterMemberNames() {
    let presentation = FleetPresentationBuilder.build(
        targets: [
            FleetPresentationTestFleetFixtures.input(
                FleetPresentationTestFleetFixtures.degradedCluster()
            ),
            FleetPresentationTestFleetFixtures.input(FleetPresentationTestFleetFixtures.online()),
        ],
        query: FleetQuery(searchText: "worker one")
    )

    #expect(presentation.cards.map(\.name) == ["Studio Cluster"])
}

@Test func connectionFilterSeparatesConnectedDelayedAndOffline() {
    let targets = [
        FleetPresentationTestFleetFixtures.input(FleetPresentationTestFleetFixtures.online()),
        FleetPresentationTestFleetFixtures.input(FleetPresentationTestFleetFixtures.delayed()),
        FleetPresentationTestFleetFixtures.input(FleetPresentationTestFleetFixtures.offline()),
    ]

    func names(_ filter: FleetConnectionFilter) -> [String] {
        FleetPresentationBuilder.build(
            targets: targets,
            query: FleetQuery(connection: filter)
        ).cards.map(\.name)
    }

    #expect(names(.connected) == ["Studio Spark"])
    #expect(names(.delayed) == ["Loft Spark"])
    #expect(names(.offline) == ["Garage Spark"])
    #expect(Set(names(.needsAttention)) == ["Loft Spark", "Garage Spark"])
    #expect(names(.any).count == 3)
}

@Test func updateFilterSelectsByRuntimeUpdateState() {
    let targets = [
        FleetPresentationTestFleetFixtures.input(
            FleetPresentationTestFleetFixtures.online(name: "Current", updateState: .current)
        ),
        FleetPresentationTestFleetFixtures.input(
            FleetPresentationTestFleetFixtures.online(
                name: "Newer available",
                seed: 7,
                updateState: .available
            )
        ),
        FleetPresentationTestFleetFixtures.input(
            FleetPresentationTestFleetFixtures.withoutEvidence(name: "No evidence"),
            canOpen: false
        ),
    ]

    func names(_ filter: FleetUpdateFilter) -> [String] {
        FleetPresentationBuilder.build(targets: targets, query: FleetQuery(update: filter))
            .cards.map(\.name)
    }

    #expect(names(.current) == ["Current"])
    #expect(names(.updateAvailable) == ["Newer available"])
    #expect(names(.unknown) == ["No evidence"])
    #expect(names(.updateRequired).isEmpty)
}

@Test func membershipFilterSeparatesSingleSparksFromClusters() {
    let targets = [
        FleetPresentationTestFleetFixtures.input(FleetPresentationTestFleetFixtures.online()),
        FleetPresentationTestFleetFixtures.input(
            FleetPresentationTestFleetFixtures.degradedCluster()
        ),
    ]

    #expect(
        FleetPresentationBuilder.build(
            targets: targets,
            query: FleetQuery(membership: .standalone)
        ).cards.map(\.name) == ["Studio Spark"]
    )
    #expect(
        FleetPresentationBuilder.build(
            targets: targets,
            query: FleetQuery(membership: .cluster)
        ).cards.map(\.name) == ["Studio Cluster"]
    )
}

@Test func installedModelFilterOffersAndMatchesInstalledRecipesOnly() {
    let downloading = FleetPresentationTestFleetFixtures.online(
        name: "Downloading Spark",
        seed: 8,
        placements: [
            FleetPresentationTestFleetFixtures.placement(
                modelID: "m-13b",
                name: "Middle 13B",
                state: .downloading
            )
        ],
        inference: .unloaded
    )
    let targets = [
        FleetPresentationTestFleetFixtures.input(FleetPresentationTestFleetFixtures.online()),
        FleetPresentationTestFleetFixtures.input(
            FleetPresentationTestFleetFixtures.degradedCluster()
        ),
        FleetPresentationTestFleetFixtures.input(downloading),
    ]

    let presentation = FleetPresentationBuilder.build(targets: targets)
    // A model that is still downloading is not installed anywhere yet.
    #expect(presentation.installedModelOptions == ["Compact 8B", "Wide 70B"])

    #expect(
        FleetPresentationBuilder.build(
            targets: targets,
            query: FleetQuery(installedModel: "Wide 70B")
        ).cards.map(\.name) == ["Studio Cluster"]
    )
}

@Test func filtersThatMatchNothingProduceARecoverableEmptyState() {
    let presentation = FleetPresentationBuilder.build(
        targets: [
            FleetPresentationTestFleetFixtures.input(FleetPresentationTestFleetFixtures.online())
        ],
        query: FleetQuery(searchText: "nothing like this")
    )

    #expect(presentation.content == .filteredEmpty(totalCount: 1))
    #expect(presentation.visibleCount == 0)
    // The summary keeps describing the whole fleet, not the empty result.
    #expect(presentation.summary.targetCount == 1)
    #expect(presentation.summary.connectedCount == 1)
}

@Test func clearingFiltersIsDetectableFromTheQuery() {
    #expect(!FleetQuery.unfiltered.isFiltering)
    #expect(FleetQuery(searchText: "  ").isFiltering == false)
    #expect(FleetQuery(searchText: "loft").isFiltering)
    #expect(FleetQuery(connection: .offline).isFiltering)
    #expect(FleetQuery(update: .updateRequired).isFiltering)
    #expect(FleetQuery(installedModel: "Compact 8B").isFiltering)
    #expect(FleetQuery(membership: .cluster).isFiltering)
}

// MARK: - Ordering

@Test func cardsThatNeedAttentionSortAheadOfHealthyOnes() {
    let presentation = FleetPresentationBuilder.build(targets: [
        FleetPresentationTestFleetFixtures.input(
            FleetPresentationTestFleetFixtures.online(name: "Aaa Healthy")
        ),
        FleetPresentationTestFleetFixtures.input(
            FleetPresentationTestFleetFixtures.offline(name: "Zzz Offline")
        ),
        FleetPresentationTestFleetFixtures.input(
            FleetPresentationTestFleetFixtures.identityMismatch(name: "Mmm Blocked"),
            canOpen: false,
            hasIdentityIssue: true
        ),
    ])

    #expect(presentation.cards.map(\.name) == ["Mmm Blocked", "Zzz Offline", "Aaa Healthy"])
}

@Test func cardOrderIsStableForEquallyUrgentTargets() {
    let first = FleetPresentationTestFleetFixtures.input(
        FleetPresentationTestFleetFixtures.online(name: "Beta", seed: 21)
    )
    let second = FleetPresentationTestFleetFixtures.input(
        FleetPresentationTestFleetFixtures.online(name: "alpha", seed: 22)
    )

    #expect(
        FleetPresentationBuilder.build(targets: [first, second]).cards.map(\.name)
            == ["alpha", "Beta"]
    )
    #expect(
        FleetPresentationBuilder.build(targets: [second, first]).cards.map(\.name)
            == ["alpha", "Beta"]
    )
}
