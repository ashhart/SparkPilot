import CryptoKit
import Foundation
@_spi(SparkTestSupport) import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
@_spi(SparkTestSupport) import SparkTransport
import Testing
@testable import SparkAppComposition

struct ExternalClusterTestExternalRequestSigner: RequestSigning {
    func authorize(_ request: URLRequest, body: Data) throws -> URLRequest {
        var signed = request
        signed.setValue("signed-for-test", forHTTPHeaderField: "X-Spark-Signature")
        return signed
    }
}

struct ExternalClusterTestExternalAPITransport: PinnedHTTPTransport {
    let pin = String(repeating: "a", count: 64)
    let target: ExternalClusterTarget
    let peer: ExternalClusterTarget
    var fabricProof: GeneratedAPI.FabricPortStatusPeerProof = .authenticatedNode
    var unreachable = false

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if unreachable { throw URLError(.cannotConnectToHost) }
        #expect(request.value(forHTTPHeaderField: "X-Spark-Signature") == "signed-for-test")
        let body: Data
        switch request.url?.path {
        case "/api/v1/identity":
            body = Data(
                """
                {"node_id":"\(target.nodeID.rawValue.uuidString.lowercased())","cluster_id":null,"name":"\(target.displayName)","role":"standalone","authority_fingerprint":"authority","runtime_version":"0.1.0","dgx_os_version":"7.0"}
                """.utf8
            )
        case "/api/v1/fabric":
            body = try JSONEncoder().encode(
                externalClusterTestExternalFabric(peer: peer.nodeID, proof: fabricProof)
            )
        case "/api/v1/cluster/import/preview":
            let requestBody = try #require(request.httpBody)
            let decoded = try JSONDecoder().decode(
                GeneratedAPI.ExternalClusterImportPreviewRequest.self,
                from: requestBody
            )
            #expect(decoded.memberNodeIds.count == 2)
            body = try JSONEncoder().encode(
                externalClusterTestExternalPreview(first: target, second: peer)
            )
        default:
            Issue.record("Unexpected external cluster request: \(request.url?.path ?? "nil")")
            body = Data()
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
