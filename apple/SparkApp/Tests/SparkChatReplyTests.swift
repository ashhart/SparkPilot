import Foundation
import SparkAPI
import Testing
@testable import SparkAppComposition

@MainActor
@Suite struct SparkChatReplyTests {
    @Test func aSavedReplyCarriesItsQuotedContextInTheUserTurn() throws {
        let content = "An older answer, with \"quoted words\".\nKeep this exact context."
        let message = SparkChatMessage(role: .user, content: "Explain that part.")
        var encoded = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any]
        )
        encoded["replyTo"] = [
            "messageID": UUID().uuidString,
            "role": "assistant",
            "content": content,
            "attachmentNames": [],
        ]
        let restored = try JSONDecoder().decode(
            SparkChatMessage.self,
            from: JSONSerialization.data(withJSONObject: encoded)
        )
        let transcript = SparkChatTranscript.messages([restored], system: "App instructions")
        #expect(transcript.count == 2)
        #expect(transcript.first?.content == "App instructions")
        #expect(transcript.last?.role == "user")
        #expect(transcript.last?.content.contains(String(reflecting: content)) == true)
        #expect(transcript.last?.content.contains("Explain that part.") == true)
    }

    @Test func sendingKeepsTheSelectedQuoteSeparateFromTheVisibleMessage() async throws {
        let recorder = ReplyRecorder()
        let model = SparkChatModel(catalogue: try chatTestFixtureCatalogue(), streamer: recorder)
        let original = SparkChatMessage(
            role: .assistant,
            content: "Try vegetable pasta.",
            reasoning: "Private reasoning"
        )
        model.messages = [original, .init(role: .assistant, content: "A later suggestion.")]
        #expect(model.beginReply(to: original.id))
        let quote = try #require(model.replyDraft)
        model.messages[0].content = "The source changed after selecting it."
        model.draft = "Could we make that for four?"
        await model.send()?.value
        let sent = try #require(model.messages.first(where: { $0.role == .user }))
        #expect(sent.content == "Could we make that for four?")
        #expect(sent.replyTo == quote)
        #expect(sent.replyTo?.content == "Try vegetable pasta.")
        #expect(model.replyDraft == nil)
        #expect(model.draft.isEmpty)
        let request = try #require(await recorder.requests.first)
        #expect(request.messages.last?.content.contains("Try vegetable pasta.") == true)
        #expect(request.messages.last?.content.contains("Private reasoning") == false)
        #expect(request.messages.filter { $0.role == "system" }.count == 1)
    }

    @Test func retryUsesTheSentQuoteWithoutConsumingAnotherDraft() async throws {
        let recorder = ReplyRecorder(failFirst: true)
        let model = SparkChatModel(catalogue: try chatTestFixtureCatalogue(), streamer: recorder)
        let original = SparkChatMessage(role: .assistant, content: "The first plan.")
        let other = SparkChatMessage(role: .assistant, content: "A different plan.")
        model.messages = [original, other]
        model.beginReply(to: original.id)
        model.draft = "Change that plan."
        await model.send()?.value
        #expect(model.canRetry)
        model.beginReply(to: other.id)
        model.draft = "A separate unsent reply."
        await model.retry()?.value
        let requests = await recorder.requests
        #expect(requests.count == 2)
        #expect(requests[0].messages == requests[1].messages)
        #expect(model.messages.filter { $0.role == .user }.count == 1)
        #expect(model.replyDraft?.messageID == other.id)
        #expect(model.draft == "A separate unsent reply.")
    }

    @Test func repliesAndReplyDraftsSurviveDiskRestoration() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = FileSparkChatStore(url: directory.appendingPathComponent("chats.json"))
        let model = SparkChatModel(
            catalogue: try chatTestFixtureCatalogue(),
            streamer: ReplyRecorder()
        )
        let workspace = SparkChatWorkspace(initialModel: model, store: store)
        let original = SparkChatMessage(role: .assistant, content: "An older answer.")
        model.messages = [original]
        model.beginReply(to: original.id)
        model.draft = "Please explain."
        await model.send()?.value
        model.beginReply(to: original.id)
        model.draft = "And another question."
        workspace.flush()
        let restored = SparkChatWorkspace(initialModel: model.makeSibling(), store: store)
        #expect(restored.selected.model.messages == model.messages)
        #expect(restored.selected.model.replyDraft == model.replyDraft)
        #expect(restored.selected.model.draft == "And another question.")
        restored.newChat()
        #expect(restored.selected.model.replyDraft == nil)
        #expect(restored.selected.model.messages.isEmpty)
        restored.select(workspace.selectedID)
        #expect(restored.selected.model.replyDraft?.messageID == original.id)
    }

    @Test func cancellingAReplyLeavesTheMessageAndFilesIntact() async throws {
        let model = SparkChatModel(
            catalogue: try chatTestFixtureCatalogue(),
            streamer: ReplyRecorder()
        )
        let original = SparkChatMessage(role: .user, content: "My earlier question.")
        model.messages = [original]
        model.draft = "Keep this draft."
        await model.importSharedFiles([
            SparkSharedFile(name: "notes.txt", data: Data("Private notes".utf8))
        ])
        model.beginReply(to: original.id)
        #expect(model.replyDraft?.role == .user)
        let attachments = model.pendingAttachments
        model.cancelReply()
        #expect(model.replyDraft == nil)
        #expect(model.draft == "Keep this draft.")
        #expect(model.pendingAttachments == attachments)
        model.beginReply(to: original.id)
        model.resetConversation()
        #expect(model.replyDraft == nil)
    }

    @Test func aSeparateVoiceTurnDoesNotUseOrClearTheTypedReply() async throws {
        let recorder = ReplyRecorder()
        let model = SparkChatModel(catalogue: try chatTestFixtureCatalogue(), streamer: recorder)
        let original = SparkChatMessage(role: .assistant, content: "An earlier answer.")
        model.messages = [original]
        model.beginReply(to: original.id)
        model.draft = "A typed reply."
        await model.sendVoiceMessage("A separate spoken question.")?.value
        #expect(model.messages.first(where: { $0.role == .user })?.replyTo == nil)
        #expect(model.replyDraft?.messageID == original.id)
        #expect(model.draft == "A typed reply.")
        #expect(
            await recorder.requests.first?.messages.last?.content == "A separate spoken question."
        )
    }

    @Test func contextRefusalKeepsTheEntireReplyForEditing() throws {
        let model = SparkChatModel(
            catalogue: try chatTestFixtureCatalogue(),
            streamer: ReplyRecorder()
        )
        let original = SparkChatMessage(
            role: .assistant,
            content: String(repeating: "Long answer. ", count: 12_000)
        )
        model.messages = [original]
        model.beginReply(to: original.id)
        model.draft = "Explain this."
        #expect(model.send() == nil)
        #expect(model.replyDraft?.content == original.content)
        #expect(model.draft == "Explain this.")
        #expect(model.messages == [original])
        #expect(model.attachmentError != nil)
    }

    @Test func unknownAndUnfinishedMessagesCannotBecomeReplyTargets() throws {
        let model = SparkChatModel(
            catalogue: try chatTestFixtureCatalogue(),
            streamer: ReplyRecorder()
        )
        let streaming = SparkChatMessage(
            role: .assistant,
            content: "Still arriving",
            isPartial: true,
            responsePhase: .answering
        )
        model.messages = [streaming]
        #expect(!model.beginReply(to: UUID()))
        #expect(!model.beginReply(to: streaming.id))
        #expect(model.replyDraft == nil)
        model.messages[0].responsePhase = .cancelled
        #expect(model.beginReply(to: streaming.id))
        #expect(model.replyDraft?.content == "Still arriving")
    }

    @Test func oldArchivesDecodeWithoutReplyFields() throws {
        let message = SparkChatMessage(role: .assistant, content: "A saved answer.")
        var encoded = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any]
        )
        encoded.removeValue(forKey: "replyTo")
        let restored = try JSONDecoder().decode(
            SparkChatMessage.self,
            from: JSONSerialization.data(withJSONObject: encoded)
        )
        #expect(restored == message)
        #expect(restored.replyTo == nil)
    }
}

private actor ReplyRecorder: SparkChatStreaming {
    private(set) var requests: [ChatCompletionRequest] = []
    private var failFirst: Bool
    init(failFirst: Bool = false) { self.failFirst = failFirst }

    func stream(target: SparkChatTarget, request: ChatCompletionRequest) async throws
        -> AsyncThrowingStream<ChatStreamEvent, any Error>
    {
        requests.append(request)
        if failFirst {
            failFirst = false
            throw URLError(.networkConnectionLost)
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(
                .chunk(id: nil, model: nil, delta: "An answer.", finishReason: "stop")
            )
            continuation.yield(.done)
            continuation.finish()
        }
    }
}
