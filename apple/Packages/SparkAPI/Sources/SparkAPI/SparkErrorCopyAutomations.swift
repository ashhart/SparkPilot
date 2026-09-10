import Foundation

extension SparkErrorCopy {
    /// Automations: what the owner asked for, and which part of it the Spark could not take.
    static func automations(_ code: String) -> String? {
        switch code {
        case "AUTOMATION_NOT_FOUND":
            String(
                localized:
                    "That automation is no longer on this Spark. Refresh to see the current list."
            )
        case "AUTOMATION_NAME_INVALID":
            String(localized: "Give the automation a name of eighty characters or fewer.")
        case "AUTOMATION_INSTRUCTIONS_INVALID":
            String(localized: "Keep the instructions to two thousand characters or fewer.")
        case "AUTOMATION_SCHEDULE_INVALID":
            String(
                localized:
                    "This Spark could not read the schedule. Check the days and times, then save again."
            )
        case "AUTOMATION_TIMEZONE_UNKNOWN":
            String(
                localized:
                    "This Spark does not know that time zone, and will not silently use another. Choose one of the zones it offers."
            )
        case "AUTOMATION_LIMIT_REACHED":
            String(
                localized:
                    "This Spark is holding as many automations as it allows. Delete one first."
            )
        case "AUTOMATION_RUN_IN_FLIGHT":
            String(localized: "This automation is already running. Wait for that run to finish.")
        case "AUTOMATION_RUN_INTERRUPTED":
            String(
                localized:
                    "The Spark restarted while this run was in progress, so its outcome is unknown. It is not repeated by itself; run it now if you still want it."
            )
        case "AUTOMATION_SLOT_MISSED":
            String(
                localized:
                    "This Spark was not running when this automation was due, and the slot is now too old to run late. The next one is unchanged."
            )
        case "AUTOMATION_RUNNER_UNAVAILABLE":
            String(
                localized:
                    "No model was ready to perform this run. Check that a model is installed and loaded, then run it again."
            )
        case "AUTOMATION_RUN_TIMED_OUT":
            String(
                localized:
                    "This task took longer than its time limit. Try a shorter request or run it again when your Spark is less busy."
            )
        case "AUTOMATION_RUN_FAILED":
            String(
                localized:
                    "This run did not finish. Its details hold the reason; you can run it again now."
            )
        default: nil
        }
    }

    /// The web tools: whether anything left the Spark, and why the answer is missing.
    static func web(_ code: String) -> String? {
        webPolicy(code) ?? webRead(code)
    }

    private static func webPolicy(_ code: String) -> String? {
        switch code {
        case "WEB_ACCESS_POLICY_OFF":
            String(
                localized:
                    "This Spark does not let models read the web. The owner can turn that on in its settings."
            )
        case "WEB_ACCESS_CHATS_NOT_PERMITTED":
            String(
                localized:
                    "This Spark allows web access for automations only, not for conversations."
            )
        case "WEB_ACCESS_HARNESS_NOT_PERMITTED":
            String(
                localized:
                    "Another app asked this Spark for the web tools. The owner has not allowed other apps to use them."
            )
        case "WEB_ACCESS_POLICY_INVALID":
            String(localized: "That web-access setting is not one this Spark can store.")
        case "WEB_SEARCH_BACKEND_INVALID":
            String(
                localized:
                    "This Spark could not use that search service address. Check the address and try again."
            )
        case "WEB_SEARCH_BACKEND_INCOMPLETE":
            String(
                localized:
                    "That search service still needs its address or its key before it can be used."
            )
        case "WEB_DOMAIN_ENTRY_INVALID":
            String(
                localized: "Enter a bare site name, with no https:// in front and no path after it."
            )
        case "WEB_DOMAIN_LIST_TOO_LONG":
            String(localized: "This site list is longer than this Spark will hold. Shorten it.")
        default: nil
        }
    }

    private static func webRead(_ code: String) -> String? {
        switch code {
        case "WEB_OUTBOUND_BLOCKED":
            String(
                localized:
                    "That request carried something private — an address, a number, a key or a device name — so this Spark did not send it. Nothing left your network."
            )
        case "AUTOMATION_TIMEZONE_UNREADABLE":
            String(
                localized:
                    "This Spark could not read the time zone file for that zone, so the schedule cannot be worked out. Choose another zone or update the Spark."
            )
        case "AUTOMATION_RUN_PANICKED":
            String(
                localized:
                    "This run stopped because the model loop behind it failed on the Spark. The schedule carries on; try the run again."
            )
        case "WEB_HOURLY_LIMIT":
            String(
                localized:
                    "This Spark has made as many web calls as it may in one hour, so this run made none. Try again later in the hour."
            )
        case "WEB_FETCH_SCHEME_BLOCKED", "WEB_FETCH_URL_INVALID":
            String(localized: "That is not an address this Spark will open, so it was not read.")
        case "WEB_FETCH_PRIVATE_ADDRESS":
            String(
                localized:
                    "That address is this Spark or something else inside your own network, so it was not read."
            )
        case "WEB_FETCH_HOST_UNRESOLVABLE":
            String(localized: "That site name could not be looked up, so nothing was read.")
        case "WEB_FETCH_ROBOTS_DENIED":
            String(
                localized:
                    "That site asks automated readers to stay away from this page, so it was not read."
            )
        case "WEB_FETCH_TOO_MANY_REDIRECTS":
            String(localized: "That address kept forwarding on to another, so it was not read.")
        case "WEB_FETCH_STATUS", "WEB_FETCH_UNREACHABLE":
            String(localized: "That page could not be read, so it is not part of this answer.")
        case "WEB_DOMAIN_BLOCKED":
            String(localized: "Your site list does not allow that address, so it was not read.")
        case "WEB_SEARCH_DISABLED":
            String(
                localized:
                    "Search is off on this Spark. It can still read a page you name yourself."
            )
        case "WEB_SEARCH_QUERY_INVALID":
            String(localized: "That search text was empty or too long, so no search was made.")
        case "WEB_SEARCH_UNAVAILABLE":
            String(localized: "The search service could not be reached, so there are no results.")
        case "WEB_TOOL_CALL_LIMIT", "WEB_RUN_BYTE_LIMIT", "WEB_RUN_TIME_LIMIT":
            String(
                localized:
                    "This answer reached the limit on how much one run may read, so it stopped before finishing. Ask again more narrowly."
            )
        case "WEB_RUN_MODEL_FAILED":
            String(localized: "The model on this Spark did not answer, so there is no result.")
        default: nil
        }
    }

    /// The private overlay's own operation failures, each with the action that follows.
    static func privateOverlay(_ code: String) -> String? {
        switch code {
        case "PRIVATE_OVERLAY_SETUP_FAILED":
            String(
                localized:
                    "This Spark could not finish setting up private remote access. Local access is unchanged; try turning it on again."
            )
        case "PRIVATE_OVERLAY_LOGIN_TIMEOUT":
            String(
                localized:
                    "The sign-in link was not completed in time. Turn private remote access on again for a fresh link."
            )
        case "PRIVATE_OVERLAY_ROUTE_UNVERIFIED":
            String(
                localized:
                    "This Spark signed in but could not yet reach itself on its private address. Check again in a moment."
            )
        default: nil
        }
    }
}
