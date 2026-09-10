import Foundation
import SparkCore
import SparkLibrary
import Testing

@testable import SparkAppComposition

// MARK: - Details

@Test func detailsCarryIdentityRoutesMembersAndNoticeCodes() {
    let cluster = FleetPresentationTestFleetFixtures.degradedCluster()
    let details = FleetPresentationBuilder.details(
        for: FleetPresentationTestFleetFixtures.input(cluster)
    )

    #expect(details.title == "Studio Cluster")
    let sectionIDs = details.sections.map(\.id)
    #expect(sectionIDs == ["overview", "members", "attention", "identity"])

    let identity = details.sections.first { $0.id == "identity" }
    #expect(
        identity?.rows.first?.value == cluster.technicalDetails.logicalIdentity
    )
    #expect(
        identity?.rows.last?.value == "Direct connection · cluster-leader.local:7443 · en1"
    )

    let attention = details.sections.first { $0.id == "attention" }
    #expect(attention?.rows.map(\.value) == ["cluster.degraded"])

    let members = details.sections.first { $0.id == "members" }
    #expect(members?.rows.count == 2)
    #expect(members?.rows.first?.value.contains("Coordinator · Reachable") == true)
}

@Test func detailsReportUnknownRuntimeAndDiskWithoutEvidence() {
    let details = FleetPresentationBuilder.details(
        for: FleetPresentationTestFleetFixtures.input(
            FleetPresentationTestFleetFixtures.withoutEvidence(),
            canOpen: false
        )
    )
    let overview = details.sections.first { $0.id == "overview" }
    let values = Dictionary(
        uniqueKeysWithValues: (overview?.rows ?? []).map { ($0.id, $0.value) }
    )

    #expect(values["runtimeVersion"] == "Unknown")
    #expect(values["updateState"] == "Unknown")
    #expect(values["disk"] == "Unknown")
    #expect(values["memory"] == "Unknown")
}

// MARK: - Motion

@Test func reducedMotionRemovesDecorationButKeepsProgress() {
    #expect(
        FleetMotion.shouldAnimateConnectionPulse(tone: .positive, reduceMotion: false)
    )
    #expect(
        !FleetMotion.shouldAnimateConnectionPulse(tone: .positive, reduceMotion: true)
    )
    #expect(
        !FleetMotion.shouldAnimateConnectionPulse(tone: .caution, reduceMotion: false)
    )
    // Progress is real work, not decoration, so Reduced Motion never hides it.
    #expect(FleetMotion.shouldShowCheckProgress(isChecking: true, reduceMotion: true))
    #expect(!FleetMotion.shouldShowCheckProgress(isChecking: false, reduceMotion: true))
}

// MARK: - Formatting

/// Checks age buckets here; compiled plural grammar is tested against built catalogues in test_bundle_lookup_matrix.py.
@Test func elapsedTimeIsCoarseAndDeterministic() {
    #expect(FleetFormat.elapsed(-10) == "Just now")
    #expect(FleetFormat.elapsed(0) == "Just now")
    #expect(FleetFormat.elapsed(59) == "Just now")
    #expect(FleetFormat.elapsed(60).hasPrefix("1 minute"))
    #expect(FleetFormat.elapsed(3_540) == "59 minutes ago")
    #expect(FleetFormat.elapsed(3_600).hasPrefix("1 hour"))
    #expect(FleetFormat.elapsed(86_399) == "23 hours ago")
    #expect(FleetFormat.elapsed(86_400).hasPrefix("1 day"))
    #expect(FleetFormat.elapsed(200_000) == "2 days ago")
}

@Test func phoneActivityMapsDurableOperationsInsteadOfShowingAPlaceholder() {
    let operation = TargetOperationSnapshot(
        id: SparkOperationID(rawValue: UUID()),
        kind: "model.install",
        state: .running,
        progress: 0.42,
        stage: "downloading",
        errorCode: nil,
        cancellable: true
    )

    let cards = AppleNavigationPlan.activityCards(for: [operation])

    #expect(cards.count == 1)
    #expect(cards[0].id == operation.id)
    #expect(cards[0].kind == "model.install")
    #expect(cards[0].state == .running)
    #expect(cards[0].stage == "downloading")
    #expect(cards[0].progress == 0.42)
    #expect(cards[0].cancellable)
}

/// Only authenticated cluster identity can produce a cluster card, regardless of snapshot member count.
@Test func aMemberListAloneNeverProducesAClusterClaim() {
    let node = FleetPresentationTestFleetFixtures.nodeID(11)
    let snapshot = FleetPresentationTestFleetFixtures.rebuilt(
        FleetPresentationTestFleetFixtures.degradedCluster(),
        identity: .node(node)
    )

    let card = FleetPresentationBuilder.card(
        for: FleetPresentationTestFleetFixtures.input(snapshot),
        isChecking: false
    )

    #expect(card.artwork == .spark)
    #expect(card.membership == "Single Spark")
    #expect(card.members.isEmpty)
}
