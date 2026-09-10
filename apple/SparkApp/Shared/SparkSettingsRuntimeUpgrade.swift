import Foundation
import Observation
import CoreImage.CIFilterBuiltins
import Network
import SparkAPI
import SparkBootstrap
import SparkCore
import SparkDesignSystem
import SparkDiscovery
import SparkSecurity
import SwiftUI
@MainActor
@Observable
final class SparkSettingsRuntimeUpgrade {
    private let runtime: any SparkSettingsManaging
    private let runtimeInstaller: (any RuntimeBootstrapInstalling)?
    private let operations: SparkSettingsOperationCoordinator
    private let onAdministratorUsernameConfirmed: (@MainActor (String) -> Void)?
    var refresh: () async -> Void = {}
    var runtimeUpgradeRequired = false
    var bundledRuntimeReleaseID: String?
    var runtimeUpdateAvailable = false
    var runtimeUpgradeProgress: String?
    var runtimePasswordFallbackRequired = false
    /// Tracks signed-update capability separately so scheduling failures on capable runtimes are not mislabelled as old software.
    var signedRuntimeUpdateSupported: Bool?
    /// Describes install or update progress with its numbered step and start time.
    var runtimeUpgradeStage: RuntimeUpgradeStage?
    /// Require an explicit administrator username before SSH installation.
    var administratorUsername = ""
    var administratorPassword = ""
    var revealsAdministratorPassword = false

    init(
        runtime: any SparkSettingsManaging,
        installer: (any RuntimeBootstrapInstalling)?,
        operations: SparkSettingsOperationCoordinator,
        username: String?,
        onAdministratorUsernameConfirmed: (@MainActor (String) -> Void)?
    ) {
        self.runtime = runtime
        self.runtimeInstaller = installer
        self.operations = operations
        self.onAdministratorUsernameConfirmed = onAdministratorUsernameConfirmed
        if let username, !username.isEmpty { administratorUsername = username }
    }

    var canInstallBundledRuntime: Bool {
        runtimeUpgradeRequired || runtimeUpdateAvailable
    }

    private func setRuntimeUpgradeStage(_ stage: RuntimeUpgradeStage) {
        runtimeUpgradeStage = stage
        runtimeUpgradeProgress = stage.title
    }

    private func clearRuntimeUpgradeStage() {
        runtimeUpgradeStage = nil
        runtimeUpgradeProgress = nil
    }

    func installRequiredRuntime() async {
        guard operations.activeMutation == nil, let runtimeInstaller else { return }
        guard !administratorUsername.isEmpty, !administratorPassword.isEmpty else {
            operations.errorMessage = String(localized: "Enter the Spark username and password.")
            return
        }
        guard let host = operations.route.host,
            let sshPort = NWEndpoint.Port(rawValue: 22)
        else {
            operations.errorMessage = String(
                localized: "This Spark does not have a usable local address."
            )
            return
        }

        let startedAt = Date()
        operations.activeMutation = String(localized: "Installing the required Spark Runtime")
        operations.errorMessage = nil
        operations.successMessage = nil
        setRuntimeUpgradeStage(.sshPreparing(startedAt: startedAt))
        let target = BootstrapSpark(
            displayName: host,
            endpoint: .hostPort(host: NWEndpoint.Host(host), port: sshPort)
        )
        let password = administratorPassword
        defer {
            administratorPassword = ""
            revealsAdministratorPassword = false
            operations.activeMutation = nil
            clearRuntimeUpgradeStage()
        }

        do {
            try await runtimeInstaller.upgrade(
                on: target,
                administratorUsername: administratorUsername,
                administratorPassword: password,
                progress: { [weak self] command in
                    Task { @MainActor [weak self] in
                        self?.setRuntimeUpgradeStage(.ssh(command, startedAt: startedAt))
                    }
                }
            )
            setRuntimeUpgradeStage(.sshWaitingForRuntime(startedAt: startedAt))
            for _ in 0..<20 {
                if (try? await runtime.sparkSettings(route: operations.route)) != nil {
                    runtimeUpgradeRequired = false
                    operations.successMessage = String(localized: "Spark Runtime installed.")
                    // Persist the username only after SSH installation succeeds.
                    onAdministratorUsernameConfirmed?(administratorUsername)
                    await refresh()
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
            operations.errorMessage = String(
                localized: "The runtime installed, but the Spark has not come back online yet."
            )
        } catch {
            operations.errorMessage = SparkSettingsFailurePresentation.runtimeInstallFailureMessage(
                error
            )
        }
    }

    func repairRequiredRuntime() async {
        guard operations.activeMutation == nil, let runtimeInstaller else { return }
        let startedAt = Date()
        operations.activeMutation = String(localized: "Updating Spark Runtime")
        operations.errorMessage = nil
        operations.successMessage = nil
        // A previous action's operation must not be read as this one's.
        operations.lastOperation = nil
        setRuntimeUpgradeStage(.signed(.verifying, startedAt: startedAt))
        defer {
            operations.activeMutation = nil
            clearRuntimeUpgradeStage()
        }

        let release: RuntimeUpdateBundle
        do {
            release = try await runtimeInstaller.prepareRuntimeUpdate()
        } catch {
            operations.errorMessage = String(
                localized: "SparkPilot could not verify its bundled Spark Runtime release."
            )
            return
        }

        let request = GeneratedAPI.InstallSoftwareUpdatesRequest(
            systemPackages: false,
            firmware: false,
            runtimeReleaseId: release.releaseID,
            runtimeReleaseBundle: await encodeRuntimeRelease(release)
        )
        let key = UUID()
        do {
            setRuntimeUpgradeStage(.signed(.approving, startedAt: startedAt))
            var operation = try await operations.submitAuthorized(
                reason: String(localized: "Confirm updating the Spark Runtime."),
                enrollmentRoute: operations.route
            ) { presence in
                await self.setRuntimeUpgradeStage(.signed(.sending, startedAt: startedAt))
                return try await self.runtime.installSoftwareUpdates(
                    route: self.operations.route,
                    request: request,
                    idempotencyKey: key,
                    userPresence: presence
                )
            }
            operations.lastOperation = operation
            setRuntimeUpgradeStage(.signed(.scheduling, startedAt: startedAt))
            operation = try await operations.waitForCompletion(
                operation,
                waitsThroughReconnect: true
            ) {
                [weak self] progress in
                if let stage = RuntimeUpgradeStage.signed(
                    operationStage: progress.stage,
                    startedAt: startedAt
                ) {
                    self?.setRuntimeUpgradeStage(stage)
                }
            }
            operations.lastOperation = operation
            guard operation.state == .succeeded else {
                throw APIError(
                    .local(
                        message: SparkSettingsFailurePresentation.runtimeRepairFailureDetail(
                            operation
                        )
                    ),
                    code: SparkSettingsFailurePresentation.runtimeRepairFailureCode(operation)
                )
            }
            runtimePasswordFallbackRequired = false
            operations.successMessage = String(
                localized: "Runtime update started. SparkPilot will reconnect when it is ready."
            )
        } catch {
            // Offer SSH recovery for missing signed-update routes or scheduling refusal while preserving their distinct explanations.
            let refusedWhileScheduling =
                operations.lastOperation?.state == .failed
                && operations.lastOperation?.stage == "runtime_update_scheduling"
            if SparkSettingsFailurePresentation.signedRuntimeRepairIsUnavailable(error)
                || refusedWhileScheduling
            {
                runtimePasswordFallbackRequired = true
                operations.errorMessage = SparkSettingsFailurePresentation.passwordFallbackMessage(
                    for: error,
                    signedUpdateSupported: signedRuntimeUpdateSupported
                )
            } else if let presence = error as? UserPresenceAuthorizationError {
                // Treat only a declined prompt as cancellation; unavailable keys or prompts remain device faults.
                operations.errorMessage =
                    presence == .declined
                    ? String(
                        localized: "The runtime was not changed because approval was cancelled."
                    )
                    : String(
                        localized: .runtimePresenceProofFailed(
                            presence.errorDescription
                                ?? String(localized: "No reason was reported.")
                        )
                    )
            } else {
                operations.errorMessage =
                    SparkSettingsFailurePresentation.runtimeUpdateStartFailureMessage(error)
            }
        }
    }

    /// Explains SSH recovery according to whether the runtime is older or its signed-update scheduling failed.
    var passwordFallbackExplanation: String {
        signedRuntimeUpdateSupported == true
            ? String(
                localized:
                    "The Spark could not take the signed update through its privileged helper, so this one-time install goes over SSH with the Spark's Linux account password. Later updates use signed SparkPilot approval again."
            )
            : String(
                localized:
                    "This old runtime cannot use paired administrator approval. Enter the Spark's Linux account password for this one-time install. Future updates use signed SparkPilot approval."
            )
    }
}
