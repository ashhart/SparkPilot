import Foundation
#if os(iOS)
    import UIKit
#elseif os(macOS)
    import IOKit.ps
#endif
import Observation
import SparkAPI
import SparkBootstrap
import SparkCore
import SparkDesignSystem
import SparkLibrary
import SparkSecurity
import SwiftUI
import UniformTypeIdentifiers
@MainActor
@Observable
final class SparkDashboardCatalogueReview {
    var catalogueStatus: GeneratedAPI.CatalogueStatus?
    var catalogueErrorMessage: String?
    var pendingCatalogueRefresh: CatalogueRefreshConfirmation?
    var isPreparingCatalogueRefresh = false
    var isRefreshingCatalogue = false
    var catalogueRefreshOperation: SparkAPI.Operation?
    var pendingProfileReenable: ProfileReenableConfirmation?
    var isPreparingProfileReenable = false
    var isReenablingProfile = false
    var profileReenableOperation: SparkAPI.Operation?
    var profileReenableErrorMessage: String?
    /// What sparkpilot.dev publishes, once checked this session.
    var publishedCatalogue: PublishedCatalogueCheck?
    var isCheckingPublishedCatalogue = false
    var publishedCatalogueError: String?
    private let catalogueSource: any PublishedCatalogueSource
    private let route: URL
    private let runtime: any SparkRuntimeReading
    private let targetID: String
    private let snapshot: SparkDashboardSnapshot
    private let authority: SparkDashboardPresenceAuthority
    private let tlsFingerprint: String?
    private let operationDelay: @Sendable (Duration) async throws -> Void
    var refresh: () async -> Void = {}
    init(
        route: URL,
        targetID: String,
        runtime: any SparkRuntimeReading,
        snapshot: SparkDashboardSnapshot,
        authority: SparkDashboardPresenceAuthority,
        tlsFingerprint: String?,
        catalogueSource: any PublishedCatalogueSource = UnconfiguredCatalogueSource(),
        operationDelay: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.catalogueSource = catalogueSource
        self.route = route
        self.targetID = targetID
        self.runtime = runtime
        self.snapshot = snapshot
        self.authority = authority
        self.tlsFingerprint = tlsFingerprint
        self.operationDelay = operationDelay
    }
    private var capabilities: SparkCapabilities? { snapshot.capabilities }
    private var capabilitiesChecked: Bool { snapshot.capabilitiesChecked }
    private var identityIssue: SparkDashboardIdentityIssue? { snapshot.identityIssue }
    private var models: [SparkModel] { snapshot.models }

    var catalogueRefreshSupported: Bool {
        capabilities?.isEnabled("signed_catalogue_refresh") == true
    }

    var profileReenableSupported: Bool {
        capabilities?.isEnabled("model_profile_reenable") == true
    }

    var remoteCatalogueStatus: String { remoteCatalogueStatusValue.text }

    var remoteCatalogueStatusValue: SparkStatusValue {
        guard capabilitiesChecked else { return SparkStatusValue(String(localized: "Checking")) }
        guard catalogueRefreshSupported else {
            return SparkStatusValue(String(localized: "Unavailable"))
        }
        guard let catalogueStatus else {
            return catalogueErrorMessage == nil
                ? SparkStatusValue(String(localized: "Checking"))
                : SparkStatusValue(String(localized: "Check failed"), tone: .attention)
        }
        return catalogueStatus.refreshAvailable
            ? SparkStatusValue(String(localized: "Ready"))
            : SparkStatusValue(String(localized: "Unavailable"))
    }

    var remoteCatalogueDetail: String {
        guard capabilitiesChecked else {
            return String(localized: "Checking signed refresh support")
        }
        guard catalogueRefreshSupported else {
            return String(
                localized: "This runtime does not publish a signed catalogue refresh service"
            )
        }
        guard let catalogueStatus else {
            return catalogueErrorMessage
                ?? String(localized: "Checking the verified catalogue snapshot")
        }
        return String(localized: .verifiedRecipesInSnapshot(catalogueStatus.recipeCount))
    }

    var catalogueRefreshStageLabel: String {
        switch catalogueRefreshOperation?.stage {
        case "validating_signature": String(localized: "Verifying the catalogue signature")
        case "checking_installed_models": String(localized: "Protecting installed models")
        case "staging_snapshot": String(localized: "Staging the verified snapshot")
        case "promoting_snapshot": String(localized: "Switching to the verified snapshot")
        case "materialising_catalogue": String(localized: "Updating the model catalogue")
        case "catalogue_ready": String(localized: "Catalogue ready")
        default: String(localized: "Refreshing the signed catalogue")
        }
    }

    /// Whether sparkpilot.dev publishes something other than the Spark's verified snapshot.
    var publishedCatalogueIsNewer: Bool {
        guard let publishedCatalogue, let catalogueStatus else { return false }
        return publishedCatalogue.differs(from: catalogueStatus.currentDigest)
    }

    var publishedCatalogueStatusLine: String {
        if isCheckingPublishedCatalogue { return String(localized: "Checking sparkpilot.dev") }
        if let publishedCatalogueError { return publishedCatalogueError }
        guard let publishedCatalogue else {
            return String(localized: "Not checked yet")
        }
        if publishedCatalogueIsNewer {
            return String(localized: .publishedRecipesAvailable(publishedCatalogue.recipeCount))
        }
        return String(localized: .publishedRecipesCurrent(publishedCatalogue.recipeCount))
    }

    /// Fetch the published catalogue and compare it with the Spark's snapshot; nothing is sent to the Spark here.
    func checkPublishedCatalogue() async {
        guard !isCheckingPublishedCatalogue else { return }
        isCheckingPublishedCatalogue = true
        defer { isCheckingPublishedCatalogue = false }
        do {
            let bytes = try await catalogueSource.catalogue()
            publishedCatalogue = try PublishedCatalogueCheck(bytes: bytes)
            publishedCatalogueError = nil
        } catch PublishedCatalogueError.notConfigured {
            publishedCatalogueError = String(localized: "This build names no published catalogue.")
        } catch PublishedCatalogueError.tooLarge {
            publishedCatalogueError = String(
                localized: "The published catalogue is larger than a Spark accepts."
            )
        } catch PublishedCatalogueCheckError.notACatalogue {
            publishedCatalogueError = String(
                localized: "sparkpilot.dev did not return a signed catalogue."
            )
        } catch {
            publishedCatalogueError = String(
                localized: "sparkpilot.dev could not be reached. Check the internet connection."
            )
        }
    }

    /// Send what sparkpilot.dev publishes through the same reviewed, presence-authorized update; the Spark verifies the signature.
    func preparePublishedCatalogueRefresh() async {
        if publishedCatalogue == nil { await checkPublishedCatalogue() }
        guard let publishedCatalogue,
            let candidate = String(data: publishedCatalogue.bytes, encoding: .utf8)
        else { return }
        await prepareCatalogueRefresh(
            candidateJSON: candidate,
            fileName: String(localized: "Recipes published on sparkpilot.dev")
        )
    }

    /// Send the app's signed presets through the same reviewed, presence-authorized update as an imported catalogue.
    func prepareBundledPresetUpdate() async {
        do {
            guard let url = Bundle.module.url(forResource: "model-presets", withExtension: "json")
            else {
                throw CocoaError(.fileNoSuchFile)
            }
            let candidate = try String(contentsOf: url, encoding: .utf8)
            await prepareCatalogueRefresh(
                candidateJSON: candidate,
                fileName: String(localized: "SparkPilot model presets")
            )
        } catch {
            catalogueErrorMessage = String(
                localized: "The bundled model presets could not be opened."
            )
        }
    }

    func prepareCatalogueRefresh(candidateJSON: String, fileName: String) async {
        guard identityIssue == nil else {
            catalogueErrorMessage = String(
                localized: "Verify this Spark's identity before changing its catalogue."
            )
            return
        }
        guard catalogueRefreshSupported, catalogueStatus?.refreshAvailable == true else {
            catalogueErrorMessage = String(
                localized: "This runtime cannot refresh its signed catalogue."
            )
            return
        }
        guard !isPreparingCatalogueRefresh else { return }
        guard candidateJSON.utf8.count <= 2 * 1024 * 1024,
            candidateJSON.utf8.count >= 2
        else {
            catalogueErrorMessage = String(
                localized: "Choose a signed catalogue JSON file no larger than 2 MB."
            )
            return
        }
        isPreparingCatalogueRefresh = true
        catalogueErrorMessage = nil
        defer { isPreparingCatalogueRefresh = false }
        let key = UUID()
        do {
            let preview = try await runtime.previewCatalogueRefresh(
                route: route,
                request: .init(candidateJson: candidateJSON),
                idempotencyKey: key
            )
            guard preview.action == .catalogueRefresh else {
                throw ModelPreviewError.actionMismatch
            }
            pendingCatalogueRefresh = CatalogueRefreshConfirmation(
                idempotencyKey: key,
                fileName: fileName,
                candidateJSON: candidateJSON,
                preview: preview
            )
        } catch let api as APIError {
            catalogueErrorMessage = APIError.message(for: api)
        } catch {
            catalogueErrorMessage =
                String(localized: "This file could not be verified as a signed Spark catalogue.")
        }
    }

    func cancelCatalogueRefresh() {
        guard !isRefreshingCatalogue else { return }
        pendingCatalogueRefresh = nil
    }

    func applyCatalogueRefresh() async {
        guard identityIssue == nil, let confirmation = pendingCatalogueRefresh,
            confirmation.canApply,
            !isRefreshingCatalogue
        else { return }
        isRefreshingCatalogue = true
        catalogueErrorMessage = nil
        catalogueRefreshOperation = nil
        defer {
            isRefreshingCatalogue = false
            catalogueRefreshOperation = nil
        }
        do {
            var operation = try await authority.submitPresenceAuthorized(
                reason: String(localized: "Confirm replacing this Spark's signed model catalogue.")
            ) { presence in
                try await self.runtime.refreshCatalogue(
                    route: self.route,
                    request: .init(
                        candidateJson: confirmation.candidateJSON,
                        acceptedPreviewDigest: confirmation.preview.previewDigest
                    ),
                    idempotencyKey: confirmation.idempotencyKey,
                    userPresence: presence
                )
            }
            catalogueRefreshOperation = operation
            // Bound polling so an unsettled operation cannot leave Apply disabled indefinitely.
            var pollsRemaining = 300
            while !operation.state.isTerminal {
                guard pollsRemaining > 0 else {
                    throw APIError(
                        .local(
                            message: String(
                                localized:
                                    "The Spark is still working on this. Refresh in a moment."
                            )
                        ),
                        code: "OPERATION_STILL_RUNNING"
                    )
                }
                pollsRemaining -= 1
                try await operationDelay(.seconds(1))
                operation = try await runtime.operation(route: route, id: operation.id)
                catalogueRefreshOperation = operation
            }
            guard operation.state == .succeeded else {
                throw APIError(
                    .local(
                        message: String(
                            localized:
                                "The refresh did not complete. The previous verified catalogue remains in use."
                        )
                    ),
                    code: operation.errorCode
                )
            }
            pendingCatalogueRefresh = nil
            await refresh()
        } catch is UserPresenceAuthorizationError {
            catalogueErrorMessage =
                String(
                    localized:
                        "Nothing changed because this Apple device could not confirm you are present."
                )
        } catch let api as APIError {
            // Append the preserved-catalogue explanation only when the local failure does not already contain it.
            catalogueErrorMessage =
                if case .local(let message) = api.reason {
                    message
                } else {
                    String(
                        localized: .catalogueRefreshFailedDetail(APIError.message(for: api))
                    )
                }
        } catch {
            catalogueErrorMessage =
                String(
                    localized:
                        "SparkPilot could not confirm whether the refresh started. Try Apply again to check the same request without creating a duplicate."
                )
        }
    }

    func prepareProfileReenable(modelID: String, profileID: String) async {
        guard identityIssue == nil, profileReenableSupported, !isPreparingProfileReenable,
            !isReenablingProfile,
            let selectedModel = models.first(where: { $0.id == modelID }),
            let profile = selectedModel.profiles.first(where: { $0.id == profileID }),
            !profile.safe
        else { return }
        isPreparingProfileReenable = true
        profileReenableErrorMessage = nil
        defer { isPreparingProfileReenable = false }
        let key = UUID()
        do {
            let preview = try await runtime.previewReenableModelProfile(
                route: route,
                modelID: modelID,
                profileID: profileID,
                idempotencyKey: key
            )
            guard preview.action == .profileReenable else {
                throw ModelPreviewError.actionMismatch
            }
            pendingProfileReenable = ProfileReenableConfirmation(
                idempotencyKey: key,
                modelID: modelID,
                modelName: selectedModel.displayName,
                profileID: profileID,
                profileName: profile.displayName,
                preview: preview
            )
        } catch {
            profileReenableErrorMessage =
                SparkDashboardFailurePresentation.profileReenableFailureMessage(error)
        }
    }

    func cancelProfileReenable() {
        guard !isReenablingProfile else { return }
        pendingProfileReenable = nil
        profileReenableErrorMessage = nil
    }

    func applyProfileReenable() async {
        guard identityIssue == nil, profileReenableSupported,
            let confirmation = pendingProfileReenable,
            confirmation.canApply,
            !isReenablingProfile
        else { return }
        isReenablingProfile = true
        profileReenableErrorMessage = nil
        profileReenableOperation = nil
        defer {
            isReenablingProfile = false
            profileReenableOperation = nil
        }
        do {
            var operation = try await authority.submitPresenceAuthorized(
                reason:
                    String(
                        localized: .confirmReEnabling(
                            profile: confirmation.profileName,
                            model: confirmation.modelName
                        )
                    )
            ) { presence in
                try await self.runtime.reenableModelProfile(
                    route: self.route,
                    modelID: confirmation.modelID,
                    profileID: confirmation.profileID,
                    request: .init(
                        acceptedPreviewDigest: confirmation.preview.previewDigest
                    ),
                    idempotencyKey: confirmation.idempotencyKey,
                    userPresence: presence
                )
            }
            profileReenableOperation = operation
            // Bound polling so an unsettled operation cannot leave Apply disabled indefinitely.
            var pollsRemaining = 300
            while !operation.state.isTerminal {
                guard pollsRemaining > 0 else {
                    throw APIError(
                        .local(
                            message: String(
                                localized:
                                    "The Spark is still working on this. Refresh in a moment."
                            )
                        ),
                        code: "OPERATION_STILL_RUNNING"
                    )
                }
                pollsRemaining -= 1
                try await operationDelay(.seconds(1))
                operation = try await runtime.operation(route: route, id: operation.id)
                profileReenableOperation = operation
            }
            guard operation.state == .succeeded else {
                pendingProfileReenable = nil
                throw APIError(
                    .local(
                        message: String(
                            localized:
                                "The profile remains disabled because the safety change failed. Review it again to retry."
                        )
                    ),
                    code: operation.errorCode
                )
            }
            pendingProfileReenable = nil
            await refresh()
        } catch is UserPresenceAuthorizationError {
            profileReenableErrorMessage =
                String(
                    localized:
                        "Nothing changed because this Apple device could not confirm you are present."
                )
        } catch let api as APIError {
            if SparkDashboardFailurePresentation.isPreviewInvalidation(api) {
                pendingProfileReenable = nil
                profileReenableErrorMessage =
                    String(
                        localized:
                            "The Spark changed since this safety review. Review the profile again."
                    )
            } else {
                profileReenableErrorMessage =
                    SparkDashboardFailurePresentation.profileReenableFailureMessage(api)
            }
        } catch {
            profileReenableErrorMessage =
                String(
                    localized:
                        "SparkPilot could not confirm whether the safety change started. Retry this review to check the same request; no model starts automatically."
                )
        }
    }

}
