import Foundation
import SparkAPI
import SparkCore
import SparkLanguageModel
import SparkTransport

/// The body of a web-tools turn: the conversation, with the owner's own calendar and reminders taken out.
enum SparkChatWebAnswerBody {
    /// The web tool loop composes its searches from these turns, so the personal-context block never enters it.
    static func request(model: String, messages: [ChatMessage]) -> GeneratedAPI.WebAnswerRequest {
        GeneratedAPI.WebAnswerRequest(
            model: model,
            messages: messages.compactMap { message in
                let content = SparkChatPersonalSummary.withoutBlock(message.content)
                guard !content.isEmpty else { return nil }
                return GeneratedAPI.WebAnswerMessage(
                    role: GeneratedAPI.WebAnswerMessageRole(rawValue: message.role) ?? .user,
                    content: content
                )
            },
            systemInstruction: nil
        )
    }
}

/// A conversation turn the Spark answers itself, with the web tools, and hands back as one stream event.
extension PinnedSparkChatStreamer {
    public func answer(
        target: SparkChatTarget,
        request: ChatCompletionRequest,
        webAccess: Bool
    ) async throws -> SparkChatAnswer {
        guard webAccess else {
            return SparkChatAnswer(events: try await stream(target: target, request: request))
        }
        let signer = try DeviceIdentityStore.loadOrCreateSigner(nodeID: target.nodeID.rawValue)
        let api = try SparkAPIClient.pinned(to: target.tlsFingerprint, signer: signer)
        let identity = try await api.identity(route: target.route)
        guard identity.nodeID == target.nodeID,
            identity.clusterID == target.clusterID,
            identity.authorityFingerprint == target.authorityFingerprint
        else {
            throw SparkChatConnectionError.identityMismatch
        }
        let answer = try await api.createWebAnswer(
            route: target.route,
            request: SparkChatWebAnswerBody.request(
                model: target.modelID,
                messages: request.messages
            )
        )
        return SparkChatAnswer(
            events: AsyncThrowingStream { continuation in
                continuation.yield(
                    .chunk(
                        id: nil,
                        model: answer.modelId,
                        delta: answer.text,
                        finishReason: answer.truncated ? "length" : "stop"
                    )
                )
                continuation.yield(.done)
                continuation.finish()
            },
            webSources: answer.sources
        )
    }
}
