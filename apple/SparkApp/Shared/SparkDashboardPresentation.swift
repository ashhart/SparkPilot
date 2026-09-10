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

/// Semantic status independent of localised display text.
public enum SparkStatusTone: String, Sendable, Equatable, CaseIterable {
    /// Nothing is wrong, or nothing is known yet.
    case normal
    /// Requires owner attention.
    case attention
}

/// Pairs a status label with its semantic tone.
public struct SparkStatusValue: Sendable, Equatable {
    public let text: String
    public let tone: SparkStatusTone

    public init(_ text: String, tone: SparkStatusTone = .normal) {
        self.text = text
        self.tone = tone
    }
}

/// Binds a dashboard to its physical coordinator and optional logical cluster identity.
public struct SparkDashboardIdentityExpectation: Sendable, Equatable {
    public let coordinatorNodeID: SparkNodeID
    public let authorityFingerprint: String?
    public let clusterID: SparkClusterID?

    public init(
        coordinatorNodeID: SparkNodeID,
        authorityFingerprint: String?,
        clusterID: SparkClusterID?
    ) {
        self.coordinatorNodeID = coordinatorNodeID
        self.authorityFingerprint = authorityFingerprint
        self.clusterID = clusterID
    }
}

public enum SparkDashboardIdentityIssue: Sendable, Equatable {
    case coordinatorMismatch
    case authorityMismatch
    case clusterMismatch
}

enum ModelPreviewError: Error {
    case missingAcceptedDigest
    case actionMismatch
}

public enum ModelLifecycleAction: String, Codable, Sendable, Equatable {
    case install
    case load
    case unload
    case remove
}

public enum ModelOperationRecoveryAction: Sendable, Equatable {
    case retryStatus
    case retryIncompleteOperation
    case refreshPreview
    case retryTerminalFailure
    /// The Spark must reboot before this model can start; retrying alone cannot help.
    case restartSpark

    var guidance: String {
        switch self {
        case .retryStatus:
            String(
                localized:
                    "The Spark may still be working. Check status before trying to start again."
            )
        case .retryIncompleteOperation:
            String(
                localized: "Check what happened on the Spark before retrying the unfinished action."
            )
        case .refreshPreview:
            String(
                localized:
                    "The earlier review is no longer current. Review the action again before continuing."
            )
        case .retryTerminalFailure:
            String(
                localized:
                    "The action stopped. Retry checks the Spark again before another attempt."
            )
        case .restartSpark:
            String(
                localized:
                    "Restart the Spark first, wait for it to reconnect, then launch your model again."
            )
        }
    }

    func accessibilityLabel(modelName: String) -> String {
        switch self {
        case .retryStatus: String(localized: .checkOperationStatus(modelName))
        case .retryIncompleteOperation: String(localized: .retryUnfinishedAction(modelName))
        case .refreshPreview: String(localized: .reviewActionAgain(modelName))
        case .retryTerminalFailure: String(localized: .retryFailedAction(modelName))
        case .restartSpark: String(localized: .restartSparkThenLaunch(modelName))
        }
    }
}

enum SparkDashboardOwnerPresentation {
    /// Open WebUI signs in by email; owners who leave it blank use this fixed local address.
    static let defaultOpenWebUIAdminEmail = "owner@spark.local"

    static func openWebUIAdminEmail(_ entered: String) -> String {
        let trimmed = entered.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultOpenWebUIAdminEmail : trimmed
    }

    /// Returns the first unmet Open WebUI form requirement or nil when installation can start.
    static func openWebUIInstallBlocker(
        offered: Bool,
        installed: Bool,
        availableRevision: String?,
        email: String,
        name: String,
        password: String,
        acceptedRevision: String?
    ) -> String? {
        guard offered else {
            return String(localized: "This Spark has not offered the Open WebUI recipe yet.")
        }
        if installed { return String(localized: "Open WebUI is already installed.") }
        // The email is optional: a blank one signs in as the fixed local address.
        if !email.isEmpty, !email.contains("@") {
            return String(localized: "Enter a full email address, or leave it blank.")
        }
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "Enter a name for the administrator.")
        }
        if !(16...128).contains(password.count) {
            return String(localized: "The password must be 16 to 128 characters.")
        }
        if let availableRevision, acceptedRevision != availableRevision {
            return String(localized: .acceptSignedRecipeToContinue(availableRevision))
        }
        return nil
    }

    static let overviewTitle = String(localized: "Overview")
    static let overviewSubtitle = String(
        localized: "Health, models and services on this DGX Spark."
    )
    static let modelServiceTitle = String(localized: "Model service")

    struct RuntimeUpdateNotice: Equatable {
        let title: String
        let detail: String
        let actionTitle: String
    }

    static func runtimeUpdateNotice(
        canInstallBundledRuntime: Bool
    ) -> RuntimeUpdateNotice? {
        guard canInstallBundledRuntime else { return nil }
        return RuntimeUpdateNotice(
            title: String(localized: "Runtime update required"),
            detail: String(
                localized:
                    "Install the latest SparkPilot runtime to unlock settings and device pairing."
            ),
            actionTitle: String(localized: "Update Spark")
        )
    }

    static func activeModelDetail(activeModelID: String?, models: [SparkModel]) -> String {
        guard let activeModelID else { return String(localized: "No active model") }
        return models.first { $0.id == activeModelID }?.displayName
            ?? String(localized: "A model is active")
    }

    static func unfinishedActionTitle(_ action: ModelLifecycleAction) -> String {
        switch action {
        case .install: String(localized: "Download didn't finish")
        case .load: String(localized: "Starting a model didn't finish")
        case .unload: String(localized: "Stopping a model didn't finish")
        case .remove: String(localized: "Model removal didn't finish")
        }
    }

    static func operationStageLabel(_ stage: String?, action: ModelLifecycleAction) -> String {
        switch stage {
        case "validating", "validation": String(localized: "Checking the request")
        case "disk_preflight": String(localized: "Checking storage")
        case "downloading": String(localized: "Downloading")
        case "verifying": String(localized: "Verifying the download")
        case "materialising", "materialise": String(localized: "Finishing the download")
        case "loading": String(localized: "Starting the model")
        case "preparing_offload_table": String(localized: "Preparing Qwen for this Spark")
        case "preparing_engine_image": String(localized: "Preparing the inference engine")
        case "draining_previous": String(localized: "Finishing requests on the current model")
        case "stopping_previous": String(localized: "Stopping the current model")
        case "starting": String(localized: "Starting the model")
        // Health checks include model loading, compilation and warmup.
        case "health_check": String(localized: "Loading the model")
        case "serving_probe": String(localized: "Checking the model responds")
        case "verifying_memory_recovery": String(localized: "Checking memory was released")
        case "restoring_previous_engine": String(localized: "Restoring the previous model")
        case "verifying_previous_engine": String(localized: "Checking the previous model")
        case "draining": String(localized: "Finishing active requests")
        case "running": String(localized: "Running the action")
        case nil:
            switch action {
            case .install: String(localized: "Downloading")
            case .load: String(localized: "Starting the model")
            case .unload: String(localized: "Stopping the model")
            case .remove: String(localized: "Removing the model")
            }
        default:
            stage?.replacingOccurrences(of: "_", with: " ").localizedCapitalized
                ?? String(localized: "Action in progress")
        }
    }

    /// Explain only reported stages; missing file counts and transfer rates are never inferred.
    static func operationStageDetail(_ stage: String?) -> String? {
        switch stage {
        case "disk_preflight":
            String(localized: "Checking there is enough space for the model.")
        case "downloading":
            String(
                localized:
                    "Downloading the model to your Spark. Next, the Spark checks the downloaded files."
            )
        case "verifying":
            String(localized: "Checking the downloaded files match the signed model recipe.")
        case "materialising", "materialise":
            String(
                localized:
                    "Putting the checked files in place. You can launch the model when this finishes."
            )
        case "preparing_offload_table":
            String(
                localized:
                    "Preparing a reusable offload table; first launch can take several minutes. You can leave this screen while the Spark works."
            )
        case "preparing_engine_image":
            String(
                localized:
                    "Preparing the software that runs your model. The first launch can take longer."
            )
        case "health_check", "loading", "starting":
            String(
                localized:
                    "Loading the model into memory and preparing it to answer. This can take a few minutes."
            )
        case "serving_probe":
            String(
                localized: "Waiting for a successful response before showing the model as ready."
            )
        default: nil
        }
    }

    /// The steps an install or a launch goes through, in the order the runtime reports them.
    static func stepPlan(for action: ModelLifecycleAction) -> [SparkOperationStep]? {
        switch action {
        case .install:
            return [
                SparkOperationStep(
                    id: "preparing_engine_image",
                    label: String(localized: "Prepare the inference engine")
                ),
                SparkOperationStep(id: "disk_preflight", label: String(localized: "Check storage")),
                SparkOperationStep(
                    id: "downloading",
                    label: String(localized: "Download the model")
                ),
                SparkOperationStep(id: "verifying", label: String(localized: "Verify the files")),
                SparkOperationStep(
                    id: "materialising",
                    label: String(localized: "Put it in place")
                ),
            ]
        case .load:
            return [
                SparkOperationStep(
                    id: "preparing_engine_image",
                    label: String(localized: "Prepare the inference engine")
                ),
                SparkOperationStep(id: "starting", label: String(localized: "Start the model")),
                SparkOperationStep(
                    id: "health_check",
                    label: String(localized: "Load it into memory")
                ),
                SparkOperationStep(
                    id: "serving_probe",
                    label: String(localized: "Check it answers")
                ),
            ]
        case .unload, .remove:
            return nil
        }
    }

    /// Stage tokens the runtime uses that belong to a step under another name.
    static func stepID(forStage stage: String?) -> String? {
        switch stage {
        case "validating", "validation": "disk_preflight"
        case "materialise": "materialising"
        case "preparing_offload_table": "preparing_engine_image"
        case "loading": "health_check"
        case "draining_previous", "stopping_previous": "preparing_engine_image"
        default: stage
        }
    }

    static func determinateProgress(_ operation: SparkAPI.Operation) -> Double? {
        // Show engine-image preparation as an indeterminate stage because privileged milestones do not measure byte completion.
        guard operation.stage != "preparing_engine_image",
            operation.stage != "preparing_offload_table"
        else { return nil }
        return operation.progress
    }
}
