import Foundation

extension SparkErrorCopy {
    /// Refusals a guest of someone else's Spark can meet, worded for the guest rather than the owner.
    static func sharing(_ code: String) -> String? {
        switch code {
        case "GUEST_AWAITING_OWNER":
            String(
                localized:
                    "The owner has not confirmed your access yet. You will be able to chat as soon as they do."
            )
        case "GUEST_ACCESS_PAUSED":
            String(
                localized: "The owner has paused your access. It works again when they resume it."
            )
        case "GUEST_ACCESS_REVOKED":
            String(
                localized:
                    "The owner has ended your access to this Spark. It has been removed from this device."
            )
        case "GUEST_ACCESS_EXPIRED":
            String(
                localized:
                    "Your access to this Spark has run out. Ask the owner for a new invitation."
            )
        case "GUEST_MODEL_NOT_ALLOWED":
            String(
                localized:
                    "The owner did not share that model with you. Choose one of the models they did."
            )
        case "GUEST_OUTSIDE_HOURS":
            String(
                localized:
                    "This Spark is outside the hours the owner shared. Try again inside them; the hours are shown in the owner's time zone."
            )
        case "GUEST_BUDGET_EXHAUSTED":
            String(
                localized:
                    "You have used today's share of this Spark. It starts again when the owner's day rolls over."
            )
        case "GUEST_CONCURRENCY_LIMIT":
            String(
                localized:
                    "One of your requests is still running. It will go through once that finishes."
            )
        case "GUEST_SCHEDULE_UNAVAILABLE":
            String(
                localized:
                    "This Spark cannot work out the time zone your hours are set in, so it is refusing rather than guessing. The owner needs to set the zone again."
            )
        case "GUEST_PARAMETER_NOT_ALLOWED":
            String(
                localized:
                    "Shared access covers conversation only. This request asked for something a guest cannot use on someone else's Spark."
            )
        case "SHARED_ACCESS_POLICY_INVALID":
            String(
                localized:
                    "One of the limits on this share is not usable. Check the models, hours and daily budget, then save again."
            )
        case "HOUSEHOLD_UNAVAILABLE":
            String(
                localized:
                    "Household sharing is unavailable on this Spark. Check its connection and runtime version."
            )
        case "HOUSEHOLD_ACCESS_REQUIRED":
            String(
                localized:
                    "Ask the owner to add you to this Spark’s household before opening shared notes."
            )
        case "HOUSEHOLD_MEMBER_UNAVAILABLE":
            String(
                localized: "That household member is no longer available. Refresh the member list."
            )
        case "HOUSEHOLD_OWNER_REQUIRED":
            String(localized: "Only the Spark owner can change household membership.")
        case "HOUSEHOLD_NOTE_INVALID":
            String(localized: "This note could not be saved. Check its text and try again.")
        case "HOUSEHOLD_NOTE_READ_ONLY":
            String(
                localized:
                    "You can read this shared note; ask its author or the owner to change it."
            )
        case "HOUSEHOLD_NOTE_CHANGED":
            String(
                localized:
                    "Someone changed this note while you were editing. Refresh it before saving again."
            )
        case "HOUSEHOLD_FULL":
            String(
                localized:
                    "This household has reached its limit. Ask the owner to remove an unused member or note."
            )
        case "GPU_DRIVER_MISMATCH":
            String(
                localized:
                    "This Spark's graphics driver was updated but the running system still has the old one loaded. Restart the Spark, then start the model again."
            )
        default: nil
        }
    }
}
