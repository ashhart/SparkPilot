import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing
@testable import SparkAppComposition

func modelLibraryTestRecipeEvidence(
    id: String = "spark/model-8b",
    name: String = "Model 8B",
    revision: String? = "2026.08.1",
    sourceRevision: String? = "source-r1",
    state: SparkModelInstallState = .available,
    fit: String? = "fits",
    capabilities: Set<String> = ["chat", "reasoning"],
    bytes: Int64? = 8_000_000_000
) -> ModelLibraryRecipeEvidence {
    ModelLibraryRecipeEvidence(
        modelID: id,
        displayName: name,
        summary: "A compact reasoning model",
        recipeRevision: revision,
        sourceRevision: sourceRevision,
        installState: state,
        downloadBytes: bytes,
        capabilities: capabilities,
        rawFit: fit,
        profiles: [
            ModelLibraryProfileEvidence(
                id: "balanced",
                name: "Balanced",
                expectedPeakBytes: 12_000_000_000,
                isSafe: true
            )
        ]
    )
}

func modelLibraryTestTargetEvidence(
    id: String,
    name: String,
    topology: ModelLibraryTargetTopology = .standalone,
    freshness: ModelLibraryEvidenceFreshness = .current(
        observedAt: modelLibraryTestLibraryEvidenceDate
    ),
    memory: Int64? = 64_000_000_000,
    activeModelID: String? = nil,
    inferenceState: SparkInferenceState? = nil,
    recipes: [ModelLibraryRecipeEvidence]
) -> ModelLibraryTargetEvidence {
    ModelLibraryTargetEvidence(
        id: id,
        name: name,
        connectionLabel: freshness.isCurrent ? "Local Wi-Fi" : "Offline",
        topology: topology,
        freshness: freshness,
        availableMemoryBytes: memory,
        runtimeVersion: "0.1.0",
        activeModelID: activeModelID,
        activeInferenceState: inferenceState,
        recipes: recipes
    )
}

func modelLibraryTestOperationalFreshness(
    inventory: OperationalFreshnessState = .current,
    memory: OperationalFreshnessState = .current
) -> TargetEvidenceFreshness {
    func evidence(
        _ state: OperationalFreshnessState,
        staleAfter: TimeInterval = 60
    ) -> OperationalEvidenceFreshness {
        let observedAt: Date? = state == .missing ? nil : modelLibraryTestLibraryEvidenceDate
        return OperationalEvidenceFreshness(
            observedAt: observedAt,
            evaluatedAt: state == .stale
                ? modelLibraryTestLibraryEvidenceDate.addingTimeInterval(staleAfter + 1)
                : modelLibraryTestLibraryEvidenceDate,
            staleAfter: staleAfter
        )
    }

    return TargetEvidenceFreshness(
        health: evidence(.current),
        inventory: evidence(inventory),
        memory: evidence(memory),
        inference: evidence(.current),
        operations: evidence(.current)
    )
}

func modelLibraryTestSharedOperationalSnapshot(
    identity: SparkTargetIdentity,
    members: [TargetMemberSnapshot],
    evidence: TargetEvidenceFreshness,
    placementState: ModelPlacementState = .available
) -> TargetOperationalSnapshot {
    let placementIdentity = ModelPlacementIdentity(
        modelID: "spark/model-8b",
        recipeRevision: "2026.08.1"
    )
    return TargetOperationalSnapshot(
        identity: identity,
        displayName: "Shared target",
        members: members,
        preferredRoute: nil,
        connectionState: .connectedWiFi,
        lastSuccessfulContact: modelLibraryTestLibraryEvidenceDate,
        evaluatedAt: modelLibraryTestLibraryEvidenceDate,
        evidence: evidence,
        runtime: TargetRuntimeSnapshot(
            version: "0.2.0",
            health: .healthy,
            updateState: .current
        ),
        vllmHealth: .stopped,
        unifiedMemory: UnifiedMemorySnapshot(
            totalBytes: 128_000_000_000,
            availableBytes: 64_000_000_000,
            pressure: .normal
        ),
        disk: nil,
        installedModelCount: 0,
        activeInference: nil,
        operations: [],
        placements: [
            ModelPlacementSnapshot(
                identity: placementIdentity,
                displayName: "Model 8B",
                state: placementState,
                evidence: evidence.inventory,
                technicalDetails: ModelPlacementTechnicalDetails(
                    modelID: placementIdentity.modelID,
                    recipeRevision: placementIdentity.recipeRevision,
                    sourceRevision: "source-r1"
                )
            )
        ],
        warnings: [],
        blockers: [],
        technicalDetails: TargetTechnicalDetails(
            logicalIdentity: identity.description,
            memberNodeIDs: members.map(\.nodeID)
        )
    )
}

func modelLibraryTestSharedCatalogue() throws -> ModelCatalogue {
    try modelLibraryTestLibraryDecode(
        """
        {"items":[{"id":"spark/model-8b","display_name":"Model 8B","description":"Compact","recipe_revision":"2026.08.1","source_revision":"source-r1","install_state":"available","total_bytes":8000000000,"capabilities":{"chat":true},"fit":"ready","profiles":[]}],"next_cursor":null}
        """
    )
}
