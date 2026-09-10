import CryptoKit
import Foundation
import SparkSecurity
import Testing
@testable import SparkAPI
#if os(macOS)
    import Darwin
#endif

struct RecipeFixture {
    let claim: GeneratedAPI.BuildClaim
    let trust: BuildWorkerTrust

    init(
        workerID: UUID,
        now: Date,
        scheme: String = "SparkApp",
        heartbeatSeconds: Int = 60
    ) throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation
        let authorityPublicKey = publicKey.hex
        let authorityFingerprint = SHA256Digest.hex(publicKey)
        let issuedAt = Self.timestamp(now)
        let expiresAt = Self.timestamp(now.addingTimeInterval(600))
        let projectID = UUID().uuidString.lowercased()
        let commit = String(repeating: "a", count: 40)
        let source = String(repeating: "c", count: 64)
        let buildID = UUID().uuidString.lowercased()
        let payload = GeneratedAPI.BuildRecipePayload(
            protocol: "SPARK-BUILD-1",
            buildId: buildID,
            workerId: workerID.uuidString.lowercased(),
            claimGeneration: 1,
            projectId: projectID,
            commit: commit,
            sourceSha256: source,
            scheme: scheme,
            configuration: "Debug",
            destination: "platform=macOS",
            actions: [.build, .test],
            timeoutSeconds: 300,
            requirements: .init(
                platform: .macOS,
                architecture: "arm64",
                signingRequired: false
            ),
            sourceTicket: .init(
                ticketId: UUID().uuidString.lowercased(),
                repositoryUrl: "https://example.invalid/repository.git",
                commit: commit,
                sourceSha256: source,
                maxBytes: 100_000_000,
                expiresAt: expiresAt
            ),
            artifactTicket: .init(
                ticketId: UUID().uuidString.lowercased(),
                uploadPathTemplate: "/api/v1/builds/\(buildID)/artifacts/{artifactId}",
                maxFileBytes: 8 * 1024 * 1024,
                maxTotalBytes: 32 * 1024 * 1024,
                maxFiles: 16,
                expiresAt: expiresAt
            ),
            issuedAt: issuedAt,
            expiresAt: expiresAt
        )
        let signature = try key.signature(for: CanonicalBuildJSON.encode(payload))
        let recipe = GeneratedAPI.SignedBuildRecipe(
            payload: payload,
            authorityPublicKey: authorityPublicKey,
            authorityFingerprint: authorityFingerprint,
            signature: Base64URL.encode(signature)
        )
        claim = GeneratedAPI.BuildClaim(
            recipe: recipe,
            recipeSha256: SHA256Digest.hex(try CanonicalBuildJSON.encode(recipe)),
            lease: .init(
                claimToken: Base64URL.encode(Data(repeating: 1, count: 32)),
                artifactToken: Base64URL.encode(Data(repeating: 2, count: 32)),
                expiresAt: expiresAt,
                heartbeatSeconds: heartbeatSeconds
            )
        )
        trust = BuildWorkerTrust(
            authorityPublicKey: authorityPublicKey,
            authorityFingerprint: authorityFingerprint,
            workerID: workerID,
            allowedProjectIDs: [projectID]
        )
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

final class MemoryCheckpoint: BuildWorkerCheckpointStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var claim: GeneratedAPI.BuildClaim?

    init(claim: GeneratedAPI.BuildClaim? = nil) { self.claim = claim }

    var current: GeneratedAPI.BuildClaim? { lock.withLock { claim } }
    func load(nodeID _: String) throws -> GeneratedAPI.BuildClaim? { lock.withLock { claim } }
    func save(_ claim: GeneratedAPI.BuildClaim, nodeID _: String) throws {
        lock.withLock { self.claim = claim }
    }
    func clear(nodeID _: String) throws { lock.withLock { claim = nil } }
}

actor FakeBuildWorkerNetwork: BuildWorkerNetworking {
    private(set) var registerCount = 0
    private(set) var claimCount = 0
    private(set) var renewCount = 0
    private(set) var reportCount = 0
    var claimValue: GeneratedAPI.BuildClaim?
    var reportError: BuildClientError?
    var reportDelay: Duration?

    func setReportError(_ error: BuildClientError?) { reportError = error }
    func setReportDelay(_ delay: Duration?) { reportDelay = delay }

    func register(
        _: GeneratedAPI.BuildWorkerRegistration,
        idempotencyKey _: UUID
    ) async throws { registerCount += 1 }

    func heartbeat(workerID: UUID, idempotencyKey _: UUID) async throws
        -> GeneratedAPI.BuildWorkerHeartbeat
    {
        .init(
            workerId: workerID.uuidString.lowercased(),
            state: .online,
            activeJobs: 0,
            heartbeatSeconds: 30
        )
    }

    func claim(workerID _: UUID, idempotencyKey _: UUID) async throws
        -> GeneratedAPI.BuildClaim?
    {
        claimCount += 1
        return claimValue
    }

    func renew(buildID: String, claimToken _: String, idempotencyKey _: UUID) async throws
        -> GeneratedAPI.BuildLeaseRenewal
    {
        renewCount += 1
        return .init(
            buildId: buildID,
            workerId: UUID().uuidString,
            expiresAt: "2099-01-01T00:00:00Z",
            cancelRequested: false
        )
    }

    func upload(
        buildID _: String,
        claimToken _: String,
        artifactToken _: String,
        evidence _: GeneratedAPI.BuildArtifactEvidence,
        bytes _: Data,
        idempotencyKey _: UUID
    ) async throws {}

    func report(
        buildID: String,
        claimToken _: String,
        result: GeneratedAPI.SignedBuildResult,
        idempotencyKey _: UUID
    ) async throws -> GeneratedAPI.BuildJob {
        reportCount += 1
        if let reportDelay { try await Task.sleep(for: reportDelay) }
        if let reportError { throw reportError }
        return .init(
            buildId: buildID,
            projectId: result.evidence.projectId,
            workerId: result.evidence.workerId,
            commit: result.evidence.commit,
            sourceSha256: result.evidence.sourceSha256,
            status: .completed,
            result: result,
            createdAt: result.evidence.startedAt,
            updatedAt: result.evidence.completedAt
        )
    }
}

struct FakeSourceFetcher: BuildSourceFetching {
    func fetch(ticket _: GeneratedAPI.BuildSourceTicket, into directory: URL) async throws -> URL {
        let source = directory.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        return source
    }
}

struct FakeExecutor: TypedBuildExecuting {
    func execute(
        recipe _: GeneratedAPI.BuildRecipePayload,
        sourceDirectory _: URL
    ) async throws -> BuildExecutionOutcome {
        .init(exitState: .succeeded, output: "Build succeeded")
    }
}
