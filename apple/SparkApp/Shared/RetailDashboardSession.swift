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
final class RetailDashboardSession {
    /// Written by hand so clearing the dashboard also detaches its event stream (§44.1).
    var dashboardModel: SparkDashboardModel? {
        get {
            access(keyPath: \.dashboardModel)
            return openDashboardModel
        }
        set {
            withMutation(keyPath: \.dashboardModel) { openDashboardModel = newValue }
            if newValue == nil { stopEventSubscription() }
        }
    }
    @ObservationIgnored
    private var openDashboardModel: SparkDashboardModel?
    @ObservationIgnored
    var onStatusFailure: (@MainActor (String, URL) async -> Void)?
    /// The open dashboard's live event reader; polling continues regardless of whether it exists.
    @ObservationIgnored
    private(set) var eventSubscription: SparkEventSubscription?
    var dashboardFailureDetail: String?
    var providerCredentialModel: ProviderCredentialModel?
    var automationsModel: SparkAutomationsModel?
    var deviceManagementModel: DeviceManagementModel?
    var sharedAccessModel: SharedAccessModel?
    var guestExperienceModel: GuestExperienceModel?
    var remoteAccessModel: RemoteAccessModel?
    var networkStatusModel: SparkNetworkStatusModel?
    var settingsModel: SparkSettingsModel?
    var powerControlModel: SparkPowerControlModel?
    var diagnosticsExportModel: DiagnosticsExportModel?
    var identitySettingsModel: SparkIdentitySettingsModel?
    var dashboardTrust: NodeTrust?
    var resolvedRuntime: (any SparkRuntimeReading)?
    private let session: RetailSetupSession
    private let runtime: (any SparkRuntimeReading)?
    private let runtimeInstaller: any RuntimeBootstrapInstalling
    private let signerProvider: RetailOnboardingModel.SignerProvider
    private let settingsUserPresenceAuthorizer: any UserPresenceAuthorizing
    private let library: SparkLibrary
    private let nodeTrustReader: @Sendable (String) -> NodeTrust?
    private let localDeviceIDProvider: @MainActor () -> String?
    private let savedRouteDiscovery: any SavedSparkRouteDiscovering
    private let identityResolver: any AuthenticatedIdentityResolving
    private let now: @Sendable () -> Date
    init(
        session: RetailSetupSession,
        runtime: (any SparkRuntimeReading)?,
        runtimeInstaller: any RuntimeBootstrapInstalling,
        signerProvider: @escaping RetailOnboardingModel.SignerProvider,
        settingsUserPresenceAuthorizer: any UserPresenceAuthorizing,
        library: SparkLibrary,
        nodeTrustReader: @escaping @Sendable (String) -> NodeTrust?,
        localDeviceIDProvider: @escaping @MainActor () -> String?,
        savedRouteDiscovery: any SavedSparkRouteDiscovering,
        identityResolver: any AuthenticatedIdentityResolving,
        now: @escaping @Sendable () -> Date
    ) {
        self.session = session
        self.runtime = runtime
        self.runtimeInstaller = runtimeInstaller
        self.signerProvider = signerProvider
        self.settingsUserPresenceAuthorizer = settingsUserPresenceAuthorizer
        self.library = library
        self.nodeTrustReader = nodeTrustReader
        self.localDeviceIDProvider = localDeviceIDProvider
        self.savedRouteDiscovery = savedRouteDiscovery
        self.identityResolver = identityResolver
        self.now = now
    }
    private var isAddingSpark: Bool {
        get { session.isAddingSpark }
        set { session.isAddingSpark = newValue }
    }
    private var administratorUsername: String? {
        get { session.administratorUsername }
        set { session.administratorUsername = newValue }
    }
    private var pairedNode: NodeTrust? {
        get { session.pairedNode }
        set { session.pairedNode = newValue }
    }
    private var pairedRouteURL: URL? {
        get { session.pairedRouteURL }
        set { session.pairedRouteURL = newValue }
    }
    private func send(_ event: RetailOnboardingEvent) { session.send(event) }

    func prepareDashboard(route: URL, entry: LibraryEntry) {
        do {
            let dashboardRuntime: any SparkRuntimeReading
            if let pairedNode, pairedRouteURL == route {
                dashboardRuntime = try SparkAPIClient.pinned(
                    to: pairedNode.tlsFingerprint,
                    signer: signer(forNode: pairedNode.nodeID)
                )
            } else if let runtime {
                dashboardRuntime = runtime
            } else {
                dashboardFailureDetail =
                    String(
                        localized:
                            "This device has no trusted connection for that Spark. Pair it again."
                    )
                return
            }
            let trust = pairedNode.flatMap { pairedRouteURL == route ? $0 : nil }
            publishDashboard(
                route: route,
                runtime: dashboardRuntime,
                targetID: entry.id,
                entry: entry,
                trust: trust
            )
            isAddingSpark = false
        } catch {
            // Report dashboard key failure separately because installation and pairing have already succeeded.
            dashboardFailureDetail =
                String(
                    localized: """
                        This device's signing key could not be opened, so it cannot \
                        talk to your Spark. Restart the app; if it happens again, the \
                        key may need to be re-created by pairing this device once more.
                        """
                )
            send(.failed(.deviceKeyUnavailable))
        }
    }

    func publishDashboard(
        route: URL,
        runtime: any SparkRuntimeReading,
        targetID: String,
        entry: LibraryEntry,
        trust: NodeTrust?
    ) {
        guard let coordinatorNodeID = entry.coordinatorNodeID else {
            dashboardFailureDetail = String(
                localized: "This target has no trusted coordinator to open."
            )
            return
        }
        let coordinator = entry.member(nodeID: coordinatorNodeID)
        let savedTrust =
            trust
            ?? nodeTrustReader(coordinatorNodeID.rawValue.uuidString.lowercased())
        dashboardTrust = trust
        let pendingDashboardModel = SparkDashboardModel(
            route: route,
            runtime: runtime,
            targetID: targetID,
            tlsFingerprint: savedTrust?.tlsFingerprint,
            expectedIdentity: SparkDashboardIdentityExpectation(
                coordinatorNodeID: coordinatorNodeID,
                authorityFingerprint: coordinator?.authorityFingerprint,
                clusterID: entry.clusterID
            ),
            targetIdentity: entry.logicalKey,
            cachedSnapshot: library.operationalSnapshot(for: entry.id),
            userPresenceAuthorizer: settingsUserPresenceAuthorizer,
            cacheEvidence: { [library, entryID = entry.id] evidence, observedAt in
                library.recordOperationalEvidence(evidence, for: entryID, at: observedAt)
            }
        )
        pendingDashboardModel.onStatusFailure = { [weak self] in
            await self?.onStatusFailure?(targetID, route)
        }
        automationsModel = (runtime as? any SparkAutomationManaging).map {
            SparkAutomationsModel(
                route: route,
                targetID: targetID,
                runtime: $0,
                localDeviceRole: savedTrust?.localDeviceRole,
                userPresenceAuthorizer: settingsUserPresenceAuthorizer
            )
        }
        providerCredentialModel = (runtime as? any ProviderCredentialManaging).map {
            ProviderCredentialModel(
                route: route,
                targetID: targetID,
                runtime: $0,
                localDeviceRole: savedTrust?.localDeviceRole,
                userPresenceAuthorizer: settingsUserPresenceAuthorizer
            )
        }
        remoteAccessModel = nil
        networkStatusModel = (runtime as? any SparkNetworkStatusReading).map {
            SparkNetworkStatusModel(route: route, runtime: $0)
        }
        // Persist the administrator username learned during setup for subsequent runtime maintenance.
        if let administratorUsername {
            library.recordAdministratorUsername(administratorUsername, for: entry.id)
        }
        let knownAdministratorUsername = administratorUsername ?? entry.administratorUsername
        settingsModel = (runtime as? any SparkSettingsManaging).map {
            SparkSettingsModel(
                route: route,
                runtime: $0,
                runtimeInstaller: runtimeInstaller,
                administratorUsername: knownAdministratorUsername,
                userPresenceAuthorizer: settingsUserPresenceAuthorizer,
                networkRouteDiscovery: savedRouteDiscovery,
                onKeptNetworkRoute: { [weak self] verifiedRoute, identity in
                    self?.adoptKeptNetworkRoute(
                        verifiedRoute,
                        identity: identity,
                        runtime: runtime,
                        targetID: targetID
                    )
                },
                onAdministratorUsernameConfirmed: { [library, entryID = entry.id] username in
                    library.recordAdministratorUsername(username, for: entryID)
                }
            )
        }
        powerControlModel = nil
        identitySettingsModel = SparkIdentitySettingsModel(
            route: route,
            entryID: targetID,
            nodeID: coordinatorNodeID,
            displayName: entry.displayName,
            hostname: coordinator?.hostname,
            library: library,
            runtime: runtime as? any SparkHostnameControlling,
            canChangeHostname: trust?.localDeviceRole == "owner"
        )
        // A guest reads only its own record; the owner's screen is built beside the device list.
        guestExperienceModel = (runtime as? any OwnSharedAccessProviding)
            .map {
                GuestExperienceModel(
                    route: route,
                    runtime: $0,
                    nodeID: coordinatorNodeID.rawValue.uuidString.lowercased()
                )
            }
        let ownerRuntime =
            trust?.localDeviceRole == "owner" ? runtime as? any SharedAccessProviding : nil
        sharedAccessModel = ownerRuntime.map { SharedAccessModel(route: route, runtime: $0) }
        guard trust != nil, let provider = runtime as? any DeviceManagementProviding else {
            deviceManagementModel = nil
            dashboardModel = pendingDashboardModel
            startEventSubscription(
                route: route,
                targetID: targetID,
                nodeID: coordinatorNodeID,
                pin: savedTrust?.tlsFingerprint
            )
            return
        }
        deviceManagementModel = DeviceManagementModel(
            route: route,
            targetID: targetID,
            localDeviceID: localDeviceIDProvider(),
            provider: provider,
            userPresenceAuthorizer: SystemUserPresenceAuthorizer(),
            onLocalDeviceRoleResolved: { [weak self] role in
                self?.providerCredentialModel?.updateLocalDeviceRole(role?.rawValue)
                self?.automationsModel?.updateLocalDeviceRole(role?.rawValue)
                self?.configureRemoteAccess(
                    route: route,
                    runtime: runtime,
                    targetID: targetID,
                    localRole: role?.rawValue
                )
            },
            now: now
        )
        dashboardModel = pendingDashboardModel
        configureRemoteAccess(
            route: route,
            runtime: runtime,
            targetID: targetID,
            localRole: savedTrust?.localDeviceRole
        )
        startEventSubscription(
            route: route,
            targetID: targetID,
            nodeID: coordinatorNodeID,
            pin: savedTrust?.tlsFingerprint
        )
    }

    /// Subscribe with the screen; a Spark that will not stream simply leaves polling to do the work.
    private func startEventSubscription(
        route: URL,
        targetID: String,
        nodeID: SparkNodeID,
        pin: String?
    ) {
        stopEventSubscription()
        let subscription = SparkEventStreamOpening.subscription(
            route: route,
            pin: pin,
            signer: try? signer(forNode: nodeID.rawValue.uuidString.lowercased()),
            apply: { [weak self] refresh in
                await self?.applyEventRefresh(refresh, targetID: targetID)
            }
        )
        eventSubscription = subscription
        subscription?.start()
    }

    func stopEventSubscription() {
        eventSubscription?.stop()
        eventSubscription = nil
    }

    /// Read again only what the event changed; §38.4's polling loop stays the safety net.
    func applyEventRefresh(_ refresh: SparkEventRefresh, targetID: String) async {
        guard let dashboardModel, dashboardModel.targetID == targetID else { return }
        let snapshot: SparkEventRefresh = [.status, .models, .operations, .inference, .workloads]
        if !refresh.isDisjoint(with: snapshot) { await dashboardModel.refresh() }
        if refresh.contains(.telemetry) {
            await dashboardModel.refreshTelemetry(reportFailure: false)
        }
        if refresh.contains(.devices) { await deviceManagementModel?.refresh() }
        if refresh.contains(.sharedAccess) { await sharedAccessModel?.refresh() }
        if refresh.contains(.remoteAccess) { await remoteAccessModel?.refresh() }
        if refresh.contains(.automations) { await automationsModel?.load() }
    }

    /// Persist the verified node's new route and rebuild route-bound models with the same runtime and trust.
    func adoptKeptNetworkRoute(
        _ verifiedRoute: URL,
        identity: SparkIdentity,
        runtime: any SparkRuntimeReading,
        targetID: String
    ) {
        guard let dashboardModel,
            dashboardModel.targetID == targetID,
            let entry = library.entry(id: targetID),
            let coordinatorNodeID = entry.coordinatorNodeID,
            coordinatorNodeID == identity.nodeID,
            let coordinator = entry.member(nodeID: coordinatorNodeID),
            let priorRoute = coordinator.routes.first(where: {
                RetailRouteComparison.sameRoute($0.baseURL, dashboardModel.route)
            }) ?? entry.preferredRoute
        else { return }

        let reachedAt = now()
        let observedRoute = CachedRoute(
            id: priorRoute.id,
            slotID: priorRoute.slotID,
            baseURL: verifiedRoute,
            kind: priorRoute.kind,
            interfaceName: priorRoute.interfaceName,
            peerFingerprint: priorRoute.peerFingerprint,
            lastSuccess: reachedAt,
            isMetered: priorRoute.isMetered
        )
        let routeHost = verifiedRoute.host ?? ""
        let hostname =
            routeHost.lowercased().hasSuffix(".local")
            ? String(routeHost.dropLast(".local".count))
            : (routeHost.isEmpty ? coordinator.hostname ?? identity.name : routeHost)
        let outcome = library.reconcile(
            AuthenticatedTarget(
                nodeID: coordinatorNodeID,
                clusterID: entry.clusterID,
                name: coordinator.name,
                role: coordinator.role,
                authorityFingerprint: coordinator.authorityFingerprint,
                displayName: hostname,
                routes: [observedRoute],
                reachedAt: reachedAt
            )
        )
        guard outcome.entry.id == targetID, outcome.effect != .identityChanged else { return }

        let trust = dashboardTrust
        dashboardModel.stopMonitoring()
        publishDashboard(
            route: verifiedRoute,
            runtime: runtime,
            targetID: targetID,
            entry: outcome.entry,
            trust: trust
        )
    }

    func configureRemoteAccess(
        route: URL,
        runtime: any SparkRuntimeReading,
        targetID: String,
        localRole: String?
    ) {
        guard dashboardModel?.targetID == targetID else { return }
        identitySettingsModel?.setCanChangeHostname(localRole == "owner")
        // Resolve owner-or-administrator support access before the stricter owner-only controls.
        if localRole == "owner" || localRole == "administrator",
            let provider = runtime as? any DiagnosticsExporting
        {
            if diagnosticsExportModel?.route != route {
                diagnosticsExportModel = DiagnosticsExportModel(
                    route: route,
                    service: provider,
                    userPresenceAuthorizer: settingsUserPresenceAuthorizer
                )
            }
        } else {
            diagnosticsExportModel = nil
        }
        guard localRole == "owner" else {
            remoteAccessModel = nil
            powerControlModel = nil
            return
        }
        if let provider = runtime as? any RemoteAccessReading {
            if remoteAccessModel?.route != route {
                remoteAccessModel = RemoteAccessModel(
                    route: route,
                    runtime: provider,
                    routeRegistration: LibraryRemoteAccessRouteRegistration(
                        library: library,
                        identityResolver: identityResolver,
                        targetID: targetID
                    )
                )
                if let remoteAccessModel { Task { await remoteAccessModel.loadIfNeeded() } }
            }
        } else {
            remoteAccessModel = nil
        }
        if let provider = runtime as? any SparkPowerControlling {
            if powerControlModel?.route != route {
                powerControlModel = SparkPowerControlModel(route: route, runtime: provider)
            }
        } else {
            powerControlModel = nil
        }
    }

    func signer(forNode nodeID: String) throws -> any RequestSigning {
        guard let identifier = UUID(uuidString: nodeID) else {
            throw RetailSignerError.invalidNodeID
        }
        return try signerProvider(identifier)
    }
}
