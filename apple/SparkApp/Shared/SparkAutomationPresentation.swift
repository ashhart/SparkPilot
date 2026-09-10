import Foundation
import SparkAPI

/// Owner-facing sentences about one automation, kept out of the views.
public enum SparkAutomationCopy {
    public static func nextRun(_ automation: GeneratedAPI.Automation) -> String {
        guard automation.enabled else { return String(localized: "Paused") }
        guard let next = automation.nextRunAt else {
            return String(localized: "No next run")
        }
        return String(localized: .automationNextRun(when: relative(next)))
    }

    public static func lastResult(_ automation: GeneratedAPI.Automation) -> String {
        guard let last = automation.lastRunAt else {
            return String(localized: "Has not run yet")
        }
        return String(
            localized: .automationLastResult(
                state: state(automation.lastRunState),
                when: relative(last)
            )
        )
    }

    public static func state(_ value: GeneratedAPI.AutomationLastRunState) -> String {
        switch value {
        case .none: String(localized: "not run yet")
        case .running: String(localized: "running now")
        case .succeeded: String(localized: "finished")
        case .failed: String(localized: "did not finish")
        case .skipped: String(localized: "skipped")
        case .interrupted: String(localized: "interrupted by a restart")
        }
    }

    public static func runState(_ value: GeneratedAPI.AutomationRunState) -> String {
        switch value {
        case .running: String(localized: "Running")
        case .succeeded: String(localized: "Finished")
        case .failed: String(localized: "Did not finish")
        case .skipped: String(localized: "Skipped")
        case .interrupted: String(localized: "Interrupted by a restart")
        }
    }

    /// What one web call ended as, or nothing when it simply succeeded.
    public static func outcome(of call: GeneratedAPI.AutomationToolCall) -> String? {
        // Tested by value rather than switched on, so an outcome this build predates shows the row plainly instead of being labelled a refusal.
        if call.outcome == .refused {
            return String(localized: .automationRefused(reason: refusal(call.errorCode ?? "")))
        }
        if call.outcome == .failed {
            return String(localized: .automationFailed(reason: refusal(call.errorCode ?? "")))
        }
        return nil
    }

    /// A fetch is decided by asking the site itself first, so "refused" never means "untouched".
    public static var robotsNote: String {
        String(
            localized:
                "Before reading a page your Spark asks that site for its rules file, so a page listed here as refused was still contacted."
        )
    }

    /// Plain words for a refusal the owner sees in a run's list of what it did.
    public static func refusal(_ code: String) -> String {
        switch code {
        case "WEB_OUTBOUND_BLOCKED":
            String(localized: "it would have sent something private out of the house")
        case "WEB_FETCH_PRIVATE_ADDRESS":
            String(localized: "the address was inside your own network")
        case "WEB_FETCH_ROBOTS_DENIED":
            String(localized: "the site asks automated readers not to read that page")
        case "WEB_DOMAIN_BLOCKED":
            String(localized: "your site list does not allow that address")
        case "WEB_FETCH_SCHEME_BLOCKED", "WEB_FETCH_URL_INVALID":
            String(localized: "that was not an ordinary web address")
        case "WEB_FETCH_TOO_MANY_REDIRECTS":
            String(localized: "the address kept redirecting")
        case "WEB_SEARCH_DISABLED":
            String(localized: "search is switched off on this Spark")
        case "WEB_SEARCH_UNAVAILABLE":
            String(localized: "the search service could not be reached")
        case "WEB_TOOL_CALL_LIMIT", "WEB_RUN_BYTE_LIMIT", "WEB_RUN_TIME_LIMIT":
            String(localized: "the run reached what one run is allowed to do")
        default:
            String(localized: "your Spark did not allow it")
        }
    }

    public static func relative(_ unixSeconds: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    public static func absolute(_ unixSeconds: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(unixSeconds))
            .formatted(date: .abbreviated, time: .shortened)
    }
}
