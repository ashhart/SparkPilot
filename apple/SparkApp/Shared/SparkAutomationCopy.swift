import Foundation

/// Stable catalogue keys with typed interpolation arguments, resolved from the application bundle.
extension LocalizedStringResource {
    static func automationNextRun(when: String) -> Self {
        .init(
            "automations.next.run",
            defaultValue: "Next run \(when)",
            comment: "When an automation will next run on the Spark."
        )
    }

    static func automationLastResult(state: String, when: String) -> Self {
        .init(
            "automations.last.result",
            defaultValue: "Last run \(when) — \(state)",
            comment: "When an automation last ran and how it ended."
        )
    }

    static func automationEveryHours(count: Int) -> Self {
        .init(
            "automations.every.hours",
            defaultValue: "Every \(count) hours",
            comment: "How often an automation repeats through the day."
        )
    }

    static func automationSearched(query: String) -> Self {
        .init(
            "automations.tool.searched",
            defaultValue: "Searched for \(query)",
            comment: "One search an automation made, showing the exact text that left the Spark."
        )
    }

    static func automationRead(url: String) -> Self {
        .init(
            "automations.tool.read",
            defaultValue: "Read \(url)",
            comment: "One page an automation read, showing the address that left the Spark."
        )
    }

    static var automationContextRemoved: Self {
        .init(
            "automations.tool.context.removed",
            defaultValue: "Your calendar was taken out before the web tools ran",
            comment:
                "The owner's personal context was removed from a run before any web tool saw it."
        )
    }

    static func automationRefused(reason: String) -> Self {
        .init(
            "automations.tool.refused",
            defaultValue: "Refused: \(reason)",
            comment: "A web tool call the Spark refused, and why."
        )
    }

    static func automationFailed(reason: String) -> Self {
        .init(
            "automations.tool.failed",
            defaultValue: "Did not finish: \(reason)",
            comment: "A web tool call that was allowed but did not complete, and why."
        )
    }
}
