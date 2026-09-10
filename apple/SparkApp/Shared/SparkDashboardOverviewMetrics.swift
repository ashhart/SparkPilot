import Foundation
import SparkAPI
import SparkCore
import SparkDesignSystem
import SparkLibrary
import SwiftUI

struct SparkDashboardOverviewMetrics: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let model: SparkDashboardModel
    let dashboardMetricSelection: String
    let edit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Place Edit below the heading at accessibility text sizes to preserve readable width.
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    atAGlanceHeading
                    Button("Edit") { edit() }
                        .buttonStyle(.bordered)
                }
            } else {
                HStack {
                    atAGlanceHeading
                    Spacer()
                    Button("Edit") { edit() }
                        .buttonStyle(.bordered)
                }
            }

            LazyVGrid(
                columns: SparkStatTileLayout.columns(
                    minimum: 145,
                    usesAccessibilityTextSize: dynamicTypeSize.isAccessibilitySize
                ),
                spacing: 12
            ) {
                ForEach(
                    SparkDashboardMetricSelection(encoded: dashboardMetricSelection).metrics
                ) { metric in
                    let content = atAGlanceContent(metric)
                    SparkDashboardTelemetryCard(
                        title: metric.title,
                        value: content.value,
                        detail: content.detail,
                        symbol: metric == .temperature && model.temperatureSeverity > 0
                            ? "thermometer.high" : metric.symbol,
                        severity: metric == .temperature ? model.temperatureSeverity : 0
                    )
                }
            }
        }

    }
    private var atAGlanceHeading: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("At a glance")
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)
            Text("The readings you chose for this Spark")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    private func atAGlanceContent(
        _ metric: SparkDashboardMetric
    ) -> (value: String, detail: String) {
        switch metric {
        case .gpu:
            (model.gpuTelemetry, String(localized: "Current accelerator load"))
        case .cpu:
            (model.cpuTelemetry, model.cpuTelemetryDetail)
        case .temperature:
            (model.temperatureTelemetry, model.temperatureDetail)
        case .power:
            (
                model.powerTelemetry,
                sparkDashboardPowerTelemetryDetail(model.telemetry?.accelerator.powerLimitWatts)
            )
        case .unifiedMemory:
            (model.unifiedMemoryTelemetry, model.unifiedMemoryTelemetryDetail)
        case .gpuMemory:
            (model.gpuMemoryTelemetry, model.gpuMemoryTelemetryDetail)
        case .memoryStalls:
            (model.memoryStallTelemetry, model.memoryStallTelemetryDetail)
        case .storage:
            (model.storageTelemetry, model.storageTelemetryDetail)
        case .inference:
            (model.inferenceTelemetry, model.inferenceTelemetryDetail)
        case .usage:
            (model.usageTelemetry, model.usageTelemetryDetail)
        case .uptime:
            (model.uptimeTelemetry, String(localized: "Time since the Spark last started"))
        }
    }
}
