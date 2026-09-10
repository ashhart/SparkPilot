import Foundation
import SparkCore

// Keeps non-secret library metadata under namespaced node and cluster identities while credentials and authoritative pins stay in Keychain.

/// Compatibility name for the shared logical identity in SparkCore.
public typealias LibraryLogicalKey = SparkTargetIdentity

/// Keys a route slot by transport and normalised interface so address changes update endpoints without merging distinct physical paths.
public struct RouteSlot: Hashable, Sendable, Codable {
    public let kind: SparkTransportKind
    /// Normalised interface or scope, with nil representing the transport-scoped default slot.
    public let scope: String?

    public init(kind: SparkTransportKind, scope: String? = nil) {
        self.kind = kind
        self.scope = RouteSlot.normalizedScope(scope)
    }

    private static func normalizedScope(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }
}

/// Updates a validated route endpoint in place using its stable slotID as the merge key.
public struct CachedRoute: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let slotID: RouteSlot
    public var baseURL: URL
    public var kind: SparkTransportKind
    /// Informational interface name of the latest endpoint observation.
    public var interfaceName: String?
    /// Caches non-secret peer identity for presentation and routing; only the Keychain holds authoritative TLS trust.
    public var peerFingerprint: String?
    public var lastSuccess: Date?
    public var isMetered: Bool
    /// Counts failed authenticated attempts since the route last succeeded, defaulting legacy records to zero.
    public var consecutiveFailures: Int

    public init(
        id: UUID = UUID(),
        slotID: RouteSlot? = nil,
        baseURL: URL,
        kind: SparkTransportKind,
        interfaceName: String? = nil,
        peerFingerprint: String? = nil,
        lastSuccess: Date? = nil,
        isMetered: Bool = false,
        consecutiveFailures: Int = 0
    ) {
        self.id = id
        self.slotID = slotID ?? RouteSlot(kind: kind, scope: interfaceName)
        self.baseURL = baseURL
        self.kind = kind
        self.interfaceName = interfaceName
        self.peerFingerprint = peerFingerprint
        self.lastSuccess = lastSuccess
        self.isMetered = isMetered
        self.consecutiveFailures = Swift.max(0, consecutiveFailures)
    }

    private enum CodingKeys: String, CodingKey {
        case id, slotID, baseURL, kind, interfaceName, peerFingerprint, lastSuccess, isMetered
        case consecutiveFailures
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        slotID = try container.decode(RouteSlot.self, forKey: .slotID)
        baseURL = try container.decode(URL.self, forKey: .baseURL)
        kind = try container.decode(SparkTransportKind.self, forKey: .kind)
        interfaceName = try container.decodeIfPresent(String.self, forKey: .interfaceName)
        peerFingerprint = try container.decodeIfPresent(String.self, forKey: .peerFingerprint)
        lastSuccess = try container.decodeIfPresent(Date.self, forKey: .lastSuccess)
        isMetered = try container.decodeIfPresent(Bool.self, forKey: .isMetered) ?? false
        // Absent in libraries written before demotion existed.
        consecutiveFailures =
            Swift.max(0, try container.decodeIfPresent(Int.self, forKey: .consecutiveFailures) ?? 0)
    }
}

/// Represents one physical node, used alone for standalone targets or as a leader or worker within a cluster.
public struct LibraryMember: Codable, Hashable, Sendable, Identifiable {
    public let nodeID: SparkNodeID
    public var name: String
    public var role: SparkNodeRole
    public var authorityFingerprint: String?
    /// Retains the last hostname only for authenticated route-rebind detection, never as node identity.
    public var hostname: String?
    public var routes: [CachedRoute]
    public var lastSeen: Date?
    public var reachable: Bool

    public init(
        nodeID: SparkNodeID,
        name: String,
        role: SparkNodeRole,
        authorityFingerprint: String? = nil,
        hostname: String? = nil,
        routes: [CachedRoute] = [],
        lastSeen: Date? = nil,
        reachable: Bool = false
    ) {
        self.nodeID = nodeID
        self.name = name
        self.role = role
        self.authorityFingerprint = authorityFingerprint
        self.hostname = hostname
        self.routes = routes
        self.lastSeen = lastSeen
        self.reachable = reachable
    }

    public var id: SparkNodeID { nodeID }

    /// The route that answered most recently; rank order breaks ties so an untried route never wins.
    public var routeInUse: CachedRoute? {
        routes.filter { $0.lastSuccess != nil }
            .max { ($0.lastSuccess ?? .distantPast) < ($1.lastSuccess ?? .distantPast) }
    }
}

/// Derives card kind from its logical key so identity scope and presentation cannot disagree.
public enum LibraryEntryKind: String, Codable, Sendable, Hashable {
    case standalone
    case cluster
}

/// Reserves identityMismatch for authenticated node replacement while applying topology changes atomically.
public enum LibraryEntryIssue: String, Codable, Sendable, Hashable {
    case identityMismatch
}

/// Caches authenticated fabric identities without address or interface observations that could be mistaken for trust.
public struct ExternalClusterAuthenticatedLink: Codable, Hashable, Sendable {
    public let memberANodeID: SparkNodeID
    public let memberAPortID: String
    public let memberBNodeID: SparkNodeID
    public let memberBPortID: String
    public let verifiedAt: Date
    public let expiresAt: Date

    public init(
        memberANodeID: SparkNodeID,
        memberAPortID: String,
        memberBNodeID: SparkNodeID,
        memberBPortID: String,
        verifiedAt: Date,
        expiresAt: Date
    ) {
        self.memberANodeID = memberANodeID
        self.memberAPortID = memberAPortID
        self.memberBNodeID = memberBNodeID
        self.memberBPortID = memberBPortID
        self.verifiedAt = verifiedAt
        self.expiresAt = expiresAt
    }
}

/// Describes a device-local external cluster without granting workload or fabric-management authority.
public struct ExternalClusterRegistration: Codable, Hashable, Sendable {
    public let authorityFingerprint: String
    public let memberNodeIDs: [SparkNodeID]
    public let registeredAt: Date
    public let lastVerifiedAt: Date
    public let authenticatedLinks: [ExternalClusterAuthenticatedLink]

    public init(
        authorityFingerprint: String,
        memberNodeIDs: [SparkNodeID],
        registeredAt: Date,
        lastVerifiedAt: Date,
        authenticatedLinks: [ExternalClusterAuthenticatedLink]
    ) {
        self.authorityFingerprint = authorityFingerprint
        self.memberNodeIDs = memberNodeIDs
        self.registeredAt = registeredAt
        self.lastVerifiedAt = lastVerifiedAt
        self.authenticatedLinks = authenticatedLinks
    }

    public func topologyIsStale(at date: Date) -> Bool {
        authenticatedLinks.isEmpty || authenticatedLinks.contains { $0.expiresAt <= date }
    }

    /// Removes a departed node from both registered membership and authenticated link references.
    public func removingMember(_ nodeID: SparkNodeID) -> ExternalClusterRegistration {
        ExternalClusterRegistration(
            authorityFingerprint: authorityFingerprint,
            memberNodeIDs: memberNodeIDs.filter { $0 != nodeID },
            registeredAt: registeredAt,
            lastVerifiedAt: lastVerifiedAt,
            authenticatedLinks: authenticatedLinks.filter {
                $0.memberANodeID != nodeID && $0.memberBNodeID != nodeID
            }
        )
    }
}

/// Identifies a library target by its namespaced node or cluster key, with raw UUIDs exposed only as data.
public struct LibraryEntry: Codable, Hashable, Sendable, Identifiable {
    public let logicalKey: LibraryLogicalKey
    /// Name reported by the Spark itself. Discovery may refresh this value.
    public var name: String
    /// Stores an owner-selected label only on this Apple device.
    public var customLabel: String?
    public var members: [LibraryMember]
    public var connectionState: SparkConnectionState
    public var issue: LibraryEntryIssue?
    public var lastSeen: Date?
    public var cachedAt: Date?
    /// Retains the last authenticated operational snapshot offline and reassesses its evidence freshness when read.
    public var cachedOperationalSnapshot: TargetOperationalSnapshot?
    /// Describes a local read-only grouping while each independently paired member remains a runtime standalone node.
    public var externalClusterRegistration: ExternalClusterRegistration?
    /// Remembers only an owner-established account name for later installation; passwords remain session-only.
    public var administratorUsername: String?

    /// Keys standalone cards by their sole node ID and cluster cards by cluster ID.
    public init(
        logicalKey: LibraryLogicalKey,
        name: String,
        customLabel: String? = nil,
        members: [LibraryMember],
        connectionState: SparkConnectionState = .offlineCached,
        issue: LibraryEntryIssue? = nil,
        lastSeen: Date? = nil,
        cachedAt: Date? = nil,
        cachedOperationalSnapshot: TargetOperationalSnapshot? = nil,
        externalClusterRegistration: ExternalClusterRegistration? = nil,
        administratorUsername: String? = nil
    ) {
        switch logicalKey {
        case .node:
            precondition(!members.isEmpty, "standalone cards keep one member")
        case .cluster:
            break
        }
        self.logicalKey = logicalKey
        self.name = name
        self.customLabel = customLabel
        self.members = members
        self.connectionState = connectionState
        self.issue = issue
        self.lastSeen = lastSeen
        self.cachedAt = cachedAt
        self.cachedOperationalSnapshot = cachedOperationalSnapshot
        self.externalClusterRegistration = externalClusterRegistration
        self.administratorUsername = administratorUsername
    }

    // MARK: Identifiable / kind

    public var id: String { logicalKey.description }

    /// Prefers the local label over runtime names so discovery cannot overwrite the owner's display choice.
    public var displayName: String {
        guard let customLabel else { return name }
        let trimmed = customLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? name : trimmed
    }

    public var kind: LibraryEntryKind {
        switch logicalKey {
        case .node: return .standalone
        case .cluster: return .cluster
        }
    }

    /// Set for cluster cards; `nil` for standalone cards.
    public var clusterID: SparkClusterID? {
        if case .cluster(let id) = logicalKey { return id }
        return nil
    }

    /// The node id a standalone card is keyed by (display/debug only).
    public var standaloneNodeID: SparkNodeID? {
        guard kind == .standalone else { return nil }
        return members.first?.nodeID
    }

    /// Routes cluster targets through a leader coordinator, leaving worker-only clusters without a usable coordinator route.
    public var coordinatorNodeID: SparkNodeID? {
        switch kind {
        case .standalone:
            return members.first?.nodeID
        case .cluster:
            if let externalClusterRegistration {
                return externalClusterRegistration.memberNodeIDs.first
            }
            return members.first { $0.role == .leader }?.nodeID
        }
    }

    /// Best remembered route for the whole target: the coordinator's route.
    public var preferredRoute: CachedRoute? {
        guard let coordinator = coordinatorNodeID else { return nil }
        return members.first { $0.nodeID == coordinator }?.routes.first
    }

    /// The coordinator route that answered most recently, so the card can say how the Spark is reached right now.
    public var routeInUse: CachedRoute? {
        guard let coordinator = coordinatorNodeID else { return nil }
        return members.first { $0.nodeID == coordinator }?.routeInUse
    }

    /// The route new sessions should use: what answered last, or the best remembered route before any contact.
    public var connectRoute: CachedRoute? {
        routeInUse ?? preferredRoute
    }

    /// Look up a member by node id.
    public func member(nodeID: SparkNodeID) -> LibraryMember? {
        members.first { $0.nodeID == nodeID }
    }

    public var reachableMemberCount: Int {
        members.count(where: \.reachable)
    }

    /// Blocks dashboard opening for entries with identity issues while retaining removal in every state.
    public var canOpen: Bool {
        issue == nil && preferredRoute != nil && externalClusterRegistration == nil
    }
}
