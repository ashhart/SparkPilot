import Foundation
import SparkCore

public struct ModelCatalogue: Sendable, Equatable, Decodable {
    public let items: [SparkModel]
    public let nextCursor: String?

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
    }
}

public struct SparkModel: Sendable, Equatable, Decodable, Identifiable {
    public let id: String
    public let displayName: String
    public let description: String?
    public let recipeRevision: String?
    public let sourceRevision: String?
    public let sourceProvider: String?
    public let gated: Bool?
    /// Who published the model weights. Older runtimes omit it.
    public let publisher: String?
    public let publisherURL: String?
    public let licenceURL: String?
    /// Identify the serving recipe author separately from the model publisher when the runtime reports it.
    public let recipeSource: SparkModelRecipeSource?
    public let installState: SparkModelInstallState
    public let totalBytes: Int64?
    public let capabilities: [String: Bool]
    public let fit: String?
    public let profiles: [SparkModelProfile]

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case description
        case recipeRevision = "recipe_revision"
        case sourceRevision = "source_revision"
        case sourceProvider = "source_provider"
        case gated
        case publisher
        case publisherURL = "publisher_url"
        case licenceURL = "licence_url"
        case recipeSource = "recipe_source"
        case installState = "install_state"
        case totalBytes = "total_bytes"
        case capabilities
        case fit
        case profiles
    }

    /// Combine available model and recipe provenance for cards, returning nil when neither exists.
    public var provenanceLine: String? {
        var parts: [String] = []
        if let publisher, !publisher.isEmpty { parts.append(publisher) }
        if let recipeSource, !recipeSource.name.isEmpty {
            parts.append(String(localized: .recipeBy(recipeSource.name)))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

public struct SparkModelRecipeSource: Sendable, Equatable, Decodable {
    public let name: String
    public let url: String
    public let revision: String?

    public init(name: String, url: String, revision: String? = nil) {
        self.name = name
        self.url = url
        self.revision = revision
    }
}

public struct SparkModelProfile: Sendable, Equatable, Decodable, Identifiable {
    public let id: String
    public let displayName: String
    public let maxModelLength: Int
    public let maxSequences: Int
    public let expectedPeakBytes: Int64
    public let measuredPeakBytes: Int64?
    public let safe: Bool
    public let idlePolicy: String?
    public let supportedIdlePolicies: [String]?
    public var idleTimeoutSeconds: Int? = nil
    public var supportsCustomIdleTimeout: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case maxModelLength = "max_model_length"
        case maxSequences = "max_sequences"
        case expectedPeakBytes = "expected_peak_bytes"
        case measuredPeakBytes = "measured_peak_bytes"
        case safe
        case idlePolicy = "idle_policy"
        case supportedIdlePolicies = "supported_idle_policies"
        case idleTimeoutSeconds = "idle_timeout_seconds"
        case supportsCustomIdleTimeout = "supports_custom_idle_timeout"
    }
}

public struct ActiveInference: Sendable, Equatable, Decodable {
    public let state: SparkInferenceState
    public let modelID: String?
    public let profileID: String?
    public let contextLength: Int?
    public let activeRequests: Int
    public let queueDepth: Int
    public let tokensPerSecond: Double?
    public let timeToFirstTokenMs: Double?
    /// What the most recent stop found about unified memory; present only while nothing is loaded.
    public var lastUnload: ActiveInferenceUnloadEvidence? = nil

    enum CodingKeys: String, CodingKey {
        case state
        case modelID = "model_id"
        case profileID = "profile_id"
        case contextLength = "context_length"
        case activeRequests = "active_requests"
        case queueDepth = "queue_depth"
        case tokensPerSecond = "tokens_per_second"
        case timeToFirstTokenMs = "time_to_first_token_ms"
        case lastUnload = "last_unload"
    }
}

/// memoryRecovered false means the engine stopped but unified memory did not return to its pre-load baseline.
public struct ActiveInferenceUnloadEvidence: Sendable, Equatable, Decodable {
    public let modelID: String
    public let memoryRecovered: Bool
    public let baselineBytes: Int64
    public let availableBytes: Int64
    public let finishedAt: String

    public init(
        modelID: String,
        memoryRecovered: Bool,
        baselineBytes: Int64,
        availableBytes: Int64,
        finishedAt: String
    ) {
        self.modelID = modelID
        self.memoryRecovered = memoryRecovered
        self.baselineBytes = baselineBytes
        self.availableBytes = availableBytes
        self.finishedAt = finishedAt
    }

    /// Memory still held back compared with the moment before the model loaded.
    public var shortfallBytes: Int64 { max(0, baselineBytes - availableBytes) }

    enum CodingKeys: String, CodingKey {
        case modelID = "model_id"
        case memoryRecovered = "memory_recovered"
        case baselineBytes = "baseline_bytes"
        case availableBytes = "available_bytes"
        case finishedAt = "finished_at"
    }
}

/// Decode the four-value memory-pressure contract, with runtime draining/recovery represented as critical until verified.
public enum MemoryPressure: String, Sendable, Equatable, CaseIterable, Decodable {
    case normal
    case warning
    case critical
    case emergency
}
