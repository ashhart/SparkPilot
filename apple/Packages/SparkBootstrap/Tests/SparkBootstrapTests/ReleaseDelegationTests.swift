import Foundation
import Testing
import SparkSecurity

@testable import SparkBootstrap

private func delegationFixture() throws -> [String: JSONValue] {
    let url = try #require(
        Bundle.module.url(forResource: "Fixtures/release-delegation.json", withExtension: nil)
    )
    return try #require(JSONValue.parse(Data(contentsOf: url)).objectValue)
}

@Test func offlineDelegationVerifiesProductionManifestAndPackage() throws {
    let fixture = try delegationFixture()
    let root = try ReleaseTrustRoot.parse(try #require(fixture["trust"]).canonicalBytes())
    let dateText = try #require(fixture["at"]?.stringValue)
    let moment = try #require(RFC3339.date(from: dateText))
    let verified = try root.verify(
        manifest: #require(fixture["manifest"]).canonicalBytes(),
        at: moment
    )
    let signatureText = try #require(fixture["package_signature"]?.stringValue)
    let signature = try #require(Base64URL.decode(signatureText))
    try root.verifyDetached(
        keyID: verified.keyID,
        payload: Data(#require(fixture["package"]?.stringValue).utf8),
        signature: signature,
        at: moment,
        channel: "stable"
    )
}

@Test func offlineDelegationRejectsUnsignedKeyChanges() throws {
    let fixture = try delegationFixture()
    var trust = try #require(fixture["trust"]?.objectValue)
    var keys = try #require(trust["keys"]?.arrayValue)
    var key = try #require(keys[0].objectValue)
    key["not_after"] = .string("2028-01-01T00:00:00Z")
    keys[0] = .object(key)
    trust["keys"] = .array(keys)
    #expect(throws: ReleaseTrustError.self) {
        _ = try ReleaseTrustRoot.parse(JSONValue.object(trust).canonicalBytes())
    }
}

@Test func offlineDelegationMatchesSharedAdversarialCases() throws {
    let fixture = try delegationFixture()
    let cases = try #require(fixture["cases"]?.arrayValue)
    let payload = try #require(fixture["package"]?.stringValue)
    let signatureText = try #require(fixture["package_signature"]?.stringValue)
    let signature = try #require(Base64URL.decode(signatureText))
    for entry in cases {
        let fields = try #require(entry.objectValue)
        let name = try #require(fields["name"]?.stringValue)
        let date = try #require(fields["at"]?.stringValue)
        let moment = try #require(RFC3339.date(from: date))
        let document = try #require(fields["trust"])
        let manifest = try #require(fields["manifest"])
        let root = try? ReleaseTrustRoot.parse(document.canonicalBytes())
        let verified = try? root?.verify(manifest: manifest.canonicalBytes(), at: moment)
        #expect((verified != nil) == (fields["accept_manifest"] == .bool(true)), "\(name)")
        if let verified, let root {
            var packageOK = false
            do {
                try root.verifyDetached(
                    keyID: verified.keyID,
                    payload: Data(payload.utf8),
                    signature: signature,
                    at: moment,
                    channel: verified.manifest.channel
                )
                packageOK = true
            } catch {}
            #expect(packageOK == (fields["accept_package"] == .bool(true)), "\(name)")
        }
    }
}
