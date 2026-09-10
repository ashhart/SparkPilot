import CryptoKit
import Foundation
import Testing
@testable import SparkSecurity

private let presenceTimestamp = "2026-08-28T14:00:00Z"
private let presenceExpiry = "2026-08-28T14:01:00Z"
private let presenceDeviceID = "63e82da2-7fb7-4b4b-9584-4a528000ac94"

private final class SecurityTestPresenceSigner: UserPresenceProofSigning, @unchecked Sendable {
    private let signer: SoftwareSigner
    let keyInfo: UserPresenceKeyInfo

    init() {
        let signer = SoftwareSigner()
        self.signer = signer
        self.keyInfo = UserPresenceKeyInfo(
            publicKeySPKI: signer.publicKeySPKI,
            protection: .softwareTestOnly
        )
    }

    func proof(for request: UserPresenceCanonicalRequest) async throws -> UserPresenceProof {
        try UserPresenceProof.sign(request) { try signer.sign($0) }
    }

    func signPairingBinding(_ binding: PairingPresenceBinding) async throws -> Data {
        try signer.sign(binding.signatureInput)
    }

    func signPresenceKeyEnrollment(
        _ binding: PresenceKeyEnrollmentBinding
    ) async throws -> Data {
        try signer.sign(binding.signatureInput)
    }
}

private func presenceCanonical(
    method: String = "DELETE",
    pathAndQuery: String = "/api/v1/devices/tablet?audit=full"
) throws -> UserPresenceCanonicalRequest {
    try UserPresenceCanonicalRequest(
        method: method,
        pathAndQuery: pathAndQuery,
        timestamp: presenceTimestamp,
        nonce: "fresh-spark1-nonce",
        bodyHashHex: SHA256Digest.hex(Data()),
        deviceID: presenceDeviceID,
        expiresAt: presenceExpiry,
        nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    )
}

@Test func userPresenceCanonicalBytesMatchTheRuntimeContract() throws {
    let canonical = try presenceCanonical()

    #expect(
        String(decoding: canonical.signatureInput, as: UTF8.self)
            == """
            SPARK-PRESENCE2
            DELETE
            /api/v1/devices/tablet?audit=full
            2026-08-28T14:00:00Z
            fresh-spark1-nonce
            e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
            63e82da2-7fb7-4b4b-9584-4a528000ac94
            2026-08-28T14:01:00Z
            00000000-0000-0000-0000-000000000002
            """
    )
}

@Test func userPresenceProofIsVersionedAndTamperResistant() throws {
    let signer = SoftwareSigner()
    let canonical = try presenceCanonical()
    let proof = try UserPresenceProof.sign(canonical) { data in
        try signer.sign(data)
    }
    let decoded = try UserPresenceProof(headerValue: proof.headerValue())

    #expect(decoded.version == 2)
    #expect(decoded.expiresAt == presenceExpiry)
    #expect(try decoded.headerValue() != "true")
    #expect(try decoded.headerValue() != "verified")

    let publicKey = try P256.Signing.PublicKey(derRepresentation: signer.publicKeySPKI)
    let signature = try P256.Signing.ECDSASignature(
        rawRepresentation: try #require(Base64URL.decode(decoded.signature))
    )
    #expect(publicKey.isValidSignature(signature, for: canonical.signatureInput))
    #expect(
        !publicKey.isValidSignature(
            signature,
            for: try presenceCanonical(pathAndQuery: "/api/v1/devices/owner").signatureInput
        )
    )
    #expect(
        !publicKey.isValidSignature(
            signature,
            for: try presenceCanonical(method: "POST").signatureInput
        )
    )
}

@Test func userPresenceExpiryCannotExceedSixtySeconds() {
    #expect(throws: UserPresenceProofError.invalidExpiry) {
        try UserPresenceCanonicalRequest(
            method: "DELETE",
            pathAndQuery: "/api/v1/devices/tablet",
            timestamp: presenceTimestamp,
            nonce: "nonce",
            bodyHashHex: SHA256Digest.hex(Data()),
            deviceID: presenceDeviceID,
            expiresAt: "2026-08-28T14:01:01Z",
            nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )
    }
}

@Test func softwarePresenceKeyReportsThatItIsNotHardwareBacked() throws {
    let signer = SecurityTestPresenceSigner()

    #expect(
        SystemUserPresenceAuthorizer.defaultApplicationTag
            != DeviceKeyFactory.defaultApplicationTag
    )
    #expect(signer.keyInfo.protection == .softwareTestOnly)
    #expect(!signer.keyInfo.isHardwareBacked)
    #expect(!signer.keyInfo.publicKeySPKI.isEmpty)
}

@Test func pairingPresenceCanonicalBytesMatchTheRuntimeFixture() throws {
    let binding = try PairingPresenceBinding(
        challengeBase64URL: "VGVzdCBwYWlyaW5nIGNoYWxsZW5nZQ",
        invitationID: UUID(uuidString: "d0483950-f543-443e-819b-78d06b620186")!,
        deviceID: UUID(uuidString: "e3778301-3007-47f1-86cd-92dc0eaf4dc5")!,
        nodeID: UUID(uuidString: "ca890ed7-7c8c-4b2c-9218-b77ef24f569a")!,
        presenceKeyFingerprint:
            "4e46f39ed679967574f9a3f0476c5337f422bd8e8dbb7ef08ab865513f55c85b"
    )

    #expect(
        String(decoding: binding.signatureInput, as: UTF8.self)
            == """
            SPARK-PAIRING-PRESENCE1
            VGVzdCBwYWlyaW5nIGNoYWxsZW5nZQ
            d0483950-f543-443e-819b-78d06b620186
            e3778301-3007-47f1-86cd-92dc0eaf4dc5
            ca890ed7-7c8c-4b2c-9218-b77ef24f569a
            4e46f39ed679967574f9a3f0476c5337f422bd8e8dbb7ef08ab865513f55c85b
            """
    )
}

@Test func presenceEnrollmentCanonicalBytesMatchTheRuntimeFixture() throws {
    let binding = try PresenceKeyEnrollmentBinding(
        method: "post",
        pathAndQuery: "/api/v1/devices/self/presence-key",
        timestamp: "2026-08-28T16:45:00Z",
        nonce: "NDU2Nzg5MDEyMzQ1Njc4OTA",
        contentSHA256:
            "fcb5f40df9be6d3081f1f50d7de6fb0f5f277f37675360c3054c55ed9796c292",
        deviceID: UUID(uuidString: "e3778301-3007-47f1-86cd-92dc0eaf4dc5")!,
        presenceKeyFingerprint:
            "4e46f39ed679967574f9a3f0476c5337f422bd8e8dbb7ef08ab865513f55c85b",
        nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    )

    #expect(
        String(decoding: binding.signatureInput, as: UTF8.self)
            == """
            SPARK-PRESENCE-ENROLL2
            POST
            /api/v1/devices/self/presence-key
            2026-08-28T16:45:00Z
            NDU2Nzg5MDEyMzQ1Njc4OTA
            fcb5f40df9be6d3081f1f50d7de6fb0f5f277f37675360c3054c55ed9796c292
            e3778301-3007-47f1-86cd-92dc0eaf4dc5
            4e46f39ed679967574f9a3f0476c5337f422bd8e8dbb7ef08ab865513f55c85b
            00000000-0000-0000-0000-000000000002
            """
    )
}

@Test func pairingFingerprintHashesTheCanonicalUncompressedPoint() throws {
    let privateKey = P256.Signing.PrivateKey()
    let info = UserPresenceKeyInfo(
        publicKeySPKI: privateKey.publicKey.derRepresentation,
        protection: .softwareTestOnly
    )
    let expected = SHA256.hash(data: privateKey.publicKey.x963Representation)
        .map { String(format: "%02x", $0) }
        .joined()

    #expect(try info.pairingFingerprint() == expected)
    #expect(privateKey.publicKey.x963Representation.count == 65)
    #expect(privateKey.publicKey.x963Representation.first == 0x04)
}

@Test func pairingClaimPresenceFieldsRoundTripTogether() throws {
    let invitation = PairingInvitation(
        version: 1,
        nodeID: "ca890ed7-7c8c-4b2c-9218-b77ef24f569a",
        authorityFingerprint: String(repeating: "a", count: 64),
        invitationID: "d0483950-f543-443e-819b-78d06b620186",
        nonce: "nonce",
        role: "owner",
        expiresAt: "2026-08-28T15:00:00Z"
    )
    let request = PairingClaimRequest(
        invitation: invitation,
        challengeID: "6f1a2e6a-6a1e-4a54-9b62-1b2f0e3a5c77",
        deviceID: "e3778301-3007-47f1-86cd-92dc0eaf4dc5",
        deviceName: "Owner iPhone",
        platform: "ios",
        devicePublicKeySPKI: "device-spki",
        presencePublicKeySPKI: "presence-spki",
        challengeSignature: "device-signature",
        presenceKeySignature: "presence-signature"
    )
    let object = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
    )

    #expect(object["presence_public_key_spki"] as? String == "presence-spki")
    #expect(object["presence_key_signature"] as? String == "presence-signature")

    let response = try JSONDecoder().decode(
        PairingClaimResponse.self,
        from: Data(
            """
            {"device":{"id":"e3778301-3007-47f1-86cd-92dc0eaf4dc5","display_name":"Owner iPhone","platform":"ios","role":"owner"},"authority_certificate":"certificate","issued_at":"2026-08-28T15:00:00Z","presence_key_fingerprint":"4e46f39ed679967574f9a3f0476c5337f422bd8e8dbb7ef08ab865513f55c85b"}
            """.utf8
        )
    )
    #expect(
        response.presenceKeyFingerprint
            == "4e46f39ed679967574f9a3f0476c5337f422bd8e8dbb7ef08ab865513f55c85b"
    )
}

@Test func approvedPresenceSessionIsAtomicallySingleUse() async throws {
    let signer = SoftwareSigner()
    let session = UserPresenceSigningSession(
        keyInfo: UserPresenceKeyInfo(
            publicKeySPKI: signer.publicKeySPKI,
            protection: .softwareTestOnly
        ),
        signing: { try signer.sign($0) }
    )
    let request = try presenceCanonical()
    let first = Task { try await session.proof(for: request) }
    let second = Task { try await session.proof(for: request) }
    var successCount = 0
    var consumedCount = 0
    for task in [first, second] {
        do {
            _ = try await task.value
            successCount += 1
        } catch UserPresenceProofError.sessionConsumed {
            consumedCount += 1
        }
    }

    #expect(successCount == 1)
    #expect(consumedCount == 1)
}

@Test func systemPathReportsKeychainPresenceWhenSecureEnclaveIsUnavailable() {
    #expect(
        SystemUserPresenceAuthorizer.preferredProtection(secureEnclaveAvailable: false)
            == .keychainUserPresence
    )
    #expect(
        SystemUserPresenceAuthorizer.preferredProtection(secureEnclaveAvailable: true)
            == .secureEnclaveUserPresence
    )
}

@Test func recipientChangeInvalidatesThePresenceSignature() throws {
    let request = try presenceCanonical()
    let signer = SoftwareSigner()
    let proof = try UserPresenceProof.sign(request) { try signer.sign($0) }
    let other = try UserPresenceCanonicalRequest(
        method: request.method,
        pathAndQuery: request.pathAndQuery,
        timestamp: request.timestamp,
        nonce: request.nonce,
        bodyHashHex: request.bodyHashHex,
        deviceID: request.deviceID,
        expiresAt: request.expiresAt,
        nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    )
    let key = try P256.Signing.PublicKey(derRepresentation: signer.publicKeySPKI)
    let signature = try P256.Signing.ECDSASignature(
        rawRepresentation: #require(Base64URL.decode(proof.signature))
    )
    #expect(key.isValidSignature(signature, for: request.signatureInput))
    #expect(!key.isValidSignature(signature, for: other.signatureInput))
    #expect(throws: UserPresenceProofError.unsupportedVersion) {
        try UserPresenceProof(version: 1, expiresAt: request.expiresAt, signature: proof.signature)
    }
}
