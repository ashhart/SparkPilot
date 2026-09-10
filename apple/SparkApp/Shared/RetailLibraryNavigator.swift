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
final class RetailLibraryNavigator {
    var openingLibraryEntryID: String?
    var libraryOpenFailure: SavedSparkOpenFailure?
    var activeProbeTask: Task<Void, Never>?
    var isRefreshingSavedSparks = false
    var probeGeneration = 0
    private let dashboard: RetailDashboardSession
    private let pairing: RetailPairingWorkflow
    private let session: RetailSetupSession
    private let runtime: (any SparkRuntimeReading)?
    let library: SparkLibrary
    /// One in-flight probe per entry, and the generation that says whose answer still counts.
    let probes = RetailEntryProbes()
    private let signerProvider: RetailOnboardingModel.SignerProvider
    private let nodeTrustReader: @Sendable (String) -> NodeTrust?
    private let identityResolver: any AuthenticatedIdentityResolving
    let savedRouteDiscovery: any SavedSparkRouteDiscovering
    let now: @Sendable () -> Date
    var invalidateInvitation: () -> Void = {}
    init(
        dashboard: RetailDashboardSession,
        pairing: RetailPairingWorkflow,
        session: RetailSetupSession,
        runtime: (any SparkRuntimeReading)?,
        library: SparkLibrary,
        signerProvider: @escaping RetailOnboardingModel.SignerProvider,
        nodeTrustReader: @escaping @Sendable (String) -> NodeTrust?,
        identityResolver: any AuthenticatedIdentityResolving,
        savedRouteDiscovery: any SavedSparkRouteDiscovering,
        now: @escaping @Sendable () -> Date
    ) {
        self.dashboard = dashboard
        self.pairing = pairing
        self.session = session
        self.runtime = runtime
        self.library = library
        self.signerProvider = signerProvider
        self.nodeTrustReader = nodeTrustReader
        self.identityResolver = identityResolver
        self.savedRouteDiscovery = savedRouteDiscovery
        self.now = now
        dashboard.onStatusFailure = { [weak self] entryID, route in
            await self?.evaluateAlternateRoutes(entryID: entryID, failed: route)
        }
    }
    private var isAddingSpark: Bool {
        get { session.isAddingSpark }
        set { session.isAddingSpark = newValue }
    }
    private var isChoosingSpark: Bool {
        get { session.isChoosingSpark }
        set { session.isChoosingSpark = newValue }
    }
    private var pairingDeviceTarget: DiscoveredSpark? {
        get { pairing.pairingDeviceTarget }
        set { pairing.pairingDeviceTarget = newValue }
    }
    private var dashboardModel: SparkDashboardModel? {
        get { dashboard.dashboardModel }
        set { dashboard.dashboardModel = newValue }
    }
    private var deviceManagementModel: DeviceManagementModel? {
        get { dashboard.deviceManagementModel }
        set { dashboard.deviceManagementModel = newValue }
    }
    private var remoteAccessModel: RemoteAccessModel? {
        get { dashboard.remoteAccessModel }
        set { dashboard.remoteAccessModel = newValue }
    }
    private var networkStatusModel: SparkNetworkStatusModel? {
        get { dashboard.networkStatusModel }
        set { dashboard.networkStatusModel = newValue }
    }
    private var settingsModel: SparkSettingsModel? {
        get { dashboard.settingsModel }
        set { dashboard.settingsModel = newValue }
    }
    private var powerControlModel: SparkPowerControlModel? {
        get { dashboard.powerControlModel }
        set { dashboard.powerControlModel = newValue }
    }
    private var identitySettingsModel: SparkIdentitySettingsModel? {
        get { dashboard.identitySettingsModel }
        set { dashboard.identitySettingsModel = newValue }
    }
    private var dashboardTrust: NodeTrust? {
        get { dashboard.dashboardTrust }
        set { dashboard.dashboardTrust = newValue }
    }
    private var resolvedRuntime: (any SparkRuntimeReading)? {
        get { dashboard.resolvedRuntime }
        set { dashboard.resolvedRuntime = newValue }
    }

    /// Authenticate the saved route before publishing a dashboard, and return its cancellable probe task.
    @discardableResult
    func openLibraryEntry(_ entryID: String) -> Task<Void, Never>? {
        // Bind failure feedback and dashboard publication to the same probe generation.
        cancelProbe()
        guard let entry = library.entry(id: entryID) else { return nil }
        guard entry.issue == nil else {
            libraryOpenFailure = SavedSparkOpenFailure(entryID: entryID, reason: .identityMismatch)
            return nil
        }
        guard let route = entry.preferredRoute else {
            libraryOpenFailure = SavedSparkOpenFailure(entryID: entryID, reason: .noRoute)
            return nil
        }
        isAddingSpark = false
        openingLibraryEntryID = entryID
        let generation = probeGeneration
        let task = Task { @MainActor in
            defer {
                if generation == probeGeneration { openingLibraryEntryID = nil }
            }
            var failure = SavedSparkOpenFailure.Reason.unavailable
            let authenticatedRoute = await authenticateEntryRoute(
                entryID: entryID,
                initialRoute: route,
                onFailure: { reason in
                    // Preserve an authentication or identity refusal over a later failed discovery address.
                    if reason.rawValue > failure.rawValue { failure = reason }
                }
            )
            guard !Task.isCancelled,
                generation == probeGeneration,
                library.entry(id: entryID) != nil
            else { return }
            guard let authenticatedRoute else {
                libraryOpenFailure = SavedSparkOpenFailure(entryID: entryID, reason: failure)
                return
            }
            // Open on the route that answered, which is Tailscale when this device is away from the Spark's network.
            guard let dashboardRuntime = resolvedRuntime ?? runtime,
                let selectedEntry = library.entry(id: entryID),
                let selectedRoute = Optional(authenticatedRoute)
            else {
                libraryOpenFailure = SavedSparkOpenFailure(
                    entryID: entryID,
                    reason: .secureConnectionUnavailable
                )
                return
            }
            let trust = selectedEntry.coordinatorNodeID
                .flatMap { nodeTrustReader($0.rawValue.uuidString.lowercased()) }
            dashboard.publishDashboard(
                route: selectedRoute.baseURL,
                runtime: dashboardRuntime,
                targetID: entryID,
                entry: selectedEntry,
                trust: trust
            )
            libraryOpenFailure = nil
        }
        activeProbeTask = task
        return task
    }

    func dismissLibraryOpenFailure() {
        libraryOpenFailure = nil
    }

    /// Rebuild the active session on an authenticated alternative, unless the user has left it.
    func evaluateAlternateRoutes(entryID: String, failed: URL) async {
        guard let current = dashboardModel,
            current.targetID == entryID,
            RetailRouteComparison.sameRoute(current.route, failed),
            library.entry(id: entryID)?.issue == nil
        else { return }
        let generation = probeGeneration
        let routeGeneration = probes.begin(entryID)
        guard
            let route = await authenticateEntryRoute(
                entryID: entryID,
                excluding: failed,
                probeGeneration: routeGeneration
            ), !Task.isCancelled,
            generation == probeGeneration,
            probes.isCurrent(entryID, generation: routeGeneration),
            dashboardModel === current,
            let entry = library.entry(id: entryID), entry.issue == nil,
            let dashboardRuntime = resolvedRuntime ?? runtime
        else { return }
        let trust = entry.coordinatorNodeID.flatMap {
            nodeTrustReader($0.rawValue.uuidString.lowercased())
        }
        current.stopMonitoring()
        dashboard.publishDashboard(
            route: route.baseURL,
            runtime: dashboardRuntime,
            targetID: entryID,
            entry: entry,
            trust: trust
        )
    }

    func cancelOpeningLibraryEntry() {
        cancelProbe()
    }

    /// Refresh the selected target's signed state before reusing its model preview and lifecycle controller.
    @discardableResult
    func prepareModelManagement(
        entryID: String,
        modelID: String,
        action: ModelLibraryManagementAction
    ) async -> Bool {
        guard let task = openLibraryEntry(entryID) else { return false }
        await task.value
        guard let dashboardModel, dashboardModel.targetID == entryID else { return false }
        return await dashboardModel.prepareLibraryManagement(
            modelID: modelID,
            action: action
        )
    }

    /// Remove only the local library card; do not alter the Spark or its grants.
    func removeLibraryEntry(_ entryID: String) {
        cancelProbe()
        probes.forget(entryID)
        _ = library.remove(entryID: entryID)
    }

    /// Reconcile reachability only after authenticated identity matching, preserving stored identity on refusal.
    @MainActor
    @discardableResult
    func updateFromProbe(entryID: String) async -> Bool {
        await probeEntry(entryID)
    }

    /// Refresh the open dashboard or independently authenticate saved cards before marking them reachable.
    func refreshSavedSparks() async {
        if let dashboardModel {
            await dashboardModel.refresh()
            return
        }
        guard !isRefreshingSavedSparks,
            !isAddingSpark,
            !isChoosingSpark,
            pairingDeviceTarget == nil
        else { return }

        isRefreshingSavedSparks = true
        defer { isRefreshingSavedSparks = false }

        let entryIDs = library.entries
            .filter { $0.issue == nil }
            .map(\.id)
        for entryID in entryIDs {
            guard !Task.isCancelled else { return }
            let startsOffline =
                library.entry(id: entryID)?.connectionState == .offlineCached
            if startsOffline {
                library.markConnecting(entryID: entryID)
            }
            let authenticated = await authenticateEntryWithRecovery(entryID: entryID)
            if !authenticated, startsOffline {
                library.clearConnecting(entryID: entryID)
            }
        }
    }

    /// Cancel the probe and invalidate its generation before another lifecycle action can publish a dashboard.
    func cancelProbe() {
        probeGeneration &+= 1
        activeProbeTask?.cancel()
        activeProbeTask = nil
        openingLibraryEntryID = nil
        libraryOpenFailure = nil
        resolvedRuntime = nil
        // Clear route-bound trust so an invitation cannot combine one Spark's pin with another's address.
        dashboardTrust = nil
        deviceManagementModel = nil
        dashboard.sharedAccessModel = nil
        dashboard.guestExperienceModel = nil
        remoteAccessModel = nil
        networkStatusModel = nil
        settingsModel = nil
        powerControlModel = nil
        identitySettingsModel = nil
        invalidateInvitation()
    }

    /// Treat CancellationError and URLError.cancelled as cancellation rather than transport failure.
    func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return false
    }

    /// True when any local, rediscovered or remote route authenticated the entry; see `authenticateEntryRoute`.
    func authenticateEntryWithRecovery(
        entryID: String,
        initialRoute: CachedRoute? = nil,
        onFailure: (@MainActor (SavedSparkOpenFailure.Reason) -> Void)? = nil
    ) async -> Bool {
        await authenticateEntryRoute(
            entryID: entryID,
            initialRoute: initialRoute,
            onFailure: onFailure
        ) != nil
    }
    /// Check cancellation after every await and before reconciliation so a superseded probe cannot mutate card state.
    @MainActor
    func authenticateProbe(
        entryID: String,
        route: CachedRoute,
        generation: Int,
        onFailure: (@MainActor (SavedSparkOpenFailure.Reason) -> Void)? = nil
    ) async -> Bool {
        guard let entry = library.entry(id: entryID) else { return false }
        guard let expected = entry.coordinatorNodeID else {
            guard !Task.isCancelled else { return false }
            onFailure?(.noRoute)
            markUnreachable(entryID: entryID, generation: generation)
            return false
        }
        if let pin = route.peerFingerprint {
            return await authenticatePinnedProbe(
                entryID: entryID,
                entry: entry,
                route: route,
                expected: expected,
                pin: pin,
                generation: generation,
                onFailure: onFailure
            )
        }
        do {
            let authenticated = try await identityResolver.resolveIdentity(
                route: route.baseURL,
                expectedNodeID: expected
            )
            guard !Task.isCancelled else { return false }
            guard authenticated.nodeID == expected else {
                onFailure?(.identityMismatch)
                markIdentityMismatch(
                    entryID: entryID,
                    generation: generation,
                    presented: authenticated.nodeID
                )
                return false
            }
            if let client = authenticated.client { resolvedRuntime = client }
            markReachable(
                entryID: entryID,
                generation: generation,
                nodeID: expected,
                route: route
            )
            return true
        } catch {
            // No error path may mutate a cancelled probe, regardless of its reported error type.
            if Task.isCancelled || isCancellationError(error) { return false }
            onFailure?(Self.savedSparkOpenFailure(for: error))
            if let authError = error as? AuthenticatedIdentityError {
                switch authError {
                case .nodeMismatch(let presented):
                    markIdentityMismatch(
                        entryID: entryID,
                        generation: generation,
                        presented: presented
                    )
                case .pinRejected:
                    // Attribute authentication or reachability failure to the specific route that was checked.
                    markUnreachable(
                        entryID: entryID,
                        generation: generation,
                        nodeID: expected,
                        route: route
                    )
                case .unbound:
                    // An unconfigured pinned transport provides no evidence that the Spark is unreachable.
                    break
                }
                return false
            }
            markUnreachable(
                entryID: entryID,
                generation: generation,
                nodeID: expected,
                route: route
            )
            return false
        }
    }

    func authenticatePinnedProbe(
        entryID: String,
        entry: LibraryEntry,
        route: CachedRoute,
        expected: SparkNodeID,
        pin: String,
        generation: Int,
        onFailure: (@MainActor (SavedSparkOpenFailure.Reason) -> Void)? = nil
    ) async -> Bool {
        do {
            let signer = try signerProvider(expected.rawValue)
            let client = try SparkAPIClient.pinned(to: pin, signer: signer)
            // Reuse one pinned session for the route probe and subsequent identity read.
            let probe = RouteProbe(pin: pin, using: client)
            let result = await probe.validate(
                route: SparkRoute(
                    nodeID: expected,
                    baseURL: route.baseURL,
                    kind: route.kind,
                    interfaceName: route.interfaceName,
                    validatedIdentityFingerprint: pin
                ),
                expectedNodeID: expected
            )
            guard !Task.isCancelled else { return false }
            switch result {
            case .accepted:
                let identity = try await client.identity(route: route.baseURL)
                guard !Task.isCancelled else { return false }
                guard identity.nodeID == expected else {
                    onFailure?(.identityMismatch)
                    markIdentityMismatch(
                        entryID: entryID,
                        generation: generation,
                        presented: identity.nodeID
                    )
                    return false
                }
                if let authority = entry.member(nodeID: expected)?.authorityFingerprint,
                    identity.authorityFingerprint.lowercased() != authority.lowercased()
                {
                    onFailure?(.identityMismatch)
                    markUnreachable(entryID: entryID, generation: generation)
                    return false
                }
                markReachable(
                    entryID: entryID,
                    generation: generation,
                    nodeID: expected,
                    route: route
                )
                resolvedRuntime = client
                return true
            case .identityMismatch(let presented, _):
                onFailure?(.identityMismatch)
                markIdentityMismatch(
                    entryID: entryID,
                    generation: generation,
                    presented: presented
                )
            case .certificateRejected:
                onFailure?(.certificateRejected)
                markUnreachable(
                    entryID: entryID,
                    generation: generation,
                    nodeID: expected,
                    route: route
                )
            case .protocolUnsupported:
                onFailure?(.protocolMismatch)
                markUnreachable(
                    entryID: entryID,
                    generation: generation,
                    nodeID: expected,
                    route: route
                )
            case .unreachable:
                onFailure?(.unavailable)
                markUnreachable(
                    entryID: entryID,
                    generation: generation,
                    nodeID: expected,
                    route: route
                )
            }
        } catch {
            if Task.isCancelled || isCancellationError(error) { return false }
            onFailure?(Self.savedSparkOpenFailure(for: error))
            markUnreachable(entryID: entryID, generation: generation)
        }
        return false
    }

    private static func savedSparkOpenFailure(for error: any Error) -> SavedSparkOpenFailure.Reason
    {
        if let error = error as? APIError, error.statusCode == 401 || error.statusCode == 403 {
            return .authentication
        }
        if case PinnedTransportError.certificateRejected = error { return .certificateRejected }
        if let error = error as? AuthenticatedIdentityError {
            switch error {
            case .nodeMismatch: return .identityMismatch
            case .unbound: return .secureConnectionUnavailable
            // The legacy pinRejected result also covers unreachable endpoints, so it cannot prove a changed certificate.
            case .pinRejected: return .unavailable
            }
        }
        return .unavailable
    }

}
