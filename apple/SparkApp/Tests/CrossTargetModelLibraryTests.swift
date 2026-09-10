import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing
@testable import SparkAppComposition

let modelLibraryTestLibraryEvidenceDate = Date(timeIntervalSince1970: 1_777_374_000)

@Test func modelLibraryRefreshHasAnOwnerFacingAccessibilityLabel() {
    #expect(
        ModelLibraryActionPresentation.refreshAccessibilityLabel
            == "Refresh model library"
    )
}

@Test func modelLibraryOffersOnlySafeManagementJourneysFromCurrentEvidence() {
    let current = ModelLibraryEvidenceFreshness.current(
        observedAt: modelLibraryTestLibraryEvidenceDate
    )
    let stale = ModelLibraryEvidenceFreshness.stale(observedAt: modelLibraryTestLibraryEvidenceDate)

    #expect(
        ModelLibraryManagementAction.resolve(
            state: .available,
            fit: .fitsNow,
            freshness: current
        ) == .install
    )
    #expect(
        ModelLibraryManagementAction.resolve(
            state: .installed,
            fit: .fitsAfterStop,
            freshness: current
        ) == .load
    )
    #expect(
        ModelLibraryManagementAction.resolve(
            state: .running,
            fit: .fitsNow,
            freshness: current
        ) == .unload
    )
    #expect(
        ModelLibraryManagementAction.resolve(
            state: .downloading,
            fit: .fitsNow,
            freshness: current
        ) == .review
    )
    #expect(
        ModelLibraryManagementAction.resolve(
            state: .failed,
            fit: .fitsNow,
            freshness: current
        ) == .review
    )
    #expect(
        ModelLibraryManagementAction.resolve(
            state: .unverified,
            fit: .fitsNow,
            freshness: current
        ) == nil
    )
    #expect(
        ModelLibraryManagementAction.resolve(
            state: .available,
            fit: .fitsNow,
            freshness: stale
        ) == nil
    )
    #expect(
        ModelLibraryManagementAction.resolve(
            state: .available,
            fit: .incompatible,
            freshness: current
        ) == nil
    )
}

@Test func fitResolverCoversEveryContractStateAndRejectsStaleEvidence() {
    let expected: [(String?, ModelTargetFit)] = [
        ("ready", .fitsNow),
        ("fits", .fitsNow),
        ("fits_after_unload", .fitsAfterStop),
        ("smaller_profile_required", .smallerProfile),
        ("cluster_required", .clusterRequired),
        ("incompatible", .incompatible),
        ("unknown", .evidenceUnavailable),
        (nil, .evidenceUnavailable),
        ("future_fit_state", .evidenceUnavailable),
    ]

    for (raw, fit) in expected {
        #expect(
            ModelTargetFit.resolve(
                rawValue: raw,
                installState: .available,
                freshness: .current(observedAt: modelLibraryTestLibraryEvidenceDate),
                topology: .standalone
            ) == fit
        )
        #expect(
            ModelTargetFit.resolve(
                rawValue: raw,
                installState: .available,
                freshness: .stale(observedAt: modelLibraryTestLibraryEvidenceDate),
                topology: .standalone
            ) == .evidenceUnavailable
        )
    }

    #expect(
        ModelTargetFit.resolve(
            rawValue: "fits",
            installState: .incompatible,
            freshness: .current(observedAt: modelLibraryTestLibraryEvidenceDate),
            topology: .standalone
        ) == .incompatible
    )
}

@Test func zeroTargetsProducesAnEmptyLibrary() {
    let snapshot = CrossTargetModelLibraryAggregator.snapshot(
        targets: [],
        generatedAt: modelLibraryTestLibraryEvidenceDate
    )

    #expect(snapshot.targets.isEmpty)
    #expect(snapshot.models.isEmpty)
    #expect(snapshot.generatedAt == modelLibraryTestLibraryEvidenceDate)
}

@Test func oneTargetShowsRecipeMetadataCoverageAndTimestampedRecommendation() throws {
    let recipe = modelLibraryTestRecipeEvidence(state: .installed, fit: "ready")
    let target = modelLibraryTestTargetEvidence(
        id: "node:a",
        name: "Studio Spark",
        activeModelID: recipe.modelID,
        inferenceState: .ready,
        recipes: [recipe]
    )

    let snapshot = CrossTargetModelLibraryAggregator.snapshot(
        targets: [target],
        generatedAt: modelLibraryTestLibraryEvidenceDate
    )
    let model = try #require(snapshot.models.first)
    let recommendation = try #require(model.recommendation)

    #expect(model.displayName == "Model 8B")
    #expect(model.versionLabel == "2026.08.1")
    #expect(model.taskLabel == "Text generation")
    #expect(model.capabilityLabels == ["Chat", "Reasoning"])
    #expect(model.downloadBytes == 8_000_000_000)
    #expect(model.verification == .verified)
    #expect(model.profiles.first?.id == "balanced")
    #expect(model.profiles.first?.isSafe == true)
    #expect(model.topologyLabel == "Single Spark")
    #expect(model.coverage.runningTargets == ["Studio Spark"])
    #expect(model.coverage.installedTargets == ["Studio Spark"])
    #expect(model.coverage.cachedRunningTargets.isEmpty)
    #expect(recommendation.targetName == "Studio Spark")
    #expect(recommendation.fit == .fitsNow)
    #expect(recommendation.evidenceAt == modelLibraryTestLibraryEvidenceDate)
    #expect(model.eligibleAlternatives.isEmpty)
    #expect(model.otherTargets.isEmpty)
    #expect(!model.accessibilitySummary.contains(recipe.modelID))
    #expect(!model.accessibilitySummary.contains(recipe.sourceRevision!))
}

@Test func manyTargetsPreferRunningThenExposeEligibleAlternatives() throws {
    let base = modelLibraryTestRecipeEvidence()
    let targets = [
        modelLibraryTestTargetEvidence(
            id: "node:download",
            name: "Archive Spark",
            memory: 100_000_000_000,
            recipes: [base]
        ),
        modelLibraryTestTargetEvidence(
            id: "node:installed",
            name: "Desk Spark",
            memory: 40_000_000_000,
            recipes: [modelLibraryTestRecipeEvidence(state: .installed, fit: "ready")]
        ),
        modelLibraryTestTargetEvidence(
            id: "node:running",
            name: "Lab Spark",
            memory: 20_000_000_000,
            activeModelID: base.modelID,
            inferenceState: .idle,
            recipes: [modelLibraryTestRecipeEvidence(state: .installed, fit: "ready")]
        ),
        modelLibraryTestTargetEvidence(
            id: "node:conditional",
            name: "Quiet Spark",
            recipes: [modelLibraryTestRecipeEvidence(fit: "fits_after_unload")]
        ),
    ]

    let model = try #require(
        CrossTargetModelLibraryAggregator.snapshot(
            targets: targets,
            generatedAt: modelLibraryTestLibraryEvidenceDate
        ).models.first
    )

    #expect(model.recommendation?.targetName == "Lab Spark")
    #expect(
        model.eligibleAlternatives.map(\.targetName) == [
            "Archive Spark", "Desk Spark", "Quiet Spark",
        ]
    )
    #expect(
        model.placements.map(\.targetName) == [
            "Archive Spark", "Desk Spark", "Lab Spark", "Quiet Spark",
        ]
    )
    #expect(model.coverage.label == "Running on Lab Spark. Installed on Desk Spark")
}

@Test func aLoadingEngineIsInstalledButNotYetRunning() throws {
    let recipe = modelLibraryTestRecipeEvidence(state: .installed, fit: "ready")
    let target = modelLibraryTestTargetEvidence(
        id: "node:loading",
        name: "Loading Spark",
        activeModelID: recipe.modelID,
        inferenceState: .loading,
        recipes: [recipe]
    )

    let model = try #require(
        CrossTargetModelLibraryAggregator.snapshot(
            targets: [target],
            generatedAt: modelLibraryTestLibraryEvidenceDate
        ).models.first
    )

    #expect(model.placements.first?.state == .installed)
    #expect(model.coverage.runningTargets.isEmpty)
    #expect(model.coverage.installedTargets == ["Loading Spark"])
}

@Test func offlineTargetRetainsCachedCoverageButCannotProduceFitOrRecommendation() throws {
    let cached = modelLibraryTestTargetEvidence(
        id: "node:offline",
        name: "Offline Spark",
        freshness: .stale(observedAt: modelLibraryTestLibraryEvidenceDate),
        activeModelID: "spark/model-8b",
        inferenceState: .ready,
        recipes: [modelLibraryTestRecipeEvidence(state: .installed, fit: "ready")]
    )

    let model = try #require(
        CrossTargetModelLibraryAggregator.snapshot(
            targets: [cached],
            generatedAt: modelLibraryTestLibraryEvidenceDate.addingTimeInterval(600)
        ).models.first
    )
    let placement = try #require(model.placements.first)

    #expect(placement.fit == .evidenceUnavailable)
    #expect(placement.state == .running)
    #expect(model.recommendation == nil)
    #expect(model.coverage.runningTargets.isEmpty)
    #expect(model.coverage.cachedRunningTargets == ["Offline Spark"])
    #expect(model.coverage.label == "Last known running on Offline Spark")
    #expect(placement.accessibilitySummary.contains("Stale evidence"))
}
