import Foundation
import SparkLibrary
import Testing

@testable import SparkAppComposition

@MainActor
struct SharedChatReceptionTests {
    @Test func revisitingTheWorkspacePreservesTheDraftAndKeepsTheOriginalPrivate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = SparkChatInbox(directory: directory)
        let share = SparkSharedChat(text: "A note shared by another app", files: [])
        try inbox.enqueue(share)
        let reception = SparkSharedChatReceptionModel(
            library: SparkLibrary(store: MemoryLibraryStore()),
            inbox: { inbox }
        )
        await reception.receive()
        let first = try #require(reception.session)
        await reception.prepare(first)
        first.model.draft = "My edited draft"
        await reception.becameActive()
        await reception.prepare(first)
        let returned = try #require(reception.session)
        #expect(returned.workspace === first.workspace)
        #expect(returned.model.draft == "My edited draft")
        #expect(!returned.workspace.isPersistent)
        #expect(try inbox.next()?.text == share.text)
        reception.keepForLater(first)
        await reception.receive()
        #expect(reception.session == nil)
        #expect(try inbox.next()?.id == share.id)
        await reception.becameActive()
        let reopened = try #require(reception.session)
        #expect(reopened.model.draft == share.text)
        #expect(reopened.workspace !== first.workspace)
        reception.finish(reopened)
        #expect(reception.session == nil)
        #expect(try inbox.next() == nil)
    }

    @Test func removingOneShareAdvancesTheInboxWithoutDeletingAnother() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let inbox = SparkChatInbox(directory: directory)
        try inbox.enqueue(SparkSharedChat(text: "First", files: []))
        try inbox.enqueue(SparkSharedChat(text: "Second", files: []))
        let reception = SparkSharedChatReceptionModel(
            library: SparkLibrary(store: MemoryLibraryStore()),
            inbox: { inbox }
        )
        await reception.receive()
        let first = try #require(reception.session)
        reception.finish(first)
        await reception.receive()
        let second = try #require(reception.session)
        #expect(second.id != first.id)
        reception.finish(first)
        #expect(reception.session?.id == second.id)
        #expect(try inbox.next()?.id == second.id)
        reception.finish(second)
        #expect(try inbox.next() == nil)
    }

    @Test func aLockedAppDoesNotReadOrPresentAnIncomingShare() async throws {
        let suite = "SharedChatReceptionTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppLockModel.enabledKey)
        var reads = 0
        let reception = SparkSharedChatReceptionModel(
            library: SparkLibrary(store: MemoryLibraryStore()),
            appLock: AppLockModel(defaults: defaults),
            inbox: {
                reads += 1
                throw SparkChatInbox.InboxError.unavailable
            }
        )
        await reception.becameActive()
        #expect(reads == 0)
        #expect(reception.session == nil)
    }
}
