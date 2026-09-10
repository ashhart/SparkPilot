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
final class RetailSetupCompletion {
    private let workflows: RetailOnboardingWorkflows
    init(workflows: RetailOnboardingWorkflows) { self.workflows = workflows }
    private var session: RetailSetupSession { workflows.session }
    private var connection: RetailSetupConnection { workflows.connection }
    private var provisioner: RetailRuntimeProvisioner { workflows.provisioner }
    private var pairing: RetailPairingWorkflow { workflows.pairing }
    private var dashboard: RetailDashboardSession { workflows.dashboard }
    private var invitations: RetailInvitationWorkflow { workflows.invitations }

    /// Reconcile and open a card only after authenticated identity or completed pairing establishes trust.
    func completeSetup() async {
        if let trust = session.pairedNode, let route = session.pairedRouteURL {
            completePairedSetup(route: route, trust: trust)
            return
        }
        guard let route = buildRoute() else { return }
        do {
            let authenticated = try await workflows.identityResolver.resolveIdentity(
                route: route,
                expectedNodeID: nil
            )
            recordCompletedSetup(route: route, authenticated: authenticated)
        } catch {
            // Leave setup actionable after authentication fails; never create a card from unverified metadata.
            session.send(.failed(.identityUnavailable))
        }
    }

    /// Persist the authenticated pairing route, certificate, node and authority, then reuse the pinned client.
    func completePairedSetup(route: URL, trust: NodeTrust) {
        do {
            guard let uuid = UUID(uuidString: trust.nodeID) else {
                session.send(.failed(.identityUnavailable))
                return
            }
            let signer = try workflows.signerProvider(uuid)
            let client = try SparkAPIClient.pinned(to: trust.tlsFingerprint, signer: signer)
            let reachedAt = workflows.now()
            let nodeID = SparkNodeID(rawValue: uuid)
            let target = AuthenticatedTarget(
                nodeID: nodeID,
                clusterID: nil,
                name: trust.nodeName,
                role: .standalone,
                authorityFingerprint: trust.authorityFingerprint,
                displayName: session.machineName,
                routes: [
                    CachedRoute(
                        baseURL: route,
                        kind: .localWiFi,
                        peerFingerprint: trust.tlsFingerprint,
                        lastSuccess: reachedAt
                    )
                ],
                reachedAt: reachedAt
            )
            let outcome = SparkIntentEntityReconciler.reconcile(target, into: workflows.library)
            applySetupLabel(to: outcome.entry.id)
            let dashboardRoute = outcome.entry.preferredRoute?.baseURL ?? route
            dashboard.resolvedRuntime = client
            dashboard.publishDashboard(
                route: dashboardRoute,
                runtime: client,
                targetID: outcome.entry.id,
                entry: workflows.library.entry(id: outcome.entry.id) ?? outcome.entry,
                trust: trust
            )
            session.isAddingSpark = false
        } catch {
            dashboard.dashboardFailureDetail =
                String(
                    localized: """
                        This device's signing key could not be opened, so it cannot \
                        talk to your Spark. Restart the app; if it happens again, pair \
                        this device again.
                        """
                )
            session.send(.failed(.deviceKeyUnavailable))
        }
    }

    /// Create or reconcile a card from transport-authenticated identity without removing existing entries.
    @discardableResult
    func recordCompletedSetup(
        route: URL,
        authenticated: AuthenticatedIdentity
    ) -> ReconciliationOutcome? {
        let identity = authenticated.identity
        let reachedAt = workflows.now()
        let target = AuthenticatedTarget(
            nodeID: identity.nodeID,
            clusterID: identity.clusterID,
            name: identity.name,
            role: SparkNodeRole(rawValue: identity.role) ?? .standalone,
            authorityFingerprint: identity.authorityFingerprint,
            displayName: session.machineName,
            routes: [CachedRoute(baseURL: route, kind: .localWiFi, lastSuccess: reachedAt)],
            reachedAt: reachedAt
        )
        let outcome = SparkIntentEntityReconciler.reconcile(target, into: workflows.library)
        applySetupLabel(to: outcome.entry.id)
        dashboard.prepareDashboard(
            route: outcome.entry.preferredRoute?.baseURL ?? route,
            entry: workflows.library.entry(id: outcome.entry.id) ?? outcome.entry
        )
        return ReconciliationOutcome(
            entry: workflows.library.entry(id: outcome.entry.id) ?? outcome.entry,
            effect: outcome.effect,
            library: workflows.library.entries
        )
    }

    private func applySetupLabel(to entryID: String) {
        let label = session.customLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        // Skipping this optional field must preserve an existing owner's label.
        guard !label.isEmpty, workflows.library.entry(id: entryID)?.issue == nil else { return }
        session.labelSaveFailed = !workflows.library.setCustomLabel(label, for: entryID)
    }

    /// Cancel and invalidate pending probes before dismissing the dashboard so late authentication cannot reopen it.
    func closeDashboard() {
        workflows.navigator.cancelProbe()
        dashboard.resolvedRuntime = nil
        dashboard.dashboardModel?.stopMonitoring()
        dashboard.dashboardModel = nil
        dashboard.providerCredentialModel = nil
        dashboard.automationsModel = nil
        dashboard.deviceManagementModel = nil
        dashboard.remoteAccessModel = nil
        dashboard.diagnosticsExportModel = nil
        dashboard.networkStatusModel = nil
        dashboard.settingsModel = nil
        dashboard.powerControlModel = nil
        dashboard.identitySettingsModel = nil
        dashboard.dashboardTrust = nil
        invitations.invitation = nil
        session.isAddingSpark = false
    }

    func resetSetup() {
        provisioner.clearExistingSparkCheck()
        provisioner.cancelRestartWait()
        connection.cancelRediscoveryTimeout()
        connection.cancelHandoffPolling()
        workflows.bootstrapDiscovery.stop()
        workflows.handoffMonitor.stop()
        session.state = RetailOnboardingState()
        workflows.localDiscovery.stop()
        session.isChoosingSpark = false
        connection.setupSSID = ""
        connection.setupSSIDIsExact = false
        connection.detectedSetupSSID = nil
        connection.joinedSetupSSID = nil
        connection.hasOfferedDetectedNetwork = false
        connection.setupJoinDetail = nil
        dashboard.dashboardTrust = nil
        dashboard.deviceManagementModel = nil
        dashboard.providerCredentialModel = nil
        dashboard.automationsModel = nil
        dashboard.remoteAccessModel = nil
        dashboard.networkStatusModel = nil
        dashboard.settingsModel = nil
        dashboard.powerControlModel = nil
        dashboard.identitySettingsModel = nil
        invitations.invitation = nil
        connection.setupPassphrase = ""
        session.machineName = ""
        session.customLabel = ""
        session.labelSaveFailed = false
        connection.setupPage = ""
        session.administratorUsername = nil
        session.administratorPassword = ""
        connection.scanErrorMessage = nil
        connection.isShowingQuickStartScanner = false
        session.bootstrapTarget = nil
        connection.nativeSetupModel = nil
        dashboard.dashboardModel?.stopMonitoring()
        dashboard.dashboardModel = nil
        session.selectedDiscoveryCandidate = nil
        pairing.pairingDeviceTarget = nil
        pairing.pairingDeviceError = nil
        pairing.isPairingDevice = false
        pairing.isBatchPairingDevice = false
        pairing.batchRecipientRequestPayload = nil
        pairing.batchPairingProgress = nil
        pairing.batchPairingError = nil
        pairing.batchPairingCoordinator = nil
        invitations.isBatchInvitingDevice = false
        invitations.batchInvitationProgress = nil
        invitations.batchInvitationPayload = nil
        invitations.batchInvitationError = nil
        invitations.batchInvitationCoordinator = nil
        invitations.isCreatingBatchInvitation = false
        session.pairedNode = nil
        session.pairedRouteURL = nil
        dashboard.dashboardFailureDetail = nil
        dashboard.resolvedRuntime = nil
        connection.oobeService = nil
        session.bootstrapResult = nil
        session.pairedNode = nil
        pairing.pairingFailureDetail = nil
    }

    func buildRoute() -> URL? {
        let host = connection.normalisedMachineName
        guard !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "\(host).local"
        components.port = 7443
        return components.url
    }
}
