import Testing

@testable import SparkAppComposition

/// A tap format that disagrees with the hardware is an uncatchable crash, so Swift decides first.
struct SparkVoiceAudioTests {
    @Test func aSilentSessionFormatIsRejectedRatherThanTapped() {
        #expect(!SparkVoiceAudioFormat.isUsable(sampleRate: 0, channelCount: 0))
        #expect(!SparkVoiceAudioFormat.isUsable(sampleRate: 48_000, channelCount: 0))
        #expect(!SparkVoiceAudioFormat.isUsable(sampleRate: 0, channelCount: 1))
    }

    @Test func anAbsurdSampleRateIsRejected() {
        #expect(!SparkVoiceAudioFormat.isUsable(sampleRate: .nan, channelCount: 1))
        #expect(!SparkVoiceAudioFormat.isUsable(sampleRate: .infinity, channelCount: 1))
        #expect(!SparkVoiceAudioFormat.isUsable(sampleRate: -48_000, channelCount: 1))
        #expect(!SparkVoiceAudioFormat.isUsable(sampleRate: 1_000, channelCount: 1))
        #expect(!SparkVoiceAudioFormat.isUsable(sampleRate: 1_000_000, channelCount: 1))
    }

    @Test func theFormatsRealHardwareReportsAreAccepted() {
        #expect(SparkVoiceAudioFormat.isUsable(sampleRate: 48_000, channelCount: 1))
        #expect(SparkVoiceAudioFormat.isUsable(sampleRate: 44_100, channelCount: 2))
        #expect(SparkVoiceAudioFormat.isUsable(sampleRate: 16_000, channelCount: 1))
        #expect(SparkVoiceAudioFormat.isUsable(sampleRate: 8_000, channelCount: 1))
    }

    @Test func aChannelCountNoTapCanHandleIsRejected() {
        #expect(!SparkVoiceAudioFormat.isUsable(sampleRate: 48_000, channelCount: 33))
    }

    @Test func theTapBufferIsSizedForTheHardwareRate() {
        #expect(SparkVoiceAudioFormat.tapBufferSize(sampleRate: 48_000) >= 1_024)
        #expect(SparkVoiceAudioFormat.tapBufferSize(sampleRate: 8_000) >= 256)
        #expect(SparkVoiceAudioFormat.tapBufferSize(sampleRate: 48_000) <= 8_192)
    }

    @Test func anUnusableFormatBecomesASurfacedFailureNotACrash() {
        let failure = SparkVoiceCapture.Failure.audioUnavailable
        #expect(SparkVoiceCaptureFailurePresentation.message(for: failure).isEmpty == false)
        #expect(
            SparkVoiceCaptureFailurePresentation.message(for: .noSpeech)
                != SparkVoiceCaptureFailurePresentation.message(for: failure)
        )
    }

    @Test func levelFromSamplesIsBoundedAndSilenceReadsAsZero() {
        #expect(SparkVoiceAudioFormat.level(rootMeanSquare: 0) == 0)
        #expect(SparkVoiceAudioFormat.level(rootMeanSquare: 1) == 1)
        #expect(SparkVoiceAudioFormat.level(rootMeanSquare: 4) == 1)
        #expect(SparkVoiceAudioFormat.level(rootMeanSquare: .nan) == 0)
        let quiet = SparkVoiceAudioFormat.level(rootMeanSquare: 0.02)
        #expect(quiet > 0 && quiet < 1)
    }
}
