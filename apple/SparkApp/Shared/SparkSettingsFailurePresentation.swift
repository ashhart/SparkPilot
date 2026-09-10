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
enum SparkSettingsFailurePresentation {

    static func release(
        _ releaseID: String?,
        differsFromInstalledVersion installedVersion: String?
    ) -> Bool {
        RuntimeReleaseIdentity.compare(releaseID: releaseID, installedVersion: installedVersion)
            == .orderedDescending
    }

    static func releaseCanReplace(
        _ releaseID: String?,
        installedVersion: String?
    ) -> Bool {
        guard
            let order = RuntimeReleaseIdentity.compare(
                releaseID: releaseID,
                installedVersion: installedVersion
            )
        else { return false }
        return order != .orderedAscending
    }

    static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        return (error as? URLError)?.code == .cancelled
    }

    /// Treat missing routes or absent HTTP responses as possible older-runtime evidence while preserving 5xx as runtime failures.
    static func mayIndicateMissingSettingsRoutes(_ error: any Error) -> Bool {
        guard let status = (error as? APIError)?.statusCode else { return true }
        return status == 404 || status == 405
    }

    /// Recognises runtimes advertising signed updates whose version is at least the bundled release.
    static func runtimeIsCurrent(
        capabilities: SparkCapabilities?,
        bundledReleaseID: String?,
        installedVersion: String?
    ) -> Bool {
        guard let capabilities, capabilities.isEnabled("signed_runtime_update") else {
            return false
        }
        return !release(bundledReleaseID, differsFromInstalledVersion: installedVersion)
    }

    static func passwordFallbackMessage(
        for error: any Error,
        signedUpdateSupported: Bool?
    ) -> String {
        guard signedUpdateSupported == true else {
            return
                String(
                    localized:
                        "This older runtime cannot accept a signed update. A one-time Spark account password is required."
                )
        }
        let reason = (error as? APIError)?.code ?? String(localized: "an unexpected error")
        return String(localized: .privilegedUpdateRefused(reason))
    }

    /// What the failed operation says about where it stopped.
    static func runtimeRepairFailureDetail(_ operation: SparkAPI.Operation) -> String {
        let stage =
            switch operation.stage {
            case "runtime_update_scheduling":
                String(localized: "while scheduling the update on the Spark")
            case "runtime_update_restarting": String(localized: "while restarting Spark Runtime")
            case let other?: String(localized: .atRuntimeUpdateStage(other))
            case nil: String(localized: "before it finished")
            }
        return String(localized: .runtimeUpdateStopped(stage))
    }

    /// Maps signed-update submission refusals to their specific recovery instead of treating every failure as a connection problem.
    static func runtimeUpdateStartFailureMessage(_ error: any Error) -> String {
        guard let api = error as? APIError else {
            return String(localized: .runtimeUpdateCouldNotStart(error.localizedDescription))
        }
        var cause = api.code ?? String(localized: "an unexpected error")
        if let status = api.statusCode {
            cause = String(localized: .reasonWithHTTPStatus(reason: cause, status: status))
        }
        return String(localized: .runtimeUpdateReported(cause))
    }

    static func signedRuntimeRepairIsUnavailable(_ error: any Error) -> Bool {
        guard let api = error as? APIError else { return false }
        if let status = api.statusCode, [404, 405, 501].contains(status) { return true }
        return [
            "NOT_FOUND", "METHOD_NOT_ALLOWED", "USER_PRESENCE_ENROLLMENT_UNAVAILABLE",
            "RUNTIME_UPDATE_SCHEDULING_UNAVAILABLE",
        ].contains(api.code)
    }

    /// A lease expiry is the runtime going quiet mid-operation, not the work failing; say so and refresh.
    static func operationLeaseExpiredMessage(_ label: String) -> String {
        String(localized: .operationLeaseExpired(label))
    }

    static func runtimeRepairFailureCode(_ operation: SparkAPI.Operation) -> String? {
        if operation.stage == "runtime_update_scheduling",
            operation.errorCode == "backend_error"
        {
            return "RUNTIME_UPDATE_SCHEDULING_UNAVAILABLE"
        }
        return operation.errorCode
    }

    static func runtimeInstallFailureMessage(_ error: any Error) -> String {
        if let ssh = error as? BootstrapSSHError {
            return runtimeSSHFailureMessage(ssh)
        }
        guard let bootstrap = error as? SparkBootstrap.RuntimeBootstrapError else {
            return
                String(
                    localized:
                        "The one-time runtime install failed before it completed. Check the connection and try again."
                )
        }
        switch bootstrap {
        case .ssh(let ssh):
            return runtimeSSHFailureMessage(ssh)
        case .manifest, .trust, .artifactUnavailable, .artifactDigestMismatch,
            .artifactSizeMismatch, .artifactSignatureInvalid:
            return
                String(
                    localized:
                        "SparkPilot refused the runtime package because its signature or contents could not be verified."
                )
        case .incompatible(let reason):
            return String(localized: .runtimePackageIncompatible(reason))
        case .preflightBlocked:
            return
                String(
                    localized:
                        "The runtime install stopped because it would interfere with software already running on this Spark."
                )
        case .preflightUnavailable:
            return String(
                localized:
                    "SparkPilot could not inspect this Spark safely before installing the runtime."
            )
        case .commandFailed, .malformedBootstrapReport:
            return
                String(
                    localized:
                        "The Spark accepted the login, but the runtime install failed on the Spark. No account change is needed."
                )
        }
    }

    static func runtimeSSHFailureMessage(_ error: BootstrapSSHError) -> String {
        switch error {
        case .authenticationFailed:
            return
                String(
                    localized:
                        "The Spark rejected that account password. Check the account name and password and try again."
                )
        // Preserve specific SSH transport failures so timeout and closed-connection recoveries remain distinguishable.
        case .connectionFailed(let detail):
            return String(localized: .sshConnectionCouldNotOpen(detail))
        case .channelFailed(let detail):
            return String(localized: .sshConnectionCouldNotStayOpen(detail))
        case .noExitStatus:
            return String(
                localized:
                    "SparkPilot could not keep the one-time SSH connection open: the Spark closed it before a command finished. Check the Spark is online and try again."
            )
        case .timedOut(let command):
            return String(localized: .sshCommandTimedOut(command.summary.lowercased()))
        case .hostKey:
            return
                String(
                    localized:
                        "The Spark's SSH identity could not be confirmed. Remove the saved host key only if this Spark was reset."
                )
        }
    }
}
