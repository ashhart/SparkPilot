import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import SwiftUI
import Testing
@testable import SparkAppComposition

@MainActor
@Test func assistantTextAppearsAsStreamingDeltasArrive() async throws {
    let gate = ChatTestChatStreamGate()
    let model = SparkChatModel(
        catalogue: try chatTestFixtureCatalogue(),
        streamer: ChatTestGatedChatStreamer(gate: gate)
    )
    model.draft = "Say hello"
    let task = try #require(model.send())

    try await chatTestWaitUntil { model.messages.last?.content == "Hel" }
    #expect(model.generationState == .streaming)
    #expect(model.messages.last?.isPartial == true)

    await gate.open()
    await task.value
    #expect(model.messages.map(\.content) == ["Say hello", "Hello"])
    #expect(model.messages.last?.isPartial == false)
    #expect(model.generationState == .ready)
}

@MainActor
@Test func cancellationKeepsPartialTextAndMakesRetryAvailable() async throws {
    let model = SparkChatModel(
        catalogue: try chatTestFixtureCatalogue(),
        streamer: ChatTestDelayedChatStreamer(delay: .seconds(30))
    )
    model.draft = "Keep going"
    let task = try #require(model.send())
    try await chatTestWaitUntil { model.messages.last?.content == "Hel" }

    model.cancel()
    await task.value

    #expect(model.generationState == .cancelled)
    #expect(model.messages.last?.content == "Hel")
    #expect(model.messages.last?.isPartial == true)
    #expect(model.canRetry)
}

@MainActor
@Test func cancellationKeepsServerReasoningBeforeTheFirstAnswerToken() async throws {
    let streamer = ChatTestControlledChatStreamer()
    var instant = Date(timeIntervalSince1970: 100)
    let model = SparkChatModel(
        catalogue: try chatTestFixtureCatalogue(),
        streamer: streamer,
        now: { instant }
    )
    model.draft = "Think through this"
    let task = try #require(model.send())
    try await chatTestWaitUntil { await streamer.isConnected() }
    await streamer.emit(
        .chunk(
            id: "reasoning",
            model: "open/compact-8b",
            delta: nil,
            reasoning: "I will check the supplied figures.",
            finishReason: nil
        )
    )
    try await chatTestWaitUntil {
        model.messages.last?.reasoning == "I will check the supplied figures."
    }
    instant = instant.addingTimeInterval(4)
    model.cancel()
    #expect(model.messages.last?.responsePhase == .cancelled)
    await task.value
    #expect(model.messages.last?.role == .assistant)
    #expect(model.messages.last?.reasoning == "I will check the supplied figures.")
    #expect(model.messages.last?.content == "")
    #expect(model.messages.last?.isPartial == true)
    #expect(model.generationState == .cancelled)
    #expect(model.canRetry)
    #expect(model.messages.last?.reasoningElapsed(at: instant.addingTimeInterval(100)) == 4)
}

@MainActor
@Test func chatThinkingStartsOnlyWithServerReasoningAndStopsAtTheAnswer() async throws {
    let streamer = ChatTestControlledChatStreamer()
    var instant = Date(timeIntervalSince1970: 100)
    let model = SparkChatModel(
        catalogue: try chatTestFixtureCatalogue(),
        streamer: streamer,
        now: { instant }
    )
    model.draft = "Explain the calculation"
    let task = try #require(model.send())
    #expect(model.messages.last?.responsePhase == .waiting)
    #expect(model.messages.last?.reasoningElapsed(at: instant) == nil)
    try await chatTestWaitUntil { await streamer.isConnected() }
    instant = instant.addingTimeInterval(5)
    await streamer.emit(
        .chunk(id: nil, model: nil, delta: nil, reasoning: " \n", finishReason: nil)
    )
    await streamer.emit(.usage(prompt: 1, completion: 0, total: 1))
    try await chatTestWaitUntil { model.messages.last?.reasoning == " \n" }
    #expect(model.messages.last?.responsePhase == .waiting)
    #expect(model.messages.last?.hasReasoning == false)
    #expect(model.messages.last?.reasoningStartedAt == nil)
    await streamer.emit(
        .chunk(id: nil, model: nil, delta: nil, reasoning: "Check the total.", finishReason: nil)
    )
    try await chatTestWaitUntil { model.messages.last?.responsePhase == .thinking }
    #expect(model.messages.last?.reasoningStartedAt == instant)
    #expect(model.messages.last?.reasoningElapsed(at: instant.addingTimeInterval(2)) == 2)
    instant = instant.addingTimeInterval(3)
    await streamer.emit(.chunk(id: nil, model: nil, delta: "42", finishReason: nil))
    try await chatTestWaitUntil { model.messages.last?.responsePhase == .answering }
    #expect(model.messages.last?.reasoningEndedAt == instant)
    #expect(model.messages.last?.reasoningElapsed(at: instant.addingTimeInterval(99)) == 3)
    instant = instant.addingTimeInterval(8)
    await streamer.emit(
        .chunk(id: nil, model: nil, delta: nil, reasoning: " Confirmed.", finishReason: nil)
    )
    try await chatTestWaitUntil { model.messages.last?.reasoning.hasSuffix(" Confirmed.") == true }
    #expect(model.messages.last?.responsePhase == .answering)
    #expect(model.messages.last?.reasoningElapsed(at: instant) == 3)
    await streamer.emit(.done)
    await task.value
    #expect(model.messages.last?.responsePhase == .complete)
    #expect(model.messages.last?.reasoningElapsed(at: instant.addingTimeInterval(99)) == 3)
    #expect(model.messages.last?.content == "42")
    #expect(!model.canRetry)
}

@MainActor
@Test func chatReasoningFailureKeepsTheServerTextAndFreezesElapsedTime() async throws {
    let streamer = ChatTestControlledChatStreamer()
    var instant = Date(timeIntervalSince1970: 100)
    let model = SparkChatModel(
        catalogue: try chatTestFixtureCatalogue(),
        streamer: streamer,
        now: { instant }
    )
    model.draft = "Check this"
    let task = try #require(model.send())
    try await chatTestWaitUntil { await streamer.isConnected() }
    await streamer.emit(
        .chunk(
            id: nil,
            model: nil,
            delta: nil,
            reasoning: "The supplied numbers differ.",
            finishReason: nil
        )
    )
    try await chatTestWaitUntil { model.messages.last?.responsePhase == .thinking }
    instant = instant.addingTimeInterval(7)
    await streamer.finish(throwing: URLError(.networkConnectionLost))
    await task.value
    #expect(model.messages.last?.responsePhase == .failed)
    #expect(model.messages.last?.reasoning == "The supplied numbers differ.")
    #expect(model.messages.last?.hasAnswer == false)
    #expect(model.messages.last?.isPartial == true)
    #expect(model.messages.last?.reasoningElapsed(at: instant.addingTimeInterval(200)) == 7)
    #expect(model.canRetry)
}

@MainActor
@Test(arguments: ["", " \n", "This is the reasoning the server returned."])
func chatResponseWithoutAnAnswerIsTerminalAndCanBeRetried(reasoning: String) async throws {
    let model = SparkChatModel(
        catalogue: try chatTestFixtureCatalogue(),
        streamer: ChatTestStaticChatStreamer(events: [
            .chunk(id: nil, model: nil, delta: " \n", reasoning: reasoning, finishReason: nil),
            .done,
        ])
    )
    model.draft = "Answer this"
    await model.send()?.value
    #expect(model.messages.last?.responsePhase == .complete)
    #expect(model.messages.last?.hasAnswer == false)
    #expect(
        model.messages.last?.hasReasoning == !reasoning.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty
    )
    #expect(model.generationState == .ready)
    #expect(model.canRetry)
    if reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        #expect(model.messages.last?.reasoningElapsed(at: .distantFuture) == nil)
    } else {
        let response = try #require(model.messages.last)
        #expect(response.reasoningEndedAt != nil)
        #expect(
            response.reasoningElapsed(at: .distantFuture) == response.reasoningElapsed(at: .now)
        )
    }
    await model.retry()?.value
    #expect(
        model.messages.count == 2,
        "retry replaces the unanswered response without repeating the user prompt"
    )
}

@MainActor
@Test func chatReasoningFinishMarkerFreezesTimeBeforeStreamCleanup() async throws {
    let streamer = ChatTestControlledChatStreamer()
    var instant = Date(timeIntervalSince1970: 100)
    let model = SparkChatModel(
        catalogue: try chatTestFixtureCatalogue(),
        streamer: streamer,
        now: { instant }
    )
    model.draft = "Think"
    let task = try #require(model.send())
    try await chatTestWaitUntil { await streamer.isConnected() }
    await streamer.emit(
        .chunk(id: nil, model: nil, delta: nil, reasoning: "Check.", finishReason: nil)
    )
    try await chatTestWaitUntil { model.messages.last?.responsePhase == .thinking }
    instant = instant.addingTimeInterval(6)
    await streamer.emit(
        .chunk(id: nil, model: nil, delta: nil, reasoning: " Done.", finishReason: "length")
    )
    try await chatTestWaitUntil { model.messages.last?.reasoning.hasSuffix(" Done.") == true }
    #expect(model.messages.last?.responsePhase == .complete)
    #expect(model.messages.last?.reasoningEndedAt == instant)
    instant = instant.addingTimeInterval(20)
    await streamer.emit(.done)
    await task.value
    #expect(model.messages.last?.reasoningElapsed(at: instant) == 6)
    #expect(model.canRetry)
}
