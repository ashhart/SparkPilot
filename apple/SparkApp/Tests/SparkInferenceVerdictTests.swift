import Foundation
import Testing
@testable import SparkAppComposition

struct SparkInferenceVerdictTests {
    private func sample(
        state: String?,
        modelID: String? = "nvidia/model",
        active: Int? = 0,
        queued: Int? = 0,
        tokensPerSecond: Double? = nil,
        pressure: String? = "normal"
    ) -> SparkInferenceExperienceSample {
        SparkInferenceExperienceSample(
            observedAt: Date(timeIntervalSince1970: 1_000),
            engine: .vllm,
            ownership: .managed,
            state: state,
            modelID: modelID,
            modelDisplayName: modelID,
            usageDay: nil,
            sparkUptimeSeconds: nil,
            engineUptimeSeconds: nil,
            promptTokens: nil,
            generatedTokens: nil,
            totalTokens: nil,
            requestCount: nil,
            failedRequestCount: nil,
            requestsPerMinute: nil,
            activeRequests: active,
            queueDepth: queued,
            tokensPerSecond: tokensPerSecond,
            promptTokensPerSecond: nil,
            generatedTokensPerSecond: nil,
            timeToFirstTokenMilliseconds: nil,
            timePerOutputTokenMilliseconds: nil,
            averageLatencyMilliseconds: nil,
            memoryPressure: pressure,
            metricsAvailability: "live",
            metricsSampleAgeSeconds: 0
        )
    }

    /// The headline answers "is it working and why is it slow" from the same sample as the counters (UX-06).
    @Test func verdictNamesTheReasonInferenceIsSlowOrIdle() {
        #expect(
            SparkInferenceExperiencePresentation.verdict(sample(state: "loading"))
                .contains("loading")
        )
        #expect(
            SparkInferenceExperiencePresentation.verdict(sample(state: "ready", pressure: "high"))
                .contains("pressure")
        )
        #expect(
            SparkInferenceExperiencePresentation.verdict(
                sample(state: "ready", active: 2, queued: 3)
            )
            .contains("3 waiting")
        )
        #expect(
            SparkInferenceExperiencePresentation.verdict(
                sample(state: "ready", active: 1, tokensPerSecond: 42.4)
            )
            .contains("42 tokens")
        )
        #expect(
            SparkInferenceExperiencePresentation.verdict(sample(state: "ready"))
                .contains("Idle and ready")
        )
        #expect(
            SparkInferenceExperiencePresentation.verdict(sample(state: nil, modelID: nil))
                .contains("No model")
        )
    }
}
