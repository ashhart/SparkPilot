import Foundation

/// The chunked bytes of one attempt at an SSE response, so the reader never owns the transport.
public typealias SSEByteStream = AsyncThrowingStream<Data, any Error>

/// What the reader saw, in the order the Spark sent it.
public enum SSEStreamElement: Sendable, Equatable {
    case event(ServerSentEvent)
    /// A heartbeat comment: nothing changed and the connection is alive.
    case heartbeat
    /// Replay no longer covers our cursor, so refresh everything and read on without one.
    case cursorExpired
}

/// Why one attempt to open the stream produced no stream.
public enum SSEOpenFailure: Error, Sendable, Equatable {
    /// `409 EVENT_CURSOR_EXPIRED`: the cursor is older than retained history.
    case cursorExpired
    /// This Spark does not serve the stream to this device, so the reader stops rather than retrying.
    case unsupported(statusCode: Int)
}

/// Why the reader gave up rather than reconnecting again.
public enum SSEStreamFailure: Error, Sendable, Equatable {
    case reconnectionsExhausted(attempts: Int)
}

/// Bounded exponential backoff with jitter, so a Spark that drops every stream is not hammered.
public struct SSERetryPolicy: Sendable, Equatable {
    public var initialDelay: Duration
    public var maximumDelay: Duration
    public var multiplier: Double
    /// The fraction of the delay the jitter may move it by, in either direction.
    public var jitterFraction: Double
    /// How long a connection must stay up before the backoff counts as recovered.
    public var resetAfter: Duration
    /// Reconnections to attempt before giving up; nil reconnects for as long as the reader lives.
    public var maximumAttempts: Int?

    public init(
        initialDelay: Duration = .milliseconds(500),
        maximumDelay: Duration = .seconds(30),
        multiplier: Double = 2,
        jitterFraction: Double = 0.25,
        resetAfter: Duration = .seconds(30),
        maximumAttempts: Int? = nil
    ) {
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.multiplier = multiplier
        self.jitterFraction = jitterFraction
        self.resetAfter = resetAfter
        self.maximumAttempts = maximumAttempts
    }

    /// A `retry:` field the Spark sent replaces the growth curve but never the ceiling.
    public func delay(forAttempt attempt: Int, serverRetry: Duration?, jitter: Double) -> Duration {
        // Cap the exponent before the curve so a long outage cannot overflow the arithmetic.
        let step = min(max(attempt, 1) - 1, 32)
        let base = serverRetry ?? initialDelay * pow(max(multiplier, 1), Double(step))
        let bounded = min(base, maximumDelay)
        let spread = 1 + jitterFraction * (min(max(jitter, 0), 1) * 2 - 1)
        return min(max(bounded * max(spread, 0), .zero), maximumDelay)
    }
}

/// Reads a Server-Sent Events stream (§38.3), resuming by `Last-Event-ID` across reconnects (§44.1).
public actor SSEClient {
    /// Opens one attempt, given the cursor to replay from; throws `SSEOpenFailure` for a refusal.
    public typealias Open = @Sendable (_ lastEventID: String?) async throws -> SSEByteStream

    /// The cursor the next attempt replays from, which callers persist across launches.
    public private(set) var lastEventID: String?
    /// Heartbeat comments seen since this reader was created.
    public private(set) var heartbeatsObserved = 0
    /// Reconnections started since this reader was created.
    public private(set) var reconnections = 0
    /// When the last byte arrived, heartbeat or event.
    public private(set) var lastActivity: Date?

    private let maxEventBytes: Int
    private let retry: SSERetryPolicy
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let jitter: @Sendable () -> Double
    private var serverRetryHint: Duration?

    public init(
        maxEventBytes: Int = 1_048_576,
        retry: SSERetryPolicy = SSERetryPolicy(),
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.maxEventBytes = maxEventBytes
        self.retry = retry
        self.now = now
        self.sleep = sleep
        self.jitter = jitter
    }

    /// Seed the cursor from storage so a relaunch resumes rather than replaying everything.
    public func resume(from id: String?) {
        lastEventID = id
    }

    /// True while a byte arrived inside the window; a heartbeat is enough, an event is not required.
    public func isLive(within window: Duration) -> Bool {
        guard let lastActivity else { return false }
        let elapsed = now().timeIntervalSince(lastActivity)
        return elapsed >= 0 && elapsed <= Self.seconds(window)
    }

    /// Read the stream, reconnecting until the reader is cancelled or the Spark refuses it.
    public func stream(opening open: @escaping Open) -> AsyncThrowingStream<
        SSEStreamElement, any Error
    > {
        AsyncThrowingStream { continuation in
            let task = Task { await self.read(opening: open, into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func read(
        opening open: @escaping Open,
        into continuation: AsyncThrowingStream<SSEStreamElement, any Error>.Continuation
    ) async {
        var attempt = 0
        while !Task.isCancelled {
            let openedAt = now()
            do {
                let bytes = try await open(lastEventID)
                try await consume(bytes, into: continuation)
                if now().timeIntervalSince(openedAt) >= Self.seconds(retry.resetAfter) {
                    attempt = 0
                }
            } catch let refusal as SSEOpenFailure {
                if case .unsupported = refusal {
                    continuation.finish(throwing: refusal)
                    return
                }
                if lastEventID != nil {
                    lastEventID = nil
                    continuation.yield(.cursorExpired)
                    continue
                }
            } catch let overlong as SSEParser.SSEError {
                continuation.finish(throwing: overlong)
                return
            } catch is CancellationError {
                break
            } catch {
                // Every other failure is a dropped connection, which the backoff below answers.
            }
            if Task.isCancelled { break }
            attempt += 1
            if let cap = retry.maximumAttempts, attempt > cap {
                continuation.finish(
                    throwing: SSEStreamFailure.reconnectionsExhausted(attempts: cap)
                )
                return
            }
            reconnections += 1
            do {
                try await sleep(
                    retry.delay(
                        forAttempt: attempt,
                        serverRetry: serverRetryHint,
                        jitter: jitter()
                    )
                )
            } catch {
                break
            }
        }
        continuation.finish()
    }

    private func consume(
        _ bytes: SSEByteStream,
        into continuation: AsyncThrowingStream<SSEStreamElement, any Error>.Continuation
    ) async throws {
        var parser = SSEParser(maxEventBytes: maxEventBytes)
        var comments = 0
        for try await chunk in bytes {
            if Task.isCancelled { return }
            lastActivity = now()
            let events = try parser.append(chunk)
            if parser.commentsSeen > comments {
                heartbeatsObserved += parser.commentsSeen - comments
                for _ in comments..<parser.commentsSeen {
                    continuation.yield(.heartbeat)
                }
                comments = parser.commentsSeen
            }
            for event in events {
                if let id = event.id, !id.isEmpty { lastEventID = id }
                if let milliseconds = event.retryMilliseconds {
                    serverRetryHint = .milliseconds(milliseconds)
                }
                continuation.yield(.event(event))
            }
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
