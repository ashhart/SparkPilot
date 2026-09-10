import Foundation
import SparkCore
import SparkDesignSystem
import SparkWidgetSupport
import SwiftUI

/// Derives the overview from operational snapshots without I/O.
public enum FleetOverviewBuilder {
    public static func build(
        from snapshots: [TargetOperationalSnapshot],
        at date: Date
    ) -> FleetOverviewSnapshot {
        build(
            targets: snapshots.map {
                FleetOverviewTarget(entryID: $0.identity.description, snapshot: $0)
            },
            at: date
        )
    }

    public static func build(
        targets: [FleetOverviewTarget],
        at date: Date
    ) -> FleetOverviewSnapshot {
        let summaries =
            targets
            .map { summary($0.snapshot, entryID: $0.entryID) }
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                    == .orderedAscending
            }

        let reported = summaries.filter { $0.memoryTotalBytes != nil }
        let total = reported.reduce(Int64(0)) { $0 + ($1.memoryTotalBytes ?? 0) }
        let used = reported.reduce(Int64(0)) { $0 + ($1.memoryUsedBytes ?? 0) }
        let hottest =
            summaries
            .filter { $0.temperatureCelsius != nil }
            .sorted { ($0.temperatureCelsius ?? 0) > ($1.temperatureCelsius ?? 0) }

        return FleetOverviewSnapshot(
            generatedAt: date,
            sparks: summaries,
            totalMemoryBytes: reported.isEmpty ? nil : total,
            usedMemoryBytes: reported.isEmpty ? nil : used,
            memoryReportedCount: reported.count,
            runningInferenceCount: summaries.count {
                $0.inferenceModelName != nil && $0.inferenceLoadingModelName == nil
            },
            connectedCount: summaries.count(where: \.isConnected),
            clusterCount: summaries.count(where: \.isCluster),
            modelMatrix: matrix(from: summaries, targets: targets),
            hottestFirst: hottest,
            connectionTallies: connectionTallies(from: summaries),
            freshestEvidenceAge: summaries.compactMap(\.evidenceAge).min()
        )
    }

    private static func summary(
        _ snapshot: TargetOperationalSnapshot,
        entryID: String
    ) -> FleetSparkSummary {
        let inference = snapshot.activeInference
        let modelName = inference?.modelIdentity.flatMap { identity in
            snapshot.placements.first { $0.identity == identity }?.displayName
                ?? identity.modelID.split(separator: "/").last.map(String.init)
        }
        let runningModelName =
            inference.map { FleetPresentationBuilder.isModelActive($0.state) } == true
            ? modelName : nil
        let loadingModelName = inference?.state == .loading ? modelName : nil
        let loadOperation = snapshot.operations.first {
            $0.kind == "model.load" && $0.state == .running
        }
        let loaded = snapshot.placements
            .filter { [.installed, .running, .starting].contains($0.state) }
            .map(\.displayName)
        let connection = FleetPresentationBuilder.connectionPresentation(
            state: snapshot.connectionState,
            isChecking: false,
            route: snapshot.routeInUse ?? snapshot.preferredRoute
        )

        return FleetSparkSummary(
            id: snapshot.identity.description,
            entryID: entryID,
            displayName: snapshot.displayName,
            isCluster: snapshot.identity.isClusterTarget,
            connectionLabel: connection.label,
            connectionSymbol: connection.symbol,
            connectionTone: connection.tone,
            connectionPath: connection.pathLabel.map { label in
                FleetSparkConnectionPath(
                    label: label,
                    host: connection.pathHost,
                    symbol: connection.pathSymbol
                )
            },
            isConnected: snapshot.connectionState.isConnectedTarget,
            evidenceAge: snapshot.evidenceAge,
            memoryTotalBytes: snapshot.unifiedMemory.map {
                SparkMemoryCapacity.installedBytes(reportedBytes: $0.totalBytes)
            },
            memoryUsedBytes: snapshot.unifiedMemory.map { $0.totalBytes - $0.availableBytes },
            memoryPressure: snapshot.unifiedMemory?.pressure ?? .unknown,
            temperatureCelsius: snapshot.temperatureCelsius,
            inferenceModelName: runningModelName,
            inferenceLoadingModelName: loadingModelName,
            inferenceLoadingStage: loadOperation?.stage,
            inferenceLoadingFraction: loadOperation?.progress,
            inferenceProfileID: inference?.profileID,
            inferenceTokensPerSecond: inference?.tokensPerSecond,
            loadedModelNames: loaded,
            memberReadyCount: snapshot.members.count(where: \.reachable),
            memberTotalCount: snapshot.members.count
        )
    }

    private static func connectionTallies(
        from summaries: [FleetSparkSummary]
    ) -> [FleetConnectionTally] {
        var tallies: [String: FleetConnectionTally] = [:]
        for spark in summaries {
            let existing = tallies[spark.connectionLabel]
            tallies[spark.connectionLabel] = FleetConnectionTally(
                label: spark.connectionLabel,
                symbol: spark.connectionSymbol,
                tone: spark.connectionTone,
                count: (existing?.count ?? 0) + 1
            )
        }
        return tallies.values.sorted {
            $0.count == $1.count ? $0.label < $1.label : $0.count > $1.count
        }
    }

    private static func matrix(
        from summaries: [FleetSparkSummary],
        targets: [FleetOverviewTarget]
    ) -> [FleetModelMatrixRow] {
        let byID = Dictionary(
            targets.map { ($0.snapshot.identity.description, $0.snapshot) },
            uniquingKeysWith: { first, _ in first }
        )
        var order: [String] = []
        var cells: [String: [FleetModelMatrixCell]] = [:]
        for spark in summaries {
            guard let snapshot = byID[spark.id] else { continue }
            for placement in snapshot.placements where placement.state != .available {
                let name = placement.displayName
                if cells[name] == nil {
                    order.append(name)
                    cells[name] = []
                }
                cells[name]?.append(
                    FleetModelMatrixCell(
                        sparkName: spark.displayName,
                        stateLabel: matrixLabel(placement.state),
                        state: placement.state,
                        isRunning: placement.state == .running
                    )
                )
            }
        }
        return
            order
            .map { FleetModelMatrixRow(modelName: $0, placements: cells[$0] ?? []) }
            .sorted { lhs, rhs in
                let lhsRunning = lhs.placements.contains(where: \.isRunning)
                let rhsRunning = rhs.placements.contains(where: \.isRunning)
                if lhsRunning != rhsRunning { return lhsRunning }
                if lhs.placements.count != rhs.placements.count {
                    return lhs.placements.count > rhs.placements.count
                }
                return lhs.modelName.localizedCaseInsensitiveCompare(rhs.modelName)
                    == .orderedAscending
            }
    }

    static func matrixLabel(_ state: ModelPlacementState) -> String {
        switch state {
        case .available: String(localized: "Available")
        case .downloading: String(localized: "Downloading")
        case .installed: String(localized: "Installed")
        case .starting: String(localized: "Starting")
        case .running: String(localized: "Running")
        case .stopping: String(localized: "Stopping")
        case .failed: String(localized: "Failed")
        case .incompatible: String(localized: "Incompatible")
        case .unknown: String(localized: "Unknown")
        }
    }
}

extension FleetFormat {
    static func celsius(_ value: Double) -> String {
        Measurement(value: value, unit: UnitTemperature.celsius)
            .formatted(
                .measurement(
                    width: .narrow,
                    usage: .asProvided,
                    numberFormatStyle: .number.precision(.fractionLength(0))
                )
            )
    }
}

extension FleetSparkSummary {
    var memoryLabel: String {
        guard let total = memoryTotalBytes, let used = memoryUsedBytes else {
            return String(localized: "Memory not reported")
        }
        return String(
            localized: .memoryUsedInUse(
                used: FleetFormat.gigabytes(used),
                total: FleetFormat.gigabytes(total)
            )
        )
    }

    var memoryShortLabel: String {
        guard let total = memoryTotalBytes, let used = memoryUsedBytes else {
            return String(localized: "Not reported")
        }
        return String(
            localized: .memoryUsedOfTotal(
                used: FleetFormat.gigabytes(used),
                total: FleetFormat.gigabytes(total)
            )
        )
    }

    var memoryPressurePresentation: FleetMemoryPressurePresentation {
        FleetMemoryPressurePresentation.make(
            pressure: memoryPressure,
            used: memoryUsedBytes,
            total: memoryTotalBytes
        )
    }
}

extension FleetTone {
    var color: Color {
        switch self {
        case .positive: .green
        case .neutral: .secondary
        case .caution: .orange
        case .critical: .red
        }
    }
}

extension SparkMemoryPressure {
    /// Describes memory pressure without labelling ordinary high usage as an emergency.
    var word: String {
        switch self {
        case .unknown: String(localized: "Not reported")
        case .normal: String(localized: "Normal")
        case .warning: String(localized: "Elevated")
        case .critical: String(localized: "High")
        case .emergency: String(localized: "Very high")
        }
    }

    var severity: Int {
        switch self {
        case .unknown: 0
        case .normal: 1
        case .warning: 2
        case .critical: 3
        case .emergency: 4
        }
    }

    var tone: FleetTone {
        switch self {
        case .normal: .positive
        case .unknown: .neutral
        case .warning, .critical: .caution
        case .emergency: .critical
        }
    }

    var color: Color {
        switch self {
        case .normal: .green
        case .warning: .yellow
        case .critical: .orange
        case .emergency: .red
        case .unknown: .secondary
        }
    }
}

/// Classify memory fullness from current usage rather than a latched runtime guard state.
struct FleetMemoryPressurePresentation: Equatable, Sendable {
    let label: String
    let tone: FleetTone
    let severity: Int

    static let notReported = FleetMemoryPressurePresentation(
        label: String(localized: "Memory pressure not reported"),
        tone: .neutral,
        severity: 0
    )

    static func make(
        pressure: SparkMemoryPressure,
        used: Int64?,
        total: Int64?
    ) -> FleetMemoryPressurePresentation {
        if let used, let total, total > 0 {
            let fraction = Double(max(0, used)) / Double(total)
            return switch fraction {
            case ..<0.25:
                FleetMemoryPressurePresentation(
                    label: String(localized: "Very low"),
                    tone: .positive,
                    severity: 1
                )
            case ..<0.50:
                FleetMemoryPressurePresentation(
                    label: String(localized: "Low"),
                    tone: .positive,
                    severity: 2
                )
            case ..<0.70:
                FleetMemoryPressurePresentation(
                    label: String(localized: "Moderate"),
                    tone: .neutral,
                    severity: 3
                )
            case ..<0.90:
                FleetMemoryPressurePresentation(
                    label: String(localized: "High"),
                    tone: .caution,
                    severity: 4
                )
            default:
                FleetMemoryPressurePresentation(
                    label: String(localized: "Very high"),
                    tone: .critical,
                    severity: 5
                )
            }
        }
        return FleetMemoryPressurePresentation(
            label: pressure.word,
            tone: pressure.tone,
            severity: pressure.severity
        )
    }
}

/// Colour memory fill according to utilization rather than historical guard pressure.
enum FleetMemoryFill {
    static func color(used: Int64, total: Int64) -> Color {
        guard total > 0 else { return .secondary }
        let fraction = Double(used) / Double(total)
        return switch fraction {
        case ..<0.70: .green
        case ..<0.90: .orange
        default: .red
        }
    }
}

/// Normalises kernel-reported memory within ten percent of known Spark capacities for consistent capacity labels across surfaces.
enum SparkMemoryCapacity {
    static func installedBytes(reportedBytes: Int64) -> Int64 {
        SparkInstalledMemoryCapacity.installedBytes(reportedBytes: reportedBytes)
    }
}

extension ModelPlacementState {
    var tint: Color {
        switch self {
        case .running: .green
        case .starting, .downloading: .blue
        case .failed, .incompatible: .red
        case .stopping: .orange
        case .installed, .available, .unknown: .secondary
        }
    }
}

extension TargetConnectionState {
    var isConnectedTarget: Bool {
        switch self {
        case .connectedWiFi, .connectedDirect, .connectedRemote: true
        default: false
        }
    }
}

extension SparkTargetIdentity {
    var isClusterTarget: Bool {
        if case .cluster = self { return true }
        return false
    }
}
