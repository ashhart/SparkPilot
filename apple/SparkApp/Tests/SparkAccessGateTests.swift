import CryptoKit
import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing

@testable import SparkAppComposition

private enum UnreachableBuild: Error { case noClient }

/// These gates are reached before any network client exists, so the factory only has to refuse.
private struct UnreachableBuildClientFactory: BuildClientCreating {
    @MainActor
    func client(for target: BuildTarget) throws -> any BuildProjectNetworking {
        throw UnreachableBuild.noClient
    }
}

private func source(_ relativePath: String) throws -> String {
    let testFile = URL(fileURLWithPath: #filePath)
    let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    return try String(contentsOf: appRoot.appending(path: relativePath), encoding: .utf8)
}

/// QA-12, QA-25: Builds said "No Paired Spark" and Clusters said "No Standalone Sparks" with three Sparks in the library; the real gate is that none of them has a session this device can use.
@Test func aSavedSparkWithNoUsableSessionIsNotTheSameAsNoSparkAtAll() {
    #expect(SparkAccessGate.resolve(savedSparks: 0, usableTargets: 0) == .noSparkSaved)
    #expect(SparkAccessGate.resolve(savedSparks: 3, usableTargets: 0) == .noUsableSpark)
    #expect(SparkAccessGate.resolve(savedSparks: 3, usableTargets: 1) == .ready)
    #expect(SparkAccessGate.resolve(savedSparks: 0, usableTargets: 2) == .ready)
}

/// QA-12, QA-25: both screens have to carry the second message, not just the first.
@Test func bothEmptyStatesSayWhichOfTheTwoProblemsItIs() throws {
    let builds = try source("Shared/BuildProjectView.swift")
    let clusters = try source("Shared/ExternalClusterPreviewView.swift")

    for view in [builds, clusters] {
        #expect(view.contains("case .noSparkSaved"))
        #expect(view.contains("case .noUsableSpark"))
    }
}

/// QA-12: the banner on the Builds tab told the owner to pair a Spark before opening Projects — the wrong screen and the wrong reason.
@MainActor
@Test func theBuildsBannerNamesBuildsAndTheRealReason() async throws {
    let library = SparkLibrary(store: MemoryLibraryStore())
    let model = BuildProjectModel(
        library: library,
        clients: UnreachableBuildClientFactory(),
        trustStore: NodeTrustStore(store: InMemoryStore()),
        defaults: try #require(UserDefaults(suiteName: "SparkAccessGateTests.\(UUID())"))
    )

    await model.refreshProjects()
    let empty = try #require(model.problem)
    #expect(!empty.contains("Projects"))
    #expect(empty.contains("build"))

    library.reconcile(
        AuthenticatedTarget(
            nodeID: SparkNodeID(rawValue: UUID()),
            clusterID: nil,
            name: "Loft Spark",
            role: .standalone,
            authorityFingerprint: String(repeating: "b", count: 64),
            displayName: "loft-spark",
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
    model.refreshTargets()
    await model.refreshProjects()

    let untrusted = try #require(model.problem)
    #expect(!untrusted.contains("Projects"))
    #expect(untrusted != empty, "a saved but unusable Spark is a different problem from none")
}

/// QA-13: Queue Build looked live and did nothing; whatever holds it back is now named on screen.
@MainActor
@Test func queueBuildSaysWhatItIsWaitingFor() async throws {
    let model = BuildProjectModel(
        library: SparkLibrary(store: MemoryLibraryStore()),
        clients: UnreachableBuildClientFactory(),
        trustStore: NodeTrustStore(store: InMemoryStore()),
        defaults: try #require(UserDefaults(suiteName: "SparkAccessGateTests.\(UUID())"))
    )

    #expect(!model.canSubmit)
    let noProject = try #require(model.submitBlockReason)
    #expect(!noProject.isEmpty)

    model.selectedProjectID = "project-1"
    #expect(model.submitBlockReason != noProject, "the next unmet condition is named in turn")
    model.commit = String(repeating: "a", count: 40)
    model.sourceSHA256 = String(repeating: "b", count: 64)
    #expect(model.submitBlockReason == nil)
    #expect(model.canSubmit)
}
