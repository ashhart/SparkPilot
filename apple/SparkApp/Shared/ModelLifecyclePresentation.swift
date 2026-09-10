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

public struct ModelLoadConfiguration: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let modelID: String
    public let modelName: String
    public let replaceActive: Bool
    public let profiles: [SparkModelProfile]
    /// A remembered preset this recipe no longer offers, shown so the owner knows why they are choosing again.
    public var staleSavedProfileID: String? = nil
}

public struct ModelActionConfirmation: Identifiable, Sendable, Equatable {
    public let idempotencyKey: UUID
    public let modelID: String
    public let lifecycleAction: ModelLifecycleAction
    public let retryRequest: ModelOperationRetryRequest
    public let preview: GeneratedAPI.ModelActionPreview
    /// Retains the selected profile with its preview so confirmation describes the limits of the accepted request.
    public let profileName: String?
    public let profile: SparkModelProfile?

    public init(
        idempotencyKey: UUID,
        modelID: String,
        lifecycleAction: ModelLifecycleAction,
        retryRequest: ModelOperationRetryRequest,
        preview: GeneratedAPI.ModelActionPreview,
        profileName: String? = nil,
        profile: SparkModelProfile? = nil
    ) {
        self.idempotencyKey = idempotencyKey
        self.modelID = modelID
        self.lifecycleAction = lifecycleAction
        self.retryRequest = retryRequest
        self.preview = preview
        self.profileName = profileName ?? profile?.displayName
        self.profile = profile
    }

    public var id: UUID { idempotencyKey }
    public var canApply: Bool { preview.blockers.isEmpty }

    /// Preserves the review's memory deficit when runtime headroom saturates at zero, without changing signed admission.
    var memoryShortfallBytes: Int? {
        let evidence = preview.evidence
        guard let required = evidence.requiredMemoryBytes,
            let available = evidence.availableMemoryBytes,
            let reserve = evidence.systemReserveBytes,
            required >= 0, available >= 0, reserve >= 0
        else { return nil }
        let (shortfall, overflow) = (required - available).addingReportingOverflow(reserve)
        return !overflow && shortfall > 0 ? shortfall : nil
    }

    var memoryBalanceLabel: String {
        memoryShortfallBytes == nil
            ? String(localized: "Expected headroom") : String(localized: "Memory shortfall")
    }

    var memoryBalanceBytes: Int? {
        memoryShortfallBytes ?? preview.evidence.expectedMemoryHeadroomBytes
    }

    /// The engine's cache pool: attention cache plus per-request recurrent state (ADR-043).
    var contextCacheBytes: Int? {
        guard let cache = preview.evidence.kvCacheBytes else { return nil }
        return cache + (preview.evidence.stateBytes ?? 0)
    }

    /// What the context cache is sized for, from the reviewed preset's own limits.
    var contextCacheDetail: String? {
        guard contextCacheBytes != nil, let profile else { return nil }
        return String(
            localized: .contextCacheDetail(
                tokens: profile.maxModelLength.formatted(),
                requests: profile.maxSequences.formatted()
            )
        )
    }

    /// The context the Spark's free memory admits right now at the preset's request count; nothing when not even the weights fit.
    var largestContextNowLine: String? {
        guard let tokens = preview.evidence.maxContextNow,
            let requests = preview.evidence.maxSequencesNow,
            tokens > 0
        else { return nil }
        return String(
            localized: .largestContextNow(
                tokens: tokens.formatted(),
                requests: requests.formatted()
            )
        )
    }

    public var title: String {
        switch preview.action {
        case .install: String(localized: "Download this model?")
        case .load: String(localized: "Start this model?")
        case .warmup: String(localized: "Schedule this model?")
        case .replace: String(localized: "Replace the running model?")
        case .stop: String(localized: "Stop this model?")
        case .remove: String(localized: "Remove this model?")
        case .catalogueRefresh: String(localized: "Refresh the signed catalogue?")
        case .profileReenable: String(localized: "Re-enable this model profile?")
        case .workloadAdopt: String(localized: "Adopt this workload?")
        case .workloadRelinquish: String(localized: "Relinquish this workload?")
        case .remoteEnable: String(localized: "Enable remote access?")
        case .remoteDisable: String(localized: "Turn off remote access?")
        case .remoteRotate: String(localized: "Rotate remote credentials?")
        }
    }

    /// The confirm button names the action; "Apply" told the owner nothing.
    public var confirmTitle: String {
        switch preview.action {
        case .install: String(localized: "Confirm download")
        case .load: String(localized: "Start model")
        case .warmup: String(localized: "Schedule")
        case .replace: String(localized: "Replace model")
        case .stop: String(localized: "Stop model")
        case .remove: String(localized: "Remove model")
        case .catalogueRefresh: String(localized: "Refresh catalogue")
        case .profileReenable: String(localized: "Re-enable")
        case .workloadAdopt: String(localized: "Adopt")
        case .workloadRelinquish: String(localized: "Relinquish")
        case .remoteEnable: String(localized: "Enable")
        case .remoteDisable: String(localized: "Turn off")
        case .remoteRotate: String(localized: "Rotate")
        }
    }

    var applyAccessibilityLabel: String {
        switch preview.action {
        case .install: String(localized: "Apply model download")
        case .load: String(localized: "Apply model start")
        case .warmup: String(localized: "Schedule model warm-up")
        case .replace: String(localized: "Apply running model replacement")
        case .stop: String(localized: "Apply model stop")
        case .remove: String(localized: "Apply model removal")
        case .catalogueRefresh: String(localized: "Apply signed catalogue refresh")
        case .profileReenable: String(localized: "Apply model profile re-enable")
        case .workloadAdopt: String(localized: "Apply workload adoption")
        case .workloadRelinquish: String(localized: "Apply workload relinquish")
        case .remoteEnable: String(localized: "Apply remote access enablement")
        case .remoteDisable: String(localized: "Apply remote access disablement")
        case .remoteRotate: String(localized: "Apply remote credential rotation")
        }
    }

    var cancelAccessibilityLabel: String {
        String(localized: "Cancel this model action review")
    }

    public var clusterSummary: String? {
        guard let cluster = preview.evidence.cluster else { return nil }
        // An empty standalone status must not render as a zero-member cluster.
        if cluster.members.isEmpty, cluster.state == GeneratedAPI.ClusterState.standalone.rawValue,
            cluster.clusterId == nil, preview.target.clusterId == nil
        {
            return nil
        }
        let reachable = cluster.members.count(where: \.reachable)
        let leaders = cluster.members.count { $0.role == .leader }
        let workers = cluster.members.count { $0.role == .worker }
        let roleSummary = String(localized: .clusterRoleSummary(leaders: leaders, workers: workers))
        return String(
            localized: .clusterReadySummary(
                reachable: reachable,
                total: cluster.members.count,
                roles: roleSummary
            )
        )
    }

    public var evidenceDateText: String {
        Self.ownerDate(preview.evidenceTimestamps.systemObservedAt)
    }

    public var expiryDateText: String {
        Self.ownerDate(preview.expiresAt)
    }

    public var reinstallSummary: String? {
        if preview.consequences.reinstallRequired {
            return String(localized: "This model must be downloaded again before it can run.")
        }
        guard preview.action == .remove else { return nil }
        return String(
            localized: "A later download can reuse the verified cached content on this Spark."
        )
    }

    public var retainedContentSummary: String? {
        guard preview.action == .remove, preview.consequences.filesRemoved.isEmpty else {
            return nil
        }
        return String(localized: "No verified cached files will be deleted by this action.")
    }

    private static func ownerDate(_ raw: String) -> String {
        guard let date = RFC3339.date(from: raw) else {
            return String(localized: "Time unavailable")
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

public struct ModelLifecycleState: Sendable, Equatable {
    public let action: ModelLifecycleAction
    public let operation: SparkAPI.Operation?
    public let errorMessage: String?
    /// A headline for failures whose fix is not a retry, shown above the message.
    public let errorTitle: String?
    public let technicalErrorCode: String?
    public let recoveryAction: ModelOperationRecoveryAction?

    public init(
        action: ModelLifecycleAction,
        operation: SparkAPI.Operation?,
        errorMessage: String?,
        errorTitle: String? = nil,
        technicalErrorCode: String? = nil,
        recoveryAction: ModelOperationRecoveryAction? = nil
    ) {
        self.action = action
        self.operation = operation
        self.errorMessage = errorMessage
        self.errorTitle = errorTitle
        self.technicalErrorCode = technicalErrorCode
        self.recoveryAction = recoveryAction
    }

    public var isRunning: Bool {
        guard let operation else { return errorMessage == nil }
        return !operation.state.isTerminal && errorMessage == nil
    }

    func progressAccessibilityLabel(modelName: String) -> String? {
        guard let operation, !operation.state.isTerminal else { return nil }
        let stage = SparkDashboardOwnerPresentation.operationStageLabel(
            operation.stage,
            action: action
        )
        guard let progress = SparkDashboardOwnerPresentation.determinateProgress(operation) else {
            return String(localized: .pair(modelName, stage))
        }
        let percentage = Int(min(1, max(0, progress)) * 100)
        return String(
            localized: .modelStageProgress(model: modelName, stage: stage, percent: percentage)
        )
    }
}
