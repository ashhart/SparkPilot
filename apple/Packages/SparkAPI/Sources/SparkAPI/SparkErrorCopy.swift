import Foundation

/// Owner copy for every code in docs/ERROR_CODES.md; only an undocumented code shows as a code.
public enum SparkErrorCopy {
    public static func message(for code: String) -> String? {
        connection(code) ?? identity(code) ?? evidence(code) ?? model(code) ?? operations(code)
            ?? sharing(code) ?? automations(code) ?? web(code) ?? privateOverlay(code)
    }

    static func connection(_ code: String) -> String? {
        switch code {
        case "NODE_NOT_REACHABLE":
            String(localized: "This Spark did not answer. SparkPilot is showing its saved state.")
        case "TLS_IDENTITY_MISMATCH":
            String(
                localized:
                    "The Spark answering on this address is not the one you paired with. SparkPilot blocked the connection; review recovery before continuing."
            )
        case "API_VERSION_UNSUPPORTED":
            String(
                localized:
                    "This app and this Spark's runtime are different versions. Update one of them, then try again."
            )
        case "RATE_LIMITED":
            String(localized: "This Spark is asking for a short pause. Try again in a moment.")
        case "REMOTE_ACCESS_UNAVAILABLE":
            String(
                localized:
                    "The remote route is unavailable. Use the local network, or check remote access on the Spark."
            )
        case "REMOTE_IDENTITY_INVALID":
            String(localized: "Remote sign-in expired. Sign in again to use the remote route.")
        case "REMOTE_ROTATION_UNAVAILABLE":
            String(
                localized:
                    "This Spark cannot rotate its remote credential right now. Try again once remote access is healthy."
            )
        case "REMOTE_ROTATION_FAILED":
            String(
                localized:
                    "The remote credential was not rotated. The existing one still works; inspect the job before retrying."
            )
        case "REMOTE_MODE_INVALID":
            String(localized: "That remote mode is not supported by this Spark.")
        case "PRIVATE_OVERLAY_UNAVAILABLE":
            String(
                localized:
                    "This Spark has no private overlay address yet. Enrol it on the Spark, then request a new review."
            )
        case "INTERNAL_ERROR":
            String(
                localized:
                    "The Spark could not finish this request. Its diagnostics hold the reason under this request's ID."
            )
        default: nil
        }
    }

    static func identity(_ code: String) -> String? {
        switch code {
        case "DEVICE_NOT_PAIRED":
            String(localized: "This device is not paired with that Spark yet. Pair it first.")
        case "DEVICE_REVOKED":
            String(
                localized:
                    "This device's access was revoked. Ask the owner to invite it again."
            )
        case "SIGNATURE_INVALID":
            String(
                localized:
                    "This Spark refused this device's signature. Pair the device again if it keeps happening."
            )
        case "REQUEST_REPLAYED":
            String(localized: "That request was already seen. Try it once more.")
        case "CLOCK_SKEW_TOO_LARGE":
            String(
                localized:
                    "This device's clock is too far from the Spark's. Correct the date and time, then try again."
            )
        case "ROLE_FORBIDDEN":
            String(localized: "This device's role does not allow that action.")
        case "AUDIT_UNAVAILABLE":
            String(
                localized:
                    "The Spark cannot record this change in its audit log, so it refused it. Try again once the Spark is healthy."
            )
        case "USER_PRESENCE_REQUIRED":
            String(localized: "Confirm on this device to make that change.")
        case "USER_PRESENCE_NOT_REGISTERED":
            String(
                localized:
                    "This device has no confirmation key on that Spark yet. Pair it again to register one."
            )
        case "USER_PRESENCE_EXPIRED":
            String(localized: "That confirmation expired. Confirm again to continue.")
        case "USER_PRESENCE_INVALID":
            String(localized: "The Spark did not accept that confirmation. Start the change again.")
        case "USER_PRESENCE_KEY_CONFLICT":
            String(
                localized:
                    "A different confirmation key is registered for this device. Recover the key before changing it."
            )
        case "TARGET_IDENTITY_MISMATCH":
            String(
                localized:
                    "That action named a Spark this request does not belong to. Reopen the Spark and try again."
            )
        default: nil
        }
    }

    static func evidence(_ code: String) -> String? {
        switch code {
        case "IDEMPOTENCY_KEY_REUSED":
            String(
                localized:
                    "The Spark has already seen that request under a different body. Start the action again."
            )
        case "EVENT_CURSOR_EXPIRED":
            String(localized: "SparkPilot fell too far behind this Spark's events and refreshed.")
        case "PREVIEW_BODY_TOO_LARGE":
            String(localized: "This preview is too large to open. Reduce its size and try again.")
        case "PREVIEW_REQUIRED":
            String(localized: "Review what will change before this can be applied.")
        case "PREVIEW_INVALID":
            String(localized: "That review could not be read. Request a new one.")
        case "PREVIEW_NOT_FOUND", "PREVIEW_EXPIRED":
            String(localized: "That review is no longer current. Request a new one.")
        case "PREVIEW_ACTION_MISMATCH":
            String(
                localized: "That review was for a different action. Request one for this action."
            )
        case "PREVIEW_ALREADY_ACCEPTED":
            String(localized: "That review was already used. Request a new one.")
        case "PREVIEW_STALE":
            String(
                localized:
                    "The Spark changed since that review. Request a new one and read what is different."
            )
        case "ACTIVE_INFERENCE_EVIDENCE_UNAVAILABLE":
            String(
                localized:
                    "The Spark cannot currently prove what its engine is doing. Wait for it to recover, then request a new review."
            )
        case "ANALYSIS_INPUT_INVALID":
            String(localized: "Check the instruction, document or limits named in this request.")
        case "INVITATION_EXPIRED":
            String(localized: "That invitation expired. Ask the owner for another one.")
        case "INVITATION_ALREADY_USED":
            String(localized: "That invitation has already been used. Ask for a new one.")
        default: nil
        }
    }
}
