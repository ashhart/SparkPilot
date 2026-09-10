import Foundation

public struct SparkRequestDeploymentEvidence: Codable, Sendable, Equatable {
    public let recipeDigest: String
    public let recipeRevision: String
    public let sourceRevision: String
    public let engineRecipe: String
    public let engineImage: String
    public let contextLength: UInt64?
    public let maxSequences: UInt32?
    public let runtimeVersion: String
    public let verification: String

    enum CodingKeys: String, CodingKey {
        case recipeDigest = "recipe_digest"
        case recipeRevision = "recipe_revision"
        case sourceRevision = "source_revision"
        case engineRecipe = "engine_recipe"
        case engineImage = "engine_image"
        case contextLength = "context_length"
        case maxSequences = "max_sequences"
        case runtimeVersion = "runtime_version"
        case verification
    }
}

public struct SparkInferenceRequestRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String { attemptID }
    public let attemptID: String
    public let requestID: String
    public let callerDeviceID: String
    public let nodeID: String
    public let modelID: String
    public let profileID: String?
    public let startedAt: Int64
    public let finishedAt: Int64?
    public let outcome: String
    public let failureCode: String?
    public let admissionMs: Double
    public let firstFrameMs: Double?
    public let elapsedMs: Double?
    public let promptTokens: UInt64?
    public let completionTokens: UInt64?
    public let provenance: SparkRequestDeploymentEvidence?

    enum CodingKeys: String, CodingKey {
        case attemptID = "attempt_id"
        case requestID = "request_id"
        case callerDeviceID = "caller_device_id"
        case nodeID = "node_id"
        case modelID = "model_id"
        case profileID = "profile_id"
        case startedAt = "started_at"
        case finishedAt = "finished_at"
        case outcome
        case failureCode = "failure_code"
        case admissionMs = "admission_ms"
        case firstFrameMs = "first_frame_ms"
        case elapsedMs = "elapsed_ms"
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case provenance
    }
}

public struct SparkInferenceRequestHistory: Decodable, Sendable {
    public let recording: Bool
    public let retentionSeconds: Int
    public let maximumRecords: Int
    public let timingSource: String
    public let records: [SparkInferenceRequestRecord]
    enum CodingKeys: String, CodingKey {
        case recording, records
        case retentionSeconds = "retention_seconds"
        case maximumRecords = "maximum_records"
        case timingSource = "timing_source"
    }
}

public struct SparkRequestHistoryClearResult: Decodable, Sendable {
    public let cleared: Int
    public let activeRequestsPreserved: Bool
    enum CodingKeys: String, CodingKey {
        case cleared
        case activeRequestsPreserved = "active_requests_preserved"
    }
}

public struct SparkRequestHistoryCancelResult: Decodable, Sendable {
    public let cancelRequested: Bool
    public let outcome: String
    enum CodingKeys: String, CodingKey {
        case cancelRequested = "cancel_requested"
        case outcome
    }
}

extension SparkAPIClient {
    public func inferenceRequestHistory(
        route: URL,
        attemptID: UUID? = nil,
        modelID: String? = nil,
        outcome: String? = nil,
        after: Int64? = nil,
        before: Int64? = nil,
        allCallers: Bool = false,
        limit: Int = 100
    ) async throws -> SparkInferenceRequestHistory {
        var url = URLComponents(
            url: endpoint(route, "api", "v1", "inference", "requests"),
            resolvingAgainstBaseURL: false
        )!
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let attemptID {
            query.append(URLQueryItem(name: "attempt_id", value: attemptID.uuidString.lowercased()))
        }
        if let modelID { query.append(URLQueryItem(name: "model_id", value: modelID)) }
        if let outcome { query.append(URLQueryItem(name: "outcome", value: outcome)) }
        if let after { query.append(URLQueryItem(name: "after", value: String(after))) }
        if let before { query.append(URLQueryItem(name: "before", value: String(before))) }
        if allCallers { query.append(URLQueryItem(name: "all_callers", value: "true")) }
        url.queryItems = query
        return try await get(url.url!)
    }

    public func clearInferenceRequestHistory(route: URL, idempotencyKey: UUID) async throws
        -> SparkRequestHistoryClearResult
    {
        try await mutation(
            method: "DELETE",
            url: endpoint(route, "api", "v1", "inference", "requests"),
            body: Optional<String>.none,
            idempotencyKey: idempotencyKey,
            userPresence: nil
        )
    }

    public func cancelInferenceRequest(route: URL, attemptID: UUID, idempotencyKey: UUID)
        async throws -> SparkRequestHistoryCancelResult
    {
        try await mutation(
            method: "POST",
            url: endpoint(
                route,
                "api",
                "v1",
                "inference",
                "requests",
                attemptID.uuidString.lowercased(),
                "cancel"
            ),
            body: Optional<String>.none,
            idempotencyKey: idempotencyKey,
            userPresence: nil
        )
    }
}
