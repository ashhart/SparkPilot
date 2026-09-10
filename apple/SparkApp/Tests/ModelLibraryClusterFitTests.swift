import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing
@testable import SparkAppComposition

@Test func onlyACompleteReadyClusterCanBecomeAnEligibleClusterTarget() throws {
    let incomplete = ModelLibraryTargetTopology(
        kind: .cluster,
        memberCount: 2,
        reachableMemberCount: 1,
        state: "degraded"
    )
    let complete = ModelLibraryTargetTopology(
        kind: .cluster,
        memberCount: 2,
        reachableMemberCount: 2,
        state: "ready"
    )
    let targets = [
        modelLibraryTestTargetEvidence(
            id: "cluster:incomplete",
            name: "Bench Cluster",
            topology: incomplete,
            recipes: [modelLibraryTestRecipeEvidence(fit: "fits")]
        ),
        modelLibraryTestTargetEvidence(
            id: "cluster:complete",
            name: "Studio Cluster",
            topology: complete,
            recipes: [modelLibraryTestRecipeEvidence(fit: "fits")]
        ),
    ]

    let model = try #require(
        CrossTargetModelLibraryAggregator.snapshot(
            targets: targets,
            generatedAt: modelLibraryTestLibraryEvidenceDate
        ).models.first
    )

    #expect(model.recommendation?.targetName == "Studio Cluster")
    #expect(model.topologyLabel == "Complete cluster")
    #expect(
        model.placements.first(where: { $0.id == "cluster:incomplete" })?.fit
            == .clusterRequired
    )
    #expect(
        model.placements.first(where: { $0.id == "cluster:complete" })?.fit == .fitsNow
    )
}

@Test func sharedMemberStateAloneDeterminesClusterCompleteness() throws {
    let clusterID = SparkClusterID(
        rawValue: UUID(uuidString: "763e82da-7fb7-4b4b-9584-4a528000ac94")!
    )
    let nodeA = SparkNodeID(
        rawValue: UUID(uuidString: "863e82da-7fb7-4b4b-9584-4a528000ac94")!
    )
    let nodeB = SparkNodeID(
        rawValue: UUID(uuidString: "963e82da-7fb7-4b4b-9584-4a528000ac94")!
    )
    let completeMembers = [
        TargetMemberSnapshot(
            nodeID: nodeA,
            displayName: "Leader",
            role: .leader,
            reachable: true
        ),
        TargetMemberSnapshot(
            nodeID: nodeB,
            displayName: "Worker",
            role: .worker,
            reachable: true
        ),
    ]
    let completeEvidence = ModelLibraryOperationalSnapshotAdapter.evidence(
        from: modelLibraryTestSharedOperationalSnapshot(
            identity: .cluster(clusterID),
            members: completeMembers,
            evidence: modelLibraryTestOperationalFreshness()
        ),
        catalogue: try modelLibraryTestSharedCatalogue()
    )
    let complete = try #require(
        CrossTargetModelLibraryAggregator.snapshot(
            targets: [completeEvidence],
            generatedAt: modelLibraryTestLibraryEvidenceDate
        ).models.first
    )

    #expect(completeEvidence.topology.isCompleteCluster)
    #expect(complete.recommendation?.targetID == SparkTargetIdentity.cluster(clusterID).description)

    let incompleteEvidence = ModelLibraryOperationalSnapshotAdapter.evidence(
        from: modelLibraryTestSharedOperationalSnapshot(
            identity: .cluster(clusterID),
            members: [
                completeMembers[0],
                TargetMemberSnapshot(
                    nodeID: nodeB,
                    displayName: "Worker",
                    role: .worker,
                    reachable: false
                ),
            ],
            evidence: modelLibraryTestOperationalFreshness()
        ),
        catalogue: try modelLibraryTestSharedCatalogue()
    )
    let incomplete = try #require(
        CrossTargetModelLibraryAggregator.snapshot(
            targets: [incompleteEvidence],
            generatedAt: modelLibraryTestLibraryEvidenceDate
        ).models.first
    )

    #expect(!incompleteEvidence.topology.isCompleteCluster)
    #expect(incomplete.placements.first?.fit == .clusterRequired)
    #expect(incomplete.recommendation == nil)
}

@Test func missingSharedCapacityEvidenceKeepsPlacementUnknown() throws {
    let nodeID = SparkNodeID(
        rawValue: UUID(uuidString: "a63e82da-7fb7-4b4b-9584-4a528000ac94")!
    )
    let target = ModelLibraryOperationalSnapshotAdapter.evidence(
        from: modelLibraryTestSharedOperationalSnapshot(
            identity: .node(nodeID),
            members: [
                TargetMemberSnapshot(
                    nodeID: nodeID,
                    displayName: "Studio Spark",
                    role: .standalone,
                    reachable: true
                )
            ],
            evidence: modelLibraryTestOperationalFreshness(memory: .missing)
        ),
        catalogue: try modelLibraryTestSharedCatalogue()
    )
    let model = try #require(
        CrossTargetModelLibraryAggregator.snapshot(
            targets: [target],
            generatedAt: modelLibraryTestLibraryEvidenceDate
        ).models.first
    )

    #expect(target.freshness == .unavailable)
    #expect(model.placements.first?.fit == .evidenceUnavailable)
    #expect(model.placements.first?.state == .available)
    #expect(model.recommendation == nil)
}

@Test func missingInventoryCannotPresentUnknownPlacementAsInstallable() throws {
    let nodeID = SparkNodeID(
        rawValue: UUID(uuidString: "b63e82da-7fb7-4b4b-9584-4a528000ac94")!
    )
    let target = ModelLibraryOperationalSnapshotAdapter.evidence(
        from: modelLibraryTestSharedOperationalSnapshot(
            identity: .node(nodeID),
            members: [
                TargetMemberSnapshot(
                    nodeID: nodeID,
                    displayName: "Studio Spark",
                    role: .standalone,
                    reachable: true
                )
            ],
            evidence: modelLibraryTestOperationalFreshness(inventory: .missing),
            placementState: .unknown
        ),
        catalogue: try modelLibraryTestSharedCatalogue()
    )
    let placement = try #require(
        CrossTargetModelLibraryAggregator.snapshot(
            targets: [target],
            generatedAt: modelLibraryTestLibraryEvidenceDate
        ).models.first?.placements.first
    )

    #expect(target.freshness == .unavailable)
    #expect(placement.state == .unknown)
    #expect(placement.state.label == "State unavailable")
    #expect(!placement.isEligible)
}

@Test func standardPolicyHidesUnverifiedAndEverywhereIncompatibleRecipes() {
    let unverified = modelLibraryTestTargetEvidence(
        id: "node:a",
        name: "Studio Spark",
        recipes: [
            modelLibraryTestRecipeEvidence(
                id: "local/unverified",
                name: "Unverified",
                revision: nil,
                state: .unverified,
                fit: "unknown"
            ),
            modelLibraryTestRecipeEvidence(
                id: "signed/incompatible",
                name: "Incompatible",
                state: .incompatible,
                fit: "incompatible"
            ),
        ]
    )

    let standard = CrossTargetModelLibraryAggregator.snapshot(
        targets: [unverified],
        generatedAt: modelLibraryTestLibraryEvidenceDate
    )
    let technical = CrossTargetModelLibraryAggregator.snapshot(
        targets: [unverified],
        generatedAt: modelLibraryTestLibraryEvidenceDate,
        visibilityPolicy: .technicalInspection
    )

    #expect(standard.models.isEmpty)
    #expect(technical.models.map(\.displayName) == ["Incompatible", "Unverified"])
    #expect(
        technical.models.first(where: { $0.displayName == "Unverified" })?.verification
            == .unverified
    )
    #expect(
        technical.models.first(where: { $0.displayName == "Incompatible" })?
            .placements.first?.fit == .incompatible
    )
}

@Test func digestsStayInTechnicalDetailsWhileHumanVersionRemainsVisible() throws {
    let sourceDigest = String(repeating: "a", count: 40)
    let humanVersion = modelLibraryTestRecipeEvidence(
        revision: "2026.08.4",
        sourceRevision: sourceDigest
    )
    let digestVersion = modelLibraryTestRecipeEvidence(
        id: "spark/digest-version",
        name: "Digest Version",
        revision: "sha256:" + String(repeating: "b", count: 64),
        sourceRevision: sourceDigest
    )
    let target = modelLibraryTestTargetEvidence(
        id: "node:a",
        name: "Studio Spark",
        recipes: [humanVersion, digestVersion]
    )
    let models = CrossTargetModelLibraryAggregator.snapshot(
        targets: [target],
        generatedAt: modelLibraryTestLibraryEvidenceDate
    ).models

    let human = try #require(models.first(where: { $0.displayName == "Model 8B" }))
    let digest = try #require(models.first(where: { $0.displayName == "Digest Version" }))
    #expect(human.versionLabel == "2026.08.4")
    #expect(human.technicalDetails.sourceRevision == sourceDigest)
    #expect(digest.versionLabel == "See technical details")
    #expect(digest.technicalDetails.recipeRevision?.hasPrefix("sha256:") == true)
    #expect(!digest.accessibilitySummary.contains(sourceDigest))
}
