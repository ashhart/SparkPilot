import CryptoKit
import Foundation
import SparkSecurity
import Testing

/// Pin SPARK2 request-signing bytes to the shared runtime canonicalization fixture.

private struct SigningFixture: Decodable {
    struct Request: Decodable {
        let method: String
        let pathAndQuery: String
        let timestamp: String
        let nonce: String
        let deviceID: String
        let nodeID: UUID
        let body: String

        enum CodingKeys: String, CodingKey {
            case method
            case pathAndQuery = "path_and_query"
            case timestamp
            case nonce
            case deviceID = "device_id"
            case nodeID = "node_id"
            case body
        }
    }

    struct Case: Decodable {
        let name: String
        let why: String
        let request: Request
        let contentSHA256: String
        let canonical: String
        let canonicalSHA256: String

        enum CodingKeys: String, CodingKey {
            case name, why, request, canonical
            case contentSHA256 = "content_sha256"
            case canonicalSHA256 = "canonical_sha256"
        }
    }

    let cases: [Case]
    let headers: [String: String]
}

private func loadFixture() throws -> SigningFixture {
    guard
        let url = Bundle.module.url(
            forResource: "Fixtures/request-signing-canonicalization.json",
            withExtension: nil
        )
    else {
        Issue.record("missing request signing canonicalisation fixture")
        throw CocoaError(.fileNoSuchFile)
    }
    return try JSONDecoder().decode(SigningFixture.self, from: try Data(contentsOf: url))
}

private func sha256Hex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

@Test("Every shared canonical case rebuilds byte for byte")
func theAppReproducesEveryCanonicalCase() throws {
    let fixture = try loadFixture()
    #expect(!fixture.cases.isEmpty)
    for testCase in fixture.cases {
        let bodyDigest = SHA256Digest.hex(Data(testCase.request.body.utf8))
        #expect(
            bodyDigest == testCase.contentSHA256,
            "\(testCase.name): body digest differs"
        )
        let canonical = CanonicalRequest(
            method: testCase.request.method,
            pathAndQuery: testCase.request.pathAndQuery,
            timestamp: testCase.request.timestamp,
            nonce: testCase.request.nonce,
            bodyHashHex: bodyDigest,
            deviceID: testCase.request.deviceID,
            nodeID: testCase.request.nodeID
        )
        let produced = String(decoding: canonical.signatureInput, as: UTF8.self)
        #expect(
            produced == testCase.canonical,
            "\(testCase.name): canonical bytes differ from the shared fixture"
        )
        #expect(
            sha256Hex(produced) == testCase.canonicalSHA256,
            "\(testCase.name): canonical digest differs"
        )
    }
}

@Test("The signed headers are the names the runtime reads")
func theHeaderNamesMatchTheContract() throws {
    let fixture = try loadFixture()
    let canonical = CanonicalRequest(
        method: "GET",
        pathAndQuery: "/api/v1/status",
        timestamp: "2026-08-27T10:05:00Z",
        nonce: "n",
        bodyHashHex: SHA256Digest.hex(Data()),
        deviceID: "ca890ed7-7c8c-4b2c-9218-b77ef24f569a",
        nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    )
    let headers = try canonical.headers(signingKey: { _ in Data(repeating: 0, count: 64) })
    // Canonicalize header names case-insensitively to match runtime verification.
    let sent = Set(headers.keys.map { $0.lowercased() })
    for name in ["node_id", "device_id", "timestamp", "nonce", "content_sha256", "signature"] {
        guard let expected = fixture.headers[name]?.lowercased() else {
            Issue.record("fixture does not name the \(name) header")
            continue
        }
        #expect(sent.contains(expected), "a signed request must carry \(expected)")
    }
}

@Test("The device id is the line that binds a signature to one device")
func theDeviceIDLineBindsTheSignature() {
    // Bind signing bytes to device identity to prevent replay under another device header.
    func input(deviceID: String) -> String {
        String(
            decoding: CanonicalRequest(
                method: "GET",
                pathAndQuery: "/api/v1/status",
                timestamp: "2026-08-27T10:05:00Z",
                nonce: "n",
                bodyHashHex: SHA256Digest.hex(Data()),
                deviceID: deviceID,
                nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            ).signatureInput,
            as: UTF8.self
        )
    }
    let first = input(deviceID: "ca890ed7-7c8c-4b2c-9218-b77ef24f569a")
    let second = input(deviceID: "3b6e5c2a-1d4f-4a8b-9c0d-2e5f7a8b9c0d")
    #expect(first != second)
    #expect(first.split(separator: "\n", omittingEmptySubsequences: false).count == 8)
    #expect(first.hasPrefix("SPARK2\n"))
    #expect(first.contains("\nca890ed7-7c8c-4b2c-9218-b77ef24f569a\n"))
}
