import SparkCore
import SparkDesignSystem
import SwiftUI

/// Detail cards retain the owner's order, including helpful empty states while readings are unavailable.
struct FleetDashboardDetailCard: View {
    let kind: FleetCardKind
    let overview: FleetOverviewSnapshot
    let onOpenSpark: (String) -> Void

    var body: some View {
        FleetOverviewCard(kind: kind, summary: summary) {
            switch kind {
            case .runningInference: inference
            case .fleetMemory: memory
            case .loadedModels: models
            case .clusters: clusters
            case .temperatures: temperatures
            case .connectivity: connectivity
            }
        }
    }

    private var summary: String {
        switch kind {
        case .runningInference:
            String(localized: .countOfTotal(overview.runningInferenceCount, overview.sparks.count))
        case .fleetMemory: overview.memoryPressurePresentation.label
        case .loadedModels: String(localized: .fleetModelCount(overview.modelMatrix.count))
        case .clusters: String(localized: .fleetClusterCount(overview.clusterCount))
        case .temperatures: overview.hottest?.temperatureCelsius.map(FleetHeat.word) ?? ""
        case .connectivity:
            String(localized: .fleetOnlineCount(overview.connectedCount, overview.sparks.count))
        }
    }

    @ViewBuilder
    private var inference: some View {
        if overview.runningSparks.isEmpty { empty(String(localized: "No model is running")) }
        ForEach(overview.runningSparks) { spark in
            FleetSparkRow(spark: spark, value: spark.inferenceModelName ?? "", onOpen: onOpenSpark)
            {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(spark.inferenceModelName ?? "").font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let stage = spark.inferenceLoadingStage {
                        Text(OperationPresentation.stageLabel(stage)).font(.caption)
                    } else if let profile = spark.inferenceProfileID {
                        Text(profile).font(.caption).foregroundStyle(.secondary)
                    }
                    if spark.inferenceLoadingModelName != nil {
                        if let fraction = spark.inferenceLoadingFraction {
                            ProgressView(value: fraction)
                        } else {
                            ProgressView()
                        }
                    } else if let tokens = spark.inferenceTokensPerSecond {
                        Text(
                            String(
                                localized: .tokensPerSecond(
                                    tokens.formatted(.number.precision(.fractionLength(1)))
                                )
                            )
                        )
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var memory: some View {
        if let used = overview.usedMemoryBytes, let total = overview.totalMemoryBytes {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) { memoryTotal(used, total) }
                VStack(alignment: .leading, spacing: 4) { memoryTotal(used, total) }
            }
            ProgressView(value: Double(used), total: Double(max(total, 1)))
                .tint(FleetMemoryFill.color(used: used, total: total))
        } else {
            empty(String(localized: "No Spark reports memory yet"))
        }
        ForEach(overview.reportingMemory) { spark in
            FleetSparkRow(spark: spark, value: spark.memoryLabel, onOpen: onOpenSpark) {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(spark.memoryShortLabel).font(.caption.monospacedDigit())
                    Text(spark.memoryPressurePresentation.label)
                        .font(.caption2).foregroundStyle(
                            spark.memoryPressurePresentation.tone.color
                        )
                }
            }
        }
    }

    @ViewBuilder
    private func memoryTotal(_ used: Int64, _ total: Int64) -> some View {
        Text(FleetFormat.gigabytes(used)).font(.title3.weight(.semibold)).monospacedDigit()
        Text(String(localized: .fleetMemoryInUse(total: FleetFormat.gigabytes(total))))
            .font(.caption).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var models: some View {
        if overview.modelMatrix.isEmpty { empty(String(localized: "No models installed yet")) }
        ForEach(overview.modelMatrix) { row in
            VStack(alignment: .leading, spacing: 6) {
                Text(row.modelName).font(.subheadline.weight(.semibold))
                FleetChipRow {
                    ForEach(Array(row.placements.enumerated()), id: \.offset) { _, cell in
                        FleetChip(
                            text: String(localized: .pair(cell.sparkName, cell.stateLabel)),
                            tint: cell.state.tint
                        )
                    }
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var clusters: some View {
        if overview.clusters.isEmpty { empty(String(localized: "No clusters configured")) }
        ForEach(overview.clusters) { spark in
            let members = String(
                localized: .clusterMembersReadyCount(
                    ready: spark.memberReadyCount,
                    total: spark.memberTotalCount
                )
            )
            FleetSparkRow(spark: spark, value: members, onOpen: onOpenSpark) {
                Text(members).font(.caption).foregroundStyle(
                    spark.memberReadyCount == spark.memberTotalCount ? Color.secondary : .orange
                )
            }
        }
    }

    @ViewBuilder
    private var temperatures: some View {
        if overview.hottestFirst.isEmpty {
            empty(String(localized: "No Spark reports temperature yet"))
        }
        ForEach(overview.hottestFirst) { spark in
            if let celsius = spark.temperatureCelsius {
                FleetSparkRow(
                    spark: spark,
                    value: FleetFormat.celsius(celsius),
                    onOpen: onOpenSpark
                ) {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(FleetFormat.celsius(celsius)).font(.subheadline.weight(.semibold))
                            .monospacedDigit()
                        Text(FleetHeat.word(celsius)).font(.caption).foregroundStyle(
                            FleetHeat.color(celsius)
                        )
                    }
                }
            }
        }
    }

    private var connectivity: some View {
        ForEach(overview.sparks) { spark in
            let connection = spark.connectionPath?.summary ?? spark.connectionLabel
            FleetSparkRow(spark: spark, value: connection, onOpen: onOpenSpark) {
                Text(connection).font(.caption).foregroundStyle(spark.connectionTone.color)
            }
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
