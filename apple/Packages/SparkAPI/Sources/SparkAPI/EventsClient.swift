import Foundation
@_spi(SparkInternal) @_spi(SparkTestSupport) import SparkTransport

/// One runtime event envelope as `contracts/schemas/runtime-event.schema.json` defines it.
public struct SparkRuntimeEvent: Sendable, Equatable {
    /// The monotonic sequence the stream resumes from; it is the SSE frame's own id.
    public let sequence: Int
    /// The catalogue type, for example `model.ready`.
    public let type: String
    public let eventID: String?
    public let occurredAt: Date?
    public let nodeID: String?
    public let clusterID: String?
    /// Set when the event belongs to a durable operation the app may already be watching.
    public let operationID: String?
    public let severity: String?

    public init(
        sequence: Int,
        type: String,
        eventID: String? = nil,
        occurredAt: Date? = nil,
        nodeID: String? = nil,
        clusterID: String? = nil,
        operationID: String? = nil,
        severity: String? = nil
    ) {
        self.sequence = sequence
        self.type = type
        self.eventID = eventID
        self.occurredAt = occurredAt
        self.nodeID = nodeID
        self.clusterID = clusterID
        self.operationID = operationID
        self.severity = severity
    }
}

/// What the events stream told the app, in the order the Spark sent it.
public enum SparkEventStreamElement: Sendable, Equatable {
    case event(SparkRuntimeEvent)
    /// The stream is alive and nothing has changed.
    case heartbeat
    /// Replay could not reach the cursor: refresh every resource, then read on without one.
    case cursorExpired
}

/// Reads `GET /api/v1/events` signed and pinned, the way chat streams are (§38.3, §44.1).
public actor EventsClient {
    private let baseURL: URL
    private let session: URLSession
    /// Held because a streaming task has to be given the pinning delegate itself.
    private let trustDelegate: PinnedSessionDelegate
    private let signer: (any RequestSigning)?
    private let retry: SSERetryPolicy
    /// Matches the runtime's own 1 MiB envelope ceiling.
    private static let maxEventBytes = 1_048_576

    public init(
        baseURL: URL,
        pin: String,
        signer: (any RequestSigning)? = nil,
        retry: SSERetryPolicy = SSERetryPolicy()
    ) throws {
        try self.init(
            baseURL: baseURL,
            pin: pin,
            signer: signer,
            retry: retry,
            interceptingWith: []
        )
    }

    /// SPI tests may inject protocol classes but cannot replace the session's hardened configuration.
    @_spi(SparkTestSupport)
    public init(
        baseURL: URL,
        pin: String,
        signer: (any RequestSigning)? = nil,
        retry: SSERetryPolicy = SSERetryPolicy(),
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
        self.retry = retry
    }

    /// Release the session once its tasks drain so the pinning delegate is not retained.
    deinit {
        session.finishTasksAndInvalidate()
    }

    /// Stream events, resuming strictly after `cursor` and reconnecting until the caller stops.
    public func events(resumingFrom cursor: String? = nil) -> AsyncThrowingStream<
        SparkEventStreamElement, any Error
    > {
        AsyncThrowingStream { continuation in
            guard signer != nil else {
                continuation.finish(throwing: APIError(.userPresenceProofUnavailable))
                return
            }
            let task = Task { await self.pump(from: cursor, into: continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Internals

    private func pump(
        from cursor: String?,
        into continuation: AsyncThrowingStream<SparkEventStreamElement, any Error>.Continuation
    ) async {
        let reader = SSEClient(maxEventBytes: Self.maxEventBytes, retry: retry)
        await reader.resume(from: cursor)
        let frames = await reader.stream { [weak self] lastEventID in
            guard let self else { throw CancellationError() }
            return try await self.open(lastEventID: lastEventID)
        }
        do {
            for try await frame in frames {
                switch frame {
                case .heartbeat:
                    continuation.yield(.heartbeat)
                case .cursorExpired:
                    continuation.yield(.cursorExpired)
                case .event(let raw):
                    if let event = Self.decode(raw) { continuation.yield(.event(event)) }
                }
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    /// Open one signed, pinned attempt and classify a refusal before any byte is read.
    private func open(lastEventID: String?) async throws -> SSEByteStream {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/events"))
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let lastEventID, !lastEventID.isEmpty {
            request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID")
        }
        // A stream has no body, so the signature covers the empty digest the runtime expects.
        if let signer { request = try signer.authorize(request, body: Data()) }
        // Never let the request time out mid-stream; the heartbeat and the reader police liveness.
        request.timeoutInterval = Self.streamTimeout
        let requestDelegate = trustDelegate.forRequest()
        let host = baseURL.host ?? ""
        let opened: (bytes: URLSession.AsyncBytes, response: URLResponse)
        do {
            opened = try await session.bytes(for: request, delegate: requestDelegate)
        } catch {
            throw requestDelegate.transportError(error, host: host)
        }
        guard let http = opened.response as? HTTPURLResponse else {
            throw APIError(.nonHTTPResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw try await Self.refusal(status: http.statusCode, body: opened.bytes)
        }
        return Self.chunks(of: opened.bytes, delegate: requestDelegate, host: host)
    }

    /// Long enough that an idle-but-healthy stream is never cut by the client's own clock.
    private static let streamTimeout: TimeInterval = 86_400

    /// Read a bounded error body and decide whether reconnecting could ever help.
    private static func refusal(
        status: Int,
        body: URLSession.AsyncBytes
    ) async throws -> any Error {
        var payload = Data()
        for try await byte in body {
            payload.append(byte)
            if payload.count >= 8 * 1024 { break }
        }
        let envelope = try? JSONDecoder().decode([String: [String: String]].self, from: payload)
        let code = envelope?["error"]?["code"]
        if status == 409 && code == "EVENT_CURSOR_EXPIRED" {
            return SSEOpenFailure.cursorExpired
        }
        if Self.retryable.contains(status) || (500..<600).contains(status) && status != 501 {
            return APIError(.unexpectedStatus, statusCode: status, code: code)
        }
        return SSEOpenFailure.unsupported(statusCode: status)
    }

    /// §38.2 keeps transport-level, 408, 425, 429 and retryable 5xx worth another attempt.
    private static let retryable: Set<Int> = [408, 425, 429]

    /// Republish the byte stream as chunks, flushing on line ends so frames are not held back.
    private static func chunks(
        of bytes: URLSession.AsyncBytes,
        delegate: PinnedSessionDelegate,
        host: String
    ) -> SSEByteStream {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var buffer = Data()
                    buffer.reserveCapacity(4096)
                    for try await byte in bytes {
                        buffer.append(byte)
                        if byte == 0x0A || byte == 0x0D || buffer.count >= 4096 {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty { continuation.yield(buffer) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: delegate.transportError(error, host: host))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Decode the envelope, falling back to the frame's own id and name for an unreadable payload.
    private static func decode(_ frame: ServerSentEvent) -> SparkRuntimeEvent? {
        let frameSequence = frame.id.flatMap(Int.init)
        guard let data = frame.data.data(using: .utf8) else {
            return Self.minimal(sequence: frameSequence, type: frame.event)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let envelope = try? decoder.decode(WireEvent.self, from: data) else {
            return Self.minimal(sequence: frameSequence, type: frame.event)
        }
        return SparkRuntimeEvent(
            sequence: envelope.sequence ?? frameSequence ?? 0,
            type: envelope.type ?? frame.event ?? "",
            eventID: envelope.eventId,
            occurredAt: envelope.occurredAt,
            nodeID: envelope.nodeId,
            clusterID: envelope.clusterId,
            operationID: envelope.operationId,
            severity: envelope.severity
        )
    }

    /// Additive payload changes must never cost the app the type it already understands.
    private static func minimal(sequence: Int?, type: String?) -> SparkRuntimeEvent? {
        guard let sequence, let type, !type.isEmpty else { return nil }
        return SparkRuntimeEvent(sequence: sequence, type: type)
    }

    /// Every field optional so an envelope that grows or loses one is still an event.
    private struct WireEvent: Decodable {
        let sequence: Int?
        let type: String?
        let eventId: String?
        let occurredAt: Date?
        let nodeId: String?
        let clusterId: String?
        let operationId: String?
        let severity: String?
    }
}
