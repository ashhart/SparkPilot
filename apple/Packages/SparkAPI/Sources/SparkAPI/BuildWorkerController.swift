import Foundation
import SparkSecurity

public enum BuildWorkerPhase: String, Codable, Sendable, Equatable {
    case disabled
    case registering
    case online
    case busy
    case offline
    case revoked
    case failed
}

public struct BuildWorkerSnapshot: Sendable, Equatable {
    public let phase: BuildWorkerPhase
    public let workerID: UUID
    public let activeBuildID: String?
    public let lastResult: GeneratedAPI.BuildJob?
    public let message: String?
    public let updatedAt: Date
}

public protocol BuildWorkerCheckpointStoring: Sendable {
    func load(nodeID: String) throws -> GeneratedAPI.BuildClaim?
    func save(_ claim: GeneratedAPI.BuildClaim, nodeID: String) throws
    func clear(nodeID: String) throws
}

public struct KeychainBuildWorkerCheckpointStore: BuildWorkerCheckpointStoring {
    public static let service = "app.spark.build-worker-checkpoint"
    private let store: any SecureStore

    public init(store: any SecureStore = KeychainStore()) {
        self.store = store
    }

    public func load(nodeID: String) throws -> GeneratedAPI.BuildClaim? {
        guard let data = try store.data(service: Self.service, account: nodeID) else { return nil }
        return try JSONDecoder().decode(GeneratedAPI.BuildClaim.self, from: data)
    }

    public func save(_ claim: GeneratedAPI.BuildClaim, nodeID: String) throws {
        try store.set(try CanonicalBuildJSON.encode(claim), service: Self.service, account: nodeID)
    }

    public func clear(nodeID: String) throws {
        try store.delete(service: Self.service, account: nodeID)
    }
}

public actor BuildWorkerController {
    public typealias SnapshotHandler = @MainActor @Sendable (BuildWorkerSnapshot) -> Void

    private let nodeID: String
    private let workerID: UUID
    private let client: any BuildWorkerNetworking
    private let trust: BuildWorkerTrust
    private let capabilities: BuildWorkerCapabilities
    private let sourceFetcher: any BuildSourceFetching
    private let executor: any TypedBuildExecuting
    private let evidenceSigner: BuildEvidenceSigner
    private let checkpointStore: any BuildWorkerCheckpointStoring
    private let workspaceRoot: URL
    private let now: @Sendable () -> Date
    private let snapshotHandler: SnapshotHandler?
    private let runsContinuously: Bool
    private var enabled = false
    private var loopTask: Task<Void, Never>?
    private var snapshot: BuildWorkerSnapshot

    public init(
        nodeID: String,
        workerID: UUID,
        client: any BuildWorkerNetworking,
        trust: BuildWorkerTrust,
        capabilities: BuildWorkerCapabilities,
        sourceFetcher: any BuildSourceFetching,
        executor: any TypedBuildExecuting,
        evidenceSigner: BuildEvidenceSigner,
        checkpointStore: any BuildWorkerCheckpointStoring = KeychainBuildWorkerCheckpointStore(),
        workspaceRoot: URL,
        runsContinuously: Bool = true,
        now: @escaping @Sendable () -> Date = Date.init,
        snapshotHandler: SnapshotHandler? = nil
    ) {
        self.nodeID = nodeID
        self.workerID = workerID
        self.client = client
        self.trust = trust
        self.capabilities = capabilities
        self.sourceFetcher = sourceFetcher
        self.executor = executor
        self.evidenceSigner = evidenceSigner
        self.checkpointStore = checkpointStore
        self.workspaceRoot = workspaceRoot
        self.runsContinuously = runsContinuously
        self.now = now
        self.snapshotHandler = snapshotHandler
        self.snapshot = BuildWorkerSnapshot(
            phase: .disabled,
            workerID: workerID,
            activeBuildID: nil,
            lastResult: nil,
            message: nil,
            updatedAt: now()
        )
    }

    deinit { loopTask?.cancel() }

    public func currentSnapshot() -> BuildWorkerSnapshot { snapshot }

    public func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        loopTask?.cancel()
        loopTask = nil
        if enabled && runsContinuously {
            loopTask = Task { [weak self] in await self?.runLoop() }
        } else {
            publish(.disabled, buildID: nil, message: nil)
        }
    }

    public func runOneCycle() async {
        guard enabled else {
            publish(.disabled, buildID: nil, message: nil)
            return
        }
        do {
            try await register()
            if let saved = try checkpointStore.load(nodeID: nodeID) {
                do {
                    try await process(saved)
                    return
                } catch BuildRecipeVerificationError.expired,
                    BuildRecipeVerificationError.leaseInvalid
                {
                    try checkpointStore.clear(nodeID: nodeID)
                    publish(
                        .online,
                        buildID: nil,
                        message: String(
                            localized: "The previous lease ended; its job returned to the queue."
                        )
                    )
                } catch BuildClientError.http(let status) where status == 404 || status == 409 {
                    try checkpointStore.clear(nodeID: nodeID)
                    publish(
                        .online,
                        buildID: nil,
                        message: String(
                            localized: "The previous lease ended; its job returned to the queue."
                        )
                    )
                }
            }
            _ = try await client.heartbeat(workerID: workerID, idempotencyKey: UUID())
            if let claim = try await client.claim(workerID: workerID, idempotencyKey: UUID()) {
                try await process(claim)
            } else {
                publish(.online, buildID: nil, message: nil)
            }
        } catch BuildClientError.http(let status) where status == 401 || status == 403 {
            publish(
                .revoked,
                buildID: snapshot.activeBuildID,
                message: String(localized: "Worker access was revoked.")
            )
            enabled = false
        } catch is BuildRecipeVerificationError {
            try? checkpointStore.clear(nodeID: nodeID)
            publish(
                .failed,
                buildID: snapshot.activeBuildID,
                message: String(localized: "A build recipe failed verification.")
            )
            enabled = false
        } catch is CancellationError {
            if enabled {
                publish(
                    .offline,
                    buildID: snapshot.activeBuildID,
                    message: String(localized: "Build stopped.")
                )
            }
        } catch {
            publish(.offline, buildID: snapshot.activeBuildID, message: "\(error)")
        }
    }

    private func runLoop() async {
        while enabled && !Task.isCancelled {
            await runOneCycle()
            guard enabled && !Task.isCancelled else { return }
            try? await Task.sleep(for: .seconds(10))
        }
    }

    private func register() async throws {
        publish(.registering, buildID: nil, message: nil)
        try await client.register(
            .init(workerID: workerID.uuidString.lowercased(), capabilities: capabilities),
            idempotencyKey: UUID()
        )
    }

    private func process(_ claim: GeneratedAPI.BuildClaim) async throws {
        let payload = try BuildRecipeVerifier.verify(claim, trust: trust, now: now())
        publish(.busy, buildID: payload.buildId, message: String(localized: "Preparing source"))
        try checkpointStore.save(claim, nodeID: nodeID)
        let jobRoot = workspaceRoot.appendingPathComponent(payload.buildId, isDirectory: true)
        if FileManager.default.fileExists(atPath: jobRoot.path) {
            try FileManager.default.removeItem(at: jobRoot)
        }
        try FileManager.default.createDirectory(at: jobRoot, withIntermediateDirectories: true)
        let job: GeneratedAPI.BuildJob
        do {
            job = try await runWithLease(claim: claim, payload: payload, jobRoot: jobRoot)
            try FileManager.default.removeItem(at: jobRoot)
        } catch {
            if FileManager.default.fileExists(atPath: jobRoot.path) {
                try FileManager.default.removeItem(at: jobRoot)
            }
            throw error
        }
        try checkpointStore.clear(nodeID: nodeID)
        snapshot = BuildWorkerSnapshot(
            phase: .online,
            workerID: workerID,
            activeBuildID: nil,
            lastResult: job,
            message: nil,
            updatedAt: now()
        )
        emit()
    }

    private func performAndReport(
        claim: GeneratedAPI.BuildClaim,
        payload: GeneratedAPI.BuildRecipePayload,
        jobRoot: URL,
        startedAt: Date
    ) async throws -> GeneratedAPI.BuildJob {
        let outcome: BuildExecutionOutcome
        do {
            let source = try await sourceFetcher.fetch(ticket: payload.sourceTicket, into: jobRoot)
            publish(.busy, buildID: payload.buildId, message: String(localized: "Building"))
            outcome = try await executor.execute(recipe: payload, sourceDirectory: source)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as BuildClientError {
            throw error
        } catch {
            outcome = BuildExecutionOutcome(
                exitState: .failed,
                output: String(localized: "The fixed build process stopped before completion."),
                diagnostics: [
                    .init(
                        severity: .error,
                        message: String(localized: "Source preparation or Xcode execution failed.")
                    )
                ]
            )
        }
        var uploaded: [GeneratedAPI.BuildArtifactEvidence] = []
        var total = 0
        for artifact in outcome.artifacts.prefix(payload.artifactTicket.maxFiles) {
            total += artifact.bytes.count
            guard artifact.bytes.count <= payload.artifactTicket.maxFileBytes,
                total <= payload.artifactTicket.maxTotalBytes
            else { throw BuildWorkerExecutionError.sourceTooLarge }
            try await client.upload(
                buildID: payload.buildId,
                claimToken: claim.lease.claimToken,
                artifactToken: claim.lease.artifactToken,
                evidence: artifact.evidence,
                bytes: artifact.bytes,
                idempotencyKey: UUID()
            )
            uploaded.append(artifact.evidence)
        }
        let output = BuildOutputRedactor.boundedUTF8(outcome.output, limit: 1024 * 1024)
        let evidence = GeneratedAPI.BuildResultEvidence(
            protocol: "SPARK-BUILD-1",
            buildId: payload.buildId,
            workerId: payload.workerId,
            claimGeneration: payload.claimGeneration,
            projectId: payload.projectId,
            commit: payload.commit,
            sourceSha256: payload.sourceSha256,
            recipeSha256: claim.recipeSha256,
            exitState: outcome.exitState,
            startedAt: Self.timestamp(startedAt),
            completedAt: Self.timestamp(now()),
            output: output,
            outputSha256: SHA256Digest.hex(Data(output.utf8)),
            testFailures: outcome.testFailures,
            diagnostics: outcome.diagnostics,
            artifacts: uploaded
        )
        let result = try evidenceSigner.sign(evidence)
        return try await client.report(
            buildID: payload.buildId,
            claimToken: claim.lease.claimToken,
            result: result,
            idempotencyKey: UUID()
        )
    }

    private enum WorkEvent: Sendable {
        case completed(GeneratedAPI.BuildJob)
        case cancellationRequested
    }

    private func runWithLease(
        claim: GeneratedAPI.BuildClaim,
        payload: GeneratedAPI.BuildRecipePayload,
        jobRoot: URL
    ) async throws -> GeneratedAPI.BuildJob {
        let startedAt = now()
        return try await withThrowingTaskGroup(of: WorkEvent.self) { group in
            group.addTask { [weak self] in
                guard let self else { throw CancellationError() }
                return .completed(
                    try await self.performAndReport(
                        claim: claim,
                        payload: payload,
                        jobRoot: jobRoot,
                        startedAt: startedAt
                    )
                )
            }
            group.addTask { [client] in
                let seconds = max(5, claim.lease.heartbeatSeconds)
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(seconds))
                    let renewal = try await client.renew(
                        buildID: payload.buildId,
                        claimToken: claim.lease.claimToken,
                        idempotencyKey: UUID()
                    )
                    if renewal.cancelRequested { return .cancellationRequested }
                }
                throw CancellationError()
            }
            guard let first = try await group.next() else { throw CancellationError() }
            group.cancelAll()
            switch first {
            case .completed(let job): return job
            case .cancellationRequested:
                // Refresh the accepted claim immediately before signing and reporting cancellation.
                _ = try await client.renew(
                    buildID: payload.buildId,
                    claimToken: claim.lease.claimToken,
                    idempotencyKey: UUID()
                )
                let output = String(localized: "Build cancelled")
                let evidence = GeneratedAPI.BuildResultEvidence(
                    protocol: "SPARK-BUILD-1",
                    buildId: payload.buildId,
                    workerId: payload.workerId,
                    claimGeneration: payload.claimGeneration,
                    projectId: payload.projectId,
                    commit: payload.commit,
                    sourceSha256: payload.sourceSha256,
                    recipeSha256: claim.recipeSha256,
                    exitState: .cancelled,
                    startedAt: Self.timestamp(startedAt),
                    completedAt: Self.timestamp(now()),
                    output: output,
                    outputSha256: SHA256Digest.hex(Data(output.utf8)),
                    testFailures: [],
                    diagnostics: [],
                    artifacts: []
                )
                return try await client.report(
                    buildID: payload.buildId,
                    claimToken: claim.lease.claimToken,
                    result: evidenceSigner.sign(evidence),
                    idempotencyKey: UUID()
                )
            }
        }
    }

    private func publish(_ phase: BuildWorkerPhase, buildID: String?, message: String?) {
        snapshot = BuildWorkerSnapshot(
            phase: phase,
            workerID: workerID,
            activeBuildID: buildID,
            lastResult: snapshot.lastResult,
            message: message,
            updatedAt: now()
        )
        emit()
    }

    private func emit() {
        guard let snapshotHandler else { return }
        let value = snapshot
        Task { @MainActor in snapshotHandler(value) }
    }

    private nonisolated static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

public enum BuildWorkerIdentityStore {
    public static let workerPrefix = "spark.build-worker."

    public static func identityKey(nodeID: String) -> String {
        workerPrefix + nodeID + ".id"
    }

    public static func enabledKey(nodeID: String) -> String {
        workerPrefix + nodeID + ".enabled"
    }

    public static func loadOrCreate(
        nodeID: String,
        defaults: UserDefaults = .standard
    ) -> UUID {
        let key = identityKey(nodeID: nodeID)
        if let raw = defaults.string(forKey: key), let existing = UUID(uuidString: raw) {
            return existing
        }
        let worker = UUID()
        defaults.set(worker.uuidString.lowercased(), forKey: key)
        return worker
    }

    public static func enabled(nodeID: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey(nodeID: nodeID))
    }

    public static func setEnabled(
        _ enabled: Bool,
        nodeID: String,
        defaults: UserDefaults = .standard
    ) {
        defaults.set(enabled, forKey: enabledKey(nodeID: nodeID))
    }
}
