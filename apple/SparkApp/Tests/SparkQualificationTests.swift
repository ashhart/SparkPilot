import Foundation
import SparkAPI
import SparkCore
import Testing
@testable import SparkAppComposition

private final class QualificationTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 100.0
    func now() -> Double { lock.withLock { value } }
    func advance(_ seconds: Double) { lock.withLock { value += seconds } }
}

private func qualificationTarget() -> SparkInferenceTestTarget {
    .init(
        chat: .init(
            id: "test",
            displayName: "Private host name",
            nodeID: SparkNodeID(rawValue: UUID()),
            route: URL(string: "https://private-host.invalid:7443")!,
            tlsFingerprint: String(repeating: "a", count: 64),
            authorityFingerprint: String(repeating: "b", count: 64),
            modelID: "example/model",
            modelName: "Example"
        ),
        profileID: "balanced"
    )
}

private func qualificationDeployment(digest: String = String(repeating: "a", count: 64)) throws
    -> SparkRequestDeploymentEvidence
{
    let value: [String: Any] = [
        "recipe_digest": digest, "recipe_revision": "2026-09-04.1",
        "source_revision": String(repeating: "b", count: 40),
        "engine_recipe": "vllm",
        "engine_image": "private.registry.internal/model@sha256:"
            + String(repeating: "c", count: 64),
        "context_length": 8192, "max_sequences": 4, "runtime_version": "0.1.12",
        "verification": "admitted_recipe_only",
    ]
    return try JSONDecoder().decode(
        SparkRequestDeploymentEvidence.self,
        from: JSONSerialization.data(withJSONObject: value)
    )
}

private actor QualificationScript: SparkQualificationExecuting {
    let clock: QualificationTestClock
    let failCorrectness: Bool
    let changeAfter: Int?
    let hold: Bool
    let budgetLimited: Bool
    let observedEngine: Int?
    let historyRecording: Bool?
    let cachedOwnObservation: Bool
    private(set) var requests: [SparkQualificationWorkload] = []
    private(set) var cancelledRequests = 0
    init(
        clock: QualificationTestClock,
        failCorrectness: Bool = false,
        changeAfter: Int? = nil,
        hold: Bool = false,
        budgetLimited: Bool = false,
        observedEngine: Int? = nil,
        historyRecording: Bool? = nil,
        cachedOwnObservation: Bool = false
    ) {
        self.clock = clock
        self.failCorrectness = failCorrectness
        self.changeAfter = changeAfter
        self.hold = hold
        self.budgetLimited = budgetLimited
        self.observedEngine = observedEngine
        self.historyRecording = historyRecording
        self.cachedOwnObservation = cachedOwnObservation
    }
    func identity(target: SparkInferenceTestTarget) async throws -> SparkQualificationIdentity {
        if let historyRecording {
            try await PinnedSparkQualificationExecutor.requireHistoryRecording {
                let body: [String: Any] = [
                    "recording": historyRecording, "retention_seconds": 1,
                    "maximum_records": 1, "timing_source": "runtime_proxy", "records": [],
                ]
                return try JSONDecoder().decode(
                    SparkInferenceRequestHistory.self,
                    from: JSONSerialization.data(withJSONObject: body)
                )
            }
        }
        return SparkQualificationIdentity(
            modelID: target.chat.modelID,
            profileID: target.profileID!,
            recipeDigest: String(repeating: "a", count: 64),
            recipeRevision: "2026-09-04.1",
            sourceRevision: String(repeating: "b", count: 40),
            runtimeVersion: "0.1.12",
            contextLimit: 8192,
            sequenceLimit: 4,
            systemReserveBytes: 1024,
            deployment: nil
        )
    }
    func sample(target: SparkInferenceTestTarget, elapsed: Double) async throws
        -> SparkQualificationMemorySample
    {
        let cachedOwn = cachedOwnObservation && requests.count == 11
        return .init(
            elapsedSeconds: elapsed,
            availableBytes: 8192,
            memoryPressure: "normal",
            proxyActiveRequests: 0,
            observedEngineRunning: cachedOwn ? 1 : observedEngine,
            engineSampleEarliestSeconds: cachedOwn
                ? elapsed - 0.019 : observedEngine.map { _ in elapsed },
            engineSampleLatestSeconds: cachedOwn
                ? elapsed - 0.001 : observedEngine.map { _ in elapsed }
        )
    }
    func request(
        target: SparkInferenceTestTarget,
        workload: SparkQualificationWorkload,
        runStarted: TimeInterval
    ) async throws -> SparkQualificationRequestMeasurement {
        requests.append(workload)
        if hold {
            do { try await Task.sleep(for: .seconds(60)) } catch {
                cancelledRequests += 1
                throw error
            }
        }
        let changed = changeAfter.map { requests.count >= $0 } ?? false
        let start = clock.now() - runStarted
        clock.advance(0.02)
        return SparkQualificationRequestMeasurement(
            workload: workload,
            startedSeconds: start,
            elapsedSeconds: 0.02,
            firstOutputSeconds: 0.01,
            promptTokens: 10,
            completionTokens: 8,
            exactAnswerMatched: budgetLimited
                ? nil : workload.expectedAnswer.map { _ in !failCorrectness },
            terminalConfirmed: true,
            outputReceived: true,
            runtimeAttemptID: UUID(),
            deployment: try qualificationDeployment(
                digest: String(repeating: changed ? "d" : "a", count: 64)
            )
        )
    }
}

@Suite @MainActor
struct SparkQualificationTests {
    @Test func presetHasClosedBoundedWorkloadsAndNoExecutionInstructions() throws {
        let preset = SparkQualificationPreset.quick
        #expect(preset.maximumRequests == SparkQualificationWorkload.allCases.count)
        #expect(
            preset.maximumGeneratedTokens
                == SparkQualificationWorkload.allCases.map(\.outputLimit).reduce(0, +)
        )
        #expect(preset.maximumDurationSeconds == 240)
        #expect(SparkQualificationWorkload.allCases.allSatisfy { $0.prompt.utf8.count < 16_384 })
        #expect(SparkQualificationRunner.percentile([3, 1, 2], 0.5) == 2)
        #expect(SparkQualificationRunner.percentile([3, 1, 2], 0.95) == 3)
        #expect(SparkQualificationRunner.percentile([.nan], 0.95) == nil)
    }

    @Test func actualUsageAndEngineObservationsStaySeparateFromRequestedCapacity() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = QualificationTestClock(), target = qualificationTarget()
        let script = QualificationScript(clock: clock)
        let store = SparkQualificationStore(directory: directory)
        let runner = SparkQualificationRunner(
            target: target,
            executor: script,
            store: store,
            now: clock.now,
            pause: { clock.advance($0) }
        )
        await runner.start()?.value
        let manifest = try #require(runner.manifest)
        #expect(manifest.state == "completed_incomplete_qualification")
        #expect(manifest.requests.count == 11)
        #expect(await script.requests.count == 11)
        #expect(manifest.cases.count == 6)
        #expect(manifest.cases.first { $0.kind == .context }?.verdict == .notDemonstrated)
        #expect(manifest.cases.first { $0.kind == .context }?.value == 10)
        #expect(manifest.cases.first { $0.kind == .concurrency }?.verdict == .notDemonstrated)
        #expect(manifest.cases.first { $0.kind == .concurrency }?.value == nil)
        #expect(manifest.cases.first { $0.kind == .stability }?.value ?? 0 >= 30)
        #expect(manifest.missingAttestations.contains("driver"))
        #expect(try store.load() == [manifest])
        let shared = try SparkQualificationExport(manifest).encoded()
        for forbidden in [
            "private.registry", "private-host", "Private host name", "runtimeAttemptID",
            "createdAt", manifest.id.uuidString,
        ] {
            #expect(!shared.contains(forbidden))
        }
        #expect(shared.contains("incomplete_no_profile_promotion"))
        #expect(!shared.contains(SparkQualificationWorkload.context.prompt))
    }

    @Test func failedSyntheticCorrectnessStopsBeforePerformanceCases() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = QualificationTestClock(),
            script = QualificationScript(clock: QualificationTestClock(), failCorrectness: true)
        let runner = SparkQualificationRunner(
            target: qualificationTarget(),
            executor: script,
            store: SparkQualificationStore(directory: directory),
            now: clock.now,
            pause: { _ in }
        )
        await runner.start()?.value
        #expect(await script.requests == [.arithmetic, .echo])
        #expect(runner.manifest?.state == "failed")
        #expect(runner.manifest?.cases.first { $0.kind == .correctness }?.verdict == .failed)
    }

    @Test func changedProvenanceStopsTheEntireRunWithoutMixingMeasurements() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = QualificationTestClock(), target = qualificationTarget()
        let script = QualificationScript(clock: clock, changeAfter: 4)
        let runner = SparkQualificationRunner(
            target: target,
            executor: script,
            store: SparkQualificationStore(directory: directory),
            now: clock.now,
            pause: { _ in }
        )
        await runner.start()?.value
        #expect(runner.errorCode == "DEPLOYMENT_CHANGED")
        #expect(await script.requests.count == 4)
        #expect(runner.manifest?.requests.count == 3)
        #expect(
            runner.manifest?.identity?.deployment?.recipeDigest == String(repeating: "a", count: 64)
        )
    }

    @Test func suspensionCancelsActiveExecutionAndPersistsAnHonestOutcome() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = QualificationTestClock(),
            script = QualificationScript(clock: QualificationTestClock(), hold: true)
        let store = SparkQualificationStore(directory: directory)
        let runner = SparkQualificationRunner(
            target: qualificationTarget(),
            executor: script,
            store: store,
            now: clock.now
        )
        let task = runner.start()
        for _ in 0..<5000 {
            if await script.requests.count > 0 { break }
            await Task.yield()
        }
        runner.cancel(suspended: true)
        await task?.value
        #expect(await script.cancelledRequests == 1)
        #expect(runner.manifest?.state == "cancelled")
        #expect(runner.manifest?.failureCode == "APP_SUSPENDED_OUTCOME_UNKNOWN")
        #expect(try store.load().first?.state == "cancelled")
    }

    @Test func reproductionRefusesChangedRecordedConfigurationBeforeSendingAnything() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = QualificationTestClock(), target = qualificationTarget()
        let script = QualificationScript(clock: clock)
        var old = SparkQualificationManifest.new()
        old.state = "completed_incomplete_qualification"
        old.identity = SparkQualificationIdentity(
            modelID: target.chat.modelID,
            profileID: target.profileID!,
            recipeDigest: String(repeating: "d", count: 64),
            recipeRevision: "old",
            sourceRevision: String(repeating: "b", count: 40),
            runtimeVersion: "0.1.12",
            contextLimit: 8192,
            sequenceLimit: 4,
            systemReserveBytes: 1024,
            deployment: try qualificationDeployment()
        )
        let runner = SparkQualificationRunner(
            target: target,
            executor: script,
            store: SparkQualificationStore(directory: directory),
            now: clock.now
        )
        await runner.start(reproducing: old)?.value
        #expect(await script.requests.isEmpty)
        #expect(runner.errorCode == "DEPLOYMENT_CHANGED")
    }

    @Test func interruptedManifestRecoversOnceAndTerminalEvidenceCannotBeOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SparkQualificationStore(directory: directory)
        let original = SparkQualificationManifest.new()
        try store.save(original)
        #expect(try store.load(activeIDs: [original.id]).first?.state == "running")
        let recovered = try #require(store.load().first)
        #expect(recovered.state == "interrupted")
        #expect(recovered.failureCode == "APP_RESTARTED_OUTCOME_UNKNOWN")
        var replacement = original
        replacement.state = "completed_incomplete_qualification"
        try store.save(replacement)
        #expect(try store.load() == [recovered])
    }
    @Test func reasoningBudgetLimitIsNotAWrongAnswerAndOtherSafeChecksContinue() async throws {
        var parser = SparkQualificationResponseAccumulator()
        try parser.receive(
            .chunk(
                id: nil,
                model: nil,
                delta: nil,
                reasoning: "Let me think through the arithmetic",
                finishReason: nil
            ),
            elapsed: 0.1
        )
        try parser.receive(.usage(prompt: 12, completion: 32, total: 44), elapsed: 0.2)
        try parser.receive(
            .chunk(id: nil, model: nil, delta: nil, finishReason: "length"),
            elapsed: 0.2
        )
        try parser.receive(.done, elapsed: 0.2)
        try parser.validateTerminal()
        #expect(parser.finishReason == "length")
        #expect(parser.usage?.completion == 32)
        #expect(parser.exactAnswerMatched(.arithmetic) == nil)
        var hiddenReasoning = SparkQualificationResponseAccumulator()
        try hiddenReasoning.receive(
            .chunk(id: nil, model: nil, delta: nil, finishReason: "length"),
            elapsed: 0.2
        )
        try hiddenReasoning.receive(.done, elapsed: 0.2)
        try hiddenReasoning.validateTerminal()
        #expect(!hiddenReasoning.outputReceived)
        #expect(hiddenReasoning.exactAnswerMatched(.arithmetic) == nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = QualificationTestClock(),
            script = QualificationScript(clock: clock, budgetLimited: true)
        let runner = SparkQualificationRunner(
            target: qualificationTarget(),
            executor: script,
            store: SparkQualificationStore(directory: directory),
            now: clock.now,
            pause: { clock.advance($0) }
        )
        await runner.start()?.value
        #expect(await script.requests.count == 11)
        #expect(
            runner.manifest?.cases.first(where: { $0.kind == .correctness })?.verdict
                == .notDemonstrated
        )
        #expect(runner.manifest?.state == "completed_incomplete_qualification")
    }

    @Test func actualParserSeparatesCompletedWrongAnswerMissingAnswerAndTruncation() throws {
        for (answer, finish, expected): (String?, String?, Bool?) in [
            ("41", "stop", false), ("42", "stop", true), ("42", "length", nil),
            (nil, "stop", nil), ("41", nil, nil),
        ] {
            var parser = SparkQualificationResponseAccumulator()
            try parser.receive(
                .chunk(
                    id: nil,
                    model: nil,
                    delta: answer,
                    reasoning: "thinking",
                    finishReason: finish
                ),
                elapsed: 1
            )
            try parser.receive(.done, elapsed: 1)
            try parser.validateTerminal()
            #expect(parser.exactAnswerMatched(.arithmetic) == expected)
        }
    }

    @Test func disabledHistoryStopsBeforeAnySyntheticRequestAndUnsupportedHistoryIsSymbolic()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = QualificationScript(clock: QualificationTestClock(), historyRecording: false)
        let runner = SparkQualificationRunner(
            target: qualificationTarget(),
            executor: script,
            store: SparkQualificationStore(directory: directory)
        )
        await runner.start()?.value
        #expect(await script.requests.isEmpty)
        #expect(runner.errorCode == "PROVENANCE_UNAVAILABLE")
        await #expect(throws: SparkQualificationError.provenanceUnavailable) {
            try await PinnedSparkQualificationExecutor.requireHistoryRecording {
                throw URLError(.unsupportedURL)
            }
        }
    }

    @Test func invisibleExternalEngineWorkRefusesInitialIdleCheck() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = QualificationScript(clock: QualificationTestClock(), observedEngine: 1)
        let runner = SparkQualificationRunner(
            target: qualificationTarget(),
            executor: script,
            store: SparkQualificationStore(directory: directory)
        )
        await runner.start()?.value
        #expect(await script.requests.isEmpty)
        #expect(runner.errorCode == "OTHER_WORK_OBSERVED")
    }

    @Test func cachedEngineCountsOnlyQualifyWhenEntireSampleWindowIsInsideOwnedOverlap() {
        var sample = SparkQualificationMemorySample(
            elapsedSeconds: 8,
            availableBytes: 100,
            memoryPressure: "normal",
            proxyActiveRequests: 0,
            observedEngineRunning: 2
        )
        #expect(
            SparkQualificationRunner.observedConcurrency([sample], overlapStart: 5, overlapEnd: 7)
                == nil
        )
        sample.engineSampleEarliestSeconds = 2
        sample.engineSampleLatestSeconds = 4
        #expect(
            SparkQualificationRunner.observedConcurrency([sample], overlapStart: 5, overlapEnd: 7)
                == nil
        )
        sample.engineSampleEarliestSeconds = 4.5
        sample.engineSampleLatestSeconds = 6
        #expect(
            SparkQualificationRunner.observedConcurrency([sample], overlapStart: 5, overlapEnd: 7)
                == nil
        )
        sample.engineSampleEarliestSeconds = 5.1
        sample.engineSampleLatestSeconds = 6.1
        #expect(
            SparkQualificationRunner.observedConcurrency([sample], overlapStart: 5, overlapEnd: 7)
                == 2
        )
    }

    @Test func cachedCountFromOurCompletedRequestDoesNotBecomeFalseInterference() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = QualificationTestClock()
        let script = QualificationScript(clock: clock, cachedOwnObservation: true)
        let runner = SparkQualificationRunner(
            target: qualificationTarget(),
            executor: script,
            store: SparkQualificationStore(directory: directory),
            now: clock.now,
            pause: { clock.advance($0) }
        )
        await runner.start()?.value
        #expect(runner.manifest?.state == "completed_incomplete_qualification")
        #expect(runner.errorCode == nil)
        #expect(
            runner.manifest?.cases.first(where: { $0.kind == .concurrency })?.verdict
                == .notDemonstrated
        )
    }

}
