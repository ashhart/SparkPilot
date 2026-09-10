import Foundation
import Observation
import SparkAPI
import SparkCore
import SparkLibrary

// MARK: - Deterministic aggregation

public enum CrossTargetModelLibraryAggregator {
    public static func snapshot(
        targets: [ModelLibraryTargetEvidence],
        generatedAt: Date,
        visibilityPolicy: ModelLibraryVisibilityPolicy = .standard
    ) -> CrossTargetModelLibrarySnapshot {
        let orderedTargets = targets.sorted {
            let comparison = $0.name.localizedCaseInsensitiveCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }

        var observations: [RecipeKey: [(ModelLibraryTargetEvidence, ModelLibraryRecipeEvidence)]] =
            [:]
        for target in orderedTargets {
            for recipe in target.recipes {
                observations[RecipeKey(recipe), default: []].append((target, recipe))
            }
        }

        let models = observations.compactMap { key, recipeObservations in
            makeItem(
                key: key,
                observations: recipeObservations,
                targets: orderedTargets,
                visibilityPolicy: visibilityPolicy
            )
        }
        .sorted {
            let comparison = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
            if comparison != .orderedSame { return comparison == .orderedAscending }
            if $0.versionLabel != $1.versionLabel { return $0.versionLabel < $1.versionLabel }
            return $0.id < $1.id
        }

        return CrossTargetModelLibrarySnapshot(
            generatedAt: generatedAt,
            targets: orderedTargets,
            models: models
        )
    }

    private struct RecipeKey: Hashable {
        let modelID: String
        let recipeRevision: String?
        let sourceRevisionFallback: String?

        init(_ recipe: ModelLibraryRecipeEvidence) {
            modelID = recipe.modelID
            recipeRevision = recipe.recipeRevision
            sourceRevisionFallback = recipe.recipeRevision == nil ? recipe.sourceRevision : nil
        }

        var stableID: String {
            [modelID, recipeRevision ?? sourceRevisionFallback ?? "version-unavailable"]
                .joined(separator: "|")
        }
    }

    private static func makeItem(
        key: RecipeKey,
        observations: [(ModelLibraryTargetEvidence, ModelLibraryRecipeEvidence)],
        targets: [ModelLibraryTargetEvidence],
        visibilityPolicy: ModelLibraryVisibilityPolicy
    ) -> CrossTargetModelLibraryItem? {
        let preferred = observations.sorted { left, right in
            if left.0.freshness.isCurrent != right.0.freshness.isCurrent {
                return left.0.freshness.isCurrent
            }
            return left.0.name.localizedCaseInsensitiveCompare(right.0.name) == .orderedAscending
        }.first!.1

        let verification: ModelLibraryRecipeVerification
        if observations.contains(where: { $0.1.installState == .unverified }) {
            verification = .unverified
        } else if key.recipeRevision != nil {
            verification = .verified
        } else {
            verification = .unavailable
        }

        let placements = targets.map { target in
            makePlacement(
                target: target,
                recipe: target.recipes.first(where: { RecipeKey($0) == key })
            )
        }
        let onlyIncompatible =
            !placements.isEmpty
            && placements.allSatisfy { $0.fit == .incompatible }
        if visibilityPolicy == .standard,
            verification != .verified || onlyIncompatible
        {
            return nil
        }

        let running = placements.filter { $0.freshness.isCurrent && $0.isRunning }
            .map(\.targetName).sorted()
        let installed = placements.filter { $0.freshness.isCurrent && $0.isInstalled }
            .map(\.targetName).sorted()
        let cachedRunning = placements.filter { !$0.freshness.isCurrent && $0.isRunning }
            .map(\.targetName).sorted()
        let cachedInstalled = placements.filter { !$0.freshness.isCurrent && $0.isInstalled }
            .map(\.targetName).sorted()
        let recommendation = recommendation(from: placements)

        return CrossTargetModelLibraryItem(
            id: key.stableID,
            displayName: preferred.displayName,
            summary: preferred.summary,
            versionLabel: displayVersion(
                recipeRevision: preferred.recipeRevision,
                sourceRevision: preferred.sourceRevision
            ),
            taskLabel: taskLabel(for: preferred.capabilities),
            capabilityLabels: capabilityLabels(for: preferred.capabilities),
            downloadBytes: observations.compactMap { $0.1.downloadBytes }.max(),
            verification: verification,
            topologyLabel: topologyLabel(for: placements),
            coverage: ModelLibraryCoverage(
                runningTargets: running,
                installedTargets: installed,
                cachedRunningTargets: cachedRunning,
                cachedInstalledTargets: cachedInstalled
            ),
            placements: placements,
            recommendation: recommendation,
            technicalDetails: ModelLibraryTechnicalDetails(
                modelID: preferred.modelID,
                recipeRevision: preferred.recipeRevision,
                sourceRevision: preferred.sourceRevision
            ),
            profiles: preferred.profiles
        )
    }

    private static func makePlacement(
        target: ModelLibraryTargetEvidence,
        recipe: ModelLibraryRecipeEvidence?
    ) -> ModelLibraryTargetPlacement {
        let state: ModelLibraryPlacementState
        if let recipe {
            if target.isActive(recipe),
                target.activeInferenceState == .ready || target.activeInferenceState == .idle
            {
                state = .running
            } else if let operationalState = recipe.operationalState {
                state = placementState(for: operationalState)
            } else if let installState = recipe.installState {
                state = placementState(for: installState)
            } else {
                state = .unknown
            }
        } else if target.freshness.isCurrent {
            state = .notPresent
        } else {
            state = .unknown
        }

        var fit = ModelTargetFit.resolve(
            rawValue: recipe?.rawFit,
            installState: recipe?.installState,
            freshness: target.freshness,
            topology: target.topology
        )
        if recipe == nil, target.freshness.isCurrent {
            fit = .incompatible
        }

        return ModelLibraryTargetPlacement(
            id: target.id,
            targetName: target.name,
            connectionLabel: target.connectionLabel,
            topology: target.topology,
            freshness: target.freshness,
            availableMemoryBytes: target.availableMemoryBytes,
            runtimeVersion: target.runtimeVersion,
            fit: fit,
            state: state,
            explanation: placementExplanation(fit: fit, target: target, recipe: recipe)
        )
    }

    private static func placementState(
        for state: SparkModelInstallState
    ) -> ModelLibraryPlacementState {
        switch state {
        case .available: .available
        case .downloading: .downloading
        case .verifying: .verifying
        case .installed: .installed
        case .failed: .failed
        case .incompatible: .incompatible
        case .unverified: .unverified
        }
    }

    private static func placementState(
        for state: ModelPlacementState
    ) -> ModelLibraryPlacementState {
        switch state {
        case .available: .available
        case .downloading: .downloading
        case .installed, .starting, .stopping: .installed
        case .running: .running
        case .failed: .failed
        case .incompatible: .incompatible
        case .unknown: .unknown
        }
    }

    private static func placementExplanation(
        fit: ModelTargetFit,
        target: ModelLibraryTargetEvidence,
        recipe: ModelLibraryRecipeEvidence?
    ) -> String {
        switch fit {
        case .fitsNow where recipe.map(target.isActive) == true:
            return String(localized: "The model is already running here.")
        case .fitsNow:
            return String(localized: "Current authenticated capacity can run this recipe.")
        case .fitsAfterStop:
            return String(localized: "It can run after the active model stops and releases memory.")
        case .smallerProfile:
            return String(localized: "Current capacity needs a smaller safe profile.")
        case .clusterRequired where target.topology.kind == .cluster:
            return String(
                localized: "All cluster members must be reachable and ready before placement."
            )
        case .clusterRequired:
            return String(localized: "This target needs the capacity of a complete cluster.")
        case .incompatible where recipe == nil:
            return String(localized: "This exact signed recipe is not in the target catalogue.")
        case .incompatible:
            return String(localized: "The runtime reports that this recipe is not compatible.")
        case .evidenceUnavailable:
            switch target.freshness {
            case .stale:
                return
                    String(
                        localized:
                            "Cached inventory is visible, but stale capacity cannot support a fit result."
                    )
            case .current, .unavailable:
                return String(
                    localized:
                        "Fresh authenticated inventory and capacity evidence are unavailable."
                )
            }
        }
    }

    private static func recommendation(
        from placements: [ModelLibraryTargetPlacement]
    ) -> ModelLibraryRecommendation? {
        let eligible = placements.filter(\.isEligible).sorted(by: isPreferred)
        guard let placement = eligible.first, let evidenceAt = placement.freshness.observedAt else {
            return nil
        }
        let explanation: String
        if placement.isRunning {
            explanation = String(
                localized: "It is already running here, and current capacity still supports it."
            )
        } else if placement.isInstalled {
            explanation = String(
                localized: "It is already installed here and can start with current capacity."
            )
        } else if placement.fit == .fitsNow {
            explanation = String(
                localized: "This target has the strongest current capacity evidence."
            )
        } else {
            explanation = String(localized: "It can run here after the active model stops.")
        }
        return ModelLibraryRecommendation(
            targetID: placement.id,
            targetName: placement.targetName,
            fit: placement.fit,
            evidenceAt: evidenceAt,
            explanation: explanation
        )
    }

    private static func isPreferred(
        _ left: ModelLibraryTargetPlacement,
        _ right: ModelLibraryTargetPlacement
    ) -> Bool {
        func rank(_ placement: ModelLibraryTargetPlacement) -> Int {
            if placement.isRunning { return 0 }
            if placement.isInstalled, placement.fit == .fitsNow { return 1 }
            if placement.fit == .fitsNow { return 2 }
            return 3
        }
        if rank(left) != rank(right) { return rank(left) < rank(right) }
        let leftMemory = left.availableMemoryBytes ?? -1
        let rightMemory = right.availableMemoryBytes ?? -1
        if leftMemory != rightMemory { return leftMemory > rightMemory }
        let comparison = left.targetName.localizedCaseInsensitiveCompare(right.targetName)
        return comparison == .orderedSame ? left.id < right.id : comparison == .orderedAscending
    }

    private static func topologyLabel(for placements: [ModelLibraryTargetPlacement]) -> String {
        let eligible = placements.filter(\.isEligible)
        let hasStandalone = eligible.contains { $0.topology.kind == .standalone }
        let hasCluster = eligible.contains { $0.topology.kind == .cluster }
        if hasStandalone, hasCluster {
            return String(localized: "Single Spark or complete cluster")
        }
        if hasStandalone { return String(localized: "Single Spark") }
        if hasCluster { return String(localized: "Complete cluster") }
        if placements.contains(where: { $0.fit == .clusterRequired }) {
            return String(localized: "Complete cluster required")
        }
        if placements.allSatisfy({ $0.fit == .evidenceUnavailable }) {
            return String(localized: "Topology evidence unavailable")
        }
        return String(localized: "No compatible topology reported")
    }

    private static func displayVersion(
        recipeRevision: String?,
        sourceRevision: String?
    ) -> String {
        if let recipeRevision, !looksTechnical(recipeRevision) { return recipeRevision }
        if let sourceRevision, !looksTechnical(sourceRevision) { return sourceRevision }
        if recipeRevision != nil || sourceRevision != nil {
            return String(localized: "See technical details")
        }
        return String(localized: "Not reported")
    }

    private static func looksTechnical(_ value: String) -> Bool {
        let normalized = value.lowercased()
        if normalized.hasPrefix("sha256:") || UUID(uuidString: value) != nil { return true }
        return normalized.count >= 40
            && normalized.allSatisfy { $0.isHexDigit }
    }

    private static func taskLabel(for capabilities: Set<String>) -> String {
        let enabled = Set(capabilities.map { $0.lowercased() })
        if enabled.contains("embeddings"), !enabled.contains("chat") {
            return String(localized: "Embeddings")
        }
        if enabled.contains("audio_input") { return String(localized: "Audio and text") }
        if enabled.contains("vision") { return String(localized: "Vision and text") }
        if enabled.contains("chat") || enabled.contains("reasoning") {
            return String(localized: "Text generation")
        }
        return String(localized: "Model inference")
    }

    private static func capabilityLabels(for capabilities: Set<String>) -> [String] {
        let names = [
            "audio_input": String(localized: "Audio input"),
            "chat": String(localized: "Chat"),
            "embeddings": String(localized: "Embeddings"),
            "guided_generation": String(localized: "Structured output"),
            "parallel_tool_calling": String(localized: "Parallel tool calling"),
            "reasoning": String(localized: "Reasoning"),
            "tool_calling": String(localized: "Tool calling"),
            "vision": String(localized: "Vision"),
        ]
        return capabilities.map {
            names[$0.lowercased()] ?? $0.replacingOccurrences(of: "_", with: " ").capitalized
        }
        .sorted()
    }
}
