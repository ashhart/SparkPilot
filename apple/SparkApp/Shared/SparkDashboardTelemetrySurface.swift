import Foundation
import SparkAPI
import SparkCore
import SparkDesignSystem

extension SparkDashboardModel {
    public var telemetry: TelemetrySnapshot? { telemetryModel.telemetry }
    public var isRefreshingTelemetry: Bool { telemetryModel.isRefreshingTelemetry }
    public var telemetryIsLive: Bool { telemetryModel.telemetryIsLive }
    public var telemetryErrorMessage: String? { telemetryModel.telemetryErrorMessage }
    public var inferenceExperience: SparkInferenceExperienceSample? {
        telemetryModel.inferenceExperience
    }
    public var inferenceHistory: [SparkInferenceExperienceSample] {
        telemetryModel.inferenceHistory
    }
    /// Refresh recorded history on its own cadence, independently of live telemetry.
    public var history: SparkTelemetryHistoryModel! { telemetryModel.history }
    public func refreshHistory(force: Bool = false) async {
        await telemetryModel.refreshHistory(force: force)
    }
    public func refreshTelemetry(reportFailure: Bool = true) async {
        await telemetryModel.refreshTelemetry(reportFailure: reportFailure)
    }
    public var telemetryUpdatedAt: Date? { telemetryModel.telemetryUpdatedAt }
    public var cpuTelemetry: String { telemetryModel.cpuTelemetry }
    public var cpuTelemetryDetail: String { telemetryModel.cpuTelemetryDetail }
    public var gpuTelemetry: String { telemetryModel.gpuTelemetry }
    public var temperatureTelemetry: String { telemetryModel.temperatureTelemetry }
    public var temperatureSeverity: Int { telemetryModel.temperatureSeverity }
    public var temperatureDetail: String { telemetryModel.temperatureDetail }
    public var powerTelemetry: String { telemetryModel.powerTelemetry }
    public var unifiedMemoryTelemetry: String { telemetryModel.unifiedMemoryTelemetry }
    public var unifiedMemoryTelemetryDetail: String { telemetryModel.unifiedMemoryTelemetryDetail }
    public var gpuMemoryTelemetry: String { telemetryModel.gpuMemoryTelemetry }
    public var gpuMemoryTelemetryDetail: String { telemetryModel.gpuMemoryTelemetryDetail }
    public var memoryStallTelemetry: String { telemetryModel.memoryStallTelemetry }
    public var memoryStallTelemetryDetail: String { telemetryModel.memoryStallTelemetryDetail }
    public var storageTelemetry: String { telemetryModel.storageTelemetry }
    public var storageTelemetryDetail: String { telemetryModel.storageTelemetryDetail }
    public var inferenceTelemetry: String { telemetryModel.inferenceTelemetry }
    public var inferenceTelemetryDetail: String { telemetryModel.inferenceTelemetryDetail }
    public var usageTelemetry: String { telemetryModel.usageTelemetry }
    public var usageTelemetryDetail: String { telemetryModel.usageTelemetryDetail }
    public var uptimeTelemetry: String { telemetryModel.uptimeTelemetry }

}
