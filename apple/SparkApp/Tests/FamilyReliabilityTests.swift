import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import Testing
@testable import SparkAppComposition

@MainActor
@Test func interleavedAnswersKeepTheirOwnSourcesAcrossArchiveRestore() async throws {
    let streamer = ChatTestControlledChatStreamer()
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileSparkChatStore(url: directory.appendingPathComponent("chats.json"))
    let first = SparkChatModel(catalogue: try chatTestFixtureCatalogue(), streamer: streamer)
    let workspace = SparkChatWorkspace(initialModel: first, store: store)
    first.allowsWebAccess = true
    first.draft = "First question"
    let task1 = try #require(first.send())
    try await chatTestWaitUntil { await streamer.requests.count == 1 }
    workspace.newChat()
    let second = workspace.selected.model
    second.draft = "Second question"
    let task2 = try #require(second.send())
    try await chatTestWaitUntil { await streamer.requests.count == 2 }
    let source1 = GeneratedAPI.WebSource(
        url: "https://first.example/article",
        title: "First source"
    )
    let source2 = GeneratedAPI.WebSource(
        url: "https://second.example/article",
        title: "Second source"
    )
    await streamer.emit(.sources([source2]), streamIndex: 1)
    await streamer.emit(.sources([source1]), streamIndex: 0)
    for index in 0...1 {
        await streamer.emit(
            .chunk(id: nil, model: "same-model", delta: "Answer", finishReason: "stop"),
            streamIndex: index
        )
        await streamer.emit(.done, streamIndex: index)
    }
    await task1.value
    await task2.value
    #expect(first.messages.last?.sources == [source1])
    #expect(second.messages.last?.sources == [source2])
    #expect(!second.allowsWebAccess)
    workspace.flush()
    let restored = SparkChatWorkspace(initialModel: first.makeSibling(), store: store)
    #expect(restored.conversations[0].model.messages.last?.sources == [source1])
    #expect(restored.conversations[1].model.messages.last?.sources == [source2])
    #expect(restored.conversations[0].model.allowsWebAccess)
    #expect(!restored.conversations[1].model.allowsWebAccess)
}

@Test(arguments: ["1,5", "1 5", "12,34", "1,234,5", "1 23 456"])
func ambiguousNumbersStayInTheTable(_ number: String) throws {
    let table = try #require(
        SparkChatTable.first(in: "Label | Amount\n---|---\nOne | \(number)\nTwo | 2")
    )
    #expect(SparkChatTable.chart(table) == nil)
}

@Test(arguments: [true, false])
func automationNotificationPreferenceSurvivesTheOperationResponse(_ requested: Bool) throws {
    let id = UUID()
    let json = """
        {"id":"\(id)","kind":"automation.run","state":"succeeded","cancellable":false,"result":{"text":"A result","notify":\(requested)}}
        """
    let operation = try JSONDecoder().decode(SparkAPI.Operation.self, from: Data(json.utf8))
    let old = TargetOperationSnapshot(
        id: .init(rawValue: id),
        kind: operation.kind,
        state: .running,
        progress: nil,
        stage: nil,
        errorCode: nil,
        cancellable: false
    )
    let new = TargetOperationSnapshot(
        id: .init(rawValue: id),
        kind: operation.kind,
        state: .succeeded,
        progress: nil,
        stage: nil,
        errorCode: nil,
        cancellable: false,
        notificationRequested: operation.notificationRequested
    )
    let before = SparkNotificationObservation(
        targetID: "one",
        connectionState: .connectedWiFi,
        operations: [old],
        noticeCodes: []
    )
    let after = SparkNotificationObservation(
        targetID: "one",
        connectionState: .connectedWiFi,
        operations: [new],
        noticeCodes: []
    )
    let notices = SparkNotificationPlanner.notifications(
        previous: ["one": before],
        current: ["one": after]
    )
    #expect(notices.count == (requested ? 1 : 0))
}

@MainActor
@Test func webPermissionIsSpecificToTheSelectedSparkAndUpdatesImmediately() throws {
    let model = SparkChatModel(
        catalogue: try chatTestFixtureCatalogue(),
        streamer: ChatTestStaticChatStreamer(events: [])
    )
    let access = SparkChatWebAccess()
    let id = try #require(model.selectedTarget?.id)
    access.updatePolicy(.automationsAndChats, targetID: "some-other-spark")
    #expect(!access.policyAllowsChats(for: model))
    access.updatePolicy(.automationsAndChats, targetID: id)
    #expect(access.policyAllowsChats(for: model))
    access.updatePolicy(.off, targetID: id)
    #expect(!access.policyAllowsChats(for: model))
}

@Test func aScheduledTaskCompletedBetweenChecksStillNotifiesExactlyOnce() throws {
    let now = Date()
    let operation = TargetOperationSnapshot(
        id: .init(rawValue: UUID()),
        kind: "automation.run",
        state: .succeeded,
        progress: nil,
        stage: nil,
        errorCode: nil,
        cancellable: false,
        completedAt: now,
        notificationRequested: true
    )
    let before = SparkNotificationObservation(
        targetID: "one",
        connectionState: .connectedWiFi,
        operations: [],
        noticeCodes: [],
        observedAt: now.addingTimeInterval(-3600)
    )
    let after = SparkNotificationObservation(
        targetID: "one",
        connectionState: .connectedWiFi,
        operations: [operation],
        noticeCodes: [],
        observedAt: now
    )
    #expect(
        SparkNotificationPlanner.notifications(previous: ["one": before], current: ["one": after])
            .count == 1
    )
    #expect(
        SparkNotificationPlanner.notifications(previous: ["one": after], current: ["one": after])
            .isEmpty
    )
}

@Test(arguments: ["WEB_ACCESS_POLICY_OFF", "WEB_ACCESS_CHATS_NOT_PERMITTED"])
func refusedWebPermissionDoesNotTellTheFamilyToPairAgain(_ code: String) {
    let failure = SparkChatFailure.resolve(APIError(.reported, statusCode: 403, code: code))
    #expect(failure.kind == .transport)
    #expect(failure.message.contains("Turn off web access in this chat"))
    #expect(!failure.message.contains("Pair"))
}
