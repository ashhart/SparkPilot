import Foundation
import Observation
import SparkAPI
import SparkSecurity

struct SparkInferenceTestTarget: Identifiable, Equatable, Sendable {
    let chat: SparkChatTarget
    let profileID: String?

    var id: String { chat.id }

    func validate(_ active: ActiveInference) throws {
        guard chat.clusterID == nil,
            active.state == .ready || active.state == .idle,
            active.modelID == chat.modelID,
            active.profileID == profileID
        else { throw SparkInferenceTestError.modelChanged }
    }

    static func checkCurrentModel(_ target: Self) async throws {
        guard target.chat.clusterID == nil else { throw SparkInferenceTestError.modelChanged }
        let signer = try DeviceIdentityStore.loadOrCreateSigner(nodeID: target.chat.nodeID.rawValue)
        let api = try SparkAPIClient.pinned(to: target.chat.tlsFingerprint, signer: signer)
        let identity = try await api.identity(route: target.chat.route)
        guard identity.nodeID == target.chat.nodeID,
            identity.clusterID == nil,
            identity.authorityFingerprint == target.chat.authorityFingerprint
        else { throw SparkChatConnectionError.identityMismatch }
        try target.validate(await api.activeInference(route: target.chat.route))
    }
}

enum SparkInferenceTestError: Error {
    case modelChanged, incompleteStream, noOutput, outputTooLarge, timedOut, abnormalFinish

    var message: String {
        switch self {
        case .modelChanged:
            String(
                localized: "The loaded model or profile changed. Refresh the Spark and try again."
            )
        case .incompleteStream:
            String(
                localized: "The response ended without confirming completion. Try the test again."
            )
        case .noOutput:
            String(localized: "The model completed the request without returning any output.")
        case .outputTooLarge:
            String(localized: "The response exceeded the small test's limit, so the test stopped.")
        case .timedOut:
            String(
                localized:
                    "The test took longer than a minute and was stopped. Check the Spark and try again."
            )
        case .abnormalFinish:
            String(
                localized: "The model filtered, refused or unexpectedly ended the test response."
            )
        }
    }
}

struct SparkInferenceTestUsage: Equatable, Sendable {
    let prompt: Int
    let completion: Int
    let total: Int

    init?(prompt: Int, completion: Int, total: Int) {
        guard prompt >= 0, completion >= 0, total >= 0,
            prompt <= Int.max - completion, total == prompt + completion
        else { return nil }
        self.prompt = prompt
        self.completion = completion
        self.total = total
    }
}

enum SparkInferenceTestPhase: String, Equatable {
    case ready, checking, waiting, receiving, succeeded, limited, cancelled, failed

    var isRunning: Bool { self == .checking || self == .waiting || self == .receiving }
}

/// Measures one bounded request through readiness and streaming only, persisting content-free client timings when a history store is supplied.
@MainActor
@Observable
final class SparkInferenceTestModel {
    static let prompt = "Reply with one short sentence confirming that you can answer a request."
    static let maximumOutputTokens = 1024
    static let maximumOutputBytes = 16_384

    let target: SparkInferenceTestTarget
    private(set) var phase: SparkInferenceTestPhase = .ready
    private(set) var firstOutputSeconds: TimeInterval?
    private(set) var elapsedSeconds: TimeInterval?
    private(set) var usage: SparkInferenceTestUsage?
    private(set) var reportedServingName: String?
    private(set) var answer = ""
    private(set) var reasoning = ""
    private(set) var errorMessage: String?
    private(set) var runtimeRecord: SparkInferenceRequestRecord?
    private(set) var stateChanged = false
    let history: SparkInferenceRunHistory?

    @ObservationIgnored private let streamer: any SparkChatStreaming
    @ObservationIgnored private let checkModel:
        @Sendable (SparkInferenceTestTarget) async throws -> Void
    @ObservationIgnored private let monotonicNow: @Sendable () -> TimeInterval
    @ObservationIgnored private let waitForDeadline: @Sendable () async throws -> Void
    @ObservationIgnored private let attemptTracker: SparkInferenceAttemptTracker
    @ObservationIgnored private let collectRuntimeEvidence: Bool
    @ObservationIgnored private var wallStartedAt: Date?
    @ObservationIgnored private var startedAt: TimeInterval?
    @ObservationIgnored private var activeRunID: UUID?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?

    init(
        target: SparkInferenceTestTarget,
        streamer: (any SparkChatStreaming)? = nil,
        history: SparkInferenceRunHistory? = nil,
        checkModel: @escaping @Sendable (SparkInferenceTestTarget) async throws -> Void =
            SparkInferenceTestTarget.checkCurrentModel,
        monotonicNow: @escaping @Sendable () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        waitForDeadline: @escaping @Sendable () async throws -> Void = {
            try await Task.sleep(for: .seconds(60))
        }
    ) {
        self.target = target
        let tracker = SparkInferenceAttemptTracker()
        self.attemptTracker = tracker
        self.streamer =
            streamer ?? PinnedSparkInferenceTestStreamer(target: target, tracker: tracker)
        self.collectRuntimeEvidence = streamer == nil
        self.history = history
        self.checkModel = checkModel
        self.monotonicNow = monotonicNow
        self.waitForDeadline = waitForDeadline
    }

    @discardableResult
    func start() -> Task<Void, Never>? {
        guard !phase.isRunning else { return nil }
        firstOutputSeconds = nil
        elapsedSeconds = nil
        usage = nil
        reportedServingName = nil
        runtimeRecord = nil
        stateChanged = false
        attemptTracker.reset()
        wallStartedAt = Date()
        answer = ""
        reasoning = ""
        errorMessage = nil
        startedAt = nil
        phase = .checking
        let runID = UUID()
        activeRunID = runID
        saveRun(runID)
        let task = Task { await run(runID) }
        self.task = task
        timeoutTask = Task { [waitForDeadline] in
            do {
                try await waitForDeadline()
                guard activeRunID == runID, !Task.isCancelled else { return }
                stop(with: .failed, message: SparkInferenceTestError.timedOut.message)
            } catch {}
        }
        return task
    }

    func cancel() {
        guard phase.isRunning else { return }
        stop(with: .cancelled, message: nil)
    }

    private func stop(with phase: SparkInferenceTestPhase, message: String?) {
        elapsedSeconds = elapsedSeconds ?? elapsed()
        self.phase = phase
        if let runID = activeRunID { saveRun(runID) }
        activeRunID = nil
        task?.cancel()
        timeoutTask?.cancel()
        task = nil
        timeoutTask = nil
        self.phase = phase
        errorMessage = message
    }

    private func saveRun(_ id: UUID) {
        guard let wallStartedAt else { return }
        history?.save(
            SparkInferenceRunRecord(
                id: id,
                harnessVersion: "sparkpilot-inference-smoke-v1",
                modelID: target.chat.modelID,
                profileID: target.profileID,
                startedAt: wallStartedAt,
                finishedAt: phase.isRunning ? nil : Date(),
                outcome: phase.rawValue,
                firstOutputSeconds: firstOutputSeconds,
                elapsedSeconds: elapsedSeconds,
                promptTokens: usage?.prompt,
                completionTokens: usage?.completion,
                outputReceived: firstOutputSeconds != nil,
                stateChanged: stateChanged,
                runtimeRecord: runtimeRecord
            )
        )
    }

    private func elapsed() -> TimeInterval? {
        startedAt.map { max(0, monotonicNow() - $0) }
    }

    private func requireCurrent(_ runID: UUID) throws {
        try Task.checkCancellation()
        guard activeRunID == runID else { throw CancellationError() }
    }

    private func run(_ runID: UUID) async {
        defer {
            if activeRunID == runID {
                saveRun(runID)
                activeRunID = nil
                task = nil
                timeoutTask?.cancel()
                timeoutTask = nil
            }
        }
        do {
            guard target.chat.clusterID == nil else { throw SparkInferenceTestError.modelChanged }
            try await checkModel(target)
            try requireCurrent(runID)
            startedAt = monotonicNow()
            phase = .waiting
            let request = ChatCompletionRequest(
                model: target.chat.modelID,
                messages: [ChatMessage(content: Self.prompt)],
                stream: true,
                maxTokens: Self.maximumOutputTokens,
                streamOptionsIncludeUsage: true
            )
            let stream = try await streamer.stream(target: target.chat, request: request)
            try requireCurrent(runID)
            var completed = false
            var reachedLimit = false
            var outputBytes = 0
            events: for try await event in stream {
                try requireCurrent(runID)
                switch event {
                case .chunk(_, let servingName, let delta, let thought, let finishReason):
                    if let servingName, !servingName.isEmpty {
                        // Send the recipe's served alias when it differs from the catalogue model ID.
                        guard servingName.utf8.count <= 512,
                            reportedServingName == nil || reportedServingName == servingName
                        else { throw SparkInferenceTestError.modelChanged }
                        reportedServingName = servingName
                    }
                    let answerBytes = delta?.utf8.count ?? 0
                    let thoughtBytes = thought?.utf8.count ?? 0
                    guard answerBytes <= Self.maximumOutputBytes - outputBytes,
                        thoughtBytes <= Self.maximumOutputBytes - outputBytes - answerBytes
                    else {
                        throw SparkInferenceTestError.outputTooLarge
                    }
                    let added = answerBytes + thoughtBytes
                    outputBytes += added
                    if added > 0 {
                        if firstOutputSeconds == nil { firstOutputSeconds = elapsed() }
                        phase = .receiving
                    }
                    answer += delta ?? ""
                    reasoning += thought ?? ""
                    if let finishReason, !finishReason.isEmpty {
                        guard finishReason == "stop" || finishReason == "length" else {
                            throw SparkInferenceTestError.abnormalFinish
                        }
                        completed = true
                        reachedLimit = finishReason == "length"
                    }
                case .sources: break
                case .usage(let prompt, let completion, let total):
                    usage = SparkInferenceTestUsage(
                        prompt: prompt,
                        completion: completion,
                        total: total
                    )
                case .done:
                    completed = true
                    break events
                }
            }
            try requireCurrent(runID)
            elapsedSeconds = elapsed()
            guard completed else { throw SparkInferenceTestError.incompleteStream }
            guard firstOutputSeconds != nil else { throw SparkInferenceTestError.noOutput }
            try await checkModel(target)
            try requireCurrent(runID)
            if collectRuntimeEvidence, let attemptID = attemptTracker.get() {
                runtimeRecord = try? await target.runtimeRecord(attemptID: attemptID)
                try requireCurrent(runID)
            }
            phase = reachedLimit ? .limited : .succeeded
        } catch {
            guard activeRunID == runID else { return }
            elapsedSeconds = elapsedSeconds ?? elapsed()
            if error is CancellationError || Task.isCancelled {
                phase = .cancelled
            } else {
                phase = .failed
                if let testError = error as? SparkInferenceTestError, case .modelChanged = testError
                {
                    stateChanged = true
                }
                errorMessage =
                    (error as? SparkInferenceTestError)?.message
                    ?? SparkChatFailure.resolve(error).message
            }
        }
    }
}

extension SparkDashboardModel {
    func inferenceTestTarget(displayName: String? = nil) -> SparkInferenceTestTarget? {
        guard case .current = freshness,
            identityIssue == nil,
            let expectedIdentity, expectedIdentity.clusterID == nil,
            let authority = expectedIdentity.authorityFingerprint,
            let tlsFingerprint,
            let inference,
            inference.state == .ready || inference.state == .idle,
            let modelID = inference.modelID
        else { return nil }
        return SparkInferenceTestTarget(
            chat: SparkChatTarget(
                id: targetID,
                displayName: displayName ?? nodeName,
                nodeID: expectedIdentity.coordinatorNodeID,
                route: route,
                tlsFingerprint: tlsFingerprint,
                authorityFingerprint: authority,
                modelID: modelID,
                modelName: models.first(where: { $0.id == modelID })?.displayName ?? modelID
            ),
            profileID: inference.profileID
        )
    }
}
