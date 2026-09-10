import Foundation
import SparkAPI
import SparkCore

extension TargetOperationalSnapshotComposer {

    func memberSnapshots(
        entry: LibraryEntry,
        status: TimedOperationalEvidence<SparkStatus>?,
        observedAt: Date?
    ) -> [TargetMemberSnapshot] {
        if case .cluster = entry.logicalKey, let reported = status?.value.cluster?.members {
            return reported.map {
                TargetMemberSnapshot(
                    nodeID: $0.nodeID,
                    displayName: $0.name,
                    role: SparkNodeRole(rawValue: $0.role) ?? .worker,
                    reachable: $0.reachable,
                    linkHealth: $0.qsfpHealth,
                    lastSuccessfulContact: status?.observedAt
                )
            }
        }
        return entry.members.map {
            TargetMemberSnapshot(
                nodeID: $0.nodeID,
                displayName: $0.name,
                role: $0.role,
                reachable: status == nil ? $0.reachable : true,
                lastSuccessfulContact: status?.observedAt ?? $0.lastSeen ?? observedAt
            )
        }
    }

    func placementSnapshots(
        inventory: TimedOperationalEvidence<ModelCatalogue>?,
        inference: TimedOperationalEvidence<ActiveInference>?,
        status: TimedOperationalEvidence<SparkStatus>?,
        cached: TargetOperationalSnapshot?,
        evidenceFreshness: OperationalEvidenceFreshness
    ) -> [ModelPlacementSnapshot] {
        guard let inventory else {
            return (cached?.placements ?? []).map {
                ModelPlacementSnapshot(
                    identity: $0.identity,
                    displayName: $0.displayName,
                    state: $0.state,
                    evidence: evidenceFreshness,
                    technicalDetails: $0.technicalDetails,
                    warnings: $0.warnings,
                    blockers: $0.blockers
                )
            }
        }
        let inferenceState =
            inference?.value.state
            ?? status.flatMap { SparkInferenceState(rawValue: $0.value.inference.state) }
        let activeModelID = inference?.value.modelID ?? status?.value.inference.modelID
        return inventory.value.items.compactMap { model in
            guard let recipe = model.recipeRevision, !recipe.isEmpty else { return nil }
            let identity = ModelPlacementIdentity(modelID: model.id, recipeRevision: recipe)
            let state = placementState(
                model: model,
                isActive: model.id == activeModelID,
                inferenceState: inferenceState
            )
            let blockers: [OperationalNotice]
            if model.installState == .unverified {
                blockers = [
                    OperationalNotice(
                        code: "model.recipe_unverified",
                        message: String(
                            localized: "The recipe identity is present but not verified."
                        )
                    )
                ]
            } else if state == .incompatible {
                blockers = [
                    OperationalNotice(
                        code: "model.incompatible",
                        message: String(
                            localized: "This signed recipe is incompatible with the target."
                        )
                    )
                ]
            } else {
                blockers = []
            }
            return ModelPlacementSnapshot(
                identity: identity,
                displayName: model.displayName,
                state: state,
                evidence: evidenceFreshness,
                technicalDetails: ModelPlacementTechnicalDetails(
                    modelID: model.id,
                    recipeRevision: recipe,
                    sourceRevision: model.sourceRevision,
                    visionSupported: model.capabilities["vision"]
                ),
                blockers: blockers
            )
        }
    }

    private func placementState(
        model: SparkModel,
        isActive: Bool,
        inferenceState: SparkInferenceState?
    ) -> ModelPlacementState {
        if isActive, let inferenceState {
            switch inferenceState {
            case .loading:
                return .starting
            case .ready, .idle:
                return .running
            case .draining, .unloading:
                return .stopping
            case .failed:
                return .failed
            case .unloaded:
                break
            }
        }
        switch model.installState {
        case .available:
            return .available
        case .downloading, .verifying:
            return .downloading
        case .installed:
            return .installed
        case .failed:
            return .failed
        case .incompatible:
            return .incompatible
        case .unverified:
            return .unknown
        }
    }

    func activeInferenceSnapshot(
        evidence: TargetOperationalEvidence,
        placements: [ModelPlacementSnapshot],
        cached: TargetOperationalSnapshot?
    ) -> ActiveInferenceSnapshot? {
        if let active = evidence.inference?.value {
            let identity = placements.first {
                $0.technicalDetails.modelID == active.modelID
            }?.identity
            return ActiveInferenceSnapshot(
                state: active.state,
                modelIdentity: identity,
                profileID: active.profileID,
                contextLength: active.contextLength,
                activeRequests: active.activeRequests,
                queueDepth: active.queueDepth,
                tokensPerSecond: active.tokensPerSecond,
                timeToFirstTokenMilliseconds: active.timeToFirstTokenMs
            )
        }
        if let status = evidence.status?.value,
            let state = SparkInferenceState(rawValue: status.inference.state)
        {
            let identity = placements.first {
                $0.technicalDetails.modelID == status.inference.modelID
            }?.identity
            return ActiveInferenceSnapshot(
                state: state,
                modelIdentity: identity,
                profileID: status.inference.profileID,
                contextLength: nil,
                activeRequests: status.inference.activeRequests,
                queueDepth: status.inference.queueDepth,
                tokensPerSecond: status.inference.tokensPerSecond,
                timeToFirstTokenMilliseconds: status.inference.timeToFirstTokenMs
            )
        }
        return cached?.activeInference
    }

    func vllmHealth(evidence: TargetOperationalEvidence) -> VLLMHealthState? {
        let state =
            evidence.inference?.value.state
            ?? evidence.status.flatMap { SparkInferenceState(rawValue: $0.value.inference.state) }
        guard let state else { return nil }
        switch state {
        case .unloaded:
            return .stopped
        case .loading:
            return .starting
        case .ready, .idle:
            return .ready
        case .draining, .unloading:
            return .stopping
        case .failed:
            return .failed
        }
    }
}
