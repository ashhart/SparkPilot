import Foundation
import SparkCore
import Testing
@testable import SparkAppComposition

@MainActor
@Test func restoringASavedSingleSparkDashboardKeepsEveryCardAndItsOrder() throws {
    let suite = "dashboard-restore-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = FleetDashboardStore(defaults: defaults)
    let saved = FleetDashboardCustomization(
        order: [
            .temperatures, .fleetMemory, .runningInference, .connectivity, .loadedModels, .clusters,
        ],
        hiddenRawValues: [FleetCardKind.clusters.rawValue]
    )
    store.save(saved)
    let model = FleetDashboardModel(store: store)
    let overview = FleetOverviewBuilder.build(
        from: [FleetPresentationTestFleetFixtures.online()],
        at: FleetPresentationTestFleetFixtures.now
    )
    let home = FleetHomeBuilder.build(overview: overview, customization: model.customization)
    #expect(home.showsAnyFleetSection)
    #expect(home.rollUp.map(\.key.reading) == [.online, .model, .memory, .temperature])
    #expect(home.fleetCards == saved.visibleCards)
    #expect(home.customisableCards == FleetCardKind.allCases)
    #expect(store.load() == saved)
}

@Test func hidingAllDashboardCardsStillLeavesTheOverviewAndCustomizationReachable() {
    let home = FleetHomeBuilder.build(
        overview: FleetOverviewBuilder.build(
            from: [FleetPresentationTestFleetFixtures.online()],
            at: FleetPresentationTestFleetFixtures.now
        ),
        customization: FleetDashboardCustomization(
            hiddenRawValues: Set(FleetCardKind.allCases.map(\.rawValue))
        )
    )
    #expect(home.fleetCards.isEmpty)
    #expect(home.showsAnyFleetSection)
    #expect(home.customisableCards == FleetCardKind.allCases)
}
