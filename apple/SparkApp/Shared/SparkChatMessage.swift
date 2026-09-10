import Foundation
import Observation
import SparkAPI
import SparkCore
import SparkLanguageModel
import SparkLibrary
import SparkSecurity
import SparkTransport

public enum SparkChatRole: String, Codable, Equatable, Sendable {
    case user
    case assistant
}

public enum SparkChatResponsePhase: String, Codable, Equatable, Sendable {
    case waiting
    case thinking
    case answering
    case complete
    case cancelled
    case failed
}

public struct SparkChatMessage: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let role: SparkChatRole
    public var content: String
    /// Stores separately emitted model reasoning for optional disclosure apart from the answer.
    public var reasoning: String
    public let targetName: String?
    public let modelName: String?
    public var isPartial: Bool
    public var responsePhase: SparkChatResponsePhase
    public var reasoningStartedAt: Date?
    public var reasoningEndedAt: Date?
    public let attachments: [SparkChatAttachment]
    public let replyTo: SparkChatReplyReference?
    /// What the runtime counted for this turn, absent until it reports usage.
    public var sources: [GeneratedAPI.WebSource]
    public var usage: SparkChatTokenUsage?
    /// The runtime's own word for why generation stopped, kept so truncation is its claim, not ours.
    public var finishReason: String?
    public var generationStartedAt: Date?
    public var generationEndedAt: Date?

    public init(
        id: UUID = UUID(),
        role: SparkChatRole,
        content: String,
        reasoning: String = "",
        targetName: String? = nil,
        modelName: String? = nil,
        isPartial: Bool = false,
        responsePhase: SparkChatResponsePhase = .complete,
        reasoningStartedAt: Date? = nil,
        reasoningEndedAt: Date? = nil,
        attachments: [SparkChatAttachment] = [],
        sources: [GeneratedAPI.WebSource] = [],
        usage: SparkChatTokenUsage? = nil,
        finishReason: String? = nil,
        generationStartedAt: Date? = nil,
        generationEndedAt: Date? = nil,
        replyTo: SparkChatReplyReference? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.reasoning = reasoning
        self.targetName = targetName
        self.modelName = modelName
        self.isPartial = isPartial
        self.attachments = attachments
        self.responsePhase = responsePhase
        self.reasoningStartedAt = reasoningStartedAt
        self.reasoningEndedAt = reasoningEndedAt
        self.sources = sources
        self.usage = usage
        self.finishReason = finishReason
        self.generationStartedAt = generationStartedAt
        self.generationEndedAt = generationEndedAt
        self.replyTo = replyTo
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, content, reasoning, targetName, modelName, isPartial, responsePhase,
            reasoningStartedAt, reasoningEndedAt, attachments, sources, usage, finishReason,
            generationStartedAt, generationEndedAt, replyTo
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try values.decode(UUID.self, forKey: .id),
            role: try values.decode(SparkChatRole.self, forKey: .role),
            content: try values.decode(String.self, forKey: .content),
            reasoning: try values.decode(String.self, forKey: .reasoning),
            targetName: try values.decodeIfPresent(String.self, forKey: .targetName),
            modelName: try values.decodeIfPresent(String.self, forKey: .modelName),
            isPartial: try values.decode(Bool.self, forKey: .isPartial),
            responsePhase: try values.decode(SparkChatResponsePhase.self, forKey: .responsePhase),
            reasoningStartedAt: try values.decodeIfPresent(Date.self, forKey: .reasoningStartedAt),
            reasoningEndedAt: try values.decodeIfPresent(Date.self, forKey: .reasoningEndedAt),
            attachments: try values.decodeIfPresent(
                [SparkChatAttachment].self,
                forKey: .attachments
            )
                ?? [],
            sources: try values.decodeIfPresent([GeneratedAPI.WebSource].self, forKey: .sources)
                ?? [],
            usage: try values.decodeIfPresent(SparkChatTokenUsage.self, forKey: .usage),
            finishReason: try values.decodeIfPresent(String.self, forKey: .finishReason),
            generationStartedAt: try values.decodeIfPresent(
                Date.self,
                forKey: .generationStartedAt
            ),
            generationEndedAt: try values.decodeIfPresent(Date.self, forKey: .generationEndedAt),
            replyTo: try values.decodeIfPresent(SparkChatReplyReference.self, forKey: .replyTo)
        )
    }

    public var hasAnswer: Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var hasReasoning: Bool {
        !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Measures thinking from first reasoning text to first answer or terminal event, excluding server wait time.
    public func reasoningElapsed(at date: Date) -> TimeInterval? {
        guard hasReasoning, let reasoningStartedAt else { return nil }
        return max(0, (reasoningEndedAt ?? date).timeIntervalSince(reasoningStartedAt))
    }

    mutating func finishReasoning(at date: Date) {
        guard let reasoningStartedAt, reasoningEndedAt == nil else { return }
        reasoningEndedAt = max(date, reasoningStartedAt)
    }

    public var accessibilityLabel: String {
        switch role {
        case .user: String(localized: .youSaid(content))
        case .assistant:
            Self.assistantAccessibilityLabel(
                target: targetName,
                model: modelName,
                content: content,
                isPartial: isPartial
            )
        }
    }

    /// Use complete catalogue sentences for each attribution and partial-response case so translators can control grammar.
    private static func assistantAccessibilityLabel(
        target: String?,
        model: String?,
        content: String,
        isPartial: Bool
    ) -> String {
        switch (target, model, isPartial) {
        case (.some(let target), .some(let model), false):
            String(localized: .sparkSaidUsing(target: target, model: model, content: content))
        case (.some(let target), .some(let model), true):
            String(
                localized: .sparkPartiallySaidUsing(
                    target: target,
                    model: model,
                    content: content
                )
            )
        case (_, _, false): String(localized: .sparkSaid(content))
        case (_, _, true): String(localized: .sparkPartiallySaid(content))
        }
    }
    func restoredAfterInterruption(at date: Date) -> Self {
        var restored = self
        if [.waiting, .thinking, .answering].contains(restored.responsePhase) {
            restored.responsePhase = .cancelled
            restored.isPartial = true
            restored.finishReasoning(at: date)
        }
        return restored
    }

}
