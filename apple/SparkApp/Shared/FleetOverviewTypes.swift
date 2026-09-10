import Foundation
import SparkCore
import SparkDesignSystem
import SparkWidgetSupport
import SwiftUI

// MARK: - Read model

/// Cards the owner can show, hide, and reorder on the fleet overview.
public enum FleetCardKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case runningInference
    case fleetMemory
    case loadedModels
    case clusters
    case temperatures
    case connectivity

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .runningInference: String(localized: "Running Inference")
        case .fleetMemory: String(localized: "Fleet Memory")
        case .loadedModels: String(localized: "Models Across Sparks")
        case .clusters: String(localized: "Clusters")
        case .temperatures: String(localized: "Temperatures")
        case .connectivity: String(localized: "Connectivity")
        }
    }

    public var symbol: String {
        switch self {
        case .runningInference: "waveform"
        case .fleetMemory: "memorychip"
        case .loadedModels: "shippingbox"
        case .clusters: "point.3.connected.trianglepath.dotted"
        case .temperatures: "thermometer.medium"
        case .connectivity: "antenna.radiowaves.left.and.right"
        }
    }
}

/// The route a Spark is answering on, in the owner's words rather than the transport's.
public struct FleetSparkConnectionPath: Equatable, Sendable {
    public let label: String
    /// Named only for a remote path; a local one does not repeat the address.
    public let host: String?
    public let symbol: String

    /// The whole path on one line: "On your network", or "Over Tailscale · host".
    public var summary: String {
        guard let host else { return label }
        return String(localized: .joined(label, host))
    }

    public var spokenSummary: String {
        guard let host else { return label }
        return String(localized: .pair(label, host))
    }
}

/// One Spark's contribution to the overview, derived only from its snapshot.
public struct FleetSparkSummary: Equatable, Identifiable, Sendable {
    public let id: String
    /// The library entry to open when the row is tapped.
    public let entryID: String
    public let displayName: String
    public let isCluster: Bool
    /// Uses the Fleet card's wording, symbol and tone for the same Spark state.
    public let connectionLabel: String
    public let connectionSymbol: String
    public let connectionTone: FleetTone
    /// The route in use, when the Spark is answering on one Home can name.
    public var connectionPath: FleetSparkConnectionPath? = nil
    public let isConnected: Bool
    public let evidenceAge: TimeInterval?
    public let memoryTotalBytes: Int64?
    public let memoryUsedBytes: Int64?
    public let memoryPressure: SparkMemoryPressure
    public let temperatureCelsius: Double?
    public let inferenceModelName: String?
    /// The model a Spark is loading right now; Home shows this instead of offering a launch.
    public var inferenceLoadingModelName: String? = nil
    /// The stage the load is in, when the Spark reports an operation for it.
    public var inferenceLoadingStage: String? = nil
    /// How far the load has run, when the operation measures it.
    public var inferenceLoadingFraction: Double? = nil
    public let inferenceProfileID: String?
    public let inferenceTokensPerSecond: Double?
    public let loadedModelNames: [String]
    public let memberReadyCount: Int
    public let memberTotalCount: Int
}

/// One model row in the fleet matrix.
public struct FleetModelMatrixRow: Equatable, Identifiable, Sendable {
    public let modelName: String
    /// Placement cells, one per Spark that holds the model.
    public let placements: [FleetModelMatrixCell]
    public var id: String { modelName }
}

public struct FleetModelMatrixCell: Equatable, Sendable {
    public let sparkName: String
    public let stateLabel: String
    public let state: ModelPlacementState
    public let isRunning: Bool
}

public struct FleetConnectionTally: Equatable, Identifiable, Sendable {
    public let label: String
    public let symbol: String
    public let tone: FleetTone
    public let count: Int
    public var id: String { label }
}

/// The complete overview, built at one shared instant.
public struct FleetOverviewSnapshot: Equatable, Sendable {
    public let generatedAt: Date
    public let sparks: [FleetSparkSummary]
    public let totalMemoryBytes: Int64?
    public let usedMemoryBytes: Int64?
    public let memoryReportedCount: Int
    public let runningInferenceCount: Int
    public let connectedCount: Int
    public let clusterCount: Int
    public let modelMatrix: [FleetModelMatrixRow]
    public let hottestFirst: [FleetSparkSummary]
    public let connectionTallies: [FleetConnectionTally]
    /// Reports the newest fleet reading's age, or nil when no reading exists.
    public let freshestEvidenceAge: TimeInterval?

    public static let empty = FleetOverviewSnapshot(
        generatedAt: .distantPast,
        sparks: [],
        totalMemoryBytes: nil,
        usedMemoryBytes: nil,
        memoryReportedCount: 0,
        runningInferenceCount: 0,
        connectedCount: 0,
        clusterCount: 0,
        modelMatrix: [],
        hottestFirst: [],
        connectionTallies: [],
        freshestEvidenceAge: nil
    )

    public var runningSparks: [FleetSparkSummary] {
        sparks.filter { $0.inferenceModelName != nil }
    }

    public var clusters: [FleetSparkSummary] {
        sparks.filter(\.isCluster)
    }

    public var reportingMemory: [FleetSparkSummary] {
        sparks.filter { $0.memoryTotalBytes != nil }
    }

    public var hottest: FleetSparkSummary? { hottestFirst.first }

    /// The worst memory pressure any reporting Spark is under.
    public var worstMemoryPressure: SparkMemoryPressure {
        reportingMemory.map(\.memoryPressure).max(by: { $0.severity < $1.severity }) ?? .unknown
    }

    /// Classify displayed pressure from memory usage because raw runtime state may remain latched after recovery.
    var memoryPressurePresentation: FleetMemoryPressurePresentation {
        reportingMemory
            .map(\.memoryPressurePresentation)
            .max(by: { $0.severity < $1.severity })
            ?? .notReported
    }
}

/// A library entry paired with its snapshot, so a row can open the Spark.
public struct FleetOverviewTarget: Sendable {
    public let entryID: String
    public let snapshot: TargetOperationalSnapshot

    public init(entryID: String, snapshot: TargetOperationalSnapshot) {
        self.entryID = entryID
        self.snapshot = snapshot
    }
}
