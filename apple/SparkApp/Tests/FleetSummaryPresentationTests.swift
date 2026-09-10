import Foundation
import SparkCore
import SparkLibrary
import Testing

@testable import SparkAppComposition

// MARK: - Summary

@Test func summaryCountsConnectedDelayedOfflineActiveAndWarnings() {
    let presentation = FleetPresentationBuilder.build(targets: [
        FleetPresentationTestFleetFixtures.input(FleetPresentationTestFleetFixtures.online()),
        FleetPresentationTestFleetFixtures.input(FleetPresentationTestFleetFixtures.delayed()),
        FleetPresentationTestFleetFixtures.input(FleetPresentationTestFleetFixtures.offline()),
        FleetPresentationTestFleetFixtures.input(
            FleetPresentationTestFleetFixtures.degradedCluster()
        ),
    ])

    #expect(presentation.summary.targetCount == 4)
    #expect(presentation.summary.connectedCount == 2)
    #expect(presentation.summary.delayedCount == 1)
    #expect(presentation.summary.offlineCount == 1)
    // The cluster has no model loaded; the other three do.
    #expect(presentation.summary.activeModelCount == 3)
    // Delayed, offline, and degraded-cluster each contribute one warning.
    #expect(presentation.summary.warningCount == 3)
    #expect(presentation.summary.blockerCount == 0)
}

@Test func summaryCountsBlockersApartFromWarnings() {
    let presentation = FleetPresentationBuilder.build(targets: [
        FleetPresentationTestFleetFixtures.input(FleetPresentationTestFleetFixtures.offline()),
        FleetPresentationTestFleetFixtures.input(
            FleetPresentationTestFleetFixtures.identityMismatch(),
            canOpen: false,
            hasIdentityIssue: true
        ),
    ])

    #expect(presentation.summary.warningCount == 1)
    #expect(presentation.summary.blockerCount == 1)
    let warningTile = presentation.summary.items.first { $0.id == "warnings" }
    #expect(warningTile?.value == "1 · 1 blocking")
}

@Test func summaryMemoryTotalOnlyCountsCurrentEvidence() {
    let presentation = FleetPresentationBuilder.build(targets: [
        FleetPresentationTestFleetFixtures.input(FleetPresentationTestFleetFixtures.online()),
        FleetPresentationTestFleetFixtures.input(FleetPresentationTestFleetFixtures.offline()),
    ])

    // Exclude an offline Spark's cached memory from actionable headroom totals.
    #expect(presentation.summary.availableUnifiedMemory == "62.1 GB")
    #expect(
        presentation.summary.memoryEvidenceNote
            == "From 1 of 2 Sparks with current evidence."
    )
}

@Test func summaryMemoryIsUnknownWhenNoTargetHasCurrentEvidence() {
    let presentation = FleetPresentationBuilder.build(targets: [
        FleetPresentationTestFleetFixtures.input(FleetPresentationTestFleetFixtures.offline())
    ])

    #expect(presentation.summary.availableUnifiedMemory == "Unknown")
    #expect(
        presentation.summary.memoryEvidenceNote
            == "No Spark reported current unified-memory evidence."
    )
}

// MARK: - Whole-surface states

@Test func fleetWithNoPairedTargetsIsEmptyAndOffersAddSpark() {
    let presentation = FleetPresentationBuilder.build(targets: [])

    #expect(presentation.content == .empty)
    #expect(presentation.totalCount == 0)
    #expect(presentation.summary.availableUnifiedMemory == "Unknown")
    #expect(
        presentation.summary.memoryEvidenceNote == "No Sparks are paired with this device yet."
    )
    #expect(AppleNavigationPlan.usesFleetHome(on: .pad))
    #expect(!AppleNavigationPlan.usesFleetHome(on: .phone))
}

@MainActor
@Test func fleetAddSparkActionReachesTheOnboardingChoice() {
    let model = RetailOnboardingModel(library: SparkLibrary(store: MemoryLibraryStore()))

    AppleShellActions.beginAddingSpark(with: model)

    #expect(model.isChoosingSpark)
}

@Test func sessionOnlyStorageRaisesABannerWithARecoveryAction() {
    let presentation = FleetPresentationBuilder.build(
        targets: [
            FleetPresentationTestFleetFixtures.input(FleetPresentationTestFleetFixtures.online())
        ],
        storage: .sessionOnly(reason: "disk is full")
    )

    #expect(presentation.storageNotice?.title == "Your Sparks aren't being saved")
    #expect(presentation.storageNotice?.actionTitle == "Try Again")
    #expect(
        presentation.storageNotice?.actionAccessibilityLabel
            == "Try Again. Retry saving Your Sparks"
    )
    // The Fleet still lists what this session knows.
    #expect(presentation.cards.count == 1)
}

@Test func durableStorageRaisesNoBanner() {
    let presentation = FleetPresentationBuilder.build(
        targets: [
            FleetPresentationTestFleetFixtures.input(FleetPresentationTestFleetFixtures.online())
        ],
        storage: .persistent
    )

    #expect(presentation.storageNotice == nil)
}

@Test func offlineTargetsStayInTheFleet() {
    let presentation = FleetPresentationBuilder.build(targets: [
        FleetPresentationTestFleetFixtures.input(FleetPresentationTestFleetFixtures.online()),
        FleetPresentationTestFleetFixtures.input(FleetPresentationTestFleetFixtures.offline()),
    ])

    #expect(presentation.cards.count == 2)
    #expect(presentation.cards.contains { $0.name == "Garage Spark" })
}

@Test func fleetPrimaryAndOfflineActionsHaveTargetSpecificAccessibilityLabels() {
    #expect(
        FleetCardAction.open.accessibilityLabel(for: "Studio Spark") == "Connect to Studio Spark"
    )
    #expect(
        FleetCardAction.checkAgain.accessibilityLabel(for: "Garage Spark")
            == "Check Garage Spark again"
    )
    #expect(
        FleetCardAction.remove.accessibilityLabel(for: "Studio Spark")
            == "Remove Studio Spark from this device"
    )
}
