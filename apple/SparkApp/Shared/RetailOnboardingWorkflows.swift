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
final class RetailOnboardingWorkflows {
    let library: SparkLibrary
    let localDiscovery: SparkDiscoveryService
    let bootstrapDiscovery: BootstrapDiscoveryService
    let handoffMonitor: NetworkHandoffMonitor
    let networkJoiner: any SetupNetworkJoining
    let currentWiFiReader: any CurrentWiFiNetworkReading
    let runtimeInstaller: any RuntimeBootstrapInstalling
    let session: RetailSetupSession
    let connection: RetailSetupConnection
    let provisioner: RetailRuntimeProvisioner
    let pairing: RetailPairingWorkflow
    let dashboard: RetailDashboardSession
    let navigator: RetailLibraryNavigator
    let invitations: RetailInvitationWorkflow
    let ai: RetailAIServicePreparation
    let signerProvider: RetailOnboardingModel.SignerProvider
    let settingsUserPresenceAuthorizer: any UserPresenceAuthorizing
    let pairingService: (any FirstOwnerPairingServicing)?
    let additionalDevicePairingService: (any AdditionalDevicePairingServicing)?
    let pairingJoinCodeRedeemer: any PairingJoinCodeRedeeming
    let oobeServiceFactory: SparkOOBEServiceFactory
    let onReady: @MainActor () -> Void
    let identityResolver: any AuthenticatedIdentityResolving
    let savedRouteDiscovery: any SavedSparkRouteDiscovering
    let runtime: (any SparkRuntimeReading)?
    let now: @Sendable () -> Date
    let rediscoveryTimeout: Duration
    let sleep: @Sendable (Duration) async throws -> Void
    let nodeTrustReader: @Sendable (String) -> NodeTrust?
    let localDeviceIDProvider: @MainActor () -> String?

    init(
        networkJoiner: any SetupNetworkJoining = SystemSetupNetworkJoiner(),
        currentWiFiReader: any CurrentWiFiNetworkReading = SystemCurrentWiFiNetworkReader(),
        runtimeInstaller: any RuntimeBootstrapInstalling = PendingRuntimeBootstrapInstaller(),
        hostKeyStore: any HostKeyStore = InMemoryHostKeyStore(),
        sshReachability: @escaping @Sendable (BootstrapSpark) async -> Bool = SparkSSHReachability
            .isListening,
        pairingService: (any FirstOwnerPairingServicing)? = nil,
        additionalDevicePairingService: (any AdditionalDevicePairingServicing)? = nil,
        pairingJoinCodeRedeemer: any PairingJoinCodeRedeeming = HTTPSPairingJoinCodeRedeemer(),
        oobeServiceFactory: @escaping SparkOOBEServiceFactory = { SparkOOBEClient(baseURL: $0) },
        localDiscovery: SparkDiscoveryService = SparkDiscoveryService(),
        bootstrapDiscovery: BootstrapDiscoveryService = BootstrapDiscoveryService(),
        handoffMonitor: NetworkHandoffMonitor = NetworkHandoffMonitor(),
        library: SparkLibrary = SparkLibrary.appLibrary(),
        identityResolver: (any AuthenticatedIdentityResolving)? = nil,
        savedRouteDiscovery: (any SavedSparkRouteDiscovering)? = nil,
        runtime: (any SparkRuntimeReading)? = nil,
        signerProvider: @escaping RetailOnboardingModel.SignerProvider = { nodeID in
            try DeviceIdentityStore.loadOrCreateSigner(nodeID: nodeID)
        },
        settingsUserPresenceAuthorizer: any UserPresenceAuthorizing =
            SystemUserPresenceAuthorizer(),
        nodeTrustReader: @escaping @Sendable (String) -> NodeTrust? = StoredNodeTrust.reader,
        localDeviceIDProvider: @escaping @MainActor () -> String? = {
            DeviceIdentityStore.loadOrCreateDeviceID().uuidString.lowercased()
        },
        rediscoveryTimeout: Duration = .seconds(600),
        restartHold: Duration = .seconds(120),
        restartLimit: Duration = .seconds(600),
        restartProbeInterval: Duration = .seconds(5),
        handoffPollInterval: Duration = .seconds(3),
        sleep: @escaping @Sendable (Duration) async throws -> Void = RetailOnboardingClock.sleep,
        now: @escaping @Sendable () -> Date = Date.init,
        onReady: @escaping @MainActor () -> Void = {}
    ) {
        self.nodeTrustReader = nodeTrustReader
        self.localDeviceIDProvider = localDeviceIDProvider
        self.rediscoveryTimeout = rediscoveryTimeout
        self.sleep = sleep
        self.networkJoiner = networkJoiner
        self.currentWiFiReader = currentWiFiReader
        self.runtimeInstaller = runtimeInstaller
        self.signerProvider = signerProvider
        self.settingsUserPresenceAuthorizer = settingsUserPresenceAuthorizer
        self.pairingService = pairingService
        self.additionalDevicePairingService = additionalDevicePairingService
        self.pairingJoinCodeRedeemer = pairingJoinCodeRedeemer
        self.oobeServiceFactory = oobeServiceFactory
        self.localDiscovery = localDiscovery
        self.bootstrapDiscovery = bootstrapDiscovery
        self.handoffMonitor = handoffMonitor
        self.library = library
        self.identityResolver =
            identityResolver
            ?? PairedIdentityResolver(
                nodeTrustReader: nodeTrustReader,
                signerProvider: signerProvider
            )
        self.savedRouteDiscovery =
            savedRouteDiscovery
            ?? BonjourSavedSparkRouteDiscovery(discovery: BootstrapDiscoveryService())
        self.runtime = runtime
        self.now = now
        self.onReady = onReady
        let session = RetailSetupSession()
        let connection = RetailSetupConnection(
            session: session,
            networkJoiner: networkJoiner,
            currentWiFiReader: currentWiFiReader,
            localDiscovery: localDiscovery,
            bootstrapDiscovery: bootstrapDiscovery,
            handoffMonitor: handoffMonitor,
            rediscoveryTimeout: rediscoveryTimeout,
            handoffPollInterval: handoffPollInterval,
            sleep: sleep,
            oobeServiceFactory: oobeServiceFactory
        )
        let provisioner = RetailRuntimeProvisioner(
            session: session,
            runtimeInstaller: runtimeInstaller,
            hostKeyStore: hostKeyStore,
            reachability: sshReachability,
            restartHold: restartHold,
            restartLimit: restartLimit,
            restartProbeInterval: restartProbeInterval,
            sleep: sleep,
            now: now
        )
        let dashboard = RetailDashboardSession(
            session: session,
            runtime: runtime,
            runtimeInstaller: runtimeInstaller,
            signerProvider: signerProvider,
            settingsUserPresenceAuthorizer: settingsUserPresenceAuthorizer,
            library: library,
            nodeTrustReader: nodeTrustReader,
            localDeviceIDProvider: localDeviceIDProvider,
            savedRouteDiscovery: self.savedRouteDiscovery,
            identityResolver: self.identityResolver,
            now: now
        )
        let pairing = RetailPairingWorkflow(
            connection: connection,
            session: session,
            pairingService: pairingService,
            additionalDevicePairingService: additionalDevicePairingService,
            pairingJoinCodeRedeemer: pairingJoinCodeRedeemer,
            localDiscovery: localDiscovery,
            library: library,
            now: now
        )
        let invitations = RetailInvitationWorkflow(
            dashboard: dashboard,
            library: library,
            runtime: runtime,
            nodeTrustReader: nodeTrustReader,
            additionalDevicePairingService: additionalDevicePairingService,
            signerProvider: signerProvider,
            settingsUserPresenceAuthorizer: settingsUserPresenceAuthorizer,
            now: now
        )
        let navigator = RetailLibraryNavigator(
            dashboard: dashboard,
            pairing: pairing,
            session: session,
            runtime: runtime,
            library: library,
            signerProvider: signerProvider,
            nodeTrustReader: nodeTrustReader,
            identityResolver: self.identityResolver,
            savedRouteDiscovery: self.savedRouteDiscovery,
            now: now
        )
        let ai = RetailAIServicePreparation(
            dashboard: dashboard,
            session: session,
            runtime: runtime,
            signerProvider: signerProvider
        )
        self.session = session
        self.connection = connection
        self.provisioner = provisioner
        self.dashboard = dashboard
        self.pairing = pairing
        self.invitations = invitations
        self.navigator = navigator
        self.ai = ai
        navigator.invalidateInvitation = { [weak invitations] in invitations?.invitation = nil }
        library.load()
    }
}
