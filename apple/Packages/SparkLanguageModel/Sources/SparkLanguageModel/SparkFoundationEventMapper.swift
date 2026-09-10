import Foundation
import SparkAPI

/// Expose generation metadata through typed accessors, keeping wire-key dictionaries for diagnostics (§39.8).
public struct SparkGenerationMetadata: Equatable, Sendable {
    public let nodeID: String?
    public let clusterID: String?
    public let modelID: String?
    public let profileID: String?
    public let requestID: String?
    public let transport: String?
    public let executionLocation: String?
    public let timeToFirstTokenMilliseconds: Double?
    public let tokensPerSecond: Double?
    public let queueMilliseconds: Double?
    public let finishReason: String?
    public let promptTokens: Int?
    public let completionTokens: Int?

    /// The §39.8 diagnostic dictionary.
    public var metadataKeys: [String: String] {
        [
            "spark.nodeID": nodeID,
            "spark.clusterID": clusterID,
            "spark.modelID": modelID,
            "spark.profileID": profileID,
            "spark.requestID": requestID,
            "spark.transport": transport,
            "spark.executionLocation": executionLocation,
        ]
        .compactMapValues { $0 }
        .merging(
            [
                timeToFirstTokenMilliseconds.map {
                    ("spark.timeToFirstTokenMilliseconds", String(format: "%.0f", $0))
                },
                tokensPerSecond.map {
                    ("spark.tokensPerSecond", String(format: "%.1f", $0))
                },
                queueMilliseconds.map {
                    ("spark.queueMilliseconds", String(format: "%.0f", $0))
                },
                finishReason.map { ("spark.finishReason", $0) },
                promptTokens.map { ("spark.promptTokens", String($0)) },
                completionTokens.map { ("spark.completionTokens", String($0)) },
            ]
            .compactMap { $0 },
            uniquingKeysWith: { first, _ in first }
        )
    }
}

/// Map proxy events into text and typed latency metadata independently of the Foundation Models adapter (§39.8).
public struct SparkStreamAccumulator: Sendable {
    private let nodeID: String?
    private let transport: String
    private let clock: @Sendable () -> DispatchTime

    public init(
        nodeID: String? = nil,
        transport: String = "spark",
        clock: @escaping @Sendable () -> DispatchTime = { .now() }
    ) {
        self.nodeID = nodeID
        self.transport = transport
        self.clock = clock
        // Measure first-token latency from request dispatch rather than the first received chunk.
        self.startedAt = clock().uptimeNanoseconds
    }

    /// Fold one event; returns the delta text to surface, if any.
    public mutating func consume(_ event: ChatStreamEvent) -> String? {
        switch event {
        case .chunk(let id, let model, let delta, _, let finishReason):
            // Retain stream-provided request and answering-model identifiers in response metadata (§39.8).
            if observedRequestID == nil, let id, !id.isEmpty {
                observedRequestID = id
            }
            if observedModelID == nil, let model, !model.isEmpty {
                observedModelID = model
            }
            if let finishReason {
                self.finishReason = finishReason
            }
            if let delta, !delta.isEmpty {
                if firstChunkAt == nil {
                    firstChunkAt = clock().uptimeNanoseconds
                }
                text.append(delta)
                return delta
            }
            return nil
        case .usage(let prompt, let completion, _):
            // Consume usage events so completion totals and throughput do not depend on a separate caller update.
            recordUsage(prompt: prompt, completion: completion)
            return nil
        case .sources:
            return nil
        case .done:
            lastAt = clock().uptimeNanoseconds
            return nil
        }
    }

    /// Attach the final usage numbers.
    public mutating func recordUsage(prompt: Int, completion: Int) {
        promptTokens = prompt
        completionTokens = completion
    }

    private var text: String = ""
    private let startedAt: UInt64
    private var firstChunkAt: UInt64?
    private var lastAt: UInt64?
    private var finishReason: String?
    private var promptTokens: Int?
    private var completionTokens: Int?
    private var observedRequestID: String?
    private var observedModelID: String?

    /// The accumulated response text so far.
    public var responseText: String { text }

    /// Prefer stream metadata unless explicitly overridden, with profile identity supplied by the caller.
    public func metadata(
        modelID: String? = nil,
        profileID: String? = nil,
        requestID: String? = nil
    ) -> SparkGenerationMetadata {
        // Measure TTFT from request to first token and throughput over the first-to-last-token production window.
        var ttft: Double?
        var throughput: Double?
        if let firstChunkAt, firstChunkAt >= startedAt {
            ttft = Double(firstChunkAt - startedAt) / 1_000_000
        }
        if let firstChunkAt, let lastAt, lastAt > firstChunkAt, let completionTokens,
            completionTokens > 0
        {
            let generatingMs = Double(lastAt - firstChunkAt) / 1_000_000
            if generatingMs > 0 {
                throughput = Double(completionTokens) / (generatingMs / 1000)
            }
        }
        return SparkGenerationMetadata(
            nodeID: nodeID,
            clusterID: nil,
            modelID: modelID ?? observedModelID,
            profileID: profileID,
            requestID: requestID ?? observedRequestID,
            transport: transport,
            executionLocation: nodeID.map { "spark/\($0)" } ?? "spark",
            timeToFirstTokenMilliseconds: ttft,
            tokensPerSecond: throughput,
            queueMilliseconds: nil,
            finishReason: finishReason,
            promptTokens: promptTokens,
            completionTokens: completionTokens
        )
    }
}

/// Folds a complete stream (test/diagnostics convenience).
extension SparkStreamAccumulator {
    public static func accumulate(
        _ events: [ChatStreamEvent],
        nodeID: String? = nil,
        transport: String = "spark"
    ) -> (accumulator: SparkStreamAccumulator, deltas: [String]) {
        var accumulator = SparkStreamAccumulator(nodeID: nodeID, transport: transport)
        var deltas: [String] = []
        for event in events {
            if let delta = accumulator.consume(event) {
                deltas.append(delta)
            }
        }
        return (accumulator, deltas)
    }
}
