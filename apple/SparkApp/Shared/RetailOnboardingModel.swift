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

/// Compose the retail setup workflows while keeping credentials in memory until consumed or explicitly cleared.
@MainActor
@Observable
public final class RetailOnboardingModel {
    private let workflows: RetailOnboardingWorkflows
    private let flow: RetailOnboardingFlowCoordinator

    public var state: RetailOnboardingState { session.state }
    public var isAddingSpark: Bool { session.isAddingSpark }
    public var isChoosingSpark: Bool { session.isChoosingSpark }
    public var setupSSID: String {
        get { connection.setupSSID }
        set { connection.setupSSID = newValue }
    }
    /// Whether ``setupSSID`` is known to be a complete network name.
    @ObservationIgnored
    private var setupSSIDIsExact: Bool {
        get { connection.setupSSIDIsExact }
        set { connection.setupSSIDIsExact = newValue }
    }
    public var setupPassphrase: String {
        get { connection.setupPassphrase }
        set { connection.setupPassphrase = newValue }
    }
    public var machineName: String {
        get { session.machineName }
        set { session.machineName = newValue }
    }
    /// An optional label on this Apple device, never a network address or proof of identity.
    public var setupCustomLabel: String {
        get { session.customLabel }
        set { session.customLabel = String(newValue.prefix(120)) }
    }
    public var setupLabelSaveFailed: Bool {
        get { session.labelSaveFailed }
        set { session.labelSaveFailed = newValue }
    }
    public var setupPage: String {
        get { connection.setupPage }
        set { connection.setupPage = newValue }
    }
    public var administratorUsername: String? {
        get { session.administratorUsername }
        set { session.administratorUsername = newValue }
    }
    public var administratorPassword: String {
        get { session.administratorPassword }
        set { session.administratorPassword = newValue }
    }
    /// The current pre-install survey, or nil when the Spark has not been checked.
    public var hostPreflight: HostPreflight? { provisioner.hostPreflight }
    /// A failed survey read, separate from conflicts reported by a successful survey.
    public var preflightError: String? { provisioner.preflightError }
    public var isCheckingSpark: Bool { provisioner.isCheckingSpark }
    /// Current install refusals replace a stale preflight report without implying that the host changed.
    public var installBlockedBy: [PreflightConflict] { provisioner.installBlockedBy }
    /// The observed setup SSID, offered through useDetectedSetupNetwork().
    public var detectedSetupSSID: String? { connection.detectedSetupSSID }
    public var sparkSetupNetworkStillActive: Bool { connection.sparkSetupNetworkStillActive }
    /// The network actually joined, which is what must later be forgotten.
    @ObservationIgnored
    private var joinedSetupSSID: String? {
        get { connection.joinedSetupSSID }
        set { connection.joinedSetupSSID = newValue }
    }
    /// Why a setup-network join could not be attempted or did not take.
    public var setupJoinDetail: String? { connection.setupJoinDetail }
    public var isShowingQuickStartScanner: Bool {
        get { connection.isShowingQuickStartScanner }
        set { connection.isShowingQuickStartScanner = newValue }
    }
    public var scanErrorMessage: String? {
        get { connection.scanErrorMessage }
        set { connection.scanErrorMessage = newValue }
    }
    /// An installed runtime awaiting device pairing must never enter factory setup.
    public var pairingDeviceTarget: DiscoveredSpark? { pairing.pairingDeviceTarget }
    public var pairingDeviceError: String? { pairing.pairingDeviceError }
    public var isPairingDevice: Bool { pairing.isPairingDevice }
    public var isBatchPairingDevice: Bool { pairing.isBatchPairingDevice }
    public var batchRecipientRequestPayload: String? { pairing.batchRecipientRequestPayload }
    public var batchPairingProgress: BatchPairingProgress? { pairing.batchPairingProgress }
    public var batchPairingError: String? { pairing.batchPairingError }
    @ObservationIgnored
    private var batchPairingCoordinator: BatchAdditionalDevicePairingCoordinator? {
        get { pairing.batchPairingCoordinator }
        set { pairing.batchPairingCoordinator = newValue }
    }
    /// Why pairing failed, in words the owner can act on.
    public var pairingFailureDetail: String? { pairing.pairingFailureDetail }
    /// Why the dashboard could not be opened after pairing succeeded.
    public var dashboardFailureDetail: String? { dashboard.dashboardFailureDetail }
    public var bootstrapTarget: BootstrapSpark? { session.bootstrapTarget }
    public var nativeSetupModel: NativeSparkSetupModel? { connection.nativeSetupModel }
    public var dashboardModel: SparkDashboardModel? { dashboard.dashboardModel }
    public var openingLibraryEntryID: String? { navigator.openingLibraryEntryID }
    public var libraryOpenFailure: SavedSparkOpenFailure? { navigator.libraryOpenFailure }
    /// Expose secret-free provider references; token input is sent once to the pinned runtime and never retained here.
    public var automationsModel: SparkAutomationsModel? {
        dashboard.automationsModel
    }

    public var providerCredentialModel: ProviderCredentialModel? {
        dashboard.providerCredentialModel
    }
    /// Expose device grants only for the exact authenticated dashboard route with paired trust.
    public var deviceManagementModel: DeviceManagementModel? { dashboard.deviceManagementModel }
    public var sharedAccessModel: SharedAccessModel? { dashboard.sharedAccessModel }
    public var guestExperienceModel: GuestExperienceModel? { dashboard.guestExperienceModel }
    /// Remote controls require the dashboard's pinned, signed runtime; placeholders cannot create an unpinned client.
    public var remoteAccessModel: RemoteAccessModel? { dashboard.remoteAccessModel }
    /// Read-only NetworkManager status for the dashboard's pinned runtime.
    public var networkStatusModel: SparkNetworkStatusModel? { dashboard.networkStatusModel }
    /// Appliance settings for the dashboard's exact pinned, signed runtime.
    public var settingsModel: SparkSettingsModel? { dashboard.settingsModel }
    /// Expose host controls only for the owner of an authenticated dashboard.
    public var powerControlModel: SparkPowerControlModel? { dashboard.powerControlModel }
    /// Expose support-bundle controls only to the open Spark's owner or administrator.
    public var diagnosticsExportModel: DiagnosticsExportModel? { dashboard.diagnosticsExportModel }
    /// Allow local labels independently; enable system hostname changes only after the owner role is known.
    public var identitySettingsModel: SparkIdentitySettingsModel? {
        dashboard.identitySettingsModel
    }
    /// Retain the selected Bonjour endpoint and interface as pairing hints, never as authenticated identity.
    public internal(set) var selectedDiscoveryCandidate: DiscoveredSpark? {
        get { session.selectedDiscoveryCandidate }
        set { session.selectedDiscoveryCandidate = newValue }
    }

    /// Persist local Spark cards by stable node or cluster identity.
    public var library: SparkLibrary { workflows.library }
    /// Pairing establishes the node trust and TLS pin used for its dashboard.
    public var pairedNode: NodeTrust? { session.pairedNode }
    /// Reuse the route that successfully claimed pairing instead of reconstructing an address.
    public var pairedRouteURL: URL? { session.pairedRouteURL }

    public var localDiscovery: SparkDiscoveryService { workflows.localDiscovery }
    public var bootstrapDiscovery: BootstrapDiscoveryService { workflows.bootstrapDiscovery }
    public var handoffMonitor: NetworkHandoffMonitor { workflows.handoffMonitor }

    private var networkJoiner: any SetupNetworkJoining { workflows.networkJoiner }
    private var currentWiFiReader: any CurrentWiFiNetworkReading { workflows.currentWiFiReader }
    private var runtimeInstaller: any RuntimeBootstrapInstalling { workflows.runtimeInstaller }
    private var session: RetailSetupSession { workflows.session }
    private var connection: RetailSetupConnection { workflows.connection }
    private var provisioner: RetailRuntimeProvisioner { workflows.provisioner }
    private var pairing: RetailPairingWorkflow { workflows.pairing }
    private var dashboard: RetailDashboardSession { workflows.dashboard }
    private var navigator: RetailLibraryNavigator { workflows.navigator }
    private var invitations: RetailInvitationWorkflow { workflows.invitations }
    private var ai: RetailAIServicePreparation { workflows.ai }

    public typealias SignerProvider = @MainActor (UUID) throws -> any RequestSigning

    private var signerProvider: SignerProvider { workflows.signerProvider }
    private var settingsUserPresenceAuthorizer: any UserPresenceAuthorizing {
        workflows.settingsUserPresenceAuthorizer
    }
    private var pairingService: (any FirstOwnerPairingServicing)? { workflows.pairingService }
    private var additionalDevicePairingService: (any AdditionalDevicePairingServicing)? {
        workflows.additionalDevicePairingService
    }
    private var pairingJoinCodeRedeemer: any PairingJoinCodeRedeeming {
        workflows.pairingJoinCodeRedeemer
    }
    /// Keep the install result only between installation and pairing, then clear it with the credential.
    @ObservationIgnored
    private var bootstrapResult: RuntimeBootstrapResult? {
        get { session.bootstrapResult }
        set { session.bootstrapResult = newValue }
    }
    private var oobeServiceFactory: SparkOOBEServiceFactory { workflows.oobeServiceFactory }
    private var onReady: @MainActor () -> Void { workflows.onReady }
    @ObservationIgnored
    private var isDetectingExistingConnection: Bool {
        get { connection.isDetectingExistingConnection }
        set { connection.isDetectingExistingConnection = newValue }
    }
    @ObservationIgnored
    private var isPairing: Bool {
        get { pairing.isPairing }
        set { pairing.isPairing = newValue }
    }
    /// An expired first-owner invitation requires a fresh invitation from the signed installer.
    @ObservationIgnored
    private var pairingNeedsRuntimeReinstall: Bool {
        get { pairing.pairingNeedsRuntimeReinstall }
        set { pairing.pairingNeedsRuntimeReinstall = newValue }
    }
    @ObservationIgnored
    private var oobeService: (any SparkOOBEServicing)? {
        get { connection.oobeService }
        set { connection.oobeService = newValue }
    }
    private var identityResolver: any AuthenticatedIdentityResolving { workflows.identityResolver }
    private var savedRouteDiscovery: any SavedSparkRouteDiscovering {
        workflows.savedRouteDiscovery
    }
    private var runtime: (any SparkRuntimeReading)? { workflows.runtime }
    private var now: @Sendable () -> Date { workflows.now }
    @ObservationIgnored
    private var activeProbeTask: Task<Void, Never>? {
        get { navigator.activeProbeTask }
        set { navigator.activeProbeTask = newValue }
    }
    @ObservationIgnored
    private var isRefreshingSavedSparks: Bool {
        get { navigator.isRefreshingSavedSparks }
        set { navigator.isRefreshingSavedSparks = newValue }
    }
    @ObservationIgnored
    private var resolvedRuntime: (any SparkRuntimeReading)? {
        get { dashboard.resolvedRuntime }
        set { dashboard.resolvedRuntime = newValue }
    }
    /// Invalidate the probe generation on every lifecycle change that supersedes dashboard publication.
    @ObservationIgnored
    private var probeGeneration: Int {
        get { navigator.probeGeneration }
        set { navigator.probeGeneration = newValue }
    }
    /// Bound post-handoff rediscovery so a missing Spark becomes a recoverable failure.
    private var rediscoveryTimeout: Duration { workflows.rediscoveryTimeout }
    private var sleep: @Sendable (Duration) async throws -> Void { workflows.sleep }
    /// Expose the bounded search task internally so tests can await completion.
    @ObservationIgnored
    var rediscoveryTimeoutTask: Task<Void, Never>? { connection.rediscoveryTimeoutTask }
    /// When the post-setup search began, for the elapsed clock on the waiting screen.
    public var rediscoveryStartedAt: Date? { connection.rediscoveryStartedAt }
    public var rediscoveryLimit: Duration { rediscoveryTimeout }
    public func lookAgainForSpark() { connection.lookAgainForSpark() }
    /// When the post-NVIDIA restart wait began, for the countdown and clock on the waiting screen.
    public var restartStartedAt: Date? { provisioner.restartStartedAt }
    public var restartHold: Duration { provisioner.restartHold }
    public var restartLimit: Duration { provisioner.restartLimit }
    public var isCheckingRestart: Bool { provisioner.isCheckingRestart }
    public var restartCheckDetail: String? { provisioner.restartCheckDetail }
    public var restartStage: RetailRestartStage { provisioner.restartStage }
    /// Hold for the restart, then check until the Spark answers; the screen's task drives this.
    public func awaitSparkRestart() async { await provisioner.awaitSparkRestart() }
    /// The owner says the Spark is back: check once now.
    public func checkSparkIsBack() async { await provisioner.checkSparkIsBack() }
    /// The host whose SSH identity changed, when that is what stopped the last check or install.
    public var changedHostKeyHost: String? { provisioner.changedHostKeyHost }
    /// The owner confirms the Spark was reset: forget the old key and carry on from where it stopped.
    public func trustNewHostKey(preparation: RetailOnboardingPreparationModel? = nil) async {
        await flow.trustNewHostKey(preparation: preparation)
    }
    @ObservationIgnored
    private var rediscoveryGeneration: Int {
        get { connection.rediscoveryGeneration }
        set { connection.rediscoveryGeneration = newValue }
    }
    /// Offer automatic setup-network continuation only once so Back remains effective.
    @ObservationIgnored
    private var hasOfferedDetectedNetwork: Bool {
        get { connection.hasOfferedDetectedNetwork }
        set { connection.hasOfferedDetectedNetwork = newValue }
    }
    private var nodeTrustReader: @Sendable (String) -> NodeTrust? { workflows.nodeTrustReader }
    private var localDeviceIDProvider: @MainActor () -> String? { workflows.localDeviceIDProvider }
    /// Use the open dashboard's recorded trust when inviting another Apple device.
    public var dashboardTrust: NodeTrust? { dashboard.dashboardTrust }
    /// The in-progress invitation for another Apple device, if any.
    public var invitation: DeviceInvitationModel? { invitations.invitation }
    public var isBatchInvitingDevice: Bool { invitations.isBatchInvitingDevice }
    public var batchInvitationProgress: BatchInvitationProgress? {
        invitations.batchInvitationProgress
    }
    public var batchInvitationPayload: String? { invitations.batchInvitationPayload }
    public var batchInvitationError: String? { invitations.batchInvitationError }
    public var isCreatingBatchInvitation: Bool { invitations.isCreatingBatchInvitation }
    @ObservationIgnored
    private var batchInvitationCoordinator: BatchDeviceInvitationCoordinator? {
        get { invitations.batchInvitationCoordinator }
        set { invitations.batchInvitationCoordinator = newValue }
    }
    public var batchInvitationSources: [BatchInvitationSource] {
        invitations.batchInvitationSources
    }

    public convenience init(
        networkJoiner: any SetupNetworkJoining = SystemSetupNetworkJoiner(),
        currentWiFiReader: any CurrentWiFiNetworkReading = SystemCurrentWiFiNetworkReader(),
        runtimeInstaller: any RuntimeBootstrapInstalling = PendingRuntimeBootstrapInstaller(),
        oobeServiceFactory: @escaping SparkOOBEServiceFactory = { SparkOOBEClient(baseURL: $0) },
        localDiscovery: SparkDiscoveryService = SparkDiscoveryService(),
        bootstrapDiscovery: BootstrapDiscoveryService = BootstrapDiscoveryService(),
        handoffMonitor: NetworkHandoffMonitor = NetworkHandoffMonitor(),
        library: SparkLibrary = SparkLibrary.appLibrary(),
        identityResolver: (any AuthenticatedIdentityResolving)? = nil,
        runtime: any SparkRuntimeReading = PendingSparkRuntimeReader(),
        onReady: @escaping @MainActor () -> Void = {}
    ) {
        self.init(
            networkJoiner: networkJoiner,
            currentWiFiReader: currentWiFiReader,
            runtimeInstaller: runtimeInstaller,
            oobeServiceFactory: oobeServiceFactory,
            localDiscovery: localDiscovery,
            bootstrapDiscovery: bootstrapDiscovery,
            handoffMonitor: handoffMonitor,
            library: library,
            identityResolver: identityResolver,
            runtime: runtime,
            signerProvider: { try DeviceIdentityStore.loadOrCreateSigner(nodeID: $0) },
            now: Date.init,
            onReady: onReady
        )
    }

    public init(
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
        signerProvider: @escaping SignerProvider = { nodeID in
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
        let workflows = RetailOnboardingWorkflows(
            networkJoiner: networkJoiner,
            currentWiFiReader: currentWiFiReader,
            runtimeInstaller: runtimeInstaller,
            hostKeyStore: hostKeyStore,
            sshReachability: sshReachability,
            pairingService: pairingService,
            additionalDevicePairingService: additionalDevicePairingService,
            pairingJoinCodeRedeemer: pairingJoinCodeRedeemer,
            oobeServiceFactory: oobeServiceFactory,
            localDiscovery: localDiscovery,
            bootstrapDiscovery: bootstrapDiscovery,
            handoffMonitor: handoffMonitor,
            library: library,
            identityResolver: identityResolver,
            savedRouteDiscovery: savedRouteDiscovery,
            runtime: runtime,
            signerProvider: signerProvider,
            settingsUserPresenceAuthorizer: settingsUserPresenceAuthorizer,
            nodeTrustReader: nodeTrustReader,
            localDeviceIDProvider: localDeviceIDProvider,
            rediscoveryTimeout: rediscoveryTimeout,
            restartHold: restartHold,
            restartLimit: restartLimit,
            restartProbeInterval: restartProbeInterval,
            handoffPollInterval: handoffPollInterval,
            sleep: sleep,
            now: now,
            onReady: onReady
        )
        self.workflows = workflows
        let flow = RetailOnboardingFlowCoordinator(workflows: workflows)
        self.flow = flow
        workflows.connection.resetSetup = { [weak flow] in flow?.resetSetup() }
        workflows.connection.performPrimaryAction = { [weak flow] in
            await flow?.performPrimaryAction()
        }
        workflows.pairing.cancelProbe = { [weak navigator = workflows.navigator] in
            navigator?.cancelProbe()
        }
        workflows.pairing.completePairedSetup = { [weak flow] route, trust in
            flow?.completePairedSetup(route: route, trust: trust)
        }
    }
    public var canJoinSetupNetwork: Bool { connection.canJoinSetupNetwork }
    public var canScanQuickStartCode: Bool { connection.canScanQuickStartCode }
    public var nvidiaSetupURL: URL? { connection.nvidiaSetupURL }
    public func startAddingSpark() { flow.startAddingSpark() }
    public func chooseSparkToAdd() { flow.chooseSparkToAdd() }
    public func cancelChoosingSpark() { flow.cancelChoosingSpark() }
    public func chooseNearbySpark(_ discovered: DiscoveredSpark) {
        flow.chooseNearbySpark(discovered)
    }
    @discardableResult
    public func chooseExistingSpark(host rawHost: String) -> Bool {
        return flow.chooseExistingSpark(host: rawHost)
    }
    public func cancelPairingDevice() { pairing.cancelPairingDevice() }
    public func beginBatchPairingDevice() { pairing.beginBatchPairingDevice() }
    public func pairSeveralSparks(payload: String) async {
        await pairing.pairSeveralSparks(payload: payload)
    }
    public func retryBatchPairing(nodeID: String) async {
        await pairing.retryBatchPairing(nodeID: nodeID)
    }
    public func cancelBatchPairingDevice() { pairing.cancelBatchPairingDevice() }
    public func finishInterruptedFirstOwnerSetup() { pairing.finishInterruptedFirstOwnerSetup() }
    public func pairThisDevice(payload: String) async {
        await pairing.pairThisDevice(payload: payload)
    }
    public func pairThisDevice(joinCode rawCode: String, trustedFingerprint: String? = nil) async {
        await pairing.pairThisDevice(joinCode: rawCode, trustedFingerprint: trustedFingerprint)
    }
    public func chooseBootstrapSpark(_ target: BootstrapSpark) { flow.chooseBootstrapSpark(target) }

    public func startAddingSpark(prefillHost: String) {
        flow.startAddingSpark(prefillHost: prefillHost)
    }
    public func cancelAddingSpark() { flow.cancelAddingSpark() }
    public func performPrimaryAction(
        preparation: RetailOnboardingPreparationModel? = nil
    ) async { await flow.performPrimaryAction(preparation: preparation) }
    public func performSecondaryAction(
        preparation: RetailOnboardingPreparationModel? = nil
    ) { flow.performSecondaryAction(preparation: preparation) }
    public func ownerFinishedNVIDIASetupOnTheSpark() {
        connection.ownerFinishedNVIDIASetupOnTheSpark()
    }
    public func detectExistingSparkConnection() async {
        await connection.detectExistingSparkConnection()
    }
    public func useDetectedSetupNetwork() { connection.useDetectedSetupNetwork() }
    public func applyQuickStartCode(_ payload: String) throws {
        try connection.applyQuickStartCode(payload)
    }
    public func quickStartCodeScanned(_ payload: String) {
        connection.quickStartCodeScanned(payload)
    }
    public func nativeSetupWiFiSubmitted() { connection.nativeSetupWiFiSubmitted() }
    public func connectionCelebrationFinished() { connection.connectionCelebrationFinished() }
    public func networkHandoffChanged(_ handoff: NetworkHandoffState) async {
        await connection.networkHandoffChanged(handoff)
    }
    public func retrySparkWiFi() { connection.retrySparkWiFi() }
    public func bootstrapCandidatesChanged(_ candidates: [BootstrapSpark]) async {
        await connection.bootstrapCandidatesChanged(candidates)
    }
    public func retry(preparation: RetailOnboardingPreparationModel? = nil) {
        flow.retry(preparation: preparation)
    }
    public func goBack() { flow.goBack() }
    public func checkExistingSpark() async { await provisioner.checkExistingSpark() }
    public var needsExistingSparkReview: Bool { provisioner.needsExistingSparkReview }
    var existingSparkReport: ExistingSparkPreflightPresentation? { provisioner.existingSparkReport }
    public func clearExistingSparkCheck() { provisioner.clearExistingSparkCheck() }
    public func pairFirstOwner() async { await pairing.pairFirstOwner() }

    var setupVoiceTarget: SparkVoiceTarget? {
        guard let trust = pairedNode, let route = pairedRouteURL,
            let uuid = UUID(uuidString: trust.nodeID)
        else { return nil }
        return SparkVoiceTarget(
            id: trust.nodeID,
            displayName: trust.nodeName,
            nodeID: SparkNodeID(rawValue: uuid),
            clusterID: nil,
            route: route,
            tlsFingerprint: trust.tlsFingerprint,
            authorityFingerprint: trust.authorityFingerprint
        )
    }
    public func checkAIServices(
        preparation: RetailOnboardingPreparationModel? = nil
    ) async { await ai.checkAIServices(preparation: preparation) }
    static func needsRuntimeReinstall(after error: any Error) -> Bool {
        return RetailOnboardingFailurePresentation.needsRuntimeReinstall(after: error)
    }
    static func shouldRetainAdministratorPassword(after error: any Error) -> Bool {
        return RetailOnboardingFailurePresentation.shouldRetainAdministratorPassword(after: error)
    }

    public var retryActionTitle: String? {
        guard state.issue == .pairingFailed, pairingNeedsRuntimeReinstall else { return nil }
        return String(localized: "Install Again")
    }
    func completeSetup() async { await flow.completeSetup() }
    @discardableResult
    public func recordCompletedSetup(
        route: URL,
        authenticated: AuthenticatedIdentity
    ) -> ReconciliationOutcome? {
        return flow.recordCompletedSetup(route: route, authenticated: authenticated)
    }
    public func closeDashboard() { flow.closeDashboard() }
    @discardableResult
    public func openLibraryEntry(_ entryID: String) -> Task<Void, Never>? {
        return navigator.openLibraryEntry(entryID)
    }
    public func dismissLibraryOpenFailure() { navigator.dismissLibraryOpenFailure() }
    public func cancelOpeningLibraryEntry() { navigator.cancelOpeningLibraryEntry() }
    @discardableResult
    public func prepareModelManagement(
        entryID: String,
        modelID: String,
        action: ModelLibraryManagementAction
    ) async -> Bool {
        return await navigator.prepareModelManagement(
            entryID: entryID,
            modelID: modelID,
            action: action
        )
    }
    public func removeLibraryEntry(_ entryID: String) { navigator.removeLibraryEntry(entryID) }
    @discardableResult
    public func updateFromProbe(entryID: String) async -> Bool {
        return await navigator.updateFromProbe(entryID: entryID)
    }
    public func refreshSavedSparks() async { await navigator.refreshSavedSparks() }
    @discardableResult
    public func handleDiscovered(_ discovered: DiscoveredSpark) -> Task<Void, Never>? {
        return flow.handleDiscovered(discovered)
    }
    public func shouldPresentDiscoveryAddSheet(probe: Task<Void, Never>?) -> Bool {
        return flow.shouldPresentDiscoveryAddSheet(probe: probe)
    }
    public func beginInvitingDevice() { invitations.beginInvitingDevice() }
    public func cancelInvitingDevice() { invitations.cancelInvitingDevice() }
    public func beginInvitingDeviceToSeveralSparks() {
        invitations.beginInvitingDeviceToSeveralSparks()
    }
    public func createBatchInvitation(
        recipientRequestPayload: String,
        selectedNodeIDs: Set<String>,
        role: InvitedDeviceRole
    ) async {
        await invitations.createBatchInvitation(
            recipientRequestPayload: recipientRequestPayload,
            selectedNodeIDs: selectedNodeIDs,
            role: role
        )
    }
    public func retryBatchInvitation(nodeID: String) async {
        await invitations.retryBatchInvitation(nodeID: nodeID)
    }
    public func revokeBatchInvitationGrants() async {
        await invitations.revokeBatchInvitationGrants()
    }
    public func cancelBatchInvitation() { invitations.cancelBatchInvitation() }
    public var canInviteDevice: Bool { invitations.canInviteDevice }
    public var canInviteDeviceToSeveralSparks: Bool { invitations.canInviteDeviceToSeveralSparks }
    public var canManageDevices: Bool { invitations.canManageDevices }
    public func retryLibraryStorage() { flow.retryLibraryStorage() }

    /// Present the specific failure detail gathered beyond the issue's standard recovery copy.
    public var failureDetail: String? {
        switch state.issue {
        case .deviceKeyUnavailable: return dashboardFailureDetail
        case .pairingFailed: return pairingFailureDetail
        case .setupHotspotUnavailable, .setupNetworkJoinDenied: return setupJoinDetail
        case .runtimeInstallFailed: return preflightError
        case .sparkNotBackAfterRestart: return restartCheckDetail
        default: return nil
        }
    }

}
