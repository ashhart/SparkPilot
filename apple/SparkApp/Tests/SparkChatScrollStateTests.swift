import Foundation
import Testing
@testable import SparkAppComposition

struct SparkChatScrollStateTests {
    @Test func voiceTurnSentFromHistoryResumesFollowing() {
        var state = readingHistory()
        state.pauseFollowing()
        let history = [SparkChatMessage(role: .assistant, content: "An older answer")]
        let spoken = SparkChatMessage(role: .user, content: "My spoken question")
        state.messagesChanged(from: history, to: history + [spoken])
        #expect(state.followsLatest)
        #expect(!state.showsLatestResponse)
    }

    @Test func sendingFromHistoryIgnoresProgrammaticLayoutCorrections() {
        var state = readingHistory()
        state.userScrollBegan()
        state.resumeFollowing()
        state.positionChanged(
            from: position(1_100),
            to: position(900),
            isPositionedByUser: false
        )
        state.userScrollEnded()
        let reply = SparkChatMessage(role: .assistant, content: "Your message was sent")
        state.messagesChanged(from: [], to: [reply])
        #expect(state.followsLatest)
        #expect(!state.showsLatestResponse)
    }

    private func position(_ offset: CGFloat, height: CGFloat = 2_000) -> ChatScrollPosition {
        ChatScrollPosition(
            offset: offset,
            contentHeight: height,
            viewportHeight: 600,
            topInset: 0,
            bottomInset: 0
        )
    }

    private func readingHistory() -> SparkChatScrollState {
        var state = SparkChatScrollState()
        state.positionChanged(from: position(1_400), to: position(400))
        return state
    }

    @Test func inspectingCompletedReasoningDoesNotAnnounceAResponse() {
        var state = readingHistory()
        let messages = [
            SparkChatMessage(role: .assistant, content: "Saved reply", reasoning: "Steps")
        ]
        state.pauseFollowing()
        state.positionChanged(from: position(400), to: position(400, height: 3_000))
        state.messagesChanged(from: messages, to: messages)
        #expect(!state.followsLatest)
        #expect(!state.showsLatestResponse)
    }

    @Test func userMessageAndEmptyAssistantAreNotNewOutput() {
        var state = readingHistory()
        let user = SparkChatMessage(role: .user, content: "Question")
        let waiting = SparkChatMessage(role: .assistant, content: "", responsePhase: .waiting)
        state.messagesChanged(from: [], to: [user])
        state.messagesChanged(from: [user], to: [user, waiting])
        #expect(!state.showsLatestResponse)
        var thinking = waiting
        thinking.responsePhase = .thinking
        thinking.content = " \n"
        state.messagesChanged(from: [user, waiting], to: [user, thinking])
        #expect(!state.showsLatestResponse)
    }

    @Test func streamedAnswerStaysUnreadUntilReachedEvenAfterCompletion() {
        var state = readingHistory()
        let first = SparkChatMessage(role: .assistant, content: "Hello", responsePhase: .answering)
        var next = first
        next.content += " there"
        state.messagesChanged(from: [first], to: [next])
        #expect(state.showsLatestResponse)
        var completed = next
        completed.responsePhase = .complete
        state.messagesChanged(from: [next], to: [completed])
        #expect(state.showsLatestResponse)
        state.userScrollBegan()
        state.positionChanged(from: position(400), to: position(1_400))
        state.userScrollEnded()
        #expect(state.followsLatest)
        #expect(!state.showsLatestResponse)
        state.positionChanged(from: position(1_400), to: position(400))
        #expect(!state.showsLatestResponse)
    }

    @Test func reasoningArrivingOffscreenAlsoAnnouncesNewOutput() {
        var state = readingHistory()
        let waiting = SparkChatMessage(role: .assistant, content: "", responsePhase: .waiting)
        var thinking = waiting
        thinking.reasoning = "Working through the question"
        thinking.responsePhase = .thinking
        state.messagesChanged(from: [waiting], to: [thinking])
        #expect(state.showsLatestResponse)
        state.resumeFollowing()
        #expect(!state.showsLatestResponse)
        state.pauseFollowing()
        #expect(!state.showsLatestResponse)
    }

    @Test(arguments: [SparkChatResponsePhase.complete, .cancelled, .failed])
    func terminalMetadataAloneDoesNotAnnounceOutput(phase: SparkChatResponsePhase) {
        var state = readingHistory()
        let first = SparkChatMessage(
            role: .assistant,
            content: "Existing reply",
            responsePhase: .answering
        )
        var terminal = first
        terminal.responsePhase = phase
        terminal.reasoningEndedAt = Date()
        state.messagesChanged(from: [first], to: [terminal])
        #expect(!state.showsLatestResponse)
    }

    @Test func followingOutputDoesNotCreateAnUnreadBadgeDuringLayout() {
        var state = SparkChatScrollState()
        let reply = SparkChatMessage(role: .assistant, content: "New reply")
        state.messagesChanged(from: [], to: [reply])
        state.positionChanged(from: position(0, height: 300), to: position(0))
        #expect(state.followsLatest)
        #expect(!state.showsLatestResponse)
        state.pauseFollowing()
        #expect(!state.showsLatestResponse)
    }

    @Test func burstArrivingWhilePausedAtBottomBecomesUnreadAfterLayout() {
        var state = SparkChatScrollState()
        state.positionChanged(from: position(1_400), to: position(1_400))
        state.pauseFollowing()
        let reply = SparkChatMessage(role: .assistant, content: "A whole new paragraph")
        state.messagesChanged(from: [], to: [reply])
        #expect(!state.showsLatestResponse)
        state.positionChanged(from: position(1_400), to: position(1_400, height: 3_000))
        #expect(state.showsLatestResponse)
    }

    @Test func visibleUpdateDoesNotBecomeUnreadWhenScrollingAway() {
        var state = SparkChatScrollState()
        state.positionChanged(from: position(1_400), to: position(1_400))
        state.pauseFollowing()
        let reply = SparkChatMessage(role: .assistant, content: "A short update on the same line")
        state.messagesChanged(from: [], to: [reply])
        state.positionChanged(from: position(1_400), to: position(400))
        #expect(!state.showsLatestResponse)
    }

    @Test func keyboardResizeDoesNotPauseFollowingAndEmptyChatHasNoBadge() {
        var state = SparkChatScrollState()
        let keyboard = ChatScrollPosition(
            offset: 1_100,
            contentHeight: 2_000,
            viewportHeight: 300,
            topInset: 0,
            bottomInset: 0
        )
        state.positionChanged(from: position(1_400), to: keyboard)
        #expect(state.followsLatest)
        state.pauseFollowing()
        let reply = SparkChatMessage(role: .assistant, content: "New reply")
        state.messagesChanged(from: [], to: [reply])
        #expect(state.showsLatestResponse)
        state.messagesChanged(from: [reply], to: [])
        #expect(state.followsLatest)
        #expect(!state.showsLatestResponse)
    }
}
