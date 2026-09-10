import Foundation
import SparkAPI

/// Errors surfaced by the Spark inference path (§39.6/§39.7/§39.9).
public enum SparkInferenceError: Error, Sendable, Equatable {
    /// Require explicit owner confirmation for downloads rather than starting them from generation requests.
    case modelNotInstalled(modelID: String)
    /// Another model is loaded; replacing it requires explicit consent.
    case modelReplacementRequired(activeModelID: String, requestedModelID: String)
    /// Reject transcript content or options the proxy cannot represent (§39.6).
    case unsupportedContent(String)
    /// A capability the caller required is not declared by the model.
    case unsupportedCapability(String)
    /// The load was requested but did not become ready in time.
    case readinessTimeout(modelID: String)
    /// Upstream transport failure.
    case transport(String)
}

/// Why `ensureReady` is running; audit-friendly.
public enum PrewarmReason: String, Sendable {
    case foundationModelsPrewarm
    case generationRequest
    case explicitUserAction
}

/// Inject typed engine readiness probes for active inference and durable model loading.
public protocol EngineReadinessProbing: Sendable {
    /// The currently active/loaded model, if any.
    func activeModelID() async throws -> String?
    /// Whether the model is installed (downloaded and verified).
    func isInstalled(modelID: String) async throws -> Bool
    /// Wait for engine readiness after starting a durable load, propagating failures.
    func startLoad(modelID: String) async throws
}

/// Apply readiness policy before streaming through the allowlisted proxy (§39.9).
public protocol SparkInferenceStreaming: Sendable {
    func ensureReady(modelID: String, reason: PrewarmReason) async throws
    func stream(
        modelID: String,
        request: ChatCompletionRequest
    ) async throws -> AsyncThrowingStream<ChatStreamEvent, any Error>
}

/// Combine engine readiness policy with allowlisted proxy streaming.
public struct SparkInferenceClient: SparkInferenceStreaming {
    private let probes: any EngineReadinessProbing
    private let chat: ChatStreaming

    public init(probes: any EngineReadinessProbing, chat: ChatStreaming) {
        self.probes = probes
        self.chat = chat
    }

    /// Await installed-model loading, require explicit replacement, and reject missing models without automatic download (§39.9).
    public func ensureReady(modelID: String, reason: PrewarmReason) async throws {
        let active = try await probes.activeModelID()
        if active == modelID {
            return
        }

        // Check installation before replacement so an absent model cannot prompt a useless unload of active work.
        guard try await probes.isInstalled(modelID: modelID) else {
            throw SparkInferenceError.modelNotInstalled(modelID: modelID)
        }
        if let active {
            throw SparkInferenceError.modelReplacementRequired(
                activeModelID: active,
                requestedModelID: modelID
            )
        }
        try await probes.startLoad(modelID: modelID)
    }

    public func stream(
        modelID: String,
        request: ChatCompletionRequest
    ) async throws -> AsyncThrowingStream<ChatStreamEvent, any Error> {
        try await ensureReady(modelID: modelID, reason: .generationRequest)
        return try await chat.stream(request)
    }
}

/// Inject the narrow streaming transport so tests can supply synthetic chat events.
public protocol ChatStreaming: Sendable {
    func stream(_ request: ChatCompletionRequest) async throws
        -> AsyncThrowingStream<ChatStreamEvent, any Error>
}

extension ChatClient: ChatStreaming {}
