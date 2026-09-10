import Foundation
import SparkAPI
import SparkSecurity

/// Accepts only a pinned-runtime UUID as response identity, without inferring matches from aliases, stream IDs or timestamps.
final class SparkInferenceAttemptTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var attemptID: UUID?
    func set(_ id: UUID) { lock.withLock { attemptID = id } }
    func get() -> UUID? { lock.withLock { attemptID } }
    func reset() { lock.withLock { attemptID = nil } }
}

struct PinnedSparkInferenceTestStreamer: SparkChatStreaming {
    let target: SparkInferenceTestTarget
    let tracker: SparkInferenceAttemptTracker

    func stream(target chatTarget: SparkChatTarget, request: ChatCompletionRequest) async throws
        -> AsyncThrowingStream<ChatStreamEvent, any Error>
    {
        guard chatTarget == target.chat else { throw SparkChatConnectionError.identityMismatch }
        try await SparkInferenceTestTarget.checkCurrentModel(target)
        let signer = try DeviceIdentityStore.loadOrCreateSigner(nodeID: chatTarget.nodeID.rawValue)
        let chat = try ChatClient(
            baseURL: chatTarget.route,
            pin: chatTarget.tlsFingerprint,
            signer: signer
        )
        return try await chat.stream(request, onRuntimeAttempt: { [tracker] in tracker.set($0) })
    }
}

extension SparkInferenceTestTarget {
    func runtimeRecord(attemptID: UUID) async throws -> SparkInferenceRequestRecord? {
        let signer = try DeviceIdentityStore.loadOrCreateSigner(nodeID: chat.nodeID.rawValue)
        let api = try SparkAPIClient.pinned(to: chat.tlsFingerprint, signer: signer)
        let identity = try await api.identity(route: chat.route)
        guard identity.nodeID == chat.nodeID, identity.clusterID == nil,
            identity.authorityFingerprint == chat.authorityFingerprint
        else { throw SparkChatConnectionError.identityMismatch }
        let history = try await api.inferenceRequestHistory(
            route: chat.route,
            attemptID: attemptID,
            limit: 1
        )
        guard let record = history.records.first,
            UUID(uuidString: record.attemptID) == attemptID,
            UUID(uuidString: record.nodeID) == chat.nodeID.rawValue,
            record.modelID == chat.modelID, record.profileID == profileID
        else { return nil }
        return record
    }
}
