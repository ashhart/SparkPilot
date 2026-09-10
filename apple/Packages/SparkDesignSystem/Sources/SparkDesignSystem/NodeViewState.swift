import Foundation
import SparkCore

/// View-state for the home dashboard (§62.1/§62.2 presentation, §41.5 card).
public enum NodeStatusBadge: String, Sendable, Equatable {
    case probing
    case ready
    case degraded
    case blocked
    case offline
    case needsUpdate
}

/// What the user can do from the home surface.
public enum NodeAction: Equatable, Sendable {
    case open
    case continueSetup
    case retry
    case reviewRecovery
    case update
    case none
}

/// Resolved presentation for one connection state (UX state matrix §62.1).
public struct ConnectionPresentation: Equatable, Sendable {
    public let title: String
    public let secondary: String
    public let action: NodeAction

    public init(title: String, secondary: String, action: NodeAction) {
        self.title = title
        self.secondary = secondary
        self.action = action
    }
}

/// Maps internal connection state to human-facing copy and primary action.
public enum NodeStatusPresentation {
    public static func resolve(_ state: SparkConnectionState) -> ConnectionPresentation {
        switch state {
        case .discovering:
            return .init(
                title: String(localized: "Finding your Spark"),
                secondary: String(localized: "Looking on nearby networks"),
                action: .none
            )
        case .foundUnpaired:
            return .init(
                title: String(localized: "DGX Spark found"),
                secondary: String(localized: "Ready to set up or pair"),
                action: .continueSetup
            )
        case .connecting:
            return .init(
                title: String(localized: "Connecting"),
                secondary: String(localized: "Establishing a secure connection"),
                action: .none
            )
        case .connectedWiFi:
            return .init(
                title: String(localized: "Ready"),
                secondary: String(localized: "Local Wi-Fi"),
                action: .open
            )
        case .connectedDirect:
            return .init(
                title: String(localized: "Ready"),
                secondary: String(localized: "Direct 10 GbE"),
                action: .open
            )
        case .connectedRemote:
            return .init(
                title: String(localized: "Ready"),
                secondary: String(localized: "Secure remote connection"),
                action: .open
            )
        case .offlineCached:
            return .init(
                title: String(localized: "Spark is offline"),
                secondary: String(localized: "Showing last known status"),
                action: .retry
            )
        case .identityMismatch:
            return .init(
                title: String(localized: "Connection blocked"),
                secondary: String(localized: "Spark's identity has changed"),
                action: .reviewRecovery
            )
        case .updateRequired:
            return .init(
                title: String(localized: "Update required"),
                secondary: String(localized: "App and runtime are incompatible"),
                action: .update
            )
        }
    }

    public static func badge(for state: SparkConnectionState) -> NodeStatusBadge {
        switch state {
        case .discovering, .connecting: return .probing
        case .connectedDirect, .connectedWiFi, .connectedRemote: return .ready
        case .foundUnpaired: return .degraded
        case .offlineCached: return .offline
        case .identityMismatch: return .blocked
        case .updateRequired: return .needsUpdate
        }
    }
}

/// The home node card's full state (§41.5).
public struct NodeCardState: Equatable, Sendable {
    public let nodeID: SparkNodeID
    public let name: String
    public let connection: SparkConnectionState
    public let connectivitySymbol: String
    public let activeModel: ModelSummary?
    public let usedMemoryBytes: Int64
    public let totalMemoryBytes: Int64
    /// Live memory pressure; `nil` when unknown (nothing to present).
    public let memoryPressure: MemoryPressureLevel?
    /// Chat is only offered on a usable, connected node (§41.5 `canChat`).
    public var canChat: Bool {
        switch connection {
        case .connectedDirect, .connectedWiFi, .connectedRemote: return true
        default: return false
        }
    }

    public struct ModelSummary: Equatable, Sendable {
        public let displayName: String
        public let performanceSummary: String

        public init(displayName: String, performanceSummary: String) {
            self.displayName = displayName
            self.performanceSummary = performanceSummary
        }
    }

    public init(
        nodeID: SparkNodeID,
        name: String,
        connection: SparkConnectionState,
        activeModel: ModelSummary?,
        usedMemoryBytes: Int64,
        totalMemoryBytes: Int64,
        memoryPressure: MemoryPressureLevel? = nil
    ) {
        self.nodeID = nodeID
        self.name = name
        self.connection = connection
        self.connectivitySymbol = symbol(for: connection)
        self.activeModel = activeModel
        self.usedMemoryBytes = usedMemoryBytes
        self.totalMemoryBytes = totalMemoryBytes
        self.memoryPressure = memoryPressure
    }

    public var presentation: ConnectionPresentation {
        NodeStatusPresentation.resolve(connection)
    }

    /// Pressure banner copy and recovery actions; `nil` hides the banner.
    public var pressurePresentation: MemoryPressurePresentation? {
        memoryPressure.flatMap(MemoryPressurePresentationResolver.resolve)
    }

    public var badge: NodeStatusBadge {
        NodeStatusPresentation.badge(for: connection)
    }

    /// Human-readable unified-memory summary (GiB, one decimal).
    public var formattedMemory: String {
        let total = Double(max(totalMemoryBytes, 1)) / 1_000_000_000
        let used = Double(max(usedMemoryBytes, 0)) / 1_000_000_000
        return String(
            localized: .usedOfTotalGigabytes(
                used: used.formatted(.number.precision(.fractionLength(1))),
                total: Measurement(value: total, unit: UnitInformationStorage.gigabytes)
                    .formatted(
                        .measurement(
                            width: .abbreviated,
                            numberFormatStyle: .number.precision(.fractionLength(1))
                        )
                    )
            )
        )
    }
}

/// State for the empty/offline/permission-denied dashboard states (§41.1).
public struct DashboardEmptyState: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case noNodes
        case permissionDenied
        case permissionRestricted
        case allOffline
    }

    public let kind: Kind
    public let title: String
    public let message: String
    public let actionLabel: String?

    public init(kind: Kind) {
        self.kind = kind
        switch kind {
        case .noNodes:
            self.title = String(localized: "No Spark Found")
            self.message = String(
                localized: "Plug in a cable or put your Spark on this network, then look again."
            )
            self.actionLabel = String(localized: "Look Again")
        case .permissionDenied:
            self.title = String(localized: "Local Network Access Off")
            self.message = String(
                localized: "Enable Local Network access for Spark to discover your hardware."
            )
            self.actionLabel = String(localized: "Open Settings")
        case .permissionRestricted:
            self.title = String(localized: "Local Network Restricted")
            self.message = String(localized: "A system restriction is blocking discovery.")
            self.actionLabel = nil
        case .allOffline:
            self.title = String(localized: "Spark is Offline")
            self.message = String(
                localized: "We're showing the last known status while reconnecting."
            )
            self.actionLabel = String(localized: "Retry")
        }
    }
}

private func symbol(for state: SparkConnectionState) -> String {
    switch state {
    case .connectedDirect: return "cable.connector"
    case .connectedWiFi: return "wifi"
    case .connectedRemote: return "globe"
    case .discovering, .connecting: return "magnifyingglass"
    case .foundUnpaired: return "arkit"
    case .offlineCached: return "arrow.clockwise"
    case .identityMismatch: return "lock.trianglebadge.exclamationmark"
    case .updateRequired: return "arrow.down.circle"
    }
}
