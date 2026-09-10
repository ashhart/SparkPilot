import CryptoKit
import Foundation
import SparkCore
import SparkSecurity
@_spi(SparkTestSupport) @_spi(SparkInternal) import SparkTransport
import Testing
@_spi(SparkTestSupport) @testable import SparkAPI

extension SparkAPITests {
    @Test func routeProbeRejectsIdentityMismatch() async throws {
        MockURLProtocol.responses = [
            "/api/v1/health": .success(Data(healthFixture.utf8))
        ]
        let expected = SparkNodeID(
            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        )
        let probe = try makeProbe()
        let route = SparkRoute(
            nodeID: expected,
            baseURL: URL(string: "https://spark.local:7443")!,
            kind: .localWiFi,
            interfaceName: nil
        )
        let result = await probe.validate(route: route, expectedNodeID: expected)
        guard case .identityMismatch(let presented, _) = result else {
            Issue.record("expected identity mismatch, got \(result)")
            return
        }
        #expect(presented.rawValue == UUID(uuidString: "63e82da2-7fb7-4b4b-9584-4a528000ac94"))
    }

    @Test func routeProbeReportsUnreachable() async throws {
        MockURLProtocol.responses = [
            "/api/v1/health": .failure(.http(503))
        ]
        let expected = SparkNodeID(rawValue: UUID())
        let probe = try makeProbe()
        let route = SparkRoute(
            nodeID: expected,
            baseURL: URL(string: "https://spark.local:7443")!,
            kind: .localWiFi,
            interfaceName: nil
        )
        let result = await probe.validate(route: route, expectedNodeID: expected)
        guard case .unreachable = result else {
            Issue.record("expected unreachable, got \(result)")
            return
        }
    }

    /// A runtime that advertises other protocols is reported as needing an update; one that says nothing predates the signal and is accepted (H-1).
    @Test func routeProbeReportsAProtocolMismatchInsteadOfAccepting() async throws {
        let expected = SparkNodeID(
            rawValue: UUID(uuidString: "63e82da2-7fb7-4b4b-9584-4a528000ac94")!
        )
        let route = SparkRoute(
            nodeID: expected,
            baseURL: URL(string: "https://spark.local:7443")!,
            kind: .localWiFi,
            interfaceName: nil
        )
        for body in [
            #"{"api_version":1,"node_id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","runtime_version":"0.1.11","status":"ok","auth_protocols":["SPARK1"]}"#,
            #"{"api_version":1,"node_id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","runtime_version":"0.2.0","status":"ok","auth_protocols":["SPARK3"]}"#,
        ] {
            MockURLProtocol.responses = ["/api/v1/health": .success(Data(body.utf8))]
            let probe = try makeProbe()
            let result = await probe.validate(route: route, expectedNodeID: expected)
            guard case .protocolUnsupported = result else {
                Issue.record("expected a protocol mismatch, got \(result)")
                continue
            }
        }
        // A SPARK2 runtime is accepted whether or not it advertises; the advertisement arrived after SPARK2 shipped.
        for body in [
            #"{"api_version":1,"node_id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","runtime_version":"0.1.12","status":"ok","auth_protocols":["SPARK2"]}"#,
            #"{"api_version":1,"node_id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","runtime_version":"0.1.12","status":"ok"}"#,
        ] {
            MockURLProtocol.responses = ["/api/v1/health": .success(Data(body.utf8))]
            let probe = try makeProbe()
            let result = await probe.validate(route: route, expectedNodeID: expected)
            guard case .accepted = result else {
                Issue.record("a SPARK2 runtime must be accepted, got \(result)")
                continue
            }
        }
    }

    @Test func controlMutationCarriesTheCallerStableUUID() async throws {
        let operation = Data(
            #"{"id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","kind":"remote.enable","state":"queued","progress":null,"stage":null,"cancellable":true}"#
                .utf8
        )
        MockURLProtocol.responses = ["/api/v1/remote/enable": .success(operation)]
        MockURLProtocol.lastRequest = nil
        MockURLProtocol.lastBody = nil
        let key = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!

        _ = try await makeClient(signer: APIUserPresenceSigner()).enableRemote(
            route: URL(string: "https://spark.local:7443")!,
            body: EnableRemoteRequest(
                mode: .privateOverlay,
                acceptedPreviewDigest: String(repeating: "a", count: 64)
            ),
            idempotencyKey: key,
            userPresence: APIUserPresenceSession()
        )

        #expect(
            MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Idempotency-Key")
                == key.uuidString
        )
        #expect(
            MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Spark-User-Presence")
                != nil
        )
    }

    @Test func powerControlsUseExactRoutesStableKeysAndFreshPresence() async throws {
        let operation = Data(
            #"{"id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","kind":"power.reboot","state":"queued","progress":null,"stage":null,"cancellable":false}"#
                .utf8
        )
        let base = URL(string: "https://spark.local:7443")!
        let key = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        let presence = APIUserPresenceSession()
        let client = try makeClient(signer: APIUserPresenceSigner())

        for (path, send) in [
            (
                "/api/v1/power/reboot",
                {
                    try await client.rebootSpark(
                        route: base,
                        idempotencyKey: key,
                        userPresence: presence
                    )
                }
            ),
            (
                "/api/v1/power/shutdown",
                {
                    try await client.shutdownSpark(
                        route: base,
                        idempotencyKey: key,
                        userPresence: presence
                    )
                }
            ),
        ] {
            MockURLProtocol.responses = [path: .success(operation)]
            MockURLProtocol.lastRequest = nil
            MockURLProtocol.lastBody = nil
            _ = try await send()

            let request = try #require(MockURLProtocol.lastRequest)
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == path)
            #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == key.uuidString)
            #expect(MockURLProtocol.lastBody == nil)
            try expectValidPresenceProof(on: request, body: Data(), signedBy: presence)
        }
    }

    @Test func routeProbeDoesNotTreatCooperativeCancellationAsACertificateFinding() {
        #expect(!RouteProbe.isCertificateRejection(CancellationError()))
        #expect(!RouteProbe.isCertificateRejection(URLError(.cancelled)))
    }

    @Test func decodesModelCatalogueAndInstallState() async throws {
        MockURLProtocol.responses = [
            "/api/v1/models": .success(
                Data(
                    #"{"items":[{"id":"open/model-8b","display_name":"Model 8B","description":"Small local model","recipe_revision":"r1","source_revision":"s1","source_provider":"huggingface","gated":true,"install_state":"available","total_bytes":8000000000,"capabilities":{"chat":true},"fit":"fits","profiles":[{"id":"balanced","display_name":"Balanced","max_model_length":32768,"max_sequences":4,"expected_peak_bytes":12000000000,"measured_peak_bytes":null,"safe":true}]}],"next_cursor":null}"#
                        .utf8
                )
            )
        ]

        let catalogue = try await (try makeClient()).models(
            route: URL(string: "https://spark.local:7443")!
        )

        #expect(catalogue.items.count == 1)
        #expect(catalogue.items[0].installState == .available)
        #expect(catalogue.items[0].sourceProvider == "huggingface")
        #expect(catalogue.items[0].gated == true)
        #expect(catalogue.items[0].fit == "fits")
        #expect(catalogue.items[0].profiles[0].safe)
    }
}
