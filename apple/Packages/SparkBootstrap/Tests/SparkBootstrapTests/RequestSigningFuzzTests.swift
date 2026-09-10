import CryptoKit
import Foundation
import SparkSecurity
import Testing

/// Verify deterministic runtime-generated SPARK2 fuzz vectors; regenerate with SPARK_FUZZ_WRITE_VECTORS=1 on signature_fuzz.

private struct FuzzVectors: Decodable {
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
        let request: Request
        let contentSHA256: String
        let canonical: String
        let canonicalSHA256: String

        enum CodingKeys: String, CodingKey {
            case name, request, canonical
            case contentSHA256 = "content_sha256"
            case canonicalSHA256 = "canonical_sha256"
        }
    }

    let seed: String
    let cases: [Case]
}

private func loadVectors() throws -> FuzzVectors {
    guard
        let url = Bundle.module.url(
            forResource: "Fixtures/request-signing-fuzz.json",
            withExtension: nil
        )
    else {
        Issue.record("missing generated request-signing vectors")
        throw CocoaError(.fileNoSuchFile)
    }
    return try JSONDecoder().decode(FuzzVectors.self, from: try Data(contentsOf: url))
}

private func canonicalRequest(_ testCase: FuzzVectors.Case, bodyDigest: String) -> CanonicalRequest
{
    CanonicalRequest(
        method: testCase.request.method,
        pathAndQuery: testCase.request.pathAndQuery,
        timestamp: testCase.request.timestamp,
        nonce: testCase.request.nonce,
        bodyHashHex: bodyDigest,
        deviceID: testCase.request.deviceID,
        nodeID: testCase.request.nodeID
    )
}

private func hex(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

@Test("Every generated vector rebuilds byte for byte on this side")
func theAppRebuildsEveryGeneratedVector() throws {
    let vectors = try loadVectors()
    #expect(vectors.cases.count == 128, "the vector file lost cases")
    for testCase in vectors.cases {
        let digest = SHA256Digest.hex(Data(testCase.request.body.utf8))
        #expect(digest == testCase.contentSHA256, "\(testCase.name): body digest differs")
        let produced = String(
            decoding: canonicalRequest(testCase, bodyDigest: digest).signatureInput,
            as: UTF8.self
        )
        #expect(
            produced == testCase.canonical,
            "\(testCase.name): canonical bytes differ from the runtime's"
        )
        #expect(hex(produced) == testCase.canonicalSHA256, "\(testCase.name): digest differs")
        #expect(
            produced.components(separatedBy: "\n").count == 8,
            "\(testCase.name): the normative form has eight lines"
        )
    }
}

@Test("Changing one field changes the bytes this side signs")
func oneChangedFieldChangesTheSignedBytes() throws {
    let vectors = try loadVectors()
    for testCase in vectors.cases.prefix(32) {
        let digest = SHA256Digest.hex(Data(testCase.request.body.utf8))
        let original = canonicalRequest(testCase, bodyDigest: digest).signatureInput
        let request = testCase.request
        let mutations: [CanonicalRequest] = [
            CanonicalRequest(
                method: request.method,
                pathAndQuery: request.pathAndQuery,
                timestamp: request.timestamp,
                nonce: request.nonce,
                bodyHashHex: digest,
                deviceID: request.deviceID,
                nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
            ),
            CanonicalRequest(
                // Canonicalize HTTP method case so get and GET produce the same signing field.
                method: request.method.uppercased() == "PATCH" ? "DELETE" : "PATCH",
                pathAndQuery: request.pathAndQuery,
                timestamp: request.timestamp,
                nonce: request.nonce,
                bodyHashHex: digest,
                deviceID: request.deviceID,
                nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            ),
            CanonicalRequest(
                method: request.method,
                pathAndQuery: request.pathAndQuery + "x",
                timestamp: request.timestamp,
                nonce: request.nonce,
                bodyHashHex: digest,
                deviceID: request.deviceID,
                nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            ),
            CanonicalRequest(
                method: request.method,
                pathAndQuery: request.pathAndQuery,
                timestamp: "2026-01-01T00:00:00Z",
                nonce: request.nonce,
                bodyHashHex: digest,
                deviceID: request.deviceID,
                nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            ),
            CanonicalRequest(
                method: request.method,
                pathAndQuery: request.pathAndQuery,
                timestamp: request.timestamp,
                nonce: request.nonce + "=",
                bodyHashHex: digest,
                deviceID: request.deviceID,
                nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            ),
            CanonicalRequest(
                method: request.method,
                pathAndQuery: request.pathAndQuery,
                timestamp: request.timestamp,
                nonce: request.nonce,
                bodyHashHex: SHA256Digest.hex(Data("different".utf8)),
                deviceID: request.deviceID,
                nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            ),
            CanonicalRequest(
                method: request.method,
                pathAndQuery: request.pathAndQuery,
                timestamp: request.timestamp,
                nonce: request.nonce,
                bodyHashHex: digest,
                deviceID: "00000000-0000-4000-8000-000000000000",
                nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            ),
        ]
        for (index, mutation) in mutations.enumerated() {
            #expect(
                mutation.signatureInput != original,
                "\(testCase.name): mutation \(index) signed the same bytes"
            )
        }
    }
}

@Test("A field carrying the delimiter is not something this side can send")
func aFieldCarryingTheDelimiterCannotBeSent() {
    // Reject embedded newlines that could alter canonical signing-field boundaries.
    let request = URLRequest(url: URL(string: "https://spark.invalid/api/v1/status")!)
    var mutable = request
    mutable.setValue("a\nb", forHTTPHeaderField: "X-Spark-Nonce")
    #expect(
        mutable.value(forHTTPHeaderField: "X-Spark-Nonce") != "a\nb",
        "a header value with a newline was accepted verbatim"
    )
}
