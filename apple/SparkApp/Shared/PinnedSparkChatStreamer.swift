import Foundation
import Observation
import SparkAPI
import SparkCore
import SparkLanguageModel
import SparkLibrary
import SparkSecurity
import SparkTransport

public enum SparkChatConnectionError: Error, Equatable, Sendable {
    case identityMismatch
    case activeModelChanged
}

/// One turn's events and, when the Spark answered with the web tools, the pages it drew on.
public struct SparkChatAnswer: Sendable {
    public let events: AsyncThrowingStream<ChatStreamEvent, any Error>
    public let webSources: [GeneratedAPI.WebSource]

    public init(
        events: AsyncThrowingStream<ChatStreamEvent, any Error>,
        webSources: [GeneratedAPI.WebSource] = []
    ) {
        self.events = events
        self.webSources = webSources
    }
}

public protocol SparkChatStreaming: Sendable {
    func stream(
        target: SparkChatTarget,
        request: ChatCompletionRequest
    ) async throws -> AsyncThrowingStream<ChatStreamEvent, any Error>

    /// The same turn, answered by the Spark with the web tools when this conversation was switched on.
    func answer(
        target: SparkChatTarget,
        request: ChatCompletionRequest,
        webAccess: Bool
    ) async throws -> SparkChatAnswer
}

extension SparkChatStreaming {
    /// A streamer that knows nothing about the web answers the ordinary way, so every existing one still conforms.
    public func answer(
        target: SparkChatTarget,
        request: ChatCompletionRequest,
        webAccess: Bool
    ) async throws -> SparkChatAnswer {
        SparkChatAnswer(events: try await stream(target: target, request: request))
    }
}

private struct CurrentModelReadinessProbe: EngineReadinessProbing {
    let api: SparkAPIClient
    let route: URL

    func activeModelID() async throws -> String? {
        let active = try await api.activeInference(route: route)
        guard active.state == .ready || active.state == .idle else { return nil }
        return active.modelID
    }

    func isInstalled(modelID: String) async throws -> Bool {
        try await api.models(route: route).items.contains {
            $0.id == modelID && $0.installState == .installed
        }
    }

    func startLoad(modelID: String) async throws {
        // Stream only after authenticated evidence marks the selected model active; lifecycle loading and confirmation occur separately.
        throw SparkChatConnectionError.activeModelChanged
    }
}

public struct PinnedSparkChatStreamer: SparkChatStreaming {
    public init() {}

    public func stream(
        target: SparkChatTarget,
        request: ChatCompletionRequest
    ) async throws -> AsyncThrowingStream<ChatStreamEvent, any Error> {
        let signer = try DeviceIdentityStore.loadOrCreateSigner(nodeID: target.nodeID.rawValue)
        let api = try SparkAPIClient.pinned(to: target.tlsFingerprint, signer: signer)
        let identity = try await api.identity(route: target.route)
        guard identity.nodeID == target.nodeID,
            identity.clusterID == target.clusterID,
            identity.authorityFingerprint == target.authorityFingerprint
        else {
            throw SparkChatConnectionError.identityMismatch
        }

        if request.messages.contains(where: { !$0.imageDataURLs.isEmpty }) {
            let models = try await api.models(route: target.route)
            guard
                models.items.first(where: { $0.id == target.modelID })?.capabilities["vision"]
                    == true
            else {
                throw SparkAttachmentError.visionUnavailable
            }
        }
        let chat = try ChatClient(
            baseURL: target.route,
            pin: target.tlsFingerprint,
            signer: signer
        )
        let inference = SparkInferenceClient(
            probes: CurrentModelReadinessProbe(api: api, route: target.route),
            chat: chat
        )
        return try await inference.stream(modelID: target.modelID, request: request)
    }
}
