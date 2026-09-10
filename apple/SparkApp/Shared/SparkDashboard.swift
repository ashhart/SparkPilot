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
public final class SparkDashboardModel {
    public var capabilities: SparkCapabilities? { snapshot.capabilities }
    public var capabilitiesChecked: Bool { snapshot.capabilitiesChecked }
    public var openWebUIService: GeneratedAPI.OptionalServiceStatus? { services.openWebUIService }
    public var openWebUIErrorMessage: String? { services.openWebUIErrorMessage }
    public var openWebUIAccessPath: String? { services.openWebUIAccessPath }
    public var isChangingOpenWebUI: Bool { services.isChangingOpenWebUI }
    public var openWebUIOperation: SparkAPI.Operation? { services.openWebUIOperation }
    public var openWebUIActionLabel: String? { services.openWebUIActionLabel }
    /// Missing workload inventory means unsupported or unavailable, never an empty inventory.
    public var workloadInventory: GeneratedAPI.WorkloadInventory? { snapshot.workloadInventory }
    public var workloadErrorMessage: String? { snapshot.workloadErrorMessage }
    public var catalogueStatus: GeneratedAPI.CatalogueStatus? { reviews.catalogueStatus }
    public var catalogueErrorMessage: String? { reviews.catalogueErrorMessage }
    public var pendingCatalogueRefresh: CatalogueRefreshConfirmation? {
        reviews.pendingCatalogueRefresh
    }
    public var isPreparingCatalogueRefresh: Bool { reviews.isPreparingCatalogueRefresh }
    public var isRefreshingCatalogue: Bool { reviews.isRefreshingCatalogue }
    public var catalogueRefreshOperation: SparkAPI.Operation? { reviews.catalogueRefreshOperation }
    public var pendingProfileReenable: ProfileReenableConfirmation? {
        reviews.pendingProfileReenable
    }
    public var isPreparingProfileReenable: Bool { reviews.isPreparingProfileReenable }
    public var isReenablingProfile: Bool { reviews.isReenablingProfile }
    public var profileReenableOperation: SparkAPI.Operation? { reviews.profileReenableOperation }
    public var profileReenableErrorMessage: String? { reviews.profileReenableErrorMessage }
    public var health: Health? { snapshot.health }
    public var status: SparkStatus? { snapshot.status }
    public var models: [SparkModel] { snapshot.models }
    /// Cache 50 recent operations for Activity; durable recovery uses separate paginated reads.
    static let cachedOperationsPageSize = 50

    public var inference: ActiveInference? { snapshot.inference }
    public var lifecycle: [String: ModelLifecycleState] { operations.lifecycle }
    public var requestedModelID: String? { operations.requestedModelID }
    public var requestedServiceID: String? { operations.requestedServiceID }
    public var downloadActivityError: String? { operations.downloadActivityError }
    public var pendingConfirmation: ModelActionConfirmation? { preview.pendingConfirmation }
    public var pendingLoadConfiguration: ModelLoadConfiguration? {
        preview.pendingLoadConfiguration
    }
    public var isPreparingConfirmation: Bool { preview.isPreparingConfirmation }
    public var isRefreshing: Bool { snapshot.isRefreshing }
    public var errorMessage: String? { snapshot.errorMessage }
    public var identityIssue: SparkDashboardIdentityIssue? { snapshot.identityIssue }
    public var freshness: SparkDashboardFreshness { snapshot.freshness }
    public var cachedSnapshot: TargetOperationalSnapshot? { snapshot.cachedSnapshot }
    public var supportsOpenWebUIPorts: Bool { services.supportsOpenWebUIPorts }
    public var openWebUIPort: String {
        get { services.openWebUIPort }
        set { services.openWebUIPort = newValue }
    }
    public var adoptExistingOpenWebUI: Bool {
        get { services.adoptExistingOpenWebUI }
        set { services.adoptExistingOpenWebUI = newValue }
    }
    public var openWebUIAdminEmail: String {
        get { services.openWebUIAdminEmail }
        set { services.openWebUIAdminEmail = newValue }
    }
    public var openWebUIAdminName: String {
        get { services.openWebUIAdminName }
        set { services.openWebUIAdminName = newValue }
    }
    public var openWebUIAdminPassword: String {
        get { services.openWebUIAdminPassword }
        set { services.openWebUIAdminPassword = newValue }
    }
    public var revealsOpenWebUIAdminPassword: Bool {
        get { services.revealsOpenWebUIAdminPassword }
        set { services.revealsOpenWebUIAdminPassword = newValue }
    }
    public var acceptedOpenWebUIRecipeRevision: String? {
        get { services.acceptedOpenWebUIRecipeRevision }
        set { services.acceptedOpenWebUIRecipeRevision = newValue }
    }
    private let snapshot: SparkDashboardSnapshot
    private let services: SparkDashboardOpenWebUI
    private let reviews: SparkDashboardCatalogueReview
    let operations: SparkModelLifecycleCoordinator
    private let preview: SparkModelPreviewController
    let telemetryModel: SparkDashboardTelemetry
    public let workloadOwnership: SparkWorkloadOwnershipModel

    public let route: URL
    public let targetID: String
    public let tlsFingerprint: String?
    /// PLAN 38.4: a failed status call evaluates the other saved routes immediately.
    @ObservationIgnored
    public var onStatusFailure: (@MainActor () async -> Void)?

    @ObservationIgnored
    private let runtime: any SparkRuntimeReading
    /// Saved coordinator identity supplied by the trusted library entry.
    public let expectedIdentity: SparkDashboardIdentityExpectation?
    @ObservationIgnored
    private let targetIdentity: SparkTargetIdentity?
    @ObservationIgnored
    private let now: @Sendable () -> Date
    @ObservationIgnored
    private let cacheEvidence:
        (@MainActor (TargetOperationalEvidence, Date) -> TargetOperationalSnapshot?)?
    @ObservationIgnored
    private var lastSuccessfulRefresh: Date?
    @ObservationIgnored
    private let telemetryDelay: @Sendable (Duration) async throws -> Void

    /// - Parameter runtime: an explicitly pinned client for this Spark.
    public init(
        route: URL,
        runtime: any SparkRuntimeReading,
        targetID: String? = nil,
        tlsFingerprint: String? = nil,
        expectedIdentity: SparkDashboardIdentityExpectation? = nil,
        targetIdentity: SparkTargetIdentity? = nil,
        cachedSnapshot: TargetOperationalSnapshot? = nil,
        operationStore: any ModelOperationRecoveryStoring =
            UserDefaultsModelOperationRecoveryStore(),
        userPresenceAuthorizer: any UserPresenceAuthorizing = SystemUserPresenceAuthorizer(),
        telemetryCache: any SparkTelemetryCaching = UserDefaultsSparkTelemetryCache(),
        inferenceExperienceAdapter: any SparkInferenceExperienceSampling =
            SparkInferenceExperienceAdapter(),
        inferenceHistoryStore: any SparkInferenceHistoryStoring =
            UserDefaultsSparkInferenceHistoryStore(),
        now: @escaping @Sendable () -> Date = Date.init,
        cacheEvidence:
            (@MainActor (TargetOperationalEvidence, Date) -> TargetOperationalSnapshot?)? = nil,
        operationDelay: (@Sendable (Duration) async throws -> Void)? = nil,
        telemetryDelay: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        catalogueSource: any PublishedCatalogueSource = BootstrapComposition.catalogueSource()
    ) {
        // Construct the default clock here to avoid the compiler's corrupt Duration thunk in signed launches.
        let operationDelay: @Sendable (Duration) async throws -> Void =
            operationDelay ?? { duration in
                try await Task.sleep(for: duration)
            }
        self.route = route
        self.targetID = targetID ?? route.absoluteString
        self.tlsFingerprint = tlsFingerprint
        self.runtime = runtime
        self.workloadOwnership = SparkWorkloadOwnershipModel(
            route: route,
            runtime: runtime,
            userPresenceAuthorizer: userPresenceAuthorizer,
            operationDelay: operationDelay
        )
        self.expectedIdentity = expectedIdentity
        self.targetIdentity = targetIdentity
        self.now = now
        self.cacheEvidence = cacheEvidence
        let cachedAt = cachedSnapshot?.lastSuccessfulContact ?? cachedSnapshot?.evaluatedAt
        self.lastSuccessfulRefresh = cachedAt
        self.telemetryDelay = telemetryDelay
        let snapshot = SparkDashboardSnapshot(
            expectedIdentity: expectedIdentity,
            cachedSnapshot: cachedSnapshot
        )
        let authority = SparkDashboardPresenceAuthority(
            route: route,
            runtime: runtime,
            authorizer: userPresenceAuthorizer
        )
        let operations = SparkModelLifecycleCoordinator(
            route: route,
            targetID: self.targetID,
            runtime: runtime,
            snapshot: snapshot,
            operationStore: operationStore,
            operationDelay: operationDelay
        )
        let preview = SparkModelPreviewController(
            route: route,
            targetID: self.targetID,
            runtime: runtime,
            snapshot: snapshot,
            operations: operations,
            operationStore: operationStore
        )
        let reviews = SparkDashboardCatalogueReview(
            route: route,
            targetID: self.targetID,
            runtime: runtime,
            snapshot: snapshot,
            authority: authority,
            tlsFingerprint: tlsFingerprint,
            catalogueSource: catalogueSource,
            operationDelay: operationDelay
        )
        let services = SparkDashboardOpenWebUI(
            route: route,
            targetID: self.targetID,
            runtime: runtime,
            snapshot: snapshot,
            authority: authority,
            tlsFingerprint: tlsFingerprint,
            operationDelay: operationDelay
        )
        self.snapshot = snapshot
        self.operations = operations
        self.preview = preview
        self.reviews = reviews
        self.services = services
        self.telemetryModel = SparkDashboardTelemetry(
            route: route,
            targetID: self.targetID,
            runtime: runtime,
            snapshot: snapshot,
            telemetryCache: telemetryCache,
            adapter: inferenceExperienceAdapter,
            historyStore: inferenceHistoryStore
        )
        operations.refresh = { [weak self] in await self?.refresh() }
        preview.refresh = { [weak self] in await self?.refresh() }
        reviews.refresh = { [weak self] in await self?.refresh() }
        services.refresh = { [weak self] in await self?.refresh() }
    }

    public func refresh() async {
        guard !isRefreshing else { return }
        snapshot.isRefreshing = true
        snapshot.errorMessage = nil
        defer { snapshot.isRefreshing = false }

        await recoverPendingOperations(queryRuntime: false)
        // Keep live telemetry available when supplementary dashboard reads fail.
        await refreshTelemetry(reportFailure: false)
        // Refresh history on entry and on its separate cadence.
        await refreshHistory()
        do {
            async let loadedHealth = runtime.health(route: route)
            async let loadedStatus = runtime.status(route: route)
            async let loadedModels = runtime.models(route: route)
            async let loadedInference = runtime.activeInference(route: route)
            async let loadedCapabilities = try? runtime.capabilities(route: route)
            async let loadedOpenWebUI = try? runtime.openWebUIStatus(route: route)
            async let loadedCatalogueStatus = try? runtime.catalogueStatus(route: route)
            // Treat inventory as optional, preserving the distinction between refusal and read failure.
            async let loadedWorkloads: Result<GeneratedAPI.WorkloadInventory, any Error> = {
                do { return .success(try await runtime.workloads(route: route)) } catch {
                    return .failure(error)
                }
            }()
            // Cache available durable operations without making their endpoint mandatory.
            async let loadedOperations = try? runtime.operations(
                route: route,
                limit: Self.cachedOperationsPageSize,
                cursor: nil
            )
            let batch = try await (
                health: loadedHealth,
                status: loadedStatus,
                models: loadedModels,
                inference: loadedInference,
                capabilities: loadedCapabilities,
                openWebUI: loadedOpenWebUI,
                catalogueStatus: loadedCatalogueStatus,
                workloads: loadedWorkloads,
                operations: loadedOperations
            )
            if let issue = snapshot.identityIssue(in: batch.health, status: batch.status) {
                snapshot.identityIssue = issue
                reviews.pendingCatalogueRefresh = nil
                reviews.pendingProfileReenable = nil
                snapshot.errorMessage =
                    String(
                        localized:
                            "Spark identity changed. This dashboard kept the last verified data and stopped refreshing."
                    )
                markCachedOrUnavailable()
                return
            }
            snapshot.identityIssue = nil
            snapshot.capabilities = batch.capabilities
            snapshot.capabilitiesChecked = true
            let supportsOpenWebUI =
                batch.capabilities?.isEnabled("optional_service_recipes") == true
                && batch.capabilities?.isEnabled("open_webui_service") == true
            if supportsOpenWebUI {
                if let service = batch.openWebUI {
                    if acceptedOpenWebUIRecipeRevision != service.availableRevision {
                        acceptedOpenWebUIRecipeRevision = nil
                    }
                    services.openWebUIService = service
                    services.postManagedServiceObservation(service)
                    services.openWebUIErrorMessage = nil
                } else {
                    services.openWebUIService = nil
                    services.postManagedServiceObservation(nil)
                    services.openWebUIErrorMessage = String(
                        localized: "Open WebUI status could not be checked."
                    )
                }
            } else {
                services.openWebUIService = nil
                services.postManagedServiceObservation(nil)
                services.openWebUIErrorMessage = nil
                acceptedOpenWebUIRecipeRevision = nil
            }
            if batch.capabilities?.isEnabled("signed_catalogue_refresh") == true {
                reviews.catalogueStatus = batch.catalogueStatus
                reviews.catalogueErrorMessage =
                    batch.catalogueStatus == nil
                    ? String(localized: "Signed catalogue status could not be checked.")
                    : nil
            } else {
                reviews.catalogueStatus = nil
                reviews.catalogueErrorMessage = nil
                reviews.pendingCatalogueRefresh = nil
            }
            if batch.capabilities?.isEnabled("workload_inventory") == true {
                switch batch.workloads {
                case .success(let inventory):
                    snapshot.workloadInventory = inventory
                    snapshot.workloadErrorMessage = nil
                case .failure(let error) where Self.isRefusal(error):
                    // Hide inventory this device is forbidden to read.
                    snapshot.workloadInventory = nil
                    snapshot.workloadErrorMessage = nil
                case .failure:
                    // An unavailable inventory does not prove that the Spark is idle.
                    snapshot.workloadInventory = nil
                    snapshot.workloadErrorMessage = String(
                        localized: "Workloads on this Spark could not be listed."
                    )
                }
            } else {
                snapshot.workloadInventory = nil
                snapshot.workloadErrorMessage = nil
            }
            if batch.capabilities?.isEnabled("model_profile_reenable") != true {
                reviews.pendingProfileReenable = nil
                reviews.profileReenableErrorMessage = nil
            }
            snapshot.health = batch.health
            snapshot.status = batch.status
            snapshot.models = signedCatalogueAvailable ? batch.models.items : []
            snapshot.inference = batch.inference
            if let telemetry {
                telemetryModel.acceptInferenceTelemetry(telemetry, publishNotification: false)
            }
            let observedAt = now()
            lastSuccessfulRefresh = observedAt
            snapshot.freshness = .current(refreshedAt: observedAt)
            if let targetIdentity {
                let evidence = TargetOperationalEvidence(
                    identity: targetIdentity,
                    respondingNodeID: batch.health.nodeID,
                    health: TimedOperationalEvidence(batch.health, observedAt: observedAt),
                    status: TimedOperationalEvidence(batch.status, observedAt: observedAt),
                    inventory: TimedOperationalEvidence(batch.models, observedAt: observedAt),
                    inference: TimedOperationalEvidence(batch.inference, observedAt: observedAt),
                    // Omit failed operation reads so cached evidence is preserved.
                    operations: batch.operations.map {
                        TimedOperationalEvidence($0.items, observedAt: observedAt)
                    }
                )
                snapshot.cachedSnapshot = cacheEvidence?(evidence, observedAt) ?? cachedSnapshot
            }
        } catch is CancellationError {
            return
        } catch {
            snapshot.errorMessage =
                String(
                    localized:
                        "Spark could not be reached. Check that both devices are on the same network."
                )
            markCachedOrUnavailable()
            // 38.4: do not wait for the next cycle to find out another route still works.
            await onStatusFailure?()
            return
        }
        await recoverPendingOperations()
    }
    @discardableResult
    public func prepareLibraryManagement(modelID: String, action: ModelLibraryManagementAction)
        async -> Bool
    {
        await preview.prepareLibraryManagement(modelID: modelID, action: action)
    }

    public static func pollingInterval(_ requested: Duration, conservingPower: Bool) -> Duration {
        conservingPower ? max(requested, .seconds(5)) : requested
    }

    public func runLiveUpdates(interval: Duration = .seconds(1)) async {
        await SparkDashboardLiveUpdater(delay: telemetryDelay).run(
            interval: interval,
            refresh: { await self.refresh() },
            refreshTelemetry: { await self.refreshTelemetry(reportFailure: true) },
            refreshHistory: { await self.refreshHistory() }
        )
    }
    /// An authoritative 403 hides a forbidden surface without suggesting a retry.
    nonisolated static func isRefusal(_ error: any Error) -> Bool {
        (error as? APIError)?.statusCode == 403
    }

    var canScheduleWarmup: Bool {
        guard case .current(let refreshedAt) = freshness,
            Date().timeIntervalSince(refreshedAt) >= 0,
            Date().timeIntervalSince(refreshedAt) <= 30,
            !isRefreshing, identityIssue == nil,
            status?.identity.clusterID == nil, status != nil
        else { return false }
        return capabilities?.isEnabled("scheduled_warmup") == true
    }

    private func markCachedOrUnavailable() {
        services.postManagedServiceObservation(nil)
        let cachedAt =
            lastSuccessfulRefresh
            ?? cachedSnapshot?.lastSuccessfulContact
            ?? cachedSnapshot?.evaluatedAt
        snapshot.freshness = cachedAt.map(SparkDashboardFreshness.cached) ?? .unavailable
    }
    public var nodeName: String { snapshot.nodeName }
    public var runtimeStatus: String { snapshot.runtimeStatus }
    public var runtimeStatusValue: SparkStatusValue { snapshot.runtimeStatusValue }
    public var vllmStatus: String { snapshot.vllmStatus }
    public var vllmStatusValue: SparkStatusValue { snapshot.vllmStatusValue }
    public var containerRuntimeAvailable: Bool { snapshot.containerRuntimeAvailable }
    public var signedCatalogueAvailable: Bool { snapshot.signedCatalogueAvailable }
    public var modelServiceDetail: String { snapshot.modelServiceDetail }
    public var modelCatalogueStatus: String { snapshot.modelCatalogueStatus }
    public var modelCatalogueStatusValue: SparkStatusValue { snapshot.modelCatalogueStatusValue }
    public var modelCatalogueDetail: String { snapshot.modelCatalogueDetail }
    public var openWebUIStatus: String { services.openWebUIStatus }
    public var openWebUIStatusValue: SparkStatusValue { services.openWebUIStatusValue }
    public var openWebUIDetail: String { services.openWebUIDetail }
    public var openWebUISupported: Bool { services.openWebUISupported }
    public var canInstallOpenWebUI: Bool { services.canInstallOpenWebUI }
    public var openWebUIInstallBlocker: String? { services.openWebUIInstallBlocker }
    public var catalogueRefreshSupported: Bool { reviews.catalogueRefreshSupported }
    public var profileReenableSupported: Bool { reviews.profileReenableSupported }
    public var remoteCatalogueStatus: String { reviews.remoteCatalogueStatus }
    public var remoteCatalogueStatusValue: SparkStatusValue { reviews.remoteCatalogueStatusValue }
    public var remoteCatalogueDetail: String { reviews.remoteCatalogueDetail }
    public var catalogueRefreshStageLabel: String { reviews.catalogueRefreshStageLabel }
    public var publishedCatalogue: PublishedCatalogueCheck? { reviews.publishedCatalogue }
    public var publishedCatalogueIsNewer: Bool { reviews.publishedCatalogueIsNewer }
    public var isCheckingPublishedCatalogue: Bool { reviews.isCheckingPublishedCatalogue }
    public var publishedCatalogueStatusLine: String { reviews.publishedCatalogueStatusLine }
    public func checkPublishedCatalogue() async { await reviews.checkPublishedCatalogue() }
    public func preparePublishedCatalogueRefresh() async {
        await reviews.preparePublishedCatalogueRefresh()
    }
    public func prepareBundledPresetUpdate() async {
        await reviews.prepareBundledPresetUpdate()
    }
    public func prepareCatalogueRefresh(candidateJSON: String, fileName: String) async {
        await reviews.prepareCatalogueRefresh(candidateJSON: candidateJSON, fileName: fileName)
    }
    public func cancelCatalogueRefresh() { reviews.cancelCatalogueRefresh() }
    public func applyCatalogueRefresh() async { await reviews.applyCatalogueRefresh() }
    public func prepareProfileReenable(modelID: String, profileID: String) async {
        await reviews.prepareProfileReenable(modelID: modelID, profileID: profileID)
    }
    nonisolated static func profileReenableFailureMessage(_ error: any Error) -> String {
        SparkDashboardFailurePresentation.profileReenableFailureMessage(error)
    }
    public func cancelProfileReenable() { reviews.cancelProfileReenable() }
    public func applyProfileReenable() async { await reviews.applyProfileReenable() }
    public func acceptOpenWebUIRecipe(_ accepted: Bool) { services.acceptOpenWebUIRecipe(accepted) }
    public func installOpenWebUI() async { await services.installOpenWebUI() }
    public func updateOpenWebUI() async { await services.updateOpenWebUI() }
    public var canRepairOpenWebUI: Bool { services.canRepairOpenWebUI }
    public func repairOpenWebUI() async { await services.repairOpenWebUI() }
    public func removeOpenWebUI(eraseData: Bool) async {
        await services.removeOpenWebUI(eraseData: eraseData)
    }
    public func requestOpenWebUIAccess() async { await services.requestOpenWebUIAccess() }
    public func dismissOpenWebUI() { services.dismissOpenWebUI() }
    public var installedModelCount: Int { snapshot.installedModelCount }
    public var availableModelCount: Int { snapshot.availableModelCount }
    public var runtimeVersion: String? { snapshot.runtimeVersion }
    public var activeModelID: String? { snapshot.activeModelID }
    public var cachedPlacements: [ModelPlacementSnapshot] { snapshot.cachedPlacements }
    public var hasRenderableData: Bool { snapshot.hasRenderableData }
    public var isShowingCachedData: Bool { snapshot.isShowingCachedData }
    public var cachedAt: Date? { snapshot.cachedAt }
    public var memoryPressure: MemoryPressureLevel? { telemetryModel.memoryPressure }
    public var pressurePresentation: MemoryPressurePresentation? {
        telemetryModel.pressurePresentation
    }
    public var memorySummary: String? { snapshot.memorySummary }
    public var pressureLabel: String { telemetryModel.pressureLabel }
    public var pressureValue: SparkStatusValue { telemetryModel.pressureValue }
    public func lifecycleState(for modelID: String) -> ModelLifecycleState? {
        return operations.lifecycleState(for: modelID)
    }
    public func recoverPendingOperations(queryRuntime: Bool = true) async {
        await operations.recoverPendingOperations(queryRuntime: queryRuntime)
    }
    public func retryStatus(
        modelID: String,
        progress: @escaping @MainActor (SparkAPI.Operation) -> Void = { _ in }
    ) async {
        await operations.retryStatus(modelID: modelID, progress: progress)
    }
    public var unlistedModelIDsNeedingRecovery: [String] {
        operations.unlistedModelIDsNeedingRecovery
    }
    public func retryIncompleteOperation(modelID: String) async {
        await operations.retryIncompleteOperation(modelID: modelID)
    }
    public func prepareInstall(modelID: String, providerCredentialID: String? = nil) async {
        await preview.prepareInstall(modelID: modelID, providerCredentialID: providerCredentialID)
    }
    public func prepareLoad(
        modelID: String,
        replaceActive: Bool,
        profileID: String? = nil
    ) async {
        await preview.prepareLoad(
            modelID: modelID,
            replaceActive: replaceActive,
            profileID: profileID
        )
    }
    public func previewLoadConfiguration(profileID: String) async {
        await preview.previewLoadConfiguration(profileID: profileID)
    }
    public func canChooseLoadProfile(modelID: String) -> Bool {
        return preview.canChooseLoadProfile(modelID: modelID)
    }
    public var canChangeLoadProfile: Bool { preview.canChangeLoadProfile }
    public func changeLoadProfile() async { await preview.changeLoadProfile() }
    @discardableResult
    public func prepareVerifiedLoad(
        modelID: String,
        profileID: String,
        expectedRecipeRevision: String,
        targetNodeID: String,
        targetClusterID: String?
    ) async -> Bool {
        return await preview.prepareVerifiedLoad(
            modelID: modelID,
            profileID: profileID,
            expectedRecipeRevision: expectedRecipeRevision,
            targetNodeID: targetNodeID,
            targetClusterID: targetClusterID
        )
    }
    public func prepareStopActiveModel() async { await preview.prepareStopActiveModel() }
    public func prepareRemove(modelID: String) async {
        await preview.prepareRemove(modelID: modelID)
    }
    public func cancelConfirmation() { preview.cancelConfirmation() }
    public func applyConfirmation(
        userPresence: String? = nil,
        progress: @escaping @MainActor (SparkAPI.Operation) -> Void = { _ in }
    ) async {
        await preview.applyConfirmation(userPresence: userPresence, progress: progress)
    }
    public func refreshPreview(modelID: String, providerCredentialID: String? = nil) async {
        await preview.refreshPreview(modelID: modelID, providerCredentialID: providerCredentialID)
    }
    public func stopMonitoring() { operations.stopMonitoring() }
}
