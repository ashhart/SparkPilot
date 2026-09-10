import CryptoKit
import Foundation
import SparkCore
import SparkSecurity
@_spi(SparkTestSupport) @_spi(SparkInternal) import SparkTransport
import Testing
@_spi(SparkTestSupport) @testable import SparkAPI

extension SparkAPITests {
    @Test func decodesActiveVLLMState() async throws {
        MockURLProtocol.responses = [
            "/api/v1/inference/active": .success(
                Data(
                    #"{"state":"ready","model_id":"open/model-8b","profile_id":"balanced","context_length":32768,"active_requests":0,"queue_depth":0,"tokens_per_second":42.5,"time_to_first_token_ms":210}"#
                        .utf8
                )
            )
        ]

        let inference = try await (try makeClient()).activeInference(
            route: URL(string: "https://spark.local:7443")!
        )

        #expect(inference.state == .ready)
        #expect(inference.modelID == "open/model-8b")
        #expect(inference.tokensPerSecond == 42.5)
    }

    @Test func modelInstallUsesGeneratedBodyEncodedIdentifierAndStableKey() async throws {
        let accepted = Data(
            #"{"id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","kind":"model.install","state":"queued","progress":0.0,"stage":"queued","cancellable":true}"#
                .utf8
        )
        MockURLProtocol.responses = [
            "/api/v1/models/open/model-8b/install": .success(accepted)
        ]
        MockURLProtocol.lastRequest = nil
        let key = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!

        _ = try await makeClient().installModel(
            route: URL(string: "https://spark.local:7443")!,
            modelID: "open/model-8b",
            request: GeneratedAPI.InstallModelRequest(
                recipeRevision: "recipe-r1",
                providerCredentialId: "credential-1",
                acceptedPreviewDigest: String(repeating: "a", count: 64)
            ),
            idempotencyKey: key
        )

        let request = try #require(MockURLProtocol.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString.contains("open%2Fmodel-8b/install") == true)
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == key.uuidString)
        let body = try #require(MockURLProtocol.lastBody)
        #expect(
            String(decoding: body, as: UTF8.self)
                == #"{"accepted_preview_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","provider_credential_id":"credential-1","recipe_revision":"recipe-r1"}"#
        )
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["recipe_revision"] as? String == "recipe-r1")
    }

    @Test func providerCredentialsStaySecretFreeAndMutationsRequirePresence() async throws {
        let credentialID = "63e82da2-7fb7-4b4b-9584-4a528000ac94"
        let credential =
            #"{"id":"\#(credentialID)","provider":"huggingface","display_name":"Private models","created_at":"2026-08-31T12:00:00Z"}"#
        MockURLProtocol.responses = [
            "/api/v1/credentials": .success(Data("{\"items\":[\(credential)]}".utf8)),
            "/api/v1/credentials/\(credentialID)": .success(Data()),
        ]
        MockURLProtocol.statusCodes = ["/api/v1/credentials": 201]
        let client = try makeClient(signer: APIUserPresenceSigner())
        let route = URL(string: "https://spark.local:7443")!
        let presence = APIUserPresenceSession()

        MockURLProtocol.statusCodes["/api/v1/credentials"] = 200
        let listed = try await client.providerCredentials(route: route)
        #expect(listed.map(\.displayName) == ["Private models"])
        #expect(!String(describing: listed).contains("hf_secret"))

        MockURLProtocol.responses["/api/v1/credentials"] = .success(Data(credential.utf8))
        MockURLProtocol.statusCodes["/api/v1/credentials"] = 201
        let added = try await client.addProviderCredential(
            route: route,
            request: GeneratedAPI.AddProviderCredentialRequest(
                provider: "huggingface",
                displayName: "Private models",
                secret: "hf_secret"
            ),
            idempotencyKey: UUID(),
            userPresence: presence
        )
        #expect(added.id == credentialID)
        #expect(
            MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Spark-User-Presence") != nil
        )

        try await client.revokeProviderCredential(
            route: route,
            credentialID: credentialID,
            idempotencyKey: UUID(),
            userPresence: presence
        )
        #expect(MockURLProtocol.lastRequest?.httpMethod == "DELETE")
        #expect(
            MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Spark-User-Presence") != nil
        )
    }

    @Test func modelLifecyclePreviewsUseTheStableKeyAndGeneratedBodies() async throws {
        let preview = Data(
            #"{"preview_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","action":"install","target":{"node_id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","cluster_id":null},"recipe":null,"evidence":{"active_inference_available":true,"engine_transitioning":false,"cluster_membership_available":true},"evidence_timestamps":{"system_observed_at":"2026-08-28T12:00:00Z"},"consequences":{"model_to_stop":null,"profile_to_stop":null,"route_withdrawal":false,"service_interruption":"none","files_removed":[],"reinstall_required":false},"blockers":[],"warnings":[],"issued_at":"2026-08-28T12:00:00Z","expires_at":"2026-08-28T12:05:00Z"}"#
                .utf8
        )
        MockURLProtocol.responses = [
            "/api/v1/models/open/model-8b/install/preview": .success(preview),
            "/api/v1/inference/load/preview": .success(preview),
            "/api/v1/inference/unload/preview": .success(preview),
            "/api/v1/models/open/model-8b/remove/preview": .success(preview),
        ]
        let client = try makeClient()
        let key = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        let route = URL(string: "https://spark.local:7443")!

        _ = try await client.previewInstallModel(
            route: route,
            modelID: "open/model-8b",
            request: GeneratedAPI.InstallModelPreviewRequest(recipeRevision: "r1"),
            idempotencyKey: key
        )
        var request = try #require(MockURLProtocol.lastRequest)
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == key.uuidString)
        var body = try #require(MockURLProtocol.lastBody)
        #expect(String(decoding: body, as: UTF8.self) == #"{"recipe_revision":"r1"}"#)

        _ = try await client.previewLoadModel(
            route: route,
            request: GeneratedAPI.LoadModelPreviewRequest(
                modelId: "open/model-8b",
                profileId: "balanced",
                replaceActive: true
            ),
            idempotencyKey: key
        )
        request = try #require(MockURLProtocol.lastRequest)
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == key.uuidString)
        body = try #require(MockURLProtocol.lastBody)
        let load = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(load["replace_active"] as? Bool == true)

        _ = try await client.previewUnloadModel(
            route: route,
            request: GeneratedAPI.StopModelPreviewRequest(force: false),
            idempotencyKey: key
        )
        request = try #require(MockURLProtocol.lastRequest)
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == key.uuidString)
        body = try #require(MockURLProtocol.lastBody)
        #expect(String(decoding: body, as: UTF8.self) == #"{"force":false}"#)

        _ = try await client.previewRemoveModel(
            route: route,
            modelID: "open/model-8b",
            idempotencyKey: key
        )
        request = try #require(MockURLProtocol.lastRequest)
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == key.uuidString)
        #expect(MockURLProtocol.lastBody == nil)
    }

    @Test func modelEngineMutationsUseGeneratedBodiesAndStableKeys() async throws {
        let accepted = Data(
            #"{"id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","kind":"model.lifecycle","state":"queued","progress":null,"stage":null,"cancellable":true}"#
                .utf8
        )
        MockURLProtocol.responses = [
            "/api/v1/inference/load": .success(accepted),
            "/api/v1/inference/unload": .success(accepted),
        ]
        let client = try makeClient()
        let loadKey = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        let unloadKey = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

        _ = try await client.loadModel(
            route: URL(string: "https://spark.local:7443")!,
            request: GeneratedAPI.LoadModelRequest(
                modelId: "open/model-8b",
                profileId: "balanced",
                replaceActive: true,
                acceptedPreviewDigest: String(repeating: "b", count: 64)
            ),
            idempotencyKey: loadKey
        )
        var request = try #require(MockURLProtocol.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == loadKey.uuidString)
        let loadBody = try #require(MockURLProtocol.lastBody)
        var json = try #require(
            JSONSerialization.jsonObject(with: loadBody) as? [String: Any]
        )
        #expect(json["model_id"] as? String == "open/model-8b")
        #expect(json["profile_id"] as? String == "balanced")
        #expect(json["replace_active"] as? Bool == true)

        _ = try await client.unloadModel(
            route: URL(string: "https://spark.local:7443")!,
            request: GeneratedAPI.StopModelRequest(
                force: false,
                acceptedPreviewDigest: String(repeating: "c", count: 64)
            ),
            idempotencyKey: unloadKey
        )
        request = try #require(MockURLProtocol.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == unloadKey.uuidString)
        let unloadBody = try #require(MockURLProtocol.lastBody)
        json = try #require(
            JSONSerialization.jsonObject(with: unloadBody) as? [String: Any]
        )
        #expect(json["force"] as? Bool == false)
    }

    @Test func modelRemovalAndOperationPollingMatchTheContract() async throws {
        let operationID = UUID(uuidString: "63e82da2-7fb7-4b4b-9584-4a528000ac94")!
        let accepted = Data(
            #"{"id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","kind":"model.remove","state":"running","progress":0.5,"stage":"deleting","cancellable":false}"#
                .utf8
        )
        MockURLProtocol.responses = [
            "/api/v1/models/open/model-8b": .success(accepted),
            "/api/v1/operations/63E82DA2-7FB7-4B4B-9584-4A528000AC94": .success(accepted),
        ]
        let client = try makeClient()
        let key = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!

        _ = try await client.removeModel(
            route: URL(string: "https://spark.local:7443")!,
            modelID: "open/model-8b",
            request: GeneratedAPI.RemoveModelRequest(
                acceptedPreviewDigest: String(repeating: "d", count: 64)
            ),
            idempotencyKey: key
        )
        var request = try #require(MockURLProtocol.lastRequest)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.absoluteString.contains("open%2Fmodel-8b") == true)
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == key.uuidString)

        let operation = try await client.operation(
            route: URL(string: "https://spark.local:7443")!,
            id: operationID
        )
        request = try #require(MockURLProtocol.lastRequest)
        #expect(request.httpMethod == "GET")
        #expect(operation.progress == 0.5)
        #expect(operation.stage == "deleting")
    }

    @Test func operationListingUsesTypedPaginationAndContractLimits() async throws {
        let page = Data(
            #"{"items":[{"id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","kind":"model.install","state":"running","progress":0.5,"stage":"downloading","cancellable":true}],"next_cursor":"next page"}"#
                .utf8
        )
        MockURLProtocol.responses = [
            "/api/v1/operations": .success(page)
        ]

        let result = try await makeClient().operations(
            route: URL(string: "https://spark.local:7443")!,
            limit: 500,
            cursor: "after/one"
        )

        let request = try #require(MockURLProtocol.lastRequest)
        let requestURL = try #require(request.url)
        let components = try #require(
            URLComponents(url: requestURL, resolvingAgainstBaseURL: false)
        )
        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) }
        )
        #expect(request.httpMethod == "GET")
        #expect(query["limit"] == "200")
        #expect(query["cursor"] == "after/one")
        #expect(result.items.first?.kind == "model.install")
        #expect(result.nextCursor == "next page")
    }
}
