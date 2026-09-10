import Foundation
import SparkAPI
import SparkCore
import SparkDesignSystem
import SparkLibrary
import SwiftUI

struct SparkDashboardHealthView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let model: SparkDashboardModel
    let displayName: String?
    var openModels: (() -> Void)? = nil

    var body: some View {
        SparkDashboardPage(refresh: { await model.refresh() }) {
            healthGrid
            SparkInferenceExperiencePanel(
                sample: model.inferenceExperience,
                history: model.inferenceHistory,
                isLive: model.telemetryIsLive,
                isLoading: model.isRefreshingTelemetry,
                errorMessage: model.telemetryErrorMessage,
                inferenceTestTarget: model.inferenceTestTarget(displayName: displayName),
                openModels: openModels
            )
            telemetryPanel
        }
        .navigationTitle("Health and telemetry")
    }
    private var healthGrid: some View {
        Group {
            if model.isRefreshing, !model.hasRenderableData {
                SparkSkeletonList(
                    rowCount: 4,
                    accessibilityLabel: String(localized: "Loading Spark health")
                )
            } else {
                VStack(spacing: 12) {
                    SparkDashboardStatusRow(
                        title: String(localized: "Spark Runtime"),
                        value: model.runtimeStatusValue,
                        detail: model.runtimeVersion.map { String(localized: .versionLabelled($0)) }
                            ?? String(localized: "Connecting"),
                        symbol: "server.rack",
                        help: String(
                            localized: "The signed Spark runtime and API running on this DGX Spark."
                        )
                    )
                    SparkDashboardStatusRow(
                        title: SparkDashboardOwnerPresentation.modelServiceTitle,
                        value: model.vllmStatusValue,
                        detail: model.modelServiceDetail,
                        symbol: "bolt.horizontal.circle",
                        help: String(
                            localized: "The local inference service that loads and serves models."
                        )
                    )
                    SparkDashboardStatusRow(
                        title: String(localized: "Models"),
                        value: model.modelCatalogueStatusValue,
                        detail: model.modelCatalogueDetail,
                        symbol: "square.stack.3d.up",
                        help: String(
                            localized: "Signed model recipes available or installed on this Spark."
                        )
                    )
                    SparkDashboardStatusRow(
                        title: String(localized: "Unified memory"),
                        value: model.pressureValue,
                        detail: model.memorySummary
                            ?? String(localized: "Reporting after first status"),
                        symbol: "memorychip",
                        help: String(localized: "Memory shared by the CPU, GPU, and running model.")
                    )
                }
            }
        }
    }
    private var telemetryPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Live telemetry")
                    .font(.title2.bold())
                SparkTooltipButton(
                    title: String(localized: "Live telemetry"),
                    message:
                        String(
                            localized:
                                "Signed readings come directly from this Spark and update while this screen is open. The last sample is cached only on this device."
                        )
                )
                Spacer()
                if model.isRefreshingTelemetry, model.telemetry == nil {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Loading live telemetry")
                } else {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.telemetryIsLive ? Color.green : Color.secondary)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(
                            model.telemetry == nil
                                ? String(localized: "Waiting")
                                : (model.telemetryIsLive
                                    ? String(localized: "Live") : String(localized: "Saved"))
                        )
                        .font(.caption.weight(.semibold))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        model.telemetry == nil
                            ? String(localized: "Waiting for telemetry")
                            : (model.telemetryIsLive
                                ? String(localized: "Telemetry is live")
                                : String(localized: "Saved telemetry"))
                    )
                }
            }

            if let message = model.telemetryErrorMessage {
                Label(message, systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.telemetry == nil, model.telemetryErrorMessage != nil,
                !model.isRefreshingTelemetry
            {
                ContentUnavailableView(
                    "Telemetry unavailable",
                    systemImage: "waveform.path.ecg.rectangle",
                    description: Text(
                        "SparkPilot will retry while this screen remains open."
                    )
                )
            } else if model.telemetry == nil {
                SparkSkeletonList(
                    rowCount: 3,
                    accessibilityLabel: String(localized: "Loading Spark telemetry")
                )
            } else {
                LazyVGrid(
                    columns: SparkStatTileLayout.columns(
                        minimum: 145,
                        usesAccessibilityTextSize: dynamicTypeSize.isAccessibilitySize
                    ),
                    spacing: 12
                ) {
                    SparkDashboardTelemetryCard(
                        title: "GPU",
                        value: model.gpuTelemetry,
                        detail: String(localized: "Current accelerator load"),
                        symbol: "gauge.with.dots.needle.67percent"
                    )
                    SparkDashboardTelemetryCard(
                        title: "CPU",
                        value: model.cpuTelemetry,
                        detail: model.cpuTelemetryDetail,
                        symbol: "cpu"
                    )
                    SparkDashboardTelemetryCard(
                        title: String(localized: "Temperature"),
                        value: model.temperatureTelemetry,
                        detail: model.temperatureDetail,
                        symbol: model.temperatureSeverity > 0
                            ? "thermometer.high" : "thermometer.medium",
                        severity: model.temperatureSeverity
                    )
                    SparkDashboardTelemetryCard(
                        title: String(localized: "Power"),
                        value: model.powerTelemetry,
                        detail: sparkDashboardPowerTelemetryDetail(
                            model.telemetry?.accelerator.powerLimitWatts
                        ),
                        symbol: "bolt.fill"
                    )
                    SparkDashboardTelemetryCard(
                        title: String(localized: "Unified memory"),
                        value: model.unifiedMemoryTelemetry,
                        detail: model.unifiedMemoryTelemetryDetail,
                        symbol: "memorychip"
                    )
                    SparkDashboardTelemetryCard(
                        title: String(localized: "GPU memory"),
                        value: model.gpuMemoryTelemetry,
                        detail: model.gpuMemoryTelemetryDetail,
                        symbol: "memorychip.fill"
                    )
                    SparkDashboardTelemetryCard(
                        title: String(localized: "Memory stalls"),
                        value: model.memoryStallTelemetry,
                        detail: model.memoryStallTelemetryDetail,
                        symbol: "waveform.path"
                    )
                    SparkDashboardTelemetryCard(
                        title: String(localized: "Storage"),
                        value: model.storageTelemetry,
                        detail: model.storageTelemetryDetail,
                        symbol: "internaldrive"
                    )
                    SparkDashboardTelemetryCard(
                        title: String(localized: "Inference"),
                        value: model.inferenceTelemetry,
                        detail: model.inferenceTelemetryDetail,
                        symbol: "waveform.path.ecg"
                    )
                    SparkDashboardTelemetryCard(
                        title: String(localized: "Usage"),
                        value: model.usageTelemetry,
                        detail: model.usageTelemetryDetail,
                        symbol: "chart.bar.xaxis"
                    )
                    SparkDashboardTelemetryCard(
                        title: String(localized: "Uptime"),
                        value: model.uptimeTelemetry,
                        detail: String(localized: "Time since the Spark last started"),
                        symbol: "clock"
                    )
                }
                if let updatedAt = model.telemetryUpdatedAt {
                    Text(
                        .sampledAt(updatedAt.formatted(date: .omitted, time: .standard))
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }

            // Show the Spark-retained history below live readings on every Apple platform.
            SparkTelemetryHistoryCard(history: model.history)
        }
    }
}
