import Foundation
import SparkAPI
import Testing

private func contractFixture(_ name: String) throws -> Data {
    let url = try #require(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
    )
    return try Data(contentsOf: url)
}

private func normalizedJSON(_ data: Data) throws -> Data {
    let object = try JSONSerialization.jsonObject(with: data)
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func requireExactJSONRoundTrip<T: Codable & Equatable>(
    _ type: T.Type,
    fixture: Data
) throws -> T {
    let decoded = try JSONDecoder().decode(type, from: fixture)
    let encoded = try JSONEncoder().encode(decoded)
    #expect(try normalizedJSON(encoded) == normalizedJSON(fixture))
    return decoded
}

@Suite("Generated OpenAPI request contracts")
struct GeneratedContractTests {
    @Test func operationTableIncludesClusterCreate() throws {
        let cluster = try #require(GeneratedAPI.operations.first { $0.id == "createCluster" })
        #expect(cluster.method == "POST")
        #expect(cluster.path == "/api/v1/cluster/create")
        #expect(cluster.requestBodyType == "CreateClusterRequest")
    }

    @Test func clusterCreateUsesNodeIDsNotPrivateMemberFacts() throws {
        let fixture = try contractFixture("create-cluster")
        let request = try requireExactJSONRoundTrip(
            GeneratedAPI.CreateClusterRequest.self,
            fixture: fixture
        )
        let encoded = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(request.memberNodeIds.count == 2)
        #expect(object["member_node_ids"] != nil)
        #expect(object["members"] == nil)
    }

    @Test func buildWorkerRegistrationIsFlatNotCapabilitiesWrapped() throws {
        let fixture = try contractFixture("register-build-worker")
        let request = try requireExactJSONRoundTrip(
            GeneratedAPI.BuildWorkerRegistration.self,
            fixture: fixture
        )
        let encoded = try JSONEncoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(request.architectures == ["arm64"])
        #expect(object["architectures"] != nil)
        #expect(object["capabilities"] == nil)
    }

    @Test func permissiveObjectsPreserveUnknownFields() throws {
        let fixture = Data(
            #"{"name":"lab","member_node_ids":["a","b"],"future_option":{"enabled":true}}"#
                .utf8
        )

        let request = try requireExactJSONRoundTrip(
            GeneratedAPI.CreateClusterRequest.self,
            fixture: fixture
        )

        #expect(request.additionalProperties["future_option"] != nil)
    }

    @Test func permissiveObjectsPreserveEveryJSONNumberShape() throws {
        let fixture = Data(
            #"{"name":"lab","member_node_ids":["a","b"],"large_signed":-9007199254740993,"large_unsigned":18446744073709551615,"ordinary":42,"fraction":1.25,"exponent":1.5e100}"#
                .utf8
        )

        let request = try requireExactJSONRoundTrip(
            GeneratedAPI.CreateClusterRequest.self,
            fixture: fixture
        )

        #expect(
            request.additionalProperties["large_signed"] == .signedInteger(-9_007_199_254_740_993)
        )
        #expect(
            request.additionalProperties["large_unsigned"]
                == .unsignedInteger(18_446_744_073_709_551_615)
        )
        #expect(request.additionalProperties["ordinary"] == .signedInteger(42))
        #expect(request.additionalProperties["fraction"] == .number(1.25))
        #expect(request.additionalProperties["exponent"] == .number(1.5e100))
    }
}
