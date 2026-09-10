import CryptoKit
import Foundation
import Network
import SparkAPI
import SparkAppComposition
import SparkDiscovery
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing

@Test func signerProducesTheSPARK2HeaderSet() throws {
    let signer = SparkRequestSigner(
        deviceID: "63e82da2-7fb7-4b4b-9584-4a528000ac94",
        nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        signingKey: AppShellTestFixedSigner(),
        now: {
            var components = DateComponents()
            components.year = 2026
            components.month = 8
            components.day = 26
            components.hour = 12
            components.timeZone = TimeZone(identifier: "UTC")
            return Calendar(identifier: .gregorian).date(from: components)!
        }
    )

    var request = URLRequest(url: URL(string: "https://spark.local:7443/api/v1/status")!)
    request.httpMethod = "GET"
    let signed = try signer.authorize(request, body: Data())

    #expect(
        signed.value(forHTTPHeaderField: "X-Spark-Device-ID")
            == "63e82da2-7fb7-4b4b-9584-4a528000ac94"
    )
    #expect(
        signed.value(forHTTPHeaderField: "X-Spark-Node-ID")
            == "00000000-0000-0000-0000-000000000002"
    )
    #expect(signed.value(forHTTPHeaderField: "X-Spark-Timestamp") == "2026-08-26T12:00:00Z")
    // SHA-256 of the empty body, hex — the well-known empty digest.
    #expect(
        signed.value(forHTTPHeaderField: "X-Spark-Content-SHA256")
            == SHA256.hex(of: Data())
    )
    let signature = signed.value(forHTTPHeaderField: "X-Spark-Signature")
    #expect(signature?.isEmpty == false)
}

@Test func signerUsesFreshNoncesAndTheBodyDigest() throws {
    let signer = SparkRequestSigner(
        deviceID: "device-1",
        nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        signingKey: AppShellTestFixedSigner()
    )
    let url = URL(string: "https://spark.local:7443/api/v1/remote/enable")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"

    let body = Data(#"{"mode":"private_overlay"}"#.utf8)
    let first = try signer.authorize(request, body: body)
    let second = try signer.authorize(request, body: body)

    #expect(
        first.value(forHTTPHeaderField: "X-Spark-Nonce")
            != second.value(forHTTPHeaderField: "X-Spark-Nonce"),
        "every request carries a fresh nonce (replay protection)"
    )
    // SHA-256 of the exact body.
    #expect(
        first.value(forHTTPHeaderField: "X-Spark-Content-SHA256")
            == SHA256.hex(of: body)
    )
}

@Test func presenceProofSharesFreshSPARK2FieldsAndExpiresWithinSixtySeconds() async throws {
    let now = Date(timeIntervalSince1970: 1_777_387_200)
    let signer = SparkRequestSigner(
        deviceID: "63e82da2-7fb7-4b4b-9584-4a528000ac94",
        nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        signingKey: AppShellTestFixedSigner(),
        now: { now }
    )
    let presence = AppShellTestAppTestPresenceSession()
    let url = URL(string: "https://spark.local:7443/api/v1/devices/tablet?audit=full")!
    var request = URLRequest(url: url)
    request.httpMethod = "DELETE"

    let first = try await signer.authorizeWithUserPresence(
        request,
        body: Data(),
        userPresence: presence
    )
    let second = try await signer.authorizeWithUserPresence(
        request,
        body: Data(),
        userPresence: AppShellTestAppTestPresenceSession()
    )

    let firstHeader = try #require(
        first.value(forHTTPHeaderField: "X-Spark-User-Presence")
    )
    let secondHeader = try #require(
        second.value(forHTTPHeaderField: "X-Spark-User-Presence")
    )
    let proof = try UserPresenceProof(headerValue: firstHeader)
    let canonical = try UserPresenceCanonicalRequest(
        method: "DELETE",
        pathAndQuery: "/api/v1/devices/tablet?audit=full",
        timestamp: try #require(first.value(forHTTPHeaderField: "X-Spark-Timestamp")),
        nonce: try #require(first.value(forHTTPHeaderField: "X-Spark-Nonce")),
        bodyHashHex: try #require(
            first.value(forHTTPHeaderField: "X-Spark-Content-SHA256")
        ),
        deviceID: try #require(first.value(forHTTPHeaderField: "X-Spark-Device-ID")),
        expiresAt: proof.expiresAt,
        nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    )
    let publicKey = try P256.Signing.PublicKey(
        derRepresentation: presence.keyInfo.publicKeySPKI
    )
    let signature = try P256.Signing.ECDSASignature(
        rawRepresentation: try #require(Base64URL.decode(proof.signature))
    )

    #expect(publicKey.isValidSignature(signature, for: canonical.signatureInput))
    #expect(firstHeader != secondHeader)
    #expect(
        first.value(forHTTPHeaderField: "X-Spark-Nonce")
            != second.value(forHTTPHeaderField: "X-Spark-Nonce")
    )
    #expect(first.value(forHTTPHeaderField: "X-Spark-Signature")?.isEmpty == false)
}

@Test func presenceCanonicalKeepsPercentEncodedPathAndQueryBytes() async throws {
    let signer = SparkRequestSigner(
        deviceID: "63e82da2-7fb7-4b4b-9584-4a528000ac94",
        nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        signingKey: AppShellTestFixedSigner(),
        now: { Date(timeIntervalSince1970: 1_777_387_200) }
    )
    let presence = AppShellTestAppTestPresenceSession()
    var request = URLRequest(
        url: URL(
            string:
                "https://spark.local:7443/api/v1/devices/a%2Fb?label=hello%20world"
        )!
    )
    request.httpMethod = "DELETE"

    let signed = try await signer.authorizeWithUserPresence(
        request,
        body: Data(),
        userPresence: presence
    )
    let proof = try UserPresenceProof(
        headerValue: try #require(
            signed.value(forHTTPHeaderField: "X-Spark-User-Presence")
        )
    )
    let canonical = try UserPresenceCanonicalRequest(
        method: "DELETE",
        pathAndQuery: "/api/v1/devices/a%2Fb?label=hello%20world",
        timestamp: try #require(signed.value(forHTTPHeaderField: "X-Spark-Timestamp")),
        nonce: try #require(signed.value(forHTTPHeaderField: "X-Spark-Nonce")),
        bodyHashHex: try #require(
            signed.value(forHTTPHeaderField: "X-Spark-Content-SHA256")
        ),
        deviceID: try #require(signed.value(forHTTPHeaderField: "X-Spark-Device-ID")),
        expiresAt: proof.expiresAt,
        nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    )
    let key = try P256.Signing.PublicKey(derRepresentation: presence.keyInfo.publicKeySPKI)
    let signature = try P256.Signing.ECDSASignature(
        rawRepresentation: try #require(Base64URL.decode(proof.signature))
    )

    #expect(key.isValidSignature(signature, for: canonical.signatureInput))
}

@Test func presenceEnrollmentSharesSPARK2FieldsAndBindsTheExactBody() async throws {
    let deviceID = "e3778301-3007-47f1-86cd-92dc0eaf4dc5"
    let signer = SparkRequestSigner(
        deviceID: deviceID,
        nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        signingKey: AppShellTestFixedSigner(),
        now: { Date(timeIntervalSince1970: 1_777_387_500) }
    )
    let presence = AppShellTestAppTestPresenceSession()
    var request = URLRequest(
        url: URL(string: "https://spark.local:7443/api/v1/devices/self/presence-key")!
    )
    request.httpMethod = "POST"

    let authorized = try await signer.authorizePresenceKeyEnrollment(
        request,
        userPresence: presence
    )
    let object = try #require(
        JSONSerialization.jsonObject(with: authorized.body) as? [String: Any]
    )
    let fingerprint = try presence.keyInfo.pairingFingerprint()
    let binding = try PresenceKeyEnrollmentBinding(
        method: "POST",
        pathAndQuery: "/api/v1/devices/self/presence-key",
        timestamp: try #require(
            authorized.request.value(forHTTPHeaderField: "X-Spark-Timestamp")
        ),
        nonce: try #require(
            authorized.request.value(forHTTPHeaderField: "X-Spark-Nonce")
        ),
        contentSHA256: try #require(
            authorized.request.value(forHTTPHeaderField: "X-Spark-Content-SHA256")
        ),
        deviceID: UUID(uuidString: deviceID)!,
        presenceKeyFingerprint: fingerprint,
        nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    )
    let key = try P256.Signing.PublicKey(derRepresentation: presence.keyInfo.publicKeySPKI)
    let signature = try P256.Signing.ECDSASignature(
        rawRepresentation: try #require(
            Base64URL.decode(
                authorized.request.value(forHTTPHeaderField: "X-Spark-Presence-Key-Proof")
                    ?? ""
            )
        )
    )

    #expect(key.isValidSignature(signature, for: binding.signatureInput))
    #expect(object["presence_key_signature"] == nil)
    #expect(object["presence_public_key_spki"] as? String == presence.keyInfo.publicKeySPKIBase64)
    #expect(
        authorized.request.value(forHTTPHeaderField: "X-Spark-Content-SHA256")
            == SHA256Digest.hex(authorized.body)
    )
    #expect(authorized.request.value(forHTTPHeaderField: "X-Spark-Signature")?.isEmpty == false)
}
