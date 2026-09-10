import Foundation

/// Reject unsupported model capabilities with actionable errors instead of silent degradation (§39.4/§39.7).
public struct SparkModelCapabilities: Hashable, Codable, Sendable {
    public let toolCalling: Bool
    public let guidedGeneration: Bool
    public let reasoning: Bool
    /// Include the model's trust context in executor identity (§14).
    public let securityContextID: UUID
    /// Bumped when the model's capability set changes.
    public let revision: String

    public init(
        toolCalling: Bool,
        guidedGeneration: Bool,
        reasoning: Bool,
        securityContextID: UUID,
        revision: String
    ) {
        self.toolCalling = toolCalling
        self.guidedGeneration = guidedGeneration
        self.reasoning = reasoning
        self.securityContextID = securityContextID
        self.revision = revision
    }

    public static func textOnly(
        securityContextID: UUID,
        revision: String = "1"
    ) -> SparkModelCapabilities {
        SparkModelCapabilities(
            toolCalling: false,
            guidedGeneration: false,
            reasoning: false,
            securityContextID: securityContextID,
            revision: revision
        )
    }
}

/// Include stable runtime behavior in executor identity while resolving transient addresses and access tokens separately (§39.4).
public struct SparkExecutorConfiguration: Hashable, Sendable {
    public let target: String
    public let modelID: String
    public let securityContextID: UUID
    public let routingPolicyVersion: Int
    public let capabilityRevision: String

    public init(
        target: String,
        modelID: String,
        securityContextID: UUID,
        routingPolicyVersion: Int,
        capabilityRevision: String
    ) {
        self.target = target
        self.modelID = modelID
        self.securityContextID = securityContextID
        self.routingPolicyVersion = routingPolicyVersion
        self.capabilityRevision = capabilityRevision
    }
}

/// Bundle target, capabilities and stable executor identity for the adapter boundary recorded in ADR-018.
public struct SparkLanguageModelDescriptor: Hashable, Sendable {
    public let target: String
    public let modelID: String
    public let capabilities: SparkModelCapabilities

    public init(
        target: String,
        modelID: String,
        capabilities: SparkModelCapabilities
    ) {
        self.target = target
        self.modelID = modelID
        self.capabilities = capabilities
    }

    /// The executor/cache identity (§39.4).
    public func executorConfiguration(routingPolicyVersion: Int) -> SparkExecutorConfiguration {
        SparkExecutorConfiguration(
            target: target,
            modelID: modelID,
            securityContextID: capabilities.securityContextID,
            routingPolicyVersion: routingPolicyVersion,
            capabilityRevision: capabilities.revision
        )
    }

    /// Fail explicitly when requested capabilities exceed the model's declared support (§39.7).
    public func require(
        _ requirement: SparkCapabilityRequirement
    ) -> SparkCapabilityRequirement? {
        let supported: Bool
        switch requirement {
        case .toolCalling: supported = capabilities.toolCalling
        case .guidedGeneration: supported = capabilities.guidedGeneration
        case .reasoning: supported = capabilities.reasoning
        }
        return supported ? nil : requirement
    }
}

/// A capability the caller needs.
public enum SparkCapabilityRequirement: Hashable, Sendable, Error {
    case toolCalling
    case guidedGeneration
    case reasoning

    public var debugDescription: String {
        switch self {
        case .toolCalling:
            String(localized: "the selected Spark model does not declare tool calling")
        case .guidedGeneration:
            String(localized: "the selected Spark model does not declare guided generation")
        case .reasoning:
            String(localized: "the selected Spark model does not declare reasoning output")
        }
    }
}
