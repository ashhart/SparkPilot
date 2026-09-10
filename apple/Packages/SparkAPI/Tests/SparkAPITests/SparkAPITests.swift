import CryptoKit
import Foundation
import SparkCore
import SparkSecurity
@_spi(SparkTestSupport) @_spi(SparkInternal) import SparkTransport
import Testing
@_spi(SparkTestSupport) @testable import SparkAPI

struct RefusedCertificateTransport: PinnedHTTPTransport {
    let pin: String
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw PinnedTransportError.certificateRejected(host: request.url?.host ?? "")
    }
}

final class APIUserPresenceSession: UserPresenceProofSigning, @unchecked Sendable {
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

    func signPresenceKeyEnrollment(
        _ binding: PresenceKeyEnrollmentBinding
    ) async throws -> Data {
        try signer.sign(binding.signatureInput)
    }
}

struct APIUserPresenceSigner: UserPresenceRequestSigning {
    func authorize(_ request: URLRequest, body: Data) throws -> URLRequest {
        var signed = request
        signed.setValue("normal-signature", forHTTPHeaderField: "X-Spark-Signature")
        return signed
    }

    func authorizeWithUserPresence(
        _ request: URLRequest,
        body: Data,
        userPresence: any UserPresenceProofSigning
    ) async throws -> URLRequest {
        let canonical = try UserPresenceCanonicalRequest(
            method: request.httpMethod ?? "GET",
            pathAndQuery: request.url?.path ?? "/",
            timestamp: "2026-08-28T14:00:00Z",
            nonce: "api-test-nonce",
            bodyHashHex: SHA256Digest.hex(body),
            deviceID: "63e82da2-7fb7-4b4b-9584-4a528000ac94",
            expiresAt: "2026-08-28T14:01:00Z",
            nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )
        let proof = try await userPresence.proof(for: canonical)
        var signed = request
        signed.setValue(try proof.headerValue(), forHTTPHeaderField: "X-Spark-User-Presence")
        signed.setValue("normal-signature", forHTTPHeaderField: "X-Spark-Signature")
        return signed
    }

    func authorizePresenceKeyEnrollment(
        _ request: URLRequest,
        userPresence: any UserPresenceProofSigning
    ) async throws -> PresenceKeyEnrollmentAuthorization {
        let fingerprint = try userPresence.keyInfo.pairingFingerprint()
        let body = try JSONSerialization.data(
            withJSONObject: [
                "presence_public_key_spki": userPresence.keyInfo.publicKeySPKIBase64
            ],
            options: [.sortedKeys]
        )
        let binding = try PresenceKeyEnrollmentBinding(
            method: "POST",
            pathAndQuery: "/api/v1/devices/self/presence-key",
            timestamp: "2026-08-28T16:45:00Z",
            nonce: "api-enrollment-nonce",
            contentSHA256: SHA256Digest.hex(body),
            deviceID: UUID(uuidString: "e3778301-3007-47f1-86cd-92dc0eaf4dc5")!,
            presenceKeyFingerprint: fingerprint,
            nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )
        let signature = try await userPresence.signPresenceKeyEnrollment(binding)
        var signed = request
        signed.setValue("normal-signature", forHTTPHeaderField: "X-Spark-Signature")
        signed.setValue(
            Base64URL.encode(signature),
            forHTTPHeaderField: "X-Spark-Presence-Key-Proof"
        )
        return PresenceKeyEnrollmentAuthorization(request: signed, body: body)
    }
}

/// The URLProtocol fixture has shared state, so this suite must remain serialized.
@Suite(.serialized)
struct SparkAPITests {
    enum StubError: Error {
        case http(Int)
        /// Foundation surfaces a delegate-cancelled authentication challenge as request cancellation.
    }

    /// One-shot URLProtocol stub that serves canned JSON per path.
    final class MockURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var responses: [String: Result<Data, StubError>] = [:]
        nonisolated(unsafe) static var requestsMade: [String] = []
        nonisolated(unsafe) static var extraHeaders: [String: [String: String]] = [:]
        nonisolated(unsafe) static var lastRequest: URLRequest?
        nonisolated(unsafe) static var lastBody: Data?
        nonisolated(unsafe) static var statusCodes: [String: Int] = [:]

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lastRequest = request
            Self.lastBody = request.httpBody ?? request.httpBodyStream.flatMap(Self.read)
            let path = request.url?.path ?? ""
            Self.requestsMade.append(path)
            switch Self.responses[path] {
            case .success(let data):
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: Self.statusCodes[path] ?? 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"].merging(
                        Self.extraHeaders[path] ?? [:],
                        uniquingKeysWith: { _, rhs in rhs }
                    )
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            case .failure(.http(let code)):
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: code,
                    httpVersion: nil,
                    headerFields: nil
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            case nil:
                client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            }
        }

        override func stopLoading() {}

        private static func read(_ stream: InputStream) -> Data {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(buffer, count: count)
            }
            return data
        }
    }

    /// The pre-TLS mock verifies probe pin wiring while SparkTransport tests exercise actual certificate enforcement.
    static let testPin = String(repeating: "a", count: 64)

    func makeClient(signer: (any RequestSigning)? = nil) throws -> SparkAPIClient {
        return SparkAPIClient(
            transport: try URLSessionPinnedTransport(
                pin: Self.testPin,
                interceptingWith: [MockURLProtocol.self]
            ),
            signer: signer
        )
    }

    func makeProbe() throws -> RouteProbe {
        RouteProbe(pin: Self.testPin, using: try makeClient())
    }

    /// Use the health payload shape served by the runtime.
    let healthFixture = """
        {"api_version":1,"node_id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","auth_protocols":["SPARK2"],"runtime_version":"0.1.0","status":"ok"}
        """

    /// The materialised Appendix B.8 example status document.
    let statusFixture = """
        {
          "api_version": 1,
          "node": {
            "node_id": "7a836150-16e1-46b5-8ac0-32b2a5f2f820",
            "cluster_id": null,
            "name": "Alex's Spark",
            "role": "standalone",
            "authority_fingerprint": "t9lNEpIu94qMhG3XG2ThMg",
            "tls_fingerprint": "a9f2c76194a56b80372c67d874306e4f40d3b0a8c77aeb7314e23422989b3a10",
            "auth_protocols":["SPARK2"],"runtime_version": "0.1.0",
            "dgx_os_version": "REPLACE_WITH_DETECTED_VALUE"
          },
          "cluster": null,
          "connection": {
            "server_observed_transport": "unclassified",
            "access_authentication": "device_signature",
            "remote_access": "disabled"
          },
          "system": {
            "unified_memory_total_bytes": 137438953472,
            "unified_memory_available_bytes": 28743895347,
            "memory_pressure": "normal",
            "cpu_utilisation": 0.18,
            "load_average_1m": 1.2,
            "disk_free_bytes": 91827364512,
            "temperature_celsius": 52,
            "power_state": "normal",
            "uptime_seconds": 123456
          },
          "inference": {
            "state": "ready",
            "model_id": "example/model-32b",
            "profile_id": "balanced-32k",
            "context_length": 32768,
            "active_requests": 1,
            "queue_depth": 0,
            "tokens_per_second": 41.8,
            "time_to_first_token_ms": 284
          },
          "operations": {
            "active": 2,
            "waiting_for_approval": 0,
            "failed_last_24h": 0
          }
        }
        """

    let telemetryFixture = """
        {
          "api_version": 1,
          "observed_at": "2026-08-29T00:15:00Z",
          "node_id": "63e82da2-7fb7-4b4b-9584-4a528000ac94",
          "node_name": "Alex's Spark",
          "system": {
            "cpu_utilisation": 0.27,
            "load_average_1m": 1.4,
            "unified_memory_total_bytes": 137438953472,
            "unified_memory_available_bytes": 68719476736,
            "unified_memory_used_bytes": 68719476736,
            "memory_pressure": "normal",
            "memory_psi_some_avg10": 0.12,
            "memory_psi_full_avg10": 0.02,
            "temperature_celsius": 54,
            "power_state": "normal",
            "uptime_seconds": 120
          },
          "accelerator": {
            "utilisation": 0.64,
            "temperature_celsius": 55,
            "power_draw_watts": 49.5,
            "power_limit_watts": 140,
            "memory_used_bytes": 25769803776,
            "memory_total_bytes": 137438953472
          },
          "storage": {
            "total_bytes": 1000000000000,
            "free_bytes": 400000000000,
            "used_bytes": 600000000000
          },
          "usage": {
            "day": "2026-08-29",
            "requests": 12,
            "failures": 1,
            "prompt_tokens": 500,
            "cached_prompt_tokens": 100,
            "generated_tokens": 250,
            "reasoning_tokens": 50,
            "total_tokens": 800
          },
          "inference": {
            "state": "ready",
            "model_id": "example/model-32b",
            "profile_id": "balanced-32k",
            "context_length": 32768,
            "active_requests": 2,
            "queue_depth": 1,
            "tokens_per_second": 42.5,
            "time_to_first_token_ms": 210
          }
        }
        """

    /// Decode runtime-captured workload inventory so field-name drift fails the test.
    let workloadInventoryFixture = """
        {
          "adoption_supported": false,
          "available": true,
          "observed_at": "2026-08-30T08:57:05.397485Z",
          "truncated": false,
          "workloads": [
            {
              "image_reference": "vllm/vllm-openai@sha256:aa",
              "kind": "inference_engine",
              "name": "spark-model-2b0b0d1e-2b3f-4f7b-9b7a-1c1a4a4a9e11",
              "ownership": "spark_managed",
              "published_ports": [],
              "configuration_state": "not_applicable",
              "api_protocol": null,
              "api_port": null,
              "served_models": [],
              "recognised_engine": "vllm",
              "state": "running",
              "workload_id": "9f2c"
            },
            {
              "image_reference": "lmsysorg/sglang:v0.4.1",
              "kind": "inference_engine",
              "name": "deepseek-serve",
              "ownership": "external_observed",
              "configuration_state": "verified",
              "api_protocol": "openai_compatible",
              "api_port": 30000,
              "served_models": ["deepseek-ai/DeepSeek-R1"],
              "published_ports": [
                {
                  "container_port": 30000,
                  "host_ip": "0.0.0.0",
                  "host_port": 30000,
                  "protocol": "tcp"
                }
              ],
              "recognised_engine": "sglang",
              "state": "running",
              "workload_id": "1a3b"
            },
            {
              "image_reference": "acme/private:1",
              "kind": "unknown",
              "name": "legacy-batch-job",
              "ownership": "unknown_external",
              "published_ports": [],
              "configuration_state": "not_applicable",
              "api_protocol": null,
              "api_port": null,
              "served_models": [],
              "recognised_engine": "none",
              "state": "running",
              "workload_id": "7e5d"
            }
          ]
        }
        """

    func expectValidPresenceProof(
        on request: URLRequest,
        body: Data,
        signedBy presence: APIUserPresenceSession
    ) throws {
        let header = try #require(
            request.value(forHTTPHeaderField: "X-Spark-User-Presence")
        )
        let proof = try UserPresenceProof(headerValue: header)
        let canonical = try UserPresenceCanonicalRequest(
            method: request.httpMethod ?? "GET",
            pathAndQuery: request.url?.path ?? "/",
            timestamp: "2026-08-28T14:00:00Z",
            nonce: "api-test-nonce",
            bodyHashHex: SHA256Digest.hex(body),
            deviceID: "63e82da2-7fb7-4b4b-9584-4a528000ac94",
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
        #expect(request.value(forHTTPHeaderField: "X-Spark-Signature") == "normal-signature")
    }
}
