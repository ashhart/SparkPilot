import Foundation
import SparkAPI
import Testing

@testable import SparkAppComposition

/// Verifies runtime history states and an explicitly labelled device-cache fallback when the Spark is unreachable.
private func history(
    recording: Bool = true,
    rows: [GeneratedAPI.TelemetryHistoryRow] = [],
    latest: String? = nil
) -> GeneratedAPI.TelemetryHistory {
    GeneratedAPI.TelemetryHistory(
        apiVersion: 1,
        nodeId: "node",
        recording: recording,
        latestObservedAt: latest,
        retention: GeneratedAPI.TelemetryHistoryRetention(
            rawSeconds: 86_400,
            aggregateSeconds: 2_592_000,
            rawBucketSeconds: 10,
            aggregateBucketSeconds: 60
        ),
        rows: rows
    )
}

private func row(
    _ observedAt: String,
    resolution: GeneratedAPI.TelemetryHistoryRowResolution = .raw,
    sampleCount: Int = 1,
    cpu: Double? = 0.25
) -> GeneratedAPI.TelemetryHistoryRow {
    GeneratedAPI.TelemetryHistoryRow(
        observedAt: observedAt,
        resolution: resolution,
        sampleCount: sampleCount,
        cpuUtilisation: cpu
    )
}

private let route = URL(string: "https://192.168.1.44:7443")!

@MainActor
@Test func historyFromTheRuntimeIsLabelledAsTheSparksOwnRecord() async {
    let model = SparkTelemetryHistoryModel(
        load: { _ in
            history(
                rows: [
                    row("2026-09-01T10:00:00Z"),
                    row("2026-09-01T09:59:50Z"),
                    row("2026-09-01T09:00:00Z", resolution: .minute, sampleCount: 6),
                ],
                latest: "2026-09-01T10:00:00Z"
            )
        }
    )
    await model.refresh(route: route)

    #expect(model.origin == .runtime)
    #expect(model.points.count == 3)
    // Oldest first, so a chart can draw it without re-sorting.
    #expect(model.points.first!.observedAt < model.points.last!.observedAt)
    #expect(model.points.last?.isRaw == true)
    #expect(model.points.first?.isRaw == false)
    #expect(model.points.first?.sampleCount == 6, "a fold lost its sample count")
    #expect(model.latestObservedAt != nil)
}

@MainActor
@Test func aSparkThatIsNotRecordingSaysSoRatherThanShowingAnEmptyChart() async {
    let model = SparkTelemetryHistoryModel(load: { _ in history(recording: false) })
    await model.refresh(route: route)

    #expect(model.origin == .none(.recordingDisabled))
    #expect(model.points.isEmpty)
    let message = SparkTelemetryHistoryCopy.emptyMessage(.recordingDisabled)
    #expect(message.contains("not recording"))
    #expect(message != SparkTelemetryHistoryCopy.emptyMessage(.noSamplesYet))
}

@MainActor
@Test func recordingWithNothingYetIsADifferentStateFromNotRecording() async {
    let model = SparkTelemetryHistoryModel(load: { _ in history(recording: true) })
    await model.refresh(route: route)
    #expect(model.origin == .none(.noSamplesYet))
    #expect(
        SparkTelemetryHistoryCopy.emptyMessage(.noSamplesYet)
            != SparkTelemetryHistoryCopy.emptyMessage(.unreachable)
    )
}

@MainActor
@Test func anUnreachableSparkFallsBackToThisDevicesCacheAndSaysThatIsWhatItIs() async {
    struct Unreachable: Error {}
    let cached = [
        SparkTelemetryHistoryPoint(
            observedAt: Date(timeIntervalSince1970: 1_756_000_000),
            isRaw: false,
            sampleCount: 1,
            cpuUtilisation: nil,
            memoryAvailableBytes: nil,
            acceleratorUtilisation: nil,
            activeRequests: 2,
            queueDepth: 0,
            tokensPerSecond: 30
        )
    ]
    let model = SparkTelemetryHistoryModel(
        load: { _ in throw Unreachable() },
        cached: { cached }
    )
    await model.refresh(route: route)

    #expect(model.origin == .deviceCache)
    #expect(model.points == cached)
    #expect(SparkTelemetryHistoryCopy.deviceCacheNotice.contains("this device"))
}

@MainActor
@Test func anUnreachableSparkWithNothingCachedSaysThatRatherThanNothingHappened() async {
    struct Unreachable: Error {}
    let model = SparkTelemetryHistoryModel(load: { _ in throw Unreachable() }, cached: { [] })
    await model.refresh(route: route)
    #expect(model.origin == .none(.unreachable))
    #expect(model.points.isEmpty)
}

/// Throttle history independently so one-second live updates do not issue history requests on every tick.
@MainActor
@Test func historyIsFetchedOnEntryAndThenOnlyAtItsOwnCadence() async {
    let calls = Counter()
    let clock = MovableClock(Date(timeIntervalSince1970: 1_756_000_000))
    let model = SparkTelemetryHistoryModel(
        load: { _ in
            calls.increment()
            return history(rows: [row("2026-09-01T10:00:00Z")])
        },
        now: { clock.value }
    )

    #expect(model.needsRefresh(), "the first entry must fetch")
    await model.refresh(route: route)
    #expect(calls.value == 1)

    // Sixty live ticks later, still inside the window.
    await model.refresh(route: route)
    #expect(calls.value == 1, "history was refetched at the live cadence")

    clock.advance(by: SparkTelemetryHistoryModel.refreshInterval + 1)
    #expect(model.needsRefresh())
    await model.refresh(route: route)
    #expect(calls.value == 2)

    // Entering the dashboard again asks regardless of the clock.
    await model.refresh(route: route, force: true)
    #expect(calls.value == 3)
}

/// Distinguish a late raw sample from an aggregate bucket even when their timestamps match.
@MainActor
@Test func aRawPointAndAMinutePointAtTheSameInstantAreDifferentPoints() async {
    let instant = "2026-09-01T10:00:00Z"
    let model = SparkTelemetryHistoryModel(
        load: { _ in
            history(
                rows: [
                    row(instant, resolution: .minute, sampleCount: 6, cpu: 0.6),
                    row(instant, resolution: .raw, cpu: 0.1),
                ],
                latest: instant
            )
        }
    )
    await model.refresh(route: route)

    #expect(model.points.count == 2, "the two readings collapsed into one")
    #expect(
        Set(model.points.map(\.id)).count == 2,
        "a raw sample and a minute at the same instant share an identity"
    )
    #expect(Set(model.points.map(\.isRaw)) == [true, false], "one of the two kinds was dropped")
}

/// Throttle failed history reads as well as successful ones to avoid one-second retry loops while offline.
@MainActor
@Test func aFailedFetchIsThrottledJustLikeASuccessfulOne() async {
    struct Unreachable: Error {}
    let calls = Counter()
    let clock = MovableClock(Date(timeIntervalSince1970: 1_756_000_000))
    let model = SparkTelemetryHistoryModel(
        load: { _ in
            calls.increment()
            throw Unreachable()
        },
        cached: { [] },
        now: { clock.value }
    )

    await model.refresh(route: route)
    #expect(calls.value == 1)
    #expect(model.origin == .none(.unreachable))

    // Sixty live ticks against an offline Spark.
    for _ in 0..<60 {
        await model.refresh(route: route)
    }
    #expect(calls.value == 1, "an offline Spark was retried at the live cadence")

    clock.advance(by: SparkTelemetryHistoryModel.refreshInterval + 1)
    await model.refresh(route: route)
    #expect(calls.value == 2, "the retry never came")
}

/// Compose telemetry history into the shared panel used by every platform root.
@Test func theSharedDashboardPanelRendersTheHistoryCard() throws {
    let source = try String(
        contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Shared/SparkDashboardHealthView.swift"),
        encoding: .utf8
    )
    #expect(
        source.contains("SparkTelemetryHistoryCard(history: model.history)"),
        "the telemetry panel no longer renders the history card"
    )
    // Assert history refresh within the live loop itself so an entry refresh cannot mask missing cadence.
    let poller = try String(
        contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Shared/SparkDashboardLiveUpdater.swift"),
        encoding: .utf8
    )
    let loop = try #require(poller.range(of: "func run("))
    let body = poller[loop.upperBound...].prefix(900)
    #expect(
        body.contains("await refreshHistory()"),
        "the live loop no longer refreshes history on its own cadence"
    )
    #expect(body.contains("await refreshTelemetry"), "the 1 Hz live card stopped refreshing")
}

private final class MovableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: Date
    init(_ instant: Date) { self.instant = instant }
    var value: Date {
        lock.lock()
        defer { lock.unlock() }
        return instant
    }
    func advance(by interval: TimeInterval) {
        lock.lock()
        instant = instant.addingTimeInterval(interval)
        lock.unlock()
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

/// Represent unsupported runtime history as not recording rather than a dashboard load failure.
@MainActor
@Test func aRuntimeWithoutTheHistoryRouteReportsNotRecording() async throws {
    struct OldRuntime: SparkRuntimeReading {
        func capabilities(route: URL) async throws -> SparkCapabilities { throw Unimplemented() }
        func health(route: URL) async throws -> Health { throw Unimplemented() }
        func status(route: URL) async throws -> SparkStatus { throw Unimplemented() }
        func telemetry(route: URL) async throws -> TelemetrySnapshot { throw Unimplemented() }
        func models(route: URL) async throws -> ModelCatalogue { throw Unimplemented() }
        func activeInference(route: URL) async throws -> ActiveInference { throw Unimplemented() }
        struct Unimplemented: Error {}
    }
    let snapshot = try await OldRuntime().telemetryHistory(route: route)
    #expect(snapshot.recording == false)
    #expect(snapshot.rows.isEmpty)
}
