import Foundation
import Observation

@MainActor @Observable
final class SparkQualificationRunner {
    private static var activeRunIDs: Set<UUID> = []
    let target: SparkInferenceTestTarget
    private(set) var manifest: SparkQualificationManifest?
    private(set) var saved: [SparkQualificationManifest] = []
    private(set) var phase = "ready"
    private(set) var errorCode: String?
    @ObservationIgnored private let executor: any SparkQualificationExecuting
    @ObservationIgnored private let store: SparkQualificationStore
    @ObservationIgnored private let now: @Sendable () -> TimeInterval
    @ObservationIgnored private let pause: @Sendable (Double) async throws -> Void
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var sampler: Task<Void, Never>?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var activeID: UUID?
    @ObservationIgnored private var started: TimeInterval = 0
    @ObservationIgnored private var inFlight = 0
    @ObservationIgnored private var activeWindows: [SparkQualificationWorkload: Double] = [:]
    @ObservationIgnored private var reproduction: SparkQualificationManifest?
    @ObservationIgnored private var storageReadable = true

    var isRunning: Bool { activeID != nil }

    init(
        target: SparkInferenceTestTarget,
        executor: any SparkQualificationExecuting = PinnedSparkQualificationExecutor(),
        store: SparkQualificationStore = SparkQualificationStore(),
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        pause: @escaping @Sendable (Double) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.target = target
        self.executor = executor
        self.store = store
        self.now = now
        self.pause = pause
        do { saved = try store.load(activeIDs: Self.activeRunIDs) } catch {
            storageReadable = false
            errorCode = "EVIDENCE_STORAGE_UNREADABLE"
        }
    }

    @discardableResult
    func start(reproducing previous: SparkQualificationManifest? = nil) -> Task<Void, Never>? {
        guard !isRunning, storageReadable else { return nil }
        if let previous {
            guard previous.isTerminal, previous.preset == .quick,
                previous.identity?.modelID == target.chat.modelID,
                previous.identity?.profileID == target.profileID,
                previous.identity?.deployment != nil
            else {
                errorCode = "REPRODUCTION_PROVENANCE_MISSING"
                return nil
            }
        }
        reproduction = previous
        manifest = .new(reproductionOf: previous?.id)
        let id = manifest!.id
        activeID = id
        Self.activeRunIDs.insert(id)
        started = now()
        inFlight = 0
        activeWindows = [:]
        phase = "checking"
        errorCode = nil
        guard persist() else { return nil }
        let task = Task { await run(id: id) }
        self.task = task
        deadline = Task {
            do {
                try await Task.sleep(
                    for: .seconds(SparkQualificationPreset.quick.maximumDurationSeconds)
                )
                guard activeID == id, !Task.isCancelled else { return }
                stop(code: SparkQualificationError.runTimedOut.rawValue, state: "failed")
            } catch {}
        }
        return task
    }

    func cancel(suspended: Bool = false) {
        guard isRunning else { return }
        stop(
            code: suspended
                ? "APP_SUSPENDED_OUTCOME_UNKNOWN" : "OWNER_CANCELLED_ENGINE_STOP_UNCONFIRMED",
            state: "cancelled"
        )
    }

    func clearFinished() {
        guard !isRunning, storageReadable else { return }
        do {
            try store.clearFinished(activeIDs: Self.activeRunIDs)
            saved = try store.load(activeIDs: Self.activeRunIDs)
            errorCode = nil
        } catch { errorCode = "EVIDENCE_CLEAR_FAILED" }
    }

    private func require(_ id: UUID) throws {
        try Task.checkCancellation()
        guard activeID == id else { throw CancellationError() }
    }

    @discardableResult private func persist() -> Bool {
        guard let manifest else { return false }
        do {
            try store.save(manifest)
            return true
        } catch {
            errorCode = SparkQualificationError.storageFailed.rawValue
            task?.cancel()
            sampler?.cancel()
            deadline?.cancel()
            if let activeID { Self.activeRunIDs.remove(activeID) }
            activeID = nil
            phase = "failed"
            return false
        }
    }

    private func stop(code: String, state: String) {
        guard activeID != nil else { return }
        if let activeID { Self.activeRunIDs.remove(activeID) }
        activeID = nil
        errorCode = code
        phase = state
        task?.cancel()
        sampler?.cancel()
        deadline?.cancel()
        manifest?.state = state
        manifest?.failureCode = code
        fillMissing(verdict: .interrupted, code: code)
        _ = persist()
        do { saved = try store.load(activeIDs: Self.activeRunIDs) } catch {
            errorCode = "EVIDENCE_STORAGE_UNREADABLE"
        }
    }

    private func fillMissing(verdict: SparkQualificationVerdict, code: String) {
        for kind in SparkQualificationCase.allCases
        where !(manifest?.cases.contains(where: { $0.kind == kind }) ?? false) {
            manifest?.cases.append(
                .init(
                    kind: kind,
                    verdict: verdict,
                    code: code,
                    sampleCount: 0,
                    value: nil,
                    secondaryValue: nil
                )
            )
        }
    }

    private func sameConfiguration(
        _ lhs: SparkQualificationIdentity,
        _ rhs: SparkQualificationIdentity
    ) -> Bool {
        var lhs = lhs, rhs = rhs
        lhs.deployment = nil
        rhs.deployment = nil
        return lhs == rhs
    }

    private func verify(id: UUID) async throws {
        let current = try await executor.identity(target: target)
        try require(id)
        guard let baseline = manifest?.identity, sameConfiguration(current, baseline) else {
            throw SparkQualificationError.deploymentChanged
        }
    }

    private func observe(id: UUID, requireIdle: Bool = false) async throws {
        let sample = try await executor.sample(target: target, elapsed: max(0, now() - started))
        try require(id)
        if (manifest?.memorySamples.count ?? 0) < 242 { manifest?.memorySamples.append(sample) }
        guard sample.availableBytes >= 0, sample.memoryPressure == "normal",
            manifest?.identity?.systemReserveBytes.map({ sample.availableBytes >= $0 }) ?? true
        else { throw SparkQualificationError.unsafeMemory }
        let proxyWindow = sample.observationStartedSeconds.flatMap {
            beginning -> ClosedRange<Double>? in
            beginning.isFinite && beginning <= sample.elapsedSeconds
                ? beginning...sample.elapsedSeconds : nil
        }
        let allowedProxyCount = requireIdle ? 0 : proxyWindow.map(maximumOwnedRequests) ?? inFlight
        guard sample.proxyActiveRequests <= allowedProxyCount else {
            throw SparkQualificationError.otherWork
        }
        if let observed = sample.observedEngineRunning, observed > 0 {
            guard let interval = Self.engineSampleInterval(sample),
                observed <= maximumOwnedRequests(in: interval)
            else { throw SparkQualificationError.otherWork }
        }
        guard persist() else { throw SparkQualificationError.storageFailed }
    }

    private func request(_ workload: SparkQualificationWorkload, id: UUID) async throws
        -> SparkQualificationRequestMeasurement
    {
        try require(id)
        inFlight += 1
        activeWindows[workload] = max(0, now() - started)
        defer {
            // A cancelled old task must not alter a subsequently started run.
            if activeID == id {
                inFlight -= 1
                activeWindows.removeValue(forKey: workload)
            }
        }
        let result = try await executor.request(
            target: target,
            workload: workload,
            runStarted: started
        )
        try require(id)
        guard result.workload == workload, result.terminalConfirmed,
            result.outputReceived || result.finishReason == "length",
            result.elapsedSeconds.isFinite, result.elapsedSeconds >= 0,
            result.startedSeconds.isFinite, result.startedSeconds >= 0,
            let evidence = result.deployment, let baseline = manifest?.identity,
            evidence.recipeDigest == baseline.recipeDigest,
            evidence.recipeRevision == baseline.recipeRevision,
            evidence.sourceRevision == baseline.sourceRevision,
            evidence.runtimeVersion == baseline.runtimeVersion,
            evidence.contextLength == UInt64(baseline.contextLimit),
            evidence.maxSequences == UInt32(baseline.sequenceLimit)
        else { throw SparkQualificationError.deploymentChanged }
        if let completion = result.completionTokens,
            completion < 0 || completion > workload.outputLimit
        {
            throw SparkQualificationError.responseInvalid
        }
        if let prompt = result.promptTokens, let completion = result.completionTokens,
            prompt < 0 || prompt > baseline.contextLimit - completion
        {
            throw SparkQualificationError.responseInvalid
        }
        if let previous = baseline.deployment, previous != evidence {
            throw SparkQualificationError.deploymentChanged
        }
        if let old = reproduction?.identity?.deployment, old != evidence {
            throw SparkQualificationError.deploymentChanged
        }
        manifest?.identity?.deployment = evidence
        guard (manifest?.requests.count ?? 0) < SparkQualificationPreset.quick.maximumRequests
        else { throw SparkQualificationError.responseInvalid }
        manifest?.requests.append(result)
        guard persist() else { throw SparkQualificationError.storageFailed }
        return result
    }

    private func record(
        _ kind: SparkQualificationCase,
        _ verdict: SparkQualificationVerdict,
        _ code: String,
        count: Int,
        value: Double? = nil,
        secondary: Double? = nil
    ) {
        manifest?.cases.removeAll { $0.kind == kind }
        manifest?.cases.append(
            .init(
                kind: kind,
                verdict: verdict,
                code: code,
                sampleCount: count,
                value: value,
                secondaryValue: secondary
            )
        )
    }

    private func run(id: UUID) async {
        defer {
            if activeID == id {
                Self.activeRunIDs.remove(id)
                activeID = nil
                task = nil
                sampler?.cancel()
                deadline?.cancel()
            }
        }
        do {
            let identity = try await executor.identity(target: target)
            try require(id)
            guard identity.modelID == target.chat.modelID, identity.profileID == target.profileID
            else { throw SparkQualificationError.identityChanged }
            if let old = reproduction?.identity, !sameConfiguration(identity, old) {
                throw SparkQualificationError.deploymentChanged
            }
            guard identity.contextLimit >= 4096, identity.sequenceLimit >= 2,
                identity.systemReserveBytes.map({ $0 >= 0 }) ?? true
            else { throw SparkQualificationError.unsupportedProfile }
            manifest?.identity = identity
            try await observe(id: id, requireIdle: true)
            sampler = Task {
                while activeID == id, !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .seconds(1))
                        try require(id)
                        try await observe(id: id)
                    } catch {
                        guard activeID == id, !Task.isCancelled else { return }
                        stop(
                            code: (error as? SparkQualificationError)?.rawValue
                                ?? "TELEMETRY_UNAVAILABLE",
                            state: "failed"
                        )
                        return
                    }
                }
            }
            phase = "correctness"
            let arithmetic = try await request(.arithmetic, id: id)
            let echo = try await request(.echo, id: id)
            let correct = arithmetic.exactAnswerMatched == true && echo.exactAnswerMatched == true
            let wrongCompletedAnswer =
                arithmetic.exactAnswerMatched == false || echo.exactAnswerMatched == false
            record(
                .correctness,
                correct ? .measured : (wrongCompletedAnswer ? .failed : .notDemonstrated),
                correct || wrongCompletedAnswer
                    ? "ONE_ARITHMETIC_AND_ONE_EXACT_ECHO_NOT_BROAD_QUALITY"
                    : "BUDGET_OR_ANSWER_COMPLETION_NOT_DEMONSTRATED",
                count: 2
            )
            guard !wrongCompletedAnswer else { throw SparkQualificationError.responseInvalid }
            try await verify(id: id)

            phase = "context"
            let context = try await request(.context, id: id)
            let inputCount = context.promptTokens
            let demonstrated =
                inputCount.map { $0 >= SparkQualificationPreset.quick.requestedPromptTokens }
                ?? false
            record(
                .context,
                demonstrated ? .measured : .notDemonstrated,
                "REPORTED_PROMPT_TOKENS_NOT_FULL_PROFILE_CONTEXT",
                count: 1,
                value: inputCount.map(Double.init),
                secondary: Double(SparkQualificationPreset.quick.requestedPromptTokens)
            )
            try await verify(id: id)

            phase = "latency"
            var timings: [Double] = []
            for workload in [SparkQualificationWorkload.latency1, .latency2, .latency3] {
                timings.append(try await request(workload, id: id).elapsedSeconds)
            }
            record(
                .latency,
                .measured,
                "CLIENT_TIMING_INCLUDES_READINESS_NO_SPEED_RANKING",
                count: timings.count,
                value: Self.percentile(timings, 0.5),
                secondary: Self.percentile(timings, 0.95)
            )
            try await verify(id: id)

            phase = "concurrency"
            async let one = request(.concurrent1, id: id)
            async let two = request(.concurrent2, id: id)
            let (first, second) = try await (one, two)
            let overlap = max(
                0,
                min(
                    first.startedSeconds + first.elapsedSeconds,
                    second.startedSeconds + second.elapsedSeconds
                ) - max(first.startedSeconds, second.startedSeconds)
            )
            let overlapStart = max(first.startedSeconds, second.startedSeconds)
            let overlapEnd = min(
                first.startedSeconds + first.elapsedSeconds,
                second.startedSeconds + second.elapsedSeconds
            )
            let observed = Self.observedConcurrency(
                manifest?.memorySamples ?? [],
                overlapStart: overlapStart,
                overlapEnd: overlapEnd
            )
            record(
                .concurrency,
                overlap > 0 && (observed ?? 0) >= 2 ? .measured : .notDemonstrated,
                "TWO_CLIENT_REQUESTS_ENGINE_ACTIVE_COUNT_SEPARATELY_SAMPLED",
                count: 2,
                value: observed.map(Double.init),
                secondary: overlap
            )
            try await verify(id: id)

            phase = "stability"
            let stabilityStart = now()
            _ = try await request(.stability1, id: id)
            try await pause(
                max(
                    0,
                    SparkQualificationPreset.quick.stabilitySpanSeconds / 2
                        - (now() - stabilityStart)
                )
            )
            _ = try await request(.stability2, id: id)
            try await pause(
                max(
                    0,
                    SparkQualificationPreset.quick.stabilitySpanSeconds - (now() - stabilityStart)
                )
            )
            _ = try await request(.stability3, id: id)
            record(
                .stability,
                now() - stabilityStart >= SparkQualificationPreset.quick.stabilitySpanSeconds
                    ? .measured : .notDemonstrated,
                "THREE_REQUESTS_OVER_STATED_SPAN_NOT_SUSTAINED_SOAK",
                count: 3,
                value: now() - stabilityStart
            )
            try await verify(id: id)
            try await observe(id: id, requireIdle: true)
            sampler?.cancel()
            let available = manifest?.memorySamples.map(\.availableBytes).min()
            let reserve = manifest?.identity?.systemReserveBytes
            let headroom = available.flatMap { available in reserve.map { available - $0 } }
            record(
                .memory,
                headroom != nil && (manifest?.memorySamples.count ?? 0) >= 2
                    ? .measured : .notDemonstrated,
                "SAMPLED_AVAILABLE_MINUS_SIGNED_RESERVE_NOT_PEAK_PROOF",
                count: manifest?.memorySamples.count ?? 0,
                value: available.map(Double.init),
                secondary: headroom.map(Double.init)
            )
            try require(id)
            manifest?.state = "completed_incomplete_qualification"
            fillMissing(verdict: .notDemonstrated, code: "NOT_MEASURED")
            phase = "completed"
            guard persist() else { throw SparkQualificationError.storageFailed }
            saved = try store.load(activeIDs: Self.activeRunIDs)
        } catch {
            guard activeID == id else { return }
            stop(
                code: (error as? SparkQualificationError)?.rawValue
                    ?? (error is CancellationError ? "CANCELLED" : "REQUEST_FAILED"),
                state: "failed"
            )
        }
    }

    static func engineSampleInterval(_ sample: SparkQualificationMemorySample) -> ClosedRange<
        Double
    >? {
        guard let earliest = sample.engineSampleEarliestSeconds,
            let latest = sample.engineSampleLatestSeconds,
            earliest.isFinite, latest.isFinite, earliest <= latest,
            latest <= sample.elapsedSeconds
        else { return nil }
        return earliest...latest
    }

    static func observedConcurrency(
        _ samples: [SparkQualificationMemorySample],
        overlapStart: Double,
        overlapEnd: Double
    ) -> Int? {
        guard overlapEnd > overlapStart else { return nil }
        return samples.compactMap { sample -> Int? in
            guard let interval = engineSampleInterval(sample),
                interval.lowerBound >= overlapStart, interval.upperBound < overlapEnd
            else { return nil }
            return sample.observedEngineRunning
        }.max()
    }

    private func maximumOwnedRequests(in interval: ClosedRange<Double>) -> Int {
        let windows =
            (manifest?.requests ?? []).map {
                ($0.startedSeconds, $0.startedSeconds + $0.elapsedSeconds)
            }
            + activeWindows.values.map { ($0, Double.infinity) }
        let points = [interval.lowerBound] + windows.map(\.0).filter { interval.contains($0) }
        return points.map { point in windows.filter { $0.0 <= point && $0.1 > point }.count }.max()
            ?? 0
    }

    static func percentile(_ values: [Double], _ quantile: Double) -> Double? {
        guard !values.isEmpty, values.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
        let sorted = values.sorted()
        let index = max(0, min(sorted.count - 1, Int(ceil(Double(sorted.count) * quantile)) - 1))
        return sorted[index]
    }
}
