import Foundation
@_spi(SparkTestSupport) import SparkAPI
import SparkBootstrap
import SparkCore
import SparkDesignSystem
import SparkDiscovery
import SparkLibrary
import SparkSecurity
@_spi(SparkTestSupport) import SparkTransport
import Testing
@testable import SparkAppComposition

// MARK: - Activity failure reasons

/// Show an operation's actionable failure reason.
@Test func activityNamesWhyAnOperationFailed() {
    #expect(
        OperationPresentation.failureText("MODEL_INSUFFICIENT_MEMORY")
            == "the profile did not fit in memory"
    )
    #expect(
        OperationPresentation.failureText("MODEL_PROFILE_UNSAFE")
            == "the profile is disabled after a memory event"
    )
    // An unknown code remains visible, so support can identify a new failure.
    let unknown = OperationPresentation.failureText("SOME_NEW_RUNTIME_CODE")
    #expect(unknown == "the Spark reported SOME_NEW_RUNTIME_CODE")
}

// MARK: - Activity provenance

/// Preserve the server's operation timestamps and actor identity for Activity.
@Test func activityCardsCarryTheSparksTimestampsAndActor() {
    let thisDevice = UUID()
    let created = Date(timeIntervalSince1970: 1_000_000)
    let snapshot = TargetOperationSnapshot(
        id: SparkOperationID(rawValue: UUID()),
        kind: "model.load",
        state: .succeeded,
        progress: nil,
        stage: "ready",
        errorCode: nil,
        cancellable: false,
        createdAt: created,
        startedAt: created.addingTimeInterval(2),
        completedAt: created.addingTimeInterval(185),
        actorDeviceID: thisDevice.uuidString.lowercased()
    )
    let cards = AppleNavigationPlan.activityCards(
        for: [snapshot],
        targetName: "example-spark",
        localDeviceID: thisDevice
    )
    let card = try! #require(cards.first)
    #expect(card.timestamp == created.addingTimeInterval(185))
    #expect(card.duration == 183)
    #expect(card.origin == .thisDevice)

    // Ten minutes after it finished.
    let line = try! #require(
        OperationPresentation.provenanceText(card, now: created.addingTimeInterval(785))
    )
    #expect(line == "Completed 10 minutes ago · took 3m 3s · from here")
}

/// Identify work started from another paired device.
@Test func activityTellsAnotherDevicesJobApart() {
    let snapshot = TargetOperationSnapshot(
        id: SparkOperationID(rawValue: UUID()),
        kind: "model.install",
        state: .running,
        progress: 0.4,
        stage: "downloading",
        errorCode: nil,
        cancellable: true,
        createdAt: Date(timeIntervalSince1970: 2_000_000),
        startedAt: Date(timeIntervalSince1970: 2_000_000),
        completedAt: nil,
        actorDeviceID: UUID().uuidString.lowercased()
    )
    let card = try! #require(
        AppleNavigationPlan.activityCards(
            for: [snapshot],
            targetName: "example-spark",
            localDeviceID: UUID()
        ).first
    )
    #expect(card.origin == .anotherDevice)
    // A running job reports no duration, only when it started.
    #expect(card.duration == nil)
    let line = try! #require(
        OperationPresentation.provenanceText(
            card,
            now: Date(timeIntervalSince1970: 2_000_000).addingTimeInterval(3_600)
        )
    )
    // Assert surrounding catalogue sentences here while compiled-bundle tests verify plural grammar.
    #expect(line.hasPrefix("Started 1 hour"))
    #expect(line.hasSuffix(" · from another device"))
}

/// Missing timestamps and actor identities must remain absent in cached Activity.
@Test func activityOmitsProvenanceItDoesNotHave() {
    let snapshot = TargetOperationSnapshot(
        id: SparkOperationID(rawValue: UUID()),
        kind: "model.load",
        state: .succeeded,
        progress: nil,
        stage: "ready",
        errorCode: nil,
        cancellable: false
    )
    let card = try! #require(AppleNavigationPlan.activityCards(for: [snapshot]).first)
    #expect(card.timestamp == nil)
    #expect(card.origin == nil)
    #expect(OperationPresentation.provenanceText(card, now: Date()) == nil)
}

/// Clamp clock skew and test elapsed-time units; the compiled-bundle matrix verifies plural grammar.
@Test func activityWordsElapsedTimeInBuckets() {
    let now = Date(timeIntervalSince1970: 3_000_000)
    func ago(_ seconds: TimeInterval) -> String {
        OperationPresentation.relativeTime(now.addingTimeInterval(-seconds), now: now)
    }
    #expect(ago(-45) == "just now")  // 45 seconds into the future.
    #expect(ago(5) == "just now")
    #expect(ago(60).hasPrefix("1 minute"))
    #expect(ago(3_540) == "59 minutes ago")
    #expect(ago(3_600).hasPrefix("1 hour"))
    #expect(ago(86_400).hasPrefix("1 day"))
    #expect(ago(3 * 86_400) == "3 days ago")
    #expect(ago(10 * 86_400).hasPrefix("1 week"))
    #expect(ago(60 * 86_400) == "2 months ago")
    #expect(ago(400 * 86_400).hasPrefix("1 year"))

    #expect(OperationPresentation.durationText(0.4) == "1s")
    #expect(OperationPresentation.durationText(59) == "59s")
    #expect(OperationPresentation.durationText(120) == "2m")
    #expect(OperationPresentation.durationText(3_600) == "1h")
    #expect(OperationPresentation.durationText(3_720) == "1h 2m")
}

/// Map every runtime operation kind to a readable Activity title.
@Test func activityNamesEveryOperationKindItMeets() {
    #expect(OperationPresentation.title(kind: "model.load") == "Loading model")
    #expect(
        OperationPresentation.title(kind: "system.software_update_check")
            == "Checking for updates"
    )
    #expect(
        OperationPresentation.title(kind: "system.software_updates")
            == "Installing system updates"
    )
    #expect(OperationPresentation.title(kind: "project.create") == "Creating project")

    // An unknown kind is words, never the identifier and never "Operation".
    let unknown = OperationPresentation.title(kind: "cluster.rebalance_shards")
    #expect(unknown == "Cluster rebalance shards")
    #expect(!unknown.contains("."))
    #expect(!unknown.contains("_"))

    // An empty kind has no words to make, so the generic label stands.
    #expect(OperationPresentation.title(kind: "") == "Operation")
}

func activityTimelineTestEntry(
    name: String,
    instant: Date
) -> LibraryEntry {
    let nodeID = SparkNodeID(rawValue: UUID())
    let snapshot = dashboardTestDashboardCachedSnapshot(at: instant)
    let operation = TargetOperationSnapshot(
        id: SparkOperationID(rawValue: UUID()),
        kind: "model.install",
        state: .running,
        progress: 0.4,
        stage: "downloading",
        errorCode: nil,
        cancellable: true,
        createdAt: instant,
        startedAt: instant
    )
    return LibraryEntry(
        logicalKey: .node(nodeID),
        name: name,
        members: [
            LibraryMember(
                nodeID: nodeID,
                name: name,
                role: .standalone,
                authorityFingerprint: "authority",
                routes: [],
                lastSeen: instant,
                reachable: true
            )
        ],
        connectionState: .connectedWiFi,
        lastSeen: instant,
        cachedAt: instant,
        cachedOperationalSnapshot: TargetOperationalSnapshot(
            identity: snapshot.identity,
            displayName: name,
            members: snapshot.members,
            preferredRoute: snapshot.preferredRoute,
            connectionState: snapshot.connectionState,
            lastSuccessfulContact: snapshot.lastSuccessfulContact,
            evaluatedAt: snapshot.evaluatedAt,
            evidence: snapshot.evidence,
            runtime: snapshot.runtime,
            vllmHealth: snapshot.vllmHealth,
            unifiedMemory: snapshot.unifiedMemory,
            disk: snapshot.disk,
            installedModelCount: snapshot.installedModelCount,
            activeInference: snapshot.activeInference,
            operations: [operation],
            placements: snapshot.placements,
            warnings: snapshot.warnings,
            blockers: snapshot.blockers,
            technicalDetails: snapshot.technicalDetails
        )
    )
}

@MainActor
@Test func theActivityTimelineIsOneChronologicalListAcrossEverySpark() {
    let older = activityTimelineTestEntry(
        name: "Desk Spark",
        instant: Date(timeIntervalSince1970: 100)
    )
    let newer = activityTimelineTestEntry(
        name: "Studio Spark",
        instant: Date(timeIntervalSince1970: 500)
    )
    let cards = AppleNavigationPlan.activityTimeline(for: [older, newer])

    #expect(cards.count == 2)
    #expect(cards.first?.targetName == "Studio Spark")
    #expect(cards.last?.targetName == "Desk Spark")
}
