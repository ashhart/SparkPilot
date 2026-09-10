import Foundation
import SparkCore
import Testing

@testable import SparkAppComposition

// Checks what Home decides to show, without a view, so duplication is caught as a value not a screenshot.

private typealias Fixtures = FleetPresentationTestFleetFixtures

private func homePresentation(
    _ snapshots: [TargetOperationalSnapshot],
    customization: FleetDashboardCustomization = FleetDashboardCustomization()
) -> FleetHomePresentation {
    let overview = FleetOverviewBuilder.build(
        targets: snapshots.enumerated().map { index, snapshot in
            FleetOverviewTarget(entryID: "entry-\(index)", snapshot: snapshot)
        },
        at: Fixtures.now
    )
    return FleetHomeBuilder.build(overview: overview, customization: customization)
}

private func loadingSpark(name: String = "Studio Spark", stage: String?, progress: Double?)
    -> TargetOperationalSnapshot
{
    let base = Fixtures.online(name: name, inference: .loading)
    return Fixtures.rebuilt(
        base,
        operations: [
            TargetOperationSnapshot(
                id: SparkOperationID(rawValue: UUID()),
                kind: "model.load",
                state: .running,
                progress: progress,
                stage: stage,
                errorCode: nil,
                cancellable: true
            )
        ]
    )
}

@Test func homeShowsTheCustomizableOverviewForOneSpark() throws {
    let home = homePresentation([Fixtures.online(temperatureCelsius: 38)])

    #expect(home.mode == .single)
    #expect(home.rollUp.count == 4)
    #expect(home.fleetCards == FleetCardKind.allCases)
    let card = try #require(home.sparks.first)
    #expect(home.sparks.count == 1)
    #expect(card.name == "Studio Spark")
    #expect(card.entryID == "entry-0")
    #expect(card.connection.value == "On your network")
    #expect(card.metrics.map(\.key.reading) == [.model, .memory, .temperature])
    #expect(card.freshness.contains(FleetFormat.elapsed(5).lowercased()))
}

@Test func homeOmitsReadingsTheSparkDoesNotReport() throws {
    let home = homePresentation([Fixtures.online()])

    let card = try #require(home.sparks.first)
    #expect(!card.metrics.map(\.key.reading).contains(.temperature))
}

@Test func homeRollsUpOnceThenGivesEverySparkItsOwnCard() throws {
    let home = homePresentation([
        Fixtures.online(name: "Studio Spark", seed: 1, temperatureCelsius: 38),
        Fixtures.online(name: "Loft Spark", seed: 2, temperatureCelsius: 51),
    ])

    #expect(home.mode == .fleet)
    #expect(home.rollUp.map(\.key.reading) == [.online, .model, .memory, .temperature])
    #expect(home.rollUp.allSatisfy { $0.key.scope == FleetHomeMetricKey.fleetScope })
    #expect(home.sparks.map(\.name) == ["Loft Spark", "Studio Spark"])
    #expect(home.sparks.allSatisfy { !$0.metrics.isEmpty })
}

@Test func theInferenceTileCountsOnlyTheSparksActuallyServing() throws {
    let home = homePresentation([
        Fixtures.online(name: "Example Spark", seed: 1, temperatureCelsius: 38),
        loadingSpark(stage: "health_check", progress: 0.62),
    ])

    let tile = try #require(home.rollUp.first { $0.key.reading == .model })
    #expect(tile.value == "1 running")
    #expect(home.overview.runningInferenceCount == 1)
    #expect(home.sparks.filter { $0.action.offersAButton }.count == 1)
}

@Test func summaryAndSparkReadingsHaveStableDistinctIdentities() {
    let fleets: [[TargetOperationalSnapshot]] = [
        [Fixtures.online(temperatureCelsius: 38)],
        [
            Fixtures.online(name: "Studio Spark", seed: 1, temperatureCelsius: 38),
            Fixtures.offline(name: "Garage Spark", seed: 3),
            Fixtures.degradedCluster(),
        ],
        [
            Fixtures.online(name: "Studio Spark", seed: 1),
            Fixtures.offline(name: "Garage Spark", seed: 3),
        ],
    ]
    for snapshots in fleets {
        let keys = homePresentation(snapshots).metricKeys
        #expect(Set(keys).count == keys.count, "Home repeated a reading")
    }
}

/// The overview count and the selected connectivity detail remain available together.
@Test func theOnlineTileRemainsWhenConnectivityDetailsAreSelected() {
    let offline = homePresentation([
        Fixtures.online(name: "Studio Spark", seed: 1),
        Fixtures.offline(name: "Garage Spark", seed: 3),
    ])
    #expect(offline.fleetCards.contains(.connectivity))
    #expect(offline.rollUp.contains { $0.key.reading == .online })
    #expect(offline.unreachableSparkNames == ["Garage Spark"])

    let everyoneOnline = homePresentation([
        Fixtures.online(name: "Studio Spark", seed: 1),
        Fixtures.online(name: "Loft Spark", seed: 2),
    ])
    #expect(everyoneOnline.rollUp.contains { $0.key.reading == .online })

    let cardHidden = homePresentation(
        [
            Fixtures.online(name: "Studio Spark", seed: 1),
            Fixtures.offline(name: "Garage Spark", seed: 3),
        ],
        customization: FleetDashboardCustomization(
            hiddenRawValues: [FleetCardKind.connectivity.rawValue]
        )
    )
    #expect(!cardHidden.fleetCards.contains(.connectivity))
    #expect(
        cardHidden.rollUp.contains { $0.key.reading == .online },
        "with the card turned off the tile is the only place the reading appears"
    )
}

/// BH-49: "2 running" beside one model name reads as one model running.
@Test func theInferenceTileDetailNamesEveryModelItCounts() throws {
    let home = homePresentation([
        Fixtures.online(
            name: "Studio Spark",
            seed: 1,
            placements: [Fixtures.placement(modelID: "m-8b", name: "Compact 8B", state: .running)]
        ),
        Fixtures.online(
            name: "Loft Spark",
            seed: 2,
            placements: [Fixtures.placement(modelID: "m-4b", name: "Tiny 4B", state: .running)]
        ),
    ])
    let tile = try #require(home.rollUp.first { $0.key.reading == .model })
    #expect(tile.value == "2 running")
    let detail = try #require(tile.detail)
    #expect(detail.contains("Compact 8B"))
    #expect(detail.contains("Tiny 4B"))
}

@Test func cardsRemainAvailableWhenTheyHaveNoCurrentReadings() {
    let single = homePresentation([Fixtures.online()])
    #expect(single.fleetCards == FleetCardKind.allCases)
    #expect(single.customisableCards == FleetCardKind.allCases)

    let plainFleet = homePresentation([
        Fixtures.online(name: "Studio Spark", seed: 1),
        Fixtures.online(
            name: "Loft Spark",
            seed: 2,
            placements: [Fixtures.placement(modelID: "m-4b", name: "Tiny 4B", state: .running)]
        ),
    ])
    #expect(plainFleet.fleetCards.contains(.clusters))
    #expect(plainFleet.fleetCards.contains(.connectivity))
    #expect(plainFleet.fleetCards.contains(.loadedModels))
}

@Test func selectedFleetCardsIncludeEveryCategory() {
    let shared = homePresentation([
        Fixtures.online(name: "Studio Spark", seed: 1),
        Fixtures.online(name: "Loft Spark", seed: 2),
    ])
    #expect(shared.fleetCards == FleetCardKind.allCases)

    let withCluster = homePresentation([
        Fixtures.online(name: "Studio Spark", seed: 1),
        Fixtures.degradedCluster(),
    ])
    #expect(withCluster.fleetCards.contains(.clusters))

    let withOffline = homePresentation([
        Fixtures.online(name: "Studio Spark", seed: 1),
        Fixtures.offline(name: "Garage Spark", seed: 3),
    ])
    #expect(withOffline.fleetCards.contains(.connectivity))
    #expect(withOffline.unreachableSparkNames == ["Garage Spark"])
}

@Test func theModelActionFollowsWhatTheSparkIsDoing() throws {
    let idle = homePresentation([
        Fixtures.online(
            placements: [
                Fixtures.placement(modelID: "m-8b", name: "Compact 8B", state: .installed)
            ],
            inference: .unloaded
        )
    ])
    #expect(try #require(idle.sparks.first).action == .launch)

    let running = homePresentation([Fixtures.online()])
    #expect(try #require(running.sparks.first).action == .switchModel)

    let loading = homePresentation([loadingSpark(stage: "health_check", progress: 0.42)])
    let action = try #require(loading.sparks.first).action
    guard case .loading(let line, let fraction) = action else {
        Issue.record("A loading Spark should offer no button, only its progress: \(action)")
        return
    }
    #expect(line.contains("Compact 8B"))
    #expect(line.contains("42"))
    #expect(fraction == 0.42)
}

@Test func aSparkWithNothingInstalledIsOfferedNoModelAction() throws {
    let home = homePresentation([Fixtures.online(placements: [], inference: .unloaded)])
    #expect(try #require(home.sparks.first).action == .none)
}

@Test func customizationOffersEveryCardEvenWithOneSpark() {
    var hidden = FleetDashboardCustomization()
    hidden.setHidden(.loadedModels, true)
    let fleet = [
        Fixtures.online(name: "Studio Spark", seed: 1),
        Fixtures.online(name: "Loft Spark", seed: 2),
    ]

    #expect(homePresentation(fleet).customisableCards == FleetCardKind.allCases)
    #expect(!homePresentation(fleet, customization: hidden).fleetCards.contains(.loadedModels))
    #expect(
        homePresentation(fleet, customization: hidden).customisableCards == FleetCardKind.allCases
    )
    #expect(homePresentation([Fixtures.online()]).customisableCards == FleetCardKind.allCases)
}

@Test func homeNamesTheSparkAndItsReadingsForVoiceOver() throws {
    let card = try #require(
        homePresentation([Fixtures.online(temperatureCelsius: 38)]).sparks.first
    )
    #expect(card.accessibilityLabel.contains("Studio Spark"))
    #expect(card.accessibilityLabel.contains("On your network"))
    #expect(card.accessibilityLabel.contains("Compact 8B"))
}

@Test func theConnectionLineNamesTheRouteTheSparkIsAnsweringOn() throws {
    let local = try #require(homePresentation([Fixtures.online()]).sparks.first)
    #expect(local.connection.value == "On your network")
    #expect(local.connection.detail == nil)
    #expect(local.connection.symbol == "house.fill")

    let remote = try #require(homePresentation([Fixtures.overTailscale()]).sparks.first)
    #expect(remote.connection.value == "Over Tailscale · spark-example.tail1234.ts.net")
    #expect(remote.connection.symbol == "lock.shield.fill")
    #expect(remote.accessibilityLabel.contains("spark-example.tail1234.ts.net"))
}

@Test func aSparkThatIsNotSimplyConnectedKeepsItsStateAndStillNamesTheRoute() throws {
    let slow = Fixtures.rebuilt(Fixtures.overTailscale(), connectionState: .delayed)
    let delayed = try #require(homePresentation([slow]).sparks.first)
    #expect(delayed.connection.value == "Answering slowly")
    #expect(delayed.connection.detail == "Over Tailscale · spark-example.tail1234.ts.net")
    #expect(delayed.connection.symbol == "clock.badge.exclamationmark")

    let offline = try #require(homePresentation([Fixtures.offline()]).sparks.first)
    #expect(offline.connection.value == "Offline · showing saved state")
    #expect(offline.connection.detail == nil)
}
