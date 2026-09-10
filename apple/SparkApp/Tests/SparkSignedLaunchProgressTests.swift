import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import Testing
@testable import SparkAppComposition

@MainActor
@Suite(.serialized)
struct SparkSignedLaunchProgressTests {
    enum Failure: Sendable { case none, temporaryStatusLoss, terminal }

    @Test(arguments: [Failure.none, .temporaryStatusLoss, .terminal], [false, true])
    func signedLaunchReportsProgressAndOnlyFailsOnTerminalFailure(
        failure: Failure,
        alreadyRunning: Bool
    )
        async throws
    {
        let node = SparkNodeID(rawValue: UUID(uuidString: "63e82da2-7fb7-4b4b-9584-4a528000ac94")!)
        let route = URL(string: "https://launch-fixture.example:7443")!
        let library = SparkLibrary(store: MemoryLibraryStore())
        let entry = library.reconcile(
            AuthenticatedTarget(
                nodeID: node,
                clusterID: nil,
                name: "Fixture Spark",
                role: .standalone,
                authorityFingerprint: "abc",
                displayName: "Fixture Spark",
                routes: [CachedRoute(baseURL: route, kind: .localWiFi)],
                reachedAt: Date()
            )
        ).entry
        let runtime = DashboardTestLifecycleRuntime(
            failOperationPolling: failure == .temporaryStatusLoss,
            operationResponses: [
                try dashboardTestLifecycleOperation(
                    kind: "model.load",
                    state: "running",
                    progress: 0.84
                ),
                try dashboardTestLifecycleOperation(
                    kind: "model.load",
                    state: failure == .terminal ? "failed" : "succeeded",
                    progress: 1
                ),
            ],
            activeModelID: alreadyRunning ? "open/model-8b" : nil,
            loadResponses: [
                try dashboardTestLifecycleOperation(
                    kind: "model.load",
                    state: "running",
                    progress: 0.15
                )
            ]
        )
        await runtime.completeLoadAs("open/model-8b")
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let launcher = SignedSparkModelLauncher(
            library: library,
            defaults: defaults,
            runtimeResolver: { _ in
                ModelLibraryRuntimeConnection(
                    route: route,
                    expectedNodeID: node,
                    expectedClusterID: nil,
                    expectedAuthorityFingerprint: "abc",
                    runtime: runtime
                )
            },
            operationStore: DashboardTestTestOperationStore()
        )
        let target = SparkChatTarget(
            id: entry.id,
            displayName: entry.displayName,
            nodeID: node,
            route: route,
            tlsFingerprint: String(repeating: "a", count: 64),
            authorityFingerprint: "abc",
            modelID: "open/model-8b",
            modelName: "Model 8B"
        )
        let plan = try await launcher.prepare(target: target, profileID: "balanced")
        var fractions: [Double] = []
        do {
            let ready = try await launcher.apply(plan) { update in
                if let fraction = update.fraction { fractions.append(fraction) }
            }
            #expect(failure != .terminal, "A failed Spark operation must not look successful")
            #expect(ready.modelID == target.modelID)
        } catch {
            guard failure == .terminal else { throw error }
            #expect(error is SparkModelLaunchError)
        }
        #expect(
            fractions.contains(0.15),
            "Show the accepted operation before waiting for its first status poll"
        )
        #expect(
            fractions.contains(0.84),
            "Progress must arrive while the real operation is running"
        )
        #expect(await runtime.loadCalls.count == 1, "Reconnecting never submits a duplicate launch")
        #expect(
            await runtime.operationResponses.isEmpty,
            "An old ready snapshot cannot complete a new launch"
        )
    }
}
