import Foundation
import Testing

@testable import SparkTransport

/// One scripted attempt at the events stream, so reconnection is exercised without a network.
private enum ScriptedAttempt: Sendable {
    case chunks([String])
    case chunksThenDrop([String])
    case refusal(SSEOpenFailure)
    case openForever([String])
}

/// The stream failure a scripted attempt uses to imitate a dropped connection.
private struct ScriptedDrop: Error, Equatable {}

/// Serves scripted attempts in order and records the cursor each attempt was opened with.
private actor ScriptedSource {
    private var scripted: [ScriptedAttempt]
    private let tail: ScriptedAttempt
    private let onTerminate: @Sendable () -> Void
    private(set) var cursors: [String?] = []

    init(
        _ scripted: [ScriptedAttempt],
        tail: ScriptedAttempt = .refusal(.unsupported(statusCode: 404)),
        onTerminate: @escaping @Sendable () -> Void = {}
    ) {
        self.scripted = scripted
        self.tail = tail
        self.onTerminate = onTerminate
    }

    var openCount: Int { cursors.count }

    func open(_ cursor: String?) throws -> SSEByteStream {
        cursors.append(cursor)
        let attempt = scripted.isEmpty ? tail : scripted.removeFirst()
        switch attempt {
        case .refusal(let failure):
            throw failure
        case .chunks(let chunks):
            return Self.stream(chunks, endsWith: nil, onTerminate: onTerminate)
        case .chunksThenDrop(let chunks):
            return Self.stream(chunks, endsWith: ScriptedDrop(), onTerminate: onTerminate)
        case .openForever(let chunks):
            return Self.stream(chunks, endsWith: nil, closes: false, onTerminate: onTerminate)
        }
    }

    private static func stream(
        _ chunks: [String],
        endsWith failure: (any Error)?,
        closes: Bool = true,
        onTerminate: @escaping @Sendable () -> Void
    ) -> SSEByteStream {
        AsyncThrowingStream { continuation in
            continuation.onTermination = { _ in onTerminate() }
            for chunk in chunks {
                continuation.yield(Data(chunk.utf8))
            }
            if closes {
                continuation.finish(throwing: failure)
            }
        }
    }
}

/// A clock the test moves by hand so liveness never depends on wall time.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = Date(timeIntervalSince1970: 1_000)

    var value: Date { lock.withLock { instant } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { instant += seconds }
    }
}

/// Read at most `count` elements and then drop the stream, so the reader stops with the test.
private func take(
    _ count: Int,
    from stream: AsyncThrowingStream<SSEStreamElement, any Error>
) async throws -> [SSEStreamElement] {
    var collected: [SSEStreamElement] = []
    var iterator = stream.makeAsyncIterator()
    while collected.count < count, let element = try await iterator.next() {
        collected.append(element)
    }
    return collected
}

/// Wait a bounded time for one signal, so a reader that never releases fails instead of hanging.
private func arrives(_ signals: AsyncStream<Void>, within limit: Duration) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            var iterator = signals.makeAsyncIterator()
            return await iterator.next() != nil
        }
        group.addTask {
            try? await Task.sleep(for: limit)
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
}

/// Read to the end, returning what arrived and the failure that ended it.
private func drain(
    _ stream: AsyncThrowingStream<SSEStreamElement, any Error>
) async -> (elements: [SSEStreamElement], failure: (any Error)?) {
    var collected: [SSEStreamElement] = []
    do {
        for try await element in stream {
            collected.append(element)
        }
        return (collected, nil)
    } catch {
        return (collected, error)
    }
}

private func testClient(
    maxEventBytes: Int = 1_048_576,
    retry: SSERetryPolicy = SSERetryPolicy(),
    now: @escaping @Sendable () -> Date = Date.init
) -> SSEClient {
    SSEClient(
        maxEventBytes: maxEventBytes,
        retry: retry,
        now: now,
        sleep: { _ in },
        jitter: { 0.5 }
    )
}

@Test func theParserCountsHeartbeatCommentsSeparatelyFromEvents() throws {
    var parser = SSEParser()

    let events = try parser.append(": heartbeat\n\n: heartbeat\n\nid: 4\ndata: {}\n\n")

    #expect(events == [ServerSentEvent(id: "4", data: "{}")])
    #expect(parser.commentsSeen == 2)
}

@Test func aReconnectionAsksForReplayFromTheLastEventID() async throws {
    let source = ScriptedSource([.chunks(["id: 7\nevent: model.ready\ndata: {\"a\":1}\n\n"])])
    let client = testClient()

    let stream = await client.stream { cursor in try await source.open(cursor) }
    let (elements, failure) = await drain(stream)

    #expect(
        elements == [
            .event(ServerSentEvent(id: "7", event: "model.ready", data: "{\"a\":1}"))
        ]
    )
    #expect(failure as? SSEOpenFailure == .unsupported(statusCode: 404))
    #expect(await source.cursors == [nil, "7"])
    #expect(await client.lastEventID == "7")
}

@Test func heartbeatsKeepTheReaderLiveWithoutReconnecting() async throws {
    let clock = TestClock()
    let source = ScriptedSource([
        .openForever([": heartbeat\n\n", ": heartbeat\n\n", "id: 12\ndata: {\"b\":2}\n\n"])
    ])
    let client = testClient(now: { clock.value })

    let stream = await client.stream { cursor in try await source.open(cursor) }
    let elements = try await take(3, from: stream)

    let last = ServerSentEvent(id: "12", data: "{\"b\":2}")
    #expect(elements == [.heartbeat, .heartbeat, .event(last)])
    #expect(await client.heartbeatsObserved == 2)
    #expect(await client.isLive(within: .seconds(45)))
    #expect(await source.openCount == 1)
    clock.advance(120)
    #expect(await client.isLive(within: .seconds(45)) == false)
}

@Test func anExpiredCursorIsReportedAndTheStreamResumesWithoutOne() async throws {
    let source = ScriptedSource([
        .refusal(.cursorExpired),
        .chunks(["id: 43\ndata: {\"c\":3}\n\n"]),
    ])
    let client = testClient()
    await client.resume(from: "42")

    let stream = await client.stream { cursor in try await source.open(cursor) }
    let (elements, failure) = await drain(stream)

    #expect(
        elements == [
            .cursorExpired,
            .event(ServerSentEvent(id: "43", data: "{\"c\":3}")),
        ]
    )
    #expect(failure as? SSEOpenFailure == .unsupported(statusCode: 404))
    #expect(await source.cursors == ["42", nil, "43"])
}

@Test func aSparkThatRefusesTheStreamIsNotRetried() async {
    let source = ScriptedSource([], tail: .refusal(.unsupported(statusCode: 403)))
    let client = testClient()

    let stream = await client.stream { cursor in try await source.open(cursor) }
    let (elements, failure) = await drain(stream)

    #expect(elements.isEmpty)
    #expect(failure as? SSEOpenFailure == .unsupported(statusCode: 403))
    #expect(await source.openCount == 1)
}

@Test func aDroppedConnectionIsRetriedUntilThePolicyStops() async {
    let policy = SSERetryPolicy(maximumAttempts: 2)
    let source = ScriptedSource([], tail: .chunksThenDrop(["id: 5\ndata: {}\n\n"]))
    let client = testClient(retry: policy)

    let stream = await client.stream { cursor in try await source.open(cursor) }
    let (elements, failure) = await drain(stream)

    #expect(elements.count == 3)
    #expect(failure as? SSEStreamFailure == .reconnectionsExhausted(attempts: 2))
    #expect(await source.cursors == [nil, "5", "5"])
}

@Test func anOversizedFrameEndsTheStreamWithoutReconnecting() async {
    let source = ScriptedSource([
        .chunks(["data: " + String(repeating: "x", count: 400) + "\n\n"])
    ])
    let client = testClient(maxEventBytes: 64)

    let stream = await client.stream { cursor in try await source.open(cursor) }
    let (elements, failure) = await drain(stream)

    #expect(elements.isEmpty)
    #expect(failure as? SSEParser.SSEError == .eventTooLarge)
    #expect(await source.openCount == 1)
}

@Test func cancellingTheReaderStopsTheStreamAndReleasesTheByteSource() async throws {
    let (terminations, terminated) = AsyncStream<Void>.makeStream()
    let source = ScriptedSource(
        [.openForever(["id: 1\ndata: {}\n\n"])],
        onTerminate: { terminated.yield(()) }
    )
    let client = testClient()
    let (observed, observe) = AsyncStream<SSEStreamElement>.makeStream()

    // Consume the way the app does, so cancelling that task is what has to stop the reader.
    let reader = Task {
        let stream = await client.stream { cursor in try await source.open(cursor) }
        for try await element in stream { observe.yield(element) }
    }
    var elements = observed.makeAsyncIterator()
    #expect(await elements.next() == .event(ServerSentEvent(id: "1", data: "{}")))
    reader.cancel()

    #expect(await arrives(terminations, within: .seconds(5)))
    #expect(await source.openCount == 1)
}

@Test func backoffGrowsExponentiallyAndStaysBounded() {
    let policy = SSERetryPolicy(
        initialDelay: .milliseconds(500),
        maximumDelay: .seconds(30),
        multiplier: 2,
        jitterFraction: 0.25
    )

    #expect(policy.delay(forAttempt: 1, serverRetry: nil, jitter: 0.5) == .milliseconds(500))
    #expect(policy.delay(forAttempt: 2, serverRetry: nil, jitter: 0.5) == .seconds(1))
    #expect(policy.delay(forAttempt: 4, serverRetry: nil, jitter: 0.5) == .seconds(4))
    #expect(policy.delay(forAttempt: 12, serverRetry: nil, jitter: 0.5) == .seconds(30))
    #expect(policy.delay(forAttempt: 40, serverRetry: nil, jitter: 0.999) <= .seconds(30))
    let low = policy.delay(forAttempt: 1, serverRetry: nil, jitter: 0)
    #expect(low >= .milliseconds(374) && low <= .milliseconds(376))
    let high = policy.delay(forAttempt: 1, serverRetry: nil, jitter: 1)
    #expect(high >= .milliseconds(624) && high <= .milliseconds(626))
    #expect(policy.delay(forAttempt: 3, serverRetry: .seconds(5), jitter: 0.5) == .seconds(5))
    #expect(policy.delay(forAttempt: 3, serverRetry: .seconds(600), jitter: 0.5) == .seconds(30))
}
