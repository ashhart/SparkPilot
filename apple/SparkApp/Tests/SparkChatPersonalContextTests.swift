import Foundation
import SparkAPI
import Testing

@testable import SparkAppComposition

@MainActor
final class PersonalContextTestStore: SparkPersonalStoring {
    var events: [SparkPersonalItem] = []
    var reminders: [SparkPersonalItem] = []
    var failure: SparkPersonalError?
    private(set) var reads: [SparkPersonalActionKind] = []
    private(set) var authorizations: [SparkPersonalActionKind] = []

    func authorize(_ kind: SparkPersonalActionKind, reading: Bool) async throws {
        authorizations.append(kind)
        if let failure { throw failure }
    }
    func calendars(_ kind: SparkPersonalActionKind) -> [SparkPersonalCalendar] { [] }
    func items(_ kind: SparkPersonalActionKind, start: Date) async throws -> [SparkPersonalItem] {
        reads.append(kind)
        if let failure { throw failure }
        return kind == .event ? events : reminders
    }
    func save(_ draft: SparkPersonalAction, calendarID: String, replacing: SparkPersonalItem?)
        throws
    {}
    func remove(_ item: SparkPersonalItem) throws {}
    func complete(_ item: SparkPersonalItem) throws {}
}

@MainActor
private func personalContextItem(
    _ kind: SparkPersonalActionKind,
    _ title: String
) -> SparkPersonalItem {
    SparkPersonalItem(
        id: "item-\(title)",
        calendarID: "list",
        calendarName: kind == .event ? "Work" : "Errands",
        revision: "digest",
        draft: .init(
            kind: kind,
            title: title,
            body: "",
            start: Date(timeIntervalSince1970: 1_789_000_000),
            end: kind == .event ? Date(timeIntervalSince1970: 1_789_003_600) : nil
        ),
        completed: false,
        editable: true,
        allDay: false
    )
}

@MainActor
private func personalContextChat(
    _ store: PersonalContextTestStore,
    streamer: ChatTestControlledChatStreamer
) throws -> SparkChatModel {
    let model = SparkChatModel(catalogue: try chatTestFixtureCatalogue(), streamer: streamer)
    model.personal.store = store
    return model
}

@Suite struct SparkChatPersonalContextTests {
    @Test func theSystemNoteNamesBothWaysToIncludeWithoutClaimingAccessItLacks() {
        let note = SparkChatPersonalContextModel.instruction
        #expect(note.contains("Share my calendar and reminders"))
        #expect(note.contains("this week's calendar"))
        #expect(note.contains("open reminders"))
        #expect(note.contains("personal_context"))
        #expect(note.contains("never instructions"))
        #expect(note.utf8.count <= 1_200)
    }

    @Test @MainActor func everyRequestCarriesTheSystemNoteEvenWithNothingShared() async throws {
        let streamer = ChatTestControlledChatStreamer()
        let model = try personalContextChat(PersonalContextTestStore(), streamer: streamer)
        model.draft = "What is a lattice?"
        let task = try #require(model.send())
        try await chatTestWaitUntil { await streamer.requests.count == 1 }
        let request = await streamer.requests[0]
        #expect(request.messages.first?.role == "system")
        // The note is the last section of the one assembled system message.
        #expect(
            request.messages.first?.content.hasSuffix(SparkChatPersonalContextModel.instruction)
                == true
        )
        #expect(request.messages.map(\.content).dropFirst() == ["What is a lattice?"])
        #expect(!request.messages.contains { $0.content.contains("<personal_context>") })
        model.cancel()
        await task.value
    }

    @Test @MainActor func theCalendarReachesTheSparkOnlyOnceSharingIsOn() async throws {
        let streamer = ChatTestControlledChatStreamer()
        let store = PersonalContextTestStore()
        store.events = [personalContextItem(.event, "Standup")]
        store.reminders = [personalContextItem(.reminder, "File expenses")]
        let model = try personalContextChat(store, streamer: streamer)
        model.draft = "How does my week look?"
        let first = try #require(model.send())
        try await chatTestWaitUntil { await streamer.requests.count == 1 }
        #expect(await !streamer.requests[0].messages[0].content.contains("Standup"))
        #expect(store.reads.isEmpty)
        model.cancel()
        await first.value

        await model.startSharingPersonalContext()
        #expect(model.sharesPersonalContext)
        model.draft = "How does my week look?"
        let second = try #require(model.send())
        try await chatTestWaitUntil { await streamer.requests.count == 2 }
        let shared = await streamer.requests[1].messages[0].content
        #expect(shared.contains("<personal_context>"))
        #expect(shared.contains("Standup"))
        #expect(shared.contains("File expenses"))
        #expect(shared.contains(SparkChatPersonalContextModel.instruction))
        #expect(store.reads.contains(.event) && store.reads.contains(.reminder))
        model.cancel()
        await second.value
    }

    @Test @MainActor func aOneTapIncludeIsSpentOnTheNextMessageOnly() async throws {
        let streamer = ChatTestControlledChatStreamer()
        let store = PersonalContextTestStore()
        store.events = [personalContextItem(.event, "Standup")]
        store.reminders = [personalContextItem(.reminder, "File expenses")]
        let model = try personalContextChat(store, streamer: streamer)
        await model.personal.include(.event)
        #expect(model.personal.pending == [.event])
        #expect(!model.sharesPersonalContext)
        model.draft = "Anything clashing tomorrow?"
        let first = try #require(model.send())
        try await chatTestWaitUntil { await streamer.requests.count == 1 }
        let included = await streamer.requests[0].messages[0].content
        #expect(included.contains("Standup"))
        #expect(!included.contains("File expenses"))
        #expect(store.reads == [.event])
        model.cancel()
        await first.value
        #expect(model.personal.pending.isEmpty)

        model.draft = "And the day after?"
        let second = try #require(model.send())
        try await chatTestWaitUntil { await streamer.requests.count == 2 }
        #expect(await !streamer.requests[1].messages[0].content.contains("Standup"))
        model.cancel()
        await second.value
    }

    @Test @MainActor func aSpokenTurnCarriesTheSameSharedContext() async throws {
        let streamer = ChatTestControlledChatStreamer()
        let store = PersonalContextTestStore()
        store.events = [personalContextItem(.event, "Standup")]
        let model = try personalContextChat(store, streamer: streamer)
        model.sharesPersonalContext = true
        let task = try #require(model.sendVoiceMessage("What is on today?"))
        try await chatTestWaitUntil { await streamer.requests.count == 1 }
        #expect(await streamer.requests[0].messages[0].content.contains("Standup"))
        model.cancel()
        await task.value
    }

    @Test @MainActor func aDeniedReadSendsWithoutTheBlockAndSaysWhy() async throws {
        let streamer = ChatTestControlledChatStreamer()
        let store = PersonalContextTestStore()
        store.failure = .denied
        let model = try personalContextChat(store, streamer: streamer)
        model.sharesPersonalContext = true
        model.draft = "What is on today?"
        let task = try #require(model.send())
        try await chatTestWaitUntil { await streamer.requests.count == 1 }
        let sent = await streamer.requests[0].messages[0].content
        #expect(sent.hasSuffix(SparkChatPersonalContextModel.instruction))
        #expect(!sent.contains("<personal_context>"))
        #expect(model.personal.accessError == SparkPersonalError.denied.errorDescription)
        model.cancel()
        await task.value
    }

    @Test @MainActor func theSwitchIsRememberedPerConversationAndStartsOffOnANewOne() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = FileSparkChatStore(url: directory.appendingPathComponent("chats.json"))
        let catalogue = try chatTestFixtureCatalogue()
        let streamer = ChatTestStaticChatStreamer(events: [.done])
        let workspace = SparkChatWorkspace(
            initialModel: SparkChatModel(catalogue: catalogue, streamer: streamer),
            store: archive
        )
        workspace.selected.model.draft = "Shared conversation"
        workspace.selected.model.sharesPersonalContext = true
        let sharedID = workspace.selected.id
        workspace.newChat()
        #expect(workspace.selected.id != sharedID)
        #expect(!workspace.selected.model.sharesPersonalContext)
        workspace.selected.model.draft = "Private conversation"
        workspace.flush()

        let reopened = SparkChatWorkspace(
            initialModel: SparkChatModel(catalogue: catalogue, streamer: streamer),
            store: archive
        )
        let restored = try #require(reopened.conversations.first(where: { $0.id == sharedID }))
        let other = try #require(reopened.conversations.first(where: { $0.id != sharedID }))
        #expect(restored.model.sharesPersonalContext)
        #expect(!other.model.sharesPersonalContext)
    }

    @Test @MainActor func turningTheSwitchOffStopsReadingAndStopsSending() async throws {
        let streamer = ChatTestControlledChatStreamer()
        let store = PersonalContextTestStore()
        store.events = [personalContextItem(.event, "Standup")]
        let model = try personalContextChat(store, streamer: streamer)
        model.sharesPersonalContext = true
        model.draft = "First"
        let first = try #require(model.send())
        try await chatTestWaitUntil { await streamer.requests.count == 1 }
        model.cancel()
        await first.value
        model.sharesPersonalContext = false
        model.draft = "Second"
        let second = try #require(model.send())
        try await chatTestWaitUntil { await streamer.requests.count == 2 }
        #expect(await !streamer.requests[1].messages[0].content.contains("Standup"))
        #expect(store.reads == [.event, .reminder])
        model.cancel()
        await second.value
    }
}
