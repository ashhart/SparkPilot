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
@MainActor
@Observable
final class SparkModelPreviewController {
    var pendingConfirmation: ModelActionConfirmation?
    var pendingLoadConfiguration: ModelLoadConfiguration?
    var previewGeneration = UUID()
    var isPreparingConfirmation = false
    private let route: URL
    private let runtime: any SparkRuntimeReading
    private let targetID: String
    private let snapshot: SparkDashboardSnapshot
    private let operations: SparkModelLifecycleCoordinator
    private let operationStore: any ModelOperationRecoveryStoring
    var refresh: () async -> Void = {}
    init(
        route: URL,
        targetID: String,
        runtime: any SparkRuntimeReading,
        snapshot: SparkDashboardSnapshot,
        operations: SparkModelLifecycleCoordinator,
        operationStore: any ModelOperationRecoveryStoring
    ) {
        self.route = route
        self.targetID = targetID
        self.runtime = runtime
        self.snapshot = snapshot
        self.operations = operations
        self.operationStore = operationStore
    }
    private var models: [SparkModel] { snapshot.models }
    private var inference: ActiveInference? { snapshot.inference }
    private var identityIssue: SparkDashboardIdentityIssue? { snapshot.identityIssue }
    private var capabilities: SparkCapabilities? {
        get { snapshot.capabilities }
        set { snapshot.capabilities = newValue }
    }
    private var capabilitiesChecked: Bool {
        get { snapshot.capabilitiesChecked }
        set { snapshot.capabilitiesChecked = newValue }
    }
    private var lifecycle: [String: ModelLifecycleState] {
        get { operations.lifecycle }
        set { operations.lifecycle = newValue }
    }
    private var lastLoadRequests: [String: ModelOperationRetryRequest] {
        get { operations.lastLoadRequests }
        set { operations.lastLoadRequests = newValue }
    }
    private var containerRuntimeAvailable: Bool { snapshot.containerRuntimeAvailable }
    private var signedCatalogueAvailable: Bool { snapshot.signedCatalogueAvailable }

    func prepareInstall(modelID: String, providerCredentialID: String? = nil) async {
        guard await canManageModels(action: .install, modelID: modelID) else { return }
        let revision = models.first(where: { $0.id == modelID })?.recipeRevision
        let key = UUID()
        await requestPreview(
            modelID: modelID,
            action: .install,
            expectedPreviewAction: .install,
            idempotencyKey: key,
            retryRequest: ModelOperationRetryRequest(
                recipeRevision: revision,
                providerCredentialID: providerCredentialID
            )
        ) {
            try await self.runtime.previewInstallModel(
                route: self.route,
                modelID: modelID,
                request: GeneratedAPI.InstallModelPreviewRequest(
                    recipeRevision: revision,
                    providerCredentialId: providerCredentialID
                ),
                idempotencyKey: key
            )
        }
    }

    func prepareLoad(
        modelID: String,
        replaceActive: Bool,
        profileID: String? = nil
    ) async {
        guard await canManageModels(action: .load, modelID: modelID),
            !isPreparingConfirmation, lifecycle[modelID]?.isRunning != true
        else { return }
        guard let model = models.first(where: { $0.id == modelID }) else { return }
        if inference?.modelID.map({ $0 != modelID }) == true, !replaceActive {
            lifecycle[modelID] = ModelLifecycleState(
                action: .load,
                operation: nil,
                errorMessage: String(
                    localized: "Choose Replace to stop the running model before starting this one."
                )
            )
            return
        }
        let safeProfiles = model.profiles.filter(\.safe)
        if profileID == nil, safeProfiles.count != 1, !model.profiles.isEmpty {
            cancelConfirmation()
            pendingLoadConfiguration = ModelLoadConfiguration(
                id: UUID(),
                modelID: modelID,
                modelName: model.displayName,
                replaceActive: replaceActive,
                profiles: model.profiles,
                staleSavedProfileID: SparkModelDefaults.staleSavedProfile(
                    targetID: targetID,
                    modelID: modelID,
                    profiles: model.profiles
                )
            )
            lifecycle[modelID] = nil
            return
        }
        guard
            let profile = profileID.flatMap({ id in model.profiles.first { $0.id == id } })
                ?? (profileID == nil ? safeProfiles.first : nil), profile.safe
        else {
            lifecycle[modelID] = ModelLifecycleState(
                action: .load,
                operation: nil,
                errorMessage: String(
                    localized: "This model has no profile that is safe for the available memory."
                )
            )
            return
        }
        let key = UUID()
        let retryRequest = ModelOperationRetryRequest(
            profileID: profile.id,
            replaceActive: replaceActive
        )
        await requestPreview(
            modelID: modelID,
            action: .load,
            expectedPreviewAction: replaceActive ? .replace : .load,
            idempotencyKey: key,
            retryRequest: retryRequest,
            profile: profile
        ) {
            try await self.runtime.previewLoadModel(
                route: self.route,
                request: GeneratedAPI.LoadModelPreviewRequest(
                    modelId: modelID,
                    profileId: profile.id,
                    replaceActive: replaceActive
                ),
                idempotencyKey: key
            )
        }
    }

    func previewLoadConfiguration(profileID: String) async {
        guard let configuration = pendingLoadConfiguration,
            configuration.profiles.contains(where: { $0.id == profileID && $0.safe })
        else { return }
        await prepareLoad(
            modelID: configuration.modelID,
            replaceActive: configuration.replaceActive,
            profileID: profileID
        )
    }

    func canChooseLoadProfile(modelID: String) -> Bool {
        (models.first(where: { $0.id == modelID })?.profiles.filter(\.safe).count ?? 0) > 1
    }

    var canChangeLoadProfile: Bool {
        guard let confirmation = pendingConfirmation, confirmation.lifecycleAction == .load,
            confirmation.retryRequest.targetNodeID == nil,
            confirmation.retryRequest.targetClusterID == nil
        else { return false }
        return canChooseLoadProfile(modelID: confirmation.modelID)
    }

    func changeLoadProfile() async {
        // Keep cluster recovery's exact verified target binding while allowing profile selection in the cluster flow.
        guard canChangeLoadProfile, let confirmation = pendingConfirmation else {
            return
        }
        cancelConfirmation()
        await prepareLoad(
            modelID: confirmation.modelID,
            replaceActive: confirmation.retryRequest.replaceActive ?? false
        )
    }

    /// Revalidates the exact signed recipe revision and profile before creating a cluster-recovery load preview.
    @discardableResult
    func prepareVerifiedLoad(
        modelID: String,
        profileID: String,
        expectedRecipeRevision: String,
        targetNodeID: String,
        targetClusterID: String?
    ) async -> Bool {
        await refresh()
        operations.requestModelFocus(modelID)
        guard identityIssue == nil,
            await canManageModels(action: .load, modelID: modelID),
            let model = models.first(where: { $0.id == modelID }),
            model.installState == .installed,
            model.recipeRevision == expectedRecipeRevision,
            let profile = model.profiles.first(where: { $0.id == profileID }),
            profile.safe
        else { return false }

        let replaceActive = inference?.modelID != nil
        let key = UUID()
        let target = GeneratedAPI.LoadModelPreviewRequestTarget(
            nodeId: targetNodeID,
            clusterId: targetClusterID
        )
        let retryRequest = ModelOperationRetryRequest(
            recipeRevision: expectedRecipeRevision,
            profileID: profile.id,
            replaceActive: replaceActive,
            targetNodeID: targetNodeID,
            targetClusterID: targetClusterID
        )
        await requestPreview(
            modelID: modelID,
            action: .load,
            expectedPreviewAction: replaceActive ? .replace : .load,
            idempotencyKey: key,
            retryRequest: retryRequest,
            profile: profile
        ) {
            try await self.runtime.previewLoadModel(
                route: self.route,
                request: GeneratedAPI.LoadModelPreviewRequest(
                    modelId: modelID,
                    profileId: profile.id,
                    replaceActive: replaceActive,
                    target: target
                ),
                idempotencyKey: key
            )
        }
        return pendingConfirmation?.idempotencyKey == key
    }

    func prepareStopActiveModel() async {
        guard let modelID = inference?.modelID else { return }
        guard await canManageModels(action: .unload, modelID: modelID) else { return }
        let key = UUID()
        let retryRequest = ModelOperationRetryRequest(force: false)
        await requestPreview(
            modelID: modelID,
            action: .unload,
            expectedPreviewAction: .stop,
            idempotencyKey: key,
            retryRequest: retryRequest
        ) {
            try await self.runtime.previewUnloadModel(
                route: self.route,
                request: GeneratedAPI.StopModelPreviewRequest(force: false),
                idempotencyKey: key
            )
        }
    }

    func prepareRemove(modelID: String) async {
        guard await canManageModels(action: .remove, modelID: modelID) else { return }
        let key = UUID()
        await requestPreview(
            modelID: modelID,
            action: .remove,
            expectedPreviewAction: .remove,
            idempotencyKey: key,
            retryRequest: ModelOperationRetryRequest()
        ) {
            try await self.runtime.previewRemoveModel(
                route: self.route,
                modelID: modelID,
                idempotencyKey: key
            )
        }
    }

    func cancelConfirmation() {
        previewGeneration = UUID()
        pendingConfirmation = nil
        pendingLoadConfiguration = nil
        isPreparingConfirmation = false
    }

    func applyConfirmation(
        userPresence: String? = nil,
        progress: @escaping @MainActor (SparkAPI.Operation) -> Void = { _ in }
    ) async {
        guard let confirmation = pendingConfirmation, confirmation.canApply else { return }
        pendingConfirmation = nil
        let request = confirmation.retryRequest
        if confirmation.lifecycleAction == .load, let profile = request.profileID {
            SparkModelDefaults.save(profile, targetID: targetID, modelID: confirmation.modelID)
        }
        await operations.perform(
            action: confirmation.lifecycleAction,
            modelID: confirmation.modelID,
            retryRequest: request,
            idempotencyKey: confirmation.idempotencyKey,
            progress: progress
        ) { key, savedRequest in
            try await SparkModelMutationSubmitter(route: self.route, runtime: self.runtime).submit(
                action: confirmation.lifecycleAction,
                modelID: confirmation.modelID,
                request: savedRequest,
                idempotencyKey: key,
                userPresence: userPresence
            )
        }
    }

    func refreshPreview(modelID: String, providerCredentialID: String? = nil) async {
        guard let state = lifecycle[modelID],
            state.recoveryAction == .refreshPreview
                || state.recoveryAction == .retryTerminalFailure
        else {
            return
        }
        lifecycle[modelID] = nil
        switch state.action {
        case .install:
            await prepareInstall(
                modelID: modelID,
                providerCredentialID: providerCredentialID
                    ?? operations.recoveryRecord(for: modelID)?.retryRequest?.providerCredentialID
            )
        case .load:
            let request =
                operations.recoveryRecord(for: modelID)?.retryRequest ?? lastLoadRequests[modelID]
            if let request, request.targetNodeID != nil || request.targetClusterID != nil {
                let prepared: Bool
                if let nodeID = request.targetNodeID, let profileID = request.profileID,
                    let revision = request.recipeRevision
                {
                    prepared = await prepareVerifiedLoad(
                        modelID: modelID,
                        profileID: profileID,
                        expectedRecipeRevision: revision,
                        targetNodeID: nodeID,
                        targetClusterID: request.targetClusterID
                    )
                } else {
                    prepared = false
                }
                if !prepared, lifecycle[modelID] == nil {
                    lifecycle[modelID] = ModelLifecycleState(
                        action: .load,
                        operation: nil,
                        errorMessage: String(
                            localized:
                                "This cluster start can no longer be verified. Return to the cluster and review its model and profile again."
                        )
                    )
                }
                return
            }
            let replacement = inference?.modelID.map { $0 != modelID } ?? false
            await prepareLoad(
                modelID: modelID,
                replaceActive: replacement,
                profileID: request?.profileID
            )
        case .unload:
            await prepareStopActiveModel()
        case .remove:
            await prepareRemove(modelID: modelID)
        }
    }

    private func requestPreview(
        modelID: String,
        action: ModelLifecycleAction,
        expectedPreviewAction: GeneratedAPI.ModelActionPreviewAction,
        idempotencyKey: UUID,
        retryRequest: ModelOperationRetryRequest,
        profileName: String? = nil,
        profile: SparkModelProfile? = nil,
        request: () async throws -> GeneratedAPI.ModelActionPreview
    ) async {
        guard !isPreparingConfirmation, lifecycle[modelID]?.isRunning != true else { return }
        let generation = previewGeneration
        do {
            if let existing = try operationStore.records(for: targetID).first(where: {
                $0.modelID == modelID
            }) {
                operations.restorePresentation(for: existing)
                return
            }
        } catch {
            guard generation == previewGeneration, !Task.isCancelled else { return }
            lifecycle[modelID] = ModelLifecycleState(
                action: action,
                operation: nil,
                errorMessage: String(
                    localized: "Saved operation recovery details could not be read on this device."
                )
            )
            return
        }
        isPreparingConfirmation = true
        if action == .load { lastLoadRequests[modelID] = retryRequest }
        defer { if generation == previewGeneration { isPreparingConfirmation = false } }
        do {
            let preview = try await request()
            guard generation == previewGeneration, !Task.isCancelled else { return }
            guard preview.action == expectedPreviewAction else {
                throw ModelPreviewError.actionMismatch
            }
            var acceptedRequest = retryRequest
            acceptedRequest.acceptedPreviewDigest = preview.previewDigest
            pendingConfirmation = ModelActionConfirmation(
                idempotencyKey: idempotencyKey,
                modelID: modelID,
                lifecycleAction: action,
                retryRequest: acceptedRequest,
                preview: preview,
                profileName: profileName,
                profile: profile
            )
            pendingLoadConfiguration = nil
            lifecycle[modelID] = nil
        } catch {
            guard generation == previewGeneration, !Task.isCancelled else { return }
            lifecycle[modelID] = ModelLifecycleState(
                action: action,
                operation: nil,
                errorMessage: SparkDashboardFailurePresentation.lifecycleMessage(for: error),
                recoveryAction: .refreshPreview
            )
        }
    }

    private func canManageModels(action: ModelLifecycleAction, modelID: String) async -> Bool {
        if !capabilitiesChecked {
            capabilities = try? await runtime.capabilities(route: route)
            capabilitiesChecked = true
        }
        guard capabilitiesChecked, containerRuntimeAvailable, signedCatalogueAvailable else {
            lifecycle[modelID] = ModelLifecycleState(
                action: action,
                operation: nil,
                errorMessage:
                    String(
                        localized:
                            "Install a Spark Runtime with container and signed catalogue support to manage models."
                    )
            )
            return false
        }
        return true
    }

    /// Revalidates a Library selection on its target before reusing signed preview and operation recovery.
    @discardableResult
    func prepareLibraryManagement(
        modelID: String,
        action: ModelLibraryManagementAction
    ) async -> Bool {
        await refresh()
        operations.requestModelFocus(modelID)
        guard identityIssue == nil else { return false }

        switch action {
        case .install:
            guard let item = models.first(where: { $0.id == modelID }),
                item.installState == .available || item.installState == .failed
            else { return false }
            await prepareInstall(modelID: modelID)
        case .load:
            guard let item = models.first(where: { $0.id == modelID }),
                item.installState == .installed,
                inference?.modelID != modelID
            else { return false }
            await prepareLoad(
                modelID: modelID,
                replaceActive: inference?.modelID != nil
            )
        case .unload:
            guard inference?.modelID == modelID else { return false }
            await prepareStopActiveModel()
        case .review:
            break
        }
        return true
    }

}
