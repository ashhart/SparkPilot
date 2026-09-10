import CryptoKit
import Foundation
import SparkSecurity
import Testing

@testable import SparkBootstrap

/// Pin invitation struct-order signing bytes against the shared runtime fixture, retaining ADR-019's separate canonical-form contract.

private struct InvitationFixture: Decodable {
    struct Case: Decodable {
        let name: String
        let why: String
        let invitation: JSONValue
        let canonical: String
        let canonicalSHA256: String

        enum CodingKeys: String, CodingKey {
            case name, why, invitation, canonical
            case canonicalSHA256 = "canonical_sha256"
        }
    }
    let cases: [Case]
}

private func loadInvitationFixture() throws -> InvitationFixture {
    guard
        let url = Bundle.module.url(
            forResource: "Fixtures/pairing-invitation-canonicalization.json",
            withExtension: nil
        )
    else {
        Issue.record("missing invitation canonicalisation fixture")
        throw CocoaError(.fileNoSuchFile)
    }
    return try JSONDecoder().decode(InvitationFixture.self, from: try Data(contentsOf: url))
}

/// Replace the parsed signature with null when deriving unsigned invitation bytes.
private func parse(_ testCase: InvitationFixture.Case) throws -> PairingInvitationPayload {
    guard var members = testCase.invitation.objectValue else {
        throw FirstOwnerPairingError.malformedInvitation("case is not an object")
    }
    members["signature"] = .string(String(repeating: "A", count: 86))
    return try PairingInvitationPayload(json: .object(members))
}

@Test func swiftMatchesTheSharedInvitationFixture() throws {
    let fixture = try loadInvitationFixture()
    #expect(!fixture.cases.isEmpty)

    for testCase in fixture.cases {
        let payload = try parse(testCase)
        let produced = String(decoding: payload.canonicalBytes, as: UTF8.self)
        #expect(
            produced == testCase.canonical,
            """
            case \(testCase.name) disagrees with the runtime.
            \(testCase.why)
            expected: \(testCase.canonical)
            produced: \(produced)
            """
        )
        #expect(
            SHA256Hex.of(payload.canonicalBytes) == testCase.canonicalSHA256,
            "case \(testCase.name) digest"
        )
    }
}

@Test func anInvitationSignedByTheRuntimesFormVerifiesHere() throws {
    // Verify canonical fixture signatures through the production first-owner pairing path.
    let fixture = try loadInvitationFixture()
    let authority = Curve25519.Signing.PrivateKey()

    for testCase in fixture.cases {
        let signature = try authority.signature(for: Data(testCase.canonical.utf8))
        guard var members = testCase.invitation.objectValue else {
            Issue.record("case \(testCase.name) is not an object")
            continue
        }
        members["signature"] = .string(Base64URL.encode(signature))
        // Signed over the fixture's bytes, parsed as an arriving invitation.
        let payload = try PairingInvitationPayload(json: .object(members))
        #expect(throws: Never.self) { try payload.verify(under: authority.publicKey) }
    }
}

@Test func anInvitationMissingTheNullSignatureMemberWouldNotVerify() throws {
    // Retain the signature member as null even when other absent optionals are omitted.
    for testCase in try loadInvitationFixture().cases {
        #expect(
            testCase.canonical.hasSuffix(",\"signature\":null}"),
            "case \(testCase.name) should end with a null signature member"
        )
    }
}
