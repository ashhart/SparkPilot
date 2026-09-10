import Testing

@testable import SparkAppComposition

/// Every threshold lives in SparkVoiceTurnTiming and the clock is the caller's, so a turn replays.
struct SparkVoiceTurnTests {
    private let loud = SparkVoiceTurnTiming.speechLevel + 0.1
    private let quiet = SparkVoiceTurnTiming.speechLevel - 0.05

    private func drive(
        _ detector: inout SparkVoiceTurnDetector,
        level: Double,
        from start: Double,
        to end: Double,
        step: Double = 0.1
    ) -> SparkVoiceTurnDetector.Outcome {
        var outcome = SparkVoiceTurnDetector.Outcome.waiting
        var now = start
        while now <= end + 1e-9 {
            outcome = detector.observe(level: level, at: now)
            if outcome != .waiting, outcome != .hearing { return outcome }
            now += step
        }
        return outcome
    }

    @Test func aNaturalPauseInsideASentenceDoesNotEndTheTurn() {
        var detector = SparkVoiceTurnDetector()
        #expect(drive(&detector, level: loud, from: 0, to: 0.9) == .hearing)
        let pause = drive(&detector, level: quiet, from: 1.0, to: 1.0 + 1.1)
        #expect(pause == .waiting || pause == .hearing)
        #expect(drive(&detector, level: loud, from: 2.2, to: 2.6) == .hearing)
    }

    @Test func aFullPauseAfterEnoughSpeechEndsTheTurn() {
        var detector = SparkVoiceTurnDetector()
        #expect(drive(&detector, level: loud, from: 0, to: 1.2) == .hearing)
        #expect(drive(&detector, level: quiet, from: 1.3, to: 4.0) == .endOfTurn)
    }

    @Test func aShortNoiseBurstIsNotATurn() {
        var detector = SparkVoiceTurnDetector()
        #expect(drive(&detector, level: loud, from: 0, to: 0.3) == .hearing)
        let outcome = drive(&detector, level: quiet, from: 0.4, to: 6.0)
        #expect(outcome == .waiting)
    }

    @Test func silenceThroughoutGivesUpRatherThanHangingForever() {
        var detector = SparkVoiceTurnDetector()
        let outcome = drive(
            &detector,
            level: quiet,
            from: 0,
            to: SparkVoiceTurnTiming.noSpeechTimeout + 1
        )
        #expect(outcome == .heardNothing)
    }

    @Test func anEndlessTurnIsCutAtTheHardLimit() {
        var detector = SparkVoiceTurnDetector()
        let outcome = drive(
            &detector,
            level: loud,
            from: 0,
            to: SparkVoiceTurnTiming.maximumTurn + 1,
            step: 0.25
        )
        #expect(outcome == .tooLong)
    }

    @Test func theTurnConstantsStayInsideTheTunedBand() {
        #expect(SparkVoiceTurnTiming.endOfTurnSilence >= 1.2)
        #expect(SparkVoiceTurnTiming.endOfTurnSilence <= 1.6)
        #expect(SparkVoiceTurnTiming.minimumSpeech >= 0.6)
        #expect(SparkVoiceTurnTiming.fillerDelay <= 0.3)
        #expect(SparkVoiceTurnTiming.bargeInLevel > SparkVoiceTurnTiming.speechLevel)
    }

    @Test func bargeInNeedsSustainedSpeechNotOneLoudSample() {
        var listener = SparkVoiceBargeInDetector()
        let firstSample = listener.observe(level: SparkVoiceTurnTiming.bargeInLevel + 0.1, at: 0)
        #expect(!firstSample)
        let silence = listener.observe(level: 0, at: 0.1)
        #expect(!silence)
        var now = 1.0
        var interrupted = false
        while now <= 1.0 + SparkVoiceTurnTiming.bargeInSpeech + 0.2 {
            interrupted = listener.observe(level: SparkVoiceTurnTiming.bargeInLevel + 0.1, at: now)
            if interrupted { break }
            now += 0.05
        }
        #expect(interrupted)
    }

    @Test func aReusedDetectorForgetsThePreviousTurn() {
        var detector = SparkVoiceTurnDetector()
        _ = drive(&detector, level: loud, from: 0, to: 1.2)
        #expect(drive(&detector, level: quiet, from: 1.3, to: 4.0) == .endOfTurn)
        detector.reset()
        #expect(drive(&detector, level: quiet, from: 10, to: 12) == .waiting)
    }
}
