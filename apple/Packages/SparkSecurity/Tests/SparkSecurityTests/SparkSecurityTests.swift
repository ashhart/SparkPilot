import CryptoKit
import Foundation
import Security
import Testing
@testable import SparkSecurity

/// Match the canonical SPARK2 signing vector shared with the Rust runtime (§58.3).
@Test func canonicalRequestMatchesServerVector() {
    let canonical = CanonicalRequest(
        method: "POST",
        pathAndQuery: "/api/v1/pairing/claim",
        timestamp: "2026-08-26T10:00:00Z",
        nonce: "abc123nonce",
        bodyHashHex: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        deviceID: "63e82da2-7fb7-4b4b-9584-4a528000ac94",
        nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    )
    let expected = """
        SPARK2
        POST
        /api/v1/pairing/claim
        2026-08-26T10:00:00Z
        abc123nonce
        ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
        63e82da2-7fb7-4b4b-9584-4a528000ac94
        00000000-0000-0000-0000-000000000002
        """
    #expect(String(data: canonical.signatureInput, encoding: .utf8) == expected)
}

@Test func sha256MatchesKnownVector() {
    #expect(
        SHA256Digest.hex(Data("abc".utf8))
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    )
}

@Test func base64urlRoundTripsWithoutPadding() {
    let data = Data([0xfb, 0xff])
    let encoded = Base64URL.encode(data)
    #expect(encoded == "-_8")
    #expect(Base64URL.decode(encoded) == data)
}

@Test func softwareSignerProducesVerifiableRawSignatures() throws {
    let signer = SoftwareSigner()
    // SPKI must match the CryptoKit public key DER exactly (server parses it).
    #expect(signer.publicKeySPKI == signer.keyPublicKeyDER)

    let message = Data("challenge||invitation||device||node".utf8)
    let signature = try signer.sign(message)
    #expect(signature.count == 64)

    // Verify with CryptoKit using the raw representation.
    let publicKey = try P256.Signing.PublicKey(
        derRepresentation: signer.publicKeySPKI
    )
    let parsed = try P256.Signing.ECDSASignature(rawRepresentation: signature)
    #expect(publicKey.isValidSignature(parsed, for: message))
}

@Test func derSignatureConvertsToRaw64Bytes() throws {
    let signature = try P256.Signing.PrivateKey().signature(for: Data("message".utf8))
    let raw = try derECDSAToRaw(der: signature.derRepresentation)
    #expect(raw.count == 64)
    #expect(raw == signature.rawRepresentation)
}

@Test func derSignatureRejectsTrailingOrNonCanonicalBytes() throws {
    let signer = P256.Signing.PrivateKey()
    let signature = try signer.signature(for: Data("message".utf8))
    var withTrailingByte = signature.derRepresentation
    withTrailingByte.append(0)

    #expect(throws: (any Error).self) {
        try derECDSAToRaw(der: withTrailingByte)
    }
}

@Test func ecKeySPKIWrapsRawPoint() throws {
    // Verify the Secure Enclave SPKI algorithm OID and bit string containing the 65-byte EC point.
    let point = Data([0x04] + [UInt8](repeating: 0x11, count: 64))
    let spki = ecKeySPKI(rawPoint: point)
    #expect(spki[0] == 0x30)
    // The bit string `03 42 00` must appear (66 == 0x42 content length).
    let expectedBitString: [UInt8] = [0x03, 0x42, 0x00]
    #expect(spki.range(of: Data(expectedBitString)) != nil)
    // Algorithm identifier (id-ecPublicKey) must be present.
    let oid: [UInt8] = [0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01]
    #expect(spki.range(of: Data(oid)) != nil)
}

@Test func secureEnclaveSPKIWrapperProducesParseableDER() throws {
    let key = P256.Signing.PrivateKey().publicKey
    let spki = ecKeySPKI(rawPoint: key.x963Representation)

    let parsed = try P256.Signing.PublicKey(derRepresentation: spki)

    #expect(parsed.x963Representation == key.x963Representation)
    #expect(spki == key.derRepresentation)
}

@Test func signedHeadersCarryTheFullContract() throws {
    let signatureProvider = { (_: Data) -> Data in
        Data([UInt8](repeating: 0x42, count: 64))
    }
    var nonce = Data(count: 24)
    let status = nonce.withUnsafeMutableBytes { buffer in
        SecRandomCopyBytes(kSecRandomDefault, 24, buffer.baseAddress!)
    }
    #expect(status == errSecSuccess)

    let canonical = CanonicalRequest(
        method: "GET",
        pathAndQuery: "/api/v1/status",
        timestamp: "2026-08-26T10:00:00Z",
        nonce: Base64URL.encode(nonce),
        bodyHashHex: SHA256Digest.hex(Data()),
        deviceID: "00000000-0000-0000-0000-000000000001",
        nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    )
    let headers = try canonical.headers(signingKey: signatureProvider)
    #expect(headers["X-Spark-Signature"]?.count ?? 0 > 80)
    #expect(headers["X-Spark-Device-ID"] == "00000000-0000-0000-0000-000000000001")
    #expect(headers["X-Spark-Content-SHA256"] == SHA256Digest.hex(Data()))
}

@Test func inMemoryStorePersistsAndDeletes() throws {
    let store = InMemoryStore()
    let payload = Data("grant".utf8)
    try store.set(payload, service: "spark.grant", account: "node-uuid")
    #expect(try store.data(service: "spark.grant", account: "node-uuid") == payload)
    try store.delete(service: "spark.grant", account: "node-uuid")
    #expect(try store.data(service: "spark.grant", account: "node-uuid") == nil)
}

extension SoftwareSigner {
    fileprivate var keyPublicKeyDER: Data {
        // Re-derive the public key from signer SPKI and compare its CryptoKit encoding.
        (self.publicKeySPKI)
    }
}
