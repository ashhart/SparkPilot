import Foundation
import SparkAPI
import Testing

@testable import SparkAppComposition

@MainActor
@Suite struct SparkEventCursorStoreTests {
    @Test func aNewStoreResumesOnlyTheSamePairingAndCertificate() throws {
        let suite = "SparkEventCursorStoreTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scope = SparkEventCursorStore.scope(identity: "node-a\ndevice-a", pin: "aa")
        SparkEventCursorStore(defaults: defaults).checkpoint("42", for: scope)
        let reopened = SparkEventCursorStore(defaults: defaults)
        #expect(reopened.cursor(for: scope) == "42")
        #expect(reopened.cursor(for: .init(repeating: "0", count: 64)) == nil)
        #expect(
            reopened.cursor(
                for: SparkEventCursorStore.scope(identity: "node-b\ndevice-a", pin: "aa")
            ) == nil
        )
        #expect(
            reopened.cursor(
                for: SparkEventCursorStore.scope(identity: "node-a\ndevice-b", pin: "aa")
            ) == nil
        )
        #expect(
            reopened.cursor(
                for: SparkEventCursorStore.scope(identity: "node-a\ndevice-a", pin: "bb")
            ) == nil
        )
        reopened.checkpoint(nil, for: scope)
        #expect(SparkEventCursorStore(defaults: defaults).cursor(for: scope) == nil)
    }

    @Test func malformedPositionsAreNeverSentOnTheNextConnection() throws {
        let suite = "SparkEventCursorStoreTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SparkEventCursorStore(defaults: defaults)
        let scope = SparkEventCursorStore.scope(identity: "node\ndevice", pin: "aa")
        for invalid in ["-1", "1\nX-Header: forged", "18446744073709551615", "", "1.5"] {
            store.checkpoint("42", for: scope)
            store.checkpoint(invalid, for: scope)
            #expect(store.cursor(for: scope) == nil)
        }
    }

    @Test func onlyTheNewest128PairingsAreRetained() throws {
        let suite = "SparkEventCursorStoreTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var timestamp: TimeInterval = 0
        let store = SparkEventCursorStore(
            defaults: defaults,
            now: {
                timestamp += 1
                return Date(timeIntervalSince1970: timestamp)
            }
        )
        for index in 0..<130 {
            store.checkpoint(
                "42",
                for: SparkEventCursorStore.scope(identity: "node-\(index)", pin: "aa")
            )
        }
        #expect(
            store.cursor(for: SparkEventCursorStore.scope(identity: "node-0", pin: "aa")) == nil
        )
        #expect(
            store.cursor(for: SparkEventCursorStore.scope(identity: "node-129", pin: "aa")) == "42"
        )
    }

    @Test func aPositionIsSavedAfterItsCanonicalRefreshFinishes() async {
        var refreshed = false
        var checkpoints: [String?] = []
        let subscription = SparkEventSubscription(
            open: { _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(.event(.init(sequence: 42, type: "model.ready")))
                    continuation.finish()
                }
            },
            apply: { _ in refreshed = true },
            checkpoint: { cursor in
                #expect(refreshed)
                checkpoints.append(cursor)
            }
        )
        await subscription.run()
        #expect(checkpoints == ["42"])
    }

    @Test func aStoppedRefreshCannotAdvanceTheDurableCursor() async {
        var waiter: CheckedContinuation<Void, Never>?
        var checkpoints: [String?] = []
        let subscription = SparkEventSubscription(
            open: { _ in
                AsyncThrowingStream { continuation in
                    continuation.yield(.event(.init(sequence: 42, type: "model.ready")))
                    continuation.finish()
                }
            },
            apply: { _ in await withCheckedContinuation { waiter = $0 } },
            checkpoint: { checkpoints.append($0) }
        )
        let run = Task { await subscription.run() }
        while waiter == nil { await Task.yield() }
        subscription.stop()
        waiter?.resume()
        await run.value
        #expect(checkpoints.isEmpty)
    }
}
