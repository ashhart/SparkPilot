import Foundation
import SparkAPI
import SparkCore
import Testing
@testable import SparkAppComposition

private func inferenceTestTarget(cluster: Bool = false) -> SparkInferenceTestTarget {
    SparkInferenceTestTarget(
        chat: SparkChatTarget(
            id: "test-spark",
            displayName: "Desk Spark",
            nodeID: SparkNodeID(rawValue: UUID()),
            clusterID: cluster ? SparkClusterID(rawValue: UUID()) : nil,
            route: URL(string: "https://spark.invalid:7443")!,
            tlsFingerprint: String(repeating: "a", count: 64),
            authorityFingerprint: String(repeating: "b", count: 64),
            modelID: "example/model",
            modelName: "Example model"
        ),
        profileID: "small"
    )
}

private actor InferenceTestScript: SparkChatStreaming {
    let events: [ChatStreamEvent]
    let fails: Bool
    private(set) var requests: [ChatCompletionRequest] = []

    init(_ events: [ChatStreamEvent], fails: Bool = false) {
        self.events = events
        self.fails = fails
    }

    func stream(target: SparkChatTarget, request: ChatCompletionRequest) async throws
        -> AsyncThrowingStream<ChatStreamEvent, any Error>
    {
        requests.append(request)
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            if fails {
                continuation.finish(throwing: URLError(.networkConnectionLost))
            } else {
                continuation.finish()
            }
        }
    }
}

private actor InferenceTestHeldStream: SparkChatStreaming {
    private var continuations: [AsyncThrowingStream<ChatStreamEvent, any Error>.Continuation] = []
    private(set) var terminated: Set<Int> = []
    var requestCount: Int { continuations.count }

    func stream(target: SparkChatTarget, request: ChatCompletionRequest) async throws
        -> AsyncThrowingStream<ChatStreamEvent, any Error>
    {
        let (stream, continuation) = AsyncThrowingStream<ChatStreamEvent, any Error>.makeStream()
        let index = continuations.count
        continuations.append(continuation)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.recordTermination(index) }
        }
        return stream
    }

    func finish(_ index: Int, text: String) {
        continuations[index].yield(.chunk(id: nil, model: nil, delta: text, finishReason: "stop"))
        continuations[index].yield(.done)
        continuations[index].finish()
    }

    private func recordTermination(_ index: Int) { terminated.insert(index) }
}

private final class InferenceTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [TimeInterval]

    init(_ values: [TimeInterval]) { self.values = values }

    func now() -> TimeInterval {
        lock.withLock {
            if values.count > 1 { return values.removeFirst() }
            return values[0]
        }
    }
}

private actor InferenceTestChecks {
    var count = 0
    func accept() { count += 1 }
    func changeAfterRequest() throws {
        count += 1
        if count > 1 { throw SparkInferenceTestError.modelChanged }
    }

    func next() -> Int {
        count += 1
        return count
    }
}

private actor InferenceTestGate {
    private(set) var isWaiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false

    func wait() async {
        guard !released else { return }
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private func waitForInferenceTest(_ condition: () async -> Bool) async throws {
    for _ in 0..<5_000 {
        if await condition() { return }
        await Task.yield()
    }
    throw URLError(.timedOut)
}

@Suite @MainActor
struct SparkInferenceTestTests {
    @Test func fixedRequestMeasuresFirstReasoningOutputAndUsesOnlyReportedUsage() async throws {
        let stream = InferenceTestScript([
            .chunk(id: nil, model: "served-alias", delta: nil, finishReason: nil),
            .chunk(
                id: nil,
                model: "served-alias",
                delta: nil,
                reasoning: "Thinking",
                finishReason: nil
            ),
            .chunk(id: nil, model: "served-alias", delta: "It works.", finishReason: "stop"),
            .usage(prompt: 12, completion: 8, total: 20), .done,
        ])
        let clock = InferenceTestClock([10, 10.25, 11.5])
        let checks = InferenceTestChecks()
        let model = SparkInferenceTestModel(
            target: inferenceTestTarget(),
            streamer: stream,
            checkModel: { _ in await checks.accept() },
            monotonicNow: clock.now
        )
        await model.start()?.value
        #expect(model.phase == .succeeded)
        #expect(model.firstOutputSeconds == 0.25)
        #expect(model.elapsedSeconds == 1.5)
        #expect(model.usage == SparkInferenceTestUsage(prompt: 12, completion: 8, total: 20))
        #expect(model.reportedServingName == "served-alias")
        #expect(model.answer == "It works.")
        #expect(model.reasoning == "Thinking")
        #expect(await checks.count == 2)
        let request = try #require(await stream.requests.first)
        #expect(request.messages == [ChatMessage(content: SparkInferenceTestModel.prompt)])
        #expect(request.model == "example/model")
        #expect(request.maxTokens == 1024)
        #expect(request.stream && request.streamOptionsIncludeUsage == true)
        #expect(request.temperature == nil)
    }

    @Test func reasoningAtTokenLimitIsOutputReceivedWithoutInventingAnAnswerOrUsage() async {
        let stream = InferenceTestScript([
            .chunk(id: nil, model: nil, delta: nil, reasoning: "Thinking", finishReason: "length"),
            .done,
        ])
        let model = SparkInferenceTestModel(
            target: inferenceTestTarget(),
            streamer: stream,
            checkModel: { _ in }
        )
        await model.start()?.value
        #expect(model.phase == .limited)
        #expect(model.answer.isEmpty)
        #expect(model.firstOutputSeconds != nil)
        #expect(model.usage == nil)
        #expect(model.reportedServingName == nil)
    }

    @Test(arguments: ["content_filter", "error", "tool_calls", "unknown"])
    func abnormalFinishesNeverBecomeSuccessful(_ finish: String) async {
        let stream = InferenceTestScript([
            .chunk(id: nil, model: nil, delta: "Partial output", finishReason: finish), .done,
        ])
        let model = SparkInferenceTestModel(
            target: inferenceTestTarget(),
            streamer: stream,
            checkModel: { _ in }
        )
        await model.start()?.value
        #expect(model.phase == .failed)
        #expect(model.errorMessage == SparkInferenceTestError.abnormalFinish.message)
    }

    @Test func emptyOutputAndUnconfirmedEOFAreFailures() async {
        for events: [ChatStreamEvent] in [
            [.chunk(id: nil, model: nil, delta: nil, finishReason: "stop"), .done],
            [.chunk(id: nil, model: nil, delta: "Partial", finishReason: nil)],
        ] {
            let model = SparkInferenceTestModel(
                target: inferenceTestTarget(),
                streamer: InferenceTestScript(events),
                checkModel: { _ in }
            )
            await model.start()?.value
            #expect(model.phase == .failed)
            #expect(model.errorMessage != nil)
        }
    }

    @Test func malformedUsageIsUnavailableAndNeverEstimatedFromOutput() async {
        let stream = InferenceTestScript([
            .chunk(id: nil, model: nil, delta: "Response", finishReason: "stop"),
            .usage(prompt: -1, completion: 10, total: 9), .done,
        ])
        let model = SparkInferenceTestModel(
            target: inferenceTestTarget(),
            streamer: stream,
            checkModel: { _ in }
        )
        await model.start()?.value
        #expect(model.phase == .succeeded)
        #expect(model.usage == nil)
        #expect(SparkInferenceTestUsage(prompt: Int.max, completion: 1, total: 0) == nil)
        #expect(SparkInferenceTestUsage(prompt: 1, completion: 2, total: 4) == nil)
    }

    @Test func failedReadinessAndClusterTargetsNeverSendARequest() async {
        let stream = InferenceTestScript([])
        for target in [inferenceTestTarget(), inferenceTestTarget(cluster: true)] {
            let model = SparkInferenceTestModel(
                target: target,
                streamer: stream,
                checkModel: { _ in
                    throw SparkInferenceTestError.modelChanged
                }
            )
            await model.start()?.value
            #expect(model.phase == .failed)
        }
        #expect(await stream.requests.isEmpty)
    }

    @Test func modelChangeAfterOutputCannotPass() async {
        let checks = InferenceTestChecks()
        let model = SparkInferenceTestModel(
            target: inferenceTestTarget(),
            streamer: InferenceTestScript([
                .chunk(id: nil, model: nil, delta: "Response", finishReason: "stop"), .done,
            ]),
            checkModel: { _ in try await checks.changeAfterRequest() }
        )
        await model.start()?.value
        #expect(model.phase == .failed)
        #expect(model.errorMessage == SparkInferenceTestError.modelChanged.message)
    }

    @Test func changedServingAliasAndOversizedOutputAreRefused() async {
        for events: [ChatStreamEvent] in [
            [
                .chunk(id: nil, model: "first", delta: "One", finishReason: nil),
                .chunk(id: nil, model: "second", delta: "Two", finishReason: "stop"), .done,
            ],
            [
                .chunk(
                    id: nil,
                    model: nil,
                    delta: String(
                        repeating: "x",
                        count: SparkInferenceTestModel.maximumOutputBytes + 1
                    ),
                    finishReason: "stop"
                ), .done,
            ],
        ] {
            let model = SparkInferenceTestModel(
                target: inferenceTestTarget(),
                streamer: InferenceTestScript(events),
                checkModel: { _ in }
            )
            await model.start()?.value
            #expect(model.phase == .failed)
            #expect(model.answer.utf8.count <= SparkInferenceTestModel.maximumOutputBytes)
        }
    }

    @Test func streamErrorAfterOutputDoesNotBecomeASuccess() async {
        let model = SparkInferenceTestModel(
            target: inferenceTestTarget(),
            streamer: InferenceTestScript(
                [.chunk(id: nil, model: nil, delta: "Partial", finishReason: nil)],
                fails: true
            ),
            checkModel: { _ in }
        )
        await model.start()?.value
        #expect(model.phase == .failed)
        #expect(model.answer == "Partial")
    }

    @Test func cancellationTerminatesTheStreamAndRetryCannotReceiveOldOutput() async throws {
        let stream = InferenceTestHeldStream()
        let model = SparkInferenceTestModel(
            target: inferenceTestTarget(),
            streamer: stream,
            checkModel: { _ in }
        )
        let first = model.start()
        #expect(model.start() == nil)
        try await waitForInferenceTest { await stream.requestCount == 1 }
        model.cancel()
        await first?.value
        #expect(model.phase == .cancelled)
        try await waitForInferenceTest { await stream.terminated.contains(0) }
        let second = model.start()
        try await waitForInferenceTest { await stream.requestCount == 2 }
        await stream.finish(0, text: "Old output")
        await stream.finish(1, text: "New output")
        await second?.value
        #expect(model.phase == .succeeded)
        #expect(model.answer == "New output")
    }

    @Test func deadlineCancelsAStalledStream() async throws {
        let stream = InferenceTestHeldStream()
        let model = SparkInferenceTestModel(
            target: inferenceTestTarget(),
            streamer: stream,
            checkModel: { _ in },
            waitForDeadline: { try await Task.sleep(for: .milliseconds(20)) }
        )
        await model.start()?.value
        #expect(model.phase == .failed)
        #expect(model.errorMessage == SparkInferenceTestError.timedOut.message)
        try await waitForInferenceTest { await stream.terminated.contains(0) }
    }

    @Test(arguments: [false, true])
    func cancellationOrDeadlineDuringPostflightPreservesTheFinishedStreamTime(_ timeout: Bool)
        async throws
    {
        let checks = InferenceTestChecks()
        let postflight = InferenceTestGate()
        let deadline = InferenceTestGate()
        let clock = InferenceTestClock([10, 10.25, 11.5, 99])
        let model = SparkInferenceTestModel(
            target: inferenceTestTarget(),
            streamer: InferenceTestScript([
                .chunk(id: nil, model: nil, delta: "Response", finishReason: "stop"), .done,
            ]),
            checkModel: { _ in
                if await checks.next() == 2 { await postflight.wait() }
            },
            monotonicNow: clock.now,
            waitForDeadline: { await deadline.wait() }
        )
        let task = model.start()
        try await waitForInferenceTest { await postflight.isWaiting }
        #expect(model.elapsedSeconds == 1.5)
        if timeout {
            await deadline.release()
            try await waitForInferenceTest { model.phase == .failed }
        } else {
            model.cancel()
            await deadline.release()
        }
        await postflight.release()
        await task?.value
        #expect(model.phase == (timeout ? .failed : .cancelled))
        #expect(model.elapsedSeconds == 1.5)
        #expect(model.firstOutputSeconds == 0.25)
    }

    @Test func cancellationDuringReadinessNeverStartsTheStream() async throws {
        let gate = InferenceTestGate()
        let stream = InferenceTestScript([])
        let model = SparkInferenceTestModel(
            target: inferenceTestTarget(),
            streamer: stream,
            checkModel: { _ in await gate.wait() }
        )
        let task = model.start()
        try await waitForInferenceTest { await gate.isWaiting }
        model.cancel()
        await gate.release()
        await task?.value
        #expect(model.phase == .cancelled)
        #expect(await stream.requests.isEmpty)
        #expect(model.firstOutputSeconds == nil)
        #expect(model.elapsedSeconds == nil)
    }

    @Test func readinessRequiresTheExpectedModelAndProfile() throws {
        let target = inferenceTestTarget()
        for (state, modelID, profile, accepted) in [
            ("ready", "example/model", "small", true),
            ("idle", "example/model", "small", true),
            ("loading", "example/model", "small", false),
            ("ready", "different/model", "small", false),
            ("ready", "example/model", "large", false),
        ] {
            let data = Data(
                """
                {"state":"\(state)","model_id":"\(modelID)","profile_id":"\(profile)",
                "active_requests":0,"queue_depth":0}
                """.utf8
            )
            let active = try JSONDecoder().decode(ActiveInference.self, from: data)
            if accepted {
                try target.validate(active)
            } else {
                #expect(throws: SparkInferenceTestError.self) { try target.validate(active) }
            }
        }
    }
    @Test func aCompletedDiagnosticPersistsMeasurementsWithoutAnswerOrThinking() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSparkInferenceRunStore(url: directory.appendingPathComponent("runs.json"))
        let history = SparkInferenceRunHistory(store: store)
        let stream = InferenceTestScript([
            .chunk(
                id: nil,
                model: "served-alias",
                delta: "private generated answer",
                reasoning: "private thought",
                finishReason: "stop"
            ),
            .usage(prompt: 12, completion: 8, total: 20), .done,
        ])
        let model = SparkInferenceTestModel(
            target: inferenceTestTarget(),
            streamer: stream,
            history: history,
            checkModel: { _ in }
        )
        await model.start()?.value
        let record = try #require(history.records.first)
        #expect(record.outcome == "succeeded")
        #expect(record.promptTokens == 12 && record.completionTokens == 8)
        #expect(record.outputReceived)
        let disk = try String(contentsOf: store.url, encoding: .utf8)
        #expect(!disk.contains("private generated answer"))
        #expect(!disk.contains("private thought"))
        #expect(!disk.contains("spark.invalid"))
        #expect(try store.read() == history.records)
    }

}
