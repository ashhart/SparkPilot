import Foundation
import SparkCore
import SparkLibrary
import SparkWidgetSupport
import Testing
@testable import SparkAppComposition

struct SparkWidgetTests {
    let date = Date(timeIntervalSince1970: 1_788_520_000)

    @Test @MainActor func widgetSnapshotNamesTheModelReportedByTheSpark() throws {
        let fixture = try chatTestFixtureLibrary()
        let snapshot = SparkWidgetSnapshotBuilder.make(
            library: fixture.library,
            readings: [:],
            isPrivate: false,
            at: fixture.now
        )
        let target = try #require(snapshot.targets.first)
        let encoded = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(target)) as? [String: Any]
        )
        #expect(encoded["activeModelName"] as? String == "Compact 8B")
    }

    @Test @MainActor func unloadingAndFailureClearTheWidgetsModelName() throws {
        for state in ["unloaded", "loading", "unloading", "failed"] {
            let fixture = try chatTestFixtureLibrary(inferenceState: state)
            let snapshot = SparkWidgetSnapshotBuilder.make(
                library: fixture.library,
                readings: [:],
                isPrivate: false,
                at: fixture.now
            )
            #expect(snapshot.targets.first?.activeModelName == nil)
        }
    }

    @Test func anOldWidgetSnapshotStillDecodesAndExpiredStatusHidesItsModel() throws {
        var target = SparkWidgetSnapshot.preview(at: date).targets[0]
        #expect(target.activeModelName(at: date) != nil)
        #expect(target.activeModelName(at: date.addingTimeInterval(1801)) == nil)
        target.isConnected = false
        #expect(target.activeModelName(at: date) == nil)
        var object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(target)) as? [String: Any]
        )
        object.removeValue(forKey: "activeModelName")
        let old = try JSONDecoder().decode(
            SparkWidgetTarget.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        #expect(old.activeModelName == nil)
        #expect(old.name == target.name)
    }

    @Test @MainActor func widgetPublicationDoesNotTurnADelayedReadingIntoAFailedConnection()
        throws
    {
        let library = SparkLibrary(store: MemoryLibraryStore())
        let node = SparkNodeID(rawValue: UUID())
        library.reconcile(
            AuthenticatedTarget(
                nodeID: node,
                clusterID: nil,
                name: "Fixture Spark",
                role: .standalone,
                authorityFingerprint: "fixture",
                displayName: "Fixture Spark",
                routes: [
                    CachedRoute(baseURL: URL(string: "https://fixture.invalid")!, kind: .localWiFi)
                ],
                reachedAt: date
            )
        )
        let later = date.addingTimeInterval(60)
        let entry = try #require(library.entries.first)
        #expect(library.operationalSnapshot(for: entry.id, at: later)?.connectionState == .delayed)
        let recent = SparkWidgetSnapshotBuilder.make(
            library: library,
            readings: [:],
            isPrivate: false,
            at: later
        )
        #expect(recent.targets.first?.isConnected(at: later) == true)
        #expect(recent.targets.first?.connection == "Connected over Wi-Fi")
        library.markUnreachable(entryID: entry.id, at: later)
        let failed = SparkWidgetSnapshotBuilder.make(
            library: library,
            readings: [:],
            isPrivate: false,
            at: later
        )
        #expect(failed.targets.first?.isConnected(at: later) == false)
    }

    @Test func widgetConnectionRemainsValidBetweenBackgroundRefreshesThenExpires() {
        let target = SparkWidgetSnapshot.preview(at: date).targets[0]
        #expect(target.isConnected(at: date.addingTimeInterval(32)))
        #expect(target.isConnected(at: date.addingTimeInterval(15 * 60)))
        #expect(target.isConnected(at: date.addingTimeInterval(30 * 60)))
        #expect(!target.isConnected(at: date.addingTimeInterval(30 * 60 + 1)))
    }

    @Test func failedOrMissingConnectionNeverShowsConnectedDespiteFreshMemory() {
        var target = SparkWidgetSnapshot.preview(at: date).targets[0]
        target.isConnected = false
        #expect(!target.isConnected(at: date))
        target.isConnected = true
        target.observedAt = nil
        #expect(!target.isConnected(at: date))
        target.observedAt = date.addingTimeInterval(61)
        #expect(!target.isConnected(at: date))
    }

    @Test func oldMemoryDoesNotHideARecentlyConfirmedConnection() {
        var target = SparkWidgetSnapshot.preview(at: date).targets[0]
        target.nodes[0].observedAt = date.addingTimeInterval(-3600)
        #expect(target.isConnected(at: date))
        #expect(!SparkWidgetFreshness.isRecent(target.nodes[0].observedAt, at: date))
    }

    @Test func widgetShowsInstalledSparkCapacityWithoutChangingMeasuredUsage() {
        let memory = SparkWidgetMemory(nodes: [
            SparkWidgetNode(
                id: "spark",
                name: "DGX Spark",
                totalBytes: 130_600_000_000,
                availableBytes: 123_890_000_000,
                observedAt: date
            )
        ])
        #expect(memory.totalBytes == 128_000_000_000)
        #expect(memory.usedBytes == 6_710_000_000)
        #expect(memory.fraction == Double(6_710_000_000) / Double(128_000_000_000))
    }

    @Test func widgetNormalisesEachPhysicalSparkBeforeSummingClusterCapacity() {
        let nodes = ["one", "two"].map { id in
            SparkWidgetNode(
                id: id,
                name: id,
                totalBytes: 130_600_000_000,
                availableBytes: 123_890_000_000,
                observedAt: date
            )
        }
        let memory = SparkWidgetMemory(nodes: nodes + [nodes[0]])
        #expect(memory.totalBytes == 256_000_000_000)
        #expect(memory.usedBytes == 13_420_000_000)
        #expect(memory.reporting == 2)
        #expect(memory.expected == 2)
    }

    @Test func widgetAndAppAgreeOnInstalledCapacityAndPreserveUnknownSizes() {
        for reported: Int64 in [0, 999, 128_000_000_000, 130_595_094_528, .max] {
            #expect(
                SparkInstalledMemoryCapacity.installedBytes(reportedBytes: reported)
                    == SparkMemoryCapacity.installedBytes(reportedBytes: reported)
            )
        }
        #expect(SparkInstalledMemoryCapacity.installedBytes(reportedBytes: 999) == 999)
    }

    @Test func clusterMemoryCountsPhysicalNodesOnceAndKeepsPartialCoverage() {
        let older = SparkWidgetNode(
            id: "one",
            name: "Old",
            totalBytes: 100,
            availableBytes: 20,
            observedAt: date.addingTimeInterval(-60)
        )
        let newest = SparkWidgetNode(
            id: "one",
            name: "New",
            totalBytes: 100,
            availableBytes: 40,
            observedAt: date
        )
        let missing = SparkWidgetNode(id: "two", name: "Offline")
        let memory = SparkWidgetMemory(nodes: [older, newest, missing])
        #expect(memory.totalBytes == 100)
        #expect(memory.usedBytes == 60)
        #expect(memory.expected == 2)
        #expect(memory.reporting == 1)
        #expect(memory.observedAt == date)
    }

    @Test func invalidUnknownAndOverflowingMemoryNeverBecomesZeroOrAFullClusterTotal() {
        let invalid = SparkWidgetNode(
            id: "bad",
            name: "Bad",
            totalBytes: 100,
            availableBytes: 101,
            observedAt: date
        )
        let missing = SparkWidgetMemory(nodes: [invalid])
        #expect(missing.totalBytes == nil)
        #expect(missing.usedBytes == nil)
        #expect(missing.reporting == 0)
        let huge = SparkWidgetMemory(nodes: [
            SparkWidgetNode(
                id: "a",
                name: "A",
                totalBytes: .max,
                availableBytes: 0,
                observedAt: date
            ),
            SparkWidgetNode(
                id: "b",
                name: "B",
                totalBytes: .max,
                availableBytes: 0,
                observedAt: date
            ),
        ])
        #expect(huge.totalBytes == nil)
        #expect(huge.fraction == nil)
    }

    @Test func clusterFreshnessUsesOldestContributingReading() {
        let memory = SparkWidgetMemory(nodes: [
            SparkWidgetNode(
                id: "a",
                name: "A",
                totalBytes: 100,
                availableBytes: 50,
                observedAt: date
            ),
            SparkWidgetNode(
                id: "b",
                name: "B",
                totalBytes: 100,
                availableBytes: 10,
                observedAt: date.addingTimeInterval(-600)
            ),
        ])
        #expect(memory.observedAt == date.addingTimeInterval(-600))
        #expect(memory.totalBytes == 200)
    }

    @Test func sharedSnapshotClearsRemovedTargetsAndAppLockRemovesTheirData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("widgets.json")
        let preview = SparkWidgetSnapshot.preview(at: date)
        #expect(try SparkWidgetStore.write(preview, to: url))
        #expect(SparkWidgetStore.read(from: url) == preview)
        #expect(try !SparkWidgetStore.write(preview, to: url))
        let locked = SparkWidgetSnapshot(targets: preview.targets, isPrivate: true)
        #expect(try SparkWidgetStore.write(locked, to: url))
        #expect(SparkWidgetStore.read(from: url).targets.isEmpty)
        #expect(try !String(contentsOf: url, encoding: .utf8).contains("Desk Spark"))
        #expect(try SparkWidgetStore.write(.empty, to: url))
        #expect(SparkWidgetStore.read(from: url) == .empty)
        try Data("{\"version\":99,\"isPrivate\":false,\"targets\":[]}".utf8).write(to: url)
        #expect(SparkWidgetStore.read(from: url) == .empty)
    }

    @Test func widgetLinksRoundTripExactTargetAndRejectAmbiguousOrForeignURLs() {
        var target = SparkWidgetSnapshot.preview(at: date).targets[0]
        target.id = "cluster:AA-BB & /?#"
        #expect(SparkWidgetSnapshot.targetID(from: target.url) == target.id)
        for raw in [
            "https://widget?target=all", "sparkpilot://widget?target=a&target=b",
            "sparkpilot://widget/path?target=a", "sparkpilot://widget?target=",
            "sparkpilot://user@widget?target=a", "sparkpilot://widget?target=a#b",
        ] {
            #expect(SparkWidgetSnapshot.targetID(from: URL(string: raw)!) == nil)
        }
    }
}

#if os(macOS)
    import AppKit
    import SwiftUI

    extension SparkWidgetTests {
        @Test @MainActor func renderCapturedWidgetForQA() throws {
            guard let folder = ProcessInfo.processInfo.environment["SPARK_WIDGET_QA_DIRECTORY"],
                let snapshotPath = ProcessInfo.processInfo.environment["SPARK_WIDGET_SNAPSHOT_FILE"]
            else { return }
            let snapshot = SparkWidgetStore.read(from: URL(fileURLWithPath: snapshotPath))
            #expect(!snapshot.targets.isEmpty)
            let content = SparkWidgetCard(snapshot: snapshot, size: .medium, date: Date())
                .padding(16).frame(width: 360, height: 170)
                .background(Color.white)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 3
            let cg = try #require(renderer.cgImage)
            let png = try #require(
                NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
            )
            try png.write(
                to: URL(fileURLWithPath: folder).appendingPathComponent("captured-widget.png")
            )
        }

        @Test @MainActor func renderWidgetLayoutsForQA() throws {
            guard let folder = ProcessInfo.processInfo.environment["SPARK_WIDGET_QA_DIRECTORY"]
            else { return }
            let date = Date()
            var offline = SparkWidgetSnapshot.preview(at: date)
            offline.targets[0].isConnected = false
            let samples:
                [(
                    String, SparkWidgetSnapshot, SparkWidgetCardSize, CGFloat, CGFloat, Bool,
                    ColorScheme
                )] = [
                    ("small-light", .preview(at: date), .small, 170, 170, false, .light),
                    ("medium-light", .preview(at: date), .medium, 360, 170, false, .light),
                    ("offline", offline, .medium, 360, 170, false, .light),
                    (
                        "expired", .preview(at: date.addingTimeInterval(-1801)), .medium, 360,
                        170, false, .light
                    ),
                    ("large-dark", .preview(at: date), .large, 360, 380, true, .dark),
                    ("ipad-extra-large", .preview(at: date), .extraLarge, 720, 380, false, .light),
                    ("empty", .empty, .small, 170, 170, false, .light),
                    ("private", .init(isPrivate: true), .medium, 360, 170, false, .dark),
                ]
            for (name, snapshot, size, width, height, memory, scheme) in samples {
                let content = SparkWidgetCard(
                    snapshot: snapshot,
                    memoryOnly: memory,
                    size: size,
                    date: date
                )
                .padding(16).frame(width: width, height: height)
                .background(scheme == .dark ? Color.black : Color.white)
                .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                let cg = try #require(renderer.cgImage)
                let png = try #require(
                    NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
                )
                try png.write(
                    to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png")
                )
            }
        }
    }
#endif

/// §2.5: a reading the widget could not refresh says how old it is instead of looking current.
@Test func aStaleWidgetMemoryReadingSaysHowOldItIs() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let fresh = now.addingTimeInterval(-60)
    let old = now.addingTimeInterval(-SparkWidgetFreshness.maximumAge - 3600)

    #expect(SparkWidgetFreshness.isRecent(fresh, at: now))
    #expect(!SparkWidgetFreshness.isRecent(old, at: now))
    #expect(String(localized: .widgetLastChecked("1 hour")).contains("1 hour"))
    #expect(String(localized: .widgetLastChecked("1 hour")).hasPrefix("Last checked"))
}

/// BH-55: a Spark that answered is connected, even when no route kind was recorded for it.
@Suite struct SparkWidgetRouteKindTests {
    let date = Date(timeIntervalSince1970: 1_788_520_000)

    @Test @MainActor func aReachableSparkWithNoRouteKindIsNotDrawnAsOffline() throws {
        let library = SparkLibrary(store: MemoryLibraryStore())
        let node = SparkNodeID(rawValue: UUID())
        let seen = AuthenticatedTarget(
            nodeID: node,
            clusterID: nil,
            name: "Routeless Spark",
            role: .standalone,
            authorityFingerprint: "fixture",
            displayName: "Routeless Spark",
            routes: [],
            reachedAt: date
        )
        // A Spark answers again on an interface this device cannot record a route for.
        library.reconcile(seen)
        library.reconcile(seen)
        let entry = try #require(library.entries.first)
        #expect(entry.preferredRoute == nil, "the fixture is meant to have no recorded route")
        #expect(entry.members.first?.reachable == true, "the fixture is meant to be reachable")
        let snapshot = SparkWidgetSnapshotBuilder.make(
            library: library,
            readings: [:],
            isPrivate: false,
            at: date
        )
        let target = try #require(snapshot.targets.first)
        #expect(target.isConnected, "a Spark that answered was drawn as offline")
        #expect(target.connection != "Offline · showing saved state")
    }

    @Test @MainActor func aSparkThatDidNotAnswerIsStillDrawnAsOffline() throws {
        let library = SparkLibrary(store: MemoryLibraryStore())
        let node = SparkNodeID(rawValue: UUID())
        library.reconcile(
            AuthenticatedTarget(
                nodeID: node,
                clusterID: nil,
                name: "Quiet Spark",
                role: .standalone,
                authorityFingerprint: "fixture",
                displayName: "Quiet Spark",
                routes: [
                    CachedRoute(baseURL: URL(string: "https://fixture.invalid")!, kind: .localWiFi)
                ],
                reachedAt: date
            )
        )
        let entry = try #require(library.entries.first)
        library.markUnreachable(entryID: entry.id, at: date)
        let snapshot = SparkWidgetSnapshotBuilder.make(
            library: library,
            readings: [:],
            isPrivate: false,
            at: date
        )
        let target = try #require(snapshot.targets.first)
        #expect(!target.isConnected)
        #expect(target.connection == "Offline · showing saved state")
    }
}
