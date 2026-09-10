import CryptoKit
import Foundation
import SparkCore
import SparkSecurity
@_spi(SparkTestSupport) @_spi(SparkInternal) import SparkTransport
import Testing
@_spi(SparkTestSupport) @testable import SparkAPI

extension SparkAPITests {
    @Test func catalogueRefreshClientUsesPreviewDigestAndFreshPresence() async throws {
        let base = URL(string: "https://spark.local:7443")!
        let client = try makeClient(signer: APIUserPresenceSigner())
        MockURLProtocol.responses = [
            "/api/v1/catalogue": .success(
                Data(
                    #"{"source":"device_local_signed_snapshot","refresh_available":true,"recipe_count":1,"current_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","signature_key_id":"spark-root","previous_snapshot_available":false,"last_refreshed_at":null,"active_engine_unaffected":true}"#
                        .utf8
                )
            )
        ]
        #expect(try await client.catalogueStatus(route: base).recipeCount == 1)

        let candidate = #"{"catalogue":"signed"}"#
        let preview = Data(
            #"{"preview_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","action":"catalogue.refresh","target":{"node_id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","cluster_id":null},"recipe":null,"evidence":{"active_inference_available":true,"engine_transitioning":false,"cluster_membership_available":true},"evidence_timestamps":{"system_observed_at":"2026-08-28T12:00:00Z"},"consequences":{"model_to_stop":null,"profile_to_stop":null,"route_withdrawal":false,"service_interruption":"none","files_removed":[],"reinstall_required":false},"blockers":[],"warnings":[],"issued_at":"2026-08-28T12:00:00Z","expires_at":"2026-08-28T12:05:00Z"}"#
                .utf8
        )
        let key = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        MockURLProtocol.responses = ["/api/v1/catalogue/refresh/preview": .success(preview)]
        _ = try await client.previewCatalogueRefresh(
            route: base,
            request: .init(candidateJson: candidate),
            idempotencyKey: key
        )
        #expect(MockURLProtocol.lastRequest?.url?.path == "/api/v1/catalogue/refresh/preview")
        #expect(
            try JSONDecoder().decode(
                GeneratedAPI.CatalogueRefreshPreviewRequest.self,
                from: #require(MockURLProtocol.lastBody)
            ).candidateJson == candidate
        )

        let operation = Data(
            #"{"id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","kind":"catalogue.refresh","state":"queued","progress":null,"stage":null,"cancellable":false}"#
                .utf8
        )
        MockURLProtocol.responses = ["/api/v1/catalogue/refresh": .success(operation)]
        let presence = APIUserPresenceSession()
        _ = try await client.refreshCatalogue(
            route: base,
            request: .init(
                candidateJson: candidate,
                acceptedPreviewDigest: String(repeating: "a", count: 64)
            ),
            idempotencyKey: key,
            userPresence: presence
        )
        let request = try #require(MockURLProtocol.lastRequest)
        let body = try #require(MockURLProtocol.lastBody)
        #expect(request.url?.path == "/api/v1/catalogue/refresh")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == key.uuidString)
        try expectValidPresenceProof(on: request, body: body, signedBy: presence)
    }

    @Test func profileReenableUsesExactReviewedProfileAndFreshPresence() async throws {
        let base = URL(string: "https://spark.local:7443")!
        let client = try makeClient(signer: APIUserPresenceSigner())
        let modelID = "open/model 8b"
        let profileID = "balanced/16k"
        let previewPath =
            "/api/v1/models/open/model 8b/profiles/balanced/16k/re-enable/preview"
        let applyPath = "/api/v1/models/open/model 8b/profiles/balanced/16k/re-enable"
        let preview = Data(
            #"{"preview_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","action":"profile.reenable","target":{"node_id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","cluster_id":null},"recipe":null,"evidence":{"active_inference_available":true,"engine_transitioning":false,"cluster_membership_available":true},"evidence_timestamps":{"system_observed_at":"2026-08-28T12:00:00Z"},"consequences":{"model_to_stop":null,"profile_to_stop":null,"route_withdrawal":false,"service_interruption":"none","files_removed":[],"reinstall_required":false},"blockers":[],"warnings":[{"code":"MODEL_PROFILE_REENABLE_RESTORES_ADMISSION","owner_explanation":"This profile can be admitted again.","recovery_action":null}],"issued_at":"2026-08-28T12:00:00Z","expires_at":"2026-08-28T12:05:00Z"}"#
                .utf8
        )
        let key = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        MockURLProtocol.responses = [previewPath: .success(preview)]

        _ = try await client.previewReenableModelProfile(
            route: base,
            modelID: modelID,
            profileID: profileID,
            idempotencyKey: key
        )
        let previewRequest = try #require(MockURLProtocol.lastRequest)
        #expect(
            previewRequest.url?.absoluteString.contains(
                "open%2Fmodel%208b/profiles/balanced%2F16k/re-enable/preview"
            ) == true
        )
        #expect(previewRequest.value(forHTTPHeaderField: "Idempotency-Key") == key.uuidString)
        #expect(MockURLProtocol.lastBody == nil)

        let operation = Data(
            #"{"id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","kind":"model.profile.reenable","state":"queued","progress":null,"stage":null,"cancellable":false}"#
                .utf8
        )
        MockURLProtocol.responses = [applyPath: .success(operation)]
        let presence = APIUserPresenceSession()
        _ = try await client.reenableModelProfile(
            route: base,
            modelID: modelID,
            profileID: profileID,
            request: .init(acceptedPreviewDigest: String(repeating: "a", count: 64)),
            idempotencyKey: key,
            userPresence: presence
        )
        let request = try #require(MockURLProtocol.lastRequest)
        let body = try #require(MockURLProtocol.lastBody)
        #expect(
            request.url?.absoluteString.contains(
                "open%2Fmodel%208b/profiles/balanced%2F16k/re-enable"
            ) == true
        )
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == key.uuidString)
        #expect(
            try JSONDecoder().decode(
                GeneratedAPI.ReenableModelProfileRequest.self,
                from: body
            ).acceptedPreviewDigest == String(repeating: "a", count: 64)
        )
        try expectValidPresenceProof(on: request, body: body, signedBy: presence)
    }

    @Test func explicitNetworkRollbackUsesTheExactSignedRoute() async throws {
        let configurationID = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        let path = "/api/v1/network/changes/\(configurationID.uuidString.lowercased())/rollback"
        let operation = Data(
            #"{"id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","kind":"network.change.rollback","state":"queued","progress":null,"stage":null,"cancellable":false}"#
                .utf8
        )
        MockURLProtocol.responses = [path: .success(operation)]
        MockURLProtocol.lastRequest = nil
        MockURLProtocol.lastBody = nil
        let presence = APIUserPresenceSession()

        _ = try await makeClient(signer: APIUserPresenceSigner()).rollbackNetworkChange(
            route: URL(string: "https://spark-new-route.local:7443")!,
            configurationID: configurationID,
            userPresence: presence
        )

        let request = try #require(MockURLProtocol.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == path)
        #expect(MockURLProtocol.lastBody == nil)
        try expectValidPresenceProof(on: request, body: Data(), signedBy: presence)
    }

    @Test func projectListingDecodesServerGrantedCapabilities() async throws {
        let path = "/api/v1/projects"
        MockURLProtocol.responses = [
            path: .success(
                Data(
                    """
                    {"items":[{"id":"10000000-0000-4000-8000-000000000001","name":"Private Assistant","state":"ready","repository_url":null,"default_branch":"main","capabilities":["read","write","terminal","agent_run","review"],"created_at":"2026-09-01T12:00:00Z","updated_at":"2026-09-01T12:00:00Z"}],"next_cursor":null,"capabilities":["create"]}
                    """.utf8
                )
            )
        ]
        let client = try makeClient(signer: APIUserPresenceSigner())

        let result = try await client.projects(
            route: URL(string: "https://spark.local:7443")!
        )

        #expect(result.canCreate)
        #expect(result.items.first?.capabilities == [.read, .write, .terminal, .agentRun, .review])
        #expect(MockURLProtocol.lastRequest?.httpMethod == "GET")
        #expect(MockURLProtocol.lastRequest?.url?.path == path)
        #expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Spark-Signature") != nil)
    }
}
