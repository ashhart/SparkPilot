import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import SwiftUI
import Testing
@testable import SparkAppComposition

@MainActor
@Test func chatResetInvalidatesTheStreamAndStartsWithAnEmptyTranscript() async throws {
    let streamer = ChatTestControlledChatStreamer()
    let model = SparkChatModel(catalogue: try chatTestFixtureCatalogue(), streamer: streamer)
    let targetID = model.selectedTargetID
    model.draft = "Private previous prompt"
    let oldTask = try #require(model.send())
    try await chatTestWaitUntil { await streamer.isConnected() }
    await streamer.emit(
        .chunk(
            id: nil,
            model: nil,
            delta: nil,
            reasoning: "Private previous reasoning.",
            finishReason: nil
        )
    )
    try await chatTestWaitUntil { model.messages.last?.responsePhase == .thinking }
    model.draft = "Unsent draft"
    model.resetConversation()
    #expect(model.messages.isEmpty)
    #expect(model.draft.isEmpty)
    #expect(model.generationState == .ready)
    #expect(!model.canRetry)
    #expect(model.selectedTargetID == targetID)
    model.draft = "New conversation"
    let newTask = try #require(model.send())
    try await chatTestWaitUntil { await streamer.requests.count == 2 }
    await streamer.emit(
        .chunk(id: nil, model: nil, delta: "Old answer", finishReason: nil),
        streamIndex: 0
    )
    await streamer.emit(
        .chunk(id: nil, model: nil, delta: "New answer", finishReason: nil),
        streamIndex: 1
    )
    await streamer.emit(.done, streamIndex: 1)
    await oldTask.value
    await newTask.value
    #expect(model.messages.map(\.content) == ["New conversation", "New answer"])
    #expect(model.messages.last?.reasoning == "")
    let request = try #require(await streamer.requests.last)
    #expect(chatTestConversation(request) == ["New conversation"])
}

@MainActor
@Test func chatResetBeforeTheTaskStartsDoesNotSendTheOldPrompt() async throws {
    let streamer = ChatTestControlledChatStreamer()
    let model = SparkChatModel(catalogue: try chatTestFixtureCatalogue(), streamer: streamer)
    model.draft = "Discard this before sending"
    let task = try #require(model.send())
    model.resetConversation()
    await task.value
    #expect(await streamer.requests.isEmpty)
    #expect(model.messages.isEmpty)
    #expect(model.generationState == .ready)
}

@MainActor
@Test func chatRetryDuringAStreamCannotDeleteTheCurrentResponse() async throws {
    let streamer = ChatTestControlledChatStreamer()
    let model = SparkChatModel(catalogue: try chatTestFixtureCatalogue(), streamer: streamer)
    model.draft = "Keep this reply"
    let task = try #require(model.send())
    try await chatTestWaitUntil { await streamer.isConnected() }
    await streamer.emit(.chunk(id: nil, model: nil, delta: "Partial reply", finishReason: nil))
    try await chatTestWaitUntil { model.messages.last?.content == "Partial reply" }
    #expect(model.retry() == nil)
    #expect(model.messages.last?.content == "Partial reply")
    await streamer.emit(.done)
    await task.value
}

@MainActor
@Test func replacingTheCatalogueMidStreamUnlocksTheChat() async throws {
    // Removing a streaming target during catalogue refresh must reset generation state so send and retry remain available.
    let gate = ChatTestChatStreamGate()
    let model = SparkChatModel(
        catalogue: try chatTestFixtureCatalogue(),
        streamer: ChatTestGatedChatStreamer(gate: gate)
    )
    model.draft = "Say hello"
    let task = try #require(model.send())
    try await chatTestWaitUntil { model.messages.last?.content == "Hel" }
    #expect(model.generationState == .streaming)

    // The refreshed catalogue no longer offers the target being streamed.
    model.replaceCatalogue(.empty)
    #expect(model.generationState == .ready)

    await gate.open()
    await task.value
}

@MainActor
@Test func targetSwitchingChangesTheNamedExecutionTarget() async throws {
    let catalogue = try chatTestFixtureCatalogue()
    let recorder = ChatTestTargetRecorder()
    let model = SparkChatModel(
        catalogue: catalogue,
        streamer: ChatTestRecordingChatStreamer(recorder: recorder)
    )
    let studio = try #require(catalogue.targets.last)
    model.selectTarget(id: studio.id)
    model.draft = "Where are you running?"

    await model.send()?.value

    #expect(model.selectedTargetID == studio.id)
    #expect(await recorder.targetIDs == [studio.id])
    #expect(model.messages.last?.targetName == "Studio Spark")
    #expect(model.messages.last?.modelName == "Reasoning 32B")
}

@MainActor
@Test func switchingTargetCancelsTheOldStreamWithoutOverwritingTheNewSelection() async throws {
    let catalogue = try chatTestFixtureCatalogue()
    let model = SparkChatModel(
        catalogue: catalogue,
        streamer: ChatTestDelayedChatStreamer(delay: .seconds(30))
    )
    model.draft = "Start on the first Spark"
    let oldTask = try #require(model.send())
    try await chatTestWaitUntil { model.messages.last?.content == "Hel" }

    let studio = try #require(catalogue.targets.last)
    model.selectTarget(id: studio.id)
    await oldTask.value

    #expect(model.selectedTargetID == studio.id)
    #expect(model.generationState == .ready)
    #expect(
        model.messages.isEmpty,
        "the previous Spark's partial answer must not enter the new transcript"
    )
    model.draft = "Continue here"
    #expect(model.canSend)
}

@MainActor
@Test func chatCopyAndLayoutRemainUsableAtAccessibilityTextSizes() throws {
    let target = try #require(chatTestFixtureCatalogue().targets.first)
    let assistant = SparkChatMessage(
        role: .assistant,
        content: "Hello",
        targetName: target.displayName,
        modelName: target.modelName
    )

    #expect(target.executionAccessibilityLabel.contains("Desk Spark"))
    #expect(target.executionAccessibilityLabel.contains("Compact 8B"))
    #expect(assistant.accessibilityLabel.contains("Desk Spark using Compact 8B"))
    #expect(SparkChatAccessibility.composerLabel == "Message to Spark")
    #expect(SparkChatAccessibility.cancelLabel == "Stop generating")
    #expect(SparkChatAccessibility.addSparkLabel == "Add a Spark for chat")
    #expect(!SparkChatLayoutPlan.stacksComposerVertically(.large))
    #expect(SparkChatLayoutPlan.stacksComposerVertically(.accessibility1))
}

@MainActor
@Test func completeStaticStreamUsesTheExistingChatEventContract() async throws {
    let model = SparkChatModel(
        catalogue: try chatTestFixtureCatalogue(),
        streamer: ChatTestStaticChatStreamer(events: [
            .chunk(id: "one", model: "open/compact-8b", delta: "Done", finishReason: "stop"),
            .usage(prompt: 3, completion: 1, total: 4),
            .done,
        ])
    )
    model.draft = "Finish"
    await model.send()?.value

    #expect(model.messages.last?.content == "Done")
    #expect(model.generationState == .ready)
}

/// A send refused after target selection changes must preserve the typed draft.
@MainActor
@Test func aSendThatCannotStartKeepsWhatWasTyped() throws {
    let model = SparkChatModel(
        catalogue: try chatTestFixtureCatalogue(),
        streamer: ChatTestDelayedChatStreamer(delay: .seconds(30))
    )
    // Every Spark goes away: there is nothing to send to.
    model.replaceCatalogue(SparkChatTargetCatalogue(targets: [], pairedTargetCount: 0))
    model.draft = "the message I typed"

    #expect(model.send() == nil, "with no target there is nothing to send to")
    #expect(model.draft == "the message I typed", "the draft must survive a refused send")
}

/// Replacing the catalogue must clear a failed request's retry state so its prompt cannot move to another Spark.
@MainActor
@Test func aCatalogueReplacementClearsAFailureFromThePreviousSpark() throws {
    let model = SparkChatModel(
        catalogue: try chatTestFixtureCatalogue(),
        streamer: ChatTestFailingChatStreamer(
            error: ChatError(
                statusCode: 503,
                code: "MODEL_NOT_LOADED",
                reason: .reported,
                diagnosticDetail: "no model"
            )
        )
    )
    model.draft = "a prompt for the first Spark"
    _ = model.send()

    model.replaceCatalogue(SparkChatTargetCatalogue(targets: [], pairedTargetCount: 0))
    #expect(model.generationState == .ready)
    #expect(model.retry() == nil, "no prompt may survive the Spark it was meant for")
}
