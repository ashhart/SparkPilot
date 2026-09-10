import Foundation

/// Stable catalogue keys with typed interpolation arguments, resolved from the application bundle.
extension LocalizedStringResource {
    static func installedOnTargets(_ targets: String) -> Self {
        .init(
            "models.installed.on",
            defaultValue: "Installed on \(targets)",
            comment: "Which Sparks hold this model without serving it."
        )
    }

    static func lastKnownRunningOn(_ targets: String) -> Self {
        .init(
            "models.last.known.running",
            defaultValue: "Last known running on \(targets)",
            comment: "Saved evidence, from Sparks that are not answering now."
        )
    }

    static func lastKnownInstalledOn(_ targets: String) -> Self {
        .init(
            "models.last.known.installed",
            defaultValue: "Last known installed on \(targets)",
            comment: "Saved evidence, from Sparks that are not answering now."
        )
    }

    static func completeSparkCluster(_ members: Int) -> Self {
        .init(
            "models.cluster.complete",
            defaultValue: "Complete \(members)-Spark cluster",
            comment: "Every member of the cluster is reachable."
        )
    }

    static func clusterMembersReady(reachable: Int, total: Int) -> Self {
        .init(
            "models.cluster.ready",
            defaultValue: "\(reachable) of \(total) cluster members ready",
            comment: "How many members answered out of the cluster's size."
        )
    }

    static func downloadOnTarget(_ target: String) -> Self {
        .init(
            "models.action.download.on",
            defaultValue: "Download on \(target)",
            comment: "§51.1: the action names the Spark it acts on."
        )
    }

    static func startOnTarget(_ target: String) -> Self {
        .init(
            "models.action.start.on",
            defaultValue: "Start on \(target)",
            comment: "§51.1: the action names the Spark it acts on."
        )
    }

    static func modelProfileChoice(name: String, context: String, requests: String) -> Self {
        .init(
            "model.profile.choice",
            defaultValue: "\(name) · \(context) tokens · \(requests) requests",
            comment:
                "A signed model profile with its context-token and simultaneous-request limits."
        )
    }

    static func startSignedProfileAcrossCluster(_ profile: String) -> Self {
        .init(
            "models.cluster.start.hint",
            defaultValue:
                "Starts the \(profile) profile across both qualified Sparks.",
            comment: "Explains the distributed model action for a verified signed profile."
        )
    }

    static func clusterLaunchMissingMember(_ spark: String) -> Self {
        .init(
            "cluster.launch.member.missing",
            defaultValue:
                "\(spark) did not return this launch. Stop remains available on the Spark that retained it.",
            comment: "Names a cluster member missing from partial distributed-launch evidence."
        )
    }

    static func stopOnTarget(_ target: String) -> Self {
        .init(
            "models.action.stop.on",
            defaultValue: "Stop on \(target)",
            comment: "§51.1: the action names the Spark it acts on."
        )
    }

    static func reviewOnTarget(_ target: String) -> Self {
        .init(
            "models.action.review.on",
            defaultValue: "Review on \(target)",
            comment: "§51.1: the action names the Spark it acts on."
        )
    }

    /// Presents the fingerprint in the Spark's format for owner comparison before administrator credentials are transmitted.
    static func hostKeyFingerprintPrompt(host: String, fingerprint: String) -> Self {
        .init(
            "onboarding.hostkey.prompt",
            defaultValue: """
                \(host) identifies itself as:

                \(fingerprint)

                Continue only if this matches the Spark in front of you. Your \
                administrator password will be sent to it.
                """,
            comment: "Shown before the owner's password travels to an unverified Spark."
        )
    }

    static func startResource(_ resource: String) -> Self {
        .init("action.start", defaultValue: "Start \(resource)", comment: "Start a named model.")
    }

    static func addDeviceInstruction(_ node: String) -> Self {
        .init(
            "pairing.add.device.instruction",
            defaultValue: """
                Open SparkPilot on the Apple device you are adding, choose \(node), \
                and enter this one-use code.
                """,
            comment: "How to redeem a six-digit join code on the device being added."
        )
    }

    // MARK: - Launch memory (ADR-043)

    static func contextCacheDetail(tokens: String, requests: String) -> Self {
        .init(
            "model.memory.context.cache.detail",
            defaultValue: "\(tokens) tokens × \(requests) requests",
            comment:
                "What the context cache is sized for: the preset's context length and request count."
        )
    }

    static func largestContextNow(tokens: String, requests: String) -> Self {
        .init(
            "model.memory.largest.context.now",
            defaultValue: "Largest context that fits now: \(tokens) tokens at \(requests) requests",
            comment:
                "The context length the Spark's free memory would admit at the preset's request count."
        )
    }

    static func defaultPresetName(_ name: String) -> Self {
        .init(
            "model.preset.default.name",
            defaultValue: "\(name) (Default)",
            comment: "Marks the preset the signed recipe recommends in a picker."
        )
    }

    static func savedPresetNoLongerOffered(_ presetID: String) -> Self {
        .init(
            "model.preset.saved.stale",
            defaultValue:
                "The preset you saved for this model (\(presetID)) is no longer offered.",
            comment: "Shown when a remembered preset id is missing from the model's current recipe."
        )
    }

    // MARK: - Onboarding and workloads

    static func healthyWithVersion(_ version: String) -> Self {
        .init(
            "preflight.healthy.version",
            defaultValue: "Healthy, version \(version)",
            comment: "The Spark answered its health check and named its runtime version."
        )
    }
}
