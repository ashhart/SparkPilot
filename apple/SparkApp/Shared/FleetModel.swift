import Foundation
import Observation
import SparkCore
import SparkLibrary

// MARK: - View state

/// Preserves Fleet search, filters and selection while navigating between cards and dashboards.
@MainActor
@Observable
public final class FleetModel {
    public var query = FleetQuery()
    public var selectedID: String?
    public private(set) var checking: Set<String> = []
    /// Counted, so two overlapping checks of one Spark do not clear the spinner after the first ends.
    @ObservationIgnored private var checkCounts: [String: Int] = [:]
    public let dashboard = FleetDashboardModel()

    /// Refreshes visible Sparks more frequently than delayedAfter so healthy cards do not age into a slow state.
    nonisolated public static let liveSweepInterval: Duration = .seconds(15)

    @ObservationIgnored private let library: SparkLibrary
    var launchLibrary: SparkLibrary { library }
    @ObservationIgnored private let now: @Sendable () -> Date

    public init(library: SparkLibrary, now: @escaping @Sendable () -> Date = Date.init) {
        self.library = library
        self.now = now
    }

    /// Maps every paired library entry to a card using cached authenticated evidence with freshness evaluated at read time.
    public var targets: [FleetTargetInput] {
        let date = now()
        return library.entries.map { entry in
            FleetTargetInput(
                entry: entry,
                snapshot: library.operationalSnapshot(for: entry.id, at: date),
                at: date
            )
        }
    }

    public var presentation: FleetPresentation {
        FleetPresentationBuilder.build(
            targets: targets,
            query: query,
            checking: checking,
            storage: library.storageStatus
        )
    }

    /// Clear selected-card details when the card is absent or removed.
    public var selectedDetails: FleetDetailsPresentation? {
        guard let selectedID, let target = targets.first(where: { $0.id == selectedID }) else {
            return nil
        }
        return FleetPresentationBuilder.details(for: target)
    }

    public func clearFilters() {
        query = .unfiltered
    }

    /// Derives the overview from the same library snapshots and evaluation time as the card list.
    public var overview: FleetOverviewSnapshot {
        let date = now()
        return FleetOverviewBuilder.build(
            targets: library.entries.compactMap { entry in
                library.operationalSnapshot(for: entry.id, at: date).map {
                    FleetOverviewTarget(entryID: entry.id, snapshot: $0)
                }
            },
            at: date
        )
    }

    /// What Home shows, decided once from the same overview the cards are drawn from.
    var home: FleetHomePresentation {
        FleetHomeBuilder.build(overview: overview, customization: dashboard.customization)
    }

    public func beginCheck(_ id: String) {
        checkCounts[id, default: 0] += 1
        checking.insert(id)
    }

    public func endCheck(_ id: String) {
        guard let count = checkCounts[id] else { return }
        guard count > 1 else {
            checkCounts[id] = nil
            checking.remove(id)
            return
        }
        checkCounts[id] = count - 1
    }

    /// Drop state belonging to a card that no longer exists.
    public func forget(_ id: String) {
        checkCounts[id] = nil
        checking.remove(id)
        if selectedID == id { selectedID = nil }
    }
}
