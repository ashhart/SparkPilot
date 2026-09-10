import Foundation
import SparkAPI
import SparkCore
import SparkIntents
import SparkLibrary
import SparkSecurity
import Testing

@testable import SparkAppComposition

/// Exercise production analysis capability, role, durable-handoff and remote-cancellation boundaries.
private actor AnalysisExecutorSpy: SparkIntentExecuting {
    var supportsAnalysis = true
    private(set) var started:
        [(target: String, input: SparkFileAnalysisInput, instruction: String)] =
            []
    private(set) var polled: [UUID] = []
    private(set) var cancelled: [UUID] = []
    private(set) var capabilityChecks: [String] = []

    let jobID = UUID(uuidString: "6f1c9f4e-0000-4000-8000-000000000001")!
    /// Outcomes handed back in order; the last one repeats.
    var outcomes: [SparkAnalysisHandoff] = [
        .finished(text: "Two risks, both funding.", truncated: false)
    ]

    init(supportsAnalysis: Bool = true, outcomes: [SparkAnalysisHandoff]? = nil) {
        self.supportsAnalysis = supportsAnalysis
        if let outcomes { self.outcomes = outcomes }
    }

    // Unused by this suite; the analysis path must not touch them.
    func status(for target: SparkIntentTarget) async throws -> SparkIntentRuntimeStatus {
        SparkIntentRuntimeStatus(loadedModelName: nil, memoryUsedPercent: 0, waitingJobs: 0)
    }
    func models(for target: SparkIntentTarget) async throws -> [SparkIntentRuntimeModel] { [] }
    func generate(
        on target: SparkIntentTarget,
        userText: String,
        instructions: String?,
        maxTokens: Int
    ) async throws -> String {
        Issue.record("a file analysis must not fall back to foreground generation")
        return ""
    }
    func loadModel(
        _ model: SparkIntentRuntimeModel,
        on target: SparkIntentTarget
    ) async throws -> String { "" }
    func unloadActiveModel(on target: SparkIntentTarget) async throws -> String { "" }

    func supportsDurableAnalysis(on target: SparkIntentTarget) async throws -> Bool {
        capabilityChecks.append(target.id)
        return supportsAnalysis
    }

    func startAnalysis(
        on target: SparkIntentTarget,
        input: SparkFileAnalysisInput,
        instruction: String
    ) async throws -> UUID {
        started.append((target.id, input, instruction))
        return jobID
    }

    func analysisOutcome(
        jobID: UUID,
        on target: SparkIntentTarget
    ) async throws -> SparkAnalysisHandoff {
        polled.append(jobID)
        let index = min(polled.count - 1, outcomes.count - 1)
        return outcomes[index]
    }

    func cancelAnalysis(jobID: UUID, on target: SparkIntentTarget) async {
        cancelled.append(jobID)
    }
}

@MainActor
private func analysisService(
    role: String?,
    executor: any SparkIntentExecuting,
    polling: SparkAnalysisPolling = SparkAnalysisPolling(
        wait: .milliseconds(120),
        interval: .milliseconds(5)
    )
) -> SparkAppIntentService {
    let nodeID = SparkNodeID(rawValue: UUID())
    let authority = String(repeating: "b", count: 64)
    let library = SparkLibrary(store: MemoryLibraryStore())
    library.reconcile(
        AuthenticatedTarget(
            nodeID: nodeID,
            clusterID: nil,
            name: "Desk Spark",
            role: .standalone,
            authorityFingerprint: authority,
            displayName: "desk-spark",
            routes: [
                CachedRoute(
                    baseURL: URL(string: "https://192.168.1.20:7443")!,
                    kind: .localWiFi,
                    lastSuccess: Date(timeIntervalSince1970: 100)
                )
            ],
            reachedAt: Date(timeIntervalSince1970: 100)
        )
    )
    let trust = NodeTrust(
        nodeID: nodeID.rawValue.uuidString.lowercased(),
        nodeName: "Desk Spark",
        tlsFingerprint: String(repeating: "a", count: 64),
        authorityFingerprint: authority,
        authorityPublicKey: "fixture",
        pairedAt: .now,
        localDeviceRole: role
    )
    return SparkAppIntentService(
        library: library,
        trustLookup: { requestedID in requestedID == trust.nodeID ? trust : nil },
        executor: executor,
        analysisPolling: polling
    )
}

private func input(_ text: String = "Risk one. Risk two.") throws -> SparkFileAnalysisInput {
    try SparkFileAnalysisInput.extract(
        data: Data(text.utf8),
        contentType: .plainText,
        suggestedName: "board-notes.txt"
    )
}

/// Reject unpublished durable-analysis capability before sending document contents.
@MainActor
@Test func fileAnalysisIsRefusedWhenTheRuntimeDoesNotPublishTheCapability() async throws {
    let executor = AnalysisExecutorSpy(supportsAnalysis: false)
    let service = analysisService(role: "owner", executor: executor)

    await #expect(throws: SparkIntentError.self) {
        _ = try await service.analyseFile(
            try input(),
            instruction: "List the risks.",
            targetID: nil
        )
    }
    #expect(await executor.capabilityChecks.count == 1)
    #expect(await executor.started.isEmpty, "no document may leave the device")
}

/// Reject observer analysis locally before exposing file bytes (§61).
@MainActor
@Test func observerGrantCannotStartAFileAnalysis() async throws {
    let executor = AnalysisExecutorSpy()
    let service = analysisService(role: "observer", executor: executor)

    await #expect(throws: SparkIntentError.self) {
        _ = try await service.analyseFile(
            try input(),
            instruction: "List the risks.",
            targetID: nil
        )
    }
    #expect(await executor.capabilityChecks.isEmpty)
    #expect(await executor.started.isEmpty)
}

@MainActor
@Test func aFinishedAnalysisComesBackAsText() async throws {
    let executor = AnalysisExecutorSpy()
    let service = analysisService(role: "owner", executor: executor)

    let outcome = try await service.analyseFile(
        try input(),
        instruction: "List the risks.",
        targetID: nil
    )
    #expect(outcome == .finished(text: "Two risks, both funding.", truncated: false))
    #expect(await executor.started.count == 1)
    #expect(await executor.started.first?.instruction == "List the risks.")
    #expect(await executor.cancelled.isEmpty, "a finished job is not cancelled")
}

/// Hand back unfinished durable jobs after the foreground wait expires (§40.3).
@MainActor
@Test func anAnalysisThatOutlivesTheWaitHandsBackItsJob() async throws {
    let executor = AnalysisExecutorSpy(outcomes: [.running(jobID: "unused")])
    let service = analysisService(role: "owner", executor: executor)

    let outcome = try await service.analyseFile(
        try input(),
        instruction: "List the risks.",
        targetID: nil
    )
    #expect(outcome == .running(jobID: await executor.jobID.uuidString.lowercased()))
    #expect(await executor.polled.count >= 1)
    #expect(
        await executor.cancelled.isEmpty,
        "handing back a job must not also stop it"
    )
}

/// Cancel remote work when its initiating intent is abandoned.
@MainActor
@Test func cancellingTheIntentCancelsTheDurableJob() async throws {
    let executor = AnalysisExecutorSpy(outcomes: [.running(jobID: "unused")])
    let service = analysisService(
        role: "owner",
        executor: executor,
        polling: SparkAnalysisPolling(wait: .seconds(30), interval: .milliseconds(20))
    )
    let payload = try input()

    let task = Task {
        try await service.analyseFile(payload, instruction: "List the risks.", targetID: nil)
    }
    // Let the job start and poll at least once before walking away.
    while await executor.polled.isEmpty {
        try await Task.sleep(for: .milliseconds(5))
    }
    task.cancel()

    let result = await task.result
    #expect(throws: CancellationError.self) { try result.get() }
    #expect(await executor.cancelled == [executor.jobID])
}

/// The instruction is bounded on the same terms as the document.
@MainActor
@Test func theAnalysisInstructionIsBounded() async throws {
    let executor = AnalysisExecutorSpy()
    let service = analysisService(role: "owner", executor: executor)

    await #expect(throws: SparkIntentError.self) {
        _ = try await service.analyseFile(
            try input(),
            instruction: String(
                repeating: "x",
                count: SparkAppIntentService.analysisInstructionLimitBytes + 1
            ),
            targetID: nil
        )
    }
    #expect(await executor.started.isEmpty)
}

/// Read an existing analysis job once without starting or cancelling work.
@MainActor
@Test func collectingAnAnalysisReadsTheJobWithoutStartingOrStoppingOne() async throws {
    let executor = AnalysisExecutorSpy()
    let service = analysisService(role: "owner", executor: executor)

    let outcome = try await service.analysisResult(
        jobID: executor.jobID.uuidString,
        targetID: nil
    )
    #expect(outcome == .finished(text: "Two risks, both funding.", truncated: false))
    #expect(await executor.started.isEmpty)
    #expect(await executor.cancelled.isEmpty)
    #expect(await executor.polled == [executor.jobID])
}

/// Reject malformed job identifiers before issuing a request.
@MainActor
@Test func collectingRefusesAnIdentifierThatIsNotAJob() async throws {
    let executor = AnalysisExecutorSpy()
    let service = analysisService(role: "owner", executor: executor)

    await #expect(throws: SparkIntentError.self) {
        _ = try await service.analysisResult(jobID: "../../operations", targetID: nil)
    }
    #expect(await executor.polled.isEmpty)
}
