import CryptoKit
import Foundation
import SparkCore
import SparkSecurity
@_spi(SparkTestSupport) @_spi(SparkInternal) import SparkTransport
import Testing
@_spi(SparkTestSupport) @testable import SparkAPI

extension SparkAPITests {
    @Test func administratorInvitationCarriesPresenceOverTheExactJSONBody() async throws {
        let response = Data(
            #"{"version":1,"node_id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","authority_fingerprint":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","invitation_id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","nonce":"bm9uY2U","role":"administrator","expires_at":"2026-08-28T14:05:00Z","signature":"c2ln"}"#
                .utf8
        )
        let path = "/api/v1/pairing/invitations"
        MockURLProtocol.responses = [path: .success(response)]
        MockURLProtocol.lastRequest = nil
        MockURLProtocol.lastBody = nil

        _ = try await makeClient(signer: APIUserPresenceSigner()).createPairingInvitation(
            route: URL(string: "https://spark.local:7443")!,
            role: "administrator",
            userPresence: APIUserPresenceSession()
        )

        let request = try #require(MockURLProtocol.lastRequest)
        let body = try #require(MockURLProtocol.lastBody)
        #expect(request.value(forHTTPHeaderField: "X-Spark-User-Presence") != nil)
        #expect(request.value(forHTTPHeaderField: "X-Spark-Signature") == "normal-signature")
        let decoded = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(decoded["role"] as? String == "administrator")
        #expect(SHA256Digest.hex(body).count == 64)
    }

    @Test func ordinaryInvitationDoesNotCarryPresence() async throws {
        let response = Data(
            #"{"version":1,"node_id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","authority_fingerprint":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","invitation_id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","nonce":"bm9uY2U","role":"user","expires_at":"2026-08-28T14:05:00Z","signature":"c2ln","join_code":"381204"}"#
                .utf8
        )
        let path = "/api/v1/pairing/invitations"
        MockURLProtocol.responses = [path: .success(response)]
        MockURLProtocol.lastRequest = nil

        let invitation = try await makeClient(signer: APIUserPresenceSigner())
            .createPairingInvitation(
                route: URL(string: "https://spark.local:7443")!,
                role: "user"
            )

        #expect(invitation.joinCode == "381204")
        #expect(
            MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Spark-User-Presence")
                == nil
        )
    }

    @Test func batchInvitationBindsTheRecipientInTheSignedRequestBody() async throws {
        let recipientID = UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!
        let recipientFingerprint = String(repeating: "b", count: 64)
        let response = Data(
            #"{"version":1,"node_id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","authority_fingerprint":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","invitation_id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","nonce":"bm9uY2U","issued_by_device_id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","recipient_device_id":"bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb","recipient_public_key_fingerprint":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","role":"administrator","expires_at":"2026-08-28T14:05:00Z","signature":"c2ln"}"#
                .utf8
        )
        MockURLProtocol.responses = ["/api/v1/pairing/invitations": .success(response)]
        MockURLProtocol.lastBody = nil

        let invitation = try await makeClient(signer: APIUserPresenceSigner())
            .createBoundPairingInvitation(
                route: URL(string: "https://spark.local:7443")!,
                role: "administrator",
                recipientDeviceID: recipientID,
                recipientPublicKeyFingerprint: recipientFingerprint,
                userPresence: APIUserPresenceSession()
            )

        let body = try #require(MockURLProtocol.lastBody)
        let decoded = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(decoded["recipient_device_id"] as? String == recipientID.uuidString)
        #expect(decoded["recipient_public_key_fingerprint"] as? String == recipientFingerprint)
        #expect(invitation.recipientDeviceID == recipientID.uuidString.lowercased())
        #expect(invitation.recipientPublicKeyFingerprint == recipientFingerprint)
    }

    @Test func routeProbeReportsARefusedCertificateAsSuchNotAsUnreachable() async throws {
        // Distinguish trust rejection from unreachability; a bare URL cancellation does not prove certificate rejection.
        let client = SparkAPIClient(transport: RefusedCertificateTransport(pin: Self.testPin))
        let expected = SparkNodeID(rawValue: UUID())
        let result = await RouteProbe(pin: Self.testPin, using: client).validate(
            route: SparkRoute(
                nodeID: expected,
                baseURL: URL(string: "https://spark.local:7443")!,
                kind: .localWiFi,
                interfaceName: nil
            ),
            expectedNodeID: expected
        )
        #expect(result == .certificateRejected(pin: Self.testPin))
    }

    @Test func deviceListingAndRevocationMatchTheContract() async throws {
        let deviceID = "63e82da2-7fb7-4b4b-9584-4a528000ac94"
        MockURLProtocol.responses = [
            "/api/v1/devices": .success(
                Data(
                    """
                    {"items":[{"id":"\(deviceID)","display_name":"Alex's iPad","platform":"ipados","role":"owner","capabilities":["models.read"],"paired_at":"2026-08-20T09:30:00Z","last_seen_at":"2026-08-28T11:45:00Z","revoked":false}]}
                    """.utf8
                )
            ),
            "/api/v1/devices/\(deviceID)": .success(Data()),
        ]
        MockURLProtocol.statusCodes["/api/v1/devices/\(deviceID)"] = 204
        MockURLProtocol.lastRequest = nil
        let client = try makeClient(signer: APIUserPresenceSigner())
        let route = URL(string: "https://spark.local:7443")!

        let devices = try await client.devices(route: route)

        #expect(devices.count == 1)
        #expect(devices[0].displayName == "Alex's iPad")
        #expect(devices[0].platform == .ipados)
        #expect(devices[0].role == .owner)
        #expect(devices[0].lastSeenAt == "2026-08-28T11:45:00Z")
        #expect(!devices[0].revoked)

        let key = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
        try await client.revokeDevice(
            route: route,
            deviceID: deviceID,
            idempotencyKey: key,
            userPresence: APIUserPresenceSession()
        )

        let request = try #require(MockURLProtocol.lastRequest)
        #expect(request.httpMethod == "DELETE")
        #expect(request.url?.path == "/api/v1/devices/\(deviceID)")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == key.uuidString)
        let header = try #require(request.value(forHTTPHeaderField: "X-Spark-User-Presence"))
        let proof = try UserPresenceProof(headerValue: header)
        #expect(proof.version == 2)
        #expect(proof.expiresAt == "2026-08-28T14:01:00Z")
        #expect(request.value(forHTTPHeaderField: "X-Spark-Signature") == "normal-signature")
    }

    @Test func revocationWithoutAPresenceCapableSignerSendsNothing() async throws {
        let deviceID = "63e82da2-7fb7-4b4b-9584-4a528000ac94"
        MockURLProtocol.responses = [
            "/api/v1/devices/\(deviceID)": .success(Data())
        ]
        MockURLProtocol.requestsMade = []
        let client = try makeClient()

        await #expect(throws: APIError.self) {
            try await client.revokeDevice(
                route: URL(string: "https://spark.local:7443")!,
                deviceID: deviceID,
                idempotencyKey: UUID(),
                userPresence: APIUserPresenceSession()
            )
        }

        #expect(!MockURLProtocol.requestsMade.contains("/api/v1/devices/\(deviceID)"))
    }

    @Test func legacyPresenceKeyEnrollmentVerifiesTheReturnedFingerprint() async throws {
        let presence = APIUserPresenceSession()
        let fingerprint = try presence.keyInfo.pairingFingerprint()
        let path = "/api/v1/devices/self/presence-key"
        MockURLProtocol.responses = [
            path: .success(
                Data("{\"presence_key_fingerprint\":\"\(fingerprint)\"}".utf8)
            )
        ]
        let client = try makeClient(signer: APIUserPresenceSigner())
        let result = try await client.enrollPresenceKey(
            route: URL(string: "https://spark.local:7443")!,
            idempotencyKey: UUID(),
            userPresence: presence
        )

        #expect(result == fingerprint)
        #expect(MockURLProtocol.lastRequest?.httpMethod == "POST")
        #expect(MockURLProtocol.lastRequest?.url?.path == path)
        #expect(MockURLProtocol.lastBody?.isEmpty == false)
        #expect(
            MockURLProtocol.lastRequest?
                .value(forHTTPHeaderField: "X-Spark-Presence-Key-Proof")?.isEmpty == false
        )
        let responseBody = try #require(MockURLProtocol.lastBody)
        let body = try #require(
            JSONSerialization.jsonObject(with: responseBody) as? [String: Any]
        )
        #expect(body["presence_public_key_spki"] != nil)
        #expect(body["presence_key_signature"] == nil)
    }

    @Test func legacyPresenceKeyEnrollmentRejectsAForgedFingerprint() async throws {
        let path = "/api/v1/devices/self/presence-key"
        MockURLProtocol.responses = [
            path: .success(
                Data(
                    "{\"presence_key_fingerprint\":\"\(String(repeating: "0", count: 64))\"}"
                        .utf8
                )
            )
        ]
        let client = try makeClient(signer: APIUserPresenceSigner())

        await #expect(throws: APIError.self) {
            _ = try await client.enrollPresenceKey(
                route: URL(string: "https://spark.local:7443")!,
                idempotencyKey: UUID(),
                userPresence: APIUserPresenceSession()
            )
        }
    }

    @Test func kokoroControlsUsePresenceAndSpeechSignsOnlyTheRequestedText() async throws {
        let base = URL(string: "https://spark.local:7443")!
        let client = try makeClient(signer: APIUserPresenceSigner())
        for action in [KokoroServiceAction.install, .update, .enable, .disable] {
            let path = "/api/v1/services/kokoro/" + action.rawValue
            MockURLProtocol.responses = [
                path: .success(
                    Data(
                        "{\"id\":\"10000000-0000-4000-8000-000000000001\",\"kind\":\"service.kokoro.install\",\"state\":\"requested\",\"cancellable\":false}"
                            .utf8
                    )
                )
            ]
            let key = UUID()
            _ = try await client.changeKokoro(
                route: base,
                action: action,
                idempotencyKey: key,
                userPresence: APIUserPresenceSession()
            )
            let request = try #require(MockURLProtocol.lastRequest)
            #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == key.uuidString)
            #expect(request.value(forHTTPHeaderField: "X-Spark-User-Presence") != nil)
            #expect(request.value(forHTTPHeaderField: "X-Spark-Signature") != nil)
        }
        var wav = Data("RIFF".utf8) + Data(repeating: 0, count: 4) + Data("WAVE".utf8)
        wav.append(Data(repeating: 0, count: 32))
        MockURLProtocol.responses = ["/v1/audio/speech": .success(wav)]
        #expect(
            try await client.speech(route: base, text: "A spoken reply", voice: "af_heart") == wav
        )
        let request = try #require(MockURLProtocol.lastRequest)
        let body = try #require(MockURLProtocol.lastBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(json.keys) == ["model", "input", "voice", "response_format", "speed"])
        #expect(json["input"] as? String == "A spoken reply")
        #expect(request.value(forHTTPHeaderField: "X-Spark-Signature") != nil)
        #expect(request.value(forHTTPHeaderField: "Accept") == "audio/wav")
    }
}
