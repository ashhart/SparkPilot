import Foundation
import SparkCore

// MARK: - Read model

/// The target count informs wording while customization remains available in either mode.
enum FleetHomeMode: String, Sendable, Equatable {
    case single
    case fleet
}

/// Names a reading so a screen can be checked for saying the same thing twice.
enum FleetHomeReading: String, Sendable, Equatable, CaseIterable {
    case connection
    case model
    case memory
    case temperature
    case online
    case unreachable
    case clusterMembers
    case modelPlacement
}

/// A reading repeats only when it describes the same subject, so a fleet total and one Spark's own figure stay distinct.
struct FleetHomeMetricKey: Hashable, Sendable {
    static let fleetScope = "fleet"

    let scope: String
    let reading: FleetHomeReading

    init(scope: String = FleetHomeMetricKey.fleetScope, reading: FleetHomeReading) {
        self.scope = scope
        self.reading = reading
    }
}

/// One reading, with the words that carry its state so colour is never the only signal.
struct FleetHomeMetric: Sendable, Equatable, Identifiable {
    let key: FleetHomeMetricKey
    let title: String
    let value: String
    let detail: String?
    let symbol: String
    let tone: FleetTone
    /// Set only where a bar can show how full something is.
    var fraction: Double?

    var id: FleetHomeMetricKey { key }

    /// Reads title, value and detail as one sentence.
    var spokenLabel: String {
        guard let detail else { return String(localized: .pair(title, value)) }
        return String(localized: .triple(title, value, detail))
    }
}

/// The one model action a live Spark card offers, mirroring the dashboard header.
enum FleetHomeModelAction: Sendable, Equatable {
    case launch
    case switchModel
    case loading(line: String, fraction: Double?)
    /// Nothing can be launched from here yet, so Home offers no button at all.
    case none

    var title: String {
        switch self {
        case .launch: String(localized: "Launch model")
        case .switchModel: String(localized: "Switch model")
        case .loading, .none: ""
        }
    }

    var symbol: String {
        switch self {
        case .launch: "play.fill"
        case .switchModel: "arrow.triangle.2.circlepath"
        case .loading: "hourglass"
        case .none: ""
        }
    }

    var offersAButton: Bool {
        switch self {
        case .launch, .switchModel: true
        case .loading, .none: false
        }
    }
}

/// One Spark as Home shows it: who it is, how it is reached, what it is doing, and the one thing to do next.
struct FleetHomeSparkCard: Sendable, Equatable, Identifiable {
    let id: String
    /// The library entry to open when the card is tapped.
    let entryID: String
    let name: String
    let isCluster: Bool
    let connection: FleetHomeMetric
    /// The Spark's own readings, in the order Home shows them.
    let metrics: [FleetHomeMetric]
    let action: FleetHomeModelAction
    let freshness: String
    let accessibilityLabel: String

    var metricKeys: [FleetHomeMetricKey] { [connection.key] + metrics.map(\.key) }
}

/// Everything Home presents in one pass, so duplication is a value that can be tested.
struct FleetHomePresentation: Sendable, Equatable {
    let mode: FleetHomeMode
    /// Summary readings for every saved fleet, including a single Spark.
    let rollUp: [FleetHomeMetric]
    let sparks: [FleetHomeSparkCard]
    /// Detail cards in the owner's saved order.
    let fleetCards: [FleetCardKind]
    /// The cards the owner can turn on or off in this mode.
    let customisableCards: [FleetCardKind]
    /// Sparks that did not answer, named by the Connectivity card.
    let unreachableSparkNames: [String]
    /// Model placement rows, including models present on just one Spark.
    let sharedModels: [FleetModelMatrixRow]
    let clusters: [FleetHomeClusterRow]
    var overview: FleetOverviewSnapshot = .empty

    static let empty = FleetHomePresentation(
        mode: .single,
        rollUp: [],
        sparks: [],
        fleetCards: [],
        customisableCards: [],
        unreachableSparkNames: [],
        sharedModels: [],
        clusters: []
    )

    /// Summary and per-Spark reading identities; detail cards keep their own stable card identifiers.
    var metricKeys: [FleetHomeMetricKey] {
        rollUp.map(\.key) + sparks.flatMap(\.metricKeys)
    }

    var showsAnyFleetSection: Bool { !rollUp.isEmpty || !fleetCards.isEmpty }

}

/// One cluster's membership, which the per-Spark card deliberately leaves to the Clusters card.
struct FleetHomeClusterRow: Sendable, Equatable, Identifiable {
    let id: String
    let entryID: String
    let name: String
    let readyCount: Int
    let totalCount: Int
    let isComplete: Bool

    var summary: String {
        String(localized: .clusterMembersReadyCount(ready: readyCount, total: totalCount))
    }
}
