import CryptoKit
import Foundation
import SparkCore
import SparkSecurity
@_spi(SparkTestSupport) @_spi(SparkInternal) import SparkTransport
import Testing
@_spi(SparkTestSupport) @testable import SparkAPI

extension SparkAPITests {
    @Test func decodesHealthAsServedByRuntime() async throws {
        MockURLProtocol.responses = [
            "/api/v1/health": .success(Data(healthFixture.utf8))
        ]
        let client = try makeClient()
        let health = try await client.health(route: URL(string: "https://spark.local:7443")!)
        #expect(health.isOK)
        #expect(health.apiVersion == 1)
        #expect(health.runtimeVersion == "0.1.0")
        #expect(health.nodeID.rawValue == UUID(uuidString: "63e82da2-7fb7-4b4b-9584-4a528000ac94"))
    }

    /// Treat unknown or absent capability flags as unavailable.
    @Test func decodesCapabilitiesAndFailsClosedOnUnknownFeatures() async throws {
        let payload =
            #"{"api_version":1,"features":{"container_runtime":false,"loopback_only":true,"signed_catalogue":true},"limits":{"engine_backend":"docker","max_active_large_models":1}}"#
        MockURLProtocol.responses = [
            "/api/v1/capabilities": .success(Data(payload.utf8))
        ]
        let client = try makeClient()
        let capabilities = try await client.capabilities(
            route: URL(string: "https://spark.local:7443")!
        )

        #expect(capabilities.apiVersion == 1)
        #expect(capabilities.isEnabled("container_runtime") == false)
        #expect(capabilities.isEnabled("loopback_only"))
        #expect(capabilities.isEnabled("signed_catalogue"))
        // A capability this build never published is unavailable, not assumed.
        #expect(capabilities.isEnabled("optional_service_recipes") == false)
        #expect(capabilities.isEnabled("") == false)
    }

    @Test func decodesStatusContractExample() async throws {
        MockURLProtocol.responses = [
            "/api/v1/status": .success(Data(statusFixture.utf8))
        ]
        let client = try makeClient()
        let status = try await client.status(route: URL(string: "https://spark.local:7443")!)

        #expect(status.apiVersion == 1)
        #expect(status.identity.name == "Alex's Spark")
        #expect(status.identity.role == "standalone")
        #expect(status.identity.authorityFingerprint == "t9lNEpIu94qMhG3XG2ThMg")
        #expect(
            status.identity.tlsFingerprint
                == "a9f2c76194a56b80372c67d874306e4f40d3b0a8c77aeb7314e23422989b3a10"
        )
        #expect(status.system.unifiedMemoryTotalBytes == 137_438_953_472)
        #expect(status.system.unifiedMemoryAvailableBytes == 28_743_895_347)
        #expect(status.system.memoryPressure == "normal")
        #expect(status.system.pressure == .normal)
        #expect(status.inference.state == "ready")
        #expect(status.inference.modelID == "example/model-32b")
        #expect(status.inference.tokensPerSecond == 41.8)
        #expect(status.cluster == nil)

        let generated = try JSONDecoder().decode(
            GeneratedAPI.Status.self,
            from: Data(statusFixture.utf8)
        )
        #expect(generated.connection?.serverObservedTransport == .unclassified)
        #expect(generated.connection?.accessAuthentication == .deviceSignature)
        #expect(generated.connection?.remoteAccess == .disabled)

        var legacyObject = try #require(
            JSONSerialization.jsonObject(with: Data(statusFixture.utf8))
                as? [String: Any]
        )
        var legacyConnection = try #require(legacyObject["connection"] as? [String: Any])
        legacyConnection["server_observed_transport"] = "ethernet"
        legacyConnection.removeValue(forKey: "access_authentication")
        legacyObject["connection"] = legacyConnection
        let legacyV1 = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacy = try JSONDecoder().decode(
            GeneratedAPI.Status.self,
            from: legacyV1
        )
        #expect(legacy.connection?.serverObservedTransport == .ethernet)
        #expect(legacy.connection?.accessAuthentication == nil)
    }

    @Test func decodesLiveTelemetryFromTheDedicatedRoute() async throws {
        MockURLProtocol.responses = [
            "/api/v1/telemetry": .success(Data(telemetryFixture.utf8))
        ]
        let client = try makeClient()
        let telemetry = try await client.telemetry(
            route: URL(string: "https://spark.local:7443")!
        )

        #expect(telemetry.nodeName == "Alex's Spark")
        #expect(telemetry.system.cpuUtilisation == 0.27)
        #expect(telemetry.accelerator.utilisation == 0.64)
        #expect(telemetry.accelerator.temperatureCelsius == 55)
        #expect(telemetry.accelerator.powerDrawWatts == 49.5)
        #expect(telemetry.accelerator.memoryUsedBytes == 25_769_803_776)
        #expect(telemetry.accelerator.memoryTotalBytes == 137_438_953_472)
        #expect(telemetry.system.memoryPSISomeAvg10 == 0.12)
        #expect(telemetry.system.memoryPSIFullAvg10 == 0.02)
        #expect(telemetry.storage.usedBytes == 600_000_000_000)
        #expect(telemetry.usage.requests == 12)
        #expect(telemetry.usage.totalTokens == 800)
        #expect(telemetry.inference.queueDepth == 1)
        #expect(telemetry.inference.tokensPerSecond == 42.5)
        #expect(telemetry.engines.isEmpty)
    }

    @Test func unavailableLiveCountersDecodeAsUnavailableRatherThanZero() throws {
        let json = telemetryFixture.replacingOccurrences(
            of: #""queue_depth": 1"#,
            with: #""queue_depth": null"#
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let telemetry = try decoder.decode(TelemetrySnapshot.self, from: Data(json.utf8))

        #expect(telemetry.inference.queueDepth == nil)
    }

    @Test func decodesExistingEngineMetricsWithoutInventingMissingCounters() throws {
        var object = try #require(
            JSONSerialization.jsonObject(with: Data(telemetryFixture.utf8))
                as? [String: Any]
        )
        object["engines"] = [
            [
                "workload_id": "1a3b",
                "engine": "vllm",
                "ownership": "external_observed",
                "availability": "live",
                "observed_at": "2026-08-29T00:15:00Z",
                "sample_age_seconds": 0,
                "served_model": "deepseek-ai/DeepSeek-R1",
                "engine_uptime_seconds": 7_860,
                "total_requests": 1_200,
                "prompt_tokens": 500_000,
                "generated_tokens": 250_000,
                "total_tokens": 750_000,
                "running_requests": 2,
                "queue_depth": 1,
                "prompt_tokens_per_second": 88.5,
                "generation_tokens_per_second": 42.25,
                "request_latency_ms": 940,
                "time_to_first_token_ms": 210,
                "time_per_output_token_ms": NSNull(),
            ]
        ]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let telemetry = try decoder.decode(
            TelemetrySnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        let engine = try #require(telemetry.engines.first)

        #expect(engine.engine == "vllm")
        #expect(engine.ownership == "external_observed")
        #expect(engine.servedModel == "deepseek-ai/DeepSeek-R1")
        #expect(engine.promptTokens == 500_000)
        #expect(engine.generatedTokens == 250_000)
        #expect(engine.generationTokensPerSecond == 42.25)
        #expect(engine.timePerOutputTokenMs == nil)
    }

    /// Decode known pressure values and tolerate future values as nil (§60).
    @Test func typedPressureCoversTheContractEnum() throws {
        func system(pressure: String) throws -> SystemStatus {
            let json = """
                {"unified_memory_total_bytes":137438953472,"unified_memory_available_bytes":28743895347,
                 "memory_pressure":"\(pressure)","cpu_utilisation":0.18,"disk_free_bytes":91827364512,
                 "uptime_seconds":123456,"temperature_celsius":null}
                """
            return try JSONDecoder().decode(SystemStatus.self, from: Data(json.utf8))
        }

        #expect(try system(pressure: "normal").pressure == .normal)
        #expect(try system(pressure: "warning").pressure == .warning)
        #expect(try system(pressure: "critical").pressure == .critical)
        #expect(try system(pressure: "emergency").pressure == .emergency)
        #expect(try system(pressure: "something-new").pressure == nil)
    }

    @Test func routeProbeAcceptsMatchingNode() async throws {
        MockURLProtocol.responses = [
            "/api/v1/health": .success(Data(healthFixture.utf8))
        ]
        let expected = SparkNodeID(
            rawValue: UUID(uuidString: "63e82da2-7fb7-4b4b-9584-4a528000ac94")!
        )
        let probe = try makeProbe()
        let route = SparkRoute(
            nodeID: expected,
            baseURL: URL(string: "https://spark.local:7443")!,
            kind: .localWiFi,
            interfaceName: nil,
            validatedIdentityFingerprint: "abc"
        )
        let result = await probe.validate(route: route, expectedNodeID: expected)
        #expect(result == .accepted(nodeID: expected, apiVersion: 1, runtimeVersion: "0.1.0"))
    }
    /// The unload verdict travels with active inference so the app can show memory that did not come back (M-6).
    @Test func activeInferenceDecodesTheLastUnloadVerdict() throws {
        let json =
            #"{"state":"unloaded","model_id":null,"profile_id":null,"context_length":null,"active_requests":0,"queue_depth":0,"tokens_per_second":null,"time_to_first_token_ms":null,"last_unload":{"model_id":"nvidia/model","memory_recovered":false,"baseline_bytes":257698037760,"available_bytes":42949672960,"finished_at":"2026-09-04T22:00:00Z"}}"#
        let active = try JSONDecoder().decode(ActiveInference.self, from: Data(json.utf8))
        let evidence = try #require(active.lastUnload)
        #expect(!evidence.memoryRecovered)
        #expect(evidence.shortfallBytes == 257_698_037_760 - 42_949_672_960)
        let older =
            #"{"state":"idle","model_id":"m","profile_id":null,"context_length":null,"active_requests":0,"queue_depth":0,"tokens_per_second":null,"time_to_first_token_ms":null}"#
        #expect(
            try JSONDecoder().decode(ActiveInference.self, from: Data(older.utf8)).lastUnload == nil
        )
    }
}
