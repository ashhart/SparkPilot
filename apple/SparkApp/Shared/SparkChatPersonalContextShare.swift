import Foundation

extension SparkChatModel {
    /// What this conversation is sharing with the Spark, in the owner's words, or nil when nothing is.
    public var personalContextShareDescription: String? {
        if sharesPersonalContext {
            return String(localized: "your calendar and reminders")
        }
        let kinds = personal.included
        if kinds.isEmpty { return nil }
        if kinds.count == 1, let kind = kinds.first {
            return SparkChatPersonalContextCopy.included(kind)
        }
        return String(localized: "this week's calendar and your open reminders")
    }
}
