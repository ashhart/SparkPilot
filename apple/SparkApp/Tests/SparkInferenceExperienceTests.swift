import Foundation
import SparkAPI
import Testing

@testable import SparkAppComposition

private func inferenceTelemetry(
    observedAt: String = "2026-08-31T09:00:00Z",
    usageDay: String = "2026-08-31",
    requests: Int64 = 40,
    promptTokens: Int64 = 2_000,
    generatedTokens: Int64 = 750,
    totalTokens: Int64 = 2_750,
    queueDepth: Int? = 3,
    tokensPerSecond: Double? = 28.5,
    timeToFirstTokenMs: Double? = 180,
    engines: String = "[]"
) throws -> TelemetrySnapshot {
    let queue = queueDepth.map(String.init) ?? "null"
    let throughput = tokensPerSecond.map { String($0) } ?? "null"
    let ttft = timeToFirstTokenMs.map { String($0) } ?? "null"
    let json = """
        {"api_version":1,"observed_at":"\(observedAt)",
        "node_id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","node_name":"private-host",
        "system":{"cpu_utilisation":0.27,"load_average_1m":1.4,
        "unified_memory_total_bytes":137438953472,
        "unified_memory_available_bytes":68719476736,
        "unified_memory_used_bytes":68719476736,"memory_pressure":"normal",
        "memory_psi_some_avg10":0.12,"memory_psi_full_avg10":0.02,
        "temperature_celsius":54,"power_state":"normal","uptime_seconds":86460},
        "accelerator":{"utilisation":0.64,"temperature_celsius":55,
        "power_draw_watts":49.5,"power_limit_watts":140,
        "memory_used_bytes":25769803776,"memory_total_bytes":137438953472},
        "storage":{"total_bytes":1000000000000,"free_bytes":400000000000,
        "used_bytes":600000000000},
        "usage":{"day":"\(usageDay)","requests":\(requests),"failures":1,
        "prompt_tokens":\(promptTokens),"cached_prompt_tokens":100,
        "generated_tokens":\(generatedTokens),"reasoning_tokens":0,
        "total_tokens":\(totalTokens)},
        "inference":{"state":"ready","model_id":"open/model-8b",
        "profile_id":"balanced","context_length":32768,"active_requests":2,
        "queue_depth":\(queue),"tokens_per_second":\(throughput),
        "time_to_first_token_ms":\(ttft)},"engines":\(engines)}
        """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(TelemetrySnapshot.self, from: Data(json.utf8))
}

@Test func externalVllmMetricsDriveTheServingPanelWithoutUsingProxyTotals() throws {
    let engines = """
        [{"workload_id":"external-vllm","engine":"vllm",
        "ownership":"external_observed","availability":"live",
        "observed_at":"2026-08-31T09:00:00Z","sample_age_seconds":0,
        "served_model":"deepseek-r1","engine_uptime_seconds":7200,
        "total_requests":50,"prompt_tokens":10000,"generated_tokens":5000,
        "total_tokens":15000,"running_requests":4,"queue_depth":2,
        "prompt_tokens_per_second":80,"generation_tokens_per_second":25,
        "request_latency_ms":410,"time_to_first_token_ms":95,
        "time_per_output_token_ms":14}]
        """
    let sample = SparkInferenceExperienceAdapter().sample(
        telemetry: try inferenceTelemetry(engines: engines),
        activeInference: nil,
        models: [],
        workloads: inventory([workload(ownership: .externalObserved, engine: .vllm)]),
        previous: nil
    )

    #expect(sample.engine == .vllm)
    #expect(sample.ownership == .external)
    #expect(sample.state == "serving")
    #expect(sample.modelID == "deepseek-r1")
    #expect(sample.engineUptimeSeconds == 7_200)
    #expect(sample.requestCount == 50)
    #expect(sample.promptTokens == 10_000)
    #expect(sample.generatedTokens == 5_000)
    #expect(sample.totalTokens == 15_000)
    #expect(sample.activeRequests == 4)
    #expect(sample.queueDepth == 2)
    #expect(sample.promptTokensPerSecond == 80)
    #expect(sample.generatedTokensPerSecond == 25)
    #expect(sample.tokensPerSecond == 25)
    #expect(sample.averageLatencyMilliseconds == 410)
    #expect(sample.timeToFirstTokenMilliseconds == 95)
    #expect(sample.timePerOutputTokenMilliseconds == 14)
    #expect(sample.metricsAvailability == "live")
    #expect(
        SparkInferenceExperiencePresentation.sourceLabel(
            availability: sample.metricsAvailability,
            ageSeconds: sample.metricsSampleAgeSeconds,
            transportIsLive: true
        ) == "Live"
    )
}

@Test func unsupportedEngineMetricsNeverFallBackToUnrelatedSparkPilotUsage() throws {
    let engines = """
        [{"workload_id":"external-sglang","engine":"sglang",
        "ownership":"external_observed","availability":"unsupported",
        "observed_at":null,"sample_age_seconds":null,"served_model":null,
        "engine_uptime_seconds":null,"total_requests":null,"prompt_tokens":null,
        "generated_tokens":null,"total_tokens":null,"running_requests":null,
        "queue_depth":null,"prompt_tokens_per_second":null,
        "generation_tokens_per_second":null,"request_latency_ms":null,
        "time_to_first_token_ms":null,"time_per_output_token_ms":null}]
        """
    let sample = SparkInferenceExperienceAdapter().sample(
        telemetry: try inferenceTelemetry(engines: engines),
        activeInference: nil,
        models: [],
        workloads: inventory([workload(ownership: .externalObserved, engine: .sglang)]),
        previous: nil
    )

    #expect(sample.state == "unavailable")
    #expect(sample.promptTokens == nil)
    #expect(sample.generatedTokens == nil)
    #expect(sample.totalTokens == nil)
    #expect(sample.requestCount == nil)
    #expect(sample.queueDepth == nil)
    #expect(sample.metricsAvailability == "unsupported")
    #expect(
        SparkInferenceExperiencePresentation.sourceLabel(
            availability: sample.metricsAvailability,
            ageSeconds: nil,
            transportIsLive: true
        ) == "Metrics unavailable"
    )
}

private func workload(
    ownership: GeneratedAPI.WorkloadOwnership,
    engine: GeneratedAPI.WorkloadEngine
) -> GeneratedAPI.ObservedWorkload {
    GeneratedAPI.ObservedWorkload(
        workloadId: "container-id",
        name: "private-container-name",
        ownership: ownership,
        kind: .inferenceEngine,
        recognisedEngine: engine,
        state: .running,
        imageReference: "private/image:tag",
        publishedPorts: []
    )
}

private func inventory(
    _ workloads: [GeneratedAPI.ObservedWorkload]
) -> GeneratedAPI.WorkloadInventory {
    .init(
        observedAt: "2026-08-31T09:00:00Z",
        available: true,
        adoptionSupported: false,
        truncated: false,
        workloads: workloads
    )
}

@Test func adapterShowsExternallyManagedSGLangWithoutOfferingControl() throws {
    let sample = SparkInferenceExperienceAdapter().sample(
        telemetry: try inferenceTelemetry(),
        activeInference: nil,
        models: [],
        workloads: inventory([workload(ownership: .externalObserved, engine: .sglang)]),
        previous: nil
    )

    #expect(sample.engine == .sglang)
    #expect(sample.ownership == .external)
    #expect(sample.ownership.allowsLifecycleControl == false)
    #expect(sample.modelDisplayName == nil)
    #expect(sample.promptTokens == 2_000)
    #expect(sample.generatedTokens == 750)
    #expect(sample.totalTokens == 2_750)
    #expect(sample.averageLatencyMilliseconds == nil)
}

@Test func adapterCalculatesRequestRateOnlyFromComparableCounters() throws {
    let adapter = SparkInferenceExperienceAdapter()
    let first = adapter.sample(
        telemetry: try inferenceTelemetry(requests: 40),
        activeInference: nil,
        models: [],
        workloads: nil,
        previous: nil
    )
    let second = adapter.sample(
        telemetry: try inferenceTelemetry(
            observedAt: "2026-08-31T09:01:00Z",
            requests: 46
        ),
        activeInference: nil,
        models: [],
        workloads: nil,
        previous: first
    )
    let reset = adapter.sample(
        telemetry: try inferenceTelemetry(
            observedAt: "2026-08-31T09:02:00Z",
            requests: 2
        ),
        activeInference: nil,
        models: [],
        workloads: nil,
        previous: second
    )
    let nextDay = adapter.sample(
        telemetry: try inferenceTelemetry(
            observedAt: "2026-09-01T00:01:00Z",
            usageDay: "2026-09-01",
            requests: 100
        ),
        activeInference: nil,
        models: [],
        workloads: nil,
        previous: second
    )

    #expect(first.requestsPerMinute == nil)
    #expect(second.requestsPerMinute == 6)
    #expect(reset.requestsPerMinute == nil)
    #expect(nextDay.requestsPerMinute == nil)
}

@Test func missingMetricsRemainUnavailableInsteadOfBecomingZero() throws {
    let sample = SparkInferenceExperienceAdapter().sample(
        telemetry: try inferenceTelemetry(
            queueDepth: nil,
            tokensPerSecond: nil,
            timeToFirstTokenMs: nil
        ),
        activeInference: nil,
        models: [],
        workloads: nil,
        previous: nil
    )

    #expect(sample.queueDepth == nil)
    #expect(sample.tokensPerSecond == nil)
    #expect(sample.timeToFirstTokenMilliseconds == nil)
    #expect(
        SparkInferenceExperiencePresentation.queuedRequests(sample.queueDepth)
            == "Not reported"
    )
}

@MainActor
@Test func localHistoryIsBoundedDeduplicatedAndContainsNoHostDetails() throws {
    let suite = "inference-history-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UserDefaultsSparkInferenceHistoryStore(defaults: defaults, limit: 3)
    let adapter = SparkInferenceExperienceAdapter()

    for minute in 0..<4 {
        let sample = adapter.sample(
            telemetry: try inferenceTelemetry(
                observedAt: "2026-08-31T09:0\(minute):00Z",
                requests: Int64(minute)
            ),
            activeInference: nil,
            models: [],
            workloads: nil,
            previous: nil
        )
        try store.save(sample, targetID: "node:stable-id")
        try store.save(sample, targetID: "node:stable-id")
    }

    let saved = try store.load(targetID: "node:stable-id")
    #expect(saved.count == 3)
    #expect(saved.map(\.requestCount) == [1, 2, 3])
    let encoded = try JSONEncoder().encode(saved)
    let text = try #require(String(data: encoded, encoding: .utf8))
    #expect(!text.contains("private-host"))
    #expect(!text.contains("private-container-name"))
    #expect(!text.contains("private/image"))
}

@MainActor
@Test func localHistoryKeepsOneLatestPointPerMinuteAcrossRelaunch() throws {
    let suite = "inference-history-buckets-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let adapter = SparkInferenceExperienceAdapter()
    let store = UserDefaultsSparkInferenceHistoryStore(defaults: defaults)

    let first = adapter.sample(
        telemetry: try inferenceTelemetry(
            observedAt: "2026-08-31T09:00:01Z",
            requests: 4
        ),
        activeInference: nil,
        models: [],
        workloads: nil,
        previous: nil
    )
    let latestInMinute = adapter.sample(
        telemetry: try inferenceTelemetry(
            observedAt: "2026-08-31T09:00:58Z",
            requests: 9
        ),
        activeInference: nil,
        models: [],
        workloads: nil,
        previous: first
    )
    try store.save(first, targetID: "node:stable-id")
    try store.save(first, targetID: "node:stable-id")
    try store.save(latestInMinute, targetID: "node:stable-id")

    let relaunched = UserDefaultsSparkInferenceHistoryStore(defaults: defaults)
    let saved = try relaunched.load(targetID: "node:stable-id")
    #expect(saved.count == 1)
    #expect(saved.first?.requestCount == 9)
    #expect(saved.first?.observedAt == latestInMinute.observedAt)
}

@MainActor
@Test func localHistoryDropsPointsOutsideItsTwentyFourHourWindow() throws {
    let suite = "inference-history-window-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let adapter = SparkInferenceExperienceAdapter()
    let store = UserDefaultsSparkInferenceHistoryStore(defaults: defaults)
    let old = adapter.sample(
        telemetry: try inferenceTelemetry(observedAt: "2026-08-29T09:00:00Z"),
        activeInference: nil,
        models: [],
        workloads: nil,
        previous: nil
    )
    let current = adapter.sample(
        telemetry: try inferenceTelemetry(observedAt: "2026-08-31T09:00:00Z"),
        activeInference: nil,
        models: [],
        workloads: nil,
        previous: nil
    )

    try store.save(old, targetID: "node:stable-id")
    try store.save(current, targetID: "node:stable-id")

    #expect(try store.load(targetID: "node:stable-id") == [current])
}
