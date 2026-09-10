import CryptoKit
import Foundation
import SparkSecurity
import Testing
@testable import SparkAPI
#if os(macOS)
    import Darwin
#endif

@Suite("Outbound Mac build worker")
struct BuildWorkerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func recipeVerificationBindsEveryAuthorityControlledField() throws {
        let workerID = UUID()
        let fixture = try RecipeFixture(workerID: workerID, now: now)

        let verified = try BuildRecipeVerifier.verify(fixture.claim, trust: fixture.trust, now: now)
        #expect(verified.commit == String(repeating: "a", count: 40))

        var wrongWorker = fixture.trust
        wrongWorker = BuildWorkerTrust(
            authorityPublicKey: wrongWorker.authorityPublicKey,
            authorityFingerprint: wrongWorker.authorityFingerprint,
            workerID: UUID(),
            allowedProjectIDs: wrongWorker.allowedProjectIDs
        )
        #expect(throws: BuildRecipeVerificationError.workerMismatch) {
            try BuildRecipeVerifier.verify(fixture.claim, trust: wrongWorker, now: now)
        }
        #expect(throws: BuildRecipeVerificationError.expired) {
            try BuildRecipeVerifier.verify(
                fixture.claim,
                trust: fixture.trust,
                now: now.addingTimeInterval(601)
            )
        }

        var tampered = fixture.claim
        tampered.recipe.payload.sourceSha256 = String(repeating: "b", count: 64)
        #expect(throws: BuildRecipeVerificationError.signatureInvalid) {
            try BuildRecipeVerifier.verify(tampered, trust: fixture.trust, now: now)
        }
    }

    @Test func stableWorkerIdentitySurvivesRelaunchAndIsScopedToNode() throws {
        let suite = try #require(UserDefaults(suiteName: "BuildWorkerTests.\(UUID())"))
        defer { suite.removePersistentDomain(forName: suite.volatileDomainNames.first ?? "") }
        let first = BuildWorkerIdentityStore.loadOrCreate(nodeID: "node-a", defaults: suite)
        let second = BuildWorkerIdentityStore.loadOrCreate(nodeID: "node-a", defaults: suite)
        let other = BuildWorkerIdentityStore.loadOrCreate(nodeID: "node-b", defaults: suite)
        #expect(first == second)
        #expect(first != other)
        #expect(BuildWorkerIdentityStore.enabled(nodeID: "node-a", defaults: suite) == false)
        BuildWorkerIdentityStore.setEnabled(true, nodeID: "node-a", defaults: suite)
        #expect(BuildWorkerIdentityStore.enabled(nodeID: "node-a", defaults: suite))
    }

    @Test func disabledWorkerNeverRegistersOrClaims() async throws {
        let network = FakeBuildWorkerNetwork()
        let controller = try makeController(network: network, savedClaim: nil)
        await controller.runOneCycle()
        #expect(await network.registerCount == 0)
        #expect(await controller.currentSnapshot().phase == .disabled)
    }

    @Test func relaunchResumesSavedLeaseWithoutClaimingAnotherJob() async throws {
        let workerID = UUID()
        let fixture = try RecipeFixture(workerID: workerID, now: now)
        let network = FakeBuildWorkerNetwork()
        let checkpoint = MemoryCheckpoint(claim: fixture.claim)
        let controller = try makeController(
            workerID: workerID,
            network: network,
            fixture: fixture,
            savedClaim: checkpoint
        )
        await controller.setEnabled(true)
        await controller.runOneCycle()

        #expect(await network.registerCount == 1)
        #expect(await network.claimCount == 0)
        #expect(await network.reportCount == 1)
        #expect(checkpoint.current == nil)
        #expect(await controller.currentSnapshot().phase == .online)
    }

    @Test func expiredSavedLeaseIsClearedSoTheRequeuedJobCanBeClaimedAgain() async throws {
        let workerID = UUID()
        let fixture = try RecipeFixture(
            workerID: workerID,
            now: now.addingTimeInterval(-601)
        )
        let network = FakeBuildWorkerNetwork()
        let checkpoint = MemoryCheckpoint(claim: fixture.claim)
        let controller = try makeController(
            workerID: workerID,
            network: network,
            fixture: fixture,
            savedClaim: checkpoint
        )
        await controller.setEnabled(true)
        await controller.runOneCycle()

        #expect(checkpoint.current == nil)
        #expect(await network.claimCount == 1)
        #expect(await controller.currentSnapshot().phase == .online)
    }

    @Test func leaseRenewalContinuesUntilTheResultReportReturns() async throws {
        let workerID = UUID()
        let fixture = try RecipeFixture(workerID: workerID, now: now, heartbeatSeconds: 5)
        let network = FakeBuildWorkerNetwork()
        await network.setReportDelay(.seconds(6))
        let controller = try makeController(
            workerID: workerID,
            network: network,
            fixture: fixture,
            savedClaim: MemoryCheckpoint(claim: fixture.claim)
        )
        await controller.setEnabled(true)
        await controller.runOneCycle()

        #expect(await network.reportCount == 1)
        #expect(await network.renewCount >= 1)
        #expect(await controller.currentSnapshot().phase == .online)
    }

    @Test func privateWorkspaceIsClearedEvenWhenResultReportingFails() async throws {
        let workerID = UUID()
        let fixture = try RecipeFixture(workerID: workerID, now: now)
        let network = FakeBuildWorkerNetwork()
        await network.setReportError(.http(500))
        let checkpoint = MemoryCheckpoint(claim: fixture.claim)
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        let controller = try makeController(
            workerID: workerID,
            network: network,
            fixture: fixture,
            savedClaim: checkpoint,
            workspaceRoot: workspace
        )
        await controller.setEnabled(true)
        await controller.runOneCycle()

        #expect(checkpoint.current != nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: workspace.path).isEmpty)
        #expect(await controller.currentSnapshot().phase == .offline)
    }

    @Test func tamperedSavedRecipeFailsClosedAndDoesNotLoopAcrossRelaunch() async throws {
        let workerID = UUID()
        let fixture = try RecipeFixture(workerID: workerID, now: now)
        var tampered = fixture.claim
        tampered.recipe.payload.commit = String(repeating: "f", count: 40)
        let network = FakeBuildWorkerNetwork()
        let checkpoint = MemoryCheckpoint(claim: tampered)
        let controller = try makeController(
            workerID: workerID,
            network: network,
            fixture: fixture,
            savedClaim: checkpoint
        )
        await controller.setEnabled(true)
        await controller.runOneCycle()

        #expect(checkpoint.current == nil)
        #expect(await controller.currentSnapshot().phase == .failed)
        #expect(await network.reportCount == 0)
    }

    @Test func hiddenBuildConfigurationIsPartOfTheVerifiedSourceDigest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("SWIFT_VERSION=6".utf8).write(
            to: directory.appendingPathComponent(".xcconfig")
        )
        let first = try BuildSourceDigest.hex(of: directory, byteLimit: 1_024)
        try Data("SWIFT_VERSION=5".utf8).write(
            to: directory.appendingPathComponent(".xcconfig")
        )
        let second = try BuildSourceDigest.hex(of: directory, byteLimit: 1_024)
        #expect(first != second)
    }

    @Test func onlyRepositoryMetadataNotNestedDotGitSourceIsExcludedFromDigest() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".git/objects", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("Fixtures/.git", isDirectory: true),
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let repositoryMetadata = directory.appendingPathComponent(".git/objects/pack")
        let nestedSource = directory.appendingPathComponent("Fixtures/.git/payload")
        try Data("metadata-a".utf8).write(to: repositoryMetadata)
        try Data("nested-a".utf8).write(to: nestedSource)
        let first = try BuildSourceDigest.hex(of: directory, byteLimit: 1_024)
        try Data("metadata-b".utf8).write(to: repositoryMetadata)
        let metadataChanged = try BuildSourceDigest.hex(of: directory, byteLimit: 1_024)
        try Data("nested-b".utf8).write(to: nestedSource)
        let nestedChanged = try BuildSourceDigest.hex(of: directory, byteLimit: 1_024)

        #expect(first == metadataChanged)
        #expect(metadataChanged != nestedChanged)
    }

    @Test func checkoutByteLimitCountsHiddenGitObjectsAsWellAsTheWorktree() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let git = directory.appendingPathComponent(".git/objects", isDirectory: true)
        try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data(repeating: 7, count: 128).write(to: git.appendingPathComponent("pack"))
        try Data(repeating: 8, count: 64).write(to: directory.appendingPathComponent("App.swift"))
        #expect(try BuildSourceDigest.allocatedBytes(in: directory) == 192)
    }

    @Test func signedOutputLimitIsMeasuredInUtf8BytesNotCharacters() {
        let output = BuildOutputRedactor.boundedUTF8(
            String(repeating: "🟢", count: 400_000),
            limit: 1_024 * 1_024
        )
        #expect(output.utf8.count <= 1_024 * 1_024)
    }

    #if os(macOS)
        @Test func xcodeInvocationUsesTypedExecutableAndNeverShellInterpolation() async throws {
            let workerID = UUID()
            let fixture = try RecipeFixture(
                workerID: workerID,
                now: now,
                scheme: "App; touch /tmp/pwned"
            )
            let runner = RecordingRunner()
            let source = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: source) }

            _ = try await XcodeBuildExecutor(runner: runner).execute(
                recipe: fixture.claim.recipe.payload,
                sourceDirectory: source
            )
            let invocation = try #require(await runner.invocations.first)
            #expect(invocation.tool == .xcodebuild)
            #expect(invocation.arguments[1] == "App; touch /tmp/pwned")
            #expect(!invocation.arguments.contains("sh"))
            #expect(!invocation.arguments.contains("-c"))
        }

        @Test func recipeFieldsWithNewlinesAreRejectedBeforeProcessLaunch() async throws {
            let fixture = try RecipeFixture(workerID: UUID(), now: now, scheme: "App\nOTHER=1")
            let runner = RecordingRunner()
            let source = FileManager.default.temporaryDirectory
            await #expect(throws: BuildWorkerExecutionError.invalidRecipeField("scheme")) {
                try await XcodeBuildExecutor(runner: runner).execute(
                    recipe: fixture.claim.recipe.payload,
                    sourceDirectory: source
                )
            }
            #expect(await runner.invocations.isEmpty)
        }

        @Test func xcresultSymlinksCannotArchiveFilesOutsideTheJobWorkspace() async throws {
            let fixture = try RecipeFixture(workerID: UUID(), now: now)
            let job = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let source = job.appendingPathComponent("source", isDirectory: true)
            let outside = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("private app state".utf8).write(to: outside)
            defer {
                try? FileManager.default.removeItem(at: job)
                try? FileManager.default.removeItem(at: outside)
            }

            await #expect(throws: BuildWorkerExecutionError.unsafeArtifact) {
                try await XcodeBuildExecutor(runner: SymlinkResultRunner(outside: outside)).execute(
                    recipe: fixture.claim.recipe.payload,
                    sourceDirectory: source
                )
            }
        }

        @Test func cancellationKillsProjectSpawnedDescendantsInTheBuildProcessGroup() async throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(at: directory) }
            let runner = FoundationFixedBuildProcessRunner()
            let environment = [
                "PATH": "/usr/bin:/bin",
                "HOME": directory.path,
                "LANG": "C",
                "GIT_AUTHOR_NAME": "Spark Test",
                "GIT_AUTHOR_EMAIL": "spark@example.invalid",
                "GIT_COMMITTER_NAME": "Spark Test",
                "GIT_COMMITTER_EMAIL": "spark@example.invalid",
            ]
            func runGit(_ arguments: [String]) async throws {
                let output = try await runner.run(
                    tool: .git,
                    arguments: arguments,
                    directory: directory,
                    environment: environment,
                    timeoutSeconds: 10,
                    outputLimit: 64 * 1024,
                    monitoredDirectory: nil,
                    byteLimit: nil
                )
                #expect(output.status == 0)
            }
            try await runGit(["init"])
            try Data("source".utf8).write(to: directory.appendingPathComponent("source.txt"))
            try await runGit(["add", "source.txt"])
            let hook = directory.appendingPathComponent(".git/hooks/pre-commit")
            try Data("#!/bin/sh\n/bin/sleep 30 &\necho $! > .git/spark-child.pid\nwait\n".utf8)
                .write(to: hook)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: hook.path
            )

            let task = Task {
                try await runner.run(
                    tool: .git,
                    arguments: ["commit", "-m", "exercise descendant cancellation"],
                    directory: directory,
                    environment: environment,
                    timeoutSeconds: 30,
                    outputLimit: 64 * 1024,
                    monitoredDirectory: nil,
                    byteLimit: nil
                )
            }
            let childFile = directory.appendingPathComponent(".git/spark-child.pid")
            for _ in 0..<100 where !FileManager.default.fileExists(atPath: childFile.path) {
                try await Task.sleep(for: .milliseconds(20))
            }
            let childText = try String(contentsOf: childFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let childPID = try #require(pid_t(childText))
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
            for _ in 0..<100 where Darwin.kill(childPID, 0) == 0 {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(Darwin.kill(childPID, 0) == -1)
            #expect(errno == ESRCH)
        }

        @Test func successfulToolExitStillKillsBackgroundProjectDescendants() async throws {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            defer { try? FileManager.default.removeItem(at: directory) }
            let runner = FoundationFixedBuildProcessRunner()
            let environment = [
                "PATH": "/usr/bin:/bin",
                "HOME": directory.path,
                "LANG": "C",
                "GIT_AUTHOR_NAME": "Spark Test",
                "GIT_AUTHOR_EMAIL": "spark@example.invalid",
                "GIT_COMMITTER_NAME": "Spark Test",
                "GIT_COMMITTER_EMAIL": "spark@example.invalid",
            ]
            func runGit(_ arguments: [String]) async throws -> FixedProcessOutput {
                try await runner.run(
                    tool: .git,
                    arguments: arguments,
                    directory: directory,
                    environment: environment,
                    timeoutSeconds: 10,
                    outputLimit: 64 * 1024,
                    monitoredDirectory: nil,
                    byteLimit: nil
                )
            }
            #expect(try await runGit(["init"]).status == 0)
            try Data("source".utf8).write(to: directory.appendingPathComponent("source.txt"))
            #expect(try await runGit(["add", "source.txt"]).status == 0)
            let hook = directory.appendingPathComponent(".git/hooks/pre-commit")
            try Data("#!/bin/sh\n/bin/sleep 30 &\necho $! > .git/spark-child.pid\nexit 0\n".utf8)
                .write(to: hook)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: hook.path
            )

            #expect(
                try await runGit(["commit", "-m", "exercise descendant cleanup"]).status == 0
            )
            let childText = try String(
                contentsOf: directory.appendingPathComponent(".git/spark-child.pid"),
                encoding: .utf8
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let childPID = try #require(pid_t(childText))
            for _ in 0..<100 where Darwin.kill(childPID, 0) == 0 {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(Darwin.kill(childPID, 0) == -1)
            #expect(errno == ESRCH)
        }
    #endif

    private func makeController(
        workerID: UUID = UUID(),
        network: FakeBuildWorkerNetwork,
        fixture: RecipeFixture? = nil,
        savedClaim: MemoryCheckpoint?,
        workspaceRoot: URL? = nil
    ) throws -> BuildWorkerController {
        let resolved = try fixture ?? RecipeFixture(workerID: workerID, now: now)
        return BuildWorkerController(
            nodeID: "node",
            workerID: workerID,
            client: network,
            trust: resolved.trust,
            capabilities: .init(xcodeVersion: "26.0"),
            sourceFetcher: FakeSourceFetcher(),
            executor: FakeExecutor(),
            evidenceSigner: BuildEvidenceSigner(key: SoftwareSigner()),
            checkpointStore: savedClaim ?? MemoryCheckpoint(),
            workspaceRoot: workspaceRoot
                ?? FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true),
            runsContinuously: false,
            now: { self.now }
        )
    }
}

#if os(macOS)
    private actor RecordingRunner: FixedBuildProcessRunning {
        struct Invocation: Sendable {
            let tool: FixedBuildTool
            let arguments: [String]
        }

        private(set) var invocations: [Invocation] = []

        func run(
            tool: FixedBuildTool,
            arguments: [String],
            directory _: URL,
            environment _: [String: String],
            timeoutSeconds _: Int,
            outputLimit _: Int,
            monitoredDirectory _: URL?,
            byteLimit _: Int?
        ) async throws -> FixedProcessOutput {
            invocations.append(.init(tool: tool, arguments: arguments))
            return .init(status: 0, output: Data("ok".utf8))
        }
    }

    private actor SymlinkResultRunner: FixedBuildProcessRunning {
        let outside: URL

        init(outside: URL) {
            self.outside = outside
        }

        func run(
            tool: FixedBuildTool,
            arguments: [String],
            directory _: URL,
            environment _: [String: String],
            timeoutSeconds _: Int,
            outputLimit _: Int,
            monitoredDirectory _: URL?,
            byteLimit _: Int?
        ) async throws -> FixedProcessOutput {
            if tool == .xcodebuild,
                let flag = arguments.firstIndex(of: "-resultBundlePath"),
                arguments.indices.contains(flag + 1)
            {
                let result = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
                try FileManager.default.createDirectory(
                    at: result,
                    withIntermediateDirectories: true
                )
                try FileManager.default.createSymbolicLink(
                    at: result.appendingPathComponent("escaped"),
                    withDestinationURL: outside
                )
            }
            return .init(status: 0, output: Data("ok".utf8))
        }
    }
#endif

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
