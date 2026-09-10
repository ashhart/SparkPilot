import CryptoKit
import Foundation
import SparkCore
import SparkSecurity
@_spi(SparkTestSupport) @_spi(SparkInternal) import SparkTransport
import Testing
@_spi(SparkTestSupport) @testable import SparkAPI

extension SparkAPITests {
    @Test func slowNetworkMutationsWaitLongerThanTheServerNmcliWindow() async throws {
        let operation = Data(
            #"{"id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","kind":"network.change","state":"queued","progress":null,"stage":null,"cancellable":false}"#
                .utf8
        )
        let base = URL(string: "https://spark.local:7443")!
        let presence = APIUserPresenceSession()
        let client = try makeClient(signer: APIUserPresenceSigner())

        MockURLProtocol.responses = ["/api/v1/network/wifi": .success(operation)]
        _ = try await client.connectWifi(
            route: base,
            request: .init(ssid: "Workshop WiFi", passphrase: "correct-password", hidden: false),
            userPresence: presence
        )
        #expect(try #require(MockURLProtocol.lastRequest).timeoutInterval > 90)

        MockURLProtocol.responses = ["/api/v1/network/travel-ap": .success(operation)]
        _ = try await client.configureTravelAccessPoint(
            route: base,
            request: .init(
                enabled: true,
                ssid: "Spark Travel",
                passphrase: "correct-password"
            ),
            userPresence: presence
        )
        #expect(try #require(MockURLProtocol.lastRequest).timeoutInterval > 90)
    }

    @Test func manualLanIpv4UsesOnlyTypedFieldsAndFreshPresence() async throws {
        let path = "/api/v1/network/ethernet/ipv4"
        let operation = Data(
            #"{"id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","kind":"network.lan.ipv4","state":"queued","progress":null,"stage":null,"cancellable":false}"#
                .utf8
        )
        MockURLProtocol.responses = [path: .success(operation)]
        MockURLProtocol.lastRequest = nil
        MockURLProtocol.lastBody = nil
        let key = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        let presence = APIUserPresenceSession()

        _ = try await makeClient(signer: APIUserPresenceSigner()).configureLanIpv4(
            route: URL(string: "https://spark.local:7443")!,
            request: .init(
                address: "192.168.100.63",
                prefixLength: 24,
                gateway: "192.168.100.1",
                dnsServers: ["1.1.1.1", "8.8.8.8"]
            ),
            idempotencyKey: key,
            userPresence: presence
        )

        let request = try #require(MockURLProtocol.lastRequest)
        let body = try #require(MockURLProtocol.lastBody)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == path)
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == key.uuidString)
        let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(object["address"] as? String == "192.168.100.63")
        #expect(object["prefix_length"] as? Int == 24)
        #expect(object["gateway"] as? String == "192.168.100.1")
        #expect(object["dns_servers"] as? [String] == ["1.1.1.1", "8.8.8.8"])
        #expect(object["interface"] == nil)
        #expect(object["connection_uuid"] == nil)
        try expectValidPresenceProof(on: request, body: body, signedBy: presence)
    }

    @Test func softwareUpdateCheckUsesTheSignedRefreshRouteAndAnEmptyBody() async throws {
        let path = "/api/v1/system/updates/check"
        let operation = Data(
            #"{"id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","kind":"system.software_update_check","state":"queued","progress":null,"stage":null,"cancellable":false}"#
                .utf8
        )
        MockURLProtocol.responses = [path: .success(operation)]
        MockURLProtocol.lastRequest = nil
        MockURLProtocol.lastBody = nil
        let key = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        let presence = APIUserPresenceSession()

        _ = try await makeClient(signer: APIUserPresenceSigner()).checkSoftwareUpdates(
            route: URL(string: "https://spark.local:7443")!,
            idempotencyKey: key,
            userPresence: presence
        )

        let request = try #require(MockURLProtocol.lastRequest)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == path)
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == key.uuidString)
        #expect(MockURLProtocol.lastBody == nil)
        try expectValidPresenceProof(on: request, body: Data(), signedBy: presence)
    }

    @Test func openWebUIClientUsesTypedSignedServiceRoutes() async throws {
        let base = URL(string: "https://spark.local:7443")!
        let operation = Data(
            #"{"id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","kind":"service.open_webui.install","state":"queued","progress":null,"stage":null,"cancellable":false}"#
                .utf8
        )
        let status = Data(
            #"{"id":"open-webui","display_name":"Open WebUI","state":"not_installed","installed":false,"running":false,"healthy":false,"installed_image_digest":null,"available_revision":"2026-08-29.1","available_version":"0.11.1","update_available":false,"access_path":null,"access_port":7444,"access_tls":true,"inference_gateway":{"scopes":["models.read","chat.completions.create"],"healthy":false,"port":18081,"loopback_only":true},"recovery":null}"#
                .utf8
        )
        let client = try makeClient(signer: APIUserPresenceSigner())
        MockURLProtocol.responses = ["/api/v1/services/open-webui": .success(status)]
        #expect(try await client.openWebUIStatus(route: base).id == .openWebui)

        let key = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        let presence = APIUserPresenceSession()
        MockURLProtocol.responses = ["/api/v1/services/open-webui/install": .success(operation)]
        _ = try await client.installOpenWebUI(
            route: base,
            request: .init(
                adminEmail: "owner@example.test",
                adminName: "Owner",
                adminPassword: "unique-password-1234",
                acceptedRecipeRevision: "2026-08-29.1"
            ),
            idempotencyKey: key,
            userPresence: presence
        )
        let request = try #require(MockURLProtocol.lastRequest)
        let body = try #require(MockURLProtocol.lastBody)
        #expect(request.url?.path == "/api/v1/services/open-webui/install")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == key.uuidString)
        try expectValidPresenceProof(on: request, body: body, signedBy: presence)

        MockURLProtocol.responses = ["/api/v1/services/open-webui/update": .success(operation)]
        _ = try await client.updateOpenWebUI(
            route: base,
            idempotencyKey: key,
            userPresence: presence
        )
        #expect(MockURLProtocol.lastRequest?.url?.path == "/api/v1/services/open-webui/update")
        #expect(MockURLProtocol.lastBody == nil)

        MockURLProtocol.responses = ["/api/v1/services/open-webui/repair": .success(operation)]
        _ = try await client.repairOpenWebUI(
            route: base,
            idempotencyKey: key,
            userPresence: presence
        )
        let repairRequest = try #require(MockURLProtocol.lastRequest)
        #expect(repairRequest.url?.path == "/api/v1/services/open-webui/repair")
        #expect(repairRequest.value(forHTTPHeaderField: "Idempotency-Key") == key.uuidString)
        #expect(MockURLProtocol.lastBody == nil)
        try expectValidPresenceProof(on: repairRequest, body: Data(), signedBy: presence)

        MockURLProtocol.responses = ["/api/v1/services/open-webui/remove": .success(operation)]
        _ = try await client.removeOpenWebUI(
            route: base,
            request: .init(eraseData: false),
            idempotencyKey: key,
            userPresence: presence
        )
        #expect(MockURLProtocol.lastRequest?.url?.path == "/api/v1/services/open-webui/remove")
        #expect(
            try JSONDecoder().decode(
                GeneratedAPI.RemoveOpenWebUIRequest.self,
                from: #require(MockURLProtocol.lastBody)
            ).eraseData == false
        )

        MockURLProtocol.responses = [
            "/api/v1/services/open-webui/access": .success(
                Data(#"{"access_path":"/services/open-webui/"}"#.utf8)
            )
        ]
        #expect(
            try await client.openWebUIAccess(route: base, idempotencyKey: key).accessPath
                == "/services/open-webui/"
        )
        #expect(MockURLProtocol.lastRequest?.url?.path == "/api/v1/services/open-webui/access")
        #expect(MockURLProtocol.lastBody == nil)
    }

    @Test func hostnameChangeUsesTypedBodyStableKeyAndFreshPresence() async throws {
        let operation = Data(
            #"{"id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","kind":"system.hostname","state":"queued","progress":null,"stage":null,"cancellable":false}"#
                .utf8
        )
        let path = "/api/v1/system/hostname"
        MockURLProtocol.responses = [path: .success(operation)]
        MockURLProtocol.lastRequest = nil
        MockURLProtocol.lastBody = nil
        let key = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        let presence = APIUserPresenceSession()

        _ = try await makeClient(signer: APIUserPresenceSigner()).setSparkHostname(
            route: URL(string: "https://spark.local:7443")!,
            hostname: "spark1",
            idempotencyKey: key,
            userPresence: presence
        )

        let request = try #require(MockURLProtocol.lastRequest)
        let body = try #require(MockURLProtocol.lastBody)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == path)
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == key.uuidString)
        #expect(
            try JSONDecoder().decode(GeneratedAPI.SetHostnameRequest.self, from: body).hostname
                == "spark1"
        )
        try expectValidPresenceProof(on: request, body: body, signedBy: presence)
    }

    @Test func clusterCreationUsesTypedBodyStableKeyAndExactBodyPresence() async throws {
        let operation = Data(
            #"{"id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","kind":"cluster.create","state":"queued","progress":null,"stage":null,"cancellable":true}"#
                .utf8
        )
        let path = "/api/v1/cluster/create"
        MockURLProtocol.responses = [path: .success(operation)]
        MockURLProtocol.lastRequest = nil
        MockURLProtocol.lastBody = nil
        let key = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        let presence = APIUserPresenceSession()

        _ = try await makeClient(signer: APIUserPresenceSigner()).createCluster(
            route: URL(string: "https://spark.local:7443")!,
            request: GeneratedAPI.CreateClusterRequest(
                name: "Studio cluster",
                memberNodeIds: [
                    "63e82da2-7fb7-4b4b-9584-4a528000ac94",
                    "7a836150-16e1-46b5-8ac0-32b2a5f2f820",
                ]
            ),
            idempotencyKey: key,
            userPresence: presence
        )

        let request = try #require(MockURLProtocol.lastRequest)
        let body = try #require(MockURLProtocol.lastBody)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == path)
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == key.uuidString)
        #expect(
            String(decoding: body, as: UTF8.self)
                == #"{"member_node_ids":["63e82da2-7fb7-4b4b-9584-4a528000ac94","7a836150-16e1-46b5-8ac0-32b2a5f2f820"],"name":"Studio cluster"}"#
        )
        try expectValidPresenceProof(on: request, body: body, signedBy: presence)
    }

    @Test func fabricInventoryUsesTheSignedReadOnlyRoute() async throws {
        let path = "/api/v1/fabric"
        MockURLProtocol.responses = [
            path: .success(
                Data(
                    #"{"observed_at":"2026-08-31T12:00:00Z","available":true,"unavailable_reason":null,"configuration_owner":"externally_configured","automatic_topology_available":false,"takeover_available":false,"address_evidence_available":true,"route_evidence_available":true,"netplan_evidence_available":true,"netplan_sources":["90-external.yaml"],"ports":[]}"#
                        .utf8
                )
            )
        ]
        MockURLProtocol.lastRequest = nil

        let fabric = try await makeClient().fabric(
            route: URL(string: "https://spark.local:7443")!
        )

        #expect(fabric.configurationOwner == .externallyConfigured)
        #expect(fabric.automaticTopologyAvailable == false)
        #expect(fabric.takeoverAvailable == false)
        let request = try #require(MockURLProtocol.lastRequest)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == path)
    }

    @Test func externalClusterPreviewSendsVariableMembersWithoutPresenceOrTakeover() async throws {
        let path = "/api/v1/cluster/import/preview"
        let members = [
            "63e82da2-7fb7-4b4b-9584-4a528000ac94",
            "7a836150-16e1-46b5-8ac0-32b2a5f2f820",
            "d876ad43-7464-452c-82fc-c6bbc7b601c4",
        ]
        MockURLProtocol.responses = [
            path: .success(
                Data(
                    #"{"name":"Existing lab","configuration_owner":"externally_configured","members":[],"authenticated_links":[],"evidence_complete":false,"registration_available":false,"automatic_topology_available":false,"takeover_available":false,"blockers":[],"preservation_guarantees":["netplan","ssh","ray","vllm","models","containers","services"]}"#
                        .utf8
                )
            )
        ]
        MockURLProtocol.lastRequest = nil
        MockURLProtocol.lastBody = nil
        let key = UUID(uuidString: "12345678-1234-4234-8234-123456789abc")!

        let preview = try await makeClient().previewExternalClusterImport(
            route: URL(string: "https://spark.local:7443")!,
            request: GeneratedAPI.ExternalClusterImportPreviewRequest(
                name: "Existing lab",
                memberNodeIds: members
            ),
            idempotencyKey: key
        )

        #expect(preview.registrationAvailable == false)
        #expect(preview.takeoverAvailable == false)
        let request = try #require(MockURLProtocol.lastRequest)
        let body = try #require(MockURLProtocol.lastBody)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == path)
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == key.uuidString)
        #expect(request.value(forHTTPHeaderField: "X-Spark-User-Presence") == nil)
        let decoded = try JSONDecoder().decode(
            GeneratedAPI.ExternalClusterImportPreviewRequest.self,
            from: body
        )
        #expect(decoded.memberNodeIds == members)
    }
}
