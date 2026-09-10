import Foundation
import Testing

@testable import SparkAppComposition

private func chatHistorySource() throws -> String {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    return try String(
        contentsOf: root.appending(path: "Shared/SparkChatHistoryView.swift"),
        encoding: .utf8
    )
}

/// The delete confirmation and the row timestamp, both reported by the September simulator pass.
@Suite struct SparkChatHistoryPresentationTests {
    /// QA-15: tapping outside is not an action VoiceOver or a keyboard can find.
    @Test func theDeleteConfirmationOffersAWayOut() throws {
        let source = try chatHistorySource()
        let dialog = try #require(source.range(of: "\"Delete this chat?\""))
        let actions = source[dialog.upperBound...]
        let end = try #require(actions.range(of: "} message: {"))
        let buttons = actions[..<end.lowerBound]
        #expect(
            buttons.contains("role: .cancel"),
            "the delete confirmation has no cancel action:\n\(buttons)"
        )
    }

    /// A popover confirmation hides the cancel button it is handed; an alert shows every button.
    @Test func theDeleteConfirmationIsPresentedWhereThatCancelIsDrawn() throws {
        let source = try chatHistorySource()
        let dialog = try #require(source.range(of: "\"Delete this chat?\""))
        let opening = source[..<dialog.lowerBound]
        #expect(opening.hasSuffix(".alert(\n                "), "\(opening.suffix(40))")
        #expect(
            !source.contains("confirmationDialog"),
            "a confirmation dialog renders as a popover here, which drops its cancel button"
        )
    }

    /// QA-18: a chat touched a moment ago was stamped "0 secs".
    @Test func aChatTouchedAMomentAgoSaysNowRatherThanCountingZeroSeconds() {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        #expect(SparkChatHistoryTimestamp.label(for: now, now: now) == "Now")
        #expect(SparkChatHistoryTimestamp.label(for: now.addingTimeInterval(-1), now: now) == "Now")
        #expect(
            SparkChatHistoryTimestamp.label(for: now.addingTimeInterval(-59), now: now) == "Now"
        )
    }

    /// A clock that ran backwards is still not the future, and never a negative age.
    @Test func aTimestampFromTheFutureIsStillNow() {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let ahead = SparkChatHistoryTimestamp.label(for: now.addingTimeInterval(120), now: now)
        #expect(ahead == "Now")
    }

    /// Past a minute the row goes back to the relative form the sheet already used.
    @Test func anOlderChatKeepsItsRelativeAge() {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let minute = SparkChatHistoryTimestamp.label(for: now.addingTimeInterval(-60), now: now)
        #expect(minute != "Now")
        #expect(minute.contains("1"), "\(minute)")
        let hour = SparkChatHistoryTimestamp.label(for: now.addingTimeInterval(-7_200), now: now)
        #expect(hour.contains("2"), "\(hour)")
        #expect(!hour.contains("0 sec"), "\(hour)")
    }
}
