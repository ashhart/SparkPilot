import Foundation
import Observation
import SparkAPI
import SparkDesignSystem
import SparkSecurity

enum RemoteAccessFailurePresentation {

    static func describeDisableError(_ error: any Error) -> String {
        if error is UserPresenceAuthorizationError {
            return
                String(
                    localized:
                        "Remote access is still on. This Apple device could not confirm you are present."
                )
        }
        if let api = error as? APIError {
            switch api.code {
            case "USER_PRESENCE_REQUIRED", "USER_PRESENCE_INVALID", "USER_PRESENCE_EXPIRED",
                "USER_PRESENCE_NOT_REGISTERED", "USER_PRESENCE_SIGNER_UNAVAILABLE",
                "USER_PRESENCE_ENROLLMENT_UNAVAILABLE":
                return
                    String(
                        localized:
                            "Remote access is still on. This Apple device could not confirm you are present."
                    )
            case "REMOTE_DISABLE_FAILED":
                return String(
                    localized:
                        "The Spark could not turn off remote access. Try again while near it."
                )
            case "REMOTE_DISABLE_STATUS_TIMEOUT":
                return
                    String(
                        localized:
                            "The Spark is still turning off remote access. Check again while near it."
                    )
            default:
                break
            }
            if api.statusCode == 401 || api.statusCode == 403 {
                return String(
                    localized: "Only an owner device can turn off remote access for this Spark."
                )
            }
        }
        return String(
            localized:
                "Remote access is still on. Check the connection to your Spark and try again."
        )
    }

    static func describeEnableError(_ error: any Error) -> String {
        if error is UserPresenceAuthorizationError {
            return
                String(
                    localized:
                        "Remote access is still off. This Apple device could not confirm you are present."
                )
        }
        if let api = error as? APIError {
            switch api.code {
            case "PRIVATE_OVERLAY_UNAVAILABLE", "PREVIEW_STALE":
                return
                    String(
                        localized:
                            "The Spark's Tailscale route is not reachable now. Check Tailscale on the Spark and request a new review."
                    )
            case "USER_PRESENCE_REQUIRED", "USER_PRESENCE_INVALID", "USER_PRESENCE_EXPIRED",
                "USER_PRESENCE_NOT_REGISTERED", "USER_PRESENCE_SIGNER_UNAVAILABLE",
                "USER_PRESENCE_ENROLLMENT_UNAVAILABLE":
                return
                    String(
                        localized:
                            "Remote access is still off. This Apple device could not confirm you are present."
                    )
            case "REMOTE_DISABLE_STATUS_TIMEOUT":
                // A poll timeout leaves enablement unresolved, so do not report remote access as disabled.
                return
                    String(
                        localized:
                            "The Spark is still enabling remote access. Refresh in a moment to see the result."
                    )
            case "REMOTE_ENABLE_FAILED":
                return
                    String(
                        localized:
                            "The Spark could not enable its private remote route. Local access is unchanged."
                    )
            default:
                break
            }
            if api.statusCode == 401 || api.statusCode == 403 {
                return String(
                    localized: "Only an owner device can enable remote access for this Spark."
                )
            }
        }
        return String(
            localized:
                "Remote access is still off. Check the local connection to your Spark and try again."
        )
    }
}
