import CryptoKit
import Foundation
import SparkCore
import SparkSecurity
@_spi(SparkTestSupport) @_spi(SparkInternal) import SparkTransport
import Testing
@_spi(SparkTestSupport) @testable import SparkAPI

// MARK: - Remote access

/// Remote status fixtures for every contract value, as sparkd serves them.
@Test func decodesRemoteStatusForEveryMode() throws {
    func decode(_ json: String) throws -> RemoteStatus {
        try JSONDecoder().decode(RemoteStatus.self, from: Data(json.utf8))
    }

    let disabled = try decode(
        #"{"enabled":false,"mode":"disabled","health":"disabled"}"#
    )
    #expect(!disabled.enabled)
    #expect(disabled.mode == .disabled)
    #expect(disabled.hostname == nil)

    let overlay = try decode(
        #"{"enabled":true,"mode":"private_overlay","health":"healthy","hostname":"100.96.4.2","available_modes":["private_overlay"],"private_overlay_provider":"tailscale"}"#
    )
    #expect(overlay.mode == .privateOverlay)
    #expect(overlay.availableModes == [.privateOverlay])
    #expect(overlay.privateOverlayProvider == "tailscale")

    let degraded = try decode(
        #"{"enabled":true,"mode":"private_overlay","health":"degraded","hostname":"a7f2.spark.example"}"#
    )
    #expect(degraded.health == .degraded)
}

/// The setup document carries the MagicDNS name and address, and only Tailscale's own sign-in origin survives decoding.
@Test func decodesRemoteOverlaySetupAndTheOverlayAddress() throws {
    let waiting = try JSONDecoder().decode(
        RemoteOverlaySetup.self,
        from: Data(
            #"{"provider":"tailscale","state":"login_required","authorization_url":"https://login.tailscale.com/a/0123456789abcdef","hostname":null,"address":null,"tailnet":null,"installable":null,"detail":null}"#
                .utf8
        )
    )
    #expect(waiting.state == .loginRequired)
    #expect(waiting.needsOwner)
    #expect(
        waiting.authorizationURL?.absoluteString
            == "https://login.tailscale.com/a/0123456789abcdef"
    )

    let ready = try JSONDecoder().decode(
        RemoteOverlaySetup.self,
        from: Data(
            #"{"provider":"tailscale","state":"ready","hostname":"spark-example.tail1234.ts.net","address":"100.96.4.2","tailnet":"tail1234.ts.net"}"#
                .utf8
        )
    )
    #expect(ready.state == .ready)
    #expect(!ready.needsOwner)
    #expect(ready.hostname == "spark-example.tail1234.ts.net")
    #expect(ready.address == "100.96.4.2")

    for link in [
        "https://login.tailscale.com.evil.example/a/0123",
        "http://login.tailscale.com/a/0123",
        "https://login.tailscale.com/a/0123?next=x",
        "https://login.tailscale.com/admin",
        "https://user@login.tailscale.com/a/0123",
    ] {
        let forged = try JSONDecoder().decode(
            RemoteOverlaySetup.self,
            from: Data(
                #"{"provider":"tailscale","state":"login_required","authorization_url":"\#(link)"}"#
                    .utf8
            )
        )
        #expect(forged.authorizationURL == nil, "\(link) must never be offered as a sign-in link")
    }

    let status = try JSONDecoder().decode(
        RemoteStatus.self,
        from: Data(
            #"{"enabled":true,"mode":"private_overlay","health":"healthy","hostname":"spark-example.tail1234.ts.net","available_modes":["private_overlay"],"private_overlay_provider":"tailscale","private_overlay_address":"100.96.4.2"}"#
                .utf8
        )
    )
    #expect(status.hostname == "spark-example.tail1234.ts.net")
    #expect(status.privateOverlayAddress == "100.96.4.2")
}

/// Encode only the private mode and accepted review digest.
@Test func remoteEnableRequestEncodesContractFieldNames() throws {
    let encoded = try JSONEncoder().encode(
        EnableRemoteRequest(
            mode: .privateOverlay,
            acceptedPreviewDigest: String(repeating: "a", count: 64)
        )
    )
    let json = try JSONDecoder().decode([String: String].self, from: encoded)
    #expect(json["mode"] == "private_overlay")
    #expect(Set(json.keys) == ["mode", "accepted_preview_digest"])
    #expect(json["accepted_preview_digest"] == String(repeating: "a", count: 64))

    let none = try JSONEncoder().encode(
        EnableRemoteRequest(
            mode: .privateOverlay,
            acceptedPreviewDigest: String(repeating: "b", count: 64)
        )
    )
    let noneJSON = try JSONDecoder().decode([String: String].self, from: none)
    #expect(noneJSON["registration_token"] == nil)
}

/// The accepted-operation body (202) decodes into the typed Operation.
@Test func decodesAcceptedRemoteOperation() throws {
    let json = """
        {"id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","kind":"remote.enable",
         "state":"running","actor_device_id":"7a836150-16e1-46b5-8ac0-32b2a5f2f820",
         "resource_id":null,"progress":null,"stage":null,
         "created_at":"2026-08-26T12:00:00Z","updated_at":"2026-08-26T12:00:00Z",
         "started_at":null,"completed_at":null,"error_code":null,"result":null,
         "cancellable":true}
        """
    let operation = try JSONDecoder().decode(Operation.self, from: Data(json.utf8))
    #expect(operation.kind == "remote.enable")
    #expect(operation.state == .running)
    #expect(operation.cancellable)
    #expect(
        operation.actorDeviceID?.uuidString.lowercased() == "7a836150-16e1-46b5-8ac0-32b2a5f2f820"
    )
    // 2026-08-26T12:00:00Z.
    #expect(operation.createdAt == Date(timeIntervalSince1970: 1_787_745_600))
    #expect(operation.startedAt == nil)
}

/// Decode a real nanosecond runtime timestamp without losing the operations response.
@Test func decodesTheNanosecondTimestampsASparkActuallySends() throws {
    let json = """
        {"id":"9a2f3f0e-6a8a-4c62-9b3f-2f1c8f1b0d11","kind":"model.load",
         "state":"succeeded","actor_device_id":"56023716-f3a4-472f-a49d-a79fbea349af",
         "resource_id":null,"progress":1.0,"stage":"ready",
         "created_at":"2026-09-03T17:00:59.904229029Z",
         "updated_at":"2026-09-03T17:04:03.120280692Z",
         "started_at":"2026-09-03T17:00:59.912000000Z",
         "completed_at":"2026-09-03T17:04:03.120280692Z",
         "error_code":null,"result":null,"cancellable":false}
        """
    let decoder = JSONDecoder()
    // Use the API client's date-decoding strategy for the fixture.
    decoder.dateDecodingStrategy = .iso8601
    let operation = try decoder.decode(Operation.self, from: Data(json.utf8))
    let created = try #require(operation.createdAt)
    let completed = try #require(operation.completedAt)
    #expect(abs(completed.timeIntervalSince(created) - 183.216) < 0.001)
}

/// Keep operations usable when optional timestamps are missing or malformed.
@Test func anUnreadableTimestampDoesNotFailTheOperation() throws {
    let json = """
        {"id":"9a2f3f0e-6a8a-4c62-9b3f-2f1c8f1b0d11","kind":"model.load",
         "state":"running","created_at":"the day before yesterday",
         "cancellable":true}
        """
    let operation = try JSONDecoder().decode(Operation.self, from: Data(json.utf8))
    #expect(operation.state == .running)
    #expect(operation.createdAt == nil)
    #expect(operation.actorDeviceID == nil)
}

/// Decode every cluster state and member shape through the shared contract types.
@Test func decodesClusterStatus() throws {
    func decode(_ json: String) throws -> ClusterStatus {
        try JSONDecoder().decode(ClusterStatus.self, from: Data(json.utf8))
    }

    let standalone = try decode(#"{"state":"standalone","members":[]}"#)
    #expect(standalone.state == "standalone")
    #expect(standalone.id == nil)

    let ready = try decode(
        """
        {"id":"6cc82f6e-1234-5678-9abc-def012345678","name":"Studio pair","state":"ready",
         "members":[{"node_id":"7a836150-16e1-46b5-8ac0-32b2a5f2f820","name":"Spark A","role":"leader","reachable":true,"qsfp_health":"healthy"},
                    {"node_id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","name":"Spark B","role":"worker","reachable":false,"qsfp_health":null}]}
        """
    )
    #expect(ready.state == "ready")
    #expect(ready.members.count == 2)
    #expect(ready.members[0].role == "leader")
    #expect(ready.members[0].qsfpHealth == "healthy")
    #expect(ready.members[1].reachable == false)

    let degraded = try decode(
        #"{"state":"degraded","members":[{"node_id":"7a836150-16e1-46b5-8ac0-32b2a5f2f820","name":"A","role":"leader","reachable":true}]}"#
    )
    #expect(degraded.state == "degraded")
}
