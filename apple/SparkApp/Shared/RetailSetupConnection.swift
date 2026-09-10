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
final class RetailSetupConnection {
    var setupSSID = "" {
        didSet {
            // Treat typed names as prefixes until a QR code or observed association establishes the exact SSID.
            if setupSSID != oldValue { setupSSIDIsExact = false }
        }
    }
    var setupSSIDIsExact = false
    var setupPassphrase = ""
    var setupPage = ""
    var detectedSetupSSID: String?
    var sparkSetupNetworkStillActive = false
    var joinedSetupSSID: String?
    var setupJoinDetail: String?
    var isShowingQuickStartScanner = false
    var scanErrorMessage: String?
    var nativeSetupModel: NativeSparkSetupModel?
    var oobeService: (any SparkOOBEServicing)?
    var isDetectingExistingConnection = false
    var hasOfferedDetectedNetwork = false
    var rediscoveryTimeoutTask: Task<Void, Never>?
    var rediscoveryGeneration = 0
    /// Re-reads the current network while reconnecting; the path monitor reports a Wi-Fi-to-Wi-Fi move as no change.
    var handoffPollTask: Task<Void, Never>?
    private var handoffPollGeneration = 0
    private let handoffPollInterval: Duration
    /// When the bounded post-setup search began, for the elapsed clock on the waiting screen.
    var rediscoveryStartedAt: Date?
    private let session: RetailSetupSession
    private let networkJoiner: any SetupNetworkJoining
    private let currentWiFiReader: any CurrentWiFiNetworkReading
    private let localDiscovery: SparkDiscoveryService
    private let bootstrapDiscovery: BootstrapDiscoveryService
    private let handoffMonitor: NetworkHandoffMonitor
    private let rediscoveryTimeout: Duration
    private let sleep: @Sendable (Duration) async throws -> Void
    private let oobeServiceFactory: SparkOOBEServiceFactory
    var resetSetup: () -> Void = {}
    var performPrimaryAction: () async -> Void = {}
    init(
        session: RetailSetupSession,
        networkJoiner: any SetupNetworkJoining,
        currentWiFiReader: any CurrentWiFiNetworkReading,
        localDiscovery: SparkDiscoveryService,
        bootstrapDiscovery: BootstrapDiscoveryService,
        handoffMonitor: NetworkHandoffMonitor,
        rediscoveryTimeout: Duration,
        handoffPollInterval: Duration = .seconds(3),
        sleep: @escaping @Sendable (Duration) async throws -> Void,
        oobeServiceFactory: @escaping SparkOOBEServiceFactory
    ) {
        self.handoffPollInterval = handoffPollInterval
        self.session = session
        self.networkJoiner = networkJoiner
        self.currentWiFiReader = currentWiFiReader
        self.localDiscovery = localDiscovery
        self.bootstrapDiscovery = bootstrapDiscovery
        self.handoffMonitor = handoffMonitor
        self.rediscoveryTimeout = rediscoveryTimeout
        self.sleep = sleep
        self.oobeServiceFactory = oobeServiceFactory
    }
    private var state: RetailOnboardingState {
        get { session.state }
        set { session.state = newValue }
    }
    private var isAddingSpark: Bool {
        get { session.isAddingSpark }
        set { session.isAddingSpark = newValue }
    }
    private var isChoosingSpark: Bool {
        get { session.isChoosingSpark }
        set { session.isChoosingSpark = newValue }
    }
    private var machineName: String {
        get { session.machineName }
        set { session.machineName = newValue }
    }
    private var administratorUsername: String? {
        get { session.administratorUsername }
        set { session.administratorUsername = newValue }
    }
    private var administratorPassword: String {
        get { session.administratorPassword }
        set { session.administratorPassword = newValue }
    }
    private var bootstrapTarget: BootstrapSpark? {
        get { session.bootstrapTarget }
        set { session.bootstrapTarget = newValue }
    }
    private func send(_ event: RetailOnboardingEvent) { session.send(event) }

    /// Offer the setup Wi-Fi form only when this platform can join the network in app.
    var canJoinSetupNetwork: Bool {
        networkJoiner.canJoinSetupNetwork
    }

    var canScanQuickStartCode: Bool {
        #if os(iOS)
            true
        #else
            false
        #endif
    }

    /// Use a supplied setup page only when it is on the setup network; else derive the address.
    private var explicitSetupPage: URL? {
        let rawPage = setupPage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPage.isEmpty, let url = URL(string: rawPage),
            SetupPageAddress.isOnSetupNetwork(url)
        else { return nil }
        return url
    }

    /// The first-boot page is plain HTTP by default, so the owner is told before typing a password.
    var setupPageIsUnencrypted: Bool {
        nvidiaSetupURL?.scheme?.lowercased() == "http"
    }

    var nvidiaSetupURL: URL? {
        if let explicitSetupPage {
            return explicitSetupPage
        }

        guard let hostName = SparkSetupAddress.hostname(for: setupSSID) else { return nil }
        var components = URLComponents()
        components.scheme = "http"
        components.host = hostName
        return components.url
    }

    /// After external first-boot setup, wait for and verify the Spark's network handoff.
    func ownerFinishedNVIDIASetupOnTheSpark() {
        guard state.phase == .nvidiaSetup, state.issue == nil else { return }
        watchForNetworkHandoff()
    }

    /// Continue automatically on the first observed setup network; later observations remain an explicit choice.
    func detectExistingSparkConnection() async {
        guard state.phase == .connectToSpark, !isDetectingExistingConnection else { return }
        isDetectingExistingConnection = true
        defer { isDetectingExistingConnection = false }

        // Opening Add Spark is not a choice of route; ask for location only when the owner picks the setup route.
        let ssid = await currentWiFiReader.currentSSID(requestingPermission: false)

        guard let ssid,
            state.phase == .connectToSpark,
            isSparkSetupSSID(ssid)
        else {
            detectedSetupSSID = nil
            return
        }

        if isChoosingSpark {
            resetSetup()
            isAddingSpark = true
        }
        detectedSetupSSID = ssid
        guard !hasOfferedDetectedNetwork else { return }
        useDetectedSetupNetwork()
    }

    /// Continue on the existing setup Wi-Fi association without joining again or retaining a passphrase.
    func useDetectedSetupNetwork() {
        guard state.phase == .connectToSpark, let ssid = detectedSetupSSID else { return }
        hasOfferedDetectedNetwork = true
        setupSSID = ssid
        setupSSIDIsExact = true
        machineName = ssid
        setupPage = ""
        setupJoinDetail = nil
        joinedSetupSSID = ssid
        send(.setupNetworkSubmitted)
        send(.setupNetworkJoined)
    }

    func applyQuickStartCode(_ payload: String) throws {
        let credentials = try QuickStartCodeParser.parse(payload)
        guard let ssid = credentials.exactSSID else {
            throw QuickStartCodeError.missingSSID
        }
        setupSSID = ssid
        setupSSIDIsExact = true
        setupPassphrase = credentials.passphrase
        machineName = ssid
        setupPage = credentials.setupPage?.absoluteString ?? ""
        setupJoinDetail = nil
    }

    func quickStartCodeScanned(_ payload: String) {
        do {
            try applyQuickStartCode(payload)
            scanErrorMessage = nil
            isShowingQuickStartScanner = false
            Task { await performPrimaryAction() }
        } catch {
            scanErrorMessage =
                String(
                    localized:
                        "That code does not contain Spark Wi-Fi details. You can enter the details from the card instead."
                )
        }
    }

    func nativeSetupWiFiSubmitted() {
        guard state.phase == .nvidiaSetup else { return }
        watchForNetworkHandoff()
    }

    /// Keep the setup Wi-Fi association until the Spark removes it, including when home-network credentials fail.
    func watchForNetworkHandoff() {
        detectedSetupSSID = nil
        sparkSetupNetworkStillActive = false
        send(.setupHotspotDisappeared)
        handoffMonitor.start()
        // Look for the Spark on the home network at once: its answer there is the proof the join worked.
        bootstrapDiscovery.start()
        startHandoffPolling()
    }

    /// Check the current network on a timer as well as on path changes.
    func startHandoffPolling() {
        cancelHandoffPolling()
        scheduleHandoffPoll(generation: handoffPollGeneration)
    }

    /// Each task sleeps once; retired generations ignore late ticks.
    private func scheduleHandoffPoll(generation: Int) {
        let interval = handoffPollInterval
        let sleep = self.sleep
        // Keep this short-lived strong capture: a vanished weak capture triggers the Swift task allocator bug.
        handoffPollTask = Task { @MainActor in
            do {
                try await sleep(interval)
            } catch {
                return
            }
            handoffPollTicked(generation: generation)
        }
    }

    private func handoffPollTicked(generation: Int) {
        guard handoffPollGeneration == generation, state.phase == .reconnecting,
            state.issue == nil
        else { return }
        scheduleHandoffPoll(generation: generation)
        let handoff = handoffMonitor.state
        Task { @MainActor in
            await networkHandoffChanged(handoff)
        }
    }

    /// Retire by generation: cancelling a sleeping task triggers the Swift task allocator bug.
    func cancelHandoffPolling() {
        handoffPollGeneration &+= 1
        handoffPollTask = nil
    }

    func connectionCelebrationFinished() {
        guard state.phase == .sparkConnected else { return }
        send(.connectionCelebrationFinished)
        prepareNativeSetupIfNeeded()
    }

    func networkHandoffChanged(_ handoff: NetworkHandoffState) async {
        guard state.phase == .reconnecting else { return }
        switch handoff {
        case .wifiAvailable, .otherNetworkAvailable:
            let setupNetwork = joinedSetupSSID ?? setupSSID
            let currentSSID = await currentWiFiReader.currentSSID()
            guard state.phase == .reconnecting else { return }

            if let currentSSID,
                currentSSID.caseInsensitiveCompare(setupNetwork) == .orderedSame
            {
                detectedSetupSSID = currentSSID
                sparkSetupNetworkStillActive = true
                return
            }

            #if os(iOS)
                // Require an observed Wi-Fi handoff; cellular availability or an unknown SSID is insufficient.
                guard handoff == .wifiAvailable, currentSSID != nil else { return }
            #endif

            completeNetworkHandoff(setupNetwork: setupNetwork)
        case .checking, .offline:
            break
        }
    }

    func retrySparkWiFi() {
        guard state.phase == .reconnecting, sparkSetupNetworkStillActive else { return }
        handoffMonitor.stop()
        cancelHandoffPolling()
        bootstrapDiscovery.stop()
        sparkSetupNetworkStillActive = false
        nativeSetupModel?.retryNetworkSelection()
        send(.retrySparkWiFi)
    }

    func completeNetworkHandoff(setupNetwork: String) {
        cancelHandoffPolling()
        networkJoiner.forget(ssid: setupNetwork)
        detectedSetupSSID = nil
        sparkSetupNetworkStillActive = false
        send(.homeNetworkAvailable)
        startRediscovery()
    }

    /// Bound home-network rediscovery while allowing the Spark's first restart up to ten minutes.
    func startRediscovery() {
        bootstrapDiscovery.start()
        cancelRediscoveryTimeout()
        rediscoveryStartedAt = Date()
        let generation = rediscoveryGeneration
        let timeout = rediscoveryTimeout
        let sleep = self.sleep
        rediscoveryTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await sleep(timeout)
            } catch {
                return
            }
            guard let self, rediscoveryGeneration == generation,
                state.phase == .rediscovering,
                state.issue == nil
            else { return }
            bootstrapDiscovery.stop()
            send(.failed(.sparkNotFoundAfterSetup))
        }
    }

    /// Restart the search on request; the elapsed clock and the limit start again.
    func lookAgainForSpark() {
        guard state.phase == .rediscovering else { return }
        bootstrapDiscovery.stop()
        startRediscovery()
    }

    func cancelRediscoveryTimeout() {
        rediscoveryGeneration &+= 1
        rediscoveryTimeoutTask = nil
    }

    func bootstrapCandidatesChanged(_ candidates: [BootstrapSpark]) async {
        guard state.phase == .rediscovering || state.phase == .reconnecting, state.issue == nil
        else { return }
        let expected = normalisedMachineName
        guard
            let target = candidates.first(where: {
                bootstrapCandidateMatches($0, expectedMachineName: expected)
            })
        else { return }

        if state.phase == .reconnecting {
            guard await sparkAnsweredOnHomeNetwork() else { return }
        }
        bootstrapTarget = target
        cancelRediscoveryTimeout()
        bootstrapDiscovery.stop()
        handoffMonitor.stop()
        send(.sparkDiscovered)
        await finishNVIDIASetup()
    }

    /// The Spark answering by name proves it joined the chosen Wi-Fi, but only once this device has left its hotspot: the hotspot carries the same advertisement.
    private func sparkAnsweredOnHomeNetwork() async -> Bool {
        let setupNetwork = joinedSetupSSID ?? setupSSID
        let currentSSID = await currentWiFiReader.currentSSID()
        guard state.phase == .reconnecting, state.issue == nil else { return false }
        if let currentSSID, currentSSID.caseInsensitiveCompare(setupNetwork) == .orderedSame {
            detectedSetupSSID = currentSSID
            sparkSetupNetworkStillActive = true
            return false
        }
        #if os(iOS)
            guard currentSSID != nil else { return false }
        #endif
        completeNetworkHandoff(setupNetwork: setupNetwork)
        return state.phase == .rediscovering
    }

    /// Join an SSID prefix unless verified as exact, then use the system-reported network name.
    func joinSetupNetwork() async {
        // Do not derive a setup address from an SSID prefix whose full name is still unknown.
        let page = explicitSetupPage
        let typedName = setupSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        let credentials: SetupNetworkCredentials
        do {
            credentials =
                setupSSIDIsExact
                ? try SetupNetworkCredentials(
                    ssid: typedName,
                    passphrase: setupPassphrase,
                    setupPage: page
                )
                : try SetupNetworkCredentials(
                    ssidPrefix: typedName,
                    passphrase: setupPassphrase,
                    setupPage: page
                )
        } catch {
            setupPassphrase = ""
            setupJoinDetail = RetailOnboardingFailurePresentation.describe(credentialError: error)
            send(.failed(.setupHotspotUnavailable))
            return
        }

        setupJoinDetail = nil
        send(.setupNetworkSubmitted)
        defer { setupPassphrase = "" }
        do {
            let joinedSSID = try await networkJoiner.join(credentials)
            joinedSetupSSID = joinedSSID
            setupSSID = joinedSSID
            setupSSIDIsExact = true
            machineName = joinedSSID
            detectedSetupSSID = joinedSSID
            hasOfferedDetectedNetwork = true
            send(.setupNetworkJoined)
        } catch let error as SetupNetworkJoinError {
            setupJoinDetail = RetailOnboardingFailurePresentation.describe(joinError: error)
            switch error {
            case .userDenied, .systemDenied:
                send(.failed(.setupNetworkJoinDenied))
            default:
                send(.failed(.setupHotspotUnavailable))
            }
        } catch {
            setupJoinDetail = nil
            send(.failed(.setupHotspotUnavailable))
        }
    }

    func prepareNativeSetupIfNeeded() {
        guard nativeSetupModel == nil, let nvidiaSetupURL else {
            if nvidiaSetupURL == nil {
                send(.failed(.nvidiaSetupInterrupted))
            }
            return
        }

        let service = oobeServiceFactory(nvidiaSetupURL)
        oobeService = service
        nativeSetupModel = NativeSparkSetupModel(
            service: service,
            transportNotice: setupPageIsUnencrypted
                ? NativeSparkSetupPresentation.unencryptedTransportNotice : nil,
            onAccountCreated: { [weak self] username, password in
                self?.administratorUsername = username
                // Keep this credential in memory only and clear it on successful pairing, cancellation or reset.
                self?.administratorPassword = password
            },
            onWiFiSubmitted: { [weak self] in
                self?.nativeSetupWiFiSubmitted()
            }
        )
    }

    func finishNVIDIASetup() async {
        guard state.phase == .finishingSparkSetup, let oobeService else { return }
        do {
            try await oobeService.finishSetup()
            send(.nvidiaSetupCompleted)
        } catch {
            send(.failed(.nvidiaFinalizationFailed))
        }
    }

    var normalisedMachineName: String {
        normalise(machineName)
    }

    func normalise(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: ".local", with: "")
    }

    func bootstrapCandidateMatches(
        _ candidate: BootstrapSpark,
        expectedMachineName: String
    ) -> Bool {
        let advertisedName = normalise(candidate.displayName)
        if advertisedName == expectedMachineName {
            return true
        }

        let sshServiceSuffix = String(localized: " ssh")
        guard advertisedName.hasSuffix(sshServiceSuffix) else { return false }
        return String(advertisedName.dropLast(sshServiceSuffix.count)) == expectedMachineName
    }

    func isSparkSetupSSID(_ value: String) -> Bool {
        let normalised = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalised.hasPrefix("spark-") || normalised.hasPrefix("dgx-spark-")
    }

}
