import Foundation
import Testing

@testable import SparkAppComposition

private func personalPrivacyPlist(_ target: String) throws -> [String: Any] {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let url = root.appending(path: "\(target)/Info.plist")
    let contents = try Data(contentsOf: url)
    let parsed = try PropertyListSerialization.propertyList(from: contents, format: nil)
    return try #require(parsed as? [String: Any])
}

@Suite struct SparkPersonalPrivacyCopyTests {
    @Test @MainActor func theListPromiseNamesEveryWayAnItemCanReachTheSpark() {
        let promise = SparkChatPersonalContextCopy.listPromise
        #expect(promise.contains("Include in request"))
        #expect(promise.contains(SparkChatPersonalContextCopy.includeCalendar))
        #expect(promise.contains(SparkChatPersonalContextCopy.includeReminders))
        #expect(promise.contains(SparkChatPersonalContextCopy.share))
        #expect(!promise.contains("Nothing from this list goes to your Spark unless"))
    }

    @Test(arguments: ["Shared", "macOS"])
    func theSystemPromptSaysWhenTitlesAndTimesTravelWithoutAnItem(target: String) throws {
        let plist = try personalPrivacyPlist(target)
        let calendar = try #require(plist["NSCalendarsFullAccessUsageDescription"] as? String)
        let reminders = try #require(plist["NSRemindersFullAccessUsageDescription"] as? String)
        for description in [calendar, reminders] {
            #expect(description.contains("Share my calendar and reminders"))
            #expect(description.contains("Include in request"))
            #expect(!description.contains("only when you include it in a request"))
        }
        #expect(calendar.contains("Include this week's calendar"))
        #expect(reminders.contains("Include open reminders"))
    }

    @Test @MainActor func everyPromiseNamesTheListNameTheSummaryActuallySends() throws {
        let item = SparkPersonalItem(
            id: "event-1",
            calendarID: "list",
            calendarName: "Therapy",
            revision: "digest",
            draft: .init(
                kind: .event,
                title: "Appointment",
                body: "",
                start: Date(timeIntervalSince1970: 1_789_025_000),
                end: Date(timeIntervalSince1970: 1_789_028_600)
            ),
            completed: false,
            editable: true,
            allDay: false
        )
        let summary = SparkChatPersonalSummary.text(
            events: [item],
            reminders: [],
            sections: [.event],
            now: Date(timeIntervalSince1970: 1_789_000_000),
            timeZone: TimeZone(identifier: "UTC") ?? .current
        )
        // BH-35: the emitter sends the calendar name, so every promise has to say so.
        #expect(summary.contains("[Therapy]"))
        let named = "the calendar or list each item is in"
        #expect(SparkChatPersonalContextCopy.explanation.contains(named))
        #expect(SparkChatPersonalContextCopy.listPromise.contains(named))
        for target in ["Shared", "macOS"] {
            let plist = try personalPrivacyPlist(target)
            let calendar = try #require(plist["NSCalendarsFullAccessUsageDescription"] as? String)
            let reminders = try #require(plist["NSRemindersFullAccessUsageDescription"] as? String)
            #expect(calendar.contains("the calendar each event is in"))
            #expect(reminders.contains("the list each reminder is in"))
        }
    }
}
