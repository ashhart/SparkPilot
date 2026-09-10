import Foundation

// Stable catalogue keys with typed interpolation arguments, resolved from the application bundle.

extension LocalizedStringResource {
    static func sharedAccessModelCount(_ count: Int) -> Self {
        .init(
            "shared.access.models.count",
            defaultValue: "\(count) models",
            comment: "How many models the owner has shared with one guest."
        )
    }

    static func sharedAccessBudgetToday(_ used: Int, _ budget: Int) -> Self {
        .init(
            "shared.access.budget.today",
            defaultValue: "\(used) of \(budget) tokens today",
            comment: "A guest's use against the daily budget the owner set."
        )
    }

    static func sharedAccessRequestsToday(_ requests: Int) -> Self {
        .init(
            "shared.access.requests.today",
            defaultValue: "\(requests) requests today",
            comment: "How many requests one guest made today."
        )
    }

    static func sharedAccessRefusalCount(_ count: Int) -> Self {
        .init(
            "shared.access.refusals.week",
            defaultValue: "\(count) requests refused this week",
            comment: "How many of a guest's requests the policy refused this week."
        )
    }

    static func sharedAccessHoursRange(_ start: String, _ end: String) -> Self {
        .init(
            "shared.access.hours.range",
            defaultValue: "\(start) to \(end)",
            comment: "The hours of the day a guest may use the Spark."
        )
    }

    static func sharedAccessWeekdayHours(_ range: String) -> Self {
        .init(
            "shared.access.hours.weekdays",
            defaultValue: "Weekdays, \(range)",
            comment: "A guest's hours when only Monday to Friday are open."
        )
    }

    static func sharedAccessHoursInZone(_ zone: String) -> Self {
        .init(
            "shared.access.hours.zone",
            defaultValue: "Times are in \(zone).",
            comment: "The owner's time zone, which the guest's hours are read in."
        )
    }

    static func sharedAccessLastSeen(_ when: String) -> Self {
        .init(
            "shared.access.last.seen",
            defaultValue: "Last used \(when)",
            comment: "When a guest last reached the Spark."
        )
    }

    static func sharedAccessInviteMessage(_ nodeName: String, _ link: String) -> Self {
        .init(
            "shared.access.invite.message",
            defaultValue: """
                I'm sharing my Spark, \(nodeName), with you.

                1. Install SparkPilot on your iPhone, iPad or Mac.
                2. If you're not on my Wi-Fi, install Tailscale too and accept the invitation \
                I'll send you separately, so your device can reach my Spark.
                3. Open this link and follow the steps: \(link)

                I'll get a prompt to confirm it's you before anything works, and I can change \
                or stop the sharing at any time.
                """,
            comment:
                "The message the owner sends a friend by iMessage or Mail with the link."
        )
    }

    static func sharedAccessInviteSubject(_ nodeName: String) -> Self {
        .init(
            "shared.access.invite.subject",
            defaultValue: "Using \(nodeName)",
            comment: "The subject line when the invitation is sent by Mail."
        )
    }

    static func guestAccessBudgetRemaining(_ remaining: Int) -> Self {
        .init(
            "guest.access.budget.remaining",
            defaultValue: "\(remaining) tokens left today",
            comment: "What a guest has left of today's share."
        )
    }

    static func guestAccessBudgetResets(_ when: String) -> Self {
        .init(
            "guest.access.budget.resets",
            defaultValue: "Starts again at \(when)",
            comment: "When a guest's daily share begins again, in the owner's time zone."
        )
    }

    static func guestAccessSharedBy(_ nodeName: String) -> Self {
        .init(
            "guest.access.shared.by",
            defaultValue: "You're using \(nodeName), shared with you by its owner.",
            comment: "Tells the guest whose Spark they are using."
        )
    }

}
