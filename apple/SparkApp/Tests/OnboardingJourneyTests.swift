import Foundation
import Network
import SparkAPI
import SparkBootstrap
import SparkCore
import SparkDiscovery
import SparkLibrary
import SparkSecurity
import Testing

@testable import SparkAppComposition

/// Exercises onboarding navigation, bounded discovery and additional-device invitation across supported Apple platforms.

// MARK: - Doubles

@MainActor
private final class JourneyNetworkJoiner: SetupNetworkJoining {
    var canJoinSetupNetwork = true
    var requestedMatch: SetupNetworkMatch?
    var forgottenSSID: String?
    /// Use the network actually joined after system selection rather than the owner's typed prefix.
    var resolvedSSID: String?
    var joinError: (any Error)?

    @discardableResult
    func join(_ credentials: SetupNetworkCredentials) async throws -> String {
        requestedMatch = credentials.match
        if let joinError { throw joinError }
        if let resolvedSSID { return resolvedSSID }
        switch credentials.match {
        case .exactSSID(let ssid): return ssid
        case .ssidPrefix(let prefix): return prefix
        }
    }

    func forget(ssid: String) {
        forgottenSSID = ssid
    }
}

@MainActor
private final class JourneyWiFiReader: CurrentWiFiNetworkReading {
    var ssid: String?

    init(ssid: String?) {
        self.ssid = ssid
    }

    func currentSSID() async -> String? { ssid }
}

private actor JourneyOOBEService: SparkOOBEServicing {
    func regionalOptions() async throws -> SparkOOBERegionalOptions {
        SparkOOBERegionalOptions(languages: [], timeZones: [])
    }
    func configureRegion(languageIndex: Int, timeZoneIndex: Int) async throws {}
    func licenceText() async throws -> String { "" }
    func acceptLicence() async throws {}
    func createAccount(username: String, password: String) async throws {}
    func configureTelemetry(functional: Bool, technical: Bool) async throws {}
    func wifiNetworks() async throws -> [SparkOOBEWiFiNetwork] { [] }
    func connectWiFi(index: Int, password: String) async throws {}
    func finishSetup() async throws {}
}

// MARK: - Selecting and joining the setup network (§10.8.2-3, §11.2)

@MainActor
@Test func aPartialNetworkNameIsSearchedForRatherThanSpeltOutExactly() async throws {
    // Let iOS select matching Wi-Fi networks and derive the Spark name from the joined SSID.
    let joiner = JourneyNetworkJoiner()
    joiner.resolvedSSID = "spark-a1b2"
    let model = RetailOnboardingModel(networkJoiner: joiner)

    model.startAddingSpark()
    model.setupSSID = "spark"
    model.setupPassphrase = "correct-horse"
    await model.performPrimaryAction()

    #expect(joiner.requestedMatch == .ssidPrefix("spark"))
    #expect(model.state.phase == .sparkConnected)
    #expect(model.machineName == "spark-a1b2", "the joined network names the Spark")
    #expect(model.setupSSID == "spark-a1b2")
    #expect(model.nvidiaSetupURL == URL(string: "http://spark-a1b2.local"))
}

@MainActor
@Test func aScannedQuickStartCodeJoinsExactlyTheNetworkItNames() async throws {
    let joiner = JourneyNetworkJoiner()
    let model = RetailOnboardingModel(networkJoiner: joiner)
    model.startAddingSpark()

    try model.applyQuickStartCode(
        "spark://setup?ssid=DGX-Spark-A1B2&password=correct-horse"
    )
    await model.performPrimaryAction()

    #expect(joiner.requestedMatch == .exactSSID("DGX-Spark-A1B2"))
    #expect(model.state.phase == .sparkConnected)
}

@MainActor
@Test func scanningQuickStartAutoConnectsWithoutShowingManualFields() async {
    let joiner = JourneyNetworkJoiner()
    let model = RetailOnboardingModel(networkJoiner: joiner)
    model.startAddingSpark()

    model.quickStartCodeScanned(
        "spark://setup?ssid=DGX-Spark-A1B2&password=correct-horse"
    )
    for _ in 0..<20 where model.state.phase != .sparkConnected {
        await Task.yield()
    }

    #expect(joiner.requestedMatch == .exactSSID("DGX-Spark-A1B2"))
    #expect(model.state.phase == .sparkConnected)
    #expect(model.setupPassphrase.isEmpty)
}

@MainActor
@Test func aNameTooShortToSearchForSaysSoRatherThanBlamingTheSpark() async {
    let joiner = JourneyNetworkJoiner()
    let model = RetailOnboardingModel(networkJoiner: joiner)
    model.startAddingSpark()
    model.setupSSID = "sp"
    model.setupPassphrase = "correct-horse"

    await model.performPrimaryAction()

    #expect(joiner.requestedMatch == nil, "nothing left the device")
    #expect(model.state.issue == .setupHotspotUnavailable)
    let detail = model.failureDetail ?? ""
    #expect(detail.contains("three characters"), "it says what to do: \(detail)")
    #expect(model.setupPassphrase.isEmpty, "the Quick Start password is not kept")
}

@MainActor
@Test func theSetupNetworkThisDeviceIsAlreadyOnIsSelectedOnce() async {
    let model = RetailOnboardingModel(
        networkJoiner: JourneyNetworkJoiner(),
        currentWiFiReader: JourneyWiFiReader(ssid: "spark-a1b2")
    )
    model.startAddingSpark()

    await model.detectExistingSparkConnection()

    #expect(model.state.phase == .sparkConnected)
    #expect(model.detectedSetupSSID == "spark-a1b2")
    #expect(model.machineName == "spark-a1b2")
}

// MARK: - Back navigation

@MainActor
@Test func comingBackFromNVIDIASetupStaysOnTheNetworkScreen() async {
    // Returning to network selection must not immediately reselect the associated network and reopen native setup.
    let model = RetailOnboardingModel(
        networkJoiner: JourneyNetworkJoiner(),
        currentWiFiReader: JourneyWiFiReader(ssid: "spark-a1b2"),
        oobeServiceFactory: { _ in JourneyOOBEService() }
    )
    model.startAddingSpark()
    await model.detectExistingSparkConnection()
    model.connectionCelebrationFinished()
    #expect(model.state.phase == .nvidiaSetup)

    model.goBack()
    #expect(model.state.phase == .connectToSpark)
    #expect(model.nativeSetupModel == nil, "the NVIDIA screens are torn down")

    await model.detectExistingSparkConnection()
    #expect(model.state.phase == .connectToSpark, "back stays back")
    #expect(model.detectedSetupSSID == "spark-a1b2", "it is offered, not taken")
}

@MainActor
@Test func theDetectedNetworkCanStillBeChosenDeliberately() async {
    let model = RetailOnboardingModel(
        networkJoiner: JourneyNetworkJoiner(),
        currentWiFiReader: JourneyWiFiReader(ssid: "spark-a1b2"),
        oobeServiceFactory: { _ in JourneyOOBEService() }
    )
    model.startAddingSpark()
    await model.detectExistingSparkConnection()
    model.connectionCelebrationFinished()
    model.goBack()

    model.useDetectedSetupNetwork()

    #expect(model.state.phase == .sparkConnected)
    #expect(model.machineName == "spark-a1b2")
}

@MainActor
@Test func addSparkDetectsTheFactoryNetworkInsteadOfWaitingForSparkd() async {
    let model = RetailOnboardingModel(
        networkJoiner: JourneyNetworkJoiner(),
        currentWiFiReader: JourneyWiFiReader(ssid: "DGX-Spark-A1B2"),
        oobeServiceFactory: { _ in JourneyOOBEService() }
    )

    model.chooseSparkToAdd()
    await model.detectExistingSparkConnection()

    #expect(!model.isChoosingSpark, "the nearby sparkd search is no longer covering the setup flow")
    #expect(model.isAddingSpark)
    #expect(model.state.phase == .sparkConnected)
    #expect(model.machineName == "DGX-Spark-A1B2")
}

@MainActor
@Test func cancellingFromTheFirstScreenReturnsToTheAddSparkChoice() async {
    let model = RetailOnboardingModel(networkJoiner: JourneyNetworkJoiner())
    model.chooseSparkToAdd()
    model.startAddingSpark()

    model.goBack()

    #expect(!model.isAddingSpark)
    #expect(model.isChoosingSpark, "the choice screen is what is behind the first screen")
    #expect(model.setupSSID.isEmpty)
}

@MainActor
@Test func anExistingSparkCanBeAddedByAddressWhenDiscoveryFindsNothing() {
    let model = RetailOnboardingModel(networkJoiner: JourneyNetworkJoiner())
    model.chooseSparkToAdd()

    #expect(model.chooseExistingSpark(host: "192.168.100.63"))
    #expect(model.pairingDeviceTarget?.displayName == "192.168.100.63")
    #expect(
        model.pairingDeviceTarget?.endpoint
            == .hostPort(host: "192.168.100.63", port: 7443)
    )
    #expect(!model.isChoosingSpark)
}

@MainActor
@Test func anExistingSparkAddressRejectsURLsAndCredentials() {
    let model = RetailOnboardingModel(networkJoiner: JourneyNetworkJoiner())
    model.chooseSparkToAdd()

    #expect(!model.chooseExistingSpark(host: "https://spark.local"))
    #expect(!model.chooseExistingSpark(host: "owner:secret@spark.local"))
    #expect(model.pairingDeviceTarget == nil)
}

// MARK: - Platforms that cannot join a setup network (§11.2)

@MainActor
@Test func aDeviceThatCannotJoinSetupWiFiIsNeverLeftOnTheQuickStartForm() async {
    let joiner = JourneyNetworkJoiner()
    joiner.canJoinSetupNetwork = false
    let model = RetailOnboardingModel(networkJoiner: joiner)
    model.startAddingSpark()

    #expect(!model.canJoinSetupNetwork)

    await model.performPrimaryAction()

    #expect(joiner.requestedMatch == nil, "no join is attempted that cannot succeed")
    #expect(model.state.issue == nil, "and no failure is invented for the owner")
    #expect(model.isChoosingSpark, "the action leads to the path this device has")
}

// MARK: - Handoff to discovery (§10.1 steps 7-9)

@MainActor
@Test func aSparkThatNeverAppearsBecomesARecoverableFailure() async {
    let model = RetailOnboardingModel(
        networkJoiner: JourneyNetworkJoiner(),
        currentWiFiReader: JourneyWiFiReader(ssid: "Home WiFi"),
        oobeServiceFactory: { _ in JourneyOOBEService() },
        rediscoveryTimeout: .milliseconds(1),
        sleep: { _ in }
    )
    model.startAddingSpark()
    model.setupSSID = "spark-a1b2"
    model.setupPassphrase = "correct-horse"
    await model.performPrimaryAction()
    model.connectionCelebrationFinished()
    model.nativeSetupWiFiSubmitted()
    await model.networkHandoffChanged(.wifiAvailable)
    #expect(model.state.phase == .rediscovering)

    await model.rediscoveryTimeoutTask?.value

    #expect(
        model.state.issue == .sparkNotFoundAfterSetup,
        "the search ends in something actionable"
    )
}

@MainActor
@Test func correctingTheSparkNameResumesTheSearchAndFindsIt() async {
    let model = RetailOnboardingModel(
        networkJoiner: JourneyNetworkJoiner(),
        currentWiFiReader: JourneyWiFiReader(ssid: "Home WiFi"),
        oobeServiceFactory: { _ in JourneyOOBEService() },
        rediscoveryTimeout: .milliseconds(1),
        sleep: { _ in }
    )
    model.startAddingSpark()
    model.setupSSID = "spark-typo"
    model.setupPassphrase = "correct-horse"
    await model.performPrimaryAction()
    model.connectionCelebrationFinished()
    model.nativeSetupWiFiSubmitted()
    await model.networkHandoffChanged(.wifiAvailable)
    await model.rediscoveryTimeoutTask?.value
    #expect(model.state.issue == .sparkNotFoundAfterSetup)

    // The name on the Quick Start card, corrected in the recovery screen.
    model.machineName = "spark-a1b2"
    model.retry()
    #expect(model.state.phase == .rediscovering)
    #expect(model.state.issue == nil)

    await model.bootstrapCandidatesChanged([
        BootstrapSpark(
            displayName: "spark-a1b2",
            endpoint: .hostPort(host: "spark-a1b2.local", port: 22)
        )
    ])

    #expect(model.state.phase == .sparkRestarting, "the corrected name finds the Spark")
}

@MainActor
@Test func finishingNVIDIASetupOnTheSparkItselfIsNotADeadEnd() async {
    // Advance onboarding when the owner completed first boot on an attached display.
    let joiner = JourneyNetworkJoiner()
    joiner.resolvedSSID = "spark-a1b2"
    let wifiReader = JourneyWiFiReader(ssid: "spark-a1b2")
    let model = RetailOnboardingModel(
        networkJoiner: joiner,
        currentWiFiReader: wifiReader,
        oobeServiceFactory: { _ in JourneyOOBEService() }
    )
    model.startAddingSpark()
    model.setupSSID = "spark"
    model.setupPassphrase = "correct-horse"
    await model.performPrimaryAction()
    model.connectionCelebrationFinished()
    #expect(model.state.phase == .nvidiaSetup)

    model.performSecondaryAction()

    #expect(model.state.phase == .reconnecting)
    #expect(joiner.forgottenSSID == nil)

    wifiReader.ssid = "Home WiFi"
    await model.networkHandoffChanged(.wifiAvailable)

    #expect(model.state.phase == .rediscovering)
    #expect(
        joiner.forgottenSSID == "spark-a1b2",
        "only a confirmed handoff forgets the network actually joined"
    )
}

/// §12.2: a refused local-network permission has a recovery path, not an empty list for ever.
@Test func aDeniedLocalNetworkShowsRecoveryRatherThanAnEmptyNearbyList() {
    #expect(
        AddSparkDiscoveryState.resolve(permission: .denied, nodeCount: 0) == .permissionDenied
    )
    #expect(
        AddSparkDiscoveryState.resolve(permission: .denied, nodeCount: 3) == .permissionDenied,
        "a stale cached result must not hide the refusal"
    )
    #expect(AddSparkDiscoveryState.resolve(permission: .granted, nodeCount: 0) == .searching)
    #expect(AddSparkDiscoveryState.resolve(permission: .notDetermined, nodeCount: 0) == .searching)
    #expect(AddSparkDiscoveryState.resolve(permission: .granted, nodeCount: 1) == .found)
}
