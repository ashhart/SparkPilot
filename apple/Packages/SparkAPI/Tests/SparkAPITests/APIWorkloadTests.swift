import CryptoKit
import Foundation
import SparkCore
import SparkSecurity
@_spi(SparkTestSupport) @_spi(SparkInternal) import SparkTransport
import Testing
@_spi(SparkTestSupport) @testable import SparkAPI

extension SparkAPITests {
    @Test func decodesTheWorkloadInventoryAsServedByRuntime() async throws {
        MockURLProtocol.responses = [
            "/api/v1/workloads": .success(Data(workloadInventoryFixture.utf8))
        ]
        MockURLProtocol.requestsMade = []
        let client = try makeClient()

        let inventory = try await client.workloads(
            route: URL(string: "https://spark.local:7443")!
        )

        #expect(MockURLProtocol.requestsMade == ["/api/v1/workloads"])
        #expect(inventory.available)
        #expect(!inventory.adoptionSupported)
        #expect(!inventory.truncated)
        #expect(inventory.workloads.count == 3)
        #expect(inventory.workloads[0].ownership == .sparkManaged)
        #expect(inventory.workloads[0].recognisedEngine == .vllm)
        #expect(inventory.workloads[1].ownership == .externalObserved)
        #expect(inventory.workloads[1].publishedPorts.first?.hostPort == 30000)
        #expect(inventory.workloads[1].servedModels == ["deepseek-ai/DeepSeek-R1"])
        #expect(inventory.workloads[1].apiPort == 30000)
        #expect(inventory.workloads[1].publishedPorts.first?.protocol == .tcp)
        #expect(inventory.workloads[2].ownership == .unknownExternal)
        #expect(inventory.workloads[2].recognisedEngine == .none)
    }

    /// Distinguish unavailable workload inspection from an observed empty runtime.
    @Test func decodesAnInventoryThatCouldNotBeRead() async throws {
        let payload = """
            {"observed_at":"2026-08-30T09:00:00Z","available":false,\
            "unavailable_reason":"the container runtime could not be inspected",\
            "adoption_supported":false,"truncated":false,"workloads":[]}
            """
        MockURLProtocol.responses = [
            "/api/v1/workloads": .success(Data(payload.utf8))
        ]
        let client = try makeClient()

        let inventory = try await client.workloads(
            route: URL(string: "https://spark.local:7443")!
        )

        #expect(!inventory.available)
        #expect(inventory.workloads.isEmpty)
        #expect(inventory.unavailableReason == "the container runtime could not be inspected")
    }

    @Test func olderWorkloadInventoryLeavesNewExternalConfigurationUnknown() async throws {
        let payload = """
            {"observed_at":"2026-08-30T09:00:00Z","available":true,
            "adoption_supported":false,"truncated":false,"workloads":[{
            "workload_id":"1a3b","name":"existing-vllm",
            "ownership":"external_observed","kind":"inference_engine",
            "recognised_engine":"vllm","state":"running",
            "image_reference":"vllm/vllm-openai:v0.11.0","published_ports":[]}]}
            """
        MockURLProtocol.responses = [
            "/api/v1/workloads": .success(Data(payload.utf8))
        ]
        let client = try makeClient()

        let inventory = try await client.workloads(
            route: URL(string: "https://spark.local:7443")!
        )

        #expect(inventory.workloads.first?.configurationState == nil)
        #expect(inventory.workloads.first?.servedModels == nil)
        #expect(inventory.workloads.first?.apiPort == nil)
    }

    @Test func workloadOwnershipUsesExactTypedRoutesBodiesStableKeysAndPresence() async throws {
        let workloadID = String(repeating: "a", count: 64)
        let adoptionPath = "/api/v1/workloads/\(workloadID)/adopt"
        let relinquishPath = "/api/v1/workloads/\(workloadID)/relinquish"
        let operation = Data(
            #"{"id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","kind":"workload.adopt","state":"queued","progress":null,"stage":null,"cancellable":false}"#
                .utf8
        )
        let relinquished = Data(
            "{\"workload_id\":\"\(workloadID)\",\"ownership\":\"external_observed\",\"container_changed\":false}"
                .utf8
        )
        MockURLProtocol.responses = [
            adoptionPath: .success(operation),
            relinquishPath: .success(relinquished),
        ]
        MockURLProtocol.statusCodes = [adoptionPath: 202, relinquishPath: 200]
        MockURLProtocol.requestsMade = []
        let client = try makeClient(signer: APIUserPresenceSigner())
        let presence = APIUserPresenceSession()
        let key = UUID(uuidString: "1065ac4e-8536-493c-8245-ec376c54b5f3")!
        let digest = String(repeating: "b", count: 64)

        _ = try await client.adoptWorkload(
            route: URL(string: "https://spark.local:7443")!,
            workloadID: workloadID,
            request: .init(
                modelId: "example/model",
                profileId: "balanced",
                acceptedPreviewDigest: digest
            ),
            idempotencyKey: key,
            userPresence: presence
        )
        #expect(
            MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Idempotency-Key")
                == key.uuidString
        )
        #expect(
            MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Spark-User-Presence") != nil
        )
        let adoptionBody =
            try JSONSerialization.jsonObject(
                with: #require(MockURLProtocol.lastBody)
            ) as? [String: String]
        #expect(adoptionBody?["model_id"] == "example/model")
        #expect(adoptionBody?["profile_id"] == "balanced")
        #expect(adoptionBody?["accepted_preview_digest"] == digest)

        let response = try await client.relinquishWorkload(
            route: URL(string: "https://spark.local:7443")!,
            workloadID: workloadID,
            request: .init(acceptedPreviewDigest: digest),
            idempotencyKey: key,
            userPresence: presence
        )
        #expect(!response.containerChanged)
        #expect(MockURLProtocol.requestsMade == [adoptionPath, relinquishPath])
        let relinquishBody =
            try JSONSerialization.jsonObject(
                with: #require(MockURLProtocol.lastBody)
            ) as? [String: String]
        #expect(relinquishBody?["accepted_preview_digest"] == digest)
    }
}
