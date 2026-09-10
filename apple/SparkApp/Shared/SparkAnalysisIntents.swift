import Foundation
import SparkAPI
import SparkCore
import SparkIntents
import SparkSecurity
import SparkTransport

/// Implements capability-gated durable file analysis with a bounded wait and recoverable job handoff.

/// Inject intent polling interval and wait budget for deterministic tests.
public struct SparkAnalysisPolling: Sendable, Equatable {
    public var wait: Duration
    public var interval: Duration

    public init(wait: Duration, interval: Duration) {
        self.wait = wait
        self.interval = interval
    }

    /// Bound foreground waiting so unfinished analysis can hand off before the system reclaims the intent.
    public static let `default` = SparkAnalysisPolling(
        wait: .seconds(25),
        interval: .milliseconds(750)
    )
}

/// Defines durable analysis separately while SparkIntentExecuting supplies the shared executor's Sendable requirement.
public protocol SparkAnalysisExecuting {
    /// Treats an absent durable_text_analysis capability as unavailable before accepting a document.
    func supportsDurableAnalysis(on target: SparkIntentTarget) async throws -> Bool

    /// Queue the analysis; returns the durable operation id.
    func startAnalysis(
        on target: SparkIntentTarget,
        input: SparkFileAnalysisInput,
        instruction: String
    ) async throws -> UUID

    /// Read one analysis job.
    func analysisOutcome(
        jobID: UUID,
        on target: SparkIntentTarget
    ) async throws -> SparkAnalysisHandoff

    /// Best effort: a job nobody is waiting for should stop.
    func cancelAnalysis(jobID: UUID, on target: SparkIntentTarget) async
}

extension SparkAppIntentService {
    /// Enforce the same instruction-byte limit as the runtime.
    public static let analysisInstructionLimitBytes = 2_000

    public func analyseFile(
        _ input: SparkFileAnalysisInput,
        instruction: String,
        targetID: String?
    ) async throws -> SparkAnalysisHandoff {
        guard instruction.utf8.count <= Self.analysisInstructionLimitBytes else {
            throw SparkIntentError.requestTooLarge(
                limitBytes: Self.analysisInstructionLimitBytes
            )
        }
        // Accept documents only through the bounded SparkFileAnalysisInput type.
        let target = try await target(id: targetID, requiring: .runInference)

        // Refuse unsupported analysis before any document bytes leave the device.
        let supported = try await userFacing {
            try await executor.supportsDurableAnalysis(on: target)
        }
        guard supported else { throw SparkIntentError.analysisUnsupported }

        let jobID = try await userFacing {
            try await executor.startAnalysis(
                on: target,
                input: input,
                instruction: instruction
            )
        }
        return try await collect(jobID: jobID, on: target)
    }

    public func analysisResult(
        jobID: String,
        targetID: String?
    ) async throws -> SparkAnalysisHandoff {
        guard let identifier = UUID(uuidString: jobID.trimmingCharacters(in: .whitespaces)) else {
            throw SparkIntentError.analysisJobUnknown(jobID: jobID)
        }
        let target = try await target(id: targetID, requiring: .runInference)
        return try await userFacing {
            try await executor.analysisOutcome(jobID: identifier, on: target)
        }
    }

    /// Cancelling the intent stops its job; exhausting the wait window leaves the requested job running and returns its identity.
    private func collect(
        jobID: UUID,
        on target: SparkIntentTarget
    ) async throws -> SparkAnalysisHandoff {
        let deadline = ContinuousClock.now.advanced(by: analysisPolling.wait)
        while true {
            do {
                let outcome = try await userFacing {
                    try await executor.analysisOutcome(jobID: jobID, on: target)
                }
                if case .finished = outcome { return outcome }
                guard ContinuousClock.now < deadline else {
                    return .running(jobID: jobID.uuidString.lowercased())
                }
                try await Task.sleep(for: analysisPolling.interval)
            } catch is CancellationError {
                await executor.cancelAnalysis(jobID: jobID, on: target)
                throw CancellationError()
            }
        }
    }
}

extension PinnedSparkIntentExecutor: SparkAnalysisExecuting {
    public func supportsDurableAnalysis(on target: SparkIntentTarget) async throws -> Bool {
        let api = try await authenticatedAPI(for: target)
        return try await api.capabilities(route: target.route)
            .isEnabled(SparkAnalysisFeature.durableTextAnalysis)
    }

    public func startAnalysis(
        on target: SparkIntentTarget,
        input: SparkFileAnalysisInput,
        instruction: String
    ) async throws -> UUID {
        let api = try await authenticatedAPI(for: target)
        let operation = try await api.startTextAnalysis(
            route: target.route,
            request: .init(
                instruction: instruction,
                text: input.text,
                sourceName: input.sourceName.isEmpty ? nil : input.sourceName,
                maxOutputTokens: Self.analysisOutputLimitTokens,
                // Bind the request to the intended target so a moved route cannot be answered by another Spark.
                target: .init(
                    nodeId: target.clusterID == nil
                        ? target.nodeID.rawValue.uuidString.lowercased() : nil,
                    clusterId: target.clusterID?.rawValue.uuidString.lowercased()
                )
            ),
            idempotencyKey: UUID()
        )
        return operation.id
    }

    public func analysisOutcome(
        jobID: UUID,
        on target: SparkIntentTarget
    ) async throws -> SparkAnalysisHandoff {
        let api = try await authenticatedAPI(for: target)
        let job = try await api.textAnalysis(route: target.route, id: jobID)
        switch job.state {
        case .succeeded:
            guard let result = job.result else {
                throw SparkIntentError.analysisFailed(
                    reason: String(localized: "The job finished without an answer.")
                )
            }
            return .finished(text: result.text, truncated: result.truncated)
        case .failed:
            throw SparkIntentError.analysisFailed(
                reason: SparkAnalysisFailure.explanation(for: job.errorCode)
            )
        case .cancelled:
            throw SparkIntentError.analysisFailed(
                reason: String(localized: "The job was cancelled.")
            )
        case .requested, .validating, .queued, .running, .waitingForApproval, .cancelling:
            return .running(jobID: jobID.uuidString.lowercased())
        }
    }

    public func cancelAnalysis(jobID: UUID, on target: SparkIntentTarget) async {
        // Preserve the owner's cancellation if best-effort remote cancellation also fails.
        guard let api = try? await authenticatedAPI(for: target) else { return }
        _ = try? await api.cancelOperation(
            route: target.route,
            id: jobID,
            idempotencyKey: UUID()
        )
    }

    /// Bound durable generation beyond the shorter foreground-intent wait.
    static let analysisOutputLimitTokens = 1_024
}

/// The capability key the runtime publishes for this feature.
enum SparkAnalysisFeature {
    static let durableTextAnalysis = "durable_text_analysis"
}

/// Owner-facing copy for a failed analysis job.
enum SparkAnalysisFailure {
    static func explanation(for code: String?) -> String {
        switch code {
        case "MODEL_NOT_LOADED":
            String(localized: "No model is loaded on that Spark.")
        case "MODEL_RESPONSE_EMPTY":
            String(localized: "The model returned nothing to show.")
        case "OPERATION_CANCELLED":
            String(localized: "The job was cancelled.")
        default:
            String(localized: "Check the Spark and try again.")
        }
    }
}
