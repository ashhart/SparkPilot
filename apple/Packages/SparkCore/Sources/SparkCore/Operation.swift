/// Treat cancelled, succeeded and failed as terminal durable-operation states (§27.1).
public enum SparkOperationState: String, Codable, Sendable {
    case requested
    case validating
    case queued
    case running
    case waitingForApproval = "waiting_for_approval"
    case cancelling
    case cancelled
    case succeeded
    case failed
}

/// Decode the server-authoritative durable operation through the OpenAPI shape.
public struct SparkOperation: Identifiable, Hashable, Sendable {
    public let id: SparkOperationID
    public let kind: String
    public let state: SparkOperationState
    public let actorDeviceID: SparkDeviceID
    public let resourceID: String?
    public let progress: Double?
    public let stage: String?
    public let cancellable: Bool

    public init(
        id: SparkOperationID,
        kind: String,
        state: SparkOperationState,
        actorDeviceID: SparkDeviceID,
        resourceID: String?,
        progress: Double?,
        stage: String?,
        cancellable: Bool
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.actorDeviceID = actorDeviceID
        self.resourceID = resourceID
        self.progress = progress
        self.stage = stage
        self.cancellable = cancellable
    }
}
