import Foundation
import Observation
import SparkAPI
import SparkCore
import SparkLanguageModel
import SparkLibrary
import SparkSecurity
import SparkTransport

public struct SparkChatFailure: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case offline
        case identityMismatch
        case authentication
        case activeModelChanged
        case transport
    }

    public let kind: Kind
    public let title: String
    public let message: String

    public init(kind: Kind, title: String, message: String) {
        self.kind = kind
        self.title = title
        self.message = message
    }

    static func resolve(_ error: any Error) -> SparkChatFailure {
        if let error = error as? SparkChatConnectionError {
            switch error {
            case .identityMismatch:
                return SparkChatFailure(
                    kind: .identityMismatch,
                    title: String(localized: "Spark identity changed"),
                    message:
                        String(
                            localized:
                                "The saved route no longer proves it is the Spark you paired with. Remove and pair it again before chatting."
                        )
                )
            case .activeModelChanged:
                return SparkChatFailure(
                    kind: .activeModelChanged,
                    title: String(localized: "The active model changed"),
                    message:
                        String(
                            localized:
                                "Check the Spark's model screen, then retry with its current active model."
                        )
                )
            }
        }
        if let error = error as? SparkInferenceError {
            switch error {
            case .readinessTimeout:
                // Nothing changed here: the model is slow or stuck, so send the owner to wait or check load progress.
                return SparkChatFailure(
                    kind: .transport,
                    title: String(localized: "The model is still loading"),
                    message:
                        String(
                            localized:
                                "The Spark did not report the model ready in time. Wait a moment and try again, or check the model's load progress on the Spark."
                        )
                )
            case .modelNotInstalled, .modelReplacementRequired:
                return SparkChatFailure(
                    kind: .activeModelChanged,
                    title: String(localized: "The active model changed"),
                    message:
                        String(
                            localized:
                                "Check the Spark's model screen, then retry with its current active model."
                        )
                )
            // Map the failure kind to copy while keeping associated mapper and transport text in diagnostics.
            case .transport, .unsupportedContent, .unsupportedCapability:
                return SparkChatFailure(
                    kind: .transport,
                    title: String(localized: "Spark could not answer"),
                    message: Self.inferenceFailureMessage(error)
                )
            }
        }
        if let error = error as? ChatError {
            if error.code == "PROTOCOL_UNSUPPORTED" {
                return SparkChatFailure(
                    kind: .authentication,
                    title: String(localized: "Update needed"),
                    message: ChatError.message(for: error)
                )
            }
            if error.statusCode == 401 || error.statusCode == 403 {
                return SparkChatFailure(
                    kind: .authentication,
                    title: String(localized: "Spark refused this device"),
                    message:
                        String(
                            localized:
                                "The signed request was not accepted. Pair this device again before retrying."
                        )
                )
            }
            return SparkChatFailure(
                kind: .transport,
                title: String(localized: "Spark could not answer"),
                message: ChatError.message(for: error)
            )
        }
        if let error = error as? APIError {
            if let code = error.code, let message = WebChatFailure.message(for: code) {
                return SparkChatFailure(
                    kind: .transport,
                    title: String(localized: "Internet access needs attention"),
                    message: message
                )
            }
            if let code = error.code, let limited = GuestChatLimit.failure(for: code) {
                return limited
            }
            if error.code == "PROTOCOL_UNSUPPORTED" {
                return SparkChatFailure(
                    kind: .authentication,
                    title: String(localized: "Update needed"),
                    message: APIError.message(for: error)
                )
            }
            if error.statusCode == 401 || error.statusCode == 403 {
                return SparkChatFailure(
                    kind: .authentication,
                    title: String(localized: "Spark refused this device"),
                    message:
                        String(
                            localized:
                                "The signed request was not accepted. Pair this device again before retrying."
                        )
                )
            }
            return SparkChatFailure(
                kind: .transport,
                title: String(localized: "Spark could not answer"),
                message: APIError.message(for: error)
            )
        }
        if let error = error as? PinnedTransportError {
            switch error {
            case .certificateRejected:
                return SparkChatFailure(
                    kind: .identityMismatch,
                    title: String(localized: "Spark identity changed"),
                    message: String(
                        localized:
                            "The Spark presented a different certificate. Chat stayed blocked."
                    )
                )
            case .unreachable:
                return SparkChatFailure(
                    kind: .offline,
                    title: String(localized: "Spark is offline"),
                    message: String(localized: "Reconnect to the Spark and retry this message.")
                )
            case .insecureScheme, .malformedPin, .nonHTTPResponse, .redirected:
                return SparkChatFailure(
                    kind: .authentication,
                    title: String(localized: "Spark connection was refused"),
                    message: String(
                        localized: "The saved route could not make a secure pinned connection."
                    )
                )
            }
        }
        if error is URLError {
            return SparkChatFailure(
                kind: .offline,
                title: String(localized: "Spark is offline"),
                message: String(localized: "Reconnect to the Spark and retry this message.")
            )
        }
        // Do not display arbitrary error descriptions that may expose type names or stored properties.
        return SparkChatFailure(
            kind: .transport,
            title: String(localized: "Spark could not answer"),
            message: String(
                localized:
                    "The Spark did not answer this message. Check the connection and try again."
            )
        )
    }

    /// Classifies transport-shaped inference failures without displaying their diagnostic strings.
    private static func inferenceFailureMessage(_ error: SparkInferenceError) -> String {
        switch error {
        case .unsupportedContent:
            String(
                localized: "This message holds something the Spark's chat service cannot accept."
            )
        case .unsupportedCapability:
            String(localized: "The active model does not support what this message asked for.")
        default:
            String(
                localized:
                    "The Spark did not answer this message. Check the connection and try again."
            )
        }
    }
}

public enum SparkChatGenerationState: Equatable, Sendable {
    case ready
    case streaming
    case cancelled
    case failed(SparkChatFailure)
}

/// Say which of the owner's limits a guest ran into, rather than reporting a refused device.
enum GuestChatLimit {
    static func failure(for code: String) -> SparkChatFailure? {
        guard let message = message(for: code) else { return nil }
        return SparkChatFailure(
            kind: .authentication,
            title: String(localized: "Shared access limit"),
            message: message
        )
    }

    static func message(for code: String) -> String? {
        switch code {
        case "GUEST_MODEL_NOT_ALLOWED":
            String(localized: "The owner has not shared this model with you. Choose another one.")
        case "GUEST_OUTSIDE_HOURS":
            String(localized: "You can use this Spark only during the hours its owner set.")
        case "GUEST_BUDGET_EXHAUSTED":
            String(
                localized:
                    "You have used today's share of this Spark. It starts again at the owner's midnight."
            )
        case "GUEST_CONCURRENCY_LIMIT":
            String(localized: "Wait for your other message to finish before sending another.")
        case "GUEST_AWAITING_OWNER":
            String(
                localized:
                    "The owner has not confirmed your access yet. They will get a prompt on their device."
            )
        case "GUEST_ACCESS_PAUSED":
            String(localized: "The owner has paused your access to this Spark.")
        case "GUEST_ACCESS_REVOKED":
            String(localized: "The owner has stopped sharing this Spark with you.")
        case "GUEST_ACCESS_EXPIRED":
            String(
                localized: "Your access to this Spark has run out. Ask the owner for a new link."
            )
        case "GUEST_SCHEDULE_UNAVAILABLE":
            String(
                localized:
                    "This Spark cannot read the time zone your hours are set in. Ask the owner to check it."
            )
        case "GUEST_BUDGET_UNAVAILABLE":
            String(
                localized:
                    "Your Spark could not check the size of this request. Try again, or ask the owner to update its engine."
            )
        case "GUEST_INPUT_UNSUPPORTED":
            String(
                localized:
                    "Shared access currently supports text chat. Remove attachments and try again."
            )
        case "GUEST_PARAMETER_NOT_ALLOWED":
            String(localized: "Shared access covers chat only, so that request was refused.")
        default:
            nil
        }
    }
}

enum WebChatFailure {
    static func message(for code: String) -> String? {
        switch code {
        case "WEB_RUN_TIME_LIMIT":
            String(
                localized:
                    "This search took too long. Try a more specific question, or turn off web access to ask your model directly."
            )
        case "WEB_ACCESS_POLICY_OFF", "WEB_ACCESS_CHATS_NOT_PERMITTED",
            "WEB_ACCESS_HARNESS_NOT_PERMITTED":
            String(
                localized:
                    "Internet access is off for this Spark. Turn off web access in this chat, or ask the owner to enable it in Automations."
            )
        case "WEB_RUN_MODEL_FAILED":
            String(
                localized:
                    "Your Spark could not finish this answer. Check that the model is ready, then retry."
            )
        default: nil
        }
    }
}
