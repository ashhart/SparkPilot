import Foundation
import SparkAPI
import SparkSecurity

enum SparkQualificationError: String, Error, Sendable {
    case identityChanged = "IDENTITY_CHANGED"
    case deploymentChanged = "DEPLOYMENT_CHANGED"
    case otherWork = "OTHER_WORK_OBSERVED"
    case unsafeMemory = "MEMORY_GUARD_OR_RESERVE"
    case unsupportedProfile = "PROFILE_TOO_SMALL"
    case provenanceUnavailable = "PROVENANCE_UNAVAILABLE"
    case responseInvalid = "RESPONSE_INVALID"
    case requestTimedOut = "REQUEST_TIMEOUT"
    case requestFailed = "REQUEST_FAILED"
    case runtimeUnavailable = "RUNTIME_UNAVAILABLE"
    case runTimedOut = "RUN_TIMEOUT"
    case storageFailed = "EVIDENCE_STORAGE_FAILED"
}

protocol SparkQualificationExecuting: Sendable {
    func identity(target: SparkInferenceTestTarget) async throws -> SparkQualificationIdentity
    func request(
        target: SparkInferenceTestTarget,
        workload: SparkQualificationWorkload,
        runStarted: TimeInterval
    ) async throws -> SparkQualificationRequestMeasurement
    func sample(target: SparkInferenceTestTarget, elapsed: Double) async throws
        -> SparkQualificationMemorySample
}

struct PinnedSparkQualificationExecutor: SparkQualificationExecuting {
    private func api(_ target: SparkInferenceTestTarget) async throws -> SparkAPIClient {
        let signer = try DeviceIdentityStore.loadOrCreateSigner(nodeID: target.chat.nodeID.rawValue)
        let api = try SparkAPIClient.pinned(to: target.chat.tlsFingerprint, signer: signer)
        let identity = try await api.identity(route: target.chat.route)
        guard identity.nodeID == target.chat.nodeID, identity.clusterID == nil,
            identity.authorityFingerprint == target.chat.authorityFingerprint
        else { throw SparkQualificationError.identityChanged }
        return api
    }

    func identity(target: SparkInferenceTestTarget) async throws -> SparkQualificationIdentity {
        let api = try await api(target)
        try await Self.requireHistoryRecording {
            try await api.inferenceRequestHistory(route: target.chat.route, limit: 1)
        }
        let identity = try await api.identity(route: target.chat.route)
        let active = try await api.activeInference(route: target.chat.route)
        do { try target.validate(active) } catch { throw SparkQualificationError.deploymentChanged }
        guard let profileID = target.profileID else {
            throw SparkQualificationError.provenanceUnavailable
        }
        let inventory = try await api.models(route: target.chat.route)
        guard
            let profile = inventory.items.first(where: { $0.id == target.chat.modelID })?.profiles
                .first(where: { $0.id == profileID }),
            profile.safe, profile.maxModelLength >= 4096, profile.maxSequences >= 2
        else { throw SparkQualificationError.unsupportedProfile }
        // Request only a consequence preview; this executor cannot apply changes and does not retain its authorisation digest.
        let preview = try await api.previewLoadModel(
            route: target.chat.route,
            request: .init(
                modelId: target.chat.modelID,
                profileId: profileID,
                replaceActive: false
            ),
            idempotencyKey: UUID()
        )
        guard UUID(uuidString: preview.target.nodeId) == target.chat.nodeID.rawValue,
            let engine = preview.evidence.activeEngine,
            engine.modelId == target.chat.modelID, engine.profileId == profileID,
            ["ready", "idle"].contains(engine.state), !preview.evidence.engineTransitioning
        else { throw SparkQualificationError.deploymentChanged }
        return SparkQualificationIdentity(
            modelID: engine.modelId,
            profileID: engine.profileId,
            recipeDigest: engine.recipeDigest,
            recipeRevision: engine.recipeRevision,
            sourceRevision: engine.sourceRevision,
            runtimeVersion: identity.runtimeVersion,
            contextLimit: profile.maxModelLength,
            sequenceLimit: profile.maxSequences,
            systemReserveBytes: preview.evidence.systemReserveBytes.map(Int64.init),
            deployment: nil
        )
    }

    static func requireHistoryRecording(
        _ load: @Sendable () async throws -> SparkInferenceRequestHistory
    ) async throws {
        do {
            guard try await load().recording else {
                throw SparkQualificationError.provenanceUnavailable
            }
        } catch is CancellationError { throw CancellationError() } catch {
            throw SparkQualificationError.provenanceUnavailable
        }
    }

    func sample(target: SparkInferenceTestTarget, elapsed: Double) async throws
        -> SparkQualificationMemorySample
    {
        let observedFrom = ProcessInfo.processInfo.systemUptime
        let api = try await api(target)
        let sample = try await api.telemetry(route: target.chat.route)
        guard sample.nodeID == target.chat.nodeID, sample.inference.modelID == target.chat.modelID,
            sample.inference.profileID == target.profileID,
            ["ready", "idle"].contains(sample.inference.state),
            abs(sample.observedAt.timeIntervalSinceNow) <= 10
        else { throw SparkQualificationError.deploymentChanged }
        let engine = sample.engines.first {
            $0.ownership == "spark_managed" && ["live", "cached"].contains($0.availability)
                && ($0.sampleAgeSeconds ?? 100) <= 3
        }
        let readDuration = max(0, ProcessInfo.processInfo.systemUptime - observedFrom)
        let received = elapsed + readDuration
        let engineAge = engine?.sampleAgeSeconds.flatMap { age in
            age >= 0 && age <= 3 ? Double(age) : nil
        }
        return SparkQualificationMemorySample(
            elapsedSeconds: received,
            availableBytes: sample.system.unifiedMemoryAvailableBytes,
            memoryPressure: ["normal", "warning", "critical", "emergency"].contains(
                sample.system.memoryPressure
            ) ? sample.system.memoryPressure : "unknown",
            proxyActiveRequests: sample.inference.activeRequests,
            observedEngineRunning: engine?.runningRequests.flatMap(Int.init(exactly:)),
            engineSampleEarliestSeconds: engineAge.map { received - $0 - 1 - readDuration },
            engineSampleLatestSeconds: engineAge.map { received - $0 },
            observationStartedSeconds: elapsed
        )
    }

    func request(
        target: SparkInferenceTestTarget,
        workload: SparkQualificationWorkload,
        runStarted: TimeInterval
    ) async throws -> SparkQualificationRequestMeasurement {
        try await withThrowingTaskGroup(of: SparkQualificationRequestMeasurement.self) { group in
            group.addTask {
                try await self.stream(target: target, workload: workload, runStarted: runStarted)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(60))
                throw SparkQualificationError.requestTimedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func stream(
        target: SparkInferenceTestTarget,
        workload: SparkQualificationWorkload,
        runStarted: TimeInterval
    ) async throws -> SparkQualificationRequestMeasurement {
        let started = ProcessInfo.processInfo.systemUptime
        try await SparkInferenceTestTarget.checkCurrentModel(target)
        let signer = try DeviceIdentityStore.loadOrCreateSigner(nodeID: target.chat.nodeID.rawValue)
        let client = try ChatClient(
            baseURL: target.chat.route,
            pin: target.chat.tlsFingerprint,
            signer: signer
        )
        let tracker = SparkInferenceAttemptTracker()
        let request = ChatCompletionRequest(
            model: target.chat.modelID,
            messages: [ChatMessage(content: workload.prompt)],
            stream: true,
            maxTokens: workload.outputLimit,
            streamOptionsIncludeUsage: true
        )
        guard try JSONEncoder().encode(request).count <= 64 * 1024 else {
            throw SparkQualificationError.responseInvalid
        }
        let stream = try await client.stream(request, onRuntimeAttempt: { tracker.set($0) })
        var accumulator = SparkQualificationResponseAccumulator()
        for try await event in stream {
            try Task.checkCancellation()
            try accumulator.receive(event, elapsed: ProcessInfo.processInfo.systemUptime - started)
            if accumulator.completed { break }
        }
        try accumulator.validateTerminal()
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        try await SparkInferenceTestTarget.checkCurrentModel(target)
        let attempt = tracker.get()
        let record = try await attempt.asyncMap { try await target.runtimeRecord(attemptID: $0) }
        guard let deployment = record?.provenance else {
            throw SparkQualificationError.provenanceUnavailable
        }
        return SparkQualificationRequestMeasurement(
            workload: workload,
            startedSeconds: max(0, started - runStarted),
            elapsedSeconds: elapsed,
            firstOutputSeconds: accumulator.firstOutput,
            promptTokens: accumulator.usage?.prompt,
            completionTokens: accumulator.usage?.completion,
            exactAnswerMatched: accumulator.exactAnswerMatched(workload),
            terminalConfirmed: accumulator.completed,
            outputReceived: accumulator.outputReceived,
            runtimeAttemptID: attempt,
            deployment: deployment,
            finishReason: accumulator.finishReason
        )
    }
}

extension Optional where Wrapped: Sendable {
    fileprivate func asyncMap<T: Sendable>(_ transform: (Wrapped) async throws -> T?) async rethrows
        -> T?
    {
        guard let value = self else { return nil }
        return try await transform(value)
    }
}

/// Shared by the actual pinned executor and parser tests; text stays ephemeral.
struct SparkQualificationResponseAccumulator {
    private var answer = ""
    private var outputBytes = 0
    private(set) var firstOutput: Double?
    private(set) var usage: SparkInferenceTestUsage?
    private(set) var completed = false
    private(set) var outputReceived = false
    private(set) var finishReason: String?

    mutating func receive(_ event: ChatStreamEvent, elapsed: Double) throws {
        switch event {
        case .chunk(_, _, let delta, let thought, let finish):
            let bytes = (delta?.utf8.count ?? 0) + (thought?.utf8.count ?? 0)
            outputBytes += bytes
            guard outputBytes <= 16_384 else { throw SparkQualificationError.responseInvalid }
            if bytes > 0 {
                outputReceived = true
                firstOutput = firstOutput ?? elapsed
            }
            answer += delta ?? ""
            if let finish {
                guard ["stop", "length"].contains(finish),
                    finishReason == nil || finishReason == finish
                else { throw SparkQualificationError.responseInvalid }
                finishReason = finish
            }
        case .sources: break
        case .usage(let prompt, let completion, let total):
            usage = SparkInferenceTestUsage(prompt: prompt, completion: completion, total: total)
        case .done: completed = true
        }
    }
    func validateTerminal() throws {
        guard completed, outputReceived || finishReason == "length" else {
            throw SparkQualificationError.responseInvalid
        }
    }
    func exactAnswerMatched(_ workload: SparkQualificationWorkload) -> Bool? {
        guard completed, finishReason == "stop", let expected = workload.expectedAnswer else {
            return nil
        }
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return nil }
        return answer == expected
    }
}
