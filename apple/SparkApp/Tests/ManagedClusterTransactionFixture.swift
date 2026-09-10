import CryptoKit
import Foundation
@_spi(SparkTestSupport) import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
@_spi(SparkTestSupport) import SparkTransport
import Testing
@testable import SparkAppComposition

struct ExternalClusterTestManagedTransactionTransport: PinnedHTTPTransport {
    let pin = String(repeating: "a", count: 64)
    let target: ExternalClusterTarget
    let peer: ExternalClusterTarget
    let recorder: ExternalClusterTestManagedTransactionRecorder
    var failProof = false
    var failFinalize = false

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        await recorder.record(path)
        if failProof, path.hasSuffix("/prove") {
            throw ExternalClusterTestManagedTransactionTestError.scriptedFailure
        }
        if failFinalize, path.hasSuffix("/finalize") {
            throw ExternalClusterTestManagedTransactionTestError.scriptedFailure
        }
        let body: Data
        if path == "/api/v1/cluster/descriptor" {
            body = try JSONSerialization.data(withJSONObject: [
                "node_id": target.nodeID.rawValue.uuidString.lowercased(),
                "name": target.displayName,
                "authority_public_key": "public-key",
                "authority_fingerprint": "authority",
                "runtime_version": "0.1.0",
                "engine_image": "vllm@sha256:" + String(repeating: "a", count: 64),
            ])
        } else {
            guard let requestBody = request.httpBody else {
                throw ExternalClusterTestManagedTransactionTestError.malformedRequest
            }
            let proposal: GeneratedAPI.ClusterProposal
            if path.hasSuffix("/commit") {
                proposal = try JSONDecoder().decode(
                    GeneratedAPI.CommitClusterTransaction.self,
                    from: requestBody
                ).proposal
            } else if path.hasSuffix("/finalize") {
                proposal = try JSONDecoder().decode(
                    GeneratedAPI.FinalizeClusterTransaction.self,
                    from: requestBody
                ).proposal
            } else if path.hasSuffix("/rollback") {
                proposal = try JSONDecoder().decode(
                    GeneratedAPI.RollbackClusterTransactionRequest.self,
                    from: requestBody
                ).proposal
            } else {
                proposal = try JSONDecoder().decode(
                    GeneratedAPI.ClusterProposal.self,
                    from: requestBody
                )
            }
            let first =
                proposal.members[0].nodeId.lowercased()
                == target.nodeID.rawValue.uuidString.lowercased()
            let localAddress = first ? "172.31.252.1" : "172.31.252.2"
            let peerAddress = first ? "172.31.252.2" : "172.31.252.1"
            let localMAC = first ? "02:00:00:00:00:01" : "02:00:00:00:00:02"
            let peerMAC = first ? "02:00:00:00:00:02" : "02:00:00:00:00:01"
            let common: [String: Any] = [
                "version": 1,
                "transaction_id": proposal.transactionId,
                "cluster_id": proposal.clusterId,
                "proposal_digest": String(repeating: "b", count: 64),
                "member_node_id": target.nodeID.rawValue.uuidString.lowercased(),
                "observed_at": "2026-08-31T09:00:00Z",
                "authority_signature": String(repeating: "A", count: 86),
            ]
            switch path {
            case let value where value.hasSuffix("/prepare"):
                var response = common
                response["owner_device_id"] = proposal.ownerDeviceId
                response["role"] = "owner"
                response["device_key_fingerprint"] = String(repeating: "c", count: 64)
                response["issued_at"] = "2026-08-31T09:00:00Z"
                response["expires_at"] = proposal.expiresAt
                body = try JSONSerialization.data(withJSONObject: response)
            case let value where value.hasSuffix("/activate"):
                body = try JSONSerialization.data(withJSONObject: [
                    "transaction_id": proposal.transactionId, "state": "active",
                ])
            case let value where value.hasSuffix("/prove"):
                var response = common
                response["peer_node_id"] = peer.nodeID.rawValue.uuidString.lowercased()
                response["local_address"] = localAddress
                response["peer_address"] = peerAddress
                response["interface"] = "enp1s0f0np0"
                response["local_mac"] = localMAC
                response["neighbour_mac"] = peerMAC
                response["speed_mbps"] = 200_000
                response["mtu"] = 9_000
                body = try JSONSerialization.data(withJSONObject: response)
            case let value where value.hasSuffix("/collective"):
                var response = common
                response["node_rank"] = first ? 0 : 1
                response["measured_latency_us"] = 250
                response["measured_bandwidth_mbps"] = 100_000
                response["operation_elapsed_ms"] = 1_000
                let initiator = proposal.members[0]
                let responder = proposal.members[1]
                response["fabric_authentication"] = [
                    "version": 1,
                    "transaction_id": proposal.transactionId,
                    "cluster_id": proposal.clusterId,
                    "proposal_digest": String(repeating: "b", count: 64),
                    "member_node_id": target.nodeID.rawValue.uuidString.lowercased(),
                    "initiator_node_id": initiator.nodeId,
                    "responder_node_id": responder.nodeId,
                    "initiator_address": "172.31.252.1",
                    "responder_address": "172.31.252.2",
                    "initiator_authority_public_key": initiator.authorityPublicKey,
                    "responder_authority_public_key": responder.authorityPublicKey,
                    "initiator_nonce": String(repeating: "B", count: 43),
                    "responder_nonce": String(repeating: "C", count: 43),
                    "initiated_at": "2026-08-31T08:59:58Z",
                    "responded_at": "2026-08-31T08:59:59Z",
                    "initiator_signature": String(repeating: "D", count: 86),
                    "responder_signature": String(repeating: "E", count: 86),
                    "acknowledgement_signature": String(repeating: "F", count: 86),
                    "completion_signature": String(repeating: "G", count: 86),
                    "observed_at": "2026-08-31T09:00:00Z",
                    "authority_signature": String(repeating: "H", count: 86),
                ]
                body = try JSONSerialization.data(withJSONObject: response)
            case let value where value.hasSuffix("/commit"):
                var response = common
                response.removeValue(forKey: "observed_at")
                response["committed_at"] = "2026-08-31T09:00:00Z"
                body = try JSONSerialization.data(withJSONObject: response)
            case let value where value.hasSuffix("/finalize"):
                body = try JSONSerialization.data(withJSONObject: [
                    "id": proposal.clusterId,
                    "name": proposal.name,
                    "state": "ready",
                    "members": [],
                ])
            case let value where value.hasSuffix("/rollback"):
                body = try JSONSerialization.data(withJSONObject: [
                    "transaction_id": proposal.transactionId, "state": "rolled_back",
                ])
            default:
                throw ExternalClusterTestManagedTransactionTestError.malformedRequest
            }
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
