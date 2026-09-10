import Foundation
import SparkAPI
import SparkCore
import Testing

@testable import SparkAppComposition

/// QA-21: a reply already on the device was never spoken, and the reason named the wrong problem.
@MainActor
struct SparkVoiceReadAloudFallbackTests {
    private func chat(paired: Int) -> SparkChatModel {
        SparkChatModel(
            catalogue: SparkChatTargetCatalogue(targets: [], pairedTargetCount: paired),
            streamer: ReadAloudFallbackStreamer()
        )
    }

    // MARK: - Which voice speaks

    @Test func theSparksOwnVoiceSpeaksWhenKokoroIsInstalledAndReachable() {
        #expect(
            SparkVoiceSession.output(
                installed: true,
                hasTarget: true,
                deviceSpeechAvailable: true
            ) == .kokoro
        )
    }

    @Test func thisDeviceSpeaksWhenKokoroCannotBeReached() {
        #expect(
            SparkVoiceSession.output(
                installed: false,
                hasTarget: false,
                deviceSpeechAvailable: true
            ) == .device
        )
        #expect(
            SparkVoiceSession.output(
                installed: false,
                hasTarget: true,
                deviceSpeechAvailable: true
            ) == .device
        )
    }

    @Test func nothingIsPromisedWhenThisDeviceHasNoVoiceEither() {
        #expect(
            SparkVoiceSession.output(
                installed: false,
                hasTarget: true,
                deviceSpeechAvailable: false
            ) == .silent
        )
    }

    @Test func explicitAppleVoiceWinsOverInstalledKokoro() {
        #expect(
            SparkVoiceSession.output(
                installed: true,
                hasTarget: true,
                deviceSpeechAvailable: true,
                preference: .device
            ) == .device
        )
        #expect(
            SparkVoiceSession.output(
                installed: true,
                hasTarget: true,
                deviceSpeechAvailable: false,
                preference: .device
            ) == .silent
        )
    }

    @Test func savingPlaybackChoiceDoesNotConsentToAppleSpeechServers() throws {
        let suite = "voice-preference-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(SparkVoiceOutputPreference.saved(in: defaults) == .spark)
        defaults.set(
            SparkVoiceOutputPreference.device.rawValue,
            forKey: SparkVoiceOutputPreference.key
        )
        #expect(SparkVoiceOutputPreference.saved(in: defaults) == .device)
        #expect(!SparkVoiceRecognitionPolicy.allowsAppleServers(in: defaults))
        defaults.set("unknown", forKey: SparkVoiceOutputPreference.key)
        #expect(SparkVoiceOutputPreference.saved(in: defaults) == .spark)
    }

    // MARK: - Why the Spark's voice is not being used

    @Test func anEmptyFleetIsAskedToPairASpark() {
        #expect(SparkVoiceSession.unavailability(pairedTargetCount: 0) == .noSparkPaired)
        let message = SparkVoiceAvailabilityCopy.message(for: .noSparkPaired)
        #expect(message == "Pair a Spark to install and use Kokoro voice.")
    }

    @Test func aPairedSparkThatIsNotAnsweringIsNotAskedToPairAnother() {
        #expect(SparkVoiceSession.unavailability(pairedTargetCount: 3) == .sparkUnreachable)
        let message = SparkVoiceAvailabilityCopy.message(for: .sparkUnreachable)
        #expect(!message.contains("Pair a Spark"), "\(message)")
        #expect(message.contains("not answering"), "\(message)")
    }

    @Test func everyReasonSaysSomethingDifferent() {
        let messages = SparkVoiceAvailability.allCases.map(SparkVoiceAvailabilityCopy.message(for:))
        #expect(Set(messages).count == messages.count, "\(messages)")
        #expect(messages.allSatisfy { !$0.isEmpty })
    }

    // MARK: - The screen the owner actually gets

    @Test func aReadAloudSheetWithNoReachableSparkStillSpeaks() async {
        let session = SparkVoiceSession(
            chat: chat(paired: 2),
            dictationOnly: false,
            readsAloud: true
        )
        session.deviceSpeechAvailable = { true }
        await session.prepare()
        #expect(session.phase == .ready)
        #expect(session.output == .device)
        #expect(session.voiceUnavailable == .sparkUnreachable)
    }

    @Test func aScreenThatCannotFallBackStillSaysWhyItIsPaused() async {
        let session = SparkVoiceSession(chat: chat(paired: 0), dictationOnly: false)
        session.deviceSpeechAvailable = { true }
        await session.prepare()
        #expect(session.phase == .failed)
        #expect(session.error == SparkVoiceAvailabilityCopy.message(for: .noSparkPaired))
    }

    @Test func theScreenNamesTheVoiceThatWillSpeak() async {
        let kokoro = SparkVoiceSession(
            chat: chat(paired: 1),
            dictationOnly: false,
            readsAloud: true
        )
        kokoro.deviceSpeechAvailable = { false }
        #expect(kokoro.speakingVoiceName == kokoro.voice.name)
        let device = SparkVoiceSession(
            chat: chat(paired: 1),
            dictationOnly: false,
            readsAloud: true
        )
        device.deviceSpeechAvailable = { true }
        await device.prepare()
        #expect(device.output == .device)
        #expect(!device.speakingVoiceName.isEmpty)
        #expect(device.speakingVoiceName != device.voice.name)
    }
}

private struct ReadAloudFallbackStreamer: SparkChatStreaming {
    func stream(target: SparkChatTarget, request: ChatCompletionRequest) async throws
        -> AsyncThrowingStream<ChatStreamEvent, any Error>
    {
        AsyncThrowingStream { $0.finish() }
    }
}

// MARK: - The first read-aloud asks which voice, once

extension SparkVoiceReadAloudFallbackTests {
    @Test func theFirstReadAloudAsksOnceAndRemembersTheAnswer() {
        let defaults = UserDefaults(suiteName: "voice-choice-\(UUID().uuidString)")!
        #expect(!SparkVoiceOutputPreference.hasChosen(in: defaults))
        #expect(
            SparkVoiceOutputPreference.saved(in: defaults) == .spark,
            "Kokoro is the recommendation"
        )

        SparkVoiceOutputPreference.choose(.device, in: defaults)

        #expect(SparkVoiceOutputPreference.hasChosen(in: defaults))
        #expect(SparkVoiceOutputPreference.saved(in: defaults) == .device)

        SparkVoiceOutputPreference.choose(.spark, in: defaults)
        #expect(SparkVoiceOutputPreference.saved(in: defaults) == .spark)
        #expect(
            SparkVoiceOutputPreference.hasChosen(in: defaults),
            "choosing Kokoro is also an answer"
        )
    }
}
