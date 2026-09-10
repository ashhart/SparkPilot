import Foundation
import SparkCore

/// Resolve execution target, model and pre-execution consent together (§39.2).
public struct RoutingSelection: Equatable, Sendable {
    public let target: ExecutionTarget
    public let modelID: String?
    public let requiresConsent: Bool
    /// Explain successful target selection as well as routing refusal (§39.11).
    public let explanation: RoutingExplanation

    public init(
        target: ExecutionTarget,
        modelID: String?,
        requiresConsent: Bool,
        explanation: RoutingExplanation = RoutingExplanation(
            location: .appleSystem,
            reason: .fitsOnThisDevice,
            constraint: nil
        )
    ) {
        self.target = target
        self.modelID = modelID
        self.requiresConsent = requiresConsent
        self.explanation = explanation
    }
}

/// The §39.11 decision as values, so the app renders it in its own catalogue copy.
public struct RoutingExplanation: Equatable, Sendable {
    public enum Location: Equatable, Sendable {
        case appleSystem
        case spark(modelID: String?)
        case sparkCluster(modelID: String?)
    }

    public enum Reason: Equatable, Sendable {
        case fitsOnThisDevice
        case largerThanThisDeviceHandles
        case needsSparkMemoryAndContext
        case needsProjectTools
        case imagesStayOnThisDevice
        case policySendsTheWholeImage
        case needsClusterCapacity
    }

    public let location: Location
    public let reason: Reason
    public let constraint: RoutingPolicy.Constraint?

    public init(
        location: Location,
        reason: Reason,
        constraint: RoutingPolicy.Constraint?
    ) {
        self.location = location
        self.reason = reason
        self.constraint = constraint
    }
}

/// Provide a distinct actionable remedy for each routing constraint failure (§39.11).
public enum RoutingError: Error, Sendable, Equatable {
    /// Policy excluded every viable target for the task.
    case noTargetSatisfiesPolicy(task: AITask, constraint: RoutingPolicy.Constraint?)
    /// A target was reachable but nothing was installed on it to run the task.
    case noModelAvailable(task: AITask, target: ExecutionTarget)
    /// The task requires distributed capacity and no cluster is available.
    case clusterRequired(task: AITask)

    /// The constraint that excluded the target, when one did.
    public var constraint: RoutingPolicy.Constraint? {
        if case .noTargetSatisfiesPolicy(_, let constraint) = self { return constraint }
        return nil
    }

    /// The task that could not be routed.
    public var task: AITask {
        switch self {
        case .noTargetSatisfiesPolicy(let task, _): task
        case .noModelAvailable(let task, _): task
        case .clusterRequired(let task): task
        }
    }
}

extension RoutingError: LocalizedError {
    /// Non-interpolated so the whole sentence is one catalogue key the reader's locale can reorder.
    public var errorDescription: String? {
        switch self {
        case .noTargetSatisfiesPolicy:
            String(
                localized:
                    "Your execution policy rules out every target that could run this. Change it in Settings, or choose another target."
            )
        case .noModelAvailable:
            String(
                localized:
                    "No model that can run this is installed on the selected target. Install one from the model catalogue and try again."
            )
        case .clusterRequired:
            String(
                localized:
                    "This needs a Spark cluster, and no compatible cluster is available."
            )
        }
    }
}

/// The catalog facts the router needs.
public struct SparkCatalogSnapshot: Sendable {
    /// Installed model ids known to handle large-context work.
    public var largeContextModelIDs: [String]
    /// Installed model ids for everyday tasks.
    public var generalModelIDs: [String]
    /// The cluster's distributed model, if any.
    public var clusterModelID: String?

    public init(
        largeContextModelIDs: [String] = [],
        generalModelIDs: [String] = [],
        clusterModelID: String? = nil
    ) {
        self.largeContextModelIDs = largeContextModelIDs
        self.generalModelIDs = generalModelIDs
        self.clusterModelID = clusterModelID
    }
}

/// Apply the routing policy and user constraints when choosing a task's execution target (§39.2).
public struct ModelRouter: Sendable {
    private let policy: RoutingPolicy
    private let preferredNodeID: SparkNodeID?

    public init(
        policy: RoutingPolicy = .permissive,
        preferredNodeID: SparkNodeID? = nil
    ) {
        self.policy = policy
        self.preferredNodeID = preferredNodeID
    }

    public func select(
        task: AITask,
        context: IntelligenceContext,
        catalog: SparkCatalogSnapshot
    ) throws -> RoutingSelection {
        let target = try preferredTarget(task: task, context: context, catalog: catalog)

        // Reject empty catalogues before returning a selection with no executable model.
        let model = modelID(for: target, task: task, catalog: catalog)
        if requiresInstalledModel(target), model == nil {
            throw RoutingError.noModelAvailable(task: task, target: target)
        }

        return RoutingSelection(
            target: target,
            modelID: model,
            requiresConsent: policy.askBeforeRemoteExecution && isRemote(target),
            explanation: explain(task: task, target: target, model: model)
        )
    }

    private func requiresInstalledModel(_ target: ExecutionTarget) -> Bool {
        switch target {
        // The system model is part of the OS; there is nothing to install.
        case .appleSystem: false
        case .spark, .sparkCluster: true
        }
    }

    /// The §39.11 decision, as values the app renders in its own catalogue copy.
    private func explain(
        task: AITask,
        target: ExecutionTarget,
        model: String?
    ) -> RoutingExplanation {
        let location: RoutingExplanation.Location =
            switch target {
            case .appleSystem: .appleSystem
            case .spark: .spark(modelID: model)
            case .sparkCluster: .sparkCluster(modelID: model)
            }
        let reason: RoutingExplanation.Reason
        switch task {
        case .shortRewrite, .summariseSmallText, .classify, .privateSearch:
            reason =
                target == .appleSystem ? .fitsOnThisDevice : .largerThanThisDeviceHandles
        case .analyseLargeDocument:
            reason = .needsSparkMemoryAndContext
        case .codeReview, .codingAgent:
            reason = .needsProjectTools
        case .visionAnalysis:
            // Claim on-device image preprocessing only when the selected path actually performs it.
            reason = target == .appleSystem ? .imagesStayOnThisDevice : .policySendsTheWholeImage
        case .hugeModelReasoning:
            reason = .needsClusterCapacity
        }
        return RoutingExplanation(
            location: location,
            reason: reason,
            constraint: policy.constraint
        )
    }

    // MARK: - §39.2 default table

    private func preferredTarget(
        task: AITask,
        context: IntelligenceContext,
        catalog: SparkCatalogSnapshot
    ) throws -> ExecutionTarget {
        let wantsSparkCapacity: Bool
        switch task {
        case .shortRewrite, .summariseSmallText, .classify, .privateSearch:
            wantsSparkCapacity = context.approximateInputBytes > 200_000
        case .visionAnalysis:
            // Vision runs on-device first; Spark fallback is explicit.
            wantsSparkCapacity = false
        case .analyseLargeDocument, .codeReview, .codingAgent, .hugeModelReasoning:
            wantsSparkCapacity = true
        }

        let sparkNode = context.preferredNodeID ?? preferredNodeID
        let cluster = context.preferredClusterID

        func sparkTarget() throws -> ExecutionTarget {
            if task == .hugeModelReasoning {
                // Require distributed cluster capacity for tasks that request it instead of silently selecting one node.
                guard let cluster, let model = catalog.clusterModelID else {
                    throw RoutingError.clusterRequired(task: task)
                }
                return .sparkCluster(clusterID: cluster, modelID: model)
            }
            guard let node = sparkNode else {
                throw RoutingError.noTargetSatisfiesPolicy(
                    task: task,
                    constraint: policy.constraint
                )
            }
            return .spark(nodeID: node, modelID: "")
        }

        let chosen: ExecutionTarget
        switch policy.constraint {
        case .onDeviceOnly:
            if wantsSparkCapacity {
                throw RoutingError.noTargetSatisfiesPolicy(task: task, constraint: .onDeviceOnly)
            }
            chosen = .appleSystem
        case .sparkOnly:
            chosen = try sparkTarget()
        case .myHardwareOnly, nil:
            // Keep cluster selection centralized in sparkTarget().
            chosen = wantsSparkCapacity ? try sparkTarget() : .appleSystem
        }

        // Evaluate hardware ownership explicitly for every execution target (§39.2).
        if policy.constraint == .myHardwareOnly, !chosen.isOwnerHardware {
            throw RoutingError.noTargetSatisfiesPolicy(task: task, constraint: .myHardwareOnly)
        }
        return chosen
    }

    private func modelID(
        for target: ExecutionTarget,
        task: AITask,
        catalog: SparkCatalogSnapshot
    ) -> String? {
        switch target {
        case .appleSystem:
            return nil
        case .spark(_, let modelID):
            return modelID.isEmpty
                ? catalog.largeContextModelIDs.first ?? catalog.generalModelIDs.first
                : modelID
        case .sparkCluster(_, let modelID):
            return modelID.isEmpty ? catalog.clusterModelID : modelID
        }
    }

    private func isRemote(_ target: ExecutionTarget) -> Bool {
        switch target {
        case .appleSystem: false
        case .spark, .sparkCluster: true
        }
    }
}
