import Foundation
import Network
import Observation
import SparkAPI
import SparkBootstrap
import SparkCore
import SparkDiscovery
import SparkDesignSystem
import SparkLibrary
import SparkIntents
import SparkSecurity
import SparkTransport
@MainActor
@Observable
final class RetailInvitationWorkflow {
    var invitation: DeviceInvitationModel?
    var isBatchInvitingDevice = false
    var batchInvitationProgress: BatchInvitationProgress?
    var batchInvitationPayload: String?
    var batchInvitationError: String?
    var isCreatingBatchInvitation = false
    var batchInvitationCoordinator: BatchDeviceInvitationCoordinator?
    private let dashboard: RetailDashboardSession
    private let library: SparkLibrary
    private let runtime: (any SparkRuntimeReading)?
    private let nodeTrustReader: @Sendable (String) -> NodeTrust?
    private let additionalDevicePairingService: (any AdditionalDevicePairingServicing)?
    private let signerProvider: RetailOnboardingModel.SignerProvider
    private let settingsUserPresenceAuthorizer: any UserPresenceAuthorizing
    private let now: @Sendable () -> Date
    init(
        dashboard: RetailDashboardSession,
        library: SparkLibrary,
        runtime: (any SparkRuntimeReading)?,
        nodeTrustReader: @escaping @Sendable (String) -> NodeTrust?,
        additionalDevicePairingService: (any AdditionalDevicePairingServicing)?,
        signerProvider: @escaping RetailOnboardingModel.SignerProvider,
        settingsUserPresenceAuthorizer: any UserPresenceAuthorizing,
        now: @escaping @Sendable () -> Date
    ) {
        self.dashboard = dashboard
        self.library = library
        self.runtime = runtime
        self.nodeTrustReader = nodeTrustReader
        self.additionalDevicePairingService = additionalDevicePairingService
        self.signerProvider = signerProvider
        self.settingsUserPresenceAuthorizer = settingsUserPresenceAuthorizer
        self.now = now
    }
    private var dashboardModel: SparkDashboardModel? {
        get { dashboard.dashboardModel }
        set { dashboard.dashboardModel = newValue }
    }
    private var deviceManagementModel: DeviceManagementModel? {
        get { dashboard.deviceManagementModel }
        set { dashboard.deviceManagementModel = newValue }
    }
    private var dashboardTrust: NodeTrust? {
        get { dashboard.dashboardTrust }
        set { dashboard.dashboardTrust = newValue }
    }
    private var resolvedRuntime: (any SparkRuntimeReading)? {
        get { dashboard.resolvedRuntime }
        set { dashboard.resolvedRuntime = newValue }
    }

    var batchInvitationSources: [BatchInvitationSource] {
        library.entries.compactMap { entry in
            guard entry.kind == .standalone,
                let nodeID = entry.standaloneNodeID?.rawValue.uuidString.lowercased(),
                let route = entry.preferredRoute?.baseURL,
                let trust = nodeTrustReader(nodeID),
                trust.localDeviceRole == "owner"
            else { return nil }
            return BatchInvitationSource(
                nodeID: nodeID,
                nodeName: entry.displayName,
                route: route,
                tlsFingerprint: trust.tlsFingerprint,
                authorityPublicKey: trust.authorityPublicKey
            )
        }
    }

    // MARK: - Inviting another Apple device (§10.7, §15.3)

    /// Create invitations only through the open authenticated dashboard using trust recorded during pairing.
    func beginInvitingDevice() {
        guard invitation == nil,
            let dashboardModel,
            let dashboardTrust,
            let runtime = resolvedRuntime ?? runtime,
            !allowedInvitationRoles.isEmpty
        else { return }
        invitation = DeviceInvitationModel(
            route: dashboardModel.route,
            trust: dashboardTrust,
            runtime: runtime,
            allowedRoles: allowedInvitationRoles,
            now: now
        )
    }

    func cancelInvitingDevice() {
        invitation = nil
    }

    func beginInvitingDeviceToSeveralSparks() {
        batchInvitationProgress = nil
        batchInvitationPayload = nil
        batchInvitationError = nil
        isBatchInvitingDevice = true
    }

    func createBatchInvitation(
        recipientRequestPayload: String,
        selectedNodeIDs: Set<String>,
        role: InvitedDeviceRole
    ) async {
        guard !isCreatingBatchInvitation, let additionalDevicePairingService else { return }
        let sources = batchInvitationSources.filter {
            selectedNodeIDs.contains($0.nodeID.lowercased())
        }
        guard sources.count >= BatchAdditionalDevicePairingPackage.minimumTargets else {
            batchInvitationError = String(localized: "Select at least two owner-managed Sparks.")
            return
        }
        isCreatingBatchInvitation = true
        batchInvitationError = nil
        defer { isCreatingBatchInvitation = false }

        do {
            let issuer = try additionalDevicePairingService.recipientIdentity()
            var clients: [String: SparkAPIClient] = [:]
            for source in sources {
                guard let nodeID = UUID(uuidString: source.nodeID) else {
                    throw BatchInvitationCoordinatorError.invalidSource(nodeID: source.nodeID)
                }
                let signer = try signerProvider(nodeID)
                clients[source.id] = try SparkAPIClient.pinned(
                    to: source.tlsFingerprint,
                    signer: signer
                )
            }
            let clientsByNode = clients
            let presence = BatchPresenceSessionProvider(
                authorizer: settingsUserPresenceAuthorizer
            )
            let coordinator = BatchDeviceInvitationCoordinator(
                issuer: issuer,
                issue: { source, recipient, requestedRole, idempotencyKey in
                    guard let client = clientsByNode[source.id] else {
                        throw BatchInvitationCoordinatorError.invalidSource(
                            nodeID: source.nodeID
                        )
                    }
                    let session = try await presence.session()
                    do {
                        return try await client.createBoundPairingInvitation(
                            route: source.route,
                            role: requestedRole,
                            expiresInSeconds: 300,
                            recipientDeviceID: recipient.deviceID,
                            recipientPublicKeyFingerprint: recipient.publicKeyFingerprint,
                            idempotencyKey: idempotencyKey,
                            userPresence: session
                        )
                    } catch let error as APIError
                        where error.code == "USER_PRESENCE_NOT_REGISTERED"
                    {
                        _ = try await client.enrollPresenceKey(
                            route: source.route,
                            idempotencyKey: UUID(),
                            userPresence: session
                        )
                        let retrySession = try await presence.session(forceRefresh: true)
                        return try await client.createBoundPairingInvitation(
                            route: source.route,
                            role: requestedRole,
                            expiresInSeconds: 300,
                            recipientDeviceID: recipient.deviceID,
                            recipientPublicKeyFingerprint: recipient.publicKeyFingerprint,
                            idempotencyKey: idempotencyKey,
                            userPresence: retrySession
                        )
                    }
                },
                revoke: { source, recipientID, idempotencyKey in
                    guard let client = clientsByNode[source.id] else {
                        throw BatchInvitationCoordinatorError.invalidSource(
                            nodeID: source.nodeID
                        )
                    }
                    try await client.revokeDevice(
                        route: source.route,
                        deviceID: recipientID.uuidString.lowercased(),
                        idempotencyKey: idempotencyKey,
                        userPresence: try await presence.session()
                    )
                }
            )
            batchInvitationCoordinator = coordinator
            let result = try await coordinator.create(
                recipientRequestPayload: recipientRequestPayload,
                role: role.rawValue,
                sources: sources
            )
            batchInvitationProgress = result.progress
            batchInvitationPayload = result.payload
            if result.payload == nil {
                batchInvitationError = String(
                    localized:
                        "Some Sparks could not create an invitation. Retry only the failed Sparks."
                )
            }
        } catch {
            batchInvitationError = RetailOnboardingFailurePresentation.describe(
                batchInvitationError: error
            )
        }
    }

    func retryBatchInvitation(nodeID: String) async {
        guard !isCreatingBatchInvitation, let coordinator = batchInvitationCoordinator,
            let batchID = batchInvitationProgress?.batchID
        else { return }
        isCreatingBatchInvitation = true
        defer { isCreatingBatchInvitation = false }
        do {
            let result = try await coordinator.retry(batchID: batchID, nodeID: nodeID)
            batchInvitationProgress = result.progress
            batchInvitationPayload = result.payload
            batchInvitationError =
                result.payload == nil
                ? String(localized: "One or more Sparks still need attention.") : nil
        } catch {
            batchInvitationError = RetailOnboardingFailurePresentation.describe(
                batchInvitationError: error
            )
        }
    }

    func revokeBatchInvitationGrants() async {
        guard !isCreatingBatchInvitation, let coordinator = batchInvitationCoordinator,
            let batchID = batchInvitationProgress?.batchID
        else { return }
        isCreatingBatchInvitation = true
        defer { isCreatingBatchInvitation = false }
        do {
            let progress = try await coordinator.compensate(batchID: batchID)
            batchInvitationProgress = progress
            batchInvitationPayload = nil
            batchInvitationError =
                progress.failedCount == 0
                ? nil
                : String(localized: "Some Sparks could not revoke the device. Retry the undo.")
        } catch {
            batchInvitationError = RetailOnboardingFailurePresentation.describe(
                batchInvitationError: error
            )
        }
    }

    func cancelBatchInvitation() {
        guard !isCreatingBatchInvitation else { return }
        isBatchInvitingDevice = false
        batchInvitationProgress = nil
        batchInvitationPayload = nil
        batchInvitationError = nil
        batchInvitationCoordinator = nil
    }

    /// Whether an invitation can be offered for the Spark on screen.
    var canInviteDevice: Bool {
        dashboardModel != nil && dashboardTrust != nil && (resolvedRuntime ?? runtime) != nil
            && !allowedInvitationRoles.isEmpty
    }

    var canInviteDeviceToSeveralSparks: Bool {
        batchInvitationSources.count >= BatchAdditionalDevicePairingPackage.minimumTargets
    }

    private var allowedInvitationRoles: [InvitedDeviceRole] {
        let role =
            dashboardTrust?.localDeviceRole ?? deviceManagementModel?.localDeviceRole?.rawValue
        return switch role {
        case "owner": [.administrator, .user]
        case "administrator": [.user]
        default: []
        }
    }

    /// Show device access only for a trusted dashboard with signed device-management support.
    var canManageDevices: Bool {
        dashboardModel != nil && dashboardTrust != nil && deviceManagementModel != nil
    }

}
