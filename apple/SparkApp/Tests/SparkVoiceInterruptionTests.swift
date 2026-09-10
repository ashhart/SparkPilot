import Foundation
import SparkAPI
import SparkCore
import Testing

@testable import SparkAppComposition

/// A stream that answers at once, so a voice session can be built without a Spark.
private struct InterruptionStreamer: SparkChatStreaming {
    func stream(target: SparkChatTarget, request: ChatCompletionRequest) async throws
        -> AsyncThrowingStream<ChatStreamEvent, any Error>
    {
        AsyncThrowingStream { $0.finish() }
    }
}

/// BH-46: a phone call must not end voice for good, and the payload decides which way it went.
@MainActor
struct SparkVoiceInterruptionTests {
    private func session() -> SparkVoiceSession {
        SparkVoiceSession(
            chat: SparkChatModel(
                catalogue: SparkChatTargetCatalogue(targets: [], pairedTargetCount: 0),
                streamer: InterruptionStreamer()
            ),
            dictationOnly: false,
            conversation: true,
            fillers: SparkVoiceFillerCache(directory: nil)
        )
    }

    @Test func theNotificationPayloadSaysWhichWayTheInterruptionWent() {
        #expect(
            SparkVoiceInterruption.parse(
                typeRawValue: SparkVoiceInterruption.beganRawValue,
                optionRawValue: nil
            ) == .began
        )
        #expect(
            SparkVoiceInterruption.parse(
                typeRawValue: SparkVoiceInterruption.endedRawValue,
                optionRawValue: SparkVoiceInterruption.shouldResumeRawValue
            ) == .ended(resume: true)
        )
        #expect(
            SparkVoiceInterruption.parse(
                typeRawValue: SparkVoiceInterruption.endedRawValue,
                optionRawValue: 0
            ) == .ended(resume: false)
        )
        #expect(SparkVoiceInterruption.parse(typeRawValue: nil, optionRawValue: 1) == nil)
        #expect(SparkVoiceInterruption.parse(typeRawValue: 97, optionRawValue: nil) == nil)
    }

    @Test func onlyTheStartOfAnInterruptionStopsAndOnlyShouldResumeStartsAgain() {
        #expect(
            SparkVoiceSession.response(
                to: .began,
                phase: .speaking,
                conversation: true,
                wasInterrupted: false
            ) == .stop
        )
        #expect(
            SparkVoiceSession.response(
                to: .began,
                phase: .ready,
                conversation: true,
                wasInterrupted: false
            ) == .ignore
        )
        #expect(
            SparkVoiceSession.response(
                to: .ended(resume: true),
                phase: .ready,
                conversation: true,
                wasInterrupted: true
            ) == .resume
        )
        #expect(
            SparkVoiceSession.response(
                to: .ended(resume: false),
                phase: .ready,
                conversation: true,
                wasInterrupted: true
            ) == .ignore
        )
        #expect(
            SparkVoiceSession.response(
                to: .ended(resume: true),
                phase: .ready,
                conversation: true,
                wasInterrupted: false
            ) == .ignore
        )
    }

    @Test func anEndedInterruptionNeverStopsAVoiceScreenThatWasNotListening() {
        let voice = session()
        voice.phase = .listening
        voice.interrupted(by: .ended(resume: false))
        #expect(voice.phase == .listening, "an ended interruption stopped the turn")
        voice.interrupted(by: .began)
        #expect(voice.phase != .listening)
        #expect(voice.wasInterrupted, "the screen forgot it had been interrupted")
    }
}
