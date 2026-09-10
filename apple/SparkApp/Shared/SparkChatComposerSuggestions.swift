import Foundation

enum SparkChatContextHint: String, Identifiable, CaseIterable, Sendable {
    case calendar, reminders
    var id: String { rawValue }

    var kind: SparkPersonalActionKind {
        self == .calendar ? .event : .reminder
    }

    var title: String {
        switch self {
        case .calendar: String(localized: "Include this week's calendar?")
        case .reminders: String(localized: "Include open reminders?")
        }
    }

    var symbol: String {
        self == .calendar ? "calendar" : "checklist"
    }
}

/// Decides when to offer the owner's own calendar or reminders, on this device, with no model call.
enum SparkChatComposerSuggestions {
    static let scanLimit = 400

    static func hints(
        for draft: String,
        already included: [SparkPersonalActionKind] = []
    ) -> [SparkChatContextHint] {
        let sentence = normalised(draft)
        let words = Set(sentence.split(separator: " ").map(String.init))
        guard !words.isEmpty else { return [] }
        let personal = !words.isDisjoint(with: firstPerson)
        return SparkChatContextHint.allCases.filter { hint in
            guard !included.contains(hint.kind) else { return false }
            if !words.isDisjoint(with: named(hint)) { return true }
            if phrases(hint).contains(where: { sentence.contains(" \($0) ") }) { return true }
            return personal && !words.isDisjoint(with: implied(hint))
        }
    }

    /// A hyphen closes up so "to-do" reads as one word; everything else that is not a letter splits.
    private static func normalised(_ draft: String) -> String {
        let tail = String(draft.suffix(scanLimit))
        let folded = tail.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let closed = folded.replacingOccurrences(of: "-", with: "")
        let words = closed.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return " \(words.joined(separator: " ")) "
    }

    private static func named(_ hint: SparkChatContextHint) -> Set<String> {
        switch hint {
        case .calendar: ["calendar", "calendars", "appointment", "appointments", "diary"]
        case .reminders: ["reminder", "reminders", "todo", "todos"]
        }
    }

    /// Words that only mean the owner's own day when the owner is talking about themselves.
    private static func implied(_ hint: SparkChatContextHint) -> Set<String> {
        switch hint {
        case .calendar:
            ["week", "weekend", "day", "agenda", "meeting", "meetings", "busy", "free", "plans"]
        case .reminders: ["task", "tasks", "chores", "errands", "outstanding"]
        }
    }

    /// "Schedule" and "list" are ordinary words on their own; these readings are not.
    private static func phrases(_ hint: SparkChatContextHint) -> [String] {
        switch hint {
        case .calendar: ["my schedule", "our schedule", "schedule this week", "whats on today"]
        case .reminders: ["my list", "shopping list", "to do list", "task list"]
        }
    }

    private static let firstPerson: Set<String> = ["i", "im", "ive", "me", "my", "mine"]
}
