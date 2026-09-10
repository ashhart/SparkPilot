import Foundation
import SparkCore
import SparkLibrary
import Testing

@testable import SparkAppComposition

@Test func externalClusterCardDoesNotInventCoordinatorOrWorkerRoles() {
    let card = FleetPresentationBuilder.card(
        for: FleetPresentationTestFleetFixtures.input(
            FleetPresentationTestFleetFixtures.degradedCluster(),
            canOpen: false,
            isExternallyConfiguredCluster: true
        ),
        isChecking: false
    )

    #expect(card.membership.hasPrefix("Externally configured cluster of 2 Sparks"))
    #expect(card.members.map(\.role) == ["Member", "Member"])
    #expect(!card.actions.contains(.open))
}

// MARK: - Card content

@Test func fleetCardLeadsWithFriendlyNameAndTruthfulConnection() {
    let card = FleetPresentationBuilder.card(
        for: FleetPresentationTestFleetFixtures.input(FleetPresentationTestFleetFixtures.online()),
        isChecking: false
    )

    #expect(card.name == "Studio Spark")
    #expect(card.connection.label == "Connected over Wi-Fi")
    #expect(card.connection.tone == .positive)
    #expect(card.lastContact == "Just now")
    #expect(card.availableMemory == "62.1 GB free of 128.0 GB")
    #expect(card.activeModel == "Compact 8B · Running")
    #expect(card.installedModels == "3 models installed")
    #expect(card.membership == "Single Spark")
    #expect(card.artwork == .spark)
    #expect(card.evidenceNote == nil)
    #expect(!card.needsAttention)
}

@Test func fleetCardShowsUnknownWhereThereIsNoEvidence() {
    let card = FleetPresentationBuilder.card(
        for: FleetPresentationTestFleetFixtures.input(
            FleetPresentationTestFleetFixtures.withoutEvidence(),
            canOpen: false
        ),
        isChecking: false
    )

    #expect(card.lastContact == "Unknown")
    #expect(card.availableMemory == "Unknown")
    #expect(card.activeModel == "Unknown")
    #expect(card.installedModels == "Unknown")
    // A card with no route cannot be opened, but it can always be removed.
    #expect(card.actions == [.checkAgain, .remove])
}

@Test func fleetCardDistinguishesNoModelRunningFromUnknown() {
    let stopped = FleetPresentationBuilder.card(
        for: FleetPresentationTestFleetFixtures.input(
            FleetPresentationTestFleetFixtures.online(inference: .unloaded)
        ),
        isChecking: false
    )
    #expect(stopped.activeModel == "No model running")

    let loading = FleetPresentationBuilder.card(
        for: FleetPresentationTestFleetFixtures.input(
            FleetPresentationTestFleetFixtures.online(inference: .loading)
        ),
        isChecking: false
    )
    #expect(loading.activeModel == "Compact 8B · Loading")
}

@Test func fleetCardReportsZeroInstalledModelsWithoutClaimingUnknown() {
    let card = FleetPresentationBuilder.card(
        for: FleetPresentationTestFleetFixtures.input(
            FleetPresentationTestFleetFixtures.online(
                placements: [],
                installedModelCount: 0,
                inference: .unloaded
            )
        ),
        isChecking: false
    )

    #expect(card.installedModels == "No models installed")
}

@Test func fleetCardKeepsOfflineValuesAndSaysWhereTheyCameFrom() {
    let card = FleetPresentationBuilder.card(
        for: FleetPresentationTestFleetFixtures.input(FleetPresentationTestFleetFixtures.offline()),
        isChecking: false
    )

    #expect(card.connection.label == "Offline · showing saved state")
    #expect(card.lastContact == "2 hours ago")
    // The retained account is not repaired or blanked while offline.
    #expect(card.availableMemory == "62.1 GB free of 128.0 GB")
    #expect(card.installedModels == "3 models installed")
    #expect(card.evidenceNote == "Saved state from the last contact, 2 hours ago.")
    #expect(
        card.warnings.contains("Showing the last authenticated state while the target is offline.")
    )
}

@Test func fleetCardMarksADelayedTargetWithoutCallingItOffline() {
    let card = FleetPresentationBuilder.card(
        for: FleetPresentationTestFleetFixtures.input(FleetPresentationTestFleetFixtures.delayed()),
        isChecking: false
    )

    #expect(card.connection.label == "Answering slowly")
    #expect(card.connection.tone == .caution)
    #expect(card.lastContact == "5 minutes ago")
    #expect(card.evidenceNote == "Values are from the last answer, 5 minutes ago.")
}

@Test func identityMismatchCardOffersOnlyRemoval() {
    let card = FleetPresentationBuilder.card(
        for: FleetPresentationTestFleetFixtures.input(
            FleetPresentationTestFleetFixtures.identityMismatch(),
            canOpen: false,
            hasIdentityIssue: true
        ),
        isChecking: false
    )

    #expect(card.connection.label == "Identity changed")
    #expect(card.connection.tone == .critical)
    #expect(card.actions == [.remove])
    #expect(
        card.blockers == ["The saved route presented a different Spark identity."]
    )
}

@Test func clusterCardShowsMembershipAndMemberReachability() {
    let card = FleetPresentationBuilder.card(
        for: FleetPresentationTestFleetFixtures.input(
            FleetPresentationTestFleetFixtures.degradedCluster()
        ),
        isChecking: false
    )

    #expect(card.artwork == .cluster(memberCount: 2))
    #expect(card.membership == "Cluster of 2 Sparks · 1 reachable")
    #expect(card.members.map(\.role) == ["Coordinator", "Worker"])
    #expect(card.members.map(\.reachability) == ["Reachable", "Not reachable"])
    #expect(card.warnings == ["One or more cluster members or links are degraded."])
}

@Test func checkingCardReportsProgressForAssistiveTechnology() {
    let card = FleetPresentationBuilder.card(
        for: FleetPresentationTestFleetFixtures.input(FleetPresentationTestFleetFixtures.online()),
        isChecking: true
    )

    #expect(card.connection.isChecking)
    #expect(card.accessibilityLabel.contains("Checking now"))
}

@Test func cardAccessibilityLabelSpeaksEveryValueTheCardShows() {
    let card = FleetPresentationBuilder.card(
        for: FleetPresentationTestFleetFixtures.input(FleetPresentationTestFleetFixtures.offline()),
        isChecking: false
    )

    #expect(card.accessibilityLabel.hasPrefix("Garage Spark. Offline · showing saved state."))
    #expect(card.accessibilityLabel.contains("Last contact 2 hours ago"))
    #expect(card.accessibilityLabel.contains("Unified memory 62.1 GB free of 128.0 GB"))
    #expect(card.accessibilityLabel.contains("Active model Compact 8B · Running"))
    #expect(card.accessibilityLabel.contains("3 models installed"))
    #expect(card.accessibilityLabel.contains("Warning: Showing the last authenticated state"))
}

@Test func firstViewportCarriesNoIdentifiersRoutesOrNoticeCodes() {
    let cluster = FleetPresentationTestFleetFixtures.degradedCluster()
    let card = FleetPresentationBuilder.card(
        for: FleetPresentationTestFleetFixtures.input(cluster),
        isChecking: false
    )

    let surface =
        ([
            card.name, card.connection.label, card.lastContact, card.availableMemory,
            card.activeModel, card.installedModels, card.membership,
            card.evidenceNote ?? "", card.accessibilityLabel,
        ] + card.warnings + card.blockers + card.members.map { "\($0.name) \($0.reachability)" })
        .joined(separator: " ")

    #expect(!surface.contains(cluster.technicalDetails.logicalIdentity))
    #expect(!surface.contains("cluster-leader.local"))
    #expect(!surface.contains("7443"))
    #expect(!surface.contains("cluster.degraded"))
    #expect(!surface.lowercased().contains("vllm"))
    #expect(!surface.lowercased().contains("docker"))
    for nodeID in cluster.technicalDetails.memberNodeIDs {
        #expect(!surface.contains(nodeID.rawValue.uuidString.lowercased()))
    }
}
