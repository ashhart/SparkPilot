import Foundation
import Network
import SparkCore
import SparkBootstrap
import SparkDiscovery
import Testing
@testable import SparkAppComposition

@MainActor
private final class FakeNetworkJoiner: SetupNetworkJoining {
    var canJoinSetupNetwork = true
    var requestedMatch: SetupNetworkMatch?
    var joinedSSID: String?
    var forgottenSSID: String?
    /// Resolve the final joined network independently of the supplied prefix.
    var resolvedSSID: String?
    var joinError: (any Error)?

    @discardableResult
    func join(_ credentials: SetupNetworkCredentials) async throws -> String {
        requestedMatch = credentials.match
        if let joinError { throw joinError }
        let joined =
            resolvedSSID
            ?? credentials.exactSSID
            ?? {
                if case .ssidPrefix(let prefix) = credentials.match { return prefix }
                return ""
            }()
        joinedSSID = joined
        return joined
    }

    func forget(ssid: String) {
        forgottenSSID = ssid
    }
}

@MainActor
private final class FakeCurrentWiFiReader: CurrentWiFiNetworkReading {
    let ssid: String?
    private(set) var permissionRequests = 0

    init(ssid: String?) {
        self.ssid = ssid
    }

    func currentSSID() async -> String? {
        permissionRequests += 1
        return ssid
    }

    func currentSSID(requestingPermission: Bool) async -> String? {
        if requestingPermission { permissionRequests += 1 }
        return ssid
    }
}

/// Opening Add Spark must never trigger the location prompt; only the setup route may (M-2).
@MainActor
@Test func detectingAnExistingConnectionNeverAsksForLocation() async {
    let reader = FakeCurrentWiFiReader(ssid: "spark-a1b2")
    let model = RetailOnboardingModel(
        networkJoiner: FakeNetworkJoiner(),
        currentWiFiReader: reader,
        runtimeInstaller: UnusedInstaller()
    )

    await model.detectExistingSparkConnection()

    #expect(model.state.phase == .sparkConnected)
    #expect(reader.permissionRequests == 0)
}

/// Fails if installation is reached in tests intended to exercise pre-installation navigation.
private struct UnusedInstaller: RuntimeBootstrapInstalling {
    struct NotExpected: Error {}
    func install(
        on target: BootstrapSpark,
        administratorPassword: String
    ) async throws -> RuntimeBootstrapResult {
        throw NotExpected()
    }
}

/// The base URLs handed to the OOBE service factory, readable after the flow has run.
private final class RecordedFactoryURLs: @unchecked Sendable {
    var urls: [URL] = []
}

private actor FakeOOBEFinisher: SparkOOBEServicing {
    private(set) var didFinish = false

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
    func finishSetup() async throws { didFinish = true }
}

@MainActor
@Test func addSparkFlowStartsOnlyAfterTheOwnerChoosesIt() {
    let model = RetailOnboardingModel(
        networkJoiner: FakeNetworkJoiner(),
        runtimeInstaller: UnusedInstaller()
    )

    #expect(!model.isAddingSpark)

    model.startAddingSpark()

    #expect(model.isAddingSpark)
    #expect(model.state.phase == .connectToSpark)
}

@MainActor
@Test func cancellingAddSparkReturnsToTheChoiceAndClearsSetupDetails() {
    let model = RetailOnboardingModel(
        networkJoiner: FakeNetworkJoiner(),
        runtimeInstaller: UnusedInstaller()
    )
    model.startAddingSpark()
    model.setupSSID = "spark-a1b2"
    model.setupPassphrase = "correct-horse"

    model.cancelAddingSpark()

    #expect(!model.isAddingSpark)
    #expect(model.isChoosingSpark, "back lands on the screen this was chosen from")
    #expect(model.setupSSID.isEmpty)
    #expect(model.setupPassphrase.isEmpty)
    #expect(model.state.phase == .connectToSpark)
}

@MainActor
@Test func successfulHotspotJoinClearsThePassphrase() async {
    let joiner = FakeNetworkJoiner()
    let model = RetailOnboardingModel(
        networkJoiner: joiner,
        runtimeInstaller: UnusedInstaller()
    )

    model.setupSSID = "DGX-Spark-A1B2"
    model.setupPassphrase = "correct-horse"

    await model.performPrimaryAction()

    #expect(model.state.phase == .sparkConnected)
    #expect(joiner.joinedSSID == "DGX-Spark-A1B2")
    #expect(model.setupPassphrase.isEmpty)
}

@MainActor
@Test func hotspotJoinDerivesSetupPageAndShowsConnectedState() async {
    let joiner = FakeNetworkJoiner()
    let model = RetailOnboardingModel(
        networkJoiner: joiner,
        runtimeInstaller: UnusedInstaller()
    )
    model.setupSSID = "spark-a1b2"
    model.setupPassphrase = "correct-horse"

    await model.performPrimaryAction()

    #expect(model.state.phase == .sparkConnected)
    #expect(model.machineName == "spark-a1b2")
    #expect(model.nvidiaSetupURL == URL(string: "http://spark-a1b2.local"))
}

@MainActor
@Test func alreadyConnectedSparkSkipsTheCredentialForm() async {
    let model = RetailOnboardingModel(
        networkJoiner: FakeNetworkJoiner(),
        currentWiFiReader: FakeCurrentWiFiReader(ssid: "spark-a1b2"),
        runtimeInstaller: UnusedInstaller()
    )

    await model.detectExistingSparkConnection()

    #expect(model.state.phase == .sparkConnected)
    #expect(model.setupSSID == "spark-a1b2")
    #expect(model.machineName == "spark-a1b2")
    #expect(model.nvidiaSetupURL == URL(string: "http://spark-a1b2.local"))
}

@MainActor
@Test func ordinaryWiFiDoesNotPretendToBeASpark() async {
    let model = RetailOnboardingModel(
        networkJoiner: FakeNetworkJoiner(),
        currentWiFiReader: FakeCurrentWiFiReader(ssid: "Home WiFi"),
        runtimeInstaller: UnusedInstaller()
    )

    await model.detectExistingSparkConnection()

    #expect(model.state.phase == .connectToSpark)
}

@MainActor
@Test func submittingNativeWiFiMovesToNetworkHandoff() async {
    let joiner = FakeNetworkJoiner()
    let model = RetailOnboardingModel(
        networkJoiner: joiner,
        runtimeInstaller: UnusedInstaller()
    )

    model.setupSSID = "DGX-Spark-A1B2"
    model.setupPassphrase = "correct-horse"
    await model.performPrimaryAction()
    model.connectionCelebrationFinished()

    model.nativeSetupWiFiSubmitted()

    #expect(model.state.phase == .reconnecting)
    #expect(joiner.forgottenSSID == nil)
}

@MainActor
@Test func theCreatedAccountBecomesTheSSHAdministrator() async throws {
    let service = FakeOOBEFinisher()
    let model = RetailOnboardingModel(
        networkJoiner: FakeNetworkJoiner(),
        runtimeInstaller: UnusedInstaller(),
        oobeServiceFactory: { _ in service }
    )
    model.setupSSID = "spark-a1b2"
    model.setupPassphrase = "correct-horse"
    await model.performPrimaryAction()
    model.connectionCelebrationFinished()
    let nativeSetup = try #require(model.nativeSetupModel)
    nativeSetup.step = .account
    nativeSetup.username = "alex"
    nativeSetup.password = "correct-horse"
    nativeSetup.confirmPassword = "correct-horse"

    await nativeSetup.continueSetup()

    #expect(model.administratorUsername == "alex")
    #expect(model.administratorPassword == "correct-horse")
}

@Test func sshBootstrapRemovesTheBonjourServiceSuffixFromTheHostName() {
    let target = BootstrapSpark(
        displayName: "spark-one SSH",
        endpoint: .hostPort(host: "spark-one.local", port: 22)
    )

    #expect(SSHRuntimeBootstrapInstaller.hostName(for: target) == "spark-one.local")
}

@MainActor
@Test func phoneReturningToWiFiDoesNotProveTheSparkLeftItsHotspot() async {
    let joiner = FakeNetworkJoiner()
    let model = RetailOnboardingModel(
        networkJoiner: joiner,
        currentWiFiReader: FakeCurrentWiFiReader(ssid: "DGX-Spark-A1B2"),
        runtimeInstaller: UnusedInstaller()
    )
    model.setupSSID = "DGX-Spark-A1B2"
    model.setupPassphrase = "correct-horse"
    await model.performPrimaryAction()
    model.connectionCelebrationFinished()
    model.nativeSetupWiFiSubmitted()

    await model.networkHandoffChanged(.wifiAvailable)

    #expect(
        model.state.phase == .reconnecting,
        "remaining on the Spark hotspot means its home Wi-Fi join did not finish"
    )
    #expect(joiner.forgottenSSID == nil)
}

@MainActor
@Test func aVisibleSparkHotspotCanReturnToWiFiSelection() async throws {
    let joiner = FakeNetworkJoiner()
    let model = RetailOnboardingModel(
        networkJoiner: joiner,
        currentWiFiReader: FakeCurrentWiFiReader(ssid: "DGX-Spark-A1B2"),
        runtimeInstaller: UnusedInstaller()
    )
    model.setupSSID = "DGX-Spark-A1B2"
    model.setupPassphrase = "correct-horse"
    await model.performPrimaryAction()
    model.connectionCelebrationFinished()
    let nativeSetup = try #require(model.nativeSetupModel)
    nativeSetup.step = .connecting
    model.nativeSetupWiFiSubmitted()
    await model.networkHandoffChanged(.wifiAvailable)

    model.retrySparkWiFi()

    #expect(model.state.phase == .nvidiaSetup)
    #expect(nativeSetup.step == .wifi)
    #expect(joiner.forgottenSSID == nil)
}

@MainActor
@Test func leavingTheSparkHotspotCompletesTheNetworkHandoff() async {
    let joiner = FakeNetworkJoiner()
    let model = RetailOnboardingModel(
        networkJoiner: joiner,
        currentWiFiReader: FakeCurrentWiFiReader(ssid: "Home WiFi"),
        runtimeInstaller: UnusedInstaller()
    )
    model.setupSSID = "DGX-Spark-A1B2"
    model.setupPassphrase = "correct-horse"
    await model.performPrimaryAction()
    model.connectionCelebrationFinished()
    model.nativeSetupWiFiSubmitted()

    await model.networkHandoffChanged(.wifiAvailable)

    #expect(model.state.phase == .rediscovering)
    #expect(joiner.forgottenSSID == "DGX-Spark-A1B2")
}

/// UX-08: the wait has a clock and a Look Again that restarts the bounded search.
@MainActor
@Test func rediscoveryExposesItsClockAndCanBeRestarted() async {
    let model = RetailOnboardingModel(
        networkJoiner: FakeNetworkJoiner(),
        currentWiFiReader: FakeCurrentWiFiReader(ssid: "Home WiFi"),
        runtimeInstaller: UnusedInstaller()
    )
    #expect(model.rediscoveryStartedAt == nil)
    model.setupSSID = "DGX-Spark-A1B2"
    model.setupPassphrase = "correct-horse"
    await model.performPrimaryAction()
    model.connectionCelebrationFinished()
    model.nativeSetupWiFiSubmitted()
    await model.networkHandoffChanged(.wifiAvailable)

    let started = model.rediscoveryStartedAt
    #expect(started != nil)
    #expect(model.rediscoveryLimit == .seconds(600))

    model.lookAgainForSpark()

    #expect(model.state.phase == .rediscovering)
    #expect(model.rediscoveryStartedAt != nil)
    #expect(model.rediscoveryStartedAt! >= started!)
}

@MainActor
@Test func rediscoveryFinishesOOBEBeforeRuntimeInstall() async {
    let service = FakeOOBEFinisher()
    let model = RetailOnboardingModel(
        networkJoiner: FakeNetworkJoiner(),
        currentWiFiReader: FakeCurrentWiFiReader(ssid: "Home WiFi"),
        runtimeInstaller: UnusedInstaller(),
        oobeServiceFactory: { _ in service }
    )
    model.setupSSID = "spark-a1b2"
    model.setupPassphrase = "correct-horse"
    await model.performPrimaryAction()
    model.connectionCelebrationFinished()
    model.nativeSetupWiFiSubmitted()
    await model.networkHandoffChanged(.wifiAvailable)

    await model.bootstrapCandidatesChanged([
        BootstrapSpark(
            displayName: "spark-a1b2",
            endpoint: .hostPort(host: "spark-a1b2.local", port: 22)
        )
    ])

    #expect(await service.didFinish)
    #expect(
        model.state.phase == .sparkRestarting,
        "the Spark restarts before anything is installed"
    )
}

@MainActor
@Test func rediscoveryAcceptsTheSparksSSHBonjourServiceName() async {
    let service = FakeOOBEFinisher()
    let model = RetailOnboardingModel(
        networkJoiner: FakeNetworkJoiner(),
        currentWiFiReader: FakeCurrentWiFiReader(ssid: "Home WiFi"),
        runtimeInstaller: UnusedInstaller(),
        oobeServiceFactory: { _ in service }
    )
    model.setupSSID = "spark-a1b2"
    model.setupPassphrase = "correct-horse"
    await model.performPrimaryAction()
    model.connectionCelebrationFinished()
    model.nativeSetupWiFiSubmitted()
    await model.networkHandoffChanged(.wifiAvailable)

    await model.bootstrapCandidatesChanged([
        BootstrapSpark(
            displayName: "spark-a1b2 SSH",
            endpoint: .hostPort(host: "spark-a1b2.local", port: 22)
        )
    ])

    #expect(model.state.phase == .sparkRestarting)
}

/// A public `page` host can never receive the administrator password, typed or scanned.
@MainActor
@Test func aSetupPageOffTheSetupNetworkIsRefusedAndTheDerivedAddressIsUsed() async throws {
    let model = RetailOnboardingModel(
        networkJoiner: FakeNetworkJoiner(),
        runtimeInstaller: UnusedInstaller()
    )
    #expect(throws: QuickStartCodeError.self) {
        try model.applyQuickStartCode(
            "spark://setup?ssid=DGX-Spark-A1B2&password=correct-horse&page=http%3A%2F%2Fevil.example%2F"
        )
    }
    #expect(model.setupPage.isEmpty)
    model.setupSSID = "spark-a1b2"
    model.setupPassphrase = "correct-horse"
    model.setupPage = "http://evil.example/setup"
    await model.performPrimaryAction()
    #expect(model.state.phase == .sparkConnected)
    #expect(model.nvidiaSetupURL == URL(string: "http://spark-a1b2.local"))
}

@MainActor
@Test func aSetupPageOnTheSetupNetworkIsUsedAndACleartextPageIsAnnounced() async throws {
    let factoryURLs = RecordedFactoryURLs()
    let model = RetailOnboardingModel(
        networkJoiner: FakeNetworkJoiner(),
        runtimeInstaller: UnusedInstaller(),
        oobeServiceFactory: { url in
            factoryURLs.urls.append(url)
            return FakeOOBEFinisher()
        }
    )
    model.setupSSID = "spark-a1b2"
    model.setupPassphrase = "correct-horse"
    model.setupPage = "http://192.168.55.1/setup"
    await model.performPrimaryAction()
    #expect(model.nvidiaSetupURL == URL(string: "http://192.168.55.1/setup"))
    model.connectionCelebrationFinished()
    #expect(factoryURLs.urls == [URL(string: "http://192.168.55.1/setup")!])
    let notice = try #require(model.nativeSetupModel?.transportNotice)
    #expect(notice == NativeSparkSetupPresentation.unencryptedTransportNotice)
    #expect(notice.contains("not encrypted"))
}

@MainActor
@Test func anEncryptedSetupPageCarriesNoCleartextNotice() async throws {
    let model = RetailOnboardingModel(
        networkJoiner: FakeNetworkJoiner(),
        runtimeInstaller: UnusedInstaller(),
        oobeServiceFactory: { _ in FakeOOBEFinisher() }
    )
    model.setupSSID = "spark-a1b2"
    model.setupPassphrase = "correct-horse"
    model.setupPage = "https://spark-a1b2.local/"
    await model.performPrimaryAction()
    model.connectionCelebrationFinished()
    #expect(model.nvidiaSetupURL == URL(string: "https://spark-a1b2.local/"))
    #expect(try #require(model.nativeSetupModel).transportNotice == nil)
}

@MainActor
@Test func quickStartCodePopulatesOnlySetupFields() throws {
    let model = RetailOnboardingModel(
        networkJoiner: FakeNetworkJoiner(),
        runtimeInstaller: UnusedInstaller()
    )
    try model.applyQuickStartCode(
        "spark://setup?ssid=DGX-Spark-A1B2&password=correct-horse&page=http%3A%2F%2F192.168.55.1%2Fsetup"
    )

    #expect(model.setupSSID == "DGX-Spark-A1B2")
    #expect(model.setupPassphrase == "correct-horse")
    #expect(model.setupPage == "http://192.168.55.1/setup")
    #expect(model.administratorPassword.isEmpty)
}
