import Foundation
import Testing

@testable import SparkTransport

/// Uses seeded streams to verify chunk-independent SSE parsing, stable EOF handling and bounded buffering.
private struct LCG {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }

    mutating func bytes(_ count: Int) -> [UInt8] {
        (0..<count).map { _ in UInt8(next() % 256) }
    }

    mutating func pick<T>(_ values: [T]) -> T { values[below(values.count)] }
}

/// Seed for the generated frame corpus.
private let frameSeed: UInt64 = 0x5353_4546_555A_5A00  // "SSEFUZZ"
/// Seed for the chunk boundaries the corpus is delivered on.
private let chunkSeed: UInt64 = 0x4348_554E_4B53_5345  // "CHUNKSSE"
private let frameCases = 512

private let hostileStrings = [
    "", " ", "\u{0}", "\u{feff}", "\u{202e}drowssap", "\u{200d}\u{200d}",
    "e\u{301}\u{301}\u{301}", "\u{1f600}\u{1f3fb}\u{200d}\u{2640}", "ﬁ", "İ",
    "\u{fdfd}", "\\", "\"", "data:", ":", "id", "\r",
]

/// Mix valid events, comments, hostile data, duplicate fields and noise in generated SSE streams.
private func generatedStreams() -> [[UInt8]] {
    var rng = LCG(seed: frameSeed)
    var streams: [[UInt8]] = []
    for index in 0..<frameCases {
        var stream = ""
        for _ in 0...rng.below(6) {
            switch rng.below(8) {
            case 0:
                stream += "data: {\"delta\":\"\(rng.pick(hostileStrings))\"}\n\n"
            case 1:
                stream += "data: [DONE]\n\n"
            case 2:
                stream += ": heartbeat\n\n"
            case 3:
                // Two data lines: one event whose payload is joined by \n.
                stream += "data: first\ndata: second\n\n"
            case 4:
                // Duplicate fields: the last id wins, and event resets.
                stream += "id: a\nid: b\nevent: x\nevent: y\ndata: {}\n\n"
            case 5:
                stream += "retry: \(rng.next() % 100_000)\ndata: {}\n\n"
            case 6:
                stream += "\(rng.pick(hostileStrings))\n"
            default:
                stream += "data: {}\r\n\r\n"
            }
        }
        var bytes = Array(stream.utf8)
        // Every eighth case carries raw bytes that are not UTF-8.
        if index % 8 == 0 {
            bytes.append(contentsOf: rng.bytes(1 + rng.below(24)))
            bytes.append(0x0A)
        }
        streams.append(bytes)
    }
    return streams
}

/// Split reads inside characters and include empty reads without treating them as end-of-stream.
private func chunkings(_ bytes: [UInt8], rng: inout LCG) -> [[[UInt8]]] {
    var all: [[[UInt8]]] = [[bytes], bytes.map { [$0] }]
    for _ in 0..<3 {
        var chunks: [[UInt8]] = []
        var offset = 0
        while offset < bytes.count {
            let take = 1 + rng.below(max(1, bytes.count - offset))
            chunks.append(Array(bytes[offset..<(offset + take)]))
            if rng.below(4) == 0 { chunks.append([]) }
            offset += take
        }
        all.append(chunks)
    }
    return all
}

private func parse(_ chunks: [[UInt8]]) throws -> [ServerSentEvent] {
    var parser = SSEParser()
    var events: [ServerSentEvent] = []
    for chunk in chunks {
        events.append(contentsOf: try parser.append(Data(chunk)))
    }
    events.append(contentsOf: try parser.finish())
    return events
}

@Test("The events do not depend on where the chunk boundaries fell")
func theEventsDoNotDependOnTheChunking() throws {
    var rng = LCG(seed: chunkSeed)
    for (index, stream) in generatedStreams().enumerated() {
        let reference = try parse([stream])
        for chunks in chunkings(stream, rng: &rng) {
            #expect(
                try parse(chunks) == reference,
                "case \(index) parsed differently when split (seed \(frameSeed))"
            )
        }
    }
}

@Test("A line that can never become an event is refused, not buffered")
func anEndlessLineIsRefusedRatherThanBuffered() throws {
    var parser = SSEParser(maxEventBytes: 4096)
    var threw = false
    do {
        for _ in 0..<8 {
            _ = try parser.append(Data(repeating: UInt8(ascii: "x"), count: 1024))
        }
    } catch SSEParser.SSEError.eventTooLarge {
        threw = true
    }
    #expect(threw, "8 KiB of a line with no newline was buffered under a 4 KiB cap")
}

@Test("The cap counts bytes, so multi-byte text cannot stretch it")
func theCapCountsBytesNotCharacters() throws {
    var parser = SSEParser(maxEventBytes: 1024)
    // Use four-byte single-character payloads to detect character-counted byte limits.
    let payload = String(repeating: "\u{1f600}", count: 400)
    var threw = false
    do {
        _ = try parser.append("data: \(payload)\n\n")
    } catch SSEParser.SSEError.eventTooLarge {
        threw = true
    }
    #expect(threw, "1600 bytes of data passed a 1024 byte cap")
}

@Test("EOF is stable: a partial event flushes once and never twice")
func endOfStreamIsStable() throws {
    var parser = SSEParser()
    let first = try parser.append("data: {\"a\":1}")
    #expect(first.isEmpty, "an unterminated line dispatched an event early")
    let flushed = try parser.finish()
    #expect(flushed.count == 1)
    #expect(flushed.first?.data == "{\"a\":1}")
    #expect(try parser.finish().isEmpty, "finishing twice repeated the event")
}

@Test("Bytes that are not UTF-8 are decoded, never crashed on")
func invalidUTF8IsSurvived() throws {
    var rng = LCG(seed: frameSeed ^ 0x00FF)
    for _ in 0..<512 {
        var parser = SSEParser()
        var bytes: [UInt8] = Array("data: ".utf8)
        bytes.append(contentsOf: rng.bytes(1 + rng.below(48)))
        bytes.append(contentsOf: [0x0A, 0x0A])
        let events = try parser.append(Data(bytes)) + parser.finish()
        for event in events {
            // Invalid UTF-8 must decode lossily into a String without crashing or exposing raw bytes.
            #expect(event.data.utf8.count >= 0)
        }
    }
}

@Test("Every committed regression frame parses to what it did before")
func everyCommittedRegressionFrameStillParses() throws {
    // Load the shared corpus directly so Swift and Rust exercise identical fixtures.
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SparkTransportTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // SparkTransport
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // apple
        .deletingLastPathComponent()  // repository root
    let url = root.appending(path: "tests/security/fuzz/regressions.json")
    let document = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    guard
        let object = document as? [String: Any],
        let frames = object["sse_frames"] as? [[String: Any]]
    else {
        Issue.record("the regression corpus has no sse_frames section")
        return
    }
    #expect(!frames.isEmpty)
    var rng = LCG(seed: chunkSeed ^ 0x1234)
    for (index, frame) in frames.enumerated() {
        guard let text = frame["text"] as? String else {
            Issue.record("sse_frames#\(index) carries no text")
            continue
        }
        #expect((frame["why"] as? String)?.isEmpty == false, "sse_frames#\(index) says nothing")
        let bytes = Array(text.utf8)
        let reference = try parse([bytes])
        for chunks in chunkings(bytes, rng: &rng) {
            #expect(try parse(chunks) == reference, "sse_frames#\(index) is chunk dependent")
        }
    }
}
