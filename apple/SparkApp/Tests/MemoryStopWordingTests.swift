import Foundation
import Testing

@testable import SparkAppComposition

private func profile(_ id: String, _ context: Int, safe: Bool = true)
    -> SparkMemoryStopPresentation.Profile
{
    SparkMemoryStopPresentation.Profile(id: id, contextLength: context, isSafe: safe)
}

/// PLAN 41.9 fixes this wording; the app had a generic "choose a smaller context or profile".
@Test func aMemoryStopUsesTheWordingPlan41_9Fixes() {
    let stop = SparkMemoryStopPresentation.resolve(
        errorCode: "MODEL_INSUFFICIENT_MEMORY",
        profiles: [profile("p64", 65_536, safe: false), profile("p32", 32_768)]
    )

    #expect(stop?.title == "Spark stopped the model to protect the system.")
    #expect(
        stop?.message
            == "The selected 64K context used more memory than expected. You can restart at 32K or inspect diagnostics."
    )
    #expect(stop?.restartTitle == "Restart at 32K")
    #expect(stop?.restartProfileID == "p32")
}

/// The offer names the largest context that still fits, not merely any smaller one.
@Test func theRestartOffersTheLargestContextThatStillFits() {
    let stop = SparkMemoryStopPresentation.resolve(
        errorCode: "MODEL_INSUFFICIENT_MEMORY",
        profiles: [
            profile("p128", 131_072, safe: false), profile("p64", 65_536),
            profile("p32", 32_768), profile("p8", 8_192),
        ]
    )

    #expect(stop?.restartProfileID == "p64")
    #expect(stop?.restartTitle == "Restart at 64K")
}

/// A profile the Spark has already marked unsafe is never offered as the way back.
@Test func anUnsafeSmallerProfileIsNotOfferedAsTheRestart() {
    let stop = SparkMemoryStopPresentation.resolve(
        errorCode: "MODEL_INSUFFICIENT_MEMORY",
        profiles: [
            profile("p64", 65_536, safe: false), profile("p32", 32_768, safe: false),
            profile("p8", 8_192),
        ]
    )

    #expect(stop?.restartProfileID == "p8")
    #expect(stop?.restartTitle == "Restart at 8K")
}

/// With nothing smaller installed the copy must not promise a restart it cannot perform.
@Test func withNothingSmallerTheCopyOffersDiagnosticsOnly() {
    let stop = SparkMemoryStopPresentation.resolve(
        errorCode: "MODEL_INSUFFICIENT_MEMORY",
        profiles: [profile("p32", 32_768, safe: false)]
    )

    #expect(stop?.restartProfileID == nil)
    #expect(stop?.restartTitle == nil)
    #expect(stop?.message.contains("no smaller context installed") == true)
    #expect(stop?.message.contains("Restart") == false)
}

@Test func anUnrelatedFailureKeepsItsOwnCopy() {
    #expect(
        SparkMemoryStopPresentation.resolve(
            errorCode: "MODEL_DOWNLOAD_FAILED",
            profiles: [profile("p32", 32_768)]
        ) == nil
    )
    #expect(SparkMemoryStopPresentation.resolve(errorCode: nil, profiles: []) == nil)
}

/// A context that is not whole thousands is quoted in full rather than rounded into a lie.
@Test func anOddContextIsQuotedInFullRatherThanRounded() {
    #expect(SparkMemoryStopPresentation.contextLabel(32_768) == "32K")
    #expect(SparkMemoryStopPresentation.contextLabel(8_000) == 8_000.formatted())
}
