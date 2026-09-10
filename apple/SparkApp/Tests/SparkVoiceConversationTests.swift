import Foundation
import SparkAPI
import SparkCore
import Testing

@testable import SparkAppComposition

private struct ConversationStreamer: SparkChatStreaming {
    func stream(target: SparkChatTarget, request: ChatCompletionRequest) async throws
        -> AsyncThrowingStream<ChatStreamEvent, any Error>
    {
        AsyncThrowingStream {
            $0.yield(
                .chunk(
                    id: "voice-conversation",
                    model: target.modelID,
                    delta: "Spoken answer",
                    reasoning: String?.none,
                    finishReason: "stop"
                )
            )
            $0.yield(.done)
            $0.finish()
        }
    }
}

/// One conversational turn end to end, without a microphone or a Spark.
@MainActor
struct SparkVoiceConversationTests {
    private func target() -> SparkVoiceTarget {
        SparkVoiceTarget(
            id: "test",
            displayName: "Test Spark",
            nodeID: SparkNodeID(rawValue: UUID()),
            clusterID: nil,
            route: URL(string: "https://fixture.invalid")!,
            tlsFingerprint: "test",
            authorityFingerprint: "test"
        )
    }

    private func model() -> SparkChatModel {
        SparkChatModel(
            catalogue: SparkChatTargetCatalogue(
                targets: [
                    SparkChatTarget(
                        id: "test",
                        displayName: "Test Spark",
                        nodeID: SparkNodeID(rawValue: UUID()),
                        route: URL(string: "https://fixture.invalid")!,
                        tlsFingerprint: "test",
                        authorityFingerprint: "test",
                        modelID: "test-model",
                        modelName: "Test model"
                    )
                ],
                pairedTargetCount: 1
            ),
            streamer: ConversationStreamer()
        )
    }

    private func session(_ chat: SparkChatModel) -> SparkVoiceSession {
        SparkVoiceSession(
            chat: chat,
            dictationOnly: false,
            conversation: true,
            initialTarget: target()
        )
    }

    @Test func appleVoiceSpeaksTheModelsReplyWithoutCallingKokoro() async {
        let chat = model()
        let voice = SparkVoiceSession(
            chat: chat,
            dictationOnly: false,
            conversation: true,
            initialTarget: target(),
            outputPreference: .device
        )
        voice.deviceSpeechAvailable = { true }
        var spoken = ""
        voice.deviceSpeechOverride = { text in
            spoken = text
            voice.stop()  // End the conversation before any real microphone is opened.
        }
        voice.receive("Tell me about the fabric")
        await voice.work?.value
        #expect(spoken == "Spoken answer")
        #expect(chat.messages.last?.content == "Spoken answer")
        #expect(voice.output == .device)
        #expect(voice.error == nil)
        voice.deviceSpeechOverride = nil
    }

    @Test func appleVoiceCanPrepareWithoutKokoroButStillNeedsMicrophonePermission() async {
        let voice = SparkVoiceSession(
            chat: model(),
            dictationOnly: false,
            conversation: true,
            initialTarget: target(),
            outputPreference: .device
        )
        voice.deviceSpeechAvailable = { true }
        await voice.prepare()
        #expect(voice.output == .device)
        #expect(voice.serviceStatus == nil)
        #expect(voice.error == nil)
        #expect(voice.phase == (voice.permission == .granted ? .ready : .permissionNeeded))
        voice.stop()
    }

    @Test func endOfSpeechSendsOnlyWhatTheOwnerSaidAndNoFillerEverReachesTheModel() async throws {
        let chat = model()
        chat.draft = "A typed line kept for later"
        let voice = session(chat)
        voice.receive("Tell me about the fabric")
        #expect(voice.phase == .heardYou || voice.phase == .thinking)
        #expect(voice.transcript == "Tell me about the fabric")
        await voice.work?.value
        let spoken = chat.messages.map(\.content)
        #expect(spoken.contains("Tell me about the fabric"))
        #expect(spoken.contains("Spoken answer"))
        for content in spoken {
            #expect(!SparkVoiceFillers.pool.contains { content.contains($0.text) })
        }
        #expect(chat.draft == "A typed line kept for later")
    }

    @Test func aFillerHeardBackThroughTheMicrophoneIsNeverSentToTheModel() {
        let chat = model()
        let voice = session(chat)
        voice.receive(SparkVoiceFillers.pool[0].text)
        #expect(chat.messages.isEmpty)
        #expect(voice.transcript.isEmpty)
        #expect(voice.phase != .heardYou)
        #expect(voice.phase != .thinking)
    }

    @Test func aTurnThatCannotBeSpokenSurfacesTheReasonAndKeepsTheChat() async throws {
        let chat = model()
        let voice = session(chat)
        voice.receive("Another question")
        await voice.work?.value
        #expect(voice.phase == .failed)
        #expect(voice.error == SparkVoiceSession.playbackFailure)
        #expect(voice.fillerPhrase == nil)
        #expect(chat.messages.last?.content == "Spoken answer")
    }

    @Test func aDeniedMicrophoneBecomesTheAskRatherThanAnError() {
        let voice = session(model())
        voice.captureFailed(SparkVoiceCapture.Failure.permission(.microphoneDenied))
        #expect(voice.phase == .permissionNeeded)
        #expect(voice.permission == .microphoneDenied)
        #expect(
            SparkVoicePermissionPresentation.notice(for: voice.permission)?.title
                == "Please enable the microphone for SparkPilot"
        )
    }

    @Test func anUnavailableRecogniserIsPresentedAsAPermissionStateNotACrash() {
        let voice = session(model())
        voice.captureFailed(SparkVoiceCapture.Failure.recognitionUnavailable)
        #expect(voice.phase == .permissionNeeded)
        #expect(voice.permission == .speechUnavailable)
    }

    @Test func anAudioFailureIsSurfacedAsCopyRatherThanTakingTheAppDown() {
        let voice = session(model())
        voice.captureFailed(SparkVoiceCapture.Failure.audioUnavailable)
        #expect(voice.phase == .failed)
        #expect(
            voice.error
                == SparkVoiceCaptureFailurePresentation.message(for: .audioUnavailable)
        )
    }

    @Test func stoppingClearsTheFillerAndTheInterruptState() {
        let voice = session(model())
        voice.fillerPhrase = SparkVoiceFillers.pool[0].text
        voice.isBargeInArmed = true
        voice.stop()
        #expect(voice.fillerPhrase == nil)
        #expect(!voice.isBargeInArmed)
        #expect(voice.phase == .needsDownload)
    }

    @Test func dictationKeepsTheTypedDraftAndAddsTheSpokenWords() {
        let chat = model()
        chat.draft = "Half a sentence"
        let voice = SparkVoiceSession(chat: chat, dictationOnly: true)
        voice.receive("and the rest of it")
        #expect(chat.draft == "Half a sentence and the rest of it")
        #expect(voice.didDictate)
    }
}

/// Counts warm-up synthesis calls from any isolation so a cancelled task can be observed.
actor SparkVoiceWarmUpCounter {
    private(set) var count = 0
    func record() { count += 1 }
}

/// BH-33: the filler warm-up must not outlive the screen that started it.
@MainActor
struct SparkVoiceWarmUpLifetimeTests {
    private func session() -> SparkVoiceSession {
        SparkVoiceSession(
            chat: SparkChatModel(
                catalogue: SparkChatTargetCatalogue(targets: [], pairedTargetCount: 0),
                streamer: ConversationStreamer()
            ),
            dictationOnly: false,
            conversation: true,
            fillers: SparkVoiceFillerCache(directory: nil)
        )
    }

    @Test func stoppingTheScreenCancelsTheWarmUpAndReleasesTheSession() async {
        let counter = SparkVoiceWarmUpCounter()
        weak var released: SparkVoiceSession?
        var warmUp: Task<Void, Never>?
        do {
            let voice = session()
            released = voice
            warmUp = voice.startWarmUp(voice: .heart) { _ in
                await counter.record()
                try await Task.sleep(for: .milliseconds(25))
                return Data([0])
            }
            try? await Task.sleep(for: .milliseconds(40))
            voice.stop()
        }
        let atStop = await counter.count
        try? await Task.sleep(for: .milliseconds(250))
        #expect(await counter.count == atStop, "the warm-up kept talking to the Spark")
        #expect(released == nil, "the warm-up kept the voice session alive")
        warmUp?.cancel()
    }

    @Test func aReleasedSessionStopsTheWarmUpWithoutStop() async {
        let counter = SparkVoiceWarmUpCounter()
        var warmUp: Task<Void, Never>?
        do {
            let voice = session()
            warmUp = voice.startWarmUp(voice: .heart) { _ in
                await counter.record()
                try await Task.sleep(for: .milliseconds(25))
                return Data([0])
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        let atRelease = await counter.count
        try? await Task.sleep(for: .milliseconds(250))
        #expect(await counter.count == atRelease, "a dismissed screen kept warming fillers")
        warmUp?.cancel()
    }
}
