import Foundation
import SparkWidgetSupport
import Testing

struct SparkDownloadActivityTests {
    @Test(arguments: [-0.1, 1.1, Double.infinity, Double.nan])
    func invalidProgressStaysUnknown(_ progress: Double) {
        let state = SparkDownloadActivityState(
            phase: .downloading,
            progress: progress,
            observedAt: Date()
        )
        #expect(state.progress == nil)
    }

    @Test func stalledUpdatesAskForRefreshWithoutInventingFailure() {
        let observed = Date(timeIntervalSince1970: 1_800_000_000)
        let state = SparkDownloadActivityState(
            phase: .downloading,
            progress: 0.4,
            observedAt: observed
        )
        #expect(state.staleAt == observed.addingTimeInterval(30))
        #expect(state.title(isStale: true) == "Open SparkPilot to refresh")
        #expect(!state.isTerminal)
        #expect(state.systemImage(isStale: true) == "clock")
    }

    @Test func terminalEvidenceDoesNotRegressIntoStaleProgress() {
        let success = SparkDownloadActivityState(
            phase: .succeeded,
            progress: 0.9,
            observedAt: Date()
        )
        #expect(success.progress == 1)
        #expect(success.title(isStale: true) == "Model installed")
        let failure = SparkDownloadActivityState(phase: .failed, progress: 0.9, observedAt: Date())
        #expect(failure.progress == nil)
        #expect(failure.systemImage(isStale: true) == "exclamationmark.triangle")
    }

    @Test func lockScreenContentUsesOnlyTheDisplayAllowlist() throws {
        let state = SparkDownloadActivityState(
            phase: .downloading,
            progress: 0.4,
            observedAt: Date()
        )
        let encoded = try JSONEncoder().encode(state)
        let fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(Set(fields.keys) == ["phase", "progress", "observedAt"])
    }
}
