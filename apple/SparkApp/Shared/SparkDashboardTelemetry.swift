import Foundation
#if os(iOS)
    import UIKit
#elseif os(macOS)
    import IOKit.ps
#endif
import Observation
import SparkAPI
import SparkCore
import SparkDesignSystem
import SparkLibrary
import SparkSecurity
import SwiftUI
import UniformTypeIdentifiers
@MainActor
@Observable
final class SparkDashboardTelemetry {
    var telemetry: TelemetrySnapshot?
    var isRefreshingTelemetry = false
    var telemetryIsLive = false
    var telemetryErrorMessage: String?
    var inferenceExperience: SparkInferenceExperienceSample?
    var inferenceHistory: [SparkInferenceExperienceSample] = []
    @ObservationIgnored var history: SparkTelemetryHistoryModel!
    private let route: URL
    private let runtime: any SparkRuntimeReading
    private let targetID: String
    private let snapshot: SparkDashboardSnapshot
    private let telemetryCache: any SparkTelemetryCaching
    private let inferenceExperienceAdapter: any SparkInferenceExperienceSampling
    private let inferenceHistoryStore: any SparkInferenceHistoryStoring
    init(
        route: URL,
        targetID: String,
        runtime: any SparkRuntimeReading,
        snapshot: SparkDashboardSnapshot,
        telemetryCache: any SparkTelemetryCaching,
        adapter: any SparkInferenceExperienceSampling,
        historyStore: any SparkInferenceHistoryStoring
    ) {
        self.route = route
        self.targetID = targetID
        self.runtime = runtime
        self.snapshot = snapshot
        self.telemetryCache = telemetryCache
        self.inferenceExperienceAdapter = adapter
        self.inferenceHistoryStore = historyStore
        inferenceHistory = (try? historyStore.load(targetID: targetID)) ?? []
        history = SparkTelemetryHistoryModel(
            load: { [runtime] route in try await runtime.telemetryHistory(route: route) },
            cached: { [weak self] in self?.cachedHistoryPoints() ?? [] }
        )
        inferenceExperience = inferenceHistory.last
        if let cached = try? telemetryCache.load(targetID: targetID),
            snapshot.expectedIdentity?.coordinatorNodeID == nil
                || cached.nodeID == snapshot.expectedIdentity?.coordinatorNodeID
        {
            telemetry = cached
            acceptInferenceTelemetry(cached, publishNotification: false)
        }
    }
    private var expectedIdentity: SparkDashboardIdentityExpectation? { snapshot.expectedIdentity }
    private var health: Health? { snapshot.health }
    private var status: SparkStatus? { snapshot.status }
    private var models: [SparkModel] { snapshot.models }
    private var inference: ActiveInference? { snapshot.inference }
    private var workloadInventory: GeneratedAPI.WorkloadInventory? { snapshot.workloadInventory }
    private var cachedSnapshot: TargetOperationalSnapshot? { snapshot.cachedSnapshot }

    /// Ask the Spark for its history if enough time has passed.
    func refreshHistory(force: Bool = false) async {
        await history.refresh(route: route, force: force)
    }

    /// What this device saw itself, for a Spark that cannot be reached.
    private func cachedHistoryPoints() -> [SparkTelemetryHistoryPoint] {
        inferenceHistory.map { sample in
            SparkTelemetryHistoryPoint(
                observedAt: sample.observedAt,
                isRaw: false,
                sampleCount: 1,
                cpuUtilisation: nil,
                memoryAvailableBytes: nil,
                acceleratorUtilisation: nil,
                activeRequests: sample.activeRequests.map(Double.init),
                queueDepth: sample.queueDepth.map(Double.init),
                tokensPerSecond: sample.tokensPerSecond
            )
        }
    }

    func refreshTelemetry(reportFailure: Bool = true) async {
        guard !isRefreshingTelemetry else { return }
        isRefreshingTelemetry = true
        defer { isRefreshingTelemetry = false }
        do {
            let sample = try await runtime.telemetry(route: route)
            let expectedNodeID = expectedIdentity?.coordinatorNodeID ?? health?.nodeID
            if let expectedNodeID, sample.nodeID != expectedNodeID {
                telemetryIsLive = false
                telemetryErrorMessage =
                    String(localized: "Live telemetry came from a different Spark and was ignored.")
                return
            }
            telemetry = sample
            telemetryIsLive = true
            telemetryErrorMessage = nil
            acceptInferenceTelemetry(sample, publishNotification: true)
            do {
                try telemetryCache.save(sample, targetID: targetID)
            } catch {
                telemetryErrorMessage =
                    String(
                        localized:
                            "Live telemetry is current, but this device could not save the latest sample."
                    )
            }
        } catch is PendingRuntimeError {
            telemetryIsLive = false
            if reportFailure {
                telemetryErrorMessage =
                    String(localized: "Update Spark Runtime to enable live hardware telemetry.")
            }
        } catch let error as APIError
            where error.code == "ROLE_FORBIDDEN" || error.statusCode == 403
        {
            // The Spark shows hardware telemetry to administrators and its owner; other roles are not paused, they are not shown it.
            telemetryIsLive = false
            if reportFailure {
                telemetryErrorMessage =
                    String(
                        localized:
                            "This Spark shows live hardware telemetry only to its administrators and owner."
                    )
            }
        } catch {
            telemetryIsLive = false
            if reportFailure {
                telemetryErrorMessage =
                    String(
                        localized:
                            "Live telemetry paused. SparkPilot is showing the last sample from this device."
                    )
            }
        }
    }

    func acceptInferenceTelemetry(
        _ telemetry: TelemetrySnapshot,
        publishNotification: Bool
    ) {
        let previous = inferenceHistory.last { $0.observedAt < telemetry.observedAt }
        let sample = inferenceExperienceAdapter.sample(
            telemetry: telemetry,
            activeInference: inference,
            models: models,
            workloads: workloadInventory,
            previous: previous
        )
        inferenceExperience = sample
        inferenceHistory.removeAll { $0.observedAt == sample.observedAt }
        inferenceHistory.append(sample)
        inferenceHistory.sort { $0.observedAt < $1.observedAt }
        inferenceHistory = Array(inferenceHistory.suffix(1_440))
        if (try? inferenceHistoryStore.save(sample, targetID: targetID)) != nil,
            let stored = try? inferenceHistoryStore.load(targetID: targetID)
        {
            inferenceHistory = stored
        }
        guard publishNotification else { return }
        NotificationCenter.default.post(
            name: .sparkInferenceObservation,
            object: SparkInferenceNotificationObservation(
                targetID: targetID,
                health: Self.inferenceNotificationHealth(sample.state),
                queueDepth: sample.queueDepth,
                memoryPressure: Self.inferenceNotificationPressure(sample.memoryPressure)
            )
        )
    }

    private nonisolated static func inferenceNotificationHealth(
        _ state: String?
    ) -> SparkInferenceNotificationHealth {
        switch state {
        case "ready", "idle": .healthy
        case "failed": .unhealthy
        default: .unknown
        }
    }

    private nonisolated static func inferenceNotificationPressure(
        _ pressure: String?
    ) -> SparkInferenceNotificationMemoryPressure {
        switch pressure {
        case "normal": .normal
        case "warning": .warning
        case "critical": .critical
        case "emergency": .emergency
        default: .unknown
        }
    }

    // Delegate tile copy to SparkTelemetryPresentation so partial readings can be tested independently.
    var telemetryUpdatedAt: Date? { telemetry?.observedAt }

    var cpuTelemetry: String { SparkTelemetryPresentation.cpu(telemetry) }

    var cpuTelemetryDetail: String { SparkTelemetryPresentation.cpuDetail(telemetry) }

    var gpuTelemetry: String { SparkTelemetryPresentation.gpu(telemetry) }

    var temperatureTelemetry: String { SparkTelemetryPresentation.temperature(telemetry) }

    var temperatureSeverity: Int {
        SparkTelemetryPresentation.temperatureSeverity(
            SparkTelemetryPresentation.highestTemperature(telemetry)
        )
    }

    var temperatureDetail: String { SparkTelemetryPresentation.temperatureDetail(telemetry) }

    var powerTelemetry: String { SparkTelemetryPresentation.power(telemetry) }

    var unifiedMemoryTelemetry: String {
        SparkTelemetryPresentation.unifiedMemory(telemetry)
    }

    var unifiedMemoryTelemetryDetail: String {
        SparkTelemetryPresentation.unifiedMemoryDetail(telemetry)
    }

    var gpuMemoryTelemetry: String { SparkTelemetryPresentation.gpuMemory(telemetry) }

    var gpuMemoryTelemetryDetail: String {
        SparkTelemetryPresentation.gpuMemoryDetail(telemetry)
    }

    var memoryStallTelemetry: String { SparkTelemetryPresentation.memoryStall(telemetry) }

    var memoryStallTelemetryDetail: String {
        SparkTelemetryPresentation.memoryStallDetail(telemetry)
    }

    var storageTelemetry: String { SparkTelemetryPresentation.storage(telemetry) }

    var storageTelemetryDetail: String {
        SparkTelemetryPresentation.storageDetail(telemetry)
    }

    var inferenceTelemetry: String { SparkTelemetryPresentation.inference(telemetry) }

    var inferenceTelemetryDetail: String {
        SparkTelemetryPresentation.inferenceDetail(telemetry)
    }

    var usageTelemetry: String { SparkTelemetryPresentation.usage(telemetry) }

    var usageTelemetryDetail: String { SparkTelemetryPresentation.usageDetail(telemetry) }

    var uptimeTelemetry: String { SparkTelemetryPresentation.uptime(telemetry) }

    /// Prefer the one-hertz telemetry sample over the slower status document.
    var memoryPressure: MemoryPressureLevel? {
        if telemetryIsLive,
            let pressure = telemetry?.system.memoryPressure,
            let live = MemoryPressureLevel(rawValue: pressure)
        {
            return live
        }
        if let live = status?.system.pressure {
            return MemoryPressureLevel(rawValue: live.rawValue)
        }
        switch cachedSnapshot?.unifiedMemory?.pressure {
        case .normal: return .normal
        case .warning: return .warning
        case .critical: return .critical
        case .emergency: return .emergency
        case .unknown, nil: return nil
        }
    }

    /// Provides pressure-banner copy and recovery actions, with nil hiding the banner.
    var pressurePresentation: MemoryPressurePresentation? {
        memoryPressure.flatMap(MemoryPressurePresentationResolver.resolve)
    }

    var pressureLabel: String { pressureValue.text }

    var pressureValue: SparkStatusValue {
        switch memoryPressure {
        case .normal, nil: SparkStatusValue(String(localized: "Normal"))
        case .warning: SparkStatusValue(String(localized: "Filling up"), tone: .attention)
        case .critical, .emergency:
            SparkStatusValue(String(localized: "Needs attention"), tone: .attention)
        }
    }

}
