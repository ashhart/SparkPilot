import Foundation
import SparkCore

/// Derive the overview and owner-selected cards from the same live readings.
enum FleetHomeBuilder {
    static func build(
        overview: FleetOverviewSnapshot,
        customization: FleetDashboardCustomization = FleetDashboardCustomization()
    ) -> FleetHomePresentation {
        let mode: FleetHomeMode = overview.sparks.count > 1 ? .fleet : .single
        let applicable = applicableCards(overview)
        let shown = customization.visibleCards.filter(applicable.contains)
        return FleetHomePresentation(
            mode: mode,
            rollUp: overview.sparks.isEmpty ? [] : rollUp(overview),
            sparks: overview.sparks.map(card),
            fleetCards: shown,
            customisableCards: applicable,
            unreachableSparkNames: overview.sparks.filter { !$0.isConnected }.map(\.displayName),
            sharedModels: overview.modelMatrix,
            clusters: overview.clusters.map(clusterRow),
            overview: overview
        )
    }

    /// Preserve the owner's choices even with one Spark or temporarily missing readings.
    static func applicableCards(_ overview: FleetOverviewSnapshot) -> [FleetCardKind] {
        overview.sparks.isEmpty ? [] : FleetCardKind.allCases
    }

    // MARK: Roll-up

    private static func rollUp(_ overview: FleetOverviewSnapshot) -> [FleetHomeMetric] {
        [onlineTile(overview), inferenceTile(overview), memoryTile(overview), heatTile(overview)]
    }

    private static func onlineTile(_ overview: FleetOverviewSnapshot) -> FleetHomeMetric {
        let everyone = overview.connectedCount == overview.sparks.count
        return FleetHomeMetric(
            key: FleetHomeMetricKey(reading: .online),
            title: String(localized: "Online"),
            value: String(
                localized: .countOfTotal(overview.connectedCount, overview.sparks.count)
            ),
            detail: everyone
                ? String(localized: "Every Spark is reachable")
                : String(localized: "Sparks reachable right now"),
            symbol: "antenna.radiowaves.left.and.right",
            tone: everyone ? .positive : .caution
        )
    }

    /// A Spark still starting a model is not yet serving one, and its own card already says so.
    private static func inferenceTile(_ overview: FleetOverviewSnapshot) -> FleetHomeMetric {
        let serving = overview.runningSparks.filter { $0.inferenceLoadingModelName == nil }
        return FleetHomeMetric(
            key: FleetHomeMetricKey(reading: .model),
            title: String(localized: "Inference"),
            value: serving.isEmpty
                ? String(localized: "Idle")
                : String(localized: .runningCount(serving.count)),
            detail: servingModels(serving) ?? String(localized: "No model is loaded anywhere"),
            symbol: "waveform",
            tone: serving.isEmpty ? .neutral : .positive
        )
    }

    /// Every model the count covers, so "2 running" is never explained by one model's name.
    private static func servingModels(_ serving: [FleetSparkSummary]) -> String? {
        var names: [String] = []
        for name in serving.compactMap(\.inferenceModelName) where !names.contains(name) {
            names.append(name)
        }
        guard !names.isEmpty else { return nil }
        return ListFormatter.localizedString(byJoining: names)
    }

    private static func memoryTile(_ overview: FleetOverviewSnapshot) -> FleetHomeMetric {
        FleetHomeMetric(
            key: FleetHomeMetricKey(reading: .memory),
            title: String(localized: "Memory"),
            value: overview.usedMemoryBytes.map(FleetFormat.gigabytes)
                ?? String(localized: "Not reported"),
            detail: memoryDetail(overview),
            symbol: "memorychip",
            tone: overview.memoryPressurePresentation.tone,
            fraction: fraction(used: overview.usedMemoryBytes, total: overview.totalMemoryBytes)
        )
    }

    private static func heatTile(_ overview: FleetOverviewSnapshot) -> FleetHomeMetric {
        FleetHomeMetric(
            key: FleetHomeMetricKey(reading: .temperature),
            title: String(localized: "Hottest"),
            value: overview.hottest?.temperatureCelsius.map(FleetFormat.celsius)
                ?? String(localized: "Not reported"),
            detail: overview.hottest?.displayName
                ?? String(localized: "No Spark reports temperature yet"),
            symbol: "thermometer.medium",
            tone: overview.hottest?.temperatureCelsius.map(FleetHeat.tone) ?? .neutral
        )
    }

    private static func memoryDetail(_ overview: FleetOverviewSnapshot) -> String {
        guard let total = overview.totalMemoryBytes else {
            return String(localized: "No Spark reports memory yet")
        }
        let reporting = overview.memoryReportedCount
        if reporting == overview.sparks.count {
            return String(localized: .fleetMemoryDetail(total: FleetFormat.gigabytes(total)))
        }
        return String(
            localized: .fleetMemoryDetailWithCoverage(
                total: FleetFormat.gigabytes(total),
                reporting: reporting,
                sparks: overview.sparks.count
            )
        )
    }

    // MARK: One Spark

    private static func card(_ spark: FleetSparkSummary) -> FleetHomeSparkCard {
        let connection = connectionMetric(spark)
        let action = action(spark)
        let metrics = [
            modelMetric(spark, action: action), memoryMetric(spark), heatMetric(spark),
        ].compactMap { $0 }
        return FleetHomeSparkCard(
            id: spark.id,
            entryID: spark.entryID,
            name: spark.displayName,
            isCluster: spark.isCluster,
            connection: connection,
            metrics: metrics,
            action: action,
            freshness: freshness(spark),
            accessibilityLabel: ListFormatter.localizedString(
                byJoining: [spark.displayName, spokenConnection(spark)]
                    + metrics.map(\.spokenLabel)
            )
        )
    }

    /// A Spark simply answering says which route it is on; any other state is news the route cannot carry.
    private static func connectionMetric(_ spark: FleetSparkSummary) -> FleetHomeMetric {
        let path = spark.connectionPath
        let saysRoute = spark.connectionTone == .positive && path != nil
        return FleetHomeMetric(
            key: FleetHomeMetricKey(scope: spark.id, reading: .connection),
            title: String(localized: "Connection"),
            value: saysRoute ? path?.summary ?? spark.connectionLabel : spark.connectionLabel,
            detail: saysRoute ? nil : path?.summary,
            symbol: saysRoute ? path?.symbol ?? spark.connectionSymbol : spark.connectionSymbol,
            tone: spark.connectionTone
        )
    }

    private static func spokenConnection(_ spark: FleetSparkSummary) -> String {
        guard let path = spark.connectionPath else { return spark.connectionLabel }
        if spark.connectionTone == .positive { return path.spokenSummary }
        return String(localized: .pair(spark.connectionLabel, path.spokenSummary))
    }

    /// The loading line already names the model, so the reading steps aside while a model starts.
    private static func modelMetric(
        _ spark: FleetSparkSummary,
        action: FleetHomeModelAction
    ) -> FleetHomeMetric? {
        if case .loading = action { return nil }
        return FleetHomeMetric(
            key: FleetHomeMetricKey(scope: spark.id, reading: .model),
            title: String(localized: "Model"),
            value: spark.inferenceModelName ?? String(localized: "No model running"),
            detail: spark.inferenceModelName == nil ? nil : servingDetail(spark),
            symbol: "waveform",
            tone: spark.inferenceModelName == nil ? .neutral : .positive
        )
    }

    private static func memoryMetric(_ spark: FleetSparkSummary) -> FleetHomeMetric? {
        guard let total = spark.memoryTotalBytes, let used = spark.memoryUsedBytes else {
            return nil
        }
        let pressure = spark.memoryPressurePresentation
        return FleetHomeMetric(
            key: FleetHomeMetricKey(scope: spark.id, reading: .memory),
            title: String(localized: "Unified memory"),
            value: String(
                localized: .memoryUsedOfTotal(
                    used: FleetFormat.gigabytes(used),
                    total: FleetFormat.gigabytes(total)
                )
            ),
            detail: pressure.label,
            symbol: "memorychip",
            tone: pressure.tone,
            fraction: fraction(used: used, total: total)
        )
    }

    private static func heatMetric(_ spark: FleetSparkSummary) -> FleetHomeMetric? {
        guard let celsius = spark.temperatureCelsius else { return nil }
        return FleetHomeMetric(
            key: FleetHomeMetricKey(scope: spark.id, reading: .temperature),
            title: String(localized: "Temperature"),
            value: FleetFormat.celsius(celsius),
            detail: FleetHeat.word(celsius),
            symbol: "thermometer.medium",
            tone: FleetHeat.tone(celsius)
        )
    }

    /// Derives the one model action from the same rules the dashboard header uses.
    static func action(_ spark: FleetSparkSummary) -> FleetHomeModelAction {
        if let loading = spark.inferenceLoadingModelName {
            let stage = spark.inferenceLoadingStage.map {
                SparkDashboardOwnerPresentation.operationStageLabel($0, action: .load)
            }
            return .loading(
                line: SparkModelActionPresentation.loadingLine(
                    name: loading,
                    stage: stage,
                    fraction: spark.inferenceLoadingFraction
                ),
                fraction: spark.inferenceLoadingFraction
            )
        }
        guard spark.isConnected else { return .none }
        if spark.inferenceModelName != nil { return .switchModel }
        return spark.loadedModelNames.isEmpty ? .none : .launch
    }

    private static func servingDetail(_ spark: FleetSparkSummary) -> String {
        var parts: [String] = []
        if let profile = spark.inferenceProfileID { parts.append(profile) }
        if let tokens = spark.inferenceTokensPerSecond {
            parts.append(
                String(
                    localized: .tokensPerSecond(
                        tokens.formatted(.number.precision(.fractionLength(1)))
                    )
                )
            )
        }
        return parts.isEmpty ? String(localized: "Serving") : parts.joined(separator: " · ")
    }

    private static func freshness(_ spark: FleetSparkSummary) -> String {
        guard let age = spark.evidenceAge else { return String(localized: "No readings yet") }
        return String(localized: .latestReading(FleetFormat.elapsed(age).lowercased()))
    }

    private static func clusterRow(_ spark: FleetSparkSummary) -> FleetHomeClusterRow {
        FleetHomeClusterRow(
            id: spark.id,
            entryID: spark.entryID,
            name: spark.displayName,
            readyCount: spark.memberReadyCount,
            totalCount: spark.memberTotalCount,
            isComplete: spark.memberReadyCount == spark.memberTotalCount
        )
    }

    private static func fraction(used: Int64?, total: Int64?) -> Double? {
        guard let used, let total, total > 0 else { return nil }
        return min(1, max(0, Double(used) / Double(total)))
    }
}
