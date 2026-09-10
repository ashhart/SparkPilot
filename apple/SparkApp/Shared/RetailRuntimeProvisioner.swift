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
final class RetailRuntimeProvisioner {
    var hostPreflight: HostPreflight?
    var preflightError: String?
    var isCheckingSpark = false
    private var checkID = UUID()
    var installBlockedBy: [PreflightConflict] = []
    /// When the restart wait began, for the countdown and clock on the waiting screen.
    var restartStartedAt: Date?
    var isCheckingRestart = false
    /// What the last restart check said, shown while the wait continues.
    var restartCheckDetail: String?
    /// Where the wait has got to: watching for the restart, restarting, or checking the Spark.
    var restartStage: RetailRestartStage = .waitingForRestart
    private var restartGeneration = 0
    let restartHold: Duration
    let restartLimit: Duration
    let restartProbeInterval: Duration
    /// The host whose recorded SSH identity no longer matches, until the owner trusts the new one.
    var changedHostKeyHost: String?
    private var hasForgottenHostKeyForThisSetup = false
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: @Sendable () -> Date
    private let session: RetailSetupSession
    private let runtimeInstaller: any RuntimeBootstrapInstalling
    private let hostKeyStore: any HostKeyStore
    private let reachability: @Sendable (BootstrapSpark) async -> Bool
    init(
        session: RetailSetupSession,
        runtimeInstaller: any RuntimeBootstrapInstalling,
        hostKeyStore: any HostKeyStore = InMemoryHostKeyStore(),
        reachability: @escaping @Sendable (BootstrapSpark) async -> Bool = SparkSSHReachability
            .isListening,
        restartHold: Duration = .seconds(120),
        restartLimit: Duration = .seconds(600),
        restartProbeInterval: Duration = .seconds(5),
        sleep: @escaping @Sendable (Duration) async throws -> Void = RetailOnboardingClock.sleep,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.session = session
        self.runtimeInstaller = runtimeInstaller
        self.hostKeyStore = hostKeyStore
        self.reachability = reachability
        self.restartHold = restartHold
        self.restartLimit = restartLimit
        self.restartProbeInterval = restartProbeInterval
        self.sleep = sleep
        self.now = now
    }
    private var state: RetailOnboardingState {
        get { session.state }
        set { session.state = newValue }
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
    private var bootstrapResult: RuntimeBootstrapResult? {
        get { session.bootstrapResult }
        set { session.bootstrapResult = newValue }
    }
    private func send(_ event: RetailOnboardingEvent) { session.send(event) }

    /// Show the pre-install survey separately from consent; the installer repeats its own mandatory preflight.
    func checkExistingSpark() async {
        guard !isCheckingSpark, let bootstrapTarget else { return }
        let attempt = UUID()
        checkID = attempt
        isCheckingSpark = true
        preflightError = nil
        installBlockedBy = []
        defer { if checkID == attempt { isCheckingSpark = false } }
        do {
            let report = try await runtimeInstaller.preflight(
                on: bootstrapTarget,
                administratorUsername: administratorUsername,
                administratorPassword: administratorPassword
            )
            guard checkID == attempt, self.bootstrapTarget?.id == bootstrapTarget.id else { return }
            hostPreflight = report
        } catch {
            guard checkID == attempt, self.bootstrapTarget?.id == bootstrapTarget.id else { return }
            // Discard the stale report when the current preflight cannot be read.
            hostPreflight = nil
            noteChangedHostKey(in: error)
            preflightError = RetailOnboardingFailurePresentation.describe(preflightError: error)
        }
    }

    /// Require review of an unchecked existing Spark; the installer's preflight independently enforces safety.
    var needsExistingSparkReview: Bool {
        state.phase == .runtimeInstall && hostPreflight == nil && preflightError == nil
            && installBlockedBy.isEmpty
    }

    /// The report to show, or `nil` when there is nothing to show yet.
    var existingSparkReport: ExistingSparkPreflightPresentation? {
        if let hostPreflight {
            return ExistingSparkPreflightPresentation(preflight: hostPreflight)
        }
        if !installBlockedBy.isEmpty {
            return ExistingSparkPreflightPresentation(blockedBy: installBlockedBy)
        }
        if preflightError != nil {
            return ExistingSparkPreflightPresentation(checkFailed: true)
        }
        return nil
    }

    /// A machine this device just took through NVIDIA first boot has new SSH keys; its old record must not block it.
    private func forgetHostKeyAfterFirstBoot() {
        guard !hasForgottenHostKeyForThisSetup,
            state.completedPhases.contains(.finishingSparkSetup),
            let bootstrapTarget
        else { return }
        hasForgottenHostKeyForThisSetup = true
        try? hostKeyStore.forget(host: SSHRuntimeBootstrapInstaller.hostName(for: bootstrapTarget))
    }

    /// Remember which host presented a different key so the owner can decide to trust the new one.
    private func noteChangedHostKey(in error: any Error) {
        changedHostKeyHost = RetailOnboardingFailurePresentation.changedHostKeyHost(in: error)
    }

    /// The owner says this Spark was reset: drop the old record so the next connection asks about the new key.
    func trustNewHostKey() {
        guard let changedHostKeyHost else { return }
        try? hostKeyStore.forget(host: changedHostKeyHost)
        self.changedHostKeyHost = nil
        restartCheckDetail = nil
    }

    /// Wait for restart and readiness without installing; use the timed hold only if no restart is observed.
    func awaitSparkRestart(holdFirst: Bool = true) async {
        guard state.phase == .sparkRestarting, state.issue == nil else { return }
        forgetHostKeyAfterFirstBoot()
        restartGeneration &+= 1
        let generation = restartGeneration
        // A resumed wait keeps its original clock; a retry after the limit starts a fresh one.
        let startedAt = holdFirst ? (restartStartedAt ?? now()) : now()
        restartStartedAt = startedAt
        restartCheckDetail = nil
        restartStage = holdFirst ? .waitingForRestart : .checking
        let holdSeconds = Double(restartHold.components.seconds)
        let limitSeconds = Double(restartLimit.components.seconds)
        func stillWaiting() -> Bool {
            restartGeneration == generation && state.phase == .sparkRestarting
                && state.issue == nil
        }
        func pause() async -> Bool {
            do {
                try await sleep(restartProbeInterval)
                return true
            } catch {
                return false
            }
        }
        if holdFirst, let bootstrapTarget {
            // The Spark dropping off the network is the restart beginning.
            while stillWaiting(), restartStage == .waitingForRestart {
                if now().timeIntervalSince(startedAt) >= holdSeconds {
                    restartStage = .checking
                    break
                }
                if await reachability(bootstrapTarget) == false {
                    restartStage = .restarting
                    break
                }
                guard await pause() else { return }
            }
            // Its SSH port answering again is the restart ending; only then is a login worth trying.
            while stillWaiting(), restartStage == .restarting {
                if await reachability(bootstrapTarget) {
                    restartStage = .checking
                    break
                }
                if now().timeIntervalSince(startedAt) >= limitSeconds {
                    restartCheckDetail = String(
                        localized:
                            "Your Spark went down for its restart but its SSH port has not answered since."
                    )
                    send(.failed(.sparkNotBackAfterRestart))
                    return
                }
                guard await pause() else { return }
            }
        }
        while stillWaiting() {
            if await probeSparkAfterRestart() { return }
            guard stillWaiting() else { return }
            if now().timeIntervalSince(startedAt) >= limitSeconds {
                send(.failed(.sparkNotBackAfterRestart))
                return
            }
            guard await pause() else { return }
        }
    }

    /// The owner says the Spark is back: check once now and stay here if it is not.
    func checkSparkIsBack() async {
        guard state.phase == .sparkRestarting, state.issue == nil else { return }
        forgetHostKeyAfterFirstBoot()
        _ = await probeSparkAfterRestart()
    }

    /// True once the Spark answers its read-only survey again, or is back but rejects the password.
    private func probeSparkAfterRestart() async -> Bool {
        guard !isCheckingRestart, let bootstrapTarget else { return false }
        isCheckingRestart = true
        defer { isCheckingRestart = false }
        do {
            _ = try await runtimeInstaller.preflight(
                on: bootstrapTarget,
                administratorUsername: administratorUsername,
                administratorPassword: administratorPassword
            )
            guard state.phase == .sparkRestarting, state.issue == nil else { return true }
            restartCheckDetail = nil
            send(.sparkRestarted)
            return true
        } catch {
            guard state.phase == .sparkRestarting, state.issue == nil else { return true }
            if RetailOnboardingFailurePresentation.installRejectedAdministratorPassword(error) {
                // The Spark is up; only the credential is wrong, so ask for it on the install step.
                administratorPassword = ""
                restartCheckDetail = nil
                preflightError = RetailOnboardingFailurePresentation.describe(preflightError: error)
                send(.sparkRestarted)
                send(.failed(.runtimeInstallFailed))
                return true
            }
            noteChangedHostKey(in: error)
            restartCheckDetail = RetailOnboardingFailurePresentation.describe(preflightError: error)
            return false
        }
    }

    /// Stop waiting for a restart that no longer matters, such as after cancel or reset.
    func cancelRestartWait() {
        restartGeneration &+= 1
        restartStartedAt = nil
        restartStage = .waitingForRestart
        isCheckingRestart = false
        restartCheckDetail = nil
        changedHostKeyHost = nil
        hasForgottenHostKeyForThisSetup = false
    }

    /// Discard a reading so it cannot outlive the machine it describes.
    func clearExistingSparkCheck() {
        checkID = UUID()
        isCheckingSpark = false
        hostPreflight = nil
        preflightError = nil
        installBlockedBy = []
    }

    func installRuntime(preparation: RetailOnboardingPreparationModel?) async {
        guard preparation?.isInstallingRuntime != true else { return }
        guard let bootstrapTarget else {
            send(.failed(.sparkNotFoundAfterSetup))
            return
        }
        let password = administratorPassword
        preparation?.isInstallingRuntime = true
        preparation?.runtime = RetailOnboardingPreparationModel.pendingRuntime
        updateRuntimePreparation(
            preparation: preparation,
            id: "runtime-package",
            detail: String(localized: "Downloading and verifying the signed release"),
            status: .working
        )
        defer { preparation?.isInstallingRuntime = false }
        do {
            bootstrapResult = try await runtimeInstaller.install(
                on: bootstrapTarget,
                administratorUsername: administratorUsername,
                administratorPassword: password,
                progress: { [weak self] command in
                    Task { @MainActor [weak self] in
                        self?.bootstrapWillRun(command, preparation: preparation)
                    }
                }
            )
            if let preparation {
                preparation.runtime = preparation.runtime.map {
                    RetailPreparationItem(
                        id: $0.id,
                        title: $0.title,
                        detail: $0.status == .unavailable ? $0.detail : String(localized: "Ready"),
                        status: $0.status == .unavailable ? .unavailable : .ready
                    )
                }
            }
            // Retain the SSH password only for safe pairing retries; pairing clears it on success or unsafe failure.
            send(.runtimeInstalled)
        } catch let error as SparkBootstrap.RuntimeBootstrapError
            where RetailOnboardingFailurePresentation.isPreflightRefusal(error)
        {
            // Report preflight refusal as a conflict before transfer, and discard the outdated survey.
            hostPreflight = nil
            if case .preflightBlocked(let conflicts) = error {
                installBlockedBy = conflicts
                preflightError = nil
            } else {
                installBlockedBy = []
                noteChangedHostKey(in: error)
                preflightError = RetailOnboardingFailurePresentation.describe(preflightError: error)
            }
            releaseAdministratorPassword(after: error)
            bootstrapResult = nil
            send(.failed(.runtimeInstallFailed))
        } catch {
            if let preparation {
                // Mark the working step, or first incomplete step, failed when installation fails.
                let incomplete = preparation.runtime.first {
                    $0.status != .ready && $0.status != .unavailable
                }
                let stalled = preparation.runtime.first { $0.status == .working } ?? incomplete
                if let stalled {
                    updateRuntimePreparation(
                        preparation: preparation,
                        id: stalled.id,
                        detail: String(localized: "This step did not finish"),
                        status: .failed
                    )
                }
            }
            noteChangedHostKey(in: error)
            preflightError = RetailOnboardingFailurePresentation.describe(installError: error)
            releaseAdministratorPassword(after: error)
            bootstrapResult = nil
            send(.failed(.runtimeInstallFailed))
        }
    }

    /// Keep the account password for a retry after a transient failure; drop it once this Spark rejects it.
    private func releaseAdministratorPassword(after error: any Error) {
        guard RetailOnboardingFailurePresentation.installRejectedAdministratorPassword(error)
        else { return }
        administratorPassword = ""
    }

    func bootstrapWillRun(
        _ command: BootstrapCommand,
        preparation: RetailOnboardingPreparationModel?
    ) {
        guard state.phase == .runtimeInstall, preparation?.isInstallingRuntime == true else {
            return
        }
        switch command {
        case .surveyHost:
            // The read-only survey precedes package installation and must not mark that step as started.
            break
        case .prepareWorkDirectory, .receiveFile, .verifyDigest, .verifyDetachedSignature,
            .verifyAgainstInstalledTrustRoot, .installPackage, .installRecommendedTools:
            updateRuntimePreparation(
                preparation: preparation,
                id: "runtime-package",
                detail: command.summary,
                status: .working
            )
        case .enablePrivilegedHelper:
            updateRuntimePreparation(
                preparation: preparation,
                id: "runtime-package",
                detail: String(localized: "Ready"),
                status: .ready
            )
            updateRuntimePreparation(
                preparation: preparation,
                id: "privileged-helper",
                detail: command.summary,
                status: .working
            )
        case .enableRuntime:
            updateRuntimePreparation(
                preparation: preparation,
                id: "privileged-helper",
                detail: String(localized: "Ready"),
                status: .ready
            )
            updateRuntimePreparation(
                preparation: preparation,
                id: "spark-runtime",
                detail: command.summary,
                status: .working
            )
        case .bootstrapOwner:
            updateRuntimePreparation(
                preparation: preparation,
                id: "spark-runtime",
                detail: String(localized: "Ready"),
                status: .ready
            )
            updateRuntimePreparation(
                preparation: preparation,
                id: "local-pairing",
                detail: command.summary,
                status: .working
            )
        case .cleanUp:
            // Cleanup also runs after failure, so only a successful install result can mark the remaining steps ready.
            break
        }
    }

    func updateRuntimePreparation(
        preparation: RetailOnboardingPreparationModel?,
        id: String,
        detail: String,
        status: RetailPreparationStatus
    ) {
        guard let preparation else { return }
        preparation.runtime = preparation.runtime.map { item in
            guard item.id == id else { return item }
            return RetailPreparationItem(
                id: item.id,
                title: item.title,
                detail: detail,
                status: status
            )
        }
    }

}
