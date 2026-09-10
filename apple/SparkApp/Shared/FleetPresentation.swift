import Foundation
import Observation
import SparkCore
import SparkLibrary

// Derives Fleet presentation without I/O, representing absent evidence as Unknown and keeping technical identities in details.

// MARK: - Query

/// Connection filter for the Fleet list.
public enum FleetConnectionFilter: String, CaseIterable, Sendable, Equatable, Identifiable {
    case any
    case connected
    case delayed
    case offline
    case needsAttention

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .any: String(localized: "Any connection")
        case .connected: String(localized: "Connected")
        case .delayed: String(localized: "Delayed")
        case .offline: String(localized: "Offline")
        case .needsAttention: String(localized: "Needs attention")
        }
    }
}

/// Keeps unknown update status selectable and distinct from an up-to-date target.
public enum FleetUpdateFilter: String, CaseIterable, Sendable, Equatable, Identifiable {
    case any
    case current
    case updateAvailable
    case updateRequired
    case unknown

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .any: String(localized: "Any update state")
        case .current: String(localized: "Up to date")
        case .updateAvailable: String(localized: "Update available")
        case .updateRequired: String(localized: "Update required")
        case .unknown: String(localized: "Update state unknown")
        }
    }
}

/// Filter standalone targets separately from logical clusters (§10.8).
public enum FleetMembershipFilter: String, CaseIterable, Sendable, Equatable, Identifiable {
    case any
    case standalone
    case cluster

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .any: String(localized: "Any membership")
        case .standalone: String(localized: "Single Sparks")
        case .cluster: String(localized: "Clusters")
        }
    }
}

/// Persists search and filter selection outside the view so navigation does not reset it.
public struct FleetQuery: Sendable, Equatable {
    public var searchText: String
    public var connection: FleetConnectionFilter
    public var update: FleetUpdateFilter
    /// Friendly model name chosen from `FleetPresentation.installedModelOptions`.
    public var installedModel: String?
    public var membership: FleetMembershipFilter

    public init(
        searchText: String = "",
        connection: FleetConnectionFilter = .any,
        update: FleetUpdateFilter = .any,
        installedModel: String? = nil,
        membership: FleetMembershipFilter = .any
    ) {
        self.searchText = searchText
        self.connection = connection
        self.update = update
        self.installedModel = installedModel
        self.membership = membership
    }

    public static let unfiltered = FleetQuery()

    /// Offer Clear Filters only when the current list is narrowed.
    public var isFiltering: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || connection != .any
            || update != .any
            || installedModel != nil
            || membership != .any
    }
}

// MARK: - Card presentation

/// Pairs chip colour with a label and symbol so colour is never the sole state indicator.
public enum FleetTone: String, Sendable, Equatable {
    case positive
    case neutral
    case caution
    case critical
}

/// Uses the Spark product image for both card kinds, adding a badge for clusters.
public enum FleetCardArtwork: Sendable, Equatable {
    case spark
    case cluster(memberCount: Int)
}

/// Plain-language connection state for one target.
public struct FleetConnectionPresentation: Sendable, Equatable {
    public let label: String
    public let symbol: String
    public let tone: FleetTone
    /// Indicates an active contact attempt with progress that remains visible under Reduced Motion.
    public let isChecking: Bool
    /// The path in use ("On your network" or "Over Tailscale") and, when remote, the host it is reached by.
    public let pathLabel: String?
    public let pathHost: String?
    public let pathSymbol: String
    public let pathAccessibilityLabel: String?

    public init(
        label: String,
        symbol: String,
        tone: FleetTone,
        isChecking: Bool,
        pathLabel: String? = nil,
        pathHost: String? = nil,
        pathSymbol: String = "network",
        pathAccessibilityLabel: String? = nil
    ) {
        self.label = label
        self.symbol = symbol
        self.tone = tone
        self.isChecking = isChecking
        self.pathLabel = pathLabel
        self.pathHost = pathHost
        self.pathSymbol = pathSymbol
        self.pathAccessibilityLabel = pathAccessibilityLabel
    }
}

/// A recovery or navigation action offered on a card.
public enum FleetCardAction: String, Sendable, Equatable, Identifiable, CaseIterable {
    case open
    case checkAgain
    case remove

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .open: String(localized: "Connect")
        case .checkAgain: String(localized: "Check Again")
        case .remove: String(localized: "Remove Entry…")
        }
    }

    public var symbol: String {
        switch self {
        case .open: "bolt.horizontal.circle"
        case .checkAgain: "arrow.clockwise"
        case .remove: "trash"
        }
    }

    public var isDestructive: Bool { self == .remove }

    func accessibilityLabel(for targetName: String) -> String {
        switch self {
        case .open: String(localized: .connectTo(targetName))
        case .checkAgain: String(localized: .checkResourceAgain(targetName))
        case .remove: String(localized: .removeFromThisDevice(targetName))
        }
    }
}

/// One member node inside a logical cluster, for the card's membership row.
public struct FleetMemberPresentation: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let role: String
    public let reachability: String
    public let tone: FleetTone

    public init(id: String, name: String, role: String, reachability: String, tone: FleetTone) {
        self.id = id
        self.name = name
        self.role = role
        self.reachability = reachability
        self.tone = tone
    }
}

/// Supplies fully formatted Fleet card fields, using Unknown wherever authenticated evidence is absent.
public struct FleetCardPresentation: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let artwork: FleetCardArtwork
    public let connection: FleetConnectionPresentation
    public let lastContact: String
    public let availableMemory: String
    public let activeModel: String
    public let installedModels: String
    public let membership: String
    public let members: [FleetMemberPresentation]
    public let warnings: [String]
    public let blockers: [String]
    /// Marks values retained from a previous contact rather than observed during this attempt.
    public let evidenceNote: String?
    public let actions: [FleetCardAction]
    public let accessibilityLabel: String

    public init(
        id: String,
        name: String,
        artwork: FleetCardArtwork,
        connection: FleetConnectionPresentation,
        lastContact: String,
        availableMemory: String,
        activeModel: String,
        installedModels: String,
        membership: String,
        members: [FleetMemberPresentation],
        warnings: [String],
        blockers: [String],
        evidenceNote: String?,
        actions: [FleetCardAction],
        accessibilityLabel: String
    ) {
        self.id = id
        self.name = name
        self.artwork = artwork
        self.connection = connection
        self.lastContact = lastContact
        self.availableMemory = availableMemory
        self.activeModel = activeModel
        self.installedModels = installedModels
        self.membership = membership
        self.members = members
        self.warnings = warnings
        self.blockers = blockers
        self.evidenceNote = evidenceNote
        self.actions = actions
        self.accessibilityLabel = accessibilityLabel
    }

    public var needsAttention: Bool { !blockers.isEmpty || !warnings.isEmpty }
}

// MARK: - Summary

/// One tile in the Fleet summary strip.
public struct FleetSummaryItem: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let value: String
    public let symbol: String

    public init(id: String, title: String, value: String, symbol: String) {
        self.id = id
        self.title = title
        self.value = value
        self.symbol = symbol
    }
}

/// Counts the entire library independently of the active search and filters.
public struct FleetSummaryPresentation: Sendable, Equatable {
    public let targetCount: Int
    public let connectedCount: Int
    public let delayedCount: Int
    public let offlineCount: Int
    public let activeModelCount: Int
    public let warningCount: Int
    /// Count blocked targets separately from warnings.
    public let blockerCount: Int
    public let availableUnifiedMemory: String
    /// Names how much of the fleet the memory total actually covers.
    public let memoryEvidenceNote: String
    public let items: [FleetSummaryItem]
    public let accessibilityLabel: String

    public init(
        targetCount: Int,
        connectedCount: Int,
        delayedCount: Int,
        offlineCount: Int,
        activeModelCount: Int,
        warningCount: Int,
        blockerCount: Int,
        availableUnifiedMemory: String,
        memoryEvidenceNote: String,
        items: [FleetSummaryItem],
        accessibilityLabel: String
    ) {
        self.targetCount = targetCount
        self.connectedCount = connectedCount
        self.delayedCount = delayedCount
        self.offlineCount = offlineCount
        self.activeModelCount = activeModelCount
        self.warningCount = warningCount
        self.blockerCount = blockerCount
        self.availableUnifiedMemory = availableUnifiedMemory
        self.memoryEvidenceNote = memoryEvidenceNote
        self.items = items
        self.accessibilityLabel = accessibilityLabel
    }
}

// MARK: - Whole-surface state

/// Reports when library changes are retained only for the current session.
public struct FleetStorageNotice: Sendable, Equatable {
    public let title: String
    public let message: String
    public let actionTitle: String

    public init(title: String, message: String, actionTitle: String) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
    }

    var actionAccessibilityLabel: String {
        String(localized: .retrySavingLibrary(actionTitle))
    }
}

/// What the Fleet list is showing right now.
public enum FleetContentState: Sendable, Equatable {
    /// No paired targets exist at all. Offers Add Spark.
    case empty
    /// Targets exist but the current query matches none. Offers Clear Filters.
    case filteredEmpty(totalCount: Int)
    case cards([FleetCardPresentation])
}

/// The complete Fleet surface.
public struct FleetPresentation: Sendable, Equatable {
    public let summary: FleetSummaryPresentation
    public let content: FleetContentState
    public let storageNotice: FleetStorageNotice?
    /// Friendly model names available to the installed-model filter.
    public let installedModelOptions: [String]
    public let visibleCount: Int
    public let totalCount: Int

    public init(
        summary: FleetSummaryPresentation,
        content: FleetContentState,
        storageNotice: FleetStorageNotice?,
        installedModelOptions: [String],
        visibleCount: Int,
        totalCount: Int
    ) {
        self.summary = summary
        self.content = content
        self.storageNotice = storageNotice
        self.installedModelOptions = installedModelOptions
        self.visibleCount = visibleCount
        self.totalCount = totalCount
    }

    public var cards: [FleetCardPresentation] {
        if case .cards(let cards) = content { return cards }
        return []
    }
}

// MARK: - Details

public struct FleetDetailRow: Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String
    public let value: String

    public init(id: String, label: String, value: String) {
        self.id = id
        self.label = label
        self.value = value
    }
}

public struct FleetDetailSection: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let rows: [FleetDetailRow]

    public init(id: String, title: String, rows: [FleetDetailRow]) {
        self.id = id
        self.title = title
        self.rows = rows
    }
}

/// Keeps logical identities, member IDs, routes and stable notice codes in the target inspector.
public struct FleetDetailsPresentation: Sendable, Equatable {
    public let id: String
    public let title: String
    public let sections: [FleetDetailSection]

    public init(id: String, title: String, sections: [FleetDetailSection]) {
        self.id = id
        self.title = title
        self.sections = sections
    }
}

// MARK: - Input

/// Combine shared operational evidence with device-local library facts for each fleet target.
public struct FleetTargetInput: Sendable, Equatable {
    public let id: String
    public let snapshot: TargetOperationalSnapshot
    public let canOpen: Bool
    public let hasIdentityIssue: Bool
    public let isExternallyConfiguredCluster: Bool

    public init(
        id: String,
        snapshot: TargetOperationalSnapshot,
        canOpen: Bool,
        hasIdentityIssue: Bool,
        isExternallyConfiguredCluster: Bool = false
    ) {
        self.id = id
        self.snapshot = snapshot
        self.canOpen = canOpen
        self.hasIdentityIssue = hasIdentityIssue
        self.isExternallyConfiguredCluster = isExternallyConfiguredCluster
    }

    public init(entry: LibraryEntry, snapshot: TargetOperationalSnapshot) {
        self.init(
            id: entry.id,
            snapshot: snapshot,
            canOpen: entry.canOpen,
            hasIdentityIssue: entry.issue == .identityMismatch,
            isExternallyConfiguredCluster: entry.externalClusterRegistration != nil
        )
    }

    /// Creates an Unknown operational account for entries without snapshots so every paired Spark remains visible.
    public init(
        entry: LibraryEntry,
        snapshot: TargetOperationalSnapshot?,
        at date: Date,
        composer: TargetOperationalSnapshotComposer = TargetOperationalSnapshotComposer()
    ) {
        self.init(
            entry: entry,
            snapshot: snapshot ?? composer.cachedSnapshot(entry: entry, at: date)
        )
    }
}

// MARK: - Focus order

/// Declares card reading and focus order explicitly so layout changes cannot silently reorder accessibility navigation.
public enum FleetFocusOrder {
    public enum Element: String, CaseIterable, Sendable {
        case name
        case connection
        case activity
        case actions
    }

    /// Visual top-to-bottom order of one card.
    public static let card: [Element] = [.name, .connection, .activity, .actions]

    /// Whether a proposed order matches the visual one.
    public static func follows(visualOrder proposed: [Element]) -> Bool {
        proposed == card
    }

    /// The accessibility sort priority that keeps an element in its visual place; higher reads first.
    public static func priority(for element: Element) -> Double {
        let index = card.firstIndex(of: element) ?? card.count
        return Double(card.count - index)
    }
}

// MARK: - Motion

/// Suppress decorative motion while preserving progress feedback for real checks under Reduce Motion.
public enum FleetMotion {
    public static func shouldAnimateConnectionPulse(
        tone: FleetTone,
        reduceMotion: Bool
    ) -> Bool {
        tone == .positive && !reduceMotion
    }

    public static func shouldShowCheckProgress(isChecking: Bool, reduceMotion: Bool) -> Bool {
        isChecking
    }
}

// MARK: - Formatting

/// Keep fixed fleet value formatting deterministic for exact-string checks.
public enum FleetFormat {
    public static let unknown = String(localized: "Unknown")

    /// Uses coarse relative ages appropriate to the freshness of cached Spark evidence.
    public static func elapsed(_ seconds: TimeInterval) -> String {
        let clamped = max(0, seconds)
        if clamped < 60 { return String(localized: "Just now") }
        if clamped < 3_600 {
            let minutes = Int(clamped / 60)
            return String(localized: .minutesAgo(minutes))
        }
        if clamped < 86_400 {
            let hours = Int(clamped / 3_600)
            return String(localized: .hoursAgo(hours))
        }
        let days = Int(clamped / 86_400)
        return String(localized: .daysAgo(days))
    }

    /// Round displayed unified-memory gigabytes to one decimal place.
    public static func gigabytes(_ bytes: Int64) -> String {
        let value = Double(max(0, bytes)) / 1_000_000_000
        return Measurement(value: value, unit: UnitInformationStorage.gigabytes)
            .formatted(
                .measurement(
                    width: .abbreviated,
                    numberFormatStyle: .number.precision(.fractionLength(1))
                )
            )
    }
}

/// The filter row earns its space only once there is more than one Spark to tell apart.
public enum FleetFilterPresentation {
    public static func showsExpandedFilters(totalCount: Int) -> Bool { totalCount >= 2 }
}
