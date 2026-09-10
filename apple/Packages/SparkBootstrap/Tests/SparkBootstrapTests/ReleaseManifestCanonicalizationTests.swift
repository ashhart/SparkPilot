import Foundation
import Testing

@testable import SparkBootstrap

/// Compare release signing bytes with the shared fixture used by Rust and Python.

private struct CanonicalizationFixture: Decodable {
    struct Case: Decodable {
        let name: String
        let why: String
        let manifest: JSONValue
        let canonical: String
        let canonicalSHA256: String

        enum CodingKeys: String, CodingKey {
            case name, why, manifest, canonical
            case canonicalSHA256 = "canonical_sha256"
        }
    }
    let cases: [Case]
}

private func fixtureData(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil)
    else {
        Issue.record("missing fixture \(name)")
        throw CocoaError(.fileNoSuchFile)
    }
    return try Data(contentsOf: url)
}

private func loadFixture() throws -> CanonicalizationFixture {
    try JSONDecoder().decode(
        CanonicalizationFixture.self,
        from: fixtureData("release-manifest-canonicalization.json")
    )
}

@Test func swiftMatchesTheSharedCanonicalisationFixture() throws {
    let fixture = try loadFixture()
    #expect(!fixture.cases.isEmpty)

    for testCase in fixture.cases {
        let canonical = try testCase.manifest.canonicalBytes(excludingTopLevel: "signature")
        let produced = String(decoding: canonical, as: UTF8.self)
        #expect(
            produced == testCase.canonical,
            """
            case \(testCase.name) disagrees with the shared fixture.
            \(testCase.why)
            expected: \(testCase.canonical)
            produced: \(produced)
            """
        )
        #expect(SHA256Hex.of(canonical) == testCase.canonicalSHA256, "case \(testCase.name) digest")
    }
}

@Test func optionalShapeAndKeyOrderDoNotChangeTheSignedBytes() throws {
    // Canonicalize omitted/null optionals, reordered keys and signed manifests to the same release bytes.
    let fixture = try loadFixture()
    let equivalent = [
        "explicit_null_optional",
        "omitted_optionals",
        "reordered_keys",
        "signature_member_is_excluded",
    ]
    let selected = fixture.cases.filter { equivalent.contains($0.name) }
    #expect(selected.count == 4, "all four equivalence cases are present")

    var produced = Set<Data>()
    for testCase in selected {
        produced.insert(try testCase.manifest.canonicalBytes(excludingTopLevel: "signature"))
    }
    #expect(produced.count == 1, "four equivalent manifests produced \(produced.count) forms")
}

@Test func canonicalBytesNeverCarryANullOrAnEscapedSolidus() throws {
    let fixture = try loadFixture()
    for testCase in fixture.cases {
        let canonical = String(
            decoding: try testCase.manifest.canonicalBytes(excludingTopLevel: "signature"),
            as: UTF8.self
        )
        #expect(!canonical.contains(":null"), "case \(testCase.name): nulls must be dropped")
        #expect(!canonical.contains("\\/"), "case \(testCase.name): the solidus is never escaped")
        #expect(
            !canonical.contains("\"signature\":"),
            "case \(testCase.name): the signature member is excluded"
        )
    }
}

@Test func escapingFollowsTheStatedRules() throws {
    let value = JSONValue.object([
        "quote": .string("a\"b"),
        "backslash": .string("a\\b"),
        "solidus": .string("a/b"),
        "controls": .string("\u{08}\u{09}\u{0A}\u{0C}\u{0D}\u{07}"),
        "nonAscii": .string("caf\u{E9}"),
    ])
    let produced = String(decoding: try value.canonicalBytes(), as: UTF8.self)

    #expect(produced.contains("\"quote\":\"a\\\"b\""))
    #expect(produced.contains("\"backslash\":\"a\\\\b\""))
    #expect(produced.contains("\"solidus\":\"a/b\""), "the solidus is written as itself")
    #expect(produced.contains("\"controls\":\"\\b\\t\\n\\f\\r\\u0007\""))
    #expect(produced.contains("caf\u{E9}"), "non-ASCII is raw UTF-8, never \\uXXXX")

    // Sort canonical object keys by UTF-8 bytes independently of insertion order.
    let keys = ["backslash", "controls", "nonAscii", "quote", "solidus"]
    var searchRange = produced.startIndex..<produced.endIndex
    for key in keys {
        guard let found = produced.range(of: "\"\(key)\":", range: searchRange) else {
            Issue.record("key \(key) is out of order in \(produced)")
            return
        }
        searchRange = found.upperBound..<produced.endIndex
    }
}

@Test func aFractionalNumberIsRefusedRatherThanGuessedAt() throws {
    // Reject fractional manifest values without inventing a cross-language representation.
    let value = JSONValue.object(["ratio": .double(1.5)])
    #expect(throws: CanonicalJSONError.unsupportedNumber(1.5)) {
        _ = try value.canonicalBytes()
    }
}

@Test func aWholeNumberThatArrivedAsADoubleStaysExact() throws {
    let value = JSONValue.object(["size": .double(4096)])
    #expect(String(decoding: try value.canonicalBytes(), as: UTF8.self) == "{\"size\":4096}")
}
