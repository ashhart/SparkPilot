import Foundation
@_spi(SparkInternal) @_spi(SparkTestSupport) import SparkTransport
import Testing

@_spi(SparkTestSupport) @testable import SparkAPI

/// The events stream is opened signed and pinned like chat, and resumes by cursor (§38.3, §44.1).
@Suite(.serialized)
struct EventsClientTests {

    private struct StubResponse {
        var statusCode: Int = 200
        var headers: [String: String] = ["Content-Type": "text/event-stream"]
        var body: Data = Data()
    }

    /// Serves one canned response per request so a reconnection can be answered differently.
    private final class EventsMockURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var queued: [StubResponse] = []
        nonisolated(unsafe) static var tail = StubResponse(statusCode: 404, headers: [:])
        nonisolated(unsafe) static var requests: [URLRequest] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.requests.append(request)
            let stub = Self.queued.isEmpty ? Self.tail : Self.queued.removeFirst()
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

    /// Records that the request was signed before it left, without imitating SPARK2 itself.
    private struct RecordingSigner: RequestSigning {
        nonisolated(unsafe) static var signedURLs: [URL] = []

        func authorize(_ request: URLRequest, body: Data) throws -> URLRequest {
            RecordingSigner.signedURLs.append(request.url!)
            var request = request
            request.setValue("SPARK2 test", forHTTPHeaderField: "Authorization")
            return request
        }
    }

    private static let testPin = String(repeating: "b", count: 64)

    private func makeClient(
        signer: (any RequestSigning)? = RecordingSigner(),
        retry: SSERetryPolicy = SSERetryPolicy(maximumAttempts: 0)
    ) throws -> EventsClient {
        EventsMockURLProtocol.queued = []
        EventsMockURLProtocol.tail = StubResponse(statusCode: 404, headers: [:])
        EventsMockURLProtocol.requests = []
        RecordingSigner.signedURLs = []
        return try EventsClient(
            baseURL: URL(string: "https://spark.local:7443")!,
            pin: Self.testPin,
            signer: signer,
            retry: retry,
            interceptingWith: [EventsMockURLProtocol.self]
        )
    }

    /// One recorded stream: a heartbeat, a model event and an operation event.
    private var eventsFixture: Data {
        Data(
            """
            : heartbeat

            id: 41
            event: model.ready
            data: {"sequence":41,"event_id":"6e3f6c4e-0f1a-4a49-9d2b-9f2b1c8a55aa",\
            "occurred_at":"2026-09-05T09:00:00Z","node_id":"1f0c9d40-6b5b-4a3e-8f7a-2c5a3b1d9e77",\
            "type":"model.ready","severity":"info","payload":{"model_id":"example-32b"}}

            id: 42
            event: operation.progress
            data: {"sequence":42,"event_id":"a1b2c3d4-0000-4000-8000-000000000001",\
            "occurred_at":"2026-09-05T09:00:01Z","node_id":"1f0c9d40-6b5b-4a3e-8f7a-2c5a3b1d9e77",\
            "operation_id":"9c0f1b2a-0000-4000-8000-000000000002",\
            "type":"operation.progress","severity":"info","payload":{"progress":0.5}}


            """.utf8
        )
    }

    /// Read to the end; the test policy stops after one attempt so nothing waits on a backoff.
    private func drain(
        _ client: EventsClient,
        resumingFrom cursor: String? = nil
    ) async -> (elements: [SparkEventStreamElement], failure: (any Error)?) {
        var collected: [SparkEventStreamElement] = []
        do {
            for try await element in await client.events(resumingFrom: cursor) {
                collected.append(element)
            }
            return (collected, nil)
        } catch {
            return (collected, error)
        }
    }

    @Test func theStreamIsOpenedSignedOnTheEventsPath() async throws {
        let client = try makeClient()
        EventsMockURLProtocol.queued = [
            StubResponse(
                headers: ["Content-Type": "text/event-stream"],
                body: eventsFixture
            )
        ]

        let result = await drain(client)

        #expect(result.failure as? SSEStreamFailure == .reconnectionsExhausted(attempts: 0))
        let opened = try #require(EventsMockURLProtocol.requests.first)
        #expect(opened.url?.path == "/api/v1/events")
        #expect(opened.value(forHTTPHeaderField: "Accept") == "text/event-stream")
        #expect(opened.value(forHTTPHeaderField: "Authorization") == "SPARK2 test")
        #expect(RecordingSigner.signedURLs.first?.path == "/api/v1/events")
        #expect(opened.value(forHTTPHeaderField: "Last-Event-ID") == nil)
    }

    @Test func recordedFramesDecodeAsRuntimeEvents() async throws {
        let client = try makeClient()
        EventsMockURLProtocol.queued = [
            StubResponse(
                headers: ["Content-Type": "text/event-stream"],
                body: eventsFixture
            )
        ]

        let result = await drain(client)

        try #require(result.elements.count == 3)
        #expect(result.elements.first == .heartbeat)
        guard case .event(let first) = result.elements[1] else {
            Issue.record("expected a decoded event")
            return
        }
        #expect(first.sequence == 41)
        #expect(first.type == "model.ready")
        #expect(first.operationID == nil)
        guard case .event(let second) = result.elements[2] else {
            Issue.record("expected a decoded event")
            return
        }
        #expect(second.sequence == 42)
        #expect(second.type == "operation.progress")
        #expect(second.operationID == "9c0f1b2a-0000-4000-8000-000000000002")
    }

    @Test func aResumedStreamAsksForReplayFromTheCursor() async throws {
        let client = try makeClient()
        EventsMockURLProtocol.queued = [
            StubResponse(
                headers: ["Content-Type": "text/event-stream"],
                body: eventsFixture
            )
        ]

        _ = await drain(client, resumingFrom: "40")

        let opened = try #require(EventsMockURLProtocol.requests.first)
        #expect(opened.value(forHTTPHeaderField: "Last-Event-ID") == "40")
    }

    @Test func anExpiredCursorIsReportedThenTheStreamReopensWithoutOne() async throws {
        let client = try makeClient()
        let expired = Data(
            """
            {"error":{"code":"EVENT_CURSOR_EXPIRED",\
            "message":"the requested event cursor is older than retained history"}}
            """.utf8
        )
        EventsMockURLProtocol.queued = [
            StubResponse(
                statusCode: 409,
                headers: ["Content-Type": "application/json"],
                body: expired
            ),
            StubResponse(
                headers: ["Content-Type": "text/event-stream"],
                body: eventsFixture
            ),
        ]

        let result = await drain(client, resumingFrom: "7")

        #expect(result.elements.first == .cursorExpired)
        #expect(EventsMockURLProtocol.requests.count == 2)
        #expect(EventsMockURLProtocol.requests[0].value(forHTTPHeaderField: "Last-Event-ID") == "7")
        #expect(EventsMockURLProtocol.requests[1].value(forHTTPHeaderField: "Last-Event-ID") == nil)
    }

    @Test func aSparkThatDoesNotServeTheStreamStopsWithoutRetrying() async throws {
        let client = try makeClient()
        EventsMockURLProtocol.tail = StubResponse(statusCode: 404, headers: [:])

        let result = await drain(client)

        #expect(result.elements.isEmpty)
        #expect(result.failure as? SSEOpenFailure == .unsupported(statusCode: 404))
        #expect(EventsMockURLProtocol.requests.count == 1)
    }

    @Test func aForbiddenStreamStopsWithoutRetryingEither() async throws {
        let client = try makeClient()
        EventsMockURLProtocol.tail = StubResponse(statusCode: 403, headers: [:])

        let result = await drain(client)

        #expect(result.failure as? SSEOpenFailure == .unsupported(statusCode: 403))
        #expect(EventsMockURLProtocol.requests.count == 1)
    }

    @Test func anUnsignedClientNeverOpensTheStream() async throws {
        let client = try makeClient(signer: nil)

        let result = await drain(client)

        #expect(result.failure is APIError)
        #expect(EventsMockURLProtocol.requests.isEmpty)
    }
}
