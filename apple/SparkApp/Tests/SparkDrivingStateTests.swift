import Foundation
import Testing

@testable import SparkAppComposition

/// The keyboard gate decides from the car, never from a guess about the owner.
struct SparkDrivingStateTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func signals(
        connected: Bool = true,
        restricted: Bool = false,
        speed: Double? = nil,
        after seconds: TimeInterval = 0
    ) -> SparkDrivingSignals {
        SparkDrivingSignals(
            carPlayConnected: connected,
            keyboardRestrictedByCar: restricted,
            speedMetersPerSecond: speed,
            observedAt: start.addingTimeInterval(seconds)
        )
    }

    @Test func withoutACarNothingChanges() {
        var reducer = SparkDrivingStateReducer()
        #expect(reducer.apply(signals(connected: false, speed: 30)) == .notDriving)
        #expect(reducer.apply(signals(connected: false, restricted: true)) == .notDriving)
    }

    @Test func theCarsOwnRestrictionWinsOverAnySpeed() {
        var reducer = SparkDrivingStateReducer()
        #expect(reducer.apply(signals(restricted: true, speed: 0)) == .moving)
    }

    @Test func movingAboveTheThresholdPausesTyping() {
        var reducer = SparkDrivingStateReducer()
        #expect(reducer.apply(signals(speed: 0)) == .parked)
        #expect(reducer.apply(signals(speed: 5, after: 1)) == .moving)
    }

    @Test func aRedLightDoesNotBringTheKeyboardBackAtOnce() {
        var reducer = SparkDrivingStateReducer()
        reducer.apply(signals(speed: 12))
        #expect(reducer.apply(signals(speed: 0, after: 1)) == .moving)
        #expect(reducer.apply(signals(speed: 0, after: 4)) == .moving)
        #expect(reducer.apply(signals(speed: 0, after: 8)) == .parked)
    }

    @Test func creepingBetweenThresholdsKeepsTheLastDecision() {
        var reducer = SparkDrivingStateReducer()
        reducer.apply(signals(speed: 12))
        #expect(reducer.apply(signals(speed: 1.0, after: 1)) == .moving)
        reducer.apply(signals(speed: 0, after: 2))
        reducer.apply(signals(speed: 0, after: 10))
        #expect(reducer.mode == .parked)
        #expect(reducer.apply(signals(speed: 1.0, after: 11)) == .parked)
    }

    @Test func connectedWithNoSpeedAtAllIsParkedNotTrapped() {
        var reducer = SparkDrivingStateReducer()
        #expect(reducer.apply(signals()) == .parked)
        reducer.apply(signals(speed: 12, after: 1))
        #expect(reducer.apply(signals(after: 5)) == .moving)
        #expect(reducer.apply(signals(after: 40)) == .moving)
        #expect(reducer.apply(signals(speed: 0, after: 41)) == .moving)
        #expect(reducer.apply(signals(speed: 0, after: 48)) == .parked)
    }

    @Test func disconnectingClearsEverything() {
        var reducer = SparkDrivingStateReducer()
        reducer.apply(signals(speed: 12))
        #expect(reducer.apply(signals(connected: false, after: 1)) == .notDriving)
        #expect(reducer.apply(signals(speed: 0, after: 2)) == .parked)
    }

    @MainActor @Test func theBridgeTurnsAModeIntoATypingRestriction() {
        let bridge = SparkCarPlayBridge()
        #expect(bridge.typingRestriction == .none)
        bridge.carPlayConnected(true, at: start)
        #expect(bridge.typingRestriction == .parkedHint)
        bridge.observe(signals(speed: 9, after: 1))
        #expect(bridge.typingRestriction == .paused)
        #expect(bridge.typingRestriction.isPaused)
        bridge.carPlayConnected(false, at: start.addingTimeInterval(2))
        #expect(bridge.typingRestriction == .none)
    }
}
