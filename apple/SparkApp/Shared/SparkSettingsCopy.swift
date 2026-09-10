import Foundation

/// Stable catalogue keys with typed interpolation arguments, resolved from the application bundle.
extension LocalizedStringResource {
    static func harnessUpdateTitle(_ name: String) -> Self {
        .init(
            "settings.harness.update.title",
            defaultValue: "\(name) update available",
            comment: "Names the coding agent with an available verified version."
        )
    }

    static func harnessUpdateBody(_ version: String) -> Self {
        .init(
            "settings.harness.update.body",
            defaultValue:
                "Version \(version) is ready to prepare when you open a new session in Develop; existing sessions keep running.",
            comment: "Explains how a signed runtime's pinned coding agent update is prepared."
        )
    }

    static func powerProfileQuiet(_ name: String) -> Self {
        .init(
            "settings.power.quiet",
            defaultValue: "Quiet-Cool · \(name)",
            comment: "The quietest nvpmodel profile."
        )
    }

    static func powerProfileBalanced(_ name: String) -> Self {
        .init(
            "settings.power.balanced",
            defaultValue: "Balanced · \(name)",
            comment: "Any other nvpmodel profile."
        )
    }

    static func confirmForgettingNetwork(_ ssid: String) -> Self {
        .init(
            "settings.confirm.forget.wifi",
            defaultValue: "Confirm forgetting \(ssid) on this Spark.",
            comment: "Presence prompt naming the Wi-Fi network being removed."
        )
    }

    static func runtimePackageIncompatible(_ reason: String) -> Self {
        .init(
            "settings.runtime.incompatible",
            defaultValue: "This runtime package is not compatible with the Spark: \(reason)",
            comment: "The update was rejected, with the runtime's own reason."
        )
    }

    static func cleanupRungAtFree(name: String, free: String) -> Self {
        .init(
            "settings.cleanup.rung",
            defaultValue: "\(name) at \(free) free",
            comment: "A storage-cleanup step and the free space that triggers it."
        )
    }

    static func modelsInstalledCount(_ count: Int) -> Self {
        .init(
            "dashboard.models.installed",
            defaultValue: "\(count) installed",
            comment: "How many signed model recipes are installed on this Spark."
        )
    }

    // MARK: - Elapsed time and counts use catalogue plural forms

    static func minutesAgo(_ minutes: Int) -> Self {
        .init(
            "fleet.elapsed.minutes",
            defaultValue: "\(minutes) minutes ago",
            comment: "How long ago a Spark last answered."
        )
    }

    static func privilegedUpdateRefused(_ reason: String) -> Self {
        .init(
            "settings.update.privileged.refused",
            defaultValue:
                "The Spark's privileged helper refused to schedule the signed update (\(reason)). Install it with a one-time Spark account password instead.",
            comment: "Signed update scheduling failed, followed by its stable reason code."
        )
    }

    static func atRuntimeUpdateStage(_ stage: String) -> Self {
        .init(
            "settings.update.stage",
            defaultValue: "at stage \(stage)",
            comment: "The runtime-defined stage where an update stopped."
        )
    }

    static func runtimeUpdateStopped(_ stage: String) -> Self {
        .init(
            "settings.update.stopped",
            defaultValue: "The Spark stopped the runtime update \(stage).",
            comment: "A runtime update failed, followed by the point where it stopped."
        )
    }

    static func runtimeUpdateCouldNotStart(_ reason: String) -> Self {
        .init(
            "settings.update.start.failed",
            defaultValue: "The signed runtime update could not be started: \(reason)",
            comment: "A runtime update could not be submitted, followed by the local error."
        )
    }

    static func reasonWithHTTPStatus(reason: String, status: Int) -> Self {
        .init(
            "settings.update.reason.http",
            defaultValue: "\(reason) (HTTP \(status))",
            comment: "An update failure reason followed by its HTTP status."
        )
    }

    static func runtimeUpdateReported(_ cause: String) -> Self {
        .init(
            "settings.update.reported",
            defaultValue:
                "The signed runtime update could not be started. The Spark reported \(cause).",
            comment: "A runtime update could not start, followed by the Spark's combined reason."
        )
    }

    static func containerInterfacesCount(_ count: Int) -> Self {
        .init(
            "network.container.interfaces",
            defaultValue: "Container and loopback interfaces (\(count))",
            comment: "Disclosure group for non-physical network interfaces and their count."
        )
    }

    static func runtimePresenceProofFailed(_ reason: String) -> Self {
        .init(
            "settings.update.presence.failed",
            defaultValue:
                "The runtime was not changed because this device could not prove your presence. \(reason)",
            comment:
                "A runtime update was refused because presence proof failed, followed by the reason."
        )
    }

    static func acceptSignedRecipeToContinue(_ revision: String) -> Self {
        .init(
            "services.accept.recipe.continue",
            defaultValue: "Accept signed recipe \(revision) to continue.",
            comment: "Install blocker naming the signed service recipe that needs acceptance."
        )
    }

    static func safetyReviewRefused(_ code: String) -> Self {
        .init(
            "models.safety.review.refused",
            defaultValue: "This Spark refused the safety review (\(code)).",
            comment: "A safety review failed, followed by the Spark's stable reason code."
        )
    }

    static func sparkReportedForAction(_ code: String) -> Self {
        .init(
            "dashboard.action.reported",
            defaultValue: "The Spark reported \(code) for this action.",
            comment: "An action failed, followed by the Spark's stable reason code."
        )
    }

    static func openWebUIInstallUnavailable(_ reason: String) -> Self {
        .init(
            "services.openwebui.install.unavailable",
            defaultValue: "Install Open WebUI is unavailable. \(reason)",
            comment: "Spoken install-button state followed by the reason it is disabled."
        )
    }

    static func publishedRecipesAvailable(_ count: Int) -> Self {
        .init(
            "catalogue.published.available",
            defaultValue: "New: \(count) recipes published, different from this Spark's snapshot",
            comment:
                "sparkpilot.dev publishes a catalogue that differs from the Spark's; the count is its recipe total."
        )
    }

    static func publishedRecipesCurrent(_ count: Int) -> Self {
        .init(
            "catalogue.published.current",
            defaultValue: "Up to date with sparkpilot.dev (\(count) recipes)",
            comment:
                "The Spark's catalogue matches what sparkpilot.dev publishes; the count is its recipe total."
        )
    }

    static func stageWithPercent(stage: String, percent: String) -> Self {
        .init(
            "operation.stage.percent",
            defaultValue: "\(stage) · \(percent)",
            comment: "An operation stage followed by its completion percentage."
        )
    }

    static func nothingChangedReported(_ cause: String) -> Self {
        .init(
            "settings.change.reported",
            defaultValue: "Nothing changed. The Spark reported \(cause).",
            comment: "A setting was unchanged, followed by the Spark's reason."
        )
    }

    static func sshConnectionCouldNotOpen(_ detail: String) -> Self {
        .init(
            "settings.ssh.open.failed",
            defaultValue:
                "SparkPilot could not open the one-time SSH connection to the Spark (\(detail)). Check the Spark is online and try again.",
            comment: "The one-time update connection failed, followed by transport detail."
        )
    }

    static func sshConnectionCouldNotStayOpen(_ detail: String) -> Self {
        .init(
            "settings.ssh.channel.failed",
            defaultValue:
                "SparkPilot could not keep the one-time SSH connection open (\(detail)). Check the Spark is online and try again.",
            comment: "The one-time update channel failed, followed by transport detail."
        )
    }

    static func sshCommandTimedOut(_ command: String) -> Self {
        .init(
            "settings.ssh.timeout",
            defaultValue:
                "SparkPilot timed out while \(command). Check the Spark is online and try again.",
            comment: "A one-time update command timed out; command describes the safe operation."
        )
    }

    static func forgetNetwork(_ ssid: String) -> Self {
        .init(
            "settings.wifi.forget",
            defaultValue: "Forget \(ssid)",
            comment: "Accessible name for forgetting the named Wi-Fi network."
        )
    }

    static func operationLeaseExpired(_ label: String) -> Self {
        .init(
            "settings.operation.lease.expired",
            defaultValue:
                "The Spark stopped reporting on \(label) before it finished, usually because Spark Runtime restarted to apply an update. The current state has been refreshed; if a restart is required, restart the Spark to finish.",
            comment:
                "The runtime's operation lease lapsed; label names the operation, e.g. installing updates."
        )
    }
}
