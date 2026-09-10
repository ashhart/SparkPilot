import Foundation
import SparkCore
import SparkSecurity
@_spi(SparkTestSupport) @_spi(SparkInternal) import SparkTransport
import Testing

@_spi(SparkTestSupport) @testable import SparkAPI

/// Answer a scripted sequence so a test can prove how many attempts a call actually made.
private final class ScriptedTransport: PinnedHTTPTransport, @unchecked Sendable {
    enum Step {
        case status(Int, headers: [String: String] = [:], body: String = "{}")
        case failure(any Error)
    }

    let pin = String(repeating: "a", count: 64)
    private let lock = NSLock()
    private var steps: [Step]
    private var seen: [URLRequest] = []

    init(_ steps: [Step]) { self.steps = steps }

    var attempts: [URLRequest] { lock.withLock { seen } }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let step: Step = lock.withLock {
            seen.append(request)
            return steps.isEmpty ? .status(200) : steps.removeFirst()
        }
        switch step {
        case .failure(let error): throw error
        case .status(let code, let headers, let body):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: code,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            return (Data(body.utf8), response)
        }
    }
}

/// Stamp a different nonce on every attempt so the test can prove each retry is signed afresh.
private final class CountingSigner: RequestSigning, @unchecked Sendable {
    private let lock = NSLock()
    private var issued = 0

    func authorize(_ request: URLRequest, body: Data) throws -> URLRequest {
        let nonce = lock.withLock {
            issued += 1
            return issued
        }
        var signed = request
        signed.setValue("nonce-\(nonce)", forHTTPHeaderField: "X-Spark-Nonce")
        return signed
    }
}

private struct Empty: Codable {}

private func client(
    _ steps: [ScriptedTransport.Step],
    policy: SparkRetryPolicy = .standard,
    recorder: Slept? = nil
) -> (SparkAPIClient, ScriptedTransport) {
    let transport = ScriptedTransport(steps)
    let slept = recorder ?? Slept()
    let api = SparkAPIClient(
        transport: transport,
        signer: CountingSigner(),
        retryPolicy: policy,
        jitter: { $0 },
        pause: { slept.record($0) },
        now: { Date(timeIntervalSince1970: 0) }
    )
    return (api, transport)
}

/// Collect the requested waits instead of spending them.
final class Slept: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval] = []
    func record(_ value: TimeInterval) { lock.withLock { values.append(value) } }
    var recorded: [TimeInterval] { lock.withLock { values } }
}

@Test func aRetryableStatusIsRetriedWithAFreshSignature() async throws {
    let (api, transport) = client([.status(503), .status(503), .status(200)])
    let _: Empty = try await api.get(URL(string: "https://spark.local/api/v1/status")!)
    #expect(transport.attempts.count == 3)
    let nonces = transport.attempts.map { $0.value(forHTTPHeaderField: "X-Spark-Nonce") }
    #expect(nonces == ["nonce-1", "nonce-2", "nonce-3"])
}

@Test func aDefiniteRefusalIsNotRetried() async throws {
    let (api, transport) = client([.status(403, body: #"{"error":{"code":"ROLE_FORBIDDEN"}}"#)])
    await #expect(throws: APIError.self) {
        let _: Empty = try await api.get(URL(string: "https://spark.local/api/v1/status")!)
    }
    #expect(transport.attempts.count == 1)
}

@Test func attemptsStopAtTheFifth() async throws {
    let (api, transport) = client(Array(repeating: .status(503), count: 8))
    await #expect(throws: APIError.self) {
        let _: Empty = try await api.get(URL(string: "https://spark.local/api/v1/status")!)
    }
    #expect(transport.attempts.count == 5)
}

@Test func anUnreachableRouteIsRetriedButARejectedCertificateIsNot() async throws {
    let (retried, retriedTransport) = client([
        .failure(PinnedTransportError.unreachable("no route")), .status(200),
    ])
    let _: Empty = try await retried.get(URL(string: "https://spark.local/api/v1/status")!)
    #expect(retriedTransport.attempts.count == 2)

    let (refused, refusedTransport) = client([
        .failure(PinnedTransportError.certificateRejected(host: "spark.local"))
    ])
    await #expect(throws: PinnedTransportError.self) {
        let _: Empty = try await refused.get(URL(string: "https://spark.local/api/v1/status")!)
    }
    #expect(refusedTransport.attempts.count == 1)
}

@Test func retryAfterSetsThePaceInsteadOfTheBackoff() async throws {
    let slept = Slept()
    let (api, _) = client(
        [.status(429, headers: ["Retry-After": "2"]), .status(200)],
        recorder: slept
    )
    let _: Empty = try await api.get(URL(string: "https://spark.local/api/v1/status")!)
    #expect(slept.recorded == [2])
}

@Test func aPresenceProvedMutationIsNeverRetried() async throws {
    let transport = ScriptedTransport([.status(503), .status(200)])
    let api = SparkAPIClient(
        transport: transport,
        signer: CountingSigner(),
        jitter: { $0 },
        pause: { _ in }
    )
    await #expect(throws: APIError.self) {
        let _: Empty = try await api.mutation(
            method: "POST",
            url: URL(string: "https://spark.local/api/v1/models/x/load")!,
            body: Optional<Empty>.none,
            idempotencyKey: UUID(),
            userPresence: "presence-proof"
        )
    }
    #expect(transport.attempts.count == 1)
}

@Test func theBackoffIsFullJitterCappedAtEightSeconds() {
    let policy = SparkRetryPolicy.standard
    #expect(policy.ceiling(afterAttempt: 1) == 0.25)
    #expect(policy.ceiling(afterAttempt: 2) == 0.5)
    #expect(policy.ceiling(afterAttempt: 3) == 1)
    #expect(policy.ceiling(afterAttempt: 30) == 8)
    var draws: [TimeInterval] = []
    for _ in 0..<200 {
        draws.append(
            policy.delay(afterAttempt: 3, retryAfter: nil, jitter: { .random(in: 0...$0) })
        )
    }
    #expect(draws.allSatisfy { (0...1).contains($0) })
    #expect(draws.contains { $0 < 0.5 })
}

@Test func retryAfterAcceptsBothDocumentedForms() {
    let now = Date(timeIntervalSince1970: 1_756_000_000)
    #expect(SparkRetryAfter.seconds(from: "3", now: now) == 3)
    #expect(SparkRetryAfter.seconds(from: nil, now: now) == nil)
    #expect(SparkRetryAfter.seconds(from: "not-a-delay", now: now) == nil)
    let httpDate = "Sun, 24 Aug 2025 03:07:00 GMT"
    let parsed = SparkRetryAfter.seconds(from: httpDate, now: now)
    #expect(parsed != nil)
    #expect((parsed ?? -1) >= 0)
}
