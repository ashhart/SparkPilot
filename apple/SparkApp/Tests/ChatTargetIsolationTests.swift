import Foundation
import SparkAPI
import Testing
@testable import SparkAppComposition

@MainActor
@Suite struct ChatTargetIsolationTests {
    @Test func thePickerStartsANewChatAndKeepsTheOldConversation() throws {
        let catalogue = try chatTestFixtureCatalogue()
        let model = SparkChatModel(
            catalogue: catalogue,
            streamer: ChatTestStaticChatStreamer(events: [.done])
        )
        let workspace = SparkChatWorkspace(initialModel: model)
        let first = workspace.selected
        let target = try #require(model.selectedTarget)
        let other = try #require(catalogue.targets.first { $0.nodeID != target.nodeID })
        model.messages = [.init(role: .user, content: "Keep with the first Spark")]
        model.draft = "Unsent first Spark draft"
        model.sharesPersonalContext = true
        workspace.selectTarget(other)
        #expect(workspace.selected.id != first.id)
        #expect(first.model.messages.first?.content == "Keep with the first Spark")
        #expect(first.model.draft == "Unsent first Spark draft")
        #expect(first.model.selectedTargetID == target.id)
        #expect(workspace.selected.model.messages.isEmpty)
        #expect(workspace.selected.model.draft.isEmpty)
        #expect(!workspace.selected.model.sharesPersonalContext)
        #expect(workspace.selected.model.selectedTargetID == other.id)
    }

    @Test func changingSparksNeverSendsThePreviousTranscript() async throws {
        let catalogue = try chatTestFixtureCatalogue()
        let streamer = ChatTestControlledChatStreamer()
        let model = SparkChatModel(catalogue: catalogue, streamer: streamer)
        let original = try #require(model.selectedTarget)
        let other = try #require(catalogue.targets.first { $0.nodeID != original.nodeID })
        model.draft = "Private first Spark question"
        let first = try #require(model.send())
        try await chatTestWaitUntil { await streamer.requests.count == 1 }
        await streamer.emit(
            .chunk(id: nil, model: nil, delta: "Private first Spark answer", finishReason: nil)
        )
        await streamer.emit(.done)
        await first.value
        model.selectTarget(other)
        model.draft = "Second Spark question"
        let second = try #require(model.send())
        try await chatTestWaitUntil { await streamer.requests.count == 2 }
        let request = await streamer.requests[1]
        #expect(chatTestConversation(request) == ["Second Spark question"])
        await streamer.emit(.done, streamIndex: 1)
        await second.value
    }
    @Test func modelReadyActionKeepsThePreviousSparksConversation() throws {
        let catalogue = try chatTestFixtureCatalogue()
        let model = SparkChatModel(
            catalogue: catalogue,
            streamer: ChatTestStaticChatStreamer(events: [.done])
        )
        let workspace = SparkChatWorkspace(initialModel: model)
        let first = workspace.selected
        let original = try #require(model.selectedTarget)
        let other = try #require(catalogue.targets.first { $0.nodeID != original.nodeID })
        model.messages = [.init(role: .user, content: "Private first Spark question")]
        #expect(workspace.openReadyTarget(other))
        #expect(workspace.selected.model.selectedTargetID == other.id)
        #expect(workspace.selected.model.messages.isEmpty)
        #expect(first.model.messages.count == 1)
    }

}
