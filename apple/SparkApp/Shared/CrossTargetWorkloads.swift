import Foundation
import Observation
import SparkCore

public enum WorkloadDisplayState: String, CaseIterable, Sendable, Equatable {
    case running
    case installed
    case downloading
    case planned
    case degraded
    case blocked
    case notPresent
    case unknown

    public var label: String {
        switch self {
        case .running: String(localized: "Running")
        case .installed: String(localized: "Installed")
        case .downloading: String(localized: "Downloading")
        case .planned: String(localized: "Planned")
        case .degraded: String(localized: "Degraded")
        case .blocked: String(localized: "Blocked")
        case .notPresent: String(localized: "Not present")
        case .unknown: String(localized: "Unknown")
        }
    }

    public var symbolName: String {
        switch self {
        case .running: "play.circle.fill"
        case .installed: "checkmark.circle.fill"
        case .downloading: "arrow.down.circle.fill"
        case .planned: "clock.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .blocked: "xmark.octagon.fill"
        case .notPresent: "minus.circle"
        case .unknown: "questionmark.circle"
        }
    }

    public var needsAttention: Bool {
        self == .degraded || self == .blocked || self == .unknown
    }
}

public enum WorkloadEvidenceState: String, Sendable, Equatable {
    case current
    case stale
    case missing

    public var label: String {
        switch self {
        case .current: String(localized: "Current evidence")
        case .stale: String(localized: "Stale evidence")
        case .missing: String(localized: "Evidence missing")
        }
    }
}

public enum WorkloadMemberState: String, Sendable, Equatable {
    case ready
    case degraded
    case unknown

    public var label: String {
        switch self {
        case .ready: String(localized: "Ready")
        case .degraded: String(localized: "Degraded")
        case .unknown: String(localized: "Unknown")
        }
    }

    public var symbolName: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .degraded: "exclamationmark.triangle.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

public struct WorkloadMemberPresentation: Sendable, Equatable, Identifiable {
    public let id: SparkNodeID
    public let name: String
    public let role: String
    public let state: WorkloadMemberState
    public let detail: String
    public let lastContact: Date?

    public init(
        id: SparkNodeID,
        name: String,
        role: String,
        state: WorkloadMemberState,
        detail: String,
        lastContact: Date?
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.state = state
        self.detail = detail
        self.lastContact = lastContact
    }

    public var accessibilitySummary: String {
        String(
            localized: .pair(
                .init(stringLiteral: name),
                .init(
                    stringLiteral: String(localized: .triple(role, state.label, detail))
                )
            )
        )
    }
}

public enum WorkloadTargetKind: Sendable, Equatable {
    case spark
    case cluster

    public var label: String {
        switch self {
        case .spark: String(localized: "Spark")
        case .cluster: String(localized: "Cluster")
        }
    }
}

public enum WorkloadClusterHealth: Sendable, Equatable {
    case notApplicable
    case healthy
    case degraded
    case unknown
}

public struct WorkloadPerformancePresentation: Sendable, Equatable {
    public let memoryLabel: String
    public let diskLabel: String
    public let activeRequestsLabel: String
    public let queueDepthLabel: String
    public let throughputLabel: String
    public let latencyLabel: String

    public init(
        memoryLabel: String,
        diskLabel: String,
        activeRequestsLabel: String,
        queueDepthLabel: String,
        throughputLabel: String,
        latencyLabel: String
    ) {
        self.memoryLabel = memoryLabel
        self.diskLabel = diskLabel
        self.activeRequestsLabel = activeRequestsLabel
        self.queueDepthLabel = queueDepthLabel
        self.throughputLabel = throughputLabel
        self.latencyLabel = latencyLabel
    }
}

public struct WorkloadTargetColumn: Sendable, Equatable, Identifiable {
    public let id: SparkTargetIdentity
    public let name: String
    public let kind: WorkloadTargetKind
    public let connectionLabel: String
    public let evidenceLabel: String
    public let memberSummary: String
    public let clusterHealth: WorkloadClusterHealth
    public let members: [WorkloadMemberPresentation]
    public let runtimeVersion: String
    public let runtimeHealthLabel: String
    public let updateLabel: String
    public let performance: WorkloadPerformancePresentation
    public let technicalIdentity: String
    public let warnings: [String]
    public let blockers: [String]

    public init(
        id: SparkTargetIdentity,
        name: String,
        kind: WorkloadTargetKind,
        connectionLabel: String,
        evidenceLabel: String,
        memberSummary: String,
        clusterHealth: WorkloadClusterHealth,
        members: [WorkloadMemberPresentation],
        runtimeVersion: String,
        runtimeHealthLabel: String,
        updateLabel: String,
        performance: WorkloadPerformancePresentation,
        technicalIdentity: String,
        warnings: [String],
        blockers: [String]
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.connectionLabel = connectionLabel
        self.evidenceLabel = evidenceLabel
        self.memberSummary = memberSummary
        self.clusterHealth = clusterHealth
        self.members = members
        self.runtimeVersion = runtimeVersion
        self.runtimeHealthLabel = runtimeHealthLabel
        self.updateLabel = updateLabel
        self.performance = performance
        self.technicalIdentity = technicalIdentity
        self.warnings = warnings
        self.blockers = blockers
    }

    public var accessibilitySummary: String {
        [name, kind.label, connectionLabel, evidenceLabel, memberSummary]
            .joined(separator: ", ")
    }
}

public struct WorkloadCellID: Hashable, Sendable {
    public let model: ModelPlacementIdentity
    public let target: SparkTargetIdentity

    public init(model: ModelPlacementIdentity, target: SparkTargetIdentity) {
        self.model = model
        self.target = target
    }
}

public struct WorkloadCellPresentation: Sendable, Equatable, Identifiable {
    public let id: WorkloadCellID
    public let state: WorkloadDisplayState
    public let evidence: WorkloadEvidenceState
    public let detail: String

    public init(
        id: WorkloadCellID,
        state: WorkloadDisplayState,
        evidence: WorkloadEvidenceState,
        detail: String
    ) {
        self.id = id
        self.state = state
        self.evidence = evidence
        self.detail = detail
    }

    public var accessibilitySummary: String {
        String(localized: .triple(state.label, evidence.label, detail))
    }
}

public struct WorkloadRowPresentation: Sendable, Equatable, Identifiable {
    public let id: ModelPlacementIdentity
    public let name: String
    public let versionLabel: String
    public let cells: [WorkloadCellPresentation]

    public init(
        id: ModelPlacementIdentity,
        name: String,
        versionLabel: String,
        cells: [WorkloadCellPresentation]
    ) {
        self.id = id
        self.name = name
        self.versionLabel = versionLabel
        self.cells = cells
    }

    public func cell(for targetID: SparkTargetIdentity) -> WorkloadCellPresentation? {
        cells.first { $0.id.target == targetID }
    }
}

public struct WorkloadComparisonSnapshot: Sendable, Equatable {
    public let generatedAt: Date
    public let targets: [WorkloadTargetColumn]
    public let rows: [WorkloadRowPresentation]

    public init(
        generatedAt: Date,
        targets: [WorkloadTargetColumn],
        rows: [WorkloadRowPresentation]
    ) {
        self.generatedAt = generatedAt
        self.targets = targets
        self.rows = rows
    }

    public static let empty = WorkloadComparisonSnapshot(
        generatedAt: .distantPast,
        targets: [],
        rows: []
    )
}
