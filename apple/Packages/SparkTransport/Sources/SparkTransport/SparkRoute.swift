import Foundation
import SparkCore

/// Bind sessions, models and jobs to stable identity while keeping SparkRoute a mutable network path (§13.1).
public struct SparkRoute: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let nodeID: SparkNodeID
    public let baseURL: URL
    public let kind: SparkTransportKind
    public let interfaceName: String?
    public let roundTripMilliseconds: Double?
    public let validatedIdentityFingerprint: String?
    public let isMetered: Bool
    public let lastSuccess: Date?

    public init(
        id: UUID = UUID(),
        nodeID: SparkNodeID,
        baseURL: URL,
        kind: SparkTransportKind,
        interfaceName: String?,
        roundTripMilliseconds: Double? = nil,
        validatedIdentityFingerprint: String? = nil,
        isMetered: Bool = false,
        lastSuccess: Date? = nil
    ) {
        self.id = id
        self.nodeID = nodeID
        self.baseURL = baseURL
        self.kind = kind
        self.interfaceName = interfaceName
        self.roundTripMilliseconds = roundTripMilliseconds
        self.validatedIdentityFingerprint = validatedIdentityFingerprint
        self.isMetered = isMetered
        self.lastSuccess = lastSuccess
    }
}

/// Lower ranks win route selection, with rejected routes ordered after every usable route.
public enum RouteRank: Int, Comparable, Sendable {
    case directEthernetPinned = 1
    case localWiFiPinned = 2
    case privateOverlay = 3
    case degraded = 4
    case offlineCache = 5
    /// Represent mismatched identity separately from unavailable or stale routes.
    case rejected = 6

    public static func < (lhs: RouteRank, rhs: RouteRank) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Rejects traffic on an identity-mismatched route even when it is the only candidate.
    public var isUsable: Bool {
        self != .rejected
    }
}

/// Reject identity mismatches, penalize failures/RTT, consider metering and preserve healthy streams (§13.2).
public struct RouteScorer {
    public init() {}

    public func rankPart(
        of route: SparkRoute,
        expectedFingerprint: String?,
        failures: Int = 0
    ) -> RouteRank {
        // Reject mismatched identity regardless of anything else.
        if let expectedFingerprint, let actual = route.validatedIdentityFingerprint,
            actual != expectedFingerprint
        {
            return .rejected
        }
        // A pinned fingerprint mark is required for direct/wifi priority.
        let pinned = route.validatedIdentityFingerprint != nil

        let base: RouteRank
        switch route.kind {
        case .directEthernet: base = pinned ? .directEthernetPinned : .privateOverlay
        case .localWiFi: base = pinned ? .localWiFiPinned : .privateOverlay
        case .privateOverlay: base = .privateOverlay
        }

        // Repeated failures demote a route below its healthy class.
        if failures >= 3 {
            return max(base, .degraded)
        }
        return base
    }

    /// Prefer unmetered paths for large transfers.
    public func prefersUnmetered(_ route: SparkRoute) -> Bool {
        !route.isMetered
    }
}

private func max(_ a: RouteRank, _ b: RouteRank) -> RouteRank {
    a.rawValue > b.rawValue ? a : b
}
