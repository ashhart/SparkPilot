import CryptoKit
import Foundation
@_spi(SparkTestSupport) import SparkAPI
import SparkSecurity
@_spi(SparkTestSupport) @_spi(SparkInternal) import SparkTransport
import Testing

@_spi(SparkTestSupport) @testable import SparkBootstrap

/// Exercise challenge, proof, claim and durable trust recording through the stubbed transport boundary.

// MARK: - A node, stubbed at the transport

/// Records what the device sent and answers as the runtime would.
final class PairingCompositionTestStubNode: @unchecked Sendable {
    let authority: Curve25519.Signing.PrivateKey
    let nodeID: String
    var claimStatus: Int = 201
    /// Override grant fields to test responses that do not describe the claiming device.
    var grantDeviceID: String?
    var grantRole = "owner"
    var grantAuthorityCertificate: Data?
    var corruptPresenceFingerprint = false
    var issuedAt = "2026-08-27T10:00:00Z"

    private(set) var paths: [String] = []
    private(set) var claimBody: [String: Any] = [:]
    private(set) var challengeBody: [String: Any] = [:]
    private var issuedChallenge = Data([0x11, 0x22, 0x33, 0x44])
    private let challengeID = "6f1a2e6a-6a1e-4a54-9b62-1b2f0e3a5c77"

    init(authority: Curve25519.Signing.PrivateKey, nodeID: String) {
        self.authority = authority
        self.nodeID = nodeID
    }

    func respond(to request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        paths.append(path)
        let body = request.httpBody ?? Data()
        let members = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]

        switch path {
        case "/api/v1/pairing/challenge":
            challengeBody = members
            let expiresAt = "2026-08-27T10:05:00Z"
            let challenge = Base64URL.encode(issuedChallenge)
            let fingerprint = SHA256Hex.of(authority.publicKey.rawRepresentation)
            let canonical = [challengeID, challenge, expiresAt, fingerprint]
                .joined(separator: "\n")
            let signature = try authority.signature(for: Data(canonical.utf8))
            return try reply(
                status: 200,
                json: [
                    "challenge_id": challengeID,
                    "challenge": challenge,
                    "expires_at": expiresAt,
                    "authority_fingerprint": fingerprint,
                    "signature": Base64URL.encode(signature),
                ]
            )

        case "/api/v1/pairing/claim":
            claimBody = members
            guard claimStatus == 201 else {
                return try reply(status: claimStatus, json: ["detail": "refused"])
            }
            let certificate =
                grantAuthorityCertificate ?? authority.publicKey.rawRepresentation
            var response: [String: Any] = [
                "device": [
                    "id": grantDeviceID ?? (members["device_id"] as? String ?? ""),
                    "display_name": members["device_name"] as? String ?? "",
                    "platform": members["platform"] as? String ?? "",
                    "role": grantRole,
                ],
                "authority_certificate": certificate.base64EncodedString(),
                "issued_at": issuedAt,
            ]
            if let encoded = members["presence_public_key_spki"] as? String,
                let spki = Data(base64Encoded: encoded),
                let key = try? P256.Signing.PublicKey(derRepresentation: spki)
            {
                response["presence_key_fingerprint"] =
                    corruptPresenceFingerprint
                    ? String(repeating: "0", count: 64)
                    : SHA256Hex.of(key.x963Representation)
            }
            return try reply(
                status: 201,
                json: response
            )

        default:
            return try reply(status: 404, json: ["detail": "no such route"])
        }
    }

    /// Retain the issued challenge for assertions about the exact device-signed bytes.
    var challengeBytes: Data { issuedChallenge }
    var challengeIdentifier: String { challengeID }

    private func reply(status: Int, json: [String: Any]) throws -> (Data, HTTPURLResponse) {
        let data = try JSONSerialization.data(withJSONObject: json)
        let response = HTTPURLResponse(
            url: URL(string: "https://spark.local:7443")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (data, response)
    }
}

/// Drive pairing through a closure-backed pinned transport without network access.
struct StubPinnedTransport: PinnedHTTPTransport {
    let pin: String
    let handler: @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)

    init(
        pin: String,
        handler: @escaping @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)
    ) {
        self.pin = pin
        self.handler = handler
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try handler(request)
    }
}

// MARK: - Harness

struct PairingCompositionTestScenario {
    let bootstrap: RuntimeBootstrapResult
    let node: PairingCompositionTestStubNode
    let store: NodeTrustStore
    let backing: InMemoryStore
    let signer: SoftwareSigner
    let deviceID = UUID(uuidString: "8ADF6E19-1E1F-4A2C-9A62-4B3E9E2E0C11")!
    var deviceIdentifier: String { deviceID.uuidString.lowercased() }
}

final class PairingCompositionTestPairingPresenceSession: UserPresenceProofSigning,
    @unchecked Sendable
{
    private let signer: SoftwareSigner
    let keyInfo: UserPresenceKeyInfo

    init(signer: SoftwareSigner) {
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
}

actor PairingCompositionTestPairingPresenceAuthorizer: UserPresenceAuthorizing {
    enum Outcome {
        case approve
        case decline
        case unavailable
    }

    private let signer = SoftwareSigner()
    private let outcome: Outcome
    private(set) var authorizationCount = 0

    init(outcome: Outcome = .approve) {
        self.outcome = outcome
    }

    func keyInfo() async throws -> UserPresenceKeyInfo {
        UserPresenceKeyInfo(
            publicKeySPKI: signer.publicKeySPKI,
            protection: .softwareTestOnly
        )
    }

    func authorize(localizedReason: String) async throws -> any UserPresenceProofSigning {
        authorizationCount += 1
        switch outcome {
        case .approve:
            return PairingCompositionTestPairingPresenceSession(signer: signer)
        case .decline:
            throw UserPresenceAuthorizationError.declined
        case .unavailable:
            throw UserPresenceAuthorizationError.unavailable
        }
    }
}

let pairingCompositionTestRoute = URL(string: "https://spark.local:7443")!

let pairingCompositionTestNodePin = String(repeating: "c", count: 64)

let pairingCompositionTestDeviceKeyTag = Data("app.spark.device-key".utf8)

func makePairingCompositionScenario(
    expiresAt: String = "2099-01-01T00:00:00Z",
    role: String = "owner"
) throws -> PairingCompositionTestScenario {
    let authority = Curve25519.Signing.PrivateKey()
    let nodeID = "ca890ed7-7c8c-4b2c-9218-b77ef24f569a"
    let fingerprint = SHA256Hex.of(authority.publicKey.rawRepresentation)
    var members: [String: JSONValue] = [
        "version": .integer(1),
        "node_id": .string(nodeID),
        "authority_fingerprint": .string(fingerprint),
        "invitation_id": .string("d0483950-f543-443e-819b-78d06b620186"),
        "nonce": .string("_gauBKJ2S7qD4YEg3YXkJLJ9pVCy4rc-PV4yJSGP3_Q"),
        "role": .string(role),
        "expires_at": .string(expiresAt),
        "signature": .string(String(repeating: "A", count: 86)),
    ]
    let unsigned = try PairingInvitationPayload(json: .object(members))
    members["signature"] = .string(
        Base64URL.encode(try authority.signature(for: unsigned.canonicalBytes))
    )

    let backing = InMemoryStore()
    return PairingCompositionTestScenario(
        bootstrap: RuntimeBootstrapResult(
            nodeID: nodeID,
            nodeName: "Spark",
            authorityFingerprint: fingerprint,
            authorityPublicKey: authority.publicKey.rawRepresentation.hexString,
            tlsFingerprint: pairingCompositionTestNodePin,
            invitationExpiresAt: expiresAt,
            invitation: .object(members),
            trustRootSource: .supplied
        ),
        node: PairingCompositionTestStubNode(authority: authority, nodeID: nodeID),
        store: NodeTrustStore(store: backing),
        backing: backing,
        signer: try SoftwareSigner(
            applicationTag: pairingCompositionTestDeviceKeyTag,
            store: backing
        )
    )
}

func pairingCompositionTestPairing(
    _ scenario: PairingCompositionTestScenario,
    pinOverride: String? = nil,
    userPresenceAuthorizer: (any UserPresenceAuthorizing)? = nil
) -> FirstOwnerPairing {
    let node = scenario.node
    return FirstOwnerPairing(
        signer: scenario.signer,
        deviceID: scenario.deviceID,
        deviceName: "Owner iPhone",
        platform: "ios",
        testUserPresenceAuthorizer: userPresenceAuthorizer,
        trustStore: scenario.store,
        testTransportFactory: { pin in
            StubPinnedTransport(pin: pinOverride ?? pin) { try node.respond(to: $0) }
        },
        now: { Date(timeIntervalSince1970: 1_787_000_000) }
    )
}
