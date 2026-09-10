import Foundation
#if os(iOS)
    import UIKit
#elseif os(macOS)
    import IOKit.ps
#endif
import Observation
import SparkAPI
import SparkCore
import SparkDesignSystem
import SparkLibrary
import SparkSecurity
import SwiftUI
import UniformTypeIdentifiers
enum SparkDashboardFailurePresentation {

    /// Maps refused safety reviews to actionable copy instead of displaying only HTTP status codes.
    nonisolated static func profileReenableFailureMessage(_ error: any Error) -> String {
        guard let api = error as? APIError else {
            return String(
                localized: "This Spark could not prepare a safety review for that profile."
            )
        }
        if api.code == "ROLE_FORBIDDEN" || api.statusCode == 403 {
            return String(
                localized:
                    "Only the Spark's owner can re-enable a profile after a memory safety event. Ask the owner to review it on their device."
            )
        }
        if api.code == "USER_PRESENCE_REQUIRED" {
            return String(localized: "Confirm on this device to review that profile.")
        }
        if case .local(let message) = api.reason {
            return message
        }
        if let code = api.code {
            return String(localized: .safetyReviewRefused(code))
        }
        return String(localized: "This Spark refused the safety review.")
    }

    static func vllmStatus(for state: SparkInferenceState) -> SparkStatusValue {
        switch state {
        case .ready, .idle:
            return SparkStatusValue(String(localized: "Healthy"))
        case .unloaded:
            return SparkStatusValue(String(localized: "Ready · No model loaded"))
        case .loading:
            return SparkStatusValue(String(localized: "Starting"))
        case .draining, .unloading:
            return SparkStatusValue(String(localized: "Stopping"))
        case .failed:
            return SparkStatusValue(String(localized: "Needs attention"), tone: .attention)
        }
    }

    static func isDefiniteRejection(_ error: any Error) -> Bool {
        guard let api = error as? APIError, let statusCode = api.statusCode else { return false }
        guard (400..<500).contains(statusCode) else { return false }
        return statusCode != 408 && statusCode != 425 && statusCode != 429
    }

    static func acceptedDigest(_ request: ModelOperationRetryRequest) throws -> String {
        guard let digest = request.acceptedPreviewDigest else {
            throw ModelPreviewError.missingAcceptedDigest
        }
        return digest
    }

    static func loadTarget(
        _ request: ModelOperationRetryRequest
    ) -> GeneratedAPI.LoadModelRequestTarget? {
        guard request.targetNodeID != nil || request.targetClusterID != nil else { return nil }
        return GeneratedAPI.LoadModelRequestTarget(
            nodeId: request.targetNodeID,
            clusterId: request.targetClusterID
        )
    }

    static func isPreviewInvalidation(_ error: any Error) -> Bool {
        guard let code = (error as? APIError)?.code else { return false }
        return [
            "PREVIEW_STALE",
            "PREVIEW_EXPIRED",
            "PREVIEW_NOT_FOUND",
            "PREVIEW_ACTION_MISMATCH",
            "PREVIEW_ALREADY_ACCEPTED",
        ].contains(code)
    }

    static func lifecycleMessage(for error: any Error) -> String {
        if let api = error as? APIError {
            return APIError.message(for: api)
        }
        return String(
            localized:
                "The Spark could not complete this action. Check the connection and try again."
        )
    }

    /// The runtime refused the start because the Spark's loaded NVIDIA module no longer matches its installed driver.
    static let driverMismatchCode = "GPU_DRIVER_MISMATCH"

    /// Names the failure whose fix is a host restart rather than a retry.
    static func ownerOperationErrorTitle(_ operation: SparkAPI.Operation) -> String? {
        guard operation.errorCode == driverMismatchCode else { return nil }
        return String(localized: "Restart the Spark to finish the driver update")
    }

    static func terminalRecoveryAction(
        for operation: SparkAPI.Operation
    ) -> ModelOperationRecoveryAction {
        operation.errorCode == driverMismatchCode ? .restartSpark : .retryTerminalFailure
    }

    /// Maps documented operation codes to recovery copy while retaining unknown codes for support.
    static func ownerOperationError(_ operation: SparkAPI.Operation) -> String? {
        guard let code = operation.errorCode else { return nil }
        switch code {
        case "MODEL_DOWNLOAD_AUTH_REQUIRED":
            return
                String(
                    localized:
                        "The provider needs a credential for this model. Add a Hugging Face token under Hugging Face access, then retry."
                )
        case "CREDENTIAL_NOT_FOUND", "CREDENTIAL_PROVIDER_MISMATCH", "CREDENTIAL_INVALID":
            return
                String(
                    localized:
                        "The saved provider credential does not fit this model. Choose or replace it under Hugging Face access, then retry."
                )
        case "MODEL_INSUFFICIENT_DISK":
            return
                String(
                    localized:
                        "The Spark does not have enough free disk for this model. Free space under Storage, then retry."
                )
        case "MODEL_INSUFFICIENT_MEMORY":
            return
                String(
                    localized:
                        "This profile needs more memory than the Spark has free. Choose a smaller context or profile."
                )
        case "MODEL_DIGEST_MISMATCH":
            return
                String(
                    localized:
                        "The downloaded files did not match the signed recipe and were discarded. Retry the download."
                )
        case "MODEL_DOWNLOAD_FAILED":
            return String(
                localized:
                    "The download was interrupted. Finished chunks are kept; retry to resume."
            )
        case "MODEL_MANIFEST_UNAVAILABLE":
            return
                String(
                    localized:
                        "The provider's file list could not be read. Check the provider and request a new preview."
                )
        case "MODEL_LOAD_FAILED", "MODEL_HEALTH_CHECK_FAILED":
            return
                String(
                    localized:
                        "The model failed to start. Try the safe profile, or check the model's diagnostics."
                )
        case driverMismatchCode:
            return
                String(
                    localized:
                        "The NVIDIA driver on the Spark was updated, but the running kernel still has the old driver loaded. Restart the Spark, then launch the model again."
                )
        case "MODEL_PROFILE_UNSAFE":
            return
                String(
                    localized:
                        "This profile was disabled after a failure. Review its measurements and re-enable it first."
                )
        case "MODEL_RECIPE_INVALID", "MODEL_RECIPE_REVISION_MISMATCH":
            return String(
                localized: "The signed recipe changed. Request a new preview and review it again."
            )
        case "MODEL_ALREADY_INSTALLED":
            return String(
                localized:
                    "That revision is already installed. Use it, or remove it explicitly first."
            )
        case "MODEL_NOT_INSTALLED":
            return String(localized: "That model is not installed on this Spark. Install it first.")
        case "ENGINE_ACTIVE":
            return String(
                localized: "Another model is running. Stop it, or choose to replace it, then retry."
            )
        case "ENGINE_NOT_READY", "ENGINE_DRAINING":
            return String(
                localized:
                    "The Spark's engine is still changing state. Wait for it to settle, then retry."
            )
        case "OPERATION_CANCELLED":
            return String(localized: "This action was cancelled.")
        case "MODEL_ROUTE_INTERRUPTION":
            return String(
                localized:
                    "The connection to the Spark dropped during this action. Reconnect and retry."
            )
        default:
            // Retain gated-download recovery for provider response text as well as symbolic operation codes.
            if code.localizedCaseInsensitiveContains("provider"), code.contains("401") {
                return
                    String(
                        localized:
                            "Hugging Face rejected the saved token. Replace it under Hugging Face access, then retry."
                    )
            }
            if code.localizedCaseInsensitiveContains("provider"), code.contains("403") {
                return
                    String(
                        localized:
                            "Hugging Face denied this download. Accept the model's access terms or replace the saved token, then retry."
                    )
            }
            return String(localized: .sparkReportedForAction(code))
        }
    }
}
