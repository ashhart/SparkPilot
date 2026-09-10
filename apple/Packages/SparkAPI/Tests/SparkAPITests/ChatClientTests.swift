import Foundation
@_spi(SparkTestSupport) @_spi(SparkInternal) import SparkTransport
import Testing
@_spi(SparkTestSupport) @testable import SparkAPI

/// Match runtime SSE ordering for content, finish, usage and DONE frames.
@Suite(.serialized)
struct ChatClientTests {

    struct StubResponse {
        var statusCode: Int = 200
        var headers: [String: String] = ["Content-Type": "application/json"]
        var body: Data = Data()
    }

    /// URLProtocol stub serving canned responses and recording requests.
    private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var response: StubResponse = StubResponse()
        nonisolated(unsafe) static var lastRequest: URLRequest?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lastRequest = request
            let stub = Self.response
            let http = HTTPURLResponse(
                url: request.url!,
                statusCode: stub.statusCode,
                httpVersion: nil,
                headerFields: stub.headers
            )!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    /// The stub proves a pin is required at construction; SparkTransport verifies TLS pinning itself.
    private static let testPin = String(repeating: "a", count: 64)

    private func makeClient(
        signer: (any RequestSigning)? = nil
    ) throws -> ChatClient {
        Self.resetStub()
        return try ChatClient(
            baseURL: URL(string: "https://spark.local:7443")!,
            pin: Self.testPin,
            signer: signer,
            interceptingWith: [MockURLProtocol.self]
        )
    }

    private static func resetStub() {
        MockURLProtocol.response = StubResponse()
        MockURLProtocol.lastRequest = nil
    }

    /// The recorded SSE body as served by the Rust mock stub (§31.6).
    private var sseFixture: Data {
        Data(
            """
            id: 1
            event: message
            data: {"id":"chatcmpl-mock","object":"chat.completion.chunk","created":0,"model":"example-32b","choices":[{"index":0,"delta":{"role":"assistant","content":"Hello"},"finish_reason":null}]}

            id: 2
            event: message
            data: {"id":"chatcmpl-mock","object":"chat.completion.chunk","created":0,"model":"example-32b","choices":[{"index":0,"delta":{"content":" from"},"finish_reason":null}]}

            id: 3
            event: message
            data: {"id":"chatcmpl-mock","object":"chat.completion.chunk","created":0,"model":"example-32b","choices":[{"index":0,"delta":{"content":" Spark."},"finish_reason":null}]}

            id: 4
            event: message
            data: {"id":"chatcmpl-mock","object":"chat.completion.chunk","created":0,"model":"example-32b","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

            id: 5
            event: message
            data: {"id":"chatcmpl-mock","object":"chat.completion.chunk","created":0,"model":"example-32b","usage":{"prompt_tokens":12,"completion_tokens":14,"total_tokens":26}}

            id: 6
            event: message
            data: [DONE]

            """.utf8
        )
    }

    @Test func streamDecodesRecordedSSEChunks() async throws {
        let client = try makeClient()
        MockURLProtocol.response.headers = ["Content-Type": "text/event-stream"]
        MockURLProtocol.response.body = sseFixture

        let stream = try await client.stream(
            ChatCompletionRequest(
                model: "example-32b",
                messages: [ChatMessage(role: "user", content: "stream me")],
                stream: true,
                streamOptionsIncludeUsage: true
            )
        )

        var events: [ChatStreamEvent] = []
        var iterator = stream.makeAsyncIterator()
        while let event = try await iterator.next() {
            events.append(event)
        }

        #expect(
            events == [
                .chunk(id: "1", model: "example-32b", delta: "Hello", finishReason: nil),
                .chunk(id: "2", model: "example-32b", delta: " from", finishReason: nil),
                .chunk(id: "3", model: "example-32b", delta: " Spark.", finishReason: nil),
                .chunk(id: "4", model: "example-32b", delta: nil, finishReason: "stop"),
                .usage(prompt: 12, completion: 14, total: 26),
                .done,
            ]
        )
        #expect(
            events.filter { if case .chunk = $0 { return true } else { return false } }.count == 4
        )
    }

    private final class AttemptBox: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [UUID] = []
        func add(_ id: UUID) { lock.withLock { ids.append(id) } }
        func values() -> [UUID] { lock.withLock { ids } }
    }

    @Test(arguments: ["6fc30b1a-159a-4772-9581-766a4de4b105", "private response metadata", ""])
    func runtimeAttemptCallbackAcceptsOnlyTheDedicatedUUIDHeader(_ header: String) async throws {
        let client = try makeClient()
        MockURLProtocol.response.headers = [
            "Content-Type": "text/event-stream", "x-spark-inference-attempt-id": header,
        ]
        MockURLProtocol.response.body = sseFixture
        let attempts = AttemptBox()
        let stream = try await client.stream(
            ChatCompletionRequest(
                model: "example-32b",
                messages: [ChatMessage(content: "synthetic")]
            ),
            onRuntimeAttempt: { attempts.add($0) }
        )
        for try await _ in stream {}
        #expect(attempts.values() == UUID(uuidString: header).map { [$0] } ?? [])
    }

    @Test func nonStreamDecodesCompletion() async throws {
        let client = try makeClient()
        MockURLProtocol.response.body = Data(
            """
            {"id":"chatcmpl-mock","object":"chat.completion","created":0,"model":"example-32b",
             "choices":[{"index":0,"message":{"role":"assistant","content":"Hello from the mock engine."},"finish_reason":"stop"}],
             "usage":{"prompt_tokens":12,"completion_tokens":14,"total_tokens":26}}
            """.utf8
        )

        let completion = try await client.complete(
            ChatCompletionRequest(
                model: "example-32b",
                messages: [ChatMessage(role: "user", content: "hi")]
            )
        )
        #expect(completion.id == "chatcmpl-mock")
        #expect(completion.choices.first?.message.content == "Hello from the mock engine.")
        #expect(completion.usage?.totalTokens == 26)
    }

    @Test func serverErrorSurfacesEnvelopeCode() async throws {
        let client = try makeClient()
        MockURLProtocol.response.statusCode = 503
        MockURLProtocol.response.body = Data(
            #"{"error":{"code":"ENGINE_DRAINING","message":"engine is draining"}}"#.utf8
        )

        let request = ChatCompletionRequest(
            model: "example-32b",
            messages: [ChatMessage(role: "user", content: "hi")]
        )
        do {
            _ = try await client.complete(request)
            Issue.record("expected a ChatError")
        } catch let error as ChatError {
            #expect(error.statusCode == 503)
            #expect(error.code == "ENGINE_DRAINING")
            #expect(error.reason == .reported)
            // The proxy's own words stay in the diagnostic and out of copy.
            #expect(error.diagnosticDetail == "engine is draining")
            #expect(!ChatError.message(for: error).contains("draining"))
        }
    }

    @Test func outgoingRequestIsSignedAndAsksForStreaming() async throws {
        struct TestSigner: RequestSigning {
            nonisolated(unsafe) static var lastBody: Data?
            func authorize(_ request: URLRequest, body: Data) throws -> URLRequest {
                TestSigner.lastBody = body
                var request = request
                request.setValue("signed=true", forHTTPHeaderField: "X-Spark-Test-Proof")
                return request
            }
        }

        let client = try makeClient(signer: TestSigner())
        MockURLProtocol.response.headers = ["Content-Type": "text/event-stream"]
        MockURLProtocol.response.body = sseFixture

        // Consume the lazy stream so the request actually fires.
        let stream = try await client.stream(
            ChatCompletionRequest(
                model: "example-32b",
                messages: [ChatMessage(role: "user", content: "stream me")],
                stream: true,
                streamOptionsIncludeUsage: true
            )
        )
        var iterator = stream.makeAsyncIterator()
        while let _ = try await iterator.next() {}

        let sent = try #require(MockURLProtocol.lastRequest)
        #expect(sent.url?.path().hasSuffix("v1/chat/completions") == true)
        #expect(sent.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(sent.value(forHTTPHeaderField: "X-Spark-Test-Proof") == "signed=true")
        #expect(sent.httpMethod == "POST")
        let encoded = try #require(TestSigner.lastBody)
        let bodyJSON = try #require(
            try? JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(bodyJSON["stream"] as? Bool == true)
        #expect((bodyJSON["stream_options"] as? [String: Any])?["include_usage"] as? Bool == true)
    }

    // MARK: - What cannot be built

    @Test func aPlaintextBaseURLIsRefused() {
        // Require HTTPS for the owner's conversation and its request signature.
        #expect(throws: PinnedTransportError.insecureScheme("http")) {
            _ = try ChatClient(
                baseURL: URL(string: "http://spark.local:7443")!,
                pin: Self.testPin
            )
        }
    }

    @Test func aPinThatIsNotAFingerprintIsRefused() {
        #expect(throws: PinnedTransportError.malformedPin("nope")) {
            _ = try ChatClient(baseURL: URL(string: "https://spark.local:7443")!, pin: "nope")
        }
    }
    /// A runtime error frame ends the answer as a thrown failure, never as a completed message (A2).
    @Test func errorFramesEndTheStreamAsAFailure() async throws {
        let frames = [
            (
                "WORKER_LOST",
                "event: error\ndata: {\"error\":{\"code\":\"WORKER_LOST\",\"message\":\"a cluster worker stopped responding\"}}\n\n"
            ),
            (
                "ENGINE_FAILED",
                "id: 1\nevent: message\ndata: {\"id\":\"chatcmpl-mock\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hel\"},\"finish_reason\":null}]}\n\nid: 2\nevent: message\ndata: {\"error\":{\"code\":\"ENGINE_FAILED\",\"message\":\"the engine exited\"}}\n\n"
            ),
        ]
        for (code, body) in frames {
            let client = try makeClient()
            MockURLProtocol.response.headers = ["Content-Type": "text/event-stream"]
            MockURLProtocol.response.body = Data(body.utf8)
            let stream = try await client.stream(
                ChatCompletionRequest(
                    model: "example-32b",
                    messages: [ChatMessage(role: "user", content: "hi")],
                    stream: true,
                    streamOptionsIncludeUsage: true
                )
            )
            var iterator = stream.makeAsyncIterator()
            var failure: ChatError?
            var completed = false
            do {
                while let event = try await iterator.next() {
                    if case .done = event { completed = true }
                }
            } catch let error as ChatError {
                failure = error
            }
            #expect(!completed, "\(code): the stream must not complete")
            #expect(failure?.code == code, "\(code): \(String(describing: failure))")
            #expect(failure?.reason == .reported)
        }
    }
}

@Test func thinkingBudgetEncodesZeroAndOmitsAnUnspecifiedBudget() throws {
    var request = ChatCompletionRequest(model: "nemotron", messages: [], thinkingTokenBudget: 0)
    var json = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
    )
    #expect(json["thinking_token_budget"] as? Int == 0)
    request.thinkingTokenBudget = nil
    json = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
    )
    #expect(json["thinking_token_budget"] == nil)
}
