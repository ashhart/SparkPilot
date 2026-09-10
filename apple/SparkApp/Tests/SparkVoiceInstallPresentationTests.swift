import Testing

@testable import SparkAppComposition

/// UX-10: the Kokoro install screen names the Spark's stage in the owner's words, never the raw token.
struct SparkVoiceInstallPresentationTests {
    @Test func theSparksStagesAreNamedForTheOwner() {
        // "pending" is the operation's seed value; the owner saw it title-cased as "Pending".
        #expect(SparkVoiceInstallPresentation.line(stage: "pending", fraction: nil) == "Preparing")
        #expect(
            SparkVoiceInstallPresentation.line(stage: "pulling_image", fraction: nil)
                == "Downloading the Kokoro voice service to your Spark"
        )
        #expect(
            SparkVoiceInstallPresentation.line(stage: "starting", fraction: nil)
                == "Starting the voice service"
        )
        #expect(
            SparkVoiceInstallPresentation.hint(stage: "pulling_image")?.contains("3 GB") == true
        )
        #expect(SparkVoiceInstallPresentation.hint(stage: "removing") == nil)
    }

    @Test func kokoroInstallLineHumanisesAnUnknownStage() {
        #expect(
            SparkVoiceInstallPresentation.line(stage: "verifying_voices", fraction: 0.5)
                == "Verifying voices · 50%"
        )
        #expect(SparkVoiceInstallPresentation.line(stage: nil, fraction: nil) == nil)
        #expect(SparkVoiceInstallPresentation.line(stage: nil, fraction: 0.25) == "25% complete")
    }
}
