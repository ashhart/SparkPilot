import CryptoKit
import Foundation
@_spi(SparkTestSupport) import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
@_spi(SparkTestSupport) import SparkTransport
import Testing
@testable import SparkAppComposition

struct ExternalClusterTestManagedLaunchTransport: PinnedHTTPTransport {
    let pin = String(repeating: "a", count: 64)
    let target: ExternalClusterTarget
    let coordinator: ExternalClusterTarget
    let worker: ExternalClusterTarget
    let recorder: ExternalClusterTestManagedLaunchOrderRecorder

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let body: Data
        if request.httpMethod == "GET", path == "/api/v1/capabilities" {
            body = Data(
                #"{"api_version":1,"features":{"cluster_inference":true}}"#.utf8
            )
        } else if request.httpMethod == "GET", path == "/api/v1/cluster" {
            body = Data(
                """
                {"id":"00000000-0000-4000-8000-000000000099","name":"Studio","state":"ready","members":[{"node_id":"\(coordinator.nodeID.rawValue.uuidString.lowercased())","name":"\(coordinator.displayName)","role":"leader","reachable":true,"qsfp_health":"healthy"},{"node_id":"\(worker.nodeID.rawValue.uuidString.lowercased())","name":"\(worker.displayName)","role":"worker","reachable":true,"qsfp_health":"healthy"}]}
                """.utf8
            )
        } else if request.httpMethod == "POST", path == "/api/v1/cluster/launches" {
            let requestBody = try #require(request.httpBody)
            let launch = try JSONDecoder().decode(
                GeneratedAPI.StartClusterLaunchRequest.self,
                from: requestBody
            )
            await recorder.record(target.nodeID.rawValue)
            body = try JSONEncoder().encode(
                GeneratedAPI.ClusterLaunchStatus(
                    launchId: launch.launchId,
                    clusterId: launch.clusterId,
                    recipeId: launch.recipeId,
                    profileId: launch.profileId,
                    state: .preparing,
                    coordinatorNodeId: coordinator.nodeID.rawValue.uuidString.lowercased(),
                    workerNodeId: worker.nodeID.rawValue.uuidString.lowercased(),
                    failureCode: nil,
                    updatedAt: "2026-09-01T12:00:00Z"
                )
            )
        } else {
            throw ExternalClusterTestManagedTransactionTestError.malformedRequest
        }
        return (
            body,
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
        )
    }
}

struct ExternalClusterTestManagedRecoveryEvidenceTransport: PinnedHTTPTransport {
    let pin = String(repeating: "a", count: 64)
    let target: ExternalClusterTarget
    let clusterID: UUID
    let installState: String
    let safeProfile: Bool

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        let body: Data
        switch path {
        case "/api/v1/health":
            body = Data(
                """
                {"api_version":1,"node_id":"\(target.nodeID.rawValue.uuidString.lowercased())","runtime_version":"0.1.0","status":"ok"}
                """.utf8
            )
        case "/api/v1/status":
            body = Data(
                """
                {"api_version":1,"node":{"node_id":"\(target.nodeID.rawValue.uuidString.lowercased())","cluster_id":"\(clusterID.uuidString.lowercased())","name":"\(target.displayName)","role":"member","authority_fingerprint":"authority","runtime_version":"0.1.0","dgx_os_version":"7.0"},"cluster":{"id":"\(clusterID.uuidString.lowercased())","name":"Studio","state":"degraded","members":[]},"system":{"unified_memory_total_bytes":137438953472,"unified_memory_available_bytes":68719476736,"memory_pressure":"normal","cpu_utilisation":0.2,"disk_free_bytes":900000000000,"uptime_seconds":120,"temperature_celsius":48},"inference":{"state":"unloaded","model_id":null,"profile_id":null,"active_requests":0,"queue_depth":0,"tokens_per_second":null,"time_to_first_token_ms":null}}
                """.utf8
            )
        case "/api/v1/models":
            body = Data(
                """
                {"items":[{"id":"verified-recipe","display_name":"Verified","description":null,"recipe_revision":"signed-r7","source_revision":"source-r1","install_state":"\(installState)","total_bytes":8,"capabilities":{"chat":true},"fit":"ready","profiles":[{"id":"safe-profile","display_name":"Safe","max_model_length":4096,"max_sequences":1,"expected_peak_bytes":1024,"measured_peak_bytes":null,"safe":\(safeProfile)}]}],"next_cursor":null}
                """.utf8
            )
        case "/api/v1/capabilities":
            body = Data(
                #"{"api_version":1,"features":{"container_runtime":true,"signed_catalogue":true}}"#
                    .utf8
            )
        default:
            throw ExternalClusterTestManagedTransactionTestError.malformedRequest
        }
        return (
            body,
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
        )
    }
}

final class ExternalClusterTestManagedPresenceSession: UserPresenceProofSigning, @unchecked Sendable
{
    private let signer = SoftwareSigner()
    lazy var keyInfo = UserPresenceKeyInfo(
        publicKeySPKI: signer.publicKeySPKI,
        protection: .softwareTestOnly
    )

    func proof(for request: UserPresenceCanonicalRequest) async throws -> UserPresenceProof {
        try UserPresenceProof.sign(request) { try signer.sign($0) }
    }
}

actor ExternalClusterTestManagedPresenceAuthorizer: UserPresenceAuthorizing {
    private let session = ExternalClusterTestManagedPresenceSession()
    func keyInfo() async throws -> UserPresenceKeyInfo { session.keyInfo }
    func authorize(localizedReason: String) async throws -> any UserPresenceProofSigning { session }
}

struct ExternalClusterTestManagedRequestSigner: UserPresenceRequestSigning {
    func authorize(_ request: URLRequest, body: Data) throws -> URLRequest { request }

    func authorizeWithUserPresence(
        _ request: URLRequest,
        body: Data,
        userPresence: any UserPresenceProofSigning
    ) async throws -> URLRequest {
        let canonical = try UserPresenceCanonicalRequest(
            method: request.httpMethod ?? "POST",
            pathAndQuery: request.url?.path ?? "/",
            timestamp: "2026-08-31T09:00:00Z",
            nonce: UUID().uuidString.lowercased(),
            bodyHashHex: SHA256Digest.hex(body),
            deviceID: "00000000-0000-4000-8000-000000000090",
            expiresAt: "2026-08-31T09:01:00Z",
            nodeID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        )
        let proof = try await userPresence.proof(for: canonical)
        var signed = request
        signed.setValue(try proof.headerValue(), forHTTPHeaderField: "X-Spark-User-Presence")
        return signed
    }

    func authorizePresenceKeyEnrollment(
        _ request: URLRequest,
        userPresence: any UserPresenceProofSigning
    ) async throws -> PresenceKeyEnrollmentAuthorization {
        throw ExternalClusterTestManagedTransactionTestError.scriptedFailure
    }
}
