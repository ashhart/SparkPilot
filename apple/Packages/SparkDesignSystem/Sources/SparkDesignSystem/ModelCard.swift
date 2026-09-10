import Foundation
import SparkCore

/// Display data for one model row (§41.7).
public struct ModelCardState: Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let publisher: String
    public let state: SparkModelUIState
    public let totalBytes: Int64?
    public let capabilities: [ModelCapability]
    public let recommendedProfile: String?
    public let lastMeasuredSpeed: String?

    public enum ModelCapability: String, Equatable, Sendable {
        case chat
        case reasoning
        case toolCalling
        case vision
        case embeddings
        case guidedGeneration

        public var label: String {
            switch self {
            case .chat: return String(localized: "Chat")
            case .reasoning: return String(localized: "Reasoning")
            case .toolCalling: return String(localized: "Tools")
            case .vision: return String(localized: "Vision")
            case .embeddings: return String(localized: "Embeddings")
            case .guidedGeneration: return String(localized: "Guided")
            }
        }
    }

    /// Show recipe authorship beside model publisher provenance when reported by the runtime.
    public let recipeSource: String?

    public init(
        id: String,
        displayName: String,
        publisher: String,
        state: SparkModelUIState,
        totalBytes: Int64?,
        capabilities: [ModelCapability],
        recommendedProfile: String?,
        lastMeasuredSpeed: String?,
        recipeSource: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.publisher = publisher
        self.state = state
        self.totalBytes = totalBytes
        self.capabilities = capabilities
        self.recommendedProfile = recommendedProfile
        self.lastMeasuredSpeed = lastMeasuredSpeed
        self.recipeSource = recipeSource
    }

    /// "NVIDIA · recipe by vLLM Recipes", or just the publisher.
    public var provenance: String {
        guard let recipeSource, !recipeSource.isEmpty else { return publisher }
        return String(localized: .modelProvenance(publisher: publisher, recipeSource: recipeSource))
    }
}

/// Maps the server `install_state` + `fit` into the §29.4 UI state.
public enum ModelUIStateMapping {
    /// Map unfamiliar Model.fit values to the safe unknown state.
    public static func resolve(installState: String, fit: String, requiresCluster: Bool = false)
        -> SparkModelUIState
    {
        switch installState {
        case "available": break  // fall through to fit
        case "downloading": return .downloading
        case "verifying": return .verifying
        case "installed": return .ready
        case "failed": return .failedWithRecovery
        case "incompatible": return .incompatible
        case "unverified": return .unverified
        default: return .available
        }
        switch fit {
        case "ready": return .ready
        case "fits", "fits_after_unload": return .available
        case "smaller_profile_required": return .incompatible
        case "cluster_required": return .requiresTwoSparks
        case "incompatible": return .incompatible
        default: return .available
        }
    }
}

/// Human-readable state copy for the model rows (§29.4, §62.2).
public struct ModelStateCopy {
    public static func title(for state: SparkModelUIState) -> String {
        switch state {
        case .available: return String(localized: "Available to install")
        case .downloading: return String(localized: "Downloading model")
        case .verifying: return String(localized: "Checking model integrity")
        case .installed, .ready: return String(localized: "Ready")
        case .unloaded: return String(localized: "Unloaded")
        case .updateAvailable: return String(localized: "Update available")
        case .incompatible: return String(localized: "Does not fit this Spark")
        case .requiresTwoSparks: return String(localized: "Requires two Sparks")
        case .unverified: return String(localized: "Unverified model")
        case .licenceActionRequired: return String(localized: "Licence action required")
        case .failedWithRecovery: return String(localized: "Model needs attention")
        }
    }
}

/// View model feeding the model list screen.
@MainActor
@Observable
public final class ModelListViewModel {
    public private(set) var cards: [ModelCardState] = []

    public init() {}

    public func apply(items: [NetworkModelItem]) {
        cards = items.map { item in
            let state = ModelUIStateMapping.resolve(
                installState: item.installState,
                fit: item.fit
            )
            return ModelCardState(
                id: item.id,
                displayName: item.displayName,
                publisher: item.publisher,
                state: state,
                totalBytes: item.totalBytes,
                capabilities: Self.capabilities(item.capabilities),
                recommendedProfile: item.recommendedProfile,
                lastMeasuredSpeed: item.lastMeasuredSpeed,
                recipeSource: item.recipeSource
            )
        }
        .sorted { $0.displayName < $1.displayName }
    }

    public func card(id: String) -> ModelCardState? {
        cards.first { $0.id == id }
    }

    private static func capabilities(_ flags: [String: Bool]) -> [ModelCardState.ModelCapability] {
        var result: [ModelCardState.ModelCapability] = []
        if flags["chat"] == true { result.append(.chat) }
        if flags["reasoning"] == true { result.append(.reasoning) }
        if flags["tool_calling"] == true { result.append(.toolCalling) }
        if flags["vision"] == true { result.append(.vision) }
        if flags["embeddings"] == true { result.append(.embeddings) }
        if flags["guided_generation"] == true { result.append(.guidedGeneration) }
        return result
    }
}

/// Wire-shaped item decodable from the `/api/v1/models` response.
public struct NetworkModelItem: Decodable, Sendable, Equatable {
    public let id: String
    public let displayName: String
    public let publisher: String
    public let installState: String
    public let fit: String
    public let totalBytes: Int64?
    public let capabilities: [String: Bool]
    public let recommendedProfile: String?
    public let lastMeasuredSpeed: String?
    /// Who wrote the serving recipe, when the runtime reports it.
    public let recipeSource: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case description
        case publisher
        case recipeSource = "recipe_source"
        case installState = "install_state"
        case fit
        case totalBytes = "total_bytes"
        case capabilities
        case profiles
    }

    private struct RecipeSource: Decodable {
        let name: String
    }

    /// Only the identifier is read; the runtime's other profile fields are numbers and booleans.
    private struct ProfileReference: Decodable {
        let id: String
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.displayName = try c.decode(String.self, forKey: .displayName)
        self.installState = try c.decode(String.self, forKey: .installState)
        self.fit = try c.decode(String.self, forKey: .fit)
        self.totalBytes = try c.decodeIfPresent(Int64.self, forKey: .totalBytes)
        self.capabilities = try c.decodeIfPresent([String: Bool].self, forKey: .capabilities) ?? [:]
        // Keep catalogue entries usable when older runtimes omit publisher metadata.
        self.publisher =
            try c.decodeIfPresent(String.self, forKey: .publisher)
            ?? String(localized: "Spark Catalogue")
        self.recipeSource = try c.decodeIfPresent(RecipeSource.self, forKey: .recipeSource)?.name
        let profiles = try c.decodeIfPresent([ProfileReference].self, forKey: .profiles) ?? []
        self.recommendedProfile = profiles.first?.id
        self.lastMeasuredSpeed = nil
    }
}
