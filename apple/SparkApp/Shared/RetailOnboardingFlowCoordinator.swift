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
final class RetailOnboardingFlowCoordinator {
    private var completion: RetailSetupCompletion { RetailSetupCompletion(workflows: workflows) }
    private let workflows: RetailOnboardingWorkflows
    init(workflows: RetailOnboardingWorkflows) { self.workflows = workflows }
    private var library: SparkLibrary { workflows.library }
    private var localDiscovery: SparkDiscoveryService { workflows.localDiscovery }
    private var bootstrapDiscovery: BootstrapDiscoveryService { workflows.bootstrapDiscovery }
    private var handoffMonitor: NetworkHandoffMonitor { workflows.handoffMonitor }
    private var session: RetailSetupSession { workflows.session }
    private var connection: RetailSetupConnection { workflows.connection }
    private var provisioner: RetailRuntimeProvisioner { workflows.provisioner }
    private var pairing: RetailPairingWorkflow { workflows.pairing }
    private var dashboard: RetailDashboardSession { workflows.dashboard }
    private var navigator: RetailLibraryNavigator { workflows.navigator }
    private var ai: RetailAIServicePreparation { workflows.ai }
    private var onReady: @MainActor () -> Void { workflows.onReady }
    private var runtime: (any SparkRuntimeReading)? { workflows.runtime }
    private var state: RetailOnboardingState { session.state }

    private var isAddingSpark: Bool { session.isAddingSpark }

    private var setupSSID: String {
        get { connection.setupSSID }
        set { connection.setupSSID = newValue }
    }

    private var machineName: String {
        get { session.machineName }
        set { session.machineName = newValue }
    }

    private var administratorPassword: String {
        get { session.administratorPassword }
        set { session.administratorPassword = newValue }
    }

    private var pairingDeviceTarget: DiscoveredSpark? { pairing.pairingDeviceTarget }

    private var dashboardModel: SparkDashboardModel? { dashboard.dashboardModel }

    private var selectedDiscoveryCandidate: DiscoveredSpark? {
        get { session.selectedDiscoveryCandidate }
        set { session.selectedDiscoveryCandidate = newValue }
    }

    private var bootstrapResult: RuntimeBootstrapResult? {
        get { session.bootstrapResult }
        set { session.bootstrapResult = newValue }
    }

    private var pairingNeedsRuntimeReinstall: Bool {
        get { pairing.pairingNeedsRuntimeReinstall }
        set { pairing.pairingNeedsRuntimeReinstall = newValue }
    }

    private var oobeService: (any SparkOOBEServicing)? {
        get { connection.oobeService }
        set { connection.oobeService = newValue }
    }

    private var canJoinSetupNetwork: Bool { connection.canJoinSetupNetwork }

    func startAddingSpark() {
        resetSetup()
        cancelProbe()
        session.isChoosingSpark = false
        session.isAddingSpark = true
    }

    /// Start local Bonjour discovery only after the explicit Add Spark action.
    func chooseSparkToAdd() {
        cancelProbe()
        session.isChoosingSpark = true
        session.isAddingSpark = false
        pairing.pairingDeviceTarget = nil
        pairing.pairingDeviceError = nil
        localDiscovery.start()
        // 10.2.2: browse _ssh._tcp as well, so a DGX Spark with no runtime yet is findable.
        bootstrapDiscovery.start()
    }

    func cancelChoosingSpark() {
        localDiscovery.stop()
        bootstrapDiscovery.stop()
        session.isChoosingSpark = false
    }

    func chooseNearbySpark(_ discovered: DiscoveredSpark) {
        localDiscovery.stop()
        bootstrapDiscovery.stop()
        session.isChoosingSpark = false
        _ = handleDiscovered(discovered)
    }

    @discardableResult
    func chooseExistingSpark(host rawHost: String) -> Bool {
        guard let discovered = ExistingSparkAddress.discovered(rawHost) else { return false }
        chooseNearbySpark(discovered)
        return true
    }

    /// Prefill setup from a discovered hostname while preserving the selected route hint.
    func startAddingSpark(prefillHost: String) {
        startAddingSpark()
        let host =
            prefillHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".local", with: "", options: [.caseInsensitive, .anchored])
            .lowercased()
        guard !host.isEmpty else { return }
        setupSSID = host
        machineName = host
    }

    /// An existing machine is already on the home network; inspect it without replaying first boot.
    func chooseBootstrapSpark(_ target: BootstrapSpark) {
        startAddingSpark()
        localDiscovery.stop()
        bootstrapDiscovery.stop()
        session.bootstrapTarget = target
        machineName = SSHRuntimeBootstrapInstaller.hostName(for: target)
        session.state = RetailOnboardingState(phase: .runtimeInstall)
    }

    /// Cancel factory setup back to the Add Spark choice that launched it.
    func cancelAddingSpark() {
        guard
            state.phase == .connectToSpark
                || (state.phase == .runtimeInstall && state.completedPhases.isEmpty)
        else { return }
        cancelProbe()
        resetSetup()
        chooseSparkToAdd()
    }

    func performPrimaryAction(
        preparation: RetailOnboardingPreparationModel? = nil
    ) async {
        switch state.phase {
        case .connectToSpark:
            guard canJoinSetupNetwork else {
                // On platforms without in-app Wi-Fi joining, find a Spark already on the network.
                chooseSparkToAdd()
                return
            }
            await joinSetupNetwork()
        case .nvidiaSetup:
            prepareNativeSetupIfNeeded()
        case .runtimeInstall:
            await installRuntime(preparation: preparation)
        case .starterModel:
            guard let preparation,
                !preparation.isCheckingAIServices,
                RetailPreparationItem.requiredServicesAreReady(preparation.ai)
            else { return }
            send(.starterModelCompleted)
            await openFirstModel(modelID: preparation.firstModelID)
        case .ready:
            await openFirstModel()
        case .securing:
            await pairFirstOwner()
        case .sparkRestarting:
            await provisioner.checkSparkIsBack()
        case .joiningSetupNetwork, .sparkConnected, .reconnecting, .rediscovering,
            .finishingSparkSetup:
            break
        }
    }

    func performSecondaryAction(
        preparation: RetailOnboardingPreparationModel? = nil
    ) {
        switch state.phase {
        case .connectToSpark:
            connection.isShowingQuickStartScanner = true
        case .nvidiaSetup:
            ownerFinishedNVIDIASetupOnTheSpark()
        case .starterModel:
            if let preparation {
                Task { await checkAIServices(preparation: preparation) }
            }
        default:
            break
        }
    }

    func retry(preparation: RetailOnboardingPreparationModel? = nil) {
        let issue = state.issue
        send(.retry)
        switch issue {
        case .nvidiaFinalizationFailed:
            Task { await finishNVIDIASetup() }
        case .sparkNotBackAfterRestart:
            Task { await provisioner.awaitSparkRestart(holdFirst: false) }
        case .runtimeInstallFailed:
            // The retained account password lets the retry start at once; without it the form waits for one.
            guard !administratorPassword.isEmpty else { return }
            provisioner.clearExistingSparkCheck()
            Task { await installRuntime(preparation: preparation) }
        case .pairingFailed:
            let reinstall = pairingNeedsRuntimeReinstall
            pairingNeedsRuntimeReinstall = false
            pairing.pairingFailureDetail = nil
            if reinstall {
                bootstrapResult = nil
                send(.runtimeReinstallRequested)
                // If the session credential is unavailable, remain on runtime setup so the owner can enter it again.
                guard !administratorPassword.isEmpty else { return }
                Task { await installRuntime(preparation: preparation) }
            } else {
                // Back in `.securing`, which drives itself.
                Task { await pairFirstOwner() }
            }
        case .sparkNotFoundAfterSetup:
            // Restart the bounded discovery search using the owner's current machine name.
            startRediscovery()
        case .homeNetworkUnavailable:
            handoffMonitor.start()
        case .setupHotspotUnavailable, .setupNetworkJoinDenied:
            connection.setupJoinDetail = nil
        default:
            break
        }
    }

    /// Forget the changed key, then repeat whatever the changed key stopped.
    func trustNewHostKey(preparation: RetailOnboardingPreparationModel?) async {
        provisioner.trustNewHostKey()
        if state.phase == .sparkRestarting, state.issue == nil {
            await provisioner.checkSparkIsBack()
        } else if state.issue == .runtimeInstallFailed {
            retry(preparation: preparation)
        } else if state.phase == .runtimeInstall {
            provisioner.clearExistingSparkCheck()
            await provisioner.checkExistingSpark()
        }
    }

    func goBack() {
        if state.phase == .connectToSpark
            || (state.phase == .runtimeInstall && state.completedPhases.isEmpty)
        {
            cancelAddingSpark()
            return
        }
        guard state.canGoBack else { return }
        cancelProbe()
        cancelRediscoveryTimeout()
        connection.cancelHandoffPolling()
        bootstrapDiscovery.stop()
        handoffMonitor.stop()
        send(.back)
        if state.phase == .connectToSpark {
            connection.nativeSetupModel = nil
            oobeService = nil
            // After Back, offer the current setup network explicitly instead of automatically undoing navigation.
            connection.hasOfferedDetectedNetwork = true
        }
    }

    /// Pairing is complete; model download, launch and a first answer are still separate steps.
    private func openFirstModel(modelID: String? = nil) async {
        await completeSetup()
        guard state.issue == nil, let dashboardModel else { return }
        if let modelID {
            dashboardModel.requestModelFocus(modelID)
        } else {
            await dashboardModel.refresh()
            guard !Task.isCancelled else { return }
            if let firstModel = dashboardModel.models.first {
                dashboardModel.requestModelFocus(firstModel.id)
            }
        }
        onReady()
    }

    func completeSetup() async { await completion.completeSetup() }
    func completePairedSetup(route: URL, trust: NodeTrust) {
        completion.completePairedSetup(route: route, trust: trust)
    }
    @discardableResult
    func recordCompletedSetup(route: URL, authenticated: AuthenticatedIdentity)
        -> ReconciliationOutcome?
    {
        completion.recordCompletedSetup(route: route, authenticated: authenticated)
    }
    func closeDashboard() { completion.closeDashboard() }
    func resetSetup() { completion.resetSetup() }

    /// Open saved discovery matches, preserve blocked-card recovery, and use shouldPresentDiscoveryAddSheet for unknown targets.
    @discardableResult
    func handleDiscovered(_ discovered: DiscoveredSpark) -> Task<Void, Never>? {
        let host = discovered.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".local", with: "", options: [.caseInsensitive, .anchored])
        if let existing = library.entry(matchingHostname: host) {
            // Known card: no discovery candidate should linger.
            selectedDiscoveryCandidate = nil
            pairing.pairingDeviceTarget = nil
            pairing.pairingDeviceError = nil
            return openLibraryEntry(existing.id)
        }
        // An advertised runtime is already installed and needs an owner's pairing invitation, never factory setup.
        cancelProbe()
        session.isAddingSpark = false
        pairing.pairingDeviceTarget = discovered
        pairing.pairingDeviceError = nil
        selectedDiscoveryCandidate = discovered
        return nil
    }

    /// Show the add sheet only for a new setup or pairing target; a nil probe alone also includes blocked saved cards.
    func shouldPresentDiscoveryAddSheet(probe: Task<Void, Never>?) -> Bool {
        probe == nil && (isAddingSpark || pairingDeviceTarget != nil)
    }

    /// Recover durable library storage while retaining entries created during this session.
    func retryLibraryStorage() {
        library.recoverDurableStorage {
            try? SparkLibraryStoreFactory.makeDurableStore()
        }
    }

    func buildRoute() -> URL? { completion.buildRoute() }

    func send(_ event: RetailOnboardingEvent) { session.send(event) }

    func ownerFinishedNVIDIASetupOnTheSpark() {
        connection.ownerFinishedNVIDIASetupOnTheSpark()
    }

    func startRediscovery() { connection.startRediscovery() }

    func cancelRediscoveryTimeout() { connection.cancelRediscoveryTimeout() }

    func joinSetupNetwork() async { await connection.joinSetupNetwork() }

    func installRuntime(preparation: RetailOnboardingPreparationModel?) async {
        await provisioner.installRuntime(preparation: preparation)
    }

    func pairFirstOwner() async { await pairing.pairFirstOwner() }

    func checkAIServices(
        preparation: RetailOnboardingPreparationModel? = nil
    ) async { await ai.checkAIServices(preparation: preparation) }

    func prepareNativeSetupIfNeeded() { connection.prepareNativeSetupIfNeeded() }

    func finishNVIDIASetup() async { await connection.finishNVIDIASetup() }

    @discardableResult
    func openLibraryEntry(_ entryID: String) -> Task<Void, Never>? {
        return navigator.openLibraryEntry(entryID)
    }

    func cancelProbe() { navigator.cancelProbe() }

    func prepareDashboard(route: URL, entry: LibraryEntry) {
        dashboard.prepareDashboard(route: route, entry: entry)
    }

    func publishDashboard(
        route: URL,
        runtime: any SparkRuntimeReading,
        targetID: String,
        entry: LibraryEntry,
        trust: NodeTrust?
    ) {
        dashboard.publishDashboard(
            route: route,
            runtime: runtime,
            targetID: targetID,
            entry: entry,
            trust: trust
        )
    }

}
