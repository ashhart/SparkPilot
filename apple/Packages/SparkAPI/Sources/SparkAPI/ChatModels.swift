import Foundation

/// One chat turn with a system, developer, user, assistant or tool role.
public struct ChatMessage: Codable, Equatable, Sendable {
    public var role: String
    public var content: String
    /// Inline image data, never a remote URL that would cause the engine to fetch a resource.
    public var imageDataURLs: [String]

    public init(role: String = "user", content: String, imageDataURLs: [String] = []) {
        self.role = role
        self.content = content
        self.imageDataURLs = imageDataURLs
    }

    private enum CodingKeys: String, CodingKey { case role, content }
    private struct Part: Codable {
        let type: String
        var text: String?
        var imageURL: ImageURL?
        struct ImageURL: Codable { let url: String }
        private enum CodingKeys: String, CodingKey {
            case type, text
            case imageURL = "image_url"
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        if imageDataURLs.isEmpty {
            try container.encode(content, forKey: .content)
        } else {
            guard imageDataURLs.allSatisfy({ $0.hasPrefix("data:image/jpeg;base64,") }) else {
                throw EncodingError.invalidValue(
                    imageDataURLs,
                    .init(
                        codingPath: encoder.codingPath,
                        debugDescription: "Inline JPEG images required"
                    )
                )
            }
            let parts =
                [Part(type: "text", text: content)]
                + imageDataURLs.map {
                    Part(type: "image_url", imageURL: Part.ImageURL(url: $0))
                }
            try container.encode(parts, forKey: .content)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(String.self, forKey: .role)
        if let text = try? container.decode(String.self, forKey: .content) {
            content = text
            imageDataURLs = []
        } else {
            let parts = try container.decode([Part].self, forKey: .content)
            guard parts.allSatisfy({ $0.type == "text" || $0.type == "image_url" }) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .content,
                    in: container,
                    debugDescription: "Unsupported content part"
                )
            }
            content = parts.compactMap(\.text).joined(separator: "\n")
            imageDataURLs = parts.compactMap { $0.imageURL?.url }
        }
    }
}

/// Mirror only the OpenAI-compatible parameters accepted by the allowlisted proxy (§31.6).
public struct ChatCompletionRequest: Encodable, Equatable, Sendable {
    public var model: String
    public var messages: [ChatMessage]
    public var stream: Bool
    public var temperature: Double?
    public var maxTokens: Int?
    public var thinkingTokenBudget: Int?
    /// Request include_usage so the final upstream chunk carries accounting totals.
    public var streamOptionsIncludeUsage: Bool?

    public init(
        model: String,
        messages: [ChatMessage],
        stream: Bool = false,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        thinkingTokenBudget: Int? = nil,
        streamOptionsIncludeUsage: Bool? = nil
    ) {
        self.model = model
        self.messages = messages
        self.stream = stream
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.thinkingTokenBudget = thinkingTokenBudget
        self.streamOptionsIncludeUsage = streamOptionsIncludeUsage
    }

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case stream
        case temperature
        case maxTokens = "max_tokens"
        case thinkingTokenBudget = "thinking_token_budget"
        case streamOptionsIncludeUsage = "stream_options"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(messages, forKey: .messages)
        try container.encode(stream, forKey: .stream)
        if let temperature { try container.encode(temperature, forKey: .temperature) }
        if let thinkingTokenBudget {
            try container.encode(thinkingTokenBudget, forKey: .thinkingTokenBudget)
        }
        if let maxTokens { try container.encode(maxTokens, forKey: .maxTokens) }
        if let include = streamOptionsIncludeUsage {
            try container.encode(["include_usage": include], forKey: .streamOptionsIncludeUsage)
        }
    }
}

/// Non-streaming completion response (§ contract `ChatCompletion`).
public struct ChatCompletion: Decodable, Sendable, Equatable {
    public struct Choice: Decodable, Sendable, Equatable {
        public struct Message: Decodable, Sendable, Equatable {
            public var role: String
            public var content: String?
            public init(role: String, content: String?) {
                self.role = role
                self.content = content
            }
        }

        public var index: Int
        public var message: Message
        public var finishReason: String?
        public init(index: Int, message: Message, finishReason: String?) {
            self.index = index
            self.message = message
            self.finishReason = finishReason
        }

        private enum CodingKeys: String, CodingKey {
            case index
            case message
            case finishReason = "finish_reason"
        }
    }

    public struct Usage: Decodable, Sendable, Equatable {
        public var promptTokens: Int
        public var completionTokens: Int
        public var totalTokens: Int
        public init(promptTokens: Int, completionTokens: Int, totalTokens: Int) {
            self.promptTokens = promptTokens
            self.completionTokens = completionTokens
            self.totalTokens = totalTokens
        }

        private enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }

    public var id: String
    public var object: String
    public var model: String
    public var choices: [Choice]
    public var usage: Usage?
}

/// One parsed element of a streaming chat ([§31.6] usage + chunks + DONE).
public enum ChatStreamEvent: Sendable, Equatable {
    /// Keep parser-separated model reasoning distinct from the answer in presentation.
    case chunk(
        id: String?,
        model: String?,
        delta: String?,
        reasoning: String? = nil,
        finishReason: String?
    )
    /// Sources belong to this stream and its assistant message.
    case sources([GeneratedAPI.WebSource])
    case usage(prompt: Int, completion: Int, total: Int)
    case done
}

/// Inject request signing through a protocol so the client stays independent of the security package.
public protocol RequestSigning: Sendable {
    func authorize(_ request: URLRequest, body: Data) throws -> URLRequest
}
