import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing
@testable import SparkAppComposition

@MainActor
@Test func dashboardLoadsItsLastDeviceLocalTelemetryBeforeTheNetworkReturns() async {
    let cache = DashboardTestTestTelemetryCache()
    let targetID = "node:\(dashboardTestDashboardCoordinatorID)"
    let live = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: DashboardTestFakeRuntimeReader(),
        targetID: targetID,
        operationStore: DashboardTestTestOperationStore(),
        telemetryCache: cache
    )
    await live.refresh()

    let restored = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: DashboardTestLifecycleRuntime(failReads: true),
        targetID: targetID,
        expectedIdentity: SparkDashboardIdentityExpectation(
            coordinatorNodeID: dashboardTestDashboardNodeID(dashboardTestDashboardCoordinatorID),
            authorityFingerprint: nil,
            clusterID: nil
        ),
        operationStore: DashboardTestTestOperationStore(),
        telemetryCache: cache
    )

    #expect(restored.telemetry == live.telemetry)
    #expect(!restored.telemetryIsLive)
    #expect(restored.storageTelemetry.contains("used"))
    #expect(restored.gpuMemoryTelemetry == live.gpuMemoryTelemetry)
    #expect(restored.memoryStallTelemetry == live.memoryStallTelemetry)
}

@MainActor
@Test func dashboardDoesNotInventUnavailableLiveCounters() async {
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: DashboardTestFakeRuntimeReader(reportsOptionalTelemetry: false),
        operationStore: DashboardTestTestOperationStore(),
        telemetryCache: DashboardTestTestTelemetryCache()
    )

    await model.refresh()

    #expect(model.gpuMemoryTelemetry == "Unavailable")
    #expect(model.memoryStallTelemetry == "Unavailable")
    #expect(model.inferenceTelemetryDetail.contains("Queue unavailable"))
}

@MainActor
@Test func visibleDashboardPollsOnlyTheLightweightTelemetryFeed() async {
    let runtime = DashboardTestFakeRuntimeReader()
    let tick = DashboardTestOneTelemetryTick()
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        operationStore: DashboardTestTestOperationStore(),
        telemetryCache: DashboardTestTestTelemetryCache(),
        telemetryDelay: { interval in try await tick.wait(interval) }
    )

    // Keep this feed-selection test independent of whether the test Mac is on battery.
    await model.runLiveUpdates(interval: .seconds(5))

    #expect(await runtime.telemetryCalls() == 2)
    let intervals = await tick.recordedIntervals()
    #expect(intervals.count == 2)
    // The live updater respects the host's current battery mode; the pure policy is checked separately.
    #expect(intervals.allSatisfy { $0 == .seconds(1) || $0 == .seconds(5) })
    #expect(model.telemetryIsLive)
}

@MainActor
@Test func dashboardStartsFromAuthenticatedCacheAndKeepsItWhenRefreshFails() async {
    let cachedAt = Date(timeIntervalSince1970: 1_777_374_000)
    let snapshot = dashboardTestDashboardCachedSnapshot(at: cachedAt)
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: DashboardTestLifecycleRuntime(failReads: true),
        cachedSnapshot: snapshot,
        operationStore: DashboardTestTestOperationStore()
    )

    #expect(model.nodeName == "Cached Spark")
    #expect(model.runtimeVersion == "0.4.0")
    #expect(
        model.vllmStatus == "Checking",
        "cached inference does not prove this runtime still has container support"
    )
    #expect(model.installedModelCount == 1)
    #expect(model.cachedPlacements.first?.displayName == "Cached Model")
    #expect(model.freshness == .cached(refreshedAt: cachedAt))

    await model.refresh()

    #expect(model.nodeName == "Cached Spark")
    #expect(model.cachedPlacements.count == 1)
    #expect(model.freshness == .cached(refreshedAt: cachedAt))
    #expect(model.errorMessage?.contains("could not be reached") == true)
}

@MainActor
@Test func successfulDashboardRefreshPublishesEvidenceToTheLocalCache() async {
    let observedAt = Date(timeIntervalSince1970: 1_777_374_100)
    let snapshot = dashboardTestDashboardCachedSnapshot(at: observedAt)
    var recordedEvidence: TargetOperationalEvidence?
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: DashboardTestFakeRuntimeReader(),
        targetIdentity: snapshot.identity,
        operationStore: DashboardTestTestOperationStore(),
        now: { observedAt },
        cacheEvidence: { evidence, date in
            #expect(date == observedAt)
            recordedEvidence = evidence
            return snapshot
        }
    )

    await model.refresh()

    #expect(recordedEvidence?.identity == snapshot.identity)
    #expect(
        recordedEvidence?.respondingNodeID
            == dashboardTestDashboardNodeID(dashboardTestDashboardCoordinatorID)
    )
    #expect(model.cachedSnapshot == snapshot)
    #expect(model.freshness == .current(refreshedAt: observedAt))
}

// MARK: - Durable operations reach the cached snapshot

/// Dashboard refresh must cache durable operations for the Activity tab.
@MainActor
@Test func aRefreshCachesTheOperationsTheActivityTabLists() async throws {
    let observedAt = Date(timeIntervalSince1970: 1_777_374_100)
    let running = try dashboardTestLifecycleOperation(
        kind: "model.install",
        state: "running",
        progress: 0.5,
        stage: "downloading"
    )
    var recordedEvidence: TargetOperationalEvidence?
    let snapshot = dashboardTestDashboardCachedSnapshot(at: observedAt)
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: DashboardTestFakeRuntimeReader(listedOperations: [running]),
        targetIdentity: snapshot.identity,
        operationStore: DashboardTestTestOperationStore(),
        now: { observedAt },
        cacheEvidence: { evidence, _ in
            recordedEvidence = evidence
            return snapshot
        }
    )

    await model.refresh()

    let operations = try #require(
        recordedEvidence?.operations,
        "the refresh cached no operations, so the Activity tab has nothing to list"
    )
    #expect(operations.value.map(\.id) == [running.id])
    #expect(operations.observedAt == observedAt)
}

/// Omit unavailable operation evidence so the composer retains the last authenticated history.
@MainActor
@Test func aSparkThatCannotListOperationsOmitsThemRatherThanReportingNone() async {
    let observedAt = Date(timeIntervalSince1970: 1_777_374_100)
    var recordedEvidence: TargetOperationalEvidence?
    let snapshot = dashboardTestDashboardCachedSnapshot(at: observedAt)
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: DashboardTestFakeRuntimeReader(listedOperations: nil),
        targetIdentity: snapshot.identity,
        operationStore: DashboardTestTestOperationStore(),
        now: { observedAt },
        cacheEvidence: { evidence, _ in
            recordedEvidence = evidence
            return snapshot
        }
    )

    await model.refresh()

    #expect(recordedEvidence != nil, "the rest of the refresh still succeeded")
    #expect(
        recordedEvidence?.operations == nil,
        "a failed operations read was reported as an established empty list"
    )
}
