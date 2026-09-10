import Foundation
import Observation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import SwiftUI

public struct SparkModelLaunchPlan: Identifiable, Sendable {
    public let id: UUID
    public let target: SparkChatTarget
    public let confirmation: ModelActionConfirmation?
    public let alreadyReady: Bool

    public init(
        id: UUID = UUID(),
        target: SparkChatTarget,
        confirmation: ModelActionConfirmation? = nil,
        alreadyReady: Bool = false
    ) {
        self.id = id
        self.target = target
        self.confirmation = confirmation
        self.alreadyReady = alreadyReady
    }

    public var requiresApproval: Bool {
        guard let confirmation else { return false }
        return confirmation.preview.action != .load || !confirmation.preview.warnings.isEmpty
            || !confirmation.canApply || confirmation.preview.consequences.modelToStop != nil
            || confirmation.preview.consequences.routeWithdrawal
    }
}

@MainActor
public protocol SparkModelLaunching: AnyObject {
    func profiles(for target: SparkChatTarget) async throws -> [SparkModelProfile]
    func preferredProfile(for target: SparkChatTarget, profiles: [SparkModelProfile]) -> String?
    /// A remembered preset id the model no longer offers; nil when the saved choice still applies.
    func staleSavedProfile(for target: SparkChatTarget, profiles: [SparkModelProfile]) -> String?
    func prepare(target: SparkChatTarget, profileID: String?) async throws -> SparkModelLaunchPlan
    func apply(_ plan: SparkModelLaunchPlan) async throws -> SparkChatTarget
    func apply(
        _ plan: SparkModelLaunchPlan,
        progress: @escaping @MainActor (SparkModelLaunchProgress) -> Void
    ) async throws -> SparkChatTarget
    func discard(_ plan: SparkModelLaunchPlan)
    func saveIdleSetting(
        _ setting: SparkModelIdleSetting,
        for target: SparkChatTarget,
        profile: SparkModelProfile
    ) async throws
}

extension SparkModelLaunching {
    public func apply(
        _ plan: SparkModelLaunchPlan,
        progress: @escaping @MainActor (SparkModelLaunchProgress) -> Void
    ) async throws -> SparkChatTarget {
        try await apply(plan)
    }

    public func preferredProfile(for target: SparkChatTarget, profiles: [SparkModelProfile])
        -> String?
    {
        SparkModelDefaults.defaultProfile(profiles: profiles)
    }
    public func staleSavedProfile(for target: SparkChatTarget, profiles: [SparkModelProfile])
        -> String?
    {
        nil
    }
    public func discard(_ plan: SparkModelLaunchPlan) {}
    public func saveIdleSetting(
        _ setting: SparkModelIdleSetting,
        for target: SparkChatTarget,
        profile: SparkModelProfile
    ) async throws {
        throw SparkModelLaunchError(
            message: String(localized: "This Spark cannot save unload settings.")
        )
    }
}

struct SparkModelLaunchError: LocalizedError {
    var title: String? = nil
    let message: String
    var errorDescription: String? { message }
}

/// Uses the same signed previews, admission checks and durable operation recovery as Library.
@MainActor
public final class SignedSparkModelLauncher: SparkModelLaunching {
    private let library: SparkLibrary
    private let defaults: UserDefaults
    private let runtimeResolver: ModelLibraryRuntimeResolver
    private let operationStore: any ModelOperationRecoveryStoring
    private var prepared: [UUID: SparkDashboardModel] = [:]

    public init(
        library: SparkLibrary,
        defaults: UserDefaults = .standard,
        runtimeResolver: ModelLibraryRuntimeResolver? = nil,
        operationStore: any ModelOperationRecoveryStoring =
            UserDefaultsModelOperationRecoveryStore()
    ) {
        self.library = library
        self.defaults = defaults
        self.runtimeResolver =
            runtimeResolver ?? SignedCrossTargetModelLibraryProvider.productionRuntime
        self.operationStore = operationStore
    }

    private func dashboard(for target: SparkChatTarget) async throws -> SparkDashboardModel {
        guard let entry = library.entry(id: target.id), entry.coordinatorNodeID == target.nodeID,
            entry.clusterID == target.clusterID
        else { throw SparkChatConnectionError.identityMismatch }
        let connection = try runtimeResolver(entry)
        guard connection.expectedNodeID == target.nodeID,
            connection.expectedAuthorityFingerprint == target.authorityFingerprint
        else { throw SparkChatConnectionError.identityMismatch }
        let dashboard = SparkDashboardModel(
            route: connection.route,
            runtime: connection.runtime,
            targetID: entry.id,
            tlsFingerprint: target.tlsFingerprint,
            expectedIdentity: SparkDashboardIdentityExpectation(
                coordinatorNodeID: target.nodeID,
                authorityFingerprint: target.authorityFingerprint,
                clusterID: target.clusterID
            ),
            targetIdentity: entry.logicalKey,
            operationStore: operationStore,
            cacheEvidence: { [weak library] evidence, date in
                guard let library, library.entry(id: entry.id)?.logicalKey == entry.logicalKey
                else { return nil }
                library.recordOperationalEvidence(evidence, for: entry.id, at: date)
                return library.operationalSnapshot(for: entry.id, at: date)
            }
        )
        await dashboard.refresh()
        try Task.checkCancellation()
        guard dashboard.identityIssue == nil, dashboard.errorMessage == nil,
            dashboard.inference != nil
        else {
            throw SparkModelLaunchError(
                message: dashboard.errorMessage
                    ?? String(localized: "The Spark could not verify its current model status.")
            )
        }
        return dashboard
    }

    public func profiles(for target: SparkChatTarget) async throws -> [SparkModelProfile] {
        let dashboard = try await dashboard(for: target)
        guard
            let model = dashboard.models.first(where: {
                $0.id == target.modelID && $0.installState == .installed
            })
        else {
            throw SparkModelLaunchError(
                message: String(
                    localized: "This model is no longer installed on the selected Spark."
                )
            )
        }
        return model.profiles
    }

    public func saveIdleSetting(
        _ setting: SparkModelIdleSetting,
        for target: SparkChatTarget,
        profile: SparkModelProfile
    ) async throws {
        let verified = try await dashboard(for: target)
        guard
            let current = verified.models.first(where: { $0.id == target.modelID })?.profiles.first(
                where: { $0.id == profile.id }),
            let entry = library.entry(id: target.id)
        else { throw SparkChatConnectionError.identityMismatch }
        let connection = try runtimeResolver(entry)
        guard connection.expectedNodeID == target.nodeID,
            connection.expectedAuthorityFingerprint == target.authorityFingerprint,
            let runtime = connection.runtime as? any SparkSettingsManaging
        else { throw SparkChatConnectionError.identityMismatch }
        let request = try setting.request(modelID: target.modelID, profile: current)
        let operations = SparkSettingsOperationCoordinator(
            route: connection.route,
            runtime: runtime,
            authorizer: SystemUserPresenceAuthorizer()
        )
        let key = UUID()
        await operations.perform(
            label: String(localized: "Saving unload setting"),
            reason: String(localized: "Confirm changing when this model unloads from memory.")
        ) { presence in
            try await runtime.updateModelIdlePolicy(
                route: connection.route,
                request: request,
                idempotencyKey: key,
                userPresence: presence
            )
        }
        if let message = operations.errorMessage { throw SparkModelLaunchError(message: message) }
        guard operations.lastOperation?.state == .succeeded else {
            throw SparkModelLaunchError(
                message: String(localized: "The Spark did not apply this setting.")
            )
        }
    }

    private func preferenceKey(_ target: SparkChatTarget) -> String {
        "spark.model-launch.profile." + target.id + "/" + target.modelID
    }

    public func preferredProfile(for target: SparkChatTarget, profiles: [SparkModelProfile])
        -> String?
    {
        SparkModelDefaults.preferred(
            targetID: target.id,
            modelID: target.modelID,
            profiles: profiles,
            defaults: defaults
        )
    }

    public func staleSavedProfile(for target: SparkChatTarget, profiles: [SparkModelProfile])
        -> String?
    {
        SparkModelDefaults.staleSavedProfile(
            targetID: target.id,
            modelID: target.modelID,
            profiles: profiles,
            defaults: defaults
        )
    }

    public func prepare(target: SparkChatTarget, profileID: String? = nil) async throws
        -> SparkModelLaunchPlan
    {
        let dashboard = try await dashboard(for: target)
        guard let inference = dashboard.inference else {
            throw SparkChatConnectionError.activeModelChanged
        }
        let installed = dashboard.models.first(where: {
            $0.id == target.modelID && $0.installState == .installed
        })
        if inference.modelID == target.modelID,
            [.ready, .idle, .loading].contains(inference.state),
            profileID == nil || profileID == inference.profileID
        {
            if let activeProfile = inference.profileID,
                installed?.profiles.contains(where: { $0.id == activeProfile && $0.safe }) == true
            {
                defaults.set(activeProfile, forKey: preferenceKey(target))
            }
            let plan = SparkModelLaunchPlan(
                target: target,
                alreadyReady: inference.state != .loading
            )
            prepared[plan.id] = dashboard
            return plan
        }
        guard let model = installed else {
            throw SparkModelLaunchError(
                message: String(
                    localized: "This model is no longer installed on the selected Spark."
                )
            )
        }
        guard [.unloaded, .ready, .idle, .failed].contains(inference.state) else {
            throw SparkModelLaunchError(
                message: String(
                    localized:
                        "Another model operation is in progress; wait for it to finish and try again."
                )
            )
        }
        guard let profile = profileID ?? preferredProfile(for: target, profiles: model.profiles),
            model.profiles.contains(where: { $0.id == profile && $0.safe })
        else {
            throw SparkModelLaunchError(
                message: String(
                    localized: "This model has no profile that is safe for the available memory."
                )
            )
        }
        let alternatives = model.profiles.filter { $0.safe && $0.id != profile }.sorted {
            $0.maxModelLength == $1.maxModelLength
                ? $0.maxSequences > $1.maxSequences : $0.maxModelLength > $1.maxModelLength
        }.map(\.id)
        let candidates = [profile] + (profileID == nil ? alternatives : [])
        for candidate in candidates {
            try Task.checkCancellation()
            await dashboard.prepareLoad(
                modelID: target.modelID,
                replaceActive: inference.modelID != nil,
                profileID: candidate
            )
            guard let preview = dashboard.pendingConfirmation?.preview,
                !preview.blockers.isEmpty,
                preview.blockers.allSatisfy({ $0.code == "MODEL_INSUFFICIENT_MEMORY" }),
                candidate != candidates.last
            else { break }
            dashboard.cancelConfirmation()
        }
        guard let confirmation = dashboard.pendingConfirmation else {
            throw SparkModelLaunchError(
                title: dashboard.lifecycle[target.modelID]?.errorTitle,
                message: dashboard.lifecycle[target.modelID]?.errorMessage
                    ?? String(
                        localized: "The launch could not be prepared; check the model in Library."
                    )
            )
        }
        let plan = SparkModelLaunchPlan(target: target, confirmation: confirmation)
        prepared[plan.id] = dashboard
        return plan
    }

    public func discard(_ plan: SparkModelLaunchPlan) {
        prepared.removeValue(forKey: plan.id)?.cancelConfirmation()
    }

    public func apply(_ plan: SparkModelLaunchPlan) async throws -> SparkChatTarget {
        try await apply(plan, progress: { _ in })
    }

    public func apply(
        _ plan: SparkModelLaunchPlan,
        progress: @escaping @MainActor (SparkModelLaunchProgress) -> Void
    ) async throws -> SparkChatTarget {
        guard let dashboard = prepared.removeValue(forKey: plan.id) else {
            throw CancellationError()
        }
        defer { dashboard.stopMonitoring() }
        let report: @MainActor (SparkAPI.Operation) -> Void = { operation in
            progress(
                SparkModelLaunchProgress(
                    stage: SparkDashboardOwnerPresentation.operationStageLabel(
                        operation.stage,
                        action: .load
                    ),
                    fraction: SparkDashboardOwnerPresentation.determinateProgress(operation),
                    detail: SparkDashboardOwnerPresentation.operationStageDetail(operation.stage)
                )
            )
        }
        if let confirmation = plan.confirmation {
            guard confirmation.canApply, dashboard.pendingConfirmation?.id == confirmation.id else {
                throw SparkModelLaunchError(
                    message: String(localized: "Review this model launch again before continuing.")
                )
            }
            await dashboard.applyConfirmation(progress: report)
            try Task.checkCancellation()
            if let lifecycle = dashboard.lifecycle[plan.target.modelID],
                let error = lifecycle.errorMessage, lifecycle.recoveryAction != .retryStatus
            {
                throw SparkModelLaunchError(title: lifecycle.errorTitle, message: error)
            }
            if let profile = confirmation.profile?.id {
                defaults.set(profile, forKey: preferenceKey(plan.target))
            }
        }
        let deadline = Date().addingTimeInterval(15 * 60)
        while true {
            try Task.checkCancellation()
            if dashboard.lifecycle[plan.target.modelID]?.recoveryAction == .retryStatus {
                // Reattach to the durable operation; never submit the load a second time.
                await dashboard.retryStatus(modelID: plan.target.modelID, progress: report)
            }
            let lifecycle = dashboard.lifecycle[plan.target.modelID]
            if let error = lifecycle?.errorMessage, lifecycle?.recoveryAction != .retryStatus {
                throw SparkModelLaunchError(title: lifecycle?.errorTitle, message: error)
            }
            if let operation = lifecycle?.operation { report(operation) }
            guard dashboard.identityIssue == nil else {
                throw SparkChatConnectionError.identityMismatch
            }
            let launchFinished =
                lifecycle?.operation == nil
                || lifecycle?.operation?.state == .succeeded
            if launchFinished, let inference = dashboard.inference,
                inference.modelID == plan.target.modelID,
                [.ready, .idle].contains(inference.state)
            {
                return SparkChatTarget(
                    id: plan.target.id,
                    displayName: plan.target.displayName,
                    nodeID: plan.target.nodeID,
                    clusterID: plan.target.clusterID,
                    route: dashboard.route,
                    tlsFingerprint: plan.target.tlsFingerprint,
                    authorityFingerprint: plan.target.authorityFingerprint,
                    modelID: plan.target.modelID,
                    modelName: plan.target.modelName,
                    contextLength: inference.contextLength,
                    visionSupported: dashboard.models.first(where: { $0.id == plan.target.modelID }
                    )?.capabilities["vision"]
                )
            }
            // Keep waiting when inference lags an accepted load or a status read is interrupted.
            let hasAcceptedLoad =
                lifecycle?.operation.map {
                    !$0.state.isTerminal || $0.state == .succeeded
                } ?? false
            let isLoading =
                dashboard.inference?.modelID == plan.target.modelID
                && dashboard.inference?.state == .loading
            guard hasAcceptedLoad || isLoading, Date() < deadline else {
                throw SparkModelLaunchError(
                    message: String(
                        localized:
                            "The selected model did not become ready; your message has been kept."
                    )
                )
            }
            try await Task.sleep(for: .seconds(2))
            await dashboard.refresh()
        }
    }
}

extension Notification.Name {
    static let sparkModelReadyChatRequested = Notification.Name("spark.modelReady.chatRequested")
}
