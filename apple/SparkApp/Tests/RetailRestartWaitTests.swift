import Foundation
import Network
import SparkBootstrap
import SparkCore
import SparkDiscovery
import Testing

@testable import SparkAppComposition

/// Factory-reset setup must await restart, prove the home Wi-Fi join and retain credentials across transient failures.

@MainActor
private final class RestartTestJoiner: SetupNetworkJoining {
    var canJoinSetupNetwork = true
    private(set) var forgottenSSID: String?
    func join(_ credentials: SetupNetworkCredentials) async throws -> String {
        credentials.exactSSID ?? "spark-a1b2"
    }
    func forget(ssid: String) { forgottenSSID = ssid }
}

/// The network this device is on, changeable mid-test to stand in for the phone moving off the hotspot.
@MainActor
private final class RestartTestWiFiReader: CurrentWiFiNetworkReading {
    var ssid: String?
    init(ssid: String?) { self.ssid = ssid }
    func currentSSID() async -> String? { ssid }
    func currentSSID(requestingPermission: Bool) async -> String? { ssid }
}

private actor RestartTestOOBE: SparkOOBEServicing {
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

/// Answers the read-only survey only after a set number of misses, the way a restarting Spark does.
private actor RestartTestInstaller: RuntimeBootstrapInstalling {
    private(set) var preflightCount = 0
    private(set) var installCount = 0
    private(set) var installPasswords: [String] = []
    private var missesBeforeAnswering: Int
    private let probeFailure: any Error
    private let installFailure: (any Error)?

    init(
        missesBeforeAnswering: Int = 0,
        probeFailure: any Error = SparkBootstrap.RuntimeBootstrapError.ssh(
            .connectionFailed("connection refused")
        ),
        installFailure: (any Error)? = nil
    ) {
        self.missesBeforeAnswering = missesBeforeAnswering
        self.probeFailure = probeFailure
        self.installFailure = installFailure
    }

    func answerFromNowOn() { missesBeforeAnswering = 0 }

    func preflight(
        on target: BootstrapSpark,
        administratorUsername: String?,
        administratorPassword: String
    ) async throws -> HostPreflight {
        preflightCount += 1
        if missesBeforeAnswering > 0 {
            missesBeforeAnswering -= 1
            throw probeFailure
        }
        return HostPreflight(survey: HostSurvey.parse("survey=1\nos=DGX OS 7.2\n"))
    }

    func install(
        on target: BootstrapSpark,
        administratorPassword: String
    ) async throws -> RuntimeBootstrapResult {
        installCount += 1
        installPasswords.append(administratorPassword)
        if let installFailure { throw installFailure }
        return firstOwnerFlowTestBootstrapResult()
    }
}

/// Advance a fake clock for restart waits; background timers pause briefly without advancing it.
private final class RestartTestClock: @unchecked Sendable {
    static let backgroundWait: Duration = .seconds(3600)

    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)
    private var pauses: [Duration] = []

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func sleep(_ duration: Duration) async throws {
        if duration >= Self.backgroundWait {
            try await Task.sleep(for: .milliseconds(1))
            return
        }
        record(duration)
        await Task.yield()
    }

    private func record(_ duration: Duration) {
        lock.withLock {
            pauses.append(duration)
            current = current.addingTimeInterval(
                Double(duration.components.seconds)
                    + Double(duration.components.attoseconds) / 1e18
            )
        }
    }

    var recordedPauses: [Duration] {
        lock.lock()
        defer { lock.unlock() }
        return pauses
    }
}

/// What the Spark's SSH port answers over time: the last value repeats.
private final class RestartTestReachability: @unchecked Sendable {
    private let lock = NSLock()
    private var script: [Bool]
    private(set) var probes = 0
    init(_ script: [Bool]) { self.script = script }
    func probe(_ target: BootstrapSpark) async -> Bool { next() }

    private func next() -> Bool {
        lock.withLock {
            probes += 1
            if script.count > 1 { return script.removeFirst() }
            return script.first ?? true
        }
    }
}

private struct RestartTestHarness {
    let model: RetailOnboardingModel
    let joiner: RestartTestJoiner
    let wifi: RestartTestWiFiReader
    let installer: RestartTestInstaller
    let oobe: RestartTestOOBE
    let clock: RestartTestClock
}

private let sparkOnTheHomeNetwork = BootstrapSpark(
    displayName: "spark-a1b2",
    endpoint: .hostPort(host: "spark-a1b2.local", port: 22)
)

/// A flow that has submitted Wi-Fi in NVIDIA setup and is waiting to see the Spark on the home network.
@MainActor
private func harnessAwaitingHandoff(
    phoneOn ssid: String?,
    installer: RestartTestInstaller = RestartTestInstaller(),
    hostKeyStore: any HostKeyStore = InMemoryHostKeyStore(),
    reachability: RestartTestReachability = RestartTestReachability([true, false, false, true]),
    restartHold: Duration = .seconds(120),
    restartLimit: Duration = .seconds(600)
) async -> RestartTestHarness {
    let joiner = RestartTestJoiner()
    let wifi = RestartTestWiFiReader(ssid: ssid)
    let oobe = RestartTestOOBE()
    let clock = RestartTestClock()
    let model = RetailOnboardingModel(
        networkJoiner: joiner,
        currentWiFiReader: wifi,
        runtimeInstaller: installer,
        hostKeyStore: hostKeyStore,
        sshReachability: { await reachability.probe($0) },
        pairingService: FirstOwnerFlowTestFakePairingService(),
        oobeServiceFactory: { _ in oobe },
        // The handoff timer and the search limit are background waits here; the tests drive the checks directly.
        rediscoveryTimeout: RestartTestClock.backgroundWait,
        restartHold: restartHold,
        restartLimit: restartLimit,
        restartProbeInterval: .seconds(5),
        handoffPollInterval: RestartTestClock.backgroundWait,
        sleep: { try await clock.sleep($0) },
        now: { clock.now() }
    )
    model.startAddingSpark()
    model.setupSSID = "spark-a1b2"
    model.setupPassphrase = "correct-horse"
    await model.performPrimaryAction()
    model.connectionCelebrationFinished()
    model.administratorUsername = "alex"
    model.administratorPassword = "hunter2"
    model.nativeSetupWiFiSubmitted()
    return RestartTestHarness(
        model: model,
        joiner: joiner,
        wifi: wifi,
        installer: installer,
        oobe: oobe,
        clock: clock
    )
}

/// The same flow taken through NVIDIA wrap-up, so the Spark is now restarting.
@MainActor
private func harnessWithSparkRestarting(
    installer: RestartTestInstaller = RestartTestInstaller(),
    hostKeyStore: any HostKeyStore = InMemoryHostKeyStore(),
    reachability: RestartTestReachability = RestartTestReachability([true, false, false, true]),
    restartHold: Duration = .seconds(120),
    restartLimit: Duration = .seconds(600)
) async -> RestartTestHarness {
    let harness = await harnessAwaitingHandoff(
        phoneOn: "Home WiFi",
        installer: installer,
        hostKeyStore: hostKeyStore,
        reachability: reachability,
        restartHold: restartHold,
        restartLimit: restartLimit
    )
    await harness.model.networkHandoffChanged(.wifiAvailable)
    await harness.model.bootstrapCandidatesChanged([sparkOnTheHomeNetwork])
    #expect(harness.model.state.phase == .sparkRestarting)
    return harness
}

// MARK: - Fix 1: the Wi-Fi join is proved by the Spark answering on the home network

@MainActor
@Test func theSparkAnsweringOnTheHomeNetworkProvesItJoinedTheWiFi() async {
    let harness = await harnessAwaitingHandoff(phoneOn: "Home WiFi")
    #expect(harness.model.state.phase == .reconnecting)

    // No path change was ever reported; the Spark simply appeared by name on the home network.
    await harness.model.bootstrapCandidatesChanged([sparkOnTheHomeNetwork])

    #expect(harness.joiner.forgottenSSID == "spark-a1b2", "the setup association is released")
    #expect(await harness.oobe.didFinish, "NVIDIA wrap-up runs once the Spark is reachable")
    #expect(harness.model.state.phase == .sparkRestarting)
}

@MainActor
@Test func theSparkSeenOverItsOwnHotspotDoesNotProveTheJoin() async {
    let harness = await harnessAwaitingHandoff(phoneOn: "spark-a1b2")

    await harness.model.bootstrapCandidatesChanged([sparkOnTheHomeNetwork])

    #expect(harness.model.state.phase == .reconnecting)
    #expect(harness.model.sparkSetupNetworkStillActive)
    #expect(harness.joiner.forgottenSSID == nil)
    #expect(await harness.oobe.didFinish == false)
}

@MainActor
@Test func thePhoneMovingOffTheHotspotIsNoticedWithoutAPathChange() async {
    let harness = await harnessAwaitingHandoff(phoneOn: "spark-a1b2")
    await harness.model.networkHandoffChanged(.wifiAvailable)
    #expect(harness.model.sparkSetupNetworkStillActive)

    // The path monitor stays at "Wi-Fi available" across the move; only the SSID differs now.
    harness.wifi.ssid = "Home WiFi"
    await harness.model.networkHandoffChanged(.wifiAvailable)

    #expect(harness.model.state.phase == .rediscovering)
    #expect(!harness.model.sparkSetupNetworkStillActive)
    #expect(harness.joiner.forgottenSSID == "spark-a1b2")
}

@MainActor
@Test func theReconnectingScreenReChecksTheNetworkOnATimer() async {
    let joiner = RestartTestJoiner()
    let wifi = RestartTestWiFiReader(ssid: "spark-a1b2")
    let model = RetailOnboardingModel(
        networkJoiner: joiner,
        currentWiFiReader: wifi,
        runtimeInstaller: RestartTestInstaller(),
        oobeServiceFactory: { _ in RestartTestOOBE() },
        handoffPollInterval: .milliseconds(5)
    )
    model.startAddingSpark()
    model.setupSSID = "spark-a1b2"
    model.setupPassphrase = "correct-horse"
    await model.performPrimaryAction()
    model.connectionCelebrationFinished()
    model.nativeSetupWiFiSubmitted()
    #expect(model.state.phase == .reconnecting)

    wifi.ssid = "Home WiFi"
    model.handoffMonitor.start()

    let movedOn = await firstOwnerFlowTestSettles { model.state.phase == .rediscovering }
    #expect(movedOn, "the timer alone must carry the flow forward once the SSID changed")
    #expect(joiner.forgottenSSID == "spark-a1b2")
}

// MARK: - Fix 2 and 4: the restart is waited out and nothing is installed until the Spark answers

@MainActor
@Test func theRestartIsWatchedRatherThanWaitedOut() async {
    let installer = RestartTestInstaller(missesBeforeAnswering: 2)
    // Up, then gone for two polls, then back: a reboot seen from the network.
    let reachability = RestartTestReachability([true, false, false, true])
    let harness = await harnessWithSparkRestarting(installer: installer, reachability: reachability)

    await harness.model.awaitSparkRestart()

    #expect(harness.model.state.phase == .runtimeInstall)
    #expect(harness.model.state.issue == nil)
    #expect(harness.model.restartStage == .checking)
    #expect(reachability.probes == 4, "polled until it went, then until it came back")
    #expect(
        await installer.preflightCount == 3,
        "two survey misses after it came back, then an answer"
    )
    #expect(await installer.installCount == 0, "the install step decides, not the wait")
    let pauses = harness.clock.recordedPauses
    #expect(
        pauses.allSatisfy { $0 == .seconds(5) },
        "no fixed hold once the restart was seen: \(pauses)"
    )
    #expect(pauses.count == 4, "two waits while watching the port, two after survey misses")
    #expect(
        harness.model.administratorPassword == "hunter2",
        "the account password is kept throughout"
    )
}

@MainActor
@Test func aSparkNeverSeenToRestartIsCheckedOnceTheHoldRunsOut() async {
    let installer = RestartTestInstaller()
    let reachability = RestartTestReachability([true])
    let harness = await harnessWithSparkRestarting(
        installer: installer,
        reachability: reachability,
        restartHold: .seconds(20)
    )

    await harness.model.awaitSparkRestart()

    #expect(harness.model.state.phase == .runtimeInstall)
    #expect(reachability.probes == 4, "polled every five seconds until the hold passed")
    #expect(await installer.preflightCount == 1)
    #expect(harness.clock.recordedPauses.count == 4)
}

@MainActor
@Test func theWaitingScreenShowsItsClockAndTheLastMiss() async {
    let installer = RestartTestInstaller(missesBeforeAnswering: 1)
    let harness = await harnessWithSparkRestarting(installer: installer)
    #expect(harness.model.restartStartedAt == nil)
    #expect(harness.model.restartHold == .seconds(120))
    #expect(harness.model.restartLimit == .seconds(600))

    await harness.model.checkSparkIsBack()

    #expect(harness.model.state.phase == .sparkRestarting, "one miss keeps the wait going")
    #expect(harness.model.restartCheckDetail != nil, "the miss is explained on the same screen")
    #expect(harness.model.restartStartedAt == nil, "the manual check does not start the clock")

    await harness.model.awaitSparkRestart()
    #expect(harness.model.state.phase == .runtimeInstall)
}

@MainActor
@Test func theOwnerCanSayTheSparkIsBackAndSkipTheHold() async {
    let installer = RestartTestInstaller()
    let harness = await harnessWithSparkRestarting(installer: installer)

    await harness.model.checkSparkIsBack()

    #expect(harness.model.state.phase == .runtimeInstall)
    #expect(harness.clock.recordedPauses.isEmpty, "no hold when the owner says it is back")
    #expect(await installer.preflightCount == 1)
}

@MainActor
@Test func theRestartWaitGivesUpAfterItsLimitAndCanBeRetried() async {
    let installer = RestartTestInstaller(missesBeforeAnswering: 1_000)
    // Gone and never back: the wait must give up at its limit, not spin.
    let harness = await harnessWithSparkRestarting(
        installer: installer,
        reachability: RestartTestReachability([true, false]),
        restartHold: .seconds(600),
        restartLimit: .seconds(20)
    )

    await harness.model.awaitSparkRestart()

    #expect(harness.model.state.issue == .sparkNotBackAfterRestart)
    #expect(harness.model.failureDetail != nil)
    #expect(await installer.installCount == 0)
    #expect(await installer.preflightCount == 0, "no login is tried while its port is silent")

    await installer.answerFromNowOn()
    harness.model.retry()

    let back = await firstOwnerFlowTestSettles { harness.model.state.phase == .runtimeInstall }
    #expect(back, "Check Again resumes the wait and the Spark's answer moves the flow on")
    #expect(harness.model.state.issue == nil)
}

@MainActor
@Test func aRejectedPasswordAfterTheRestartIsAskedForOnTheInstallStep() async {
    let installer = RestartTestInstaller(
        missesBeforeAnswering: 1_000,
        probeFailure: SparkBootstrap.RuntimeBootstrapError.ssh(.authenticationFailed)
    )
    let harness = await harnessWithSparkRestarting(installer: installer)

    await harness.model.checkSparkIsBack()

    #expect(harness.model.state.phase == .runtimeInstall, "the Spark is up; only the login failed")
    #expect(harness.model.state.issue == .runtimeInstallFailed)
    #expect(harness.model.administratorPassword.isEmpty, "a rejected password is not kept")
    #expect(harness.model.failureDetail?.localizedCaseInsensitiveContains("password") == true)
}

// MARK: - A factory reset gives the Spark new SSH keys

private let oldHostKey = SSHHostKeyFingerprint(keyType: "ssh-ed25519", value: "old")
private let newHostKey = SSHHostKeyFingerprint(keyType: "ssh-ed25519", value: "new")

@MainActor
@Test func theOldHostKeyIsForgottenOnceFirstBootRanOnThisDevice() async throws {
    let store = InMemoryHostKeyStore(entries: ["spark-a1b2.local": oldHostKey])
    let harness = await harnessWithSparkRestarting(hostKeyStore: store)

    await harness.model.checkSparkIsBack()

    #expect(harness.model.state.phase == .runtimeInstall)
    #expect(
        try store.fingerprint(forHost: "spark-a1b2.local") == nil,
        "the record from before the reset would refuse the Spark's new key"
    )
}

@MainActor
@Test func aChangedHostKeyIsExplainedAndCanBeTrusted() async throws {
    let store = InMemoryHostKeyStore(entries: ["hostkey-fixture.local": oldHostKey])
    let installer = RestartTestInstaller(
        missesBeforeAnswering: 1_000,
        probeFailure: SparkBootstrap.RuntimeBootstrapError.ssh(
            .hostKey(
                .changed(host: "hostkey-fixture.local", expected: oldHostKey, presented: newHostKey)
            )
        )
    )
    // Use a unique library host; interrupted setup must retain trust until the owner explicitly resets it.
    let model = RetailOnboardingModel(runtimeInstaller: installer, hostKeyStore: store)
    model.chooseSparkToAdd()
    _ = model.chooseExistingSpark(host: "hostkey-fixture.local")
    model.finishInterruptedFirstOwnerSetup()
    model.administratorUsername = "alex"
    model.administratorPassword = "hunter2"
    #expect(model.state.phase == .runtimeInstall)

    await model.checkExistingSpark()

    #expect(model.changedHostKeyHost == "hostkey-fixture.local")
    #expect(model.preflightError?.localizedCaseInsensitiveContains("identity has changed") == true)
    #expect(
        try store.fingerprint(forHost: "hostkey-fixture.local") == oldHostKey,
        "not dropped on its own"
    )

    await installer.answerFromNowOn()
    await model.trustNewHostKey()

    #expect(try store.fingerprint(forHost: "hostkey-fixture.local") == nil)
    #expect(model.changedHostKeyHost == nil)
    #expect(model.hostPreflight != nil, "the check is repeated once the old key is gone")
}

// MARK: - Fix 3: the account password survives a transient failure of the install itself

@MainActor
@Test func aTransientInstallFailureKeepsThePasswordForTheRetry() async {
    let installer = RestartTestInstaller(
        installFailure: SparkBootstrap.RuntimeBootstrapError.ssh(.noExitStatus)
    )
    let harness = await harnessWithSparkRestarting(installer: installer)
    await harness.model.checkSparkIsBack()
    let preparation = RetailOnboardingPreparationModel()

    await harness.model.performPrimaryAction(preparation: preparation)

    #expect(harness.model.state.issue == .runtimeInstallFailed)
    #expect(harness.model.administratorPassword == "hunter2", "the Spark did not reject it")
    #expect(harness.model.failureDetail != nil)

    harness.model.retry(preparation: preparation)
    let retried = await firstOwnerFlowTestSettles { await installer.installCount == 2 }
    #expect(retried, "Try Again reinstalls with the retained password, no form in between")
    #expect(await installer.installPasswords == ["hunter2", "hunter2"])
}

@MainActor
@Test func aPasswordTheSparkRejectsDuringInstallIsReleased() async {
    let installer = RestartTestInstaller(
        installFailure: SparkBootstrap.RuntimeBootstrapError.ssh(.authenticationFailed)
    )
    let harness = await harnessWithSparkRestarting(installer: installer)
    await harness.model.checkSparkIsBack()

    await harness.model.performPrimaryAction(preparation: RetailOnboardingPreparationModel())

    #expect(harness.model.state.issue == .runtimeInstallFailed)
    #expect(harness.model.administratorPassword.isEmpty)
    #expect(harness.model.failureDetail?.localizedCaseInsensitiveContains("password") == true)
}

@MainActor
@Test func cancellingSetupStopsTheRestartWait() async {
    let installer = RestartTestInstaller(missesBeforeAnswering: 1_000)
    let harness = await harnessWithSparkRestarting(installer: installer)
    let waiting = Task { await harness.model.awaitSparkRestart() }
    await Task.yield()

    harness.model.startAddingSpark()
    await waiting.value

    #expect(harness.model.state.phase == .connectToSpark)
    #expect(harness.model.restartStartedAt == nil)
}
