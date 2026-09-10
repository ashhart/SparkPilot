import Foundation

/// One parsed Server-Sent Event (§38.3).
public struct ServerSentEvent: Sendable, Equatable {
    public var id: String?
    public var event: String?
    public var data: String
    public var retryMilliseconds: Int?

    public init(
        id: String? = nil,
        event: String? = nil,
        data: String = "",
        retryMilliseconds: Int? = nil
    ) {
        self.id = id
        self.event = event
        self.data = data
        self.retryMilliseconds = retryMilliseconds
    }
}

/// Parses SSE incrementally as UTF-8 bytes so CRLF terminators remain distinguishable across network chunks.
public struct SSEParser: Sendable {
    /// Bounded event payload size (never accumulate unbounded transcripts).
    public let maxEventBytes: Int
    private static let lf: UInt8 = 0x0A
    private static let cr: UInt8 = 0x0D

    private var buffer: Data = Data()
    private var eventId: String?
    private var eventName: String?
    private var dataLines: [String] = []
    private var retryMilliseconds: Int?
    /// Comment frames seen, so a reader can treat `: heartbeat` as liveness without buffering.
    public private(set) var commentsSeen = 0

    public init(maxEventBytes: Int = 1_048_576) {
        self.maxEventBytes = maxEventBytes
    }

    public mutating func append(_ data: Data) throws -> [ServerSentEvent] {
        buffer.append(data)
        let events = try drainBuffer()
        if buffer.count > maxEventBytes {
            // Reject overlong pending lines before an unterminated stream can grow the buffer indefinitely.
            throw SSEError.eventTooLarge
        }
        return events
    }

    public mutating func append(_ text: String) throws -> [ServerSentEvent] {
        try append(Data(text.utf8))
    }

    /// Flush a partially delivered final event (EOF semantics).
    public mutating func finish() throws -> [ServerSentEvent] {
        var events: [ServerSentEvent] = []
        if !buffer.isEmpty {
            buffer.append(SSEParser.lf)
            events.append(contentsOf: try drainBuffer())
        }
        events.append(contentsOf: try flushDispatch())
        return events
    }

    public enum SSEError: Error, Equatable {
        case eventTooLarge
    }

    private mutating func drainBuffer() throws -> [ServerSentEvent] {
        var events: [ServerSentEvent] = []
        // Retain a trailing CR until the next chunk resolves CRLF; finish() supplies LF to flush a final CR-terminated line.
        while let terminator = buffer.firstIndex(where: {
            $0 == SSEParser.lf || $0 == SSEParser.cr
        }) {
            let afterTerminator: Data.Index
            if buffer[terminator] == SSEParser.cr {
                let next = buffer.index(after: terminator)
                if next == buffer.endIndex {
                    break  // trailing CR: wait for the byte that follows it
                }
                afterTerminator =
                    buffer[next] == SSEParser.lf ? buffer.index(after: next) : next
            } else {
                afterTerminator = buffer.index(after: terminator)
            }
            let lineBytes = buffer[buffer.startIndex..<terminator]
            let line = String(decoding: Data(lineBytes), as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex..<afterTerminator)
            try handleLine(line, events: &events)
        }
        return events
    }

    private mutating func handleLine(_ line: String, events: inout [ServerSentEvent]) throws {
        if line.isEmpty {
            if let event = dispatch() {
                events.append(event)
            }
            return
        }
        if line.hasPrefix(":") {
            commentsSeen += 1
            return
        }
        let parts = line.split(separator: ":", maxSplits: 1)
        let field = String(parts[0]).trimmingCharacters(in: .whitespaces)
        let rawValue = parts.count > 1 ? String(parts[1]) : ""
        let value = rawValue.hasPrefix(" ") ? String(rawValue.dropFirst()) : rawValue
        switch field {
        case "id":
            if !value.contains("\u{0}") { eventId = value }
        case "event":
            eventName = value.isEmpty ? nil : value
        case "data":
            // Count UTF-8 bytes for maxEventBytes so multibyte payloads cannot bypass the bound.
            let accumulated = dataLines.reduce(0) { $0 + $1.utf8.count }
            if accumulated + value.utf8.count > maxEventBytes {
                throw SSEError.eventTooLarge
            }
            dataLines.append(value)
        case "retry":
            retryMilliseconds = Int(value.trimmingCharacters(in: .whitespaces))
        default:
            break  // unknown fields ignored
        }
    }

    private mutating func flushDispatch() throws -> [ServerSentEvent] {
        if let event = dispatch() {
            return [event]
        }
        return []
    }

    private mutating func dispatch() -> ServerSentEvent? {
        let data = dataLines.joined(separator: "\n")
        dataLines.removeAll()
        // Dispatch only events with data while retaining sticky IDs without replaying stale frames.
        guard !data.isEmpty else {
            eventName = nil
            return nil
        }
        let event = ServerSentEvent(
            id: eventId,
            event: eventName,
            data: data,
            retryMilliseconds: retryMilliseconds
        )
        eventName = nil
        return event
    }
}
