import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing

@testable import SparkAppComposition

private let usageTestLocale = Locale(identifier: "en_US")

private func contextUse(
    used: Int,
    limit: Int?,
    isTruncated: Bool = false
) -> SparkChatContextUse {
    SparkChatContextUse(
        usedTokens: used,
        contextLength: limit,
        isTruncated: isTruncated,
        locale: usageTestLocale
    )
}

@Test func tokenCountsRoundToOneDecimalOnceTheyPassAThousand() {
    #expect(SparkChatUsageFormat.tokens(0, locale: usageTestLocale) == "0")
    #expect(SparkChatUsageFormat.tokens(999, locale: usageTestLocale) == "999")
    #expect(SparkChatUsageFormat.tokens(1_000, locale: usageTestLocale) == "1.0K")
    #expect(SparkChatUsageFormat.tokens(12_400, locale: usageTestLocale) == "12.4K")
    #expect(SparkChatUsageFormat.tokens(65_536, locale: usageTestLocale) == "65.5K")
    #expect(SparkChatUsageFormat.tokens(1_536_000, locale: usageTestLocale) == "1.5M")
}

@Test func theHeaderReadsAsTheOwnerAskedForIt() {
    let use = contextUse(used: 12_400, limit: 65_536)

    #expect(use.percent == 19)
    #expect(use.summary == "12.4K of 65.5K \u{00B7} 19%")
    #expect(use.tone == .normal)
    #expect(use.hint == nil)
    #expect(use.truncationNote == nil)
    #expect(use.fraction == 12_400 / 65_536.0)
}

@Test func thePercentIsRoundedOnceSoTheToneNeverDisagreesWithTheNumberShown() {
    #expect(contextUse(used: 52_000, limit: 65_536).percent == 79)
    #expect(contextUse(used: 52_000, limit: 65_536).tone == .normal)
    #expect(contextUse(used: 52_500, limit: 65_536).percent == 80)
    #expect(contextUse(used: 52_500, limit: 65_536).tone == .caution)
    #expect(contextUse(used: 62_000, limit: 65_536).percent == 95)
    #expect(contextUse(used: 62_000, limit: 65_536).tone == .critical)
    #expect(contextUse(used: 61_700, limit: 65_536).percent == 94)
    #expect(contextUse(used: 61_700, limit: 65_536).tone == .caution)
}

@Test func aFullOrOverfullWindowStopsAtAHundredPercent() {
    #expect(contextUse(used: 65_536, limit: 65_536).percent == 100)
    #expect(contextUse(used: 70_000, limit: 65_536).percent == 100)
    #expect(contextUse(used: 70_000, limit: 65_536).fraction == 1)
    #expect(contextUse(used: 70_000, limit: 65_536).tone == .critical)
}

@Test func aCrowdedWindowSaysWhatToDoAboutIt() {
    #expect(
        contextUse(used: 52_500, limit: 65_536).hint == "Start a new chat to keep answers sharp"
    )
    #expect(
        contextUse(used: 62_000, limit: 65_536).hint == "Start a new chat to keep answers sharp"
    )
}

@Test func anUnknownContextLengthShowsWhatIsKnownAndInventsNoPercent() {
    let use = contextUse(used: 12_400, limit: nil)

    #expect(use.percent == nil)
    #expect(use.fraction == nil)
    #expect(use.tone == .normal)
    #expect(use.summary == "12.4K used")
    #expect(use.hint == nil)
}

@Test func aContextLengthOfNothingIsTreatedAsUnknownRatherThanDividedBy() {
    #expect(contextUse(used: 12_400, limit: 0).percent == nil)
    #expect(contextUse(used: 12_400, limit: 0).summary == "12.4K used")
}

@Test func aTurnTheRuntimeCutShortSaysSoAlongsideTheNumbers() {
    let use = contextUse(used: 64_000, limit: 65_536, isTruncated: true)

    #expect(use.truncationNote == "The last answer was cut short by the context limit.")
    #expect(use.summary == "64.0K of 65.5K \u{00B7} 98%")
    #expect(contextUse(used: 1_000, limit: 65_536).truncationNote == nil)
}

@Test func aResponseFooterCountsTheAnswerAndItsSpeed() {
    let message = SparkChatMessage(
        role: .assistant,
        content: "Done.",
        usage: SparkChatTokenUsage(promptTokens: 1_200, completionTokens: 512, totalTokens: 1_712),
        generationStartedAt: Date(timeIntervalSince1970: 100),
        generationEndedAt: Date(timeIntervalSince1970: 116)
    )

    #expect(message.tokensPerSecond == 32)
    #expect(
        SparkChatUsageFormat.responseFooter(for: message, locale: usageTestLocale)
            == "512 tokens \u{00B7} 32 tokens/s"
    )
}

@Test func aResponseWithoutUsageOrTimeShowsNoFooterNumbers() {
    let noUsage = SparkChatMessage(role: .assistant, content: "Done.")
    #expect(SparkChatUsageFormat.responseFooter(for: noUsage, locale: usageTestLocale) == nil)
    #expect(noUsage.tokensPerSecond == nil)

    let noClock = SparkChatMessage(
        role: .assistant,
        content: "Done.",
        usage: SparkChatTokenUsage(promptTokens: 1_200, completionTokens: 512, totalTokens: 1_712)
    )
    #expect(noClock.tokensPerSecond == nil)
    #expect(
        SparkChatUsageFormat.responseFooter(for: noClock, locale: usageTestLocale) == "512 tokens"
    )
}

@MainActor
@Test func everyTurnRefreshesTheContextReadingFromTheRuntimesOwnUsage() async throws {
    let streamer = ChatTestControlledChatStreamer()
    let model = SparkChatModel(catalogue: try chatTestFixtureCatalogue(), streamer: streamer)
    #expect(model.contextUse == nil)

    model.draft = "First"
    let first = try #require(model.send())
    try await chatTestWaitUntil { await streamer.isConnected() }
    await streamer.emit(.chunk(id: nil, model: nil, delta: "One.", finishReason: "stop"))
    await streamer.emit(.usage(prompt: 900, completion: 100, total: 1_000))
    await streamer.emit(.done)
    await first.value
    #expect(model.contextUse?.usedTokens == 1_000)
    #expect(model.messages.last?.usage?.completionTokens == 100)

    model.draft = "Second"
    let second = try #require(model.send())
    try await chatTestWaitUntil { await streamer.requests.count == 2 }
    await streamer.emit(.chunk(id: nil, model: nil, delta: "Two.", finishReason: "length"))
    await streamer.emit(.usage(prompt: 2_400, completion: 600, total: 3_000))
    await streamer.emit(.done)
    await second.value
    #expect(model.contextUse?.usedTokens == 3_000)
    #expect(model.contextUse?.isTruncated == true)
    #expect(model.contextUse?.contextLength == model.selectedTarget?.contextLength)
}

@MainActor
@Test func aRuntimeThatReportsNoUsageLeavesTheHeaderQuiet() async throws {
    let streamer = ChatTestControlledChatStreamer()
    let model = SparkChatModel(catalogue: try chatTestFixtureCatalogue(), streamer: streamer)
    model.draft = "First"
    let task = try #require(model.send())
    try await chatTestWaitUntil { await streamer.isConnected() }
    await streamer.emit(.chunk(id: nil, model: nil, delta: "One.", finishReason: "stop"))
    await streamer.emit(.done)
    await task.value

    #expect(model.messages.last?.usage == nil)
    #expect(model.contextUse == nil)
}

@MainActor
@Test func theHeaderAndTheFooterNeverDisagreeAboutOneTurn() async throws {
    let streamer = ChatTestControlledChatStreamer()
    let model = SparkChatModel(catalogue: try chatTestFixtureCatalogue(), streamer: streamer)
    model.draft = "First"
    let task = try #require(model.send())
    try await chatTestWaitUntil { await streamer.isConnected() }
    await streamer.emit(.chunk(id: nil, model: nil, delta: "One.", finishReason: "stop"))
    await streamer.emit(.usage(prompt: 11_888, completion: 512, total: 12_400))
    await streamer.emit(.done)
    await task.value

    let answer = try #require(model.messages.last)
    let usage = try #require(answer.usage)
    let use = try #require(model.contextUse)
    #expect(use.usedTokens == usage.totalTokens)
    #expect(usage.promptTokens + usage.completionTokens == usage.totalTokens)
    #expect(
        SparkChatUsageFormat.tokens(use.usedTokens, locale: usageTestLocale)
            == SparkChatUsageFormat.tokens(usage.totalTokens, locale: usageTestLocale)
    )
    #expect(
        SparkChatUsageFormat.responseFooter(for: answer, locale: usageTestLocale)?
            .hasPrefix("512 tokens") == true
    )
}

@MainActor
private func usageTestCatalogue(contextLength: Int?) -> SparkChatTargetCatalogue {
    SparkChatTargetCatalogue(
        targets: [
            SparkChatTarget(
                id: "node:33333333-3333-4333-8333-333333333333",
                displayName: "Desk Spark",
                nodeID: SparkNodeID(
                    rawValue: UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
                ),
                route: URL(string: "https://desk-spark.local:7443")!,
                tlsFingerprint: String(repeating: "a", count: 64),
                authorityFingerprint: "authority-desk",
                modelID: "open/compact-8b",
                modelName: "Compact 8B",
                contextLength: contextLength
            )
        ],
        pairedTargetCount: 1
    )
}

@MainActor
@Test func theContextReadingMeasuresTheTurnAgainstTheModelsOwnWindow() async throws {
    let streamer = ChatTestControlledChatStreamer()
    let model = SparkChatModel(
        catalogue: usageTestCatalogue(contextLength: 65_536),
        streamer: streamer
    )
    model.draft = "First"
    let task = try #require(model.send())
    try await chatTestWaitUntil { await streamer.isConnected() }
    await streamer.emit(.chunk(id: nil, model: nil, delta: "One.", finishReason: "stop"))
    await streamer.emit(.usage(prompt: 11_888, completion: 512, total: 12_400))
    await streamer.emit(.done)
    await task.value

    let use = try #require(model.contextUse)
    #expect(use.contextLength == 65_536)
    #expect(use.percent == 19)
    #expect(use.tone == .normal)
    #expect(
        SparkChatContextUse(
            usedTokens: use.usedTokens,
            contextLength: use.contextLength,
            isTruncated: use.isTruncated,
            locale: usageTestLocale
        ).summary == "12.4K of 65.5K \u{00B7} 19%"
    )
}

@MainActor
@Test func aSparkThatNeverSaidItsWindowSizeGetsNoInventedPercentage() async throws {
    let streamer = ChatTestControlledChatStreamer()
    let model = SparkChatModel(
        catalogue: usageTestCatalogue(contextLength: nil),
        streamer: streamer
    )
    model.draft = "First"
    let task = try #require(model.send())
    try await chatTestWaitUntil { await streamer.isConnected() }
    await streamer.emit(.chunk(id: nil, model: nil, delta: "One.", finishReason: "stop"))
    await streamer.emit(.usage(prompt: 11_888, completion: 512, total: 12_400))
    await streamer.emit(.done)
    await task.value

    #expect(model.contextUse?.percent == nil)
    #expect(model.contextUse?.contextLength == nil)
}

@Test func theSpokenContextReadingCarriesTheNumbersTheWarningAndTheAdvice() {
    #expect(
        contextUse(used: 12_400, limit: 65_536).accessibilityValue == "12.4K of 65.5K \u{00B7} 19%"
    )
    #expect(
        contextUse(used: 64_000, limit: 65_536, isTruncated: true).accessibilityValue
            == "64.0K of 65.5K \u{00B7} 98%, The last answer was cut short by the context limit., "
            + "Start a new chat to keep answers sharp"
    )
    #expect(contextUse(used: 12_400, limit: nil).accessibilityValue == "12.4K used")
}
