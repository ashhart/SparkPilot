import CryptoKit
import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing
@testable import SparkAppComposition

@MainActor
@Test func iPadAndMacBuildJourneyPersistsAndRecoversBuildProgress() async throws {
    let nodeID = SparkNodeID(rawValue: UUID())
    let library = SparkLibrary(store: MemoryLibraryStore())
    library.reconcile(
        AuthenticatedTarget(
            nodeID: nodeID,
            clusterID: nil,
            name: "Build Spark",
            role: .standalone,
            authorityFingerprint: String(repeating: "b", count: 64),
            displayName: "build-spark",
            routes: [
                CachedRoute(
                    baseURL: URL(string: "https://192.168.1.80:7443")!,
                    kind: .localWiFi,
                    lastSuccess: .now
                )
            ],
            reachedAt: .now
        )
    )
    let authority = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
    let store = InMemoryStore()
    let trustStore = NodeTrustStore(store: store)
    try trustStore.remember(
        NodeTrust(
            nodeID: nodeID.rawValue.uuidString.lowercased(),
            nodeName: "Build Spark",
            tlsFingerprint: String(repeating: "a", count: 64),
            authorityFingerprint: SHA256Digest.hex(authority),
            authorityPublicKey: authority.hex,
            pairedAt: .now,
            localDeviceRole: "developer"
        )
    )
    let client = FakeBuildProjectClient()
    let suiteName = "BuildProjectModelTests.\(UUID())"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let model = BuildProjectModel(
        library: library,
        clients: FakeBuildClientFactory(client: client),
        trustStore: trustStore,
        defaults: defaults
    )

    await model.refreshProjects()
    #expect(model.projects.map(\.name) == ["SparkPilot"])
    model.commit = String(repeating: "a", count: 40)
    model.sourceSHA256 = String(repeating: "b", count: 64)
    #expect(model.canSubmit)
    await model.submit()
    #expect(model.builds.first?.status == "queued")

    let relaunched = BuildProjectModel(
        library: library,
        clients: FakeBuildClientFactory(client: client),
        trustStore: trustStore,
        defaults: defaults
    )
    let expectedBuildID = client.buildID
    #expect(relaunched.builds.first?.id == expectedBuildID)
    await relaunched.refreshProjects()
    #expect(relaunched.builds.first?.status == "completed")

    let screenshot = SavedBuildArtifact(
        artifactID: client.artifactID,
        relativePath: "screenshots/result.png",
        sha256: client.artifactDigest
    )
    #expect(
        try await relaunched.screenshotData(
            build: try #require(relaunched.builds.first),
            artifact: screenshot
        )
            == client.artifactBytes
    )
    #expect(await client.lastArtifactRequest == "\(expectedBuildID)/\(client.artifactID)")
}

@Test func legacyScreenshotLabelsRemainReadableButCannotMasqueradeAsDownloadEvidence() throws {
    let data = Data(
        #"{"id":"build","targetID":"target","projectName":"App","status":"completed","updatedAt":"2026-09-01T12:00:00Z","diagnostics":[],"screenshots":["old.png"]}"#
            .utf8
    )
    let saved = try JSONDecoder().decode(SavedBuild.self, from: data)
    #expect(
        saved.screenshots == [
            SavedBuildArtifact(artifactID: "", relativePath: "old.png", sha256: "")
        ]
    )
}

private struct FakeBuildClientFactory: BuildClientCreating {
    let client: FakeBuildProjectClient

    @MainActor
    func client(for _: BuildTarget) throws -> any BuildProjectNetworking { client }
}

private actor FakeBuildProjectClient: BuildProjectNetworking {
    let projectID = UUID().uuidString.lowercased()
    let buildID = UUID().uuidString.lowercased()
    nonisolated let artifactID = UUID().uuidString.lowercased()
    nonisolated let artifactBytes = Data("verified screenshot".utf8)
    nonisolated var artifactDigest: String { SHA256Digest.hex(artifactBytes) }
    private(set) var lastArtifactRequest: String?

    func projects() async throws -> [GeneratedAPI.Project] {
        [
            .init(
                id: projectID,
                name: "SparkPilot",
                state: .ready,
                repositoryUrl: "https://example.invalid/sparkpilot.git",
                defaultBranch: "main",
                capabilities: [.read],
                createdAt: "2026-09-01T12:00:00Z",
                updatedAt: "2026-09-01T12:00:00Z"
            )
        ]
    }

    func submitTracked(
        _: GeneratedAPI.BuildJobRequest,
        idempotencyKey _: UUID
    ) async throws -> BuildClient.Submission {
        .init(operationID: UUID().uuidString.lowercased(), buildID: buildID)
    }

    func job(buildID: String) async throws -> GeneratedAPI.BuildJob {
        .init(
            buildId: buildID,
            projectId: projectID,
            commit: String(repeating: "a", count: 40),
            sourceSha256: String(repeating: "b", count: 64),
            status: .completed,
            createdAt: "2026-09-01T12:00:00Z",
            updatedAt: "2026-09-01T12:01:00Z"
        )
    }

    func artifact(
        buildID: String,
        artifactID: String,
        expectedSHA256: String
    ) async throws -> Data {
        guard artifactID == self.artifactID, expectedSHA256 == artifactDigest else {
            throw BuildClientError.artifactDigestMismatch
        }
        lastArtifactRequest = "\(buildID)/\(artifactID)"
        return artifactBytes
    }
}

extension Data {
    fileprivate var hex: String { map { String(format: "%02x", $0) }.joined() }
}
