import Foundation
import SparkAPI
import SparkTransport
import Testing

@testable import SparkAppComposition

/// Every type the app acts on must be a type this runtime actually publishes (§44.1).
@Suite struct SparkEventRoutingTests {

    /// The catalogue, split into what is published and what is only reserved.
    private static func catalogue() throws -> (published: Set<String>, reserved: Set<String>) {
        let testFile = URL(fileURLWithPath: #filePath)
        let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let repoRoot = appRoot.deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(
            contentsOf: repoRoot.appending(path: "docs/EVENT_CATALOGUE.md"),
            encoding: .utf8
        )
        var published: Set<String> = []
        var reserved: Set<String> = []
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("- `") else { continue }
            let afterTick = line.dropFirst(3)
            guard let close = afterTick.firstIndex(of: "`") else { continue }
            let type = String(afterTick[afterTick.startIndex..<close])
            guard type.contains(".") else { continue }
            if line.contains("not published by this runtime") {
                reserved.insert(type)
            } else {
                published.insert(type)
            }
        }
        return (published, reserved)
    }

    @Test func everyRoutedTypeIsPublishedByThisRuntime() throws {
        let catalogue = try Self.catalogue()
        #expect(catalogue.published.count > 40)
        for type in SparkEventRouting.routedTypes {
            #expect(catalogue.published.contains(type), "\(type) is not a published event type")
            #expect(!catalogue.reserved.contains(type), "\(type) is reserved, not emitted")
        }
    }

    @Test func aRoutedTypeAlwaysAsksForAtLeastOneRefresh() {
        for type in SparkEventRouting.routedTypes {
            #expect(!SparkEventRouting.refreshes(for: type).isEmpty, "\(type) refreshes nothing")
        }
    }

    @Test func anUnknownTypeIsIgnoredRatherThanRefusedOrCrashed() {
        #expect(SparkEventRouting.refreshes(for: "model.teleported.v9").isEmpty)
        #expect(SparkEventRouting.refreshes(for: "").isEmpty)
        #expect(SparkEventRouting.refreshes(for: "…").isEmpty)
    }

    @Test func theLifecycleTypesTheDashboardShowsAreRouted() {
        #expect(SparkEventRouting.refreshes(for: "model.ready").contains(.models))
        #expect(SparkEventRouting.refreshes(for: "model.ready").contains(.inference))
        #expect(SparkEventRouting.refreshes(for: "operation.progress").contains(.operations))
        #expect(SparkEventRouting.refreshes(for: "operation.completed").contains(.status))
        #expect(
            SparkEventRouting.refreshes(for: "node.memory.pressure.changed").contains(.telemetry)
        )
        #expect(SparkEventRouting.refreshes(for: "device.revoked").contains(.devices))
        #expect(SparkEventRouting.refreshes(for: "shared_access.revoked").contains(.sharedAccess))
        #expect(SparkEventRouting.refreshes(for: "remote.tunnel.unhealthy").contains(.remoteAccess))
        #expect(SparkEventRouting.refreshes(for: "automation.run.failed").contains(.automations))
        #expect(SparkEventRouting.refreshes(for: "workload.adopted").contains(.workloads))
    }

    @Test func aReservedTypeIsNotRouted() {
        #expect(SparkEventRouting.refreshes(for: "inference.request.started").isEmpty)
        #expect(SparkEventRouting.refreshes(for: "node.status.changed").isEmpty)
    }
}

/// The dashboard's subscription applies mapped refreshes and never removes polling (§44.1).
@MainActor
@Suite struct SparkEventSubscriptionTests {

    /// Records what the subscription asked the app to refresh.
    private final class Recorder {
        var applied: [SparkEventRefresh] = []
    }

    private func subscription(
        _ script: [SparkEventStreamElement],
        failingWith failure: (any Error)? = nil,
        recorder: Recorder,
        apply: (@MainActor (SparkEventRefresh) async -> Void)? = nil
    ) -> SparkEventSubscription {
        SparkEventSubscription(
            open: { _ in
                AsyncThrowingStream { continuation in
                    for element in script { continuation.yield(element) }
                    continuation.finish(throwing: failure)
                }
            },
            apply: { refresh in
                recorder.applied.append(refresh)
                await apply?(refresh)
            }
        )
    }

    private func event(_ type: String, sequence: Int) -> SparkEventStreamElement {
        .event(SparkRuntimeEvent(sequence: sequence, type: type))
    }

    @Test func aMappedEventAsksForExactlyTheRefreshesItMeans() async {
        let recorder = Recorder()
        let subscription = subscription(
            [event("operation.completed", sequence: 3)],
            recorder: recorder
        )

        await subscription.run()

        #expect(recorder.applied == [SparkEventRouting.refreshes(for: "operation.completed")])
        #expect(subscription.lastEventID == "3")
    }

    @Test func anUnknownTypeRefreshesNothingAndStillMovesTheCursor() async {
        let recorder = Recorder()
        let subscription = subscription(
            [event("model.teleported.v9", sequence: 11)],
            recorder: recorder
        )

        await subscription.run()

        #expect(recorder.applied.isEmpty)
        #expect(subscription.lastEventID == "11")
    }

    @Test func anExpiredCursorRefreshesEverythingAndForgetsTheCursor() async {
        let recorder = Recorder()
        let subscription = subscription([.cursorExpired], recorder: recorder)
        subscription.resume(from: "9")

        await subscription.run()

        #expect(recorder.applied == [SparkEventRefresh.everything])
        #expect(subscription.lastEventID == nil)
    }

    @Test func aHeartbeatIsLivenessRatherThanARefresh() async {
        let recorder = Recorder()
        let subscription = subscription([.heartbeat, .heartbeat], recorder: recorder)

        await subscription.run()

        #expect(recorder.applied.isEmpty)
        #expect(subscription.eventsSeen == 0)
        #expect(subscription.heartbeatsSeen == 2)
    }

    @Test func aSparkThatRefusesTheStreamLeavesPollingAlone() async {
        let recorder = Recorder()
        let subscription = subscription(
            [],
            failingWith: SSEOpenFailure.unsupported(statusCode: 404),
            recorder: recorder
        )

        await subscription.run()

        #expect(recorder.applied.isEmpty)
        #expect(subscription.isStreaming == false)
        #expect(subscription.refusedByThisSpark)
    }

    @Test func aBurstArrivingDuringARefreshIsFoldedIntoOneFollowUp() async {
        let recorder = Recorder()
        let (held, release) = AsyncStream<Void>.makeStream()
        let subscription = subscription(
            [
                event("model.ready", sequence: 1),
                event("device.paired", sequence: 2),
                event("remote.tunnel.enabled", sequence: 3),
            ],
            recorder: recorder,
            apply: { _ in
                guard recorder.applied.count == 1 else { return }
                var iterator = held.makeAsyncIterator()
                _ = await iterator.next()
            }
        )

        let reading = Task { await subscription.run() }
        // Hold the first refresh until the whole burst has been read behind it.
        var spins = 0
        while subscription.eventsSeen < 3 && spins < 10_000 {
            await Task.yield()
            spins += 1
        }
        release.yield(())
        release.finish()
        await reading.value

        #expect(recorder.applied.count == 2)
        #expect(recorder.applied[0] == SparkEventRouting.refreshes(for: "model.ready"))
        #expect(
            recorder.applied[1]
                == SparkEventRouting.refreshes(for: "device.paired").union(
                    SparkEventRouting.refreshes(for: "remote.tunnel.enabled")
                )
        )
        #expect(subscription.lastEventID == "3")
    }

    @Test func stoppingEndsTheSubscriptionAndClearsLiveness() async {
        let recorder = Recorder()
        let subscription = subscription([.heartbeat], recorder: recorder)

        subscription.start()
        subscription.stop()

        #expect(subscription.isStreaming == false)
    }
}

/// A dashboard only subscribes when this device can open a signed, pinned stream.
@MainActor
@Suite struct SparkEventStreamOpeningTests {

    private struct StubSigner: RequestSigning {
        func authorize(_ request: URLRequest, body: Data) throws -> URLRequest { request }
    }

    private static let pin = String(repeating: "c", count: 64)
    private static let route = URL(string: "https://spark.local:7443")!

    @Test func aTrustedSparkGetsASubscription() {
        let subscription = SparkEventStreamOpening.subscription(
            route: Self.route,
            pin: Self.pin,
            signer: StubSigner(),
            apply: { _ in }
        )

        #expect(subscription != nil)
    }

    @Test func anUnpinnedSparkGetsNoneRatherThanAnUnpinnedStream() {
        #expect(
            SparkEventStreamOpening.subscription(
                route: Self.route,
                pin: nil,
                signer: StubSigner(),
                apply: { _ in }
            ) == nil
        )
        #expect(
            SparkEventStreamOpening.subscription(
                route: Self.route,
                pin: "not-a-fingerprint",
                signer: StubSigner(),
                apply: { _ in }
            ) == nil
        )
    }

    @Test func anUnsignedOrInsecureRouteGetsNoneEither() {
        #expect(
            SparkEventStreamOpening.subscription(
                route: Self.route,
                pin: Self.pin,
                signer: nil,
                apply: { _ in }
            ) == nil
        )
        #expect(
            SparkEventStreamOpening.subscription(
                route: URL(string: "http://spark.local:7443")!,
                pin: Self.pin,
                signer: StubSigner(),
                apply: { _ in }
            ) == nil
        )
    }
}
