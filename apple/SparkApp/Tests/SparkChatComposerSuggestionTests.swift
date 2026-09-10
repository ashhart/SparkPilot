import Foundation
import Testing

@testable import SparkAppComposition

@Suite struct SparkChatComposerSuggestionTests {
    @Test(
        arguments: [
            "How does my week look?",
            "What is on my calendar tomorrow?",
            "Do I have any appointments on Friday?",
            "Summarise my meetings for me",
            "Am I free on Thursday afternoon?",
            "what's in my diary next week",
            "Give me my agenda",
            "What does my schedule look like today?",
        ]
    )
    func draftsAboutTheOwnersTimeSuggestTheCalendar(draft: String) {
        #expect(SparkChatComposerSuggestions.hints(for: draft).contains(.calendar))
    }

    @Test(
        arguments: [
            "What reminders do I have open?",
            "Read me my to-dos",
            "Any TODOs left before Friday?",
            "What tasks do I still owe someone?",
            "remind me what my errands are",
            "Read out my shopping list",
        ]
    )
    func draftsAboutOutstandingWorkSuggestReminders(draft: String) {
        #expect(SparkChatComposerSuggestions.hints(for: draft).contains(.reminders))
    }

    @Test(
        arguments: [
            "Explain how the Linux task scheduler works",
            "Write a function that returns a list of prime numbers",
            "What is the busiest port in Europe?",
            "Draft a meeting agenda template for a client we have never met",
            "How do I schedule a cron job on the Spark?",
            "",
            "   ",
        ]
    )
    func draftsThatAreNotAboutTheOwnersOwnDaySuggestNothing(draft: String) {
        #expect(SparkChatComposerSuggestions.hints(for: draft).isEmpty)
    }

    @Test func aDraftAboutBothOffersBothInThatOrder() {
        let hints = SparkChatComposerSuggestions.hints(
            for: "Compare my calendar with my open reminders"
        )
        #expect(hints == [.calendar, .reminders])
    }

    @Test func caseAccentsAndPunctuationDoNotChangeTheAnswer() {
        #expect(SparkChatComposerSuggestions.hints(for: "MY CALENDAR!!!") == [.calendar])
        #expect(SparkChatComposerSuggestions.hints(for: "my agénda") == [.calendar])
        #expect(SparkChatComposerSuggestions.hints(for: "to-do?") == [.reminders])
    }

    @Test func aGenericWordCountsOnlyWhenTheOwnerIsTalkingAboutThemselves() {
        #expect(SparkChatComposerSuggestions.hints(for: "How long is a working week?").isEmpty)
        #expect(SparkChatComposerSuggestions.hints(for: "How is my week going?") == [.calendar])
    }

    @Test func nothingIsSuggestedForContextTheOwnerAlreadyIncluded() {
        let draft = "Compare my calendar with my open reminders"
        #expect(SparkChatComposerSuggestions.hints(for: draft, already: [.event]) == [.reminders])
        #expect(SparkChatComposerSuggestions.hints(for: draft, already: [.reminder]) == [.calendar])
        #expect(SparkChatComposerSuggestions.hints(for: draft, already: [.event, .reminder]) == [])
    }

    @Test func onlyTheEndOfAVeryLongDraftIsScanned() {
        let filler = String(repeating: "a ", count: 4_000)
        #expect(SparkChatComposerSuggestions.hints(for: "my calendar " + filler).isEmpty)
        #expect(SparkChatComposerSuggestions.hints(for: filler + " my calendar") == [.calendar])
    }

    @Test func eachHintNamesTheThingItWouldInclude() {
        #expect(SparkChatContextHint.calendar.kind == .event)
        #expect(SparkChatContextHint.reminders.kind == .reminder)
        #expect(SparkChatContextHint.calendar.title != SparkChatContextHint.reminders.title)
        #expect(!SparkChatContextHint.calendar.title.isEmpty)
        #expect(!SparkChatContextHint.reminders.title.isEmpty)
    }
}
