import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import Testing

@testable import SparkAppComposition

/// A launcher whose load is held open, so a refresh can move the selection while it runs.
@MainActor
private final class BugHuntHeldLauncher: SparkModelLaunching {
    var release: CheckedContinuation<Void, Never>?
    var isApplying = false

    func profiles(for target: SparkChatTarget) async throws -> [SparkModelProfile] { [] }

    func prepare(target: SparkChatTarget, profileID: String?) async throws -> SparkModelLaunchPlan {
        SparkModelLaunchPlan(target: target)
    }

    func apply(_ plan: SparkModelLaunchPlan) async throws -> SparkChatTarget {
        isApplying = true
        await withCheckedContinuation { release = $0 }
        return plan.target
    }

    func discard(_ plan: SparkModelLaunchPlan) {}

    func finish() {
        release?.resume()
        release = nil
    }
}

private struct BugHuntQuietStreamer: SparkChatStreaming {
    func stream(target: SparkChatTarget, request: ChatCompletionRequest) async throws
        -> AsyncThrowingStream<ChatStreamEvent, any Error>
    {
        AsyncThrowingStream { $0.finish() }
    }
}

/// A Spark that answers with the web tools and reports the pages it read.
private struct BugHuntWebStreamer: SparkChatStreaming {
    let sources: [GeneratedAPI.WebSource]

    func stream(target: SparkChatTarget, request: ChatCompletionRequest) async throws
        -> AsyncThrowingStream<ChatStreamEvent, any Error>
    {
        AsyncThrowingStream { $0.finish() }
    }

    func answer(target: SparkChatTarget, request: ChatCompletionRequest, webAccess: Bool)
        async throws -> SparkChatAnswer
    {
        SparkChatAnswer(
            events: AsyncThrowingStream {
                $0.yield(.chunk(id: nil, model: nil, delta: "Read it.", finishReason: "stop"))
                $0.yield(.done)
                $0.finish()
            },
            webSources: webAccess ? sources : []
        )
    }
}

private func bugHuntPersonalItem() -> SparkPersonalItem {
    SparkPersonalItem(
        id: "event-1",
        calendarID: "list",
        calendarName: "Personal",
        revision: "digest",
        draft: .init(
            kind: .event,
            title: "Therapy",
            body: "",
            start: Date(timeIntervalSince1970: 1_789_025_000),
            end: Date(timeIntervalSince1970: 1_789_028_600)
        ),
        completed: false,
        editable: true,
        allDay: false
    )
}

private func bugHuntTarget(model: String) -> SparkChatTarget {
    SparkChatTarget(
        id: "desk",
        displayName: "Desk Spark",
        nodeID: SparkNodeID(rawValue: UUID(uuidString: "63e82da2-7fb7-4b4b-9584-4a528000ac94")!),
        route: URL(string: "https://spark.example:8443")!,
        tlsFingerprint: String(repeating: "a", count: 64),
        authorityFingerprint: String(repeating: "b", count: 64),
        modelID: model,
        modelName: model
    )
}

/// Red tests for docs/reviews/BUG-HUNT-2026-09-05.md; a still-disabled one names the finding it proves and fails without its trait.
@MainActor
struct BugHuntRedTests {
    private func conversation() -> SparkChatModel {
        SparkChatModel(library: SparkLibrary(store: MemoryLibraryStore(), now: { Date() }))
    }

    @Test
    func aLoadWhoseTargetMovedUnderneathItGivesTheComposerBack() async throws {
        let launcher = BugHuntHeldLauncher()
        let model = SparkChatModel(
            catalogue: SparkChatTargetCatalogue(
                targets: [],
                pairedTargetCount: 1,
                installedTargets: [bugHuntTarget(model: "nemotron")]
            ),
            streamer: BugHuntQuietStreamer(),
            modelLauncher: launcher
        )
        model.draft = "Ask the Spark something"
        let task = try #require(model.send())
        for _ in 0..<2000 where !launcher.isApplying {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(launcher.isApplying, "the load never started, so the guard was never reached")
        // Exactly what an eight-second refresh does when a load-with-replace withdraws the target.
        model.replaceCatalogue(
            SparkChatTargetCatalogue(
                targets: [],
                pairedTargetCount: 1,
                installedTargets: [bugHuntTarget(model: "other")]
            )
        )
        launcher.finish()
        await task.value
        #expect(
            model.modelLaunchState == .idle,
            """
            BH-22: the launch state is stuck, so the composer is disabled for the life of the \
            conversation
            """
        )
        #expect(model.isPreparingModel == false)
        #expect(model.canSend, "the owner cannot send another message")
    }

    @Test
    func webAccessConsentDoesNotOutliveTheConversationThatGaveIt() {
        // BH-50: the production surfaces read this instance, so the seam and the views agree.
        let access = SparkChatWebAccess.shared
        var consented: ObjectIdentifier?
        do {
            let first = conversation()
            access.setOn(true, for: first)
            consented = ObjectIdentifier(first)
        }
        // Allocating another conversation of the same class routinely reuses the freed block.
        var reused: SparkChatModel?
        for _ in 0..<256 {
            let candidate = conversation()
            if ObjectIdentifier(candidate) == consented {
                reused = candidate
                break
            }
        }
        guard let reused else {
            Issue.record(
                "the allocator did not reuse the block on this run; the defect is unchanged"
            )
            return
        }
        defer { access.setOn(false, for: reused) }
        #expect(
            access.isOn(reused) == false,
            "a brand-new conversation is already allowed to read the internet"
        )
    }

    @Test
    func theSourcesOneAnswerDrewOnReachTheConversationThatAskedFor() async throws {
        let access = SparkChatWebAccess()
        let sources = [GeneratedAPI.WebSource(url: "https://example.com/a", title: "A")]
        let catalogue = SparkChatTargetCatalogue(
            targets: [bugHuntTarget(model: "qwen3-8b")],
            pairedTargetCount: 1
        )
        let chat = SparkChatModel(
            catalogue: catalogue,
            streamer: BugHuntWebStreamer(sources: sources)
        )
        let sibling = SparkChatModel(
            catalogue: catalogue,
            streamer: BugHuntWebStreamer(sources: sources)
        )
        access.setOn(true, for: chat)
        chat.draft = "What happened today?"
        await try #require(chat.send()).value
        #expect(
            access.sources(for: chat).map(\.url) == ["https://example.com/a"],
            "BH-12: the run's history never reaches the conversation that asked for it"
        )
        #expect(
            access.sources(for: sibling).isEmpty,
            "another conversation on the same model adopted URLs it never asked for"
        )
    }

    @Test
    func theWebAccessExplanationDoesNotAssertAPolicyItHasNotRead() {
        let access = SparkChatWebAccess()
        let chat = SparkChatModel(
            catalogue: SparkChatTargetCatalogue(
                targets: [bugHuntTarget(model: "qwen3-8b")],
                pairedTargetCount: 1
            ),
            streamer: BugHuntQuietStreamer()
        )
        // A fresh process has read no Spark's setting, and an unread setting is not a refusal.
        #expect(access.policy(for: chat) == .unknown)
        let copy = SparkChatWebAccessCopy.explanation(policy: access.policy(for: chat))
        #expect(
            copy.contains("does not let") == false,
            "BH-13: an unread policy is shown as a decision the owner's Spark has made"
        )
        access.record(.allowed, forSpark: "other-spark")
        #expect(
            access.policy(for: chat) == .unknown,
            "one Spark's policy was read as though it were every Spark's"
        )
        access.record(.allowed, forSpark: "desk")
        #expect(access.policy(for: chat) == .allowed)
    }

    @Test
    func theWebRouteIsNeverHandedTheOwnersCalendar() throws {
        let block = SparkChatPersonalSummary.text(
            events: [bugHuntPersonalItem()],
            reminders: [],
            sections: [.event],
            now: Date(timeIntervalSince1970: 1_789_000_000),
            timeZone: TimeZone(identifier: "UTC") ?? .current
        )
        let system = try #require(
            SparkChatInstructionAssembly.systemMessage(extra: [
                SparkChatInstructionSection(
                    name: "personal-context",
                    text: "\(SparkChatPersonalContextModel.instruction)\n\n\(block)"
                )
            ])
        )
        let transcript = SparkChatTranscript.messages(
            [SparkChatMessage(role: .user, content: "Find a restaurant near my 7pm")],
            system: system
        )
        #expect(
            transcript.contains { $0.content.contains(SparkChatPersonalSummary.openingTag) },
            "the chat transcript is meant to carry the block; only the web route must not"
        )
        let body = SparkChatWebAnswerBody.request(model: "qwen3-8b", messages: transcript)
        let sent = body.messages.map(\.content).joined(separator: "\n")
        #expect(
            sent.contains(SparkChatPersonalSummary.openingTag) == false,
            "BH-36: the personal-context block reaches the tool loop the model writes queries from"
        )
        #expect(sent.contains("Therapy") == false, "a calendar title reached the web route")
        #expect(sent.contains("Find a restaurant near my 7pm"))
    }

    @Test
    func plainStyleLeavesAnUnspacedEmDashAsideAlone() {
        let written = "The result\u{2014}which nobody expected\u{2014}was fine."
        let cleaned = SparkChatPlainText.cleaned(written, isComplete: true)
        #expect(
            cleaned.contains("result-which") == false,
            "an em-dash aside became a hyphenated non-word: \(cleaned)"
        )
    }

    @Test
    func plainStyleLeavesADashAttributionAlone() {
        let written = "Nothing is more permanent than a temporary fix.\n\n\u{2014} Anonymous"
        let cleaned = SparkChatPlainText.cleaned(written, isComplete: true)
        #expect(
            cleaned.contains(": Anonymous") == false,
            "an attribution dash became a colon: \(cleaned)"
        )
    }
}
