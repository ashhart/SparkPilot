import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing

@testable import SparkAppComposition

@MainActor
private func plainStyleTestSettings(enabled: Bool) -> SparkChatSettings {
    let defaults = UserDefaults(suiteName: "plain-style-\(UUID().uuidString)")!
    let settings = SparkChatSettings(defaults: defaults)
    settings.isPlainStyleEnabled = enabled
    return settings
}

@Test func theStyleInstructionAsksForEveryRuleAndBreaksNoneOfThemItself() {
    let instruction = SparkChatPlainStyle.instruction

    #expect(!instruction.contains("\u{2014}"))
    #expect(!instruction.contains("\u{2013}"))
    #expect(instruction.contains("em dash"))
    #expect(instruction.contains("Answer the question first"))
    #expect(instruction.contains("Certainly"))
    #expect(instruction.contains("As an AI"))
    #expect(instruction.contains("emoji"))
    #expect(instruction.count < 600)
}

@Test func theStyleSectionCarriesItsStableNameAndGoesQuietWhenSwitchedOff() {
    #expect(SparkChatPlainStyle.section(isEnabled: true).name == "plain-style")
    #expect(SparkChatPlainStyle.section(isEnabled: true).text == SparkChatPlainStyle.instruction)
    #expect(SparkChatPlainStyle.section(isEnabled: false).text.isEmpty)

    #expect(
        SparkChatInstructionAssembly.systemMessage(
            extra: [SparkChatPlainStyle.section(isEnabled: false)]
        ) == nil
    )
    #expect(
        SparkChatInstructionAssembly.systemMessage(
            extra: [SparkChatPlainStyle.section(isEnabled: true)]
        )?.contains(SparkChatPlainStyle.instruction) == true
    )
}

@MainActor
@Test func aPlainStyleChatCarriesTheStyleInstructionInItsOneSystemMessage() async throws {
    let streamer = ChatTestControlledChatStreamer()
    let model = SparkChatModel(
        catalogue: try chatTestFixtureCatalogue(),
        streamer: streamer,
        settings: plainStyleTestSettings(enabled: true)
    )
    model.draft = "Explain context windows"
    let task = try #require(model.send())
    try await chatTestWaitUntil { await streamer.isConnected() }
    await streamer.emit(.chunk(id: nil, model: nil, delta: "Fine.", finishReason: "stop"))
    await streamer.emit(.done)
    await task.value

    let request = try #require(await streamer.requests.first)
    #expect(request.messages.filter { $0.role == "system" }.count == 1)
    #expect(request.messages.first?.role == "system")
    #expect(request.messages.first?.content.contains(SparkChatPlainStyle.instruction) == true)
    #expect(chatTestConversation(request) == ["Explain context windows"])
}

@MainActor
@Test func switchingPlainStyleOffTakesTheStyleInstructionOutOfTheRequest() async throws {
    let streamer = ChatTestControlledChatStreamer()
    let model = SparkChatModel(
        catalogue: try chatTestFixtureCatalogue(),
        streamer: streamer,
        settings: plainStyleTestSettings(enabled: false)
    )
    model.draft = "Explain context windows"
    let task = try #require(model.send())
    try await chatTestWaitUntil { await streamer.isConnected() }
    await streamer.emit(.chunk(id: nil, model: nil, delta: "Fine.", finishReason: "stop"))
    await streamer.emit(.done)
    await task.value

    let request = try #require(await streamer.requests.first)
    #expect(
        request.messages.allSatisfy { !$0.content.contains(SparkChatPlainStyle.instruction) }
    )
    #expect(chatTestConversation(request) == ["Explain context windows"])
}

@MainActor
@Test func aConversationOverrideDecidesPlainStyleWhicheverWayTheSettingPoints() async throws {
    let settings = plainStyleTestSettings(enabled: true)
    let model = SparkChatModel(
        catalogue: try chatTestFixtureCatalogue(),
        streamer: ChatTestControlledChatStreamer(),
        settings: settings
    )
    #expect(model.usesPlainStyle)

    model.setPlainStyleOverride(false)
    #expect(!model.usesPlainStyle)
    #expect(model.plainStyleOverride == false)

    settings.isPlainStyleEnabled = false
    model.setPlainStyleOverride(true)
    #expect(model.usesPlainStyle)

    model.setPlainStyleOverride(nil)
    #expect(!model.usesPlainStyle)
}

@MainActor
@Test func thePlainStyleSettingIsOnUntilSomebodyTurnsItOff() {
    let defaults = UserDefaults(suiteName: "plain-style-default-\(UUID().uuidString)")!
    #expect(SparkChatSettings(defaults: defaults).isPlainStyleEnabled)

    SparkChatSettings(defaults: defaults).isPlainStyleEnabled = false
    #expect(!SparkChatSettings(defaults: defaults).isPlainStyleEnabled)
}

@MainActor
@Test func aStreamedAnswerIsTidiedAtEachParagraphAndAgainAtTheEnd() async throws {
    let streamer = ChatTestControlledChatStreamer()
    let model = SparkChatModel(
        catalogue: try chatTestFixtureCatalogue(),
        streamer: streamer,
        settings: plainStyleTestSettings(enabled: true)
    )
    model.draft = "Explain it"
    let task = try #require(model.send())
    try await chatTestWaitUntil { await streamer.isConnected() }

    await streamer.emit(
        .chunk(id: nil, model: nil, delta: "Certainly! The plan \u{2014} in", finishReason: nil)
    )
    try await chatTestWaitUntil { model.messages.last?.hasAnswer == true }
    #expect(model.messages.last?.content == "Certainly! The plan \u{2014} in")

    await streamer.emit(
        .chunk(id: nil, model: nil, delta: " short \u{2014} is ready.\n\nNext", finishReason: nil)
    )
    try await chatTestWaitUntil { model.messages.last?.content.hasSuffix("Next") == true }
    #expect(model.messages.last?.content == "The plan, in short, is ready.\n\nNext")

    await streamer.emit(
        .chunk(id: nil, model: nil, delta: " up. I hope this helps!", finishReason: "stop")
    )
    await streamer.emit(.done)
    await task.value
    #expect(model.messages.last?.content == "The plan, in short, is ready.\n\nNext up.")
}

@MainActor
@Test func withPlainStyleOffTheAnswerIsShownExactlyAsTheModelWroteIt() async throws {
    let streamer = ChatTestControlledChatStreamer()
    let model = SparkChatModel(
        catalogue: try chatTestFixtureCatalogue(),
        streamer: streamer,
        settings: plainStyleTestSettings(enabled: false)
    )
    model.draft = "Explain it"
    let task = try #require(model.send())
    try await chatTestWaitUntil { await streamer.isConnected() }
    let answer = "Certainly! The plan \u{2014} in short \u{2014} is ready. I hope this helps!"
    await streamer.emit(.chunk(id: nil, model: nil, delta: answer, finishReason: "stop"))
    await streamer.emit(.done)
    await task.value

    #expect(model.messages.last?.content == answer)
}

@MainActor
@Test func stoppingAStreamStillLeavesTheTextThatArrivedTidy() async throws {
    let streamer = ChatTestControlledChatStreamer()
    let model = SparkChatModel(
        catalogue: try chatTestFixtureCatalogue(),
        streamer: streamer,
        settings: plainStyleTestSettings(enabled: true)
    )
    model.draft = "Explain it"
    let task = try #require(model.send())
    try await chatTestWaitUntil { await streamer.isConnected() }
    await streamer.emit(
        .chunk(
            id: nil,
            model: nil,
            delta: "Sure! One rule \u{2014} keep it short",
            finishReason: nil
        )
    )
    try await chatTestWaitUntil { model.messages.last?.hasAnswer == true }
    model.cancel()
    await task.value

    #expect(model.messages.last?.content == "One rule: keep it short")
    #expect(model.messages.last?.responsePhase == .cancelled)
}

@MainActor
@Test func aConversationsPlainStyleChoiceSurvivesReopeningTheApp() async throws {
    let store = ChatTestChatArchiveMemoryStore()
    let settings = plainStyleTestSettings(enabled: true)
    let model = SparkChatModel(
        catalogue: try chatTestFixtureCatalogue(),
        streamer: ChatTestStaticChatStreamer(events: [.done]),
        settings: settings
    )
    let workspace = SparkChatWorkspace(initialModel: model, store: store)
    workspace.selected.model.draft = "Keep the model's own words"
    workspace.selected.model.setPlainStyleOverride(false)
    workspace.flush()

    let reopened = SparkChatWorkspace(initialModel: model.makeSibling(), store: store)
    #expect(reopened.selected.model.plainStyleOverride == false)
    #expect(!reopened.selected.model.usesPlainStyle)

    reopened.selected.model.setPlainStyleOverride(nil)
    reopened.flush()
    let again = SparkChatWorkspace(initialModel: model.makeSibling(), store: store)
    #expect(again.selected.model.plainStyleOverride == nil)
    #expect(again.selected.model.usesPlainStyle)
}

@MainActor
@Test func anArchiveWrittenBeforePlainStyleExistedStillOpens() throws {
    let store = ChatTestChatArchiveMemoryStore()
    let identifier = UUID()
    store.archive = SparkChatArchive(
        selectedID: identifier,
        conversations: [
            SparkChatRecord(
                id: identifier,
                title: nil,
                updatedAt: Date(timeIntervalSince1970: 1_000),
                targetID: nil,
                draft: "",
                messages: []
            )
        ]
    )
    let model = SparkChatModel(
        catalogue: try chatTestFixtureCatalogue(),
        streamer: ChatTestStaticChatStreamer(events: [.done]),
        settings: plainStyleTestSettings(enabled: true)
    )

    let workspace = SparkChatWorkspace(initialModel: model, store: store)
    #expect(workspace.selected.model.plainStyleOverride == nil)
    #expect(workspace.selected.model.usesPlainStyle)
}

@MainActor
@Test func theByteBudgetLeavesRoomForTheInstructionsTheRequestWillCarry() throws {
    let target = SparkChatTarget(
        id: "budget",
        displayName: "Desk Spark",
        nodeID: SparkNodeID(rawValue: UUID()),
        route: URL(string: "https://spark.invalid")!,
        tlsFingerprint: String(repeating: "a", count: 64),
        authorityFingerprint: "authority",
        modelID: "open/compact-8b",
        modelName: "Compact 8B",
        contextLength: 8_000
    )
    let catalogue = SparkChatTargetCatalogue(targets: [target], pairedTargetCount: 1)
    // The chart instruction and the calendar note always ride in the system message; only the style section is in question.
    let standing = SparkChatInstructionAssembly.systemMessage(extra: [
        SparkChartInstruction.section,
        SparkChatInstructionSection(
            name: "personal-context",
            text: SparkChatPersonalContextModel.instruction
        ),
    ])?.utf8.count
    let prompt = String(repeating: "a", count: 8_000 - 2_048 - (standing ?? 0) - 8)

    let plain = SparkChatModel(
        catalogue: catalogue,
        streamer: ChatTestControlledChatStreamer(),
        settings: plainStyleTestSettings(enabled: true)
    )
    plain.draft = prompt
    #expect(plain.send() == nil)
    #expect(plain.attachmentError != nil)

    let unstyled = SparkChatModel(
        catalogue: catalogue,
        streamer: ChatTestControlledChatStreamer(),
        settings: plainStyleTestSettings(enabled: false)
    )
    unstyled.draft = prompt
    #expect(unstyled.send() != nil)
    #expect(unstyled.attachmentError == nil)
}
