import Foundation
import SparkCore

// Mirror OpenAPI schemas while tolerating additional properties allowed by the runtime.

public struct Health: Sendable, Equatable, Decodable {
    public let status: String
    public let apiVersion: Int
    public let runtimeVersion: String
    public let nodeID: SparkNodeID
    /// Signing protocols the runtime accepts; absent on runtimes that predate the signal.
    public let authProtocols: [String]?

    /// The request-signing protocol this build speaks; the security package's canonical form must agree.
    public static let signingProtocol = "SPARK2"

    public init(
        status: String,
        apiVersion: Int,
        runtimeVersion: String,
        nodeID: SparkNodeID,
        authProtocols: [String]? = nil
    ) {
        self.status = status
        self.apiVersion = apiVersion
        self.runtimeVersion = runtimeVersion
        self.nodeID = nodeID
        self.authProtocols = authProtocols
    }

    public var isOK: Bool { status == "ok" }

    /// Runtimes older than the advertisement say nothing; only an explicit list without this protocol is a refusal.
    public var speaksThisProtocol: Bool {
        guard let authProtocols else { return true }
        return authProtocols.contains(Self.signingProtocol)
    }

    enum CodingKeys: String, CodingKey {
        case status
        case apiVersion = "api_version"
        case runtimeVersion = "runtime_version"
        case nodeID = "node_id"
        case authProtocols = "auth_protocols"
    }
}

/// A durable operation as returned by 202 endpoints (§27).
public struct Operation: Sendable, Equatable, Decodable {
    public let id: UUID
    public let kind: String
    public let state: OperationState
    public let progress: Double?
    public let stage: String?
    public let errorCode: String?
    public let cancellable: Bool
    /// Retain the requesting paired-device identity so Activity can attribute work.
    public let actorDeviceID: UUID?
    public let createdAt: Date?
    public let startedAt: Date?
    public let completedAt: Date?

    public let notificationRequested: Bool?

    enum CodingKeys: String, CodingKey {
        case id, kind, state, progress, stage, cancellable, result
        case errorCode = "error_code"
        case actorDeviceID = "actor_device_id"
        case createdAt = "created_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }

    public enum OperationState: String, Sendable, Equatable, Decodable {
        case requested, validating, queued, running
        case waitingForApproval = "waiting_for_approval"
        case cancelling, cancelled, succeeded, failed
    }

    public init(
        id: UUID,
        kind: String,
        state: OperationState,
        progress: Double? = nil,
        stage: String? = nil,
        errorCode: String? = nil,
        cancellable: Bool,
        actorDeviceID: UUID? = nil,
        createdAt: Date? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        notificationRequested: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.progress = progress
        self.stage = stage
        self.errorCode = errorCode
        self.cancellable = cancellable
        self.actorDeviceID = actorDeviceID
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.notificationRequested = notificationRequested
    }

    /// Parse nanosecond timestamps from text, treating malformed values as absent so one timestamp cannot discard the response.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(String.self, forKey: .kind)
        state = try container.decode(OperationState.self, forKey: .state)
        progress = try container.decodeIfPresent(Double.self, forKey: .progress)
        stage = try container.decodeIfPresent(String.self, forKey: .stage)
        errorCode = try container.decodeIfPresent(String.self, forKey: .errorCode)
        cancellable = try container.decode(Bool.self, forKey: .cancellable)
        actorDeviceID = try container.decodeIfPresent(UUID.self, forKey: .actorDeviceID)
        createdAt = Self.instant(container, .createdAt)
        startedAt = Self.instant(container, .startedAt)
        completedAt = Self.instant(container, .completedAt)
        struct Delivery: Decodable { let notify: Bool? }
        notificationRequested = try container.decodeIfPresent(Delivery.self, forKey: .result)?
            .notify
    }

    private static func instant(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> Date? {
        // Treat absent and malformed optional fields as nil.
        guard let text = try? container.decodeIfPresent(String.self, forKey: key) else {
            return nil
        }
        return RFC3339.date(from: text)
    }
}

/// One page from `GET /api/v1/operations`.
public struct OperationPage: Sendable, Equatable, Decodable {
    public let items: [Operation]
    public let nextCursor: String?

    public init(items: [Operation], nextCursor: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }

    enum CodingKeys: String, CodingKey {
        case items
        case nextCursor = "next_cursor"
    }
}

/// Marker for bodies that carry no payload.
public struct NoBody: Sendable, Equatable, Encodable {}

/// Treat capabilities as available only when explicitly published by the runtime.
public struct SparkCapabilities: Sendable, Equatable, Decodable {
    public let apiVersion: Int
    public let features: [String: Bool]

    public init(apiVersion: Int, features: [String: Bool]) {
        self.apiVersion = apiVersion
        self.features = features
    }

    /// Whether `feature` is published AND enabled. Absent means unavailable.
    public func isEnabled(_ feature: String) -> Bool {
        features[feature] ?? false
    }

    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version"
        case features
    }
}

/// Keep authority-key identity separate from the optional HTTPS leaf-certificate pin.
public struct SparkIdentity: Sendable, Equatable, Decodable {
    public let nodeID: SparkNodeID
    public let clusterID: SparkClusterID?
    public let name: String
    public let role: String
    /// SHA-256 of the Ed25519 key that signs pairing material.
    public let authorityFingerprint: String
    /// Hash exact local API leaf-certificate DER, separately from the pairing authority key.
    public let tlsFingerprint: String?
    public let runtimeVersion: String
    public let dgxOSVersion: String?

    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case clusterID = "cluster_id"
        case name
        case role
        case authorityFingerprint = "authority_fingerprint"
        case tlsFingerprint = "tls_fingerprint"
        case runtimeVersion = "runtime_version"
        case dgxOSVersion = "dgx_os_version"
    }
}

public struct SparkStatus: Sendable, Equatable, Decodable {
    public let apiVersion: Int
    public let identity: SparkIdentity
    public let cluster: ClusterStatus?
    public let system: SystemStatus
    public let inference: InferenceStatus

    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version"
        case identity = "node"
        case cluster
        case system
        case inference
    }
}

/// Cluster topology from the OpenAPI `Cluster` schema. Null when standalone.
public struct ClusterStatus: Sendable, Equatable, Decodable {
    public let id: SparkClusterID?
    public let name: String?
    public let state: String
    public let members: [ClusterMember]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case state
        case members
    }
}

public struct ClusterMember: Sendable, Equatable, Decodable {
    public let nodeID: SparkNodeID
    public let name: String
    public let role: String
    public let reachable: Bool
    public let qsfpHealth: String?

    enum CodingKeys: String, CodingKey {
        case nodeID = "node_id"
        case name
        case role
        case reachable
        case qsfpHealth = "qsfp_health"
    }
}
