import Foundation
import Testing

@testable import SparkBootstrap

/// Verify the shipped Python-signed release through the independent Swift verifier and shared Rust-compatible trust root.

private func fixture(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil) else {
        Issue.record("missing fixture \(name)")
        throw CocoaError(.fileNoSuchFile)
    }
    return try Data(contentsOf: url)
}

private func trustRoot() throws -> ReleaseTrustRoot {
    try ReleaseTrustRoot.parse(fixture("release-keys.json"))
}

private func shippedManifest() throws -> Data {
    try fixture("spark-runtime-0.1.0-dev.json")
}

/// Mutate an actual signed artifact member so fixture host changes cannot disable the tampering test.
private func manifestReplacingArtifactMember(
    _ member: String,
    with replacement: String
) throws -> Data {
    var manifest = try #require(JSONValue.parse(try shippedManifest()).objectValue)
    var artifacts = try #require(manifest["artifacts"]?.arrayValue)
    var artifact = try #require(artifacts.first?.objectValue)
    artifact[member] = .string(replacement)
    artifacts[0] = .object(artifact)
    manifest["artifacts"] = .array(artifacts)
    return try JSONValue.object(manifest).canonicalBytes()
}

private let shippedKeyID = "spark-release-dev-2026b"
private let insideWindow = RFC3339.date(from: "2026-08-28T17:00:00Z")!

private func shippedKeyIndex(in keys: [JSONValue]) throws -> Int {
    try #require(keys.firstIndex { $0.objectValue?["key_id"]?.stringValue == shippedKeyID })
}

@Test func theShippedManifestVerifiesAgainstTheShippedTrustRoot() throws {
    let verified = try trustRoot().verify(manifest: shippedManifest(), at: insideWindow)
    #expect(verified.keyID == shippedKeyID)
    #expect(verified.manifest.version == "0.1.0")
    #expect(verified.manifest.channel == "dev")
    #expect(verified.manifest.artifacts.count == 1)

    let artifact = try verified.manifest.artifact(named: nil)
    #expect(artifact.architecture == "aarch64")
    #expect(artifact.sha256.count == 64)
    #expect(artifact.url.scheme == "https")
    #expect(artifact.signatureURL.scheme == "https")
}

@Test func theTrustRootRecordsPurposesAndAWindow() throws {
    let root = try trustRoot()
    #expect(root.schema == ReleaseTrustRoot.currentSchema)
    let key = try #require(root.keys.first)
    #expect(key.purposes.contains(ReleaseTrustRoot.manifestPurpose))
    #expect(key.purposes.contains(ReleaseTrustRoot.packagePurpose))
    #expect(!key.purposes.contains(ReleaseTrustRoot.cataloguePurpose))
    #expect(key.channels.allSatisfy(ReleaseTrustRoot.directTrustChannels.contains))
    #expect(key.revokedAt == nil)
    #expect(key.notAfter > key.notBefore)
}

@Test func aTamperedDigestBreaksTheManifestSignature() throws {
    var text = String(decoding: try shippedManifest(), as: UTF8.self)
    let manifest = try ReleaseManifest.parse(try shippedManifest())
    let real = try manifest.artifact(named: nil).sha256
    text = text.replacingOccurrences(of: real, with: String(repeating: "0", count: 64))

    #expect(throws: ReleaseTrustError.signatureInvalid(shippedKeyID)) {
        _ = try trustRoot().verify(manifest: Data(text.utf8), at: insideWindow)
    }
}

@Test func aTamperedURLBreaksTheManifestSignature() throws {
    let tampered = try manifestReplacingArtifactMember(
        "url",
        with: "https://tampered.invalid/spark-runtime.deb"
    )
    #expect(throws: ReleaseTrustError.signatureInvalid(shippedKeyID)) {
        _ = try trustRoot().verify(manifest: tampered, at: insideWindow)
    }
}

@Test func anUnsignedManifestIsRefused() throws {
    var members = try #require(JSONValue.parse(try shippedManifest()).objectValue)
    members.removeValue(forKey: "signature")
    let unsigned = try JSONValue.object(members).canonicalBytes()

    #expect(throws: ReleaseTrustError.manifest(.missingSignature)) {
        _ = try trustRoot().verify(manifest: unsigned, at: insideWindow)
    }
}

@Test func aManifestSignedByAnUnknownKeyIsRefused() throws {
    let text = String(decoding: try shippedManifest(), as: UTF8.self)
        .replacingOccurrences(of: shippedKeyID, with: "somebody-elses-key")
    #expect(throws: ReleaseTrustError.unknownKeyID("somebody-elses-key")) {
        _ = try trustRoot().verify(manifest: Data(text.utf8), at: insideWindow)
    }
}

@Test func aKeyOutsideItsWindowIsRefused() throws {
    let tooLate = RFC3339.date(from: "2029-01-01T00:00:00Z")!
    #expect(throws: ReleaseTrustError.self) {
        _ = try trustRoot().verify(manifest: shippedManifest(), at: tooLate)
    }
    let tooEarly = RFC3339.date(from: "2025-01-01T00:00:00Z")!
    #expect(throws: ReleaseTrustError.self) {
        _ = try trustRoot().verify(manifest: shippedManifest(), at: tooEarly)
    }
}

@Test func aRevokedKeyIsRefused() throws {
    var root = try #require(JSONValue.parse(try fixture("release-keys.json")).objectValue)
    var keys = try #require(root["keys"]?.arrayValue)
    let keyIndex = try shippedKeyIndex(in: keys)
    var key = try #require(keys[keyIndex].objectValue)
    key["revoked_at"] = .string("2026-08-28T11:00:00Z")
    keys[keyIndex] = .object(key)
    root["keys"] = .array(keys)

    let revoked = try ReleaseTrustRoot.parse(try JSONValue.object(root).canonicalBytes())
    #expect(throws: ReleaseTrustError.revokedKey(shippedKeyID)) {
        _ = try revoked.verify(manifest: shippedManifest(), at: insideWindow)
    }
}

@Test func unparseableRevocationMetadataIsRefusedRatherThanIgnored() throws {
    var root = try #require(JSONValue.parse(try fixture("release-keys.json")).objectValue)
    var keys = try #require(root["keys"]?.arrayValue)
    let keyIndex = try shippedKeyIndex(in: keys)
    var key = try #require(keys[keyIndex].objectValue)
    key["revoked_at"] = .string("june")
    keys[keyIndex] = .object(key)
    root["keys"] = .array(keys)

    // Reject malformed revocation timestamps rather than retaining withdrawn keys.
    #expect(throws: ReleaseTrustError.self) {
        _ = try ReleaseTrustRoot.parse(try JSONValue.object(root).canonicalBytes())
    }
}

@Test func oneKeyIDMayNotAppearTwice() throws {
    var root = try #require(JSONValue.parse(try fixture("release-keys.json")).objectValue)
    let keys = try #require(root["keys"]?.arrayValue)
    root["keys"] = .array(keys + keys)

    #expect(throws: ReleaseTrustError.duplicateKeyID("spark-release-dev-2026a")) {
        _ = try ReleaseTrustRoot.parse(try JSONValue.object(root).canonicalBytes())
    }
}

@Test func aCatalogueKeyMayNotSignARelease() throws {
    var root = try #require(JSONValue.parse(try fixture("release-keys.json")).objectValue)
    var keys = try #require(root["keys"]?.arrayValue)
    let keyIndex = try shippedKeyIndex(in: keys)
    var key = try #require(keys[keyIndex].objectValue)
    key["purposes"] = .array([.string(ReleaseTrustRoot.cataloguePurpose)])
    keys[keyIndex] = .object(key)
    root["keys"] = .array(keys)

    let scoped = try ReleaseTrustRoot.parse(try JSONValue.object(root).canonicalBytes())
    #expect(throws: ReleaseTrustError.self) {
        _ = try scoped.verify(manifest: shippedManifest(), at: insideWindow)
    }
}

@Test func aDirectTrustRootMayNotVouchForAProductionChannel() throws {
    // Reject a widened stable-channel grant from a schema-1 trust root even when its signature verifies.
    var root = try #require(JSONValue.parse(try fixture("release-keys.json")).objectValue)
    var keys = try #require(root["keys"]?.arrayValue)
    let keyIndex = try shippedKeyIndex(in: keys)
    var key = try #require(keys[keyIndex].objectValue)
    key["channels"] = .array([.string("stable")])
    keys[keyIndex] = .object(key)
    root["keys"] = .array(keys)
    let widened = try ReleaseTrustRoot.parse(try JSONValue.object(root).canonicalBytes())

    var manifest = try #require(JSONValue.parse(try shippedManifest()).objectValue)
    manifest["channel"] = .string("stable")
    let stable = try JSONValue.object(manifest).canonicalBytes()

    // Reject the wrong release channel before performing signature verification.
    #expect(throws: ReleaseTrustError.delegationRequired("stable")) {
        _ = try widened.verify(manifest: stable, at: insideWindow)
    }
}

@Test func aTrustRootWithNoKeysOrAFutureSchemaIsRefused() throws {
    let empty = try JSONValue.object(["schema": .integer(1), "keys": .array([])]).canonicalBytes()
    #expect(throws: ReleaseTrustError.empty) { _ = try ReleaseTrustRoot.parse(empty) }

    let future = try JSONValue.object(["schema": .integer(99), "keys": .array([])]).canonicalBytes()
    #expect(throws: ReleaseTrustError.unsupportedSchema(99)) {
        _ = try ReleaseTrustRoot.parse(future)
    }
}

@Test func aManifestWithAnUnknownMemberIsRefused() throws {
    var members = try #require(JSONValue.parse(try shippedManifest()).objectValue)
    members["surprise"] = .integer(1)
    let extended = try JSONValue.object(members).canonicalBytes()
    #expect(throws: ReleaseTrustError.manifest(.unexpectedField("surprise"))) {
        _ = try trustRoot().verify(manifest: extended, at: insideWindow)
    }
}

@Test func aManifestOfferingAPlaintextURLIsRefused() throws {
    let plaintext = try manifestReplacingArtifactMember(
        "url",
        with: "http://tampered.invalid/spark-runtime.deb"
    )
    #expect(throws: ReleaseTrustError.self) {
        _ = try trustRoot().verify(manifest: plaintext, at: insideWindow)
    }
}

@Test func aCosignManifestIsRefusedRatherThanSkipped() throws {
    // Reject signature algorithms this verifier does not implement.
    var members = try #require(JSONValue.parse(try shippedManifest()).objectValue)
    var signature = try #require(members["signature"]?.objectValue)
    signature["algorithm"] = .string("cosign")
    members["signature"] = .object(signature)
    let cosigned = try JSONValue.object(members).canonicalBytes()

    #expect(throws: ReleaseTrustError.manifest(.unsupportedAlgorithm("cosign"))) {
        _ = try trustRoot().verify(manifest: cosigned, at: insideWindow)
    }
}

@Test func detachedSignaturesAreVerifiedAgainstTheSameKeyPolicy() throws {
    let root = try trustRoot()
    // A signature that is not 64 bytes never reaches the curve.
    #expect(throws: ReleaseTrustError.signatureInvalid("spark-release-dev-2026a")) {
        try root.verifyDetached(
            keyID: "spark-release-dev-2026a",
            payload: Data("package".utf8),
            signature: Data(repeating: 0, count: 10),
            at: insideWindow,
            channel: "dev"
        )
    }
    // And an unknown key is refused before anything else.
    #expect(throws: ReleaseTrustError.unknownKeyID("nobody")) {
        try root.verifyDetached(
            keyID: "nobody",
            payload: Data("package".utf8),
            signature: Data(repeating: 0, count: 64),
            at: insideWindow,
            channel: "dev"
        )
    }
}

@Test func rfc3339ParsingIsStrict() {
    #expect(RFC3339.date(from: "2026-08-27T00:00:00Z") != nil)
    #expect(RFC3339.date(from: "2026-08-27t00:00:00z") != nil)
    #expect(RFC3339.date(from: "2026-08-27T00:00:00.500Z") != nil)
    #expect(RFC3339.date(from: "2026-08-27T01:00:00+01:00") != nil)

    // An offset is mandatory: a signing window must not be ambiguous.
    #expect(RFC3339.date(from: "2026-08-27T00:00:00") == nil)
    #expect(RFC3339.date(from: "2026-08-27 00:00:00Z") == nil)
    #expect(RFC3339.date(from: "26-08-27T00:00:00Z") == nil)
    #expect(RFC3339.date(from: "2026-02-31T00:00:00Z") == nil)
    #expect(RFC3339.date(from: "2026-13-01T00:00:00Z") == nil)
    #expect(RFC3339.date(from: "2026-08-27T25:00:00Z") == nil)
    #expect(RFC3339.date(from: "") == nil)
    #expect(RFC3339.date(from: "2026-08-27T00:00:00Zzz") == nil)

    let parsed = try? #require(RFC3339.date(from: "2026-08-27T01:00:00+01:00"))
    #expect(parsed == RFC3339.date(from: "2026-08-27T00:00:00Z"))
}
