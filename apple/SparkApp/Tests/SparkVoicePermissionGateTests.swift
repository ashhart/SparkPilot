import Foundation
import SparkAPI
import SparkCore
import Testing

@testable import SparkAppComposition

/// QA-20: the voice sheet opened at "Ready when you are" with the microphone still unanswered.
@MainActor
struct SparkVoicePermissionGateTests {
    private func chat() -> SparkChatModel {
        SparkChatModel(
            catalogue: SparkChatTargetCatalogue(targets: [], pairedTargetCount: 0),
            streamer: SparkVoiceGateStreamer()
        )
    }

    @Test func anUnansweredMicrophoneIsAskedAboutBeforeDictationSaysItIsReady() {
        #expect(
            SparkVoiceSession.restingPhase(
                permission: .notDetermined,
                listens: true,
                installed: false,
                dictationOnly: true
            ) == .permissionNeeded
        )
    }

    @Test func anUnansweredMicrophoneAlsoComesBeforeAVoiceChatSaysItIsReady() {
        #expect(
            SparkVoiceSession.restingPhase(
                permission: .notDetermined,
                listens: true,
                installed: true,
                dictationOnly: false
            ) == .permissionNeeded
        )
    }

    @Test func aRefusedOrRestrictedMicrophoneIsShownTheSameWay() {
        for state in [
            SparkVoicePermission.microphoneDenied, .speechDenied, .speechRestricted,
            .speechUnavailable,
        ] {
            #expect(
                SparkVoiceSession.restingPhase(
                    permission: state,
                    listens: true,
                    installed: true,
                    dictationOnly: true
                ) == .permissionNeeded,
                "\(state) was allowed to look ready"
            )
        }
    }

    @Test func aGrantedMicrophoneKeepsTheReadyAndInstallPhasesItAlwaysHad() {
        #expect(
            SparkVoiceSession.restingPhase(
                permission: .granted,
                listens: true,
                installed: false,
                dictationOnly: true
            ) == .ready
        )
        #expect(
            SparkVoiceSession.restingPhase(
                permission: .granted,
                listens: true,
                installed: false,
                dictationOnly: false
            ) == .needsDownload
        )
    }

    /// Reading a reply aloud never opens the microphone, so it is never gated on one.
    @Test func aScreenThatOnlySpeaksIsNotHeldUpByTheMicrophone() {
        #expect(
            SparkVoiceSession.restingPhase(
                permission: .notDetermined,
                listens: false,
                installed: true,
                dictationOnly: false
            ) == .ready
        )
        #expect(!SparkVoiceSession.listens(dictationOnly: false, conversation: false))
        #expect(SparkVoiceSession.listens(dictationOnly: true, conversation: false))
        #expect(SparkVoiceSession.listens(dictationOnly: false, conversation: true))
    }

    /// The notice survives the stop that every button on the screen performs first.
    @Test func stoppingDoesNotHandTheOwnerBackAReadyScreenTheyCannotUse() {
        let session = SparkVoiceSession(chat: chat(), dictationOnly: true)
        session.permission = .notDetermined
        session.stop()
        #expect(session.phase == .permissionNeeded)
        session.permission = .granted
        session.stop()
        #expect(session.phase == .ready)
    }

    /// The button on that notice asks for the permission rather than sending them to Settings.
    @Test func theNoticeAsksForTheMicrophoneItself() {
        let notice = SparkVoicePermissionPresentation.notice(for: .notDetermined)
        #expect(notice?.title == "SparkPilot needs your microphone")
        #expect(notice?.actionTitle == "Allow microphone access")
        #expect(notice?.opensSettings == false)
    }
}

private struct SparkVoiceGateStreamer: SparkChatStreaming {
    func stream(target: SparkChatTarget, request: ChatCompletionRequest) async throws
        -> AsyncThrowingStream<ChatStreamEvent, any Error>
    {
        AsyncThrowingStream { $0.finish() }
    }
}
