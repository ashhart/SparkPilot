import Foundation

/// Keep logical compute identity independent of network routes.
public enum SparkTargetIdentity: Hashable, Sendable, Codable, CustomStringConvertible {
    case node(SparkNodeID)
    case cluster(SparkClusterID)

    public var description: String {
        switch self {
        case .node(let id):
            "node:\(id.rawValue.uuidString.lowercased())"
        case .cluster(let id):
            "cluster:\(id.rawValue.uuidString.lowercased())"
        }
    }

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let uuid = UUID(uuidString: String(parts[1])) else {
            return nil
        }
        switch parts[0] {
        case "node":
            self = .node(SparkNodeID(rawValue: uuid))
        case "cluster":
            self = .cluster(SparkClusterID(rawValue: uuid))
        default:
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        guard let identity = SparkTargetIdentity(rawValue: rawValue) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "invalid logical target identity: \(rawValue)"
                )
            )
        }
        self = identity
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

/// Represent delayed authenticated evidence separately from transport connection results.
public enum TargetConnectionState: String, Codable, Hashable, Sendable {
    case discovering
    case foundUnpaired
    case connecting
    case connectedWiFi
    case connectedDirect
    case connectedRemote
    case delayed
    case offlineCached
    case identityMismatch
    case updateRequired
}

public enum OperationalFreshnessState: String, Codable, Hashable, Sendable {
    case current
    case stale
    case missing
}

/// Evaluate evidence age at evaluatedAt so cached snapshots remain deterministic.
public struct OperationalEvidenceFreshness: Codable, Hashable, Sendable {
    public let observedAt: Date?
    public let evaluatedAt: Date
    public let staleAfter: TimeInterval
    public let state: OperationalFreshnessState

    public init(
        observedAt: Date?,
        evaluatedAt: Date,
        staleAfter: TimeInterval,
        forceStale: Bool = false
    ) {
        self.observedAt = observedAt
        self.evaluatedAt = evaluatedAt
        self.staleAfter = max(0, staleAfter)
        guard let observedAt else {
            self.state = .missing
            return
        }
        let age = max(0, evaluatedAt.timeIntervalSince(observedAt))
        self.state = forceStale || age > self.staleAfter ? .stale : .current
    }

    public var age: TimeInterval? {
        observedAt.map { max(0, evaluatedAt.timeIntervalSince($0)) }
    }

    public func reassessed(at date: Date, forceStale: Bool = false)
        -> OperationalEvidenceFreshness
    {
        OperationalEvidenceFreshness(
            observedAt: observedAt,
            evaluatedAt: date,
            staleAfter: staleAfter,
            forceStale: forceStale
        )
    }
}

/// Apply freshness limits during snapshot assembly without altering cached evidence.
public struct OperationalFreshnessPolicy: Codable, Hashable, Sendable {
    public let health: TimeInterval
    public let inventory: TimeInterval
    public let memory: TimeInterval
    public let inference: TimeInterval
    public let operations: TimeInterval
    public let delayedAfter: TimeInterval

    public init(
        health: TimeInterval = 15,
        inventory: TimeInterval = 60,
        memory: TimeInterval = 15,
        inference: TimeInterval = 15,
        operations: TimeInterval = 15,
        delayedAfter: TimeInterval = 30
    ) {
        self.health = health
        self.inventory = inventory
        self.memory = memory
        self.inference = inference
        self.operations = operations
        self.delayedAfter = delayedAfter
    }

    public static let standard = OperationalFreshnessPolicy()
}

public struct TargetEvidenceFreshness: Codable, Hashable, Sendable {
    public let health: OperationalEvidenceFreshness
    public let inventory: OperationalEvidenceFreshness
    public let memory: OperationalEvidenceFreshness
    public let inference: OperationalEvidenceFreshness
    public let operations: OperationalEvidenceFreshness

    public init(
        health: OperationalEvidenceFreshness,
        inventory: OperationalEvidenceFreshness,
        memory: OperationalEvidenceFreshness,
        inference: OperationalEvidenceFreshness,
        operations: OperationalEvidenceFreshness
    ) {
        self.health = health
        self.inventory = inventory
        self.memory = memory
        self.inference = inference
        self.operations = operations
    }

    public var hasStaleEvidence: Bool {
        [health, inventory, memory, inference, operations].contains { $0.state == .stale }
    }

    public func reassessed(at date: Date, forceStale: Bool = false) -> TargetEvidenceFreshness {
        TargetEvidenceFreshness(
            health: health.reassessed(at: date, forceStale: forceStale),
            inventory: inventory.reassessed(at: date, forceStale: forceStale),
            memory: memory.reassessed(at: date, forceStale: forceStale),
            inference: inference.reassessed(at: date, forceStale: forceStale),
            operations: operations.reassessed(at: date, forceStale: forceStale)
        )
    }
}

/// Keep displayed routes separate from identity and pinning decisions.
public struct PreferredRouteSummary: Codable, Hashable, Sendable {
    public let kind: SparkTransportKind
    public let host: String?
    public let port: Int?
    public let interfaceName: String?
    public let lastSuccessfulAt: Date?
    public let isMetered: Bool

    public init(
        kind: SparkTransportKind,
        host: String?,
        port: Int?,
        interfaceName: String?,
        lastSuccessfulAt: Date?,
        isMetered: Bool
    ) {
        self.kind = kind
        self.host = host
        self.port = port
        self.interfaceName = interfaceName
        self.lastSuccessfulAt = lastSuccessfulAt
        self.isMetered = isMetered
    }
}

public struct TargetMemberSnapshot: Codable, Hashable, Sendable, Identifiable {
    public let nodeID: SparkNodeID
    public let displayName: String
    public let role: SparkNodeRole
    public let reachable: Bool
    public let linkHealth: String?
    public let lastSuccessfulContact: Date?

    public init(
        nodeID: SparkNodeID,
        displayName: String,
        role: SparkNodeRole,
        reachable: Bool,
        linkHealth: String? = nil,
        lastSuccessfulContact: Date? = nil
    ) {
        self.nodeID = nodeID
        self.displayName = displayName
        self.role = role
        self.reachable = reachable
        self.linkHealth = linkHealth
        self.lastSuccessfulContact = lastSuccessfulContact
    }

    public var id: SparkNodeID { nodeID }
}

public enum SparkRuntimeHealthState: String, Codable, Hashable, Sendable {
    case healthy
    case degraded
    case unavailable
    case unknown
}

public enum SparkRuntimeUpdateState: String, Codable, Hashable, Sendable {
    case current
    case available
    case required
    case unknown
}

public struct TargetRuntimeSnapshot: Codable, Hashable, Sendable {
    public let version: String?
    public let health: SparkRuntimeHealthState
    public let updateState: SparkRuntimeUpdateState
    public let availableVersion: String?

    public init(
        version: String?,
        health: SparkRuntimeHealthState,
        updateState: SparkRuntimeUpdateState,
        availableVersion: String? = nil
    ) {
        self.version = version
        self.health = health
        self.updateState = updateState
        self.availableVersion = availableVersion
    }
}

public enum VLLMHealthState: String, Codable, Hashable, Sendable {
    case stopped
    case starting
    case ready
    case stopping
    case failed
    case unknown
}

public enum SparkMemoryPressure: String, Codable, Hashable, Sendable {
    case normal
    case warning
    case critical
    case emergency
    case unknown
}

public struct UnifiedMemorySnapshot: Codable, Hashable, Sendable {
    public let totalBytes: Int64
    public let availableBytes: Int64
    public let pressure: SparkMemoryPressure

    public init(totalBytes: Int64, availableBytes: Int64, pressure: SparkMemoryPressure) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.pressure = pressure
    }
}

public struct DiskCapacitySnapshot: Codable, Hashable, Sendable {
    public let freeBytes: Int64

    public init(freeBytes: Int64) {
        self.freeBytes = freeBytes
    }
}

/// Compare recipe placements by signed catalogue identity rather than mutable display names.
public struct ModelPlacementIdentity: Codable, Hashable, Sendable, CustomStringConvertible {
    public let modelID: String
    public let recipeRevision: String

    public init(modelID: String, recipeRevision: String) {
        self.modelID = modelID
        self.recipeRevision = recipeRevision
    }

    public var description: String { "\(modelID)@\(recipeRevision)" }
}

public enum ModelPlacementState: String, Codable, Hashable, Sendable, CaseIterable {
    case available
    case downloading
    case installed
    case starting
    case running
    case stopping
    case failed
    case incompatible
    case unknown
}

public struct OperationalNotice: Codable, Hashable, Sendable, Identifiable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var id: String { code }
}

public struct ModelPlacementTechnicalDetails: Codable, Hashable, Sendable {
    public let modelID: String
    public let recipeRevision: String
    public let sourceRevision: String?
    /// Nil when the runtime did not supply verified capability metadata.
    public let visionSupported: Bool?

    public init(
        modelID: String,
        recipeRevision: String,
        sourceRevision: String?,
        visionSupported: Bool? = nil
    ) {
        self.modelID = modelID
        self.recipeRevision = recipeRevision
        self.sourceRevision = sourceRevision
        self.visionSupported = visionSupported
    }
}

public struct ModelPlacementSnapshot: Codable, Hashable, Sendable, Identifiable {
    public let identity: ModelPlacementIdentity
    public let displayName: String
    public let state: ModelPlacementState
    public let evidence: OperationalEvidenceFreshness
    public let technicalDetails: ModelPlacementTechnicalDetails
    public let warnings: [OperationalNotice]
    public let blockers: [OperationalNotice]

    public init(
        identity: ModelPlacementIdentity,
        displayName: String,
        state: ModelPlacementState,
        evidence: OperationalEvidenceFreshness,
        technicalDetails: ModelPlacementTechnicalDetails,
        warnings: [OperationalNotice] = [],
        blockers: [OperationalNotice] = []
    ) {
        self.identity = identity
        self.displayName = displayName
        self.state = state
        self.evidence = evidence
        self.technicalDetails = technicalDetails
        self.warnings = warnings
        self.blockers = blockers
    }

    public var id: ModelPlacementIdentity { identity }
}

public struct ActiveInferenceSnapshot: Codable, Hashable, Sendable {
    public let state: SparkInferenceState
    public let modelIdentity: ModelPlacementIdentity?
    public let profileID: String?
    public let contextLength: Int?
    public let activeRequests: Int
    public let queueDepth: Int?
    public let tokensPerSecond: Double?
    public let timeToFirstTokenMilliseconds: Double?

    public init(
        state: SparkInferenceState,
        modelIdentity: ModelPlacementIdentity?,
        profileID: String?,
        contextLength: Int? = nil,
        activeRequests: Int,
        queueDepth: Int?,
        tokensPerSecond: Double?,
        timeToFirstTokenMilliseconds: Double?
    ) {
        self.state = state
        self.modelIdentity = modelIdentity
        self.profileID = profileID
        self.contextLength = contextLength
        self.activeRequests = activeRequests
        self.queueDepth = queueDepth
        self.tokensPerSecond = tokensPerSecond
        self.timeToFirstTokenMilliseconds = timeToFirstTokenMilliseconds
    }
}

public struct TargetOperationSnapshot: Codable, Hashable, Sendable, Identifiable {
    public let id: SparkOperationID
    public let kind: String
    public let state: SparkOperationState
    public let progress: Double?
    public let stage: String?
    public let errorCode: String?
    public let cancellable: Bool
    /// Allow missing acceptance, start or completion timestamps for older snapshots and in-flight work.
    public let createdAt: Date?
    public let startedAt: Date?
    public let completedAt: Date?
    /// The paired device that asked for the work, as the Spark recorded it.
    public let actorDeviceID: String?

    public let notificationRequested: Bool?

    public init(
        id: SparkOperationID,
        kind: String,
        state: SparkOperationState,
        progress: Double?,
        stage: String?,
        errorCode: String?,
        cancellable: Bool,
        createdAt: Date? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        actorDeviceID: String? = nil,
        notificationRequested: Bool? = nil
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.progress = progress
        self.stage = stage
        self.errorCode = errorCode
        self.cancellable = cancellable
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.actorDeviceID = actorDeviceID
        self.notificationRequested = notificationRequested
    }

    /// Prefer completion time, then start time, then request time for display.
    public var mostRecentInstant: Date? { completedAt ?? startedAt ?? createdAt }

    /// How long a finished operation took, when both ends are known.
    public var duration: TimeInterval? {
        guard let completedAt, let start = startedAt ?? createdAt else { return nil }
        let elapsed = completedAt.timeIntervalSince(start)
        return elapsed >= 0 ? elapsed : nil
    }
}

public struct TargetTechnicalDetails: Codable, Hashable, Sendable {
    public let logicalIdentity: String
    public let memberNodeIDs: [SparkNodeID]

    public init(logicalIdentity: String, memberNodeIDs: [SparkNodeID]) {
        self.logicalIdentity = logicalIdentity
        self.memberNodeIDs = memberNodeIDs
    }
}

/// Retain prior successful values while marking their evidence stale in immutable operational snapshots.
public struct TargetOperationalSnapshot: Codable, Hashable, Sendable, Identifiable {
    public let identity: SparkTargetIdentity
    public let displayName: String
    public let members: [TargetMemberSnapshot]
    public let preferredRoute: PreferredRouteSummary?
    public let connectionState: TargetConnectionState
    public let lastSuccessfulContact: Date?
    public let evaluatedAt: Date
    public let evidence: TargetEvidenceFreshness
    public let runtime: TargetRuntimeSnapshot
    public let vllmHealth: VLLMHealthState
    public let unifiedMemory: UnifiedMemorySnapshot?
    public let disk: DiskCapacitySnapshot?
    public let installedModelCount: Int
    public let activeInference: ActiveInferenceSnapshot?
    public let operations: [TargetOperationSnapshot]
    public let placements: [ModelPlacementSnapshot]
    public let warnings: [OperationalNotice]
    public let blockers: [OperationalNotice]
    public let technicalDetails: TargetTechnicalDetails
    /// Hottest reported sensor in degrees Celsius; nil when not reported.
    public let temperatureCelsius: Double?
    /// The route that answered most recently, which may rank below `preferredRoute` (for example Tailscale while away).
    public let routeInUse: PreferredRouteSummary?

    public init(
        identity: SparkTargetIdentity,
        displayName: String,
        members: [TargetMemberSnapshot],
        preferredRoute: PreferredRouteSummary?,
        connectionState: TargetConnectionState,
        lastSuccessfulContact: Date?,
        evaluatedAt: Date,
        evidence: TargetEvidenceFreshness,
        runtime: TargetRuntimeSnapshot,
        vllmHealth: VLLMHealthState,
        unifiedMemory: UnifiedMemorySnapshot?,
        disk: DiskCapacitySnapshot?,
        installedModelCount: Int,
        activeInference: ActiveInferenceSnapshot?,
        operations: [TargetOperationSnapshot],
        placements: [ModelPlacementSnapshot],
        warnings: [OperationalNotice],
        blockers: [OperationalNotice],
        technicalDetails: TargetTechnicalDetails,
        temperatureCelsius: Double? = nil,
        routeInUse: PreferredRouteSummary? = nil
    ) {
        self.identity = identity
        self.displayName = displayName
        self.members = members
        self.preferredRoute = preferredRoute
        self.connectionState = connectionState
        self.lastSuccessfulContact = lastSuccessfulContact
        self.evaluatedAt = evaluatedAt
        self.evidence = evidence
        self.runtime = runtime
        self.vllmHealth = vllmHealth
        self.unifiedMemory = unifiedMemory
        self.disk = disk
        self.installedModelCount = installedModelCount
        self.activeInference = activeInference
        self.operations = operations
        self.placements = placements
        self.warnings = warnings
        self.blockers = blockers
        self.technicalDetails = technicalDetails
        self.temperatureCelsius = temperatureCelsius
        self.routeInUse = routeInUse
    }

    public var id: SparkTargetIdentity { identity }

    public var evidenceAge: TimeInterval? {
        lastSuccessfulContact.map { max(0, evaluatedAt.timeIntervalSince($0)) }
    }
}
