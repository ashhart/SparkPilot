import Foundation

/// Stable catalogue keys with typed interpolation arguments, resolved from the application bundle.
extension LocalizedStringResource {
    static func retryFailedAction(_ model: String) -> Self {
        .init(
            "dashboard.retry.failed",
            defaultValue: "Retry the failed action for \(model)",
            comment: "Retry label after the Spark reported a failure."
        )
    }

    static func restartSparkThenLaunch(_ model: String) -> Self {
        .init(
            "dashboard.recovery.restart_spark",
            defaultValue: "Restart the Spark, then launch \(model) again",
            comment: "Recovery label when a model cannot start until the Spark reboots."
        )
    }

    static func retryUnfinishedAction(_ model: String) -> Self {
        .init(
            "dashboard.retry.incomplete",
            defaultValue: "Retry the unfinished action for \(model)",
            comment: "Retry label when an action never reached a terminal state."
        )
    }

    static func reviewActionAgain(_ model: String) -> Self {
        .init(
            "dashboard.retry.review",
            defaultValue: "Review the action for \(model) again",
            comment: "The Spark changed, so the review has to be taken again."
        )
    }

    static func replaceRunningModelWith(_ model: String) -> Self {
        .init(
            "dashboard.replace.running",
            defaultValue: "Replace the running model with \(model)",
            comment: "Starting this model stops the one already running."
        )
    }

    static func confirmReEnabling(profile: String, model: String) -> Self {
        .init(
            "dashboard.confirm.reenable",
            defaultValue: "Confirm re-enabling \(profile) for \(model).",
            comment: "Presence prompt naming the profile a memory event disabled."
        )
    }

    static func actionInProgressFor(_ model: String) -> Self {
        .init(
            "dashboard.action.in.progress",
            defaultValue: "\(model), action in progress",
            comment: "Accessibility label while a model's action is running."
        )
    }

    static func modelStageProgress(model: String, stage: String, percent: Int) -> Self {
        .init(
            "dashboard.model.progress",
            defaultValue: "\(model), \(stage), \(percent) percent",
            comment: "§51.1: progress announced with its stage and its percentage."
        )
    }

    static func modelsAvailableOnThisSpark(_ count: Int) -> Self {
        .init(
            "dashboard.models.available",
            defaultValue: "\(count) available on this Spark",
            comment: "How many signed recipes this Spark can install."
        )
    }

    static func verifiedRecipesInSnapshot(_ count: Int) -> Self {
        .init(
            "dashboard.recipes.snapshot",
            defaultValue: "\(count) verified recipes in the device-local snapshot",
            comment: "How many recipes the verified catalogue snapshot holds."
        )
    }

    static func clusterRoleSummary(leaders: Int, workers: Int) -> Self {
        .init(
            "dashboard.cluster.roles",
            defaultValue: "\(leaders) leader, \(workers) workers",
            comment: "How a cluster's members divide into leaders and workers."
        )
    }

    static func clusterReadySummary(reachable: Int, total: Int, roles: String) -> Self {
        .init(
            "dashboard.cluster.ready",
            defaultValue: "\(reachable) of \(total) ready · \(roles)",
            comment: "How many cluster members answered, and their roles."
        )
    }

    static func catalogueRefreshFailedDetail(_ detail: String) -> Self {
        .init(
            "dashboard.catalogue.refresh.failed",
            defaultValue: "\(detail) The previous verified catalogue remains in use.",
            comment: "A refresh failed; the Spark kept the catalogue it had."
        )
    }

    static func versionGatewayNeedsAttention(_ version: String) -> Self {
        .init(
            "dashboard.service.gateway.attention",
            defaultValue: "Version \(version) · Inference gateway needs attention",
            comment: "The optional service is healthy but its gateway is not."
        )
    }

    static func versionAndSignedRecipe(version: String, revision: String) -> Self {
        .init(
            "dashboard.service.version",
            defaultValue: "Version \(version) · Signed recipe \(revision)",
            comment: "The installed optional service and the recipe it came from."
        )
    }

    static func memoryUsedOfTotal(used: String, total: String) -> Self {
        .init(
            "dashboard.memory.used.of.total",
            defaultValue: "\(used) of \(total)",
            comment: "Unified memory in use against the amount fitted."
        )
    }

    // MARK: - Power-profile copy retains NVIDIA mode names alongside localised descriptions

    static func powerProfileMax(_ name: String) -> Self {
        .init(
            "settings.power.max",
            defaultValue: "Max · \(name)",
            comment: "The highest-performance nvpmodel profile, named as the host names it."
        )
    }

    static func removeFromThisDevice(_ target: String) -> Self {
        .init(
            "fleet.action.remove",
            defaultValue: "Remove \(target) from this device",
            comment: "Removes only the local entry; the Spark is untouched."
        )
    }

    static func forgetNetworkNamed(_ ssid: String) -> Self {
        .init(
            "settings.wifi.forget.named",
            defaultValue: "Forget \(ssid)",
            comment: "Confirmation button that names the Wi-Fi network being forgotten."
        )
    }

    static func deleteChatNamed(_ title: String) -> Self {
        .init(
            "chat.history.delete.named",
            defaultValue: "Delete \(title)",
            comment: "Confirmation button that names the saved chat being deleted."
        )
    }

    static func retrySavingLibrary(_ action: String) -> Self {
        .init(
            "fleet.retry.saving",
            defaultValue: "\(action). Retry saving Your Sparks",
            comment: "The library store failed; this offers the action again."
        )
    }

    static func memoryFreeOfTotal(free: String, total: String) -> Self {
        .init(
            "fleet.memory.free",
            defaultValue: "\(free) free of \(total)",
            comment: "Free unified memory against the amount fitted."
        )
    }

    static func savedStateFromContact(_ contact: String) -> Self {
        .init(
            "fleet.saved.state",
            defaultValue: "Saved state from the last contact, \(contact).",
            comment: "The card is showing cached values and says when they were taken."
        )
    }

    static func valuesFromLastAnswer(_ contact: String) -> Self {
        .init(
            "fleet.values.delayed",
            defaultValue: "Values are from the last answer, \(contact).",
            comment: "The Spark is answering slowly, so these values are the previous ones."
        )
    }

    static func lastContactLabel(_ contact: String) -> Self {
        .init(
            "fleet.label.last.contact",
            defaultValue: "Last contact \(contact)",
            comment: "Part of the card's spoken label."
        )
    }

    static func unifiedMemoryLabel(_ memory: String) -> Self {
        .init(
            "fleet.label.memory",
            defaultValue: "Unified memory \(memory)",
            comment: "Part of the card's spoken label."
        )
    }

    static func activeModelLabel(_ model: String) -> Self {
        .init(
            "fleet.label.active.model",
            defaultValue: "Active model \(model)",
            comment: "Part of the card's spoken label."
        )
    }

    static func fromSparksWithEvidence(contributing: Int, total: Int) -> Self {
        .init(
            "fleet.memory.contributing",
            defaultValue: "From \(contributing) of \(total) Sparks with current evidence.",
            comment: "A total summed only from Sparks whose readings are fresh."
        )
    }

    static func warningsWithBlockers(warnings: Int, blockers: Int) -> Self {
        .init(
            "fleet.warnings.blocking",
            defaultValue: "\(warnings) · \(blockers) blocking",
            comment: "How many warnings there are and how many stop work."
        )
    }

    static func memberRoleReachabilityNode(
        role: String,
        reachability: String,
        node: String
    ) -> Self {
        .init(
            "fleet.member.summary",
            defaultValue: "\(role) · \(reachability) · node \(node)",
            comment: "One cluster member's role, whether it answered, and its node id."
        )
    }

    // MARK: - Value templates keep prefixes and connective words within catalogue keys

    static func blockedBy(_ reason: String) -> Self {
        .init(
            "fleet.blocked.by",
            defaultValue: "Blocked: \(reason)",
            comment: "One blocker in a Fleet card's spoken label."
        )
    }

    static func latestReading(_ age: String) -> Self {
        .init(
            "fleet.home.latest.reading",
            defaultValue: "Latest reading \(age)",
            comment: "How old the readings on one Spark's Home card are."
        )
    }

    static func fleetClusterCount(_ count: Int) -> Self {
        .init(
            "fleet.home.cluster.count",
            defaultValue: "\(count) clusters",
            comment: "How many clusters the fleet holds, on the Clusters card."
        )
    }

    static func runningCount(_ count: Int) -> Self {
        .init(
            "fleet.inference.running",
            defaultValue: "\(count) running",
            comment: "Number of Sparks currently serving inference."
        )
    }

    static func fleetMemoryDetail(total: String) -> Self {
        .init(
            "fleet.memory.detail",
            defaultValue: "of \(total) in use",
            comment: "Introduces the fleet's total fitted memory after the used amount."
        )
    }

    static func fleetMemoryDetailWithCoverage(total: String, reporting: Int, sparks: Int) -> Self {
        .init(
            "fleet.memory.detail.coverage",
            defaultValue: "of \(total) in use · \(reporting) of \(sparks) reporting",
            comment: "Total memory and how many Sparks supplied a current reading."
        )
    }

    static func memoryUsedInUse(used: String, total: String) -> Self {
        .init(
            "fleet.memory.used.in.use",
            defaultValue: "\(used) of \(total) in use",
            comment: "One Spark's used memory and total fitted memory."
        )
    }

    // MARK: - Developer tools

    static func developerBridgeUnavailable(_ reason: String) -> Self {
        .init(
            "developer.bridge.unavailable",
            defaultValue: "Spark could not start its local bridge. \(reason)",
            comment: "The local developer-tool bridge failed, followed by its reason."
        )
    }

    static func fleetModelCount(_ count: Int) -> Self {
        .init(
            "fleet.dashboard.models.count",
            defaultValue: "\(count) models",
            comment: "Number of distinct models installed across the saved Sparks."
        )
    }

    static func fleetMemoryInUse(total: String) -> Self {
        .init(
            "fleet.dashboard.memory.total",
            defaultValue: "of \(total) in use",
            comment: "Capacity beside the dashboard's total used memory."
        )
    }

    static func fleetOnlineCount(_ online: Int, _ total: Int) -> Self {
        .init(
            "fleet.dashboard.online.count",
            defaultValue: "\(online) of \(total) online",
            comment: "Reachable Sparks and the total saved Spark count."
        )
    }
}
