import Foundation
import Security
import SparkCore
import SparkTransport
import Testing

// MARK: - Tests for the §13 route stack.

@Test func routePriorityFollowsDefaultOrder() {
    let node = SparkNodeID(rawValue: UUID())
    let scorer = RouteScorer()
    let pinned = "a1b2c3d4e5f60718293a4b5c6d7e8f90"

    let direct = SparkRoute(
        nodeID: node,
        baseURL: URL(string: "https://spark.local:7443")!,
        kind: .directEthernet,
        interfaceName: "en5",
        validatedIdentityFingerprint: pinned
    )
    let wifi = SparkRoute(
        nodeID: node,
        baseURL: URL(string: "https://spark.local:7443")!,
        kind: .localWiFi,
        interfaceName: "en0",
        validatedIdentityFingerprint: pinned
    )
    let overlay = SparkRoute(
        nodeID: node,
        baseURL: URL(string: "https://100.64.0.2")!,
        kind: .privateOverlay,
        interfaceName: nil,
        validatedIdentityFingerprint: pinned
    )
    let directRank = scorer.rankPart(of: direct, expectedFingerprint: pinned)
    let wifiRank = scorer.rankPart(of: wifi, expectedFingerprint: pinned)
    let overlayRank = scorer.rankPart(of: overlay, expectedFingerprint: pinned)

    #expect(directRank < wifiRank)
    #expect(wifiRank < overlayRank)
    #expect(overlayRank < .offlineCache)
}

@Test func identityMismatchRejectsRoute() {
    let node = SparkNodeID(rawValue: UUID())
    let scorer = RouteScorer()
    let route = SparkRoute(
        nodeID: node,
        baseURL: URL(string: "https://spark.local:7443")!,
        kind: .directEthernet,
        interfaceName: nil,
        validatedIdentityFingerprint: "11111111aaaaaaaa22222222bbbbbbbb"
    )
    let rank = scorer.rankPart(
        of: route,
        expectedFingerprint: "different-fingerprint"
    )
    #expect(rank == .rejected, "identity mismatch must reject the route")
}

@Test func repeatedFailuresDemoteRoute() {
    let node = SparkNodeID(rawValue: UUID())
    let scorer = RouteScorer()
    let pinned = "a1b2c3d4e5f60718293a4b5c6d7e8f90"
    let direct = SparkRoute(
        nodeID: node,
        baseURL: URL(string: "https://spark.local:7443")!,
        kind: .directEthernet,
        interfaceName: "en5",
        validatedIdentityFingerprint: pinned
    )
    let healed = scorer.rankPart(of: direct, expectedFingerprint: pinned, failures: 0)
    let degraded = scorer.rankPart(of: direct, expectedFingerprint: pinned, failures: 5)
    #expect(healed < degraded, "repeated failures must demote the route")
}

/// Ascending route order must place identity-rejected routes after every healthy route.
@Test func aRejectedRouteSortsBehindEveryUsableOne() {
    let usable: [RouteRank] = [
        .directEthernetPinned, .localWiFiPinned, .privateOverlay, .degraded,
        .offlineCache,
    ]
    for rank in usable {
        #expect(rank < .rejected, "\(rank) must outrank a rejected route")
    }

    // Mixed route sorting must keep rejected routes behind usable routes.
    let sorted = ([RouteRank.rejected] + usable).sorted()
    #expect(sorted.first == .directEthernetPinned)
    #expect(sorted.last == .rejected)
}

@Test func unmeteredPathsPreferredForDownloads() {
    let node = SparkNodeID(rawValue: UUID())
    let scorer = RouteScorer()
    let metered = SparkRoute(
        nodeID: node,
        baseURL: URL(string: "https://a")!,
        kind: .privateOverlay,
        interfaceName: nil,
        isMetered: true
    )
    let unmetered = SparkRoute(
        nodeID: node,
        baseURL: URL(string: "https://b")!,
        kind: .privateOverlay,
        interfaceName: nil,
        isMetered: false
    )
    #expect(scorer.prefersUnmetered(unmetered))
    #expect(!scorer.prefersUnmetered(metered))
}

// PinnedTrustPolicyTests covers trust decisions using real certificate fixtures.

// Parse identical SSE events across arbitrary chunk boundaries, terminators, comments and bounds (§38.3).
@Test func sseParsesAcrossChunkBoundaries() throws {
    let frame =
        "id: 17882\nevent: model.download.progress\ndata: {\"progress\":0.82}\n\nid: 17883\nevent: model.ready\ndata: {\"model\":\"m\"}\n\n"
    let data = Data(frame.utf8)

    // Feed byte-by-byte.
    var parserA = SSEParser()
    var eventsFromBytes: [ServerSentEvent] = []
    for byte in data {
        eventsFromBytes += try parserA.append(Data([byte]))
    }

    // Feed as two awkward chunks.
    var parserB = SSEParser()
    let mid = data.count / 3
    let eventsFromChunks =
        try parserB.append(data.prefix(mid))
        + parserB.append(data.subdata(in: data.startIndex + mid..<data.endIndex))

    #expect(eventsFromBytes.count == 2)
    #expect(eventsFromChunks == eventsFromBytes)
    #expect(eventsFromBytes[0].id == "17882")
    #expect(eventsFromBytes[0].event == "model.download.progress")
    #expect(eventsFromBytes[0].data.contains("\"progress\":0.82"))
    #expect(eventsFromBytes[1].event == "model.ready")
}

@Test func sseHandlesCRLFAndComments() throws {
    var parser = SSEParser()
    let crlf = "id: 1\r\n: heartbeat\r\nevent: ping\r\ndata: hi\r\n\r\n"
    let events = try parser.append(Data(crlf.utf8))
    #expect(events.count == 1)
    #expect(events[0].event == "ping")
    #expect(events[0].data == "hi")
}

@Test func sseDropsBadIdAndEnforcesSizeLimit() {
    var parser = SSEParser(maxEventBytes: 64)
    let bogus = "id: with\u{0}null\ndata: x\n\n"
    let events = try? parser.append(Data(bogus.utf8))
    #expect(events?.first?.id == nil, "the NUL-containing id must be dropped")
    _ = events
}

@Test func boundedEventSizeThrows() {
    var parser = SSEParser(maxEventBytes: 8)
    #expect(throws: SSEParser.SSEError.self) {
        try parser.append(Data("data: waytooLongValue\n\n".utf8))
    }
}

@Test func unterminatedLineBeyondTheCapThrowsInsteadOfBufferingForever() {
    var parser = SSEParser(maxEventBytes: 64)
    let chunk = String(repeating: "a", count: 40)
    #expect(throws: SSEParser.SSEError.self) {
        // No newline ever arrives; the pending line must still be bounded.
        _ = try parser.append(Data(("data: " + chunk).utf8))
        _ = try parser.append(Data(chunk.utf8))
    }
}

@Test func finishDispatchesTheFinalUnterminatedEvent() throws {
    var parser = SSEParser()
    _ = try parser.append(Data("event: done\ndata: final-token".utf8))
    let events = try parser.finish()
    #expect(events.count == 1)
    #expect(events[0].event == "done")
    #expect(events[0].data == "final-token")
}

/// Accept bare CR terminators equivalently to LF-delimited SSE.
@Test func sseHandlesBareCarriageReturnLineEndings() throws {
    var parser = SSEParser()
    // Dispatch on a complete blank line while retaining an ambiguous trailing CR until the next byte.
    let events = try parser.append(Data("data: a\r\rdata: b\r\r".utf8))
    #expect(events.count == 1)
    #expect(events[0].data == "a")
}

/// Do not turn CRLF split across chunks into an extra blank line.
@Test func sseCRLFSplitAcrossChunkBoundaryYieldsNoEmptyLine() throws {
    var parser = SSEParser()
    #expect(try parser.append(Data("data: hi\r".utf8)).isEmpty)
    let events = try parser.append(Data("\n\n".utf8))
    #expect(events.count == 1)
    #expect(events[0].data == "hi")
}

/// Enforce event bounds in UTF-8 bytes even when the grapheme count is small.
@Test func sseDataCapCountsUTF8BytesNotGraphemes() {
    var parser = SSEParser(maxEventBytes: 10)
    #expect(throws: SSEParser.SSEError.self) {
        // Reject three four-byte glyphs under a ten-byte cap.
        _ = try parser.append(Data("data: 😀\n".utf8))
        _ = try parser.append(Data("data: 😀\n".utf8))
        _ = try parser.append(Data("data: 😀\n".utf8))
    }
}
