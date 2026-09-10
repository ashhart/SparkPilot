import Foundation
import SparkAPI
import Testing

@testable import SparkAppComposition

/// Exercises partial telemetry using nullable JSON fields that match runtime response fixtures.
private func telemetry(
    cpuUtilisation: String = "0.27",
    loadAverage: String = "1.4",
    unifiedTotal: String = "137438953472",
    unifiedAvailable: String = "68719476736",
    unifiedUsed: String = "68719476736",
    memoryPressure: String = "normal",
    psiSome: String = "0.12",
    psiFull: String = "0.02",
    systemTemperature: String = "54",
    uptimeSeconds: String = "120",
    acceleratorUtilisation: String = "0.64",
    acceleratorTemperature: String = "55",
    powerDrawWatts: String = "49.5",
    acceleratorMemoryUsed: String = "25769803776",
    acceleratorMemoryTotal: String = "137438953472",
    storageTotal: String = "1000000000000",
    storageFree: String = "400000000000",
    storageUsed: String = "600000000000",
    requests: String = "12",
    failures: String = "1",
    totalTokens: String = "800",
    inferenceState: String = "ready",
    activeRequests: String = "2",
    queueDepth: String = "1",
    tokensPerSecond: String = "42.5"
) throws -> TelemetrySnapshot {
    let json = """
        {"api_version":1,"observed_at":"2026-08-29T00:15:00Z",
        "node_id":"63e82da2-7fb7-4b4b-9584-4a528000ac94","node_name":"My Spark",
        "system":{"cpu_utilisation":\(cpuUtilisation),"load_average_1m":\(loadAverage),
        "unified_memory_total_bytes":\(unifiedTotal),
        "unified_memory_available_bytes":\(unifiedAvailable),
        "unified_memory_used_bytes":\(unifiedUsed),"memory_pressure":"\(memoryPressure)",
        "memory_psi_some_avg10":\(psiSome),"memory_psi_full_avg10":\(psiFull),
        "temperature_celsius":\(systemTemperature),"power_state":"normal",
        "uptime_seconds":\(uptimeSeconds)},
        "accelerator":{"utilisation":\(acceleratorUtilisation),
        "temperature_celsius":\(acceleratorTemperature),"power_draw_watts":\(powerDrawWatts),
        "power_limit_watts":140,"memory_used_bytes":\(acceleratorMemoryUsed),
        "memory_total_bytes":\(acceleratorMemoryTotal)},
        "storage":{"total_bytes":\(storageTotal),"free_bytes":\(storageFree),
        "used_bytes":\(storageUsed)},
        "usage":{"day":"2026-08-29","requests":\(requests),"failures":\(failures),
        "prompt_tokens":500,"cached_prompt_tokens":100,"generated_tokens":250,
        "reasoning_tokens":50,"total_tokens":\(totalTokens)},
        "inference":{"state":"\(inferenceState)","model_id":"open/model-8b",
        "profile_id":"balanced","context_length":32768,"active_requests":\(activeRequests),
        "queue_depth":\(queueDepth),"tokens_per_second":\(tokensPerSecond),
        "time_to_first_token_ms":210}}
        """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(TelemetrySnapshot.self, from: Data(json.utf8))
}

// MARK: - Nothing sampled yet

/// Distinguish expected-but-pending readings from metrics the Spark does not report.
@Test func noSampleDistinguishesWaitingFromUnavailable() {
    #expect(SparkTelemetryPresentation.cpu(nil) == "Waiting")
    #expect(SparkTelemetryPresentation.inference(nil) == "Waiting")
    #expect(SparkTelemetryPresentation.usage(nil) == "Waiting")
    #expect(SparkTelemetryPresentation.uptime(nil) == "Waiting")

    #expect(SparkTelemetryPresentation.gpu(nil) == "Unavailable")
    #expect(SparkTelemetryPresentation.temperature(nil) == "Unavailable")
    #expect(SparkTelemetryPresentation.power(nil) == "Unavailable")
    #expect(SparkTelemetryPresentation.unifiedMemory(nil) == "Unavailable")
    #expect(SparkTelemetryPresentation.gpuMemory(nil) == "Unavailable")
    #expect(SparkTelemetryPresentation.memoryStall(nil) == "Unavailable")
    #expect(SparkTelemetryPresentation.storage(nil) == "Unavailable")
}

@Test func noSampleExplainsEachMissingDetailLine() {
    #expect(SparkTelemetryPresentation.cpuDetail(nil) == "Processor load is not reported yet.")
    #expect(
        SparkTelemetryPresentation.unifiedMemoryDetail(nil)
            == "Unified memory is not reported yet."
    )
    #expect(
        SparkTelemetryPresentation.gpuMemoryDetail(nil)
            == "Driver memory counters are not reported."
    )
    #expect(
        SparkTelemetryPresentation.memoryStallDetail(nil)
            == "Linux memory pressure stalls are not reported."
    )
    #expect(
        SparkTelemetryPresentation.storageDetail(nil)
            == "Filesystem capacity is not reported yet."
    )
    #expect(
        SparkTelemetryPresentation.inferenceDetail(nil)
            == "Inference activity is not reported yet."
    )
    #expect(
        SparkTelemetryPresentation.usageDetail(nil)
            == "Today's local request totals are not reported yet."
    )
}

// MARK: - A Spark that reports only some of it

@Test func aSparkWithoutDriverMemoryCountersSaysSoRatherThanShowingZero() throws {
    let sample = try telemetry(
        acceleratorMemoryUsed: "null",
        acceleratorMemoryTotal: "null"
    )
    #expect(SparkTelemetryPresentation.gpuMemory(sample) == "Unavailable")
    #expect(
        SparkTelemetryPresentation.gpuMemoryDetail(sample)
            == "Driver memory counters are not reported."
    )
}

/// Treat zero capacity as an unavailable measurement rather than full storage or absent memory.
@Test func unmeasuredCapacityIsUnavailableRatherThanZero() throws {
    let sample = try telemetry(unifiedTotal: "0", storageTotal: "0")
    #expect(SparkTelemetryPresentation.unifiedMemory(sample) == "Unavailable")
    #expect(
        SparkTelemetryPresentation.unifiedMemoryDetail(sample)
            == "Unified memory is not reported yet."
    )
    #expect(SparkTelemetryPresentation.storage(sample) == "Unavailable")
    #expect(
        SparkTelemetryPresentation.storageDetail(sample)
            == "Filesystem capacity is not reported yet."
    )
}

/// Name missing partial or full stall readings independently.
@Test func partialStallIsShownEvenWhenFullStallIsMissing() throws {
    let withoutFull = try telemetry(psiFull: "null")
    #expect(SparkTelemetryPresentation.memoryStall(withoutFull) == "0.12%")
    #expect(
        SparkTelemetryPresentation.memoryStallDetail(withoutFull)
            == "10-second partial-stall average · Full-stall PSI unavailable"
    )

    let withoutAny = try telemetry(psiSome: "null", psiFull: "null")
    #expect(SparkTelemetryPresentation.memoryStall(withoutAny) == "Unavailable")
    #expect(
        SparkTelemetryPresentation.memoryStallDetail(withoutAny)
            == "Linux memory pressure stalls are not reported."
    )
}

/// Display both required processor readings once a sample exists, reserving unavailable copy for no sample.
@Test func aSampledProcessorAlwaysReportsUtilisationAndLoad() throws {
    #expect(try SparkTelemetryPresentation.cpu(telemetry()) == "27%")
    #expect(try SparkTelemetryPresentation.cpu(telemetry(cpuUtilisation: "0")) == "0%")
    #expect(try SparkTelemetryPresentation.cpu(telemetry(cpuUtilisation: "1")) == "100%")
    #expect(
        try SparkTelemetryPresentation.cpuDetail(telemetry())
            == "1 minute load average 1.40"
    )
}

/// Prefer accelerator temperature, fall back to the system sensor and omit absent readings.
@Test func temperatureFallsBackToTheSystemSensorAndThenGivesUp() throws {
    #expect(try SparkTelemetryPresentation.temperature(telemetry()) == "55°C")
    #expect(
        try SparkTelemetryPresentation.temperature(telemetry(acceleratorTemperature: "null"))
            == "54°C"
    )
    #expect(
        try SparkTelemetryPresentation.temperature(
            telemetry(systemTemperature: "null", acceleratorTemperature: "null")
        ) == "Unavailable"
    )
}

@Test func anIdleAcceleratorStillReportsItsUtilisationAndPower() throws {
    #expect(try SparkTelemetryPresentation.gpu(telemetry(acceleratorUtilisation: "0")) == "0%")
    #expect(
        try SparkTelemetryPresentation.gpu(telemetry(acceleratorUtilisation: "null"))
            == "Unavailable"
    )
    #expect(
        try SparkTelemetryPresentation.power(telemetry(powerDrawWatts: "null")) == "Unavailable"
    )
}

// MARK: - Inference and usage

/// Show throughput only for serving engines and show loading or other states explicitly.
@Test func aModelThatIsNotServingShowsItsStateInsteadOfZeroThroughput() throws {
    let loading = try telemetry(inferenceState: "loading", tokensPerSecond: "null")
    #expect(SparkTelemetryPresentation.inference(loading) == "Loading")
    #expect(try SparkTelemetryPresentation.inference(telemetry()) == "42.5 tok/s")
}

@Test func anUnreportedQueueDepthDoesNotBecomeZeroQueued() throws {
    let sample = try telemetry(queueDepth: "null")
    #expect(SparkTelemetryPresentation.inferenceDetail(sample) == "2 active · Queue unavailable")
    #expect(try SparkTelemetryPresentation.inferenceDetail(telemetry()) == "2 active · 1 queued")
}

@Test func failuresAreNamedOnlyWhenThereAreSome() throws {
    #expect(
        try SparkTelemetryPresentation.usageDetail(telemetry(failures: "3"))
            == "12 requests · 3 failed today"
    )
    #expect(
        try SparkTelemetryPresentation.usageDetail(telemetry(failures: "0"))
            == "12 requests today"
    )
}

// MARK: - Uptime

/// Drop finer uptime units as presentation moves to coarser time ranges.
@Test func uptimeCoarsensAsItGrows() throws {
    #expect(try SparkTelemetryPresentation.uptime(telemetry(uptimeSeconds: "0")) == "0m")
    #expect(try SparkTelemetryPresentation.uptime(telemetry(uptimeSeconds: "59")) == "0m")
    #expect(try SparkTelemetryPresentation.uptime(telemetry(uptimeSeconds: "600")) == "10m")
    #expect(try SparkTelemetryPresentation.uptime(telemetry(uptimeSeconds: "3600")) == "1h 0m")
    #expect(try SparkTelemetryPresentation.uptime(telemetry(uptimeSeconds: "7860")) == "2h 11m")
    #expect(try SparkTelemetryPresentation.uptime(telemetry(uptimeSeconds: "86400")) == "1d 0h")
    #expect(try SparkTelemetryPresentation.uptime(telemetry(uptimeSeconds: "540000")) == "6d 6h")
}

@Test func hotTemperaturesHaveDifferentSeverityFromNormalReadings() {
    #expect(SparkTelemetryPresentation.temperatureSeverity(45) == 0)
    #expect(SparkTelemetryPresentation.temperatureSeverity(75) == 1)
    #expect(SparkTelemetryPresentation.temperatureSeverity(85) == 2)
    #expect(SparkTelemetryPresentation.temperatureSeverity(95) == 3)
    #expect(SparkTelemetryPresentation.temperatureSeverity(.nan) == 0)
}

@MainActor @Test func batteryPollingBacksOffWithoutSpeedingUpAnExistingSlowPoll() {
    #expect(SparkDashboardModel.pollingInterval(.seconds(1), conservingPower: true) == .seconds(5))
    #expect(
        SparkDashboardModel.pollingInterval(.seconds(10), conservingPower: true) == .seconds(10)
    )
    #expect(SparkDashboardModel.pollingInterval(.seconds(1), conservingPower: false) == .seconds(1))
}
