import Foundation
@_spi(SparkTestSupport) import SparkAPI
import SparkBootstrap
import SparkCore
import SparkDesignSystem
import SparkDiscovery
import SparkLibrary
import SparkSecurity
@_spi(SparkTestSupport) import SparkTransport
import Testing
@testable import SparkAppComposition

let settingsCompositionTestSettingsTelemetryNodeID = SparkNodeID(
    rawValue: UUID(uuidString: "63e82da2-7fb7-4b4b-9584-4a528000ac94")!
)

enum SettingsCompositionTestSettingsTelemetryTestError: Error {
    case summaryUnavailable
    case unused
}

final class SettingsCompositionTestSettingsPresenceSession: UserPresenceProofSigning,
    @unchecked Sendable
{
    private let signer = SoftwareSigner()

    lazy var keyInfo = UserPresenceKeyInfo(
        publicKeySPKI: signer.publicKeySPKI,
        protection: .softwareTestOnly
    )

    func proof(for request: UserPresenceCanonicalRequest) async throws -> UserPresenceProof {
        try UserPresenceProof.sign(request) { try signer.sign($0) }
    }
}

actor SettingsCompositionTestSettingsPresenceAuthorizer: UserPresenceAuthorizing {
    private let session = SettingsCompositionTestSettingsPresenceSession()

    func keyInfo() async throws -> UserPresenceKeyInfo { session.keyInfo }

    func authorize(localizedReason: String) async throws -> any UserPresenceProofSigning {
        session
    }
}

struct SettingsCompositionTestTelemetryFixtureTransport: PinnedHTTPTransport {
    let pin = String(repeating: "a", count: 64)

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        #expect(request.url?.path == "/api/v1/telemetry")
        let body = Data(
            #"{"api_version":1,"observed_at":"2026-08-29T12:00:00Z","node_id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","node_name":"Workshop Spark","system":{"cpu_utilisation":0.27,"load_average_1m":1.4,"unified_memory_total_bytes":137438953472,"unified_memory_available_bytes":68719476736,"unified_memory_used_bytes":68719476736,"memory_pressure":"normal","temperature_celsius":54,"power_state":"normal","uptime_seconds":120},"accelerator":{"utilisation":0.64,"temperature_celsius":55,"power_draw_watts":49.5,"power_limit_watts":140},"storage":{"total_bytes":1000000000000,"free_bytes":400000000000,"used_bytes":600000000000},"usage":{"day":"2026-08-29","requests":0,"failures":0,"prompt_tokens":0,"cached_prompt_tokens":0,"generated_tokens":0,"reasoning_tokens":0,"total_tokens":0},"inference":{"state":"unloaded","model_id":null,"profile_id":null,"context_length":null,"active_requests":0,"queue_depth":0,"tokens_per_second":null,"time_to_first_token_ms":null}}"#
                .utf8
        )
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        return (body, response)
    }
}

actor SettingsCompositionTestSettingsTelemetryIdentityResolver: AuthenticatedIdentityResolving {
    func resolveIdentity(
        route: URL,
        expectedNodeID: SparkNodeID?
    ) async throws -> AuthenticatedIdentity {
        #expect(expectedNodeID == settingsCompositionTestSettingsTelemetryNodeID)
        let json =
            #"{"node_id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","cluster_id":null,"name":"Workshop Spark","role":"standalone","authority_fingerprint":"authority-a","runtime_version":"0.1.0","dgx_os_version":"7.0"}"#
        return AuthenticatedIdentity(
            identity: try JSONDecoder().decode(SparkIdentity.self, from: Data(json.utf8))
        )
    }
}
