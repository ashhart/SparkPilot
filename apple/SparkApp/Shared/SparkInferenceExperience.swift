import Foundation
import SparkAPI
import SwiftUI

public enum SparkInferenceEngineDisplay: String, Codable, Equatable, Sendable {
    case vllm
    case sglang
    case ray
    case other
    case multiple
    case notReported

    public var label: String {
        switch self {
        case .vllm: "vLLM"
        case .sglang: "SGLang"
        case .ray: "Ray"
        case .other: String(localized: "Inference engine")
        case .multiple: String(localized: "Multiple engines")
        case .notReported: String(localized: "Engine not reported")
        }
    }
}

public enum SparkInferenceOwnership: String, Codable, Equatable, Sendable {
    case managed
    case external
    case mixed
    case unknown

    public var label: String {
        switch self {
        case .managed: String(localized: "Managed by SparkPilot")
        case .external: String(localized: "Externally managed, observed only")
        case .mixed: String(localized: "Managed and external engines")
        case .unknown: String(localized: "Ownership not reported")
        }
    }

    public var allowsLifecycleControl: Bool { self == .managed }
}

/// Carries content-free inference measurements without request text, network addresses, credentials or host identity.
public struct SparkInferenceExperienceSample: Codable, Equatable, Sendable {
    public let observedAt: Date
    public let engine: SparkInferenceEngineDisplay
    public let ownership: SparkInferenceOwnership
    public let state: String?
    public let modelID: String?
    public let modelDisplayName: String?
    public let usageDay: String?
    public let sparkUptimeSeconds: Int64?
    public let engineUptimeSeconds: Int64?
    public let promptTokens: Int64?
    public let generatedTokens: Int64?
    public let totalTokens: Int64?
    public let requestCount: Int64?
    public let failedRequestCount: Int64?
    public let requestsPerMinute: Double?
    public let activeRequests: Int?
    public let queueDepth: Int?
    public let tokensPerSecond: Double?
    public let promptTokensPerSecond: Double?
    public let generatedTokensPerSecond: Double?
    public let timeToFirstTokenMilliseconds: Double?
    public let timePerOutputTokenMilliseconds: Double?
    public let averageLatencyMilliseconds: Double?
    public let memoryPressure: String?
    public let metricsAvailability: String?
    public let metricsSampleAgeSeconds: Int64?

    public init(
        observedAt: Date,
        engine: SparkInferenceEngineDisplay,
        ownership: SparkInferenceOwnership,
        state: String?,
        modelID: String?,
        modelDisplayName: String?,
        usageDay: String?,
        sparkUptimeSeconds: Int64?,
        engineUptimeSeconds: Int64?,
        promptTokens: Int64?,
        generatedTokens: Int64?,
        totalTokens: Int64?,
        requestCount: Int64?,
        failedRequestCount: Int64?,
        requestsPerMinute: Double?,
        activeRequests: Int?,
        queueDepth: Int?,
        tokensPerSecond: Double?,
        promptTokensPerSecond: Double?,
        generatedTokensPerSecond: Double?,
        timeToFirstTokenMilliseconds: Double?,
        timePerOutputTokenMilliseconds: Double?,
        averageLatencyMilliseconds: Double?,
        memoryPressure: String?,
        metricsAvailability: String?,
        metricsSampleAgeSeconds: Int64?
    ) {
        self.observedAt = observedAt
        self.engine = engine
        self.ownership = ownership
        self.state = state
        self.modelID = modelID
        self.modelDisplayName = modelDisplayName
        self.usageDay = usageDay
        self.sparkUptimeSeconds = sparkUptimeSeconds
        self.engineUptimeSeconds = engineUptimeSeconds
        self.promptTokens = promptTokens
        self.generatedTokens = generatedTokens
        self.totalTokens = totalTokens
        self.requestCount = requestCount
        self.failedRequestCount = failedRequestCount
        self.requestsPerMinute = requestsPerMinute
        self.activeRequests = activeRequests
        self.queueDepth = queueDepth
        self.tokensPerSecond = tokensPerSecond
        self.promptTokensPerSecond = promptTokensPerSecond
        self.generatedTokensPerSecond = generatedTokensPerSecond
        self.timeToFirstTokenMilliseconds = timeToFirstTokenMilliseconds
        self.timePerOutputTokenMilliseconds = timePerOutputTokenMilliseconds
        self.averageLatencyMilliseconds = averageLatencyMilliseconds
        self.memoryPressure = memoryPressure
        self.metricsAvailability = metricsAvailability
        self.metricsSampleAgeSeconds = metricsSampleAgeSeconds
    }
}

public protocol SparkInferenceExperienceSampling: Sendable {
    func sample(
        telemetry: TelemetrySnapshot,
        activeInference: ActiveInference?,
        models: [SparkModel],
        workloads: GeneratedAPI.WorkloadInventory?,
        previous: SparkInferenceExperienceSample?
    ) -> SparkInferenceExperienceSample
}

public struct SparkInferenceExperienceAdapter: SparkInferenceExperienceSampling {
    public init() {}

    public func sample(
        telemetry: TelemetrySnapshot,
        activeInference: ActiveInference?,
        models: [SparkModel],
        workloads: GeneratedAPI.WorkloadInventory?,
        previous: SparkInferenceExperienceSample?
    ) -> SparkInferenceExperienceSample {
        let serving = servingWorkloads(in: workloads)
        let engineTelemetry = primaryEngine(in: telemetry.engines)
        let hasUsableEngineMetrics =
            engineTelemetry.map {
                $0.availability == "live" || $0.availability == "cached"
            } ?? false
        let ownership = ownership(of: serving, telemetry: engineTelemetry)
        let modelID =
            engineTelemetry?.servedModel ?? telemetry.inference.modelID ?? activeInference?.modelID
        let modelName = models.first { $0.id == modelID }?.displayName
        let promptRate = engineTelemetry?.promptTokensPerSecond
        let generationRate = engineTelemetry?.generationTokensPerSecond
        return SparkInferenceExperienceSample(
            observedAt: telemetry.observedAt,
            engine: engine(of: serving, telemetry: engineTelemetry),
            ownership: ownership,
            state: state(telemetry: telemetry.inference, engine: engineTelemetry),
            modelID: modelID,
            modelDisplayName: modelName,
            usageDay: telemetry.usage.day,
            sparkUptimeSeconds: telemetry.system.uptimeSeconds,
            engineUptimeSeconds: hasUsableEngineMetrics
                ? engineTelemetry?.engineUptimeSeconds : nil,
            promptTokens: engineMetric(
                engineTelemetry?.promptTokens,
                hasUsableMetrics: hasUsableEngineMetrics,
                legacy: telemetry.usage.promptTokens,
                engineReportsPresent: !telemetry.engines.isEmpty
            ),
            generatedTokens: engineMetric(
                engineTelemetry?.generatedTokens,
                hasUsableMetrics: hasUsableEngineMetrics,
                legacy: telemetry.usage.generatedTokens,
                engineReportsPresent: !telemetry.engines.isEmpty
            ),
            totalTokens: engineMetric(
                engineTelemetry?.totalTokens,
                hasUsableMetrics: hasUsableEngineMetrics,
                legacy: telemetry.usage.totalTokens,
                engineReportsPresent: !telemetry.engines.isEmpty
            ),
            requestCount: engineMetric(
                engineTelemetry?.totalRequests,
                hasUsableMetrics: hasUsableEngineMetrics,
                legacy: telemetry.usage.requests,
                engineReportsPresent: !telemetry.engines.isEmpty
            ),
            failedRequestCount: telemetry.engines.isEmpty ? telemetry.usage.failures : nil,
            requestsPerMinute: requestRate(
                currentCount: hasUsableEngineMetrics
                    ? engineTelemetry?.totalRequests
                    : telemetry.engines.isEmpty
                        ? telemetry.usage.requests : nil,
                usageDay: telemetry.usage.day,
                currentDate: telemetry.observedAt,
                previous: previous
            ),
            activeRequests: hasUsableEngineMetrics
                ? engineTelemetry?.runningRequests.flatMap(Int.init(exactly:))
                : telemetry.engines.isEmpty ? telemetry.inference.activeRequests : nil,
            queueDepth: hasUsableEngineMetrics
                ? engineTelemetry?.queueDepth.flatMap(Int.init(exactly:))
                : telemetry.engines.isEmpty ? telemetry.inference.queueDepth : nil,
            tokensPerSecond: hasUsableEngineMetrics
                ? generationRate
                : telemetry.engines.isEmpty ? telemetry.inference.tokensPerSecond : nil,
            promptTokensPerSecond: hasUsableEngineMetrics ? promptRate : nil,
            generatedTokensPerSecond: hasUsableEngineMetrics ? generationRate : nil,
            timeToFirstTokenMilliseconds: hasUsableEngineMetrics
                ? engineTelemetry?.timeToFirstTokenMs
                : telemetry.engines.isEmpty ? telemetry.inference.timeToFirstTokenMs : nil,
            timePerOutputTokenMilliseconds: hasUsableEngineMetrics
                ? engineTelemetry?.timePerOutputTokenMs : nil,
            averageLatencyMilliseconds: hasUsableEngineMetrics
                ? engineTelemetry?.requestLatencyMs : nil,
            memoryPressure: telemetry.system.memoryPressure,
            metricsAvailability: engineTelemetry?.availability,
            metricsSampleAgeSeconds: engineTelemetry?.sampleAgeSeconds
        )
    }

    private func primaryEngine(
        in engines: [InferenceEngineTelemetry]
    ) -> InferenceEngineTelemetry? {
        engines.min { left, right in
            let leftRank = engineRank(left)
            let rightRank = engineRank(right)
            return leftRank == rightRank
                ? left.workloadID < right.workloadID
                : leftRank < rightRank
        }
    }

    private func engineRank(_ engine: InferenceEngineTelemetry) -> Int {
        let managed = engine.ownership == "spark_managed"
        switch engine.availability {
        case "live": return managed ? 0 : 1
        case "cached": return managed ? 2 : 3
        case "unsupported": return 4
        default: return 5
        }
    }

    private func engineMetric(
        _ value: Int64?,
        hasUsableMetrics: Bool,
        legacy: Int64,
        engineReportsPresent: Bool
    ) -> Int64? {
        if hasUsableMetrics { return value }
        return engineReportsPresent ? nil : legacy
    }

    private func state(
        telemetry: LiveInferenceTelemetry,
        engine: InferenceEngineTelemetry?
    ) -> String? {
        guard let engine, engine.ownership != "spark_managed" else {
            return telemetry.state
        }
        switch engine.availability {
        case "live": return "serving"
        case "cached": return "cached"
        default: return "unavailable"
        }
    }

    private func servingWorkloads(
        in inventory: GeneratedAPI.WorkloadInventory?
    ) -> [GeneratedAPI.ObservedWorkload] {
        guard let inventory, inventory.available else { return [] }
        return inventory.workloads.filter {
            guard $0.kind == .inferenceEngine else { return false }
            switch $0.state {
            case .running, .restarting, .paused: return true
            default: return false
            }
        }
    }

    private func ownership(
        of workloads: [GeneratedAPI.ObservedWorkload],
        telemetry: InferenceEngineTelemetry?
    ) -> SparkInferenceOwnership {
        if workloads.isEmpty, let telemetry {
            return telemetry.ownership == "spark_managed" ? .managed : .external
        }
        guard !workloads.isEmpty else { return .unknown }
        let hasManaged = workloads.contains { $0.ownership == .sparkManaged }
        let hasExternal = workloads.contains { $0.ownership != .sparkManaged }
        if hasManaged, hasExternal { return .mixed }
        return hasManaged ? .managed : .external
    }

    private func engine(
        of workloads: [GeneratedAPI.ObservedWorkload],
        telemetry: InferenceEngineTelemetry?
    ) -> SparkInferenceEngineDisplay {
        if workloads.isEmpty, let telemetry {
            return engine(rawValue: telemetry.engine)
        }
        let engines = Set(workloads.map(\.recognisedEngine))
        guard engines.count == 1, let engine = engines.first else {
            return engines.isEmpty ? .notReported : .multiple
        }
        switch engine {
        case .vllm: return .vllm
        case .sglang: return .sglang
        case .ray: return .ray
        case .none, .openWebui: return .other
        }
    }

    private func engine(rawValue: String) -> SparkInferenceEngineDisplay {
        switch rawValue {
        case "vllm": .vllm
        case "sglang": .sglang
        case "ray": .ray
        default: .other
        }
    }

    private func requestRate(
        currentCount: Int64?,
        usageDay: String,
        currentDate: Date,
        previous: SparkInferenceExperienceSample?
    ) -> Double? {
        guard let currentCount,
            let previous,
            let previousCount = previous.requestCount,
            previous.usageDay == usageDay,
            currentCount >= previousCount
        else { return nil }
        let elapsed = currentDate.timeIntervalSince(previous.observedAt)
        guard elapsed > 0, elapsed <= 15 * 60 else { return nil }
        return Double(currentCount - previousCount) / elapsed * 60
    }
}
