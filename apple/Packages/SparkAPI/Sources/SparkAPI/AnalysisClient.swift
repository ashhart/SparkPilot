import Foundation

/// Submit and cancel durable local text analyses through the runtime operation API.
extension SparkAPIClient {
    /// Return the durable operation immediately so its result survives an App Intent process exiting.
    public func startTextAnalysis(
        route base: URL,
        request: GeneratedAPI.TextAnalysisRequest,
        idempotencyKey: UUID
    ) async throws -> Operation {
        try await post(
            endpoint(base, "api", "v1", "inference", "analyses"),
            body: request,
            idempotencyKey: idempotencyKey
        )
    }

    /// Decode only analysis operations, rejecting other job kinds instead of presenting unrelated results.
    public func textAnalysis(route base: URL, id: UUID) async throws -> SparkTextAnalysisJob {
        let job: SparkTextAnalysisJob = try await get(
            endpoint(base, "api", "v1", "operations", id.uuidString)
        )
        guard job.kind == SparkTextAnalysisJob.kind else {
            throw APIError(
                .operationKindMismatch,
                code: "OPERATION_KIND_MISMATCH",
                diagnosticDetail: "operation \(id) is a \(job.kind), not an analysis"
            )
        }
        return job
    }

    /// Cancel abandoned durable work so it stops consuming the owner's model and memory.
    @discardableResult
    public func cancelOperation(
        route base: URL,
        id: UUID,
        idempotencyKey: UUID
    ) async throws -> Operation {
        try await post(
            endpoint(base, "api", "v1", "operations", id.uuidString, "cancel"),
            body: EmptyRequestBody(),
            idempotencyKey: idempotencyKey
        )
    }
}

/// `{}` — for routes that take an idempotency key and nothing else.
struct EmptyRequestBody: Encodable {}

/// One durable text-analysis operation.
public struct SparkTextAnalysisJob: Sendable, Equatable, Decodable {
    /// The `kind` the runtime records for these operations.
    public static let kind = "inference.analysis"

    public let id: UUID
    public let kind: String
    public let state: Operation.OperationState
    public let errorCode: String?
    /// Present only once the job succeeded.
    public let result: SparkTextAnalysis?

    enum CodingKeys: String, CodingKey {
        case id, kind, state, result
        case errorCode = "error_code"
    }
}

/// The stored answer.
public struct SparkTextAnalysis: Sendable, Equatable, Decodable {
    public let text: String
    public let modelID: String
    public let outputTokens: Int?
    /// Indicate output-ceiling truncation so callers cannot present an incomplete answer as complete.
    public let truncated: Bool

    enum CodingKeys: String, CodingKey {
        case text, truncated
        case modelID = "model_id"
        case outputTokens = "output_tokens"
    }
}
