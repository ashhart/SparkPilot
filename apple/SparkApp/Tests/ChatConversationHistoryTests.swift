import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import SwiftUI
import Testing
@testable import SparkAppComposition

@MainActor
@Test func chatHistoryKeepsIndependentStreamsAndRequestHistories() async throws {
    let streamer = ChatTestControlledChatStreamer()
    let workspace = SparkChatWorkspace(
        initialModel: SparkChatModel(
            catalogue: try chatTestFixtureCatalogue(),
            streamer: streamer
        )
    )
    let first = workspace.selected
    first.model.draft = "First conversation"
    let firstTask = try #require(first.model.send())
    try await chatTestWaitUntil { await streamer.requests.count == 1 }
    workspace.newChat()
    let second = workspace.selected
    #expect(first.id != second.id)
    second.model.draft = "Second conversation"
    let secondTask = try #require(second.model.send())
    try await chatTestWaitUntil { await streamer.requests.count == 2 }
    await streamer.emit(
        .chunk(id: "a", model: "fixture", delta: "First answer", finishReason: "stop"),
        streamIndex: 0
    )
    await streamer.emit(.done, streamIndex: 0)
    await firstTask.value
    #expect(second.model.generationState == .streaming)
    workspace.select(first.id)
    await streamer.emit(
        .chunk(id: "b", model: "fixture", delta: "Second answer", finishReason: "stop"),
        streamIndex: 1
    )
    await streamer.emit(.done, streamIndex: 1)
    await secondTask.value
    #expect(first.model.messages.map(\.content) == ["First conversation", "First answer"])
    #expect(second.model.messages.map(\.content) == ["Second conversation", "Second answer"])
    let requests = await streamer.requests
    #expect(chatTestConversation(requests[0]) == ["First conversation"])
    #expect(chatTestConversation(requests[1]) == ["Second conversation"])
    first.model.draft = "Follow up on the first answer"
    let followUp = try #require(first.model.send())
    try await chatTestWaitUntil { await streamer.requests.count == 3 }
    let followUpRequest = await streamer.requests[2]
    #expect(
        chatTestConversation(followUpRequest) == [
            "First conversation", "First answer", "Follow up on the first answer",
        ]
    )
    #expect(followUpRequest.messages.first?.role == "system")
    await streamer.emit(.done, streamIndex: 2)
    await followUp.value
}

@MainActor
@Test func chatHistoryRestoresDraftsTitlesReasoningAndSelectionFromDisk() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileSparkChatStore(url: directory.appendingPathComponent("chats.json"))
    let model = SparkChatModel(
        catalogue: try chatTestFixtureCatalogue(),
        streamer: ChatTestStaticChatStreamer(events: [
            .chunk(
                id: "1",
                model: "fixture",
                delta: nil,
                reasoning: "Check the facts.",
                finishReason: nil
            ),
            .chunk(id: "1", model: "fixture", delta: "Answer", finishReason: "stop"), .done,
        ])
    )
    let workspace = SparkChatWorkspace(initialModel: model, store: store)
    let first = workspace.selected.id
    model.draft = "A question"
    await model.send()?.value
    workspace.rename(first, to: "Research")
    workspace.newChat()
    let second = workspace.selected.id
    workspace.selected.model.draft = "Unsent draft"
    workspace.flush()
    let restored = SparkChatWorkspace(initialModel: model.makeSibling(), store: store)
    #expect(restored.conversations.count == 2)
    #expect(restored.selectedID == second)
    #expect(restored.selected.model.draft == "Unsent draft")
    restored.select(first)
    #expect(restored.selected.title == "Research")
    #expect(restored.selected.model.messages == model.messages)
    #expect(restored.selected.model.messages.last?.reasoning == "Check the facts.")
    #expect(restored.selected.model.messages.last?.reasoningEndedAt != nil)
    let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
    #expect(values.isExcludedFromBackup == true)
    let raw = try String(contentsOf: store.url, encoding: .utf8)
    #expect(!raw.contains("tlsFingerprint"))
    #expect(!raw.contains("https://"))
}

@MainActor
@Test func chatHistoryRestoresInterruptedResponseWithoutResendingOrChangingSpark() async throws {
    let store = ChatTestChatArchiveMemoryStore()
    let targets = try chatTestFixtureCatalogue()
    let streamer = ChatTestControlledChatStreamer()
    let model = SparkChatModel(catalogue: targets, streamer: streamer)
    let workspace = SparkChatWorkspace(initialModel: model, store: store)
    model.draft = "Think about this"
    let task = try #require(model.send())
    try await chatTestWaitUntil { await streamer.isConnected() }
    await streamer.emit(
        .chunk(id: "1", model: "fixture", delta: nil, reasoning: "In progress", finishReason: nil)
    )
    try await chatTestWaitUntil { model.messages.last?.hasReasoning == true }
    workspace.flush()
    let restored = SparkChatWorkspace(initialModel: model.makeSibling(), store: store)
    let saved = restored.selected.model
    #expect(saved.messages.last?.responsePhase == .cancelled)
    #expect(saved.messages.last?.reasoningEndedAt != nil)
    #expect(saved.generationState == .cancelled)
    #expect(await streamer.requests.count == 1)
    saved.replaceCatalogue(
        SparkChatTargetCatalogue(
            targets: [try #require(targets.targets.last)],
            pairedTargetCount: 2
        )
    )
    #expect(saved.selectedTargetID == targets.targets.first?.id)
    #expect(saved.selectedTarget == nil)
    #expect(!saved.canRetry)
    #expect(!saved.messages.isEmpty)
    saved.replaceCatalogue(targets)
    #expect(saved.canRetry)
    #expect(saved.selectedTargetID == targets.targets.first?.id)
    model.cancel()
    await task.value
}

@MainActor
@Test func chatHistoryDeletionStopsOnlyDeletedStreamAndSurvivesReload() async throws {
    let store = ChatTestChatArchiveMemoryStore()
    let streamer = ChatTestControlledChatStreamer()
    let workspace = SparkChatWorkspace(
        initialModel: SparkChatModel(
            catalogue: try chatTestFixtureCatalogue(),
            streamer: streamer
        ),
        store: store
    )
    let first = workspace.selected
    first.model.draft = "Delete me"
    let task = try #require(first.model.send())
    try await chatTestWaitUntil { await streamer.isConnected() }
    workspace.newChat()
    let second = workspace.selected
    second.model.draft = "Keep me"
    workspace.delete(first.id)
    await streamer.emit(
        .chunk(id: "late", model: "fixture", delta: "Late reply", finishReason: nil),
        streamIndex: 0
    )
    await task.value
    #expect(workspace.conversations.map(\.id) == [second.id])
    #expect(second.model.draft == "Keep me")
    #expect(store.archive.conversations.map(\.id) == [second.id])
    workspace.delete(second.id)
    #expect(workspace.conversations.count == 1)
    #expect(workspace.selected.model.messages.isEmpty)
    #expect(workspace.selected.model.draft.isEmpty)
}

@MainActor
@Test func chatHistoryReusesEmptyChatAndKeepsSeparateDrafts() throws {
    let workspace = SparkChatWorkspace(
        initialModel: SparkChatModel(
            catalogue: try chatTestFixtureCatalogue(),
            streamer: ChatTestStaticChatStreamer(events: [])
        )
    )
    let first = workspace.selected
    workspace.newChat()
    #expect(workspace.selectedID == first.id)
    first.model.draft = "First draft"
    workspace.newChat()
    let second = workspace.selected
    second.model.draft = "Second draft"
    workspace.select(first.id)
    #expect(workspace.selected.model.draft == "First draft")
    #expect(second.model.draft == "Second draft")
    #expect(workspace.conversations.count == 2)
}

@MainActor
@Test func chatHistoryKeepsCorruptArchiveInsteadOfOverwritingIt() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileSparkChatStore(url: directory.appendingPathComponent("chats.json"))
    let original = Data("invalid archive".utf8)
    try original.write(to: store.url)
    let workspace = SparkChatWorkspace(
        initialModel: SparkChatModel(
            catalogue: try chatTestFixtureCatalogue(),
            streamer: ChatTestStaticChatStreamer(events: [])
        ),
        store: store
    )
    #expect(workspace.storageError != nil)
    workspace.selected.model.draft = "Keep this in memory"
    workspace.flush()
    #expect(try Data(contentsOf: store.url) == original)
    #expect(workspace.selected.model.draft == "Keep this in memory")
}

@MainActor
@Test func chatHistoryReportsSaveFailureAndRecoversWithoutLosingDraft() throws {
    let store = ChatTestChatArchiveMemoryStore()
    let workspace = SparkChatWorkspace(
        initialModel: SparkChatModel(
            catalogue: try chatTestFixtureCatalogue(),
            streamer: ChatTestStaticChatStreamer(events: [])
        ),
        store: store
    )
    workspace.selected.model.draft = "A draft that must survive"
    store.fails = true
    workspace.flush()
    #expect(workspace.storageError != nil)
    #expect(workspace.selected.model.draft == "A draft that must survive")
    store.fails = false
    workspace.flush()
    #expect(workspace.storageError == nil)
    #expect(store.archive.conversations.first?.draft == "A draft that must survive")
}
