import Foundation

/// The intelligence capability a feature requests — never a URL (§39.1).
public enum AITask: Hashable, Sendable, CaseIterable {
    case shortRewrite
    case summariseSmallText
    case classify
    case analyseLargeDocument
    case codeReview
    case codingAgent
    case visionAnalysis
    case privateSearch
    case hugeModelReasoning
}

/// Always expose the resolved execution target because routing changes are user-visible (§39.2).
public enum ExecutionTarget: Hashable, Sendable {
    /// The on-device Apple system model.
    case appleSystem
    /// A Spark node's local model.
    case spark(nodeID: SparkNodeID, modelID: String)
    /// A distributed model across a two-Spark cluster.
    case sparkCluster(clusterID: SparkClusterID, modelID: String)

    /// Require every execution-target case to state whether it satisfies the owner's hardware-only policy (§39.2).
    public var isOwnerHardware: Bool {
        switch self {
        case .appleSystem: true
        case .spark: true
        case .sparkCluster: true
        }
    }
}

/// Require consent for allowed remote targets when askBeforeRemoteExecution is enabled (§39.2).
public struct RoutingPolicy: Hashable, Sendable {
    public enum Constraint: Hashable, Sendable {
        /// Apple system model only.
        case onDeviceOnly
        /// The user's own hardware only (system model + Sparks).
        case myHardwareOnly
        /// Sparks only.
        case sparkOnly
    }

    public var constraint: Constraint?
    public var askBeforeRemoteExecution: Bool

    public init(
        constraint: Constraint? = nil,
        askBeforeRemoteExecution: Bool = false
    ) {
        self.constraint = constraint
        self.askBeforeRemoteExecution = askBeforeRemoteExecution
    }

    public static let permissive = RoutingPolicy()
}

/// Context for one routing decision.
public struct IntelligenceContext: Sendable {
    public let instructions: String?
    public let approximateInputBytes: Int
    public let preferredNodeID: SparkNodeID?
    public let preferredClusterID: SparkClusterID?

    public init(
        instructions: String? = nil,
        approximateInputBytes: Int = 0,
        preferredNodeID: SparkNodeID? = nil,
        preferredClusterID: SparkClusterID? = nil
    ) {
        self.instructions = instructions
        self.approximateInputBytes = approximateInputBytes
        self.preferredNodeID = preferredNodeID
        self.preferredClusterID = preferredClusterID
    }
}
