import Foundation
@_spi(SparkInternal) @_spi(SparkTestSupport) import SparkTransport

/// Represent non-2xx engine/proxy error envelopes with the typed API failure vocabulary.
public struct ChatError: Error, Sendable, Equatable {
    public let statusCode: Int?
    public let code: String?
    /// Share typed failure reasons with APIError so both use the same presenter.
    public let reason: APIFailure
    /// Keep bounded proxy prose as internal diagnostics rather than user-visible copy.
    public let diagnosticDetail: String

    public init(
        statusCode: Int?,
        code: String?,
        reason: APIFailure,
        diagnosticDetail: String = ""
    ) {
        self.statusCode = statusCode
        self.code = code
        self.reason = reason
        self.diagnosticDetail = diagnosticDetail
    }
}

extension ChatError: LocalizedError {
    public var errorDescription: String? { ChatError.message(for: self) }
}

extension ChatError {
    /// Maps failed chat requests to owner-facing copy.
    public static func message(for error: ChatError) -> String {
        APIError.message(
            for: APIError(error.reason, statusCode: error.statusCode, code: error.code)
        )
    }
}

/// Stream completions through the allowlisted proxy; ADR-018 records the Foundation Models platform deviation.
public actor ChatClient {
    private let baseURL: URL
    private let session: URLSession
    /// Held because streaming has to pass it per task; see `stream`.
    private let trustDelegate: PinnedSessionDelegate
    private let signer: (any RequestSigning)?

    /// Build an internal HTTPS session pinned to tls_fingerprint for streaming, preventing callers from substituting unpinned transports.
    public init(
        baseURL: URL,
        pin: String,
        signer: (any RequestSigning)? = nil
    ) throws {
        try self.init(baseURL: baseURL, pin: pin, signer: signer, interceptingWith: [])
    }

    /// SPI tests may inject protocol classes but cannot replace session caches, cookies or credential stores.
    @_spi(SparkTestSupport)
    public init(
        baseURL: URL,
        pin: String,
        signer: (any RequestSigning)? = nil,
        interceptingWith protocolClasses: [AnyClass]
    ) throws {
        guard baseURL.scheme?.lowercased() == "https" else {
            throw PinnedTransportError.insecureScheme(baseURL.scheme ?? "none")
        }
        guard URLSessionPinnedTransport.isFingerprint(pin) else {
            throw PinnedTransportError.malformedPin(pin)
        }
        self.baseURL = baseURL
        let pinned = PinnedSession.pinnedWithDelegate(
            to: pin,
            interceptingWith: protocolClasses
        )
        self.session = pinned.session
        self.trustDelegate = pinned.delegate
        self.signer = signer
    }

    /// Invalidate the session after active tasks drain to release its retained delegate and trust policy.
    deinit {
        session.finishTasksAndInvalidate()
    }

    /// Non-streaming completion; the proxy counts usage upstream.
    public func complete(_ request: ChatCompletionRequest) async throws -> ChatCompletion {
        var request = request
        request.stream = false
        var urlRequest = try makeRequest(request)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        let requestDelegate = trustDelegate.forRequest()
        do {
            let (data, response) = try await session.data(
                for: urlRequest,
                delegate: requestDelegate
            )
            try Self.validate(response, errorBody: data)
            return try JSONDecoder().decode(ChatCompletion.self, from: data)
        } catch {
            throw requestDelegate.transportError(error, host: baseURL.host ?? "")
        }
    }

    /// Yield SSE chunks, usage and completion as frames arrive, or finish with ChatError for non-2xx responses.
    public func stream(_ request: ChatCompletionRequest) async throws -> AsyncThrowingStream<
        ChatStreamEvent, any Error
    > {
        try await stream(request, onRuntimeAttempt: nil)
    }

    public func stream(
        _ request: ChatCompletionRequest,
        onRuntimeAttempt: (@Sendable (UUID) -> Void)?
    ) async throws
        -> AsyncThrowingStream<ChatStreamEvent, any Error>
    {
        var request = request
        request.stream = true
        let urlRequest = try makeRequest(request)

        let requestDelegate = trustDelegate.forRequest()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // Attach the pin delegate to every streaming task so system trust cannot replace node pinning.
                    let (bytes, response) = try await session.bytes(
                        for: urlRequest,
                        delegate: requestDelegate
                    )
                    guard let http = response as? HTTPURLResponse,
                        (200..<300).contains(http.statusCode)
                    else {
                        var errorBody = Data()
                        for try await chunk in bytes {
                            errorBody.append(chunk)
                            if errorBody.count > 64 * 1024 { break }
                        }
                        continuation.finish(throwing: Self.error(for: response, body: errorBody))
                        return
                    }
                    if let id = http.value(forHTTPHeaderField: "x-spark-inference-attempt-id")
                        .flatMap(UUID.init(uuidString:))
                    {
                        onRuntimeAttempt?(id)
                    }
                    var parser = SSEParser()
                    // Feed raw bytes and flush on CR/LF so SSE blank separators and token latency survive buffering.
                    var buffer = Data()
                    buffer.reserveCapacity(4096)
                    func drain(_ data: Data, parser: inout SSEParser) throws {
                        let events = try parser.append(data)
                        for event in events {
                            if let parsed = try Self.parse(event) {
                                continuation.yield(parsed)
                            }
                        }
                    }
                    for try await byte in bytes {
                        buffer.append(byte)
                        if byte == 0x0A || byte == 0x0D || buffer.count >= 4096 {
                            try drain(buffer, parser: &parser)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty {
                        try drain(buffer, parser: &parser)
                    }
                    if let trailing = try? parser.finish() {
                        for event in trailing {
                            if let parsed = try Self.parse(event) {
                                continuation.yield(parsed)
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(
                        throwing: requestDelegate.transportError(error, host: baseURL.host ?? "")
                    )
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Internals

    private func makeRequest(_ request: ChatCompletionRequest) throws -> URLRequest {
        var urlRequest = URLRequest(
            url: baseURL.appendingPathComponent("v1/chat/completions")
        )
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(
            request.stream ? "text/event-stream" : "application/json",
            forHTTPHeaderField: "Accept"
        )
        let body = try JSONEncoder().encode(request)
        if let signer {
            urlRequest = try signer.authorize(urlRequest, body: body)
        }
        urlRequest.httpBody = body
        // Give chat generation a request timeout suitable for first-token latency rather than the three-second presence probe.
        urlRequest.timeoutInterval = 120
        return urlRequest
    }

    private nonisolated static func validate(_ response: URLResponse, errorBody: Data) throws {
        guard let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode)
        else {
            throw error(for: response, body: errorBody)
        }
    }

    private nonisolated static func error(for response: URLResponse, body: Data) -> ChatError {
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        let envelope = try? JSONDecoder().decode([String: [String: String]].self, from: body)
        let message = envelope?["error"]?["message"]
        return ChatError(
            statusCode: statusCode,
            code: envelope?["error"]?["code"],
            reason: message == nil ? .unexpectedStatus : .reported,
            diagnosticDetail: message ?? ""
        )
    }

    /// Decode a runtime error frame as the thrown failure it is, so a truncated answer is never shown as complete.
    private nonisolated static func streamError(_ event: ServerSentEvent) -> ChatError? {
        let object = event.data.data(using: .utf8).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let envelope = object?["error"] as? [String: Any]
        guard event.event == "error" || envelope != nil else { return nil }
        return ChatError(
            statusCode: nil,
            code: envelope?["code"] as? String ?? "STREAM_INTERRUPTED",
            reason: .reported,
            diagnosticDetail: envelope?["message"] as? String
                ?? "the answer stopped before it was complete"
        )
    }

    private nonisolated static func parse(_ event: ServerSentEvent) throws -> ChatStreamEvent? {
        if event.data == "[DONE]" {
            return .done
        }
        if let failure = streamError(event) {
            throw failure
        }
        struct RawChunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable {
                    let content: String?
                    /// Decode both reasoning and legacy reasoning_content fields when the engine exposes a reasoning parser.
                    let reasoning: String?

                    enum CodingKeys: String, CodingKey {
                        case content
                        case reasoning
                        case reasoningContent = "reasoning_content"
                    }

                    init(from decoder: any Decoder) throws {
                        let values = try decoder.container(keyedBy: CodingKeys.self)
                        content = try values.decodeIfPresent(String.self, forKey: .content)
                        let current = try values.decodeIfPresent(String.self, forKey: .reasoning)
                        let legacy = try values.decodeIfPresent(
                            String.self,
                            forKey: .reasoningContent
                        )
                        reasoning = current ?? legacy
                    }
                }

                let delta: Delta?
                let finishReason: String?
                enum CodingKeys: String, CodingKey {
                    case delta
                    case finishReason = "finish_reason"
                }
            }

            struct Usage: Decodable {
                let promptTokens: Int
                let completionTokens: Int
                let totalTokens: Int
                enum CodingKeys: String, CodingKey {
                    case promptTokens = "prompt_tokens"
                    case completionTokens = "completion_tokens"
                    case totalTokens = "total_tokens"
                }
            }

            let id: String?
            let model: String?
            let choices: [Choice]?
            let usage: Usage?
        }

        guard let data = event.data.data(using: .utf8),
            let chunk = try? JSONDecoder().decode(RawChunk.self, from: data)
        else {
            return nil
        }
        if let usage = chunk.usage {
            return .usage(
                prompt: usage.promptTokens,
                completion: usage.completionTokens,
                total: usage.totalTokens
            )
        }
        let choice = chunk.choices?.first
        return .chunk(
            id: event.id ?? chunk.id,
            model: chunk.model,
            delta: choice?.delta?.content,
            reasoning: choice?.delta?.reasoning,
            finishReason: choice?.finishReason
        )
    }
}
