import Foundation

/// Stable catalogue keys with typed interpolation arguments, resolved from the application bundle.
extension LocalizedStringResource {
    static func clusterOfSparks(_ count: Int) -> Self {
        .init(
            "fleet.cluster.of.sparks",
            defaultValue: "Cluster of \(count) Sparks",
            comment: "How many Sparks one cluster card represents."
        )
    }

    static func independentlyPairedSparks(_ count: Int) -> Self {
        .init(
            "cluster.independently.paired",
            defaultValue: "\(count) independently paired Sparks",
            comment: "Members of an externally configured cluster."
        )
    }

    static func lastContact(_ contact: String) -> Self {
        .init(
            "fleet.last.contact",
            defaultValue: "· \(contact)",
            comment: "When a Spark last answered, appended to its status."
        )
    }

    static func coverageSummary(_ coverage: String) -> Self {
        .init(
            "models.coverage.summary",
            defaultValue: "Installation and running coverage. \(coverage)",
            comment: "Accessibility label for the cross-target coverage cell."
        )
    }

    static func targetFit(_ fit: String) -> Self {
        .init(
            "models.target.fit",
            defaultValue: "Target fit: \(fit)",
            comment: "Whether a model fits one target's memory."
        )
    }

    static func recipeVerification(_ verification: String) -> Self {
        .init(
            "models.recipe.verification",
            defaultValue: "Recipe verification: \(verification)",
            comment: "Signature state of a model recipe."
        )
    }

    static func usingCredential(_ credential: String) -> Self {
        .init(
            "models.using.credential",
            defaultValue: "Using \(credential)",
            comment: "Which stored provider reference a gated download will use."
        )
    }

    static func runningModelWillStop(_ model: String) -> Self {
        .init(
            "models.running.will.stop",
            defaultValue: "The running model \(model) will stop.",
            comment: "Consequence shown before replacing the active model."
        )
    }

    static func joinCode(_ code: String) -> Self {
        .init(
            "pairing.join.code",
            defaultValue: "Join code \(code)",
            comment: "Accessibility label for the six-digit device join code."
        )
    }

    static func stepOfFive(_ step: Int) -> Self {
        .init(
            "setup.step.of.five",
            defaultValue: "Step \(step) of 5",
            comment: "Position within the NVIDIA setup sequence."
        )
    }

    static func observedAt(_ instant: String) -> Self {
        .init(
            "workloads.observed",
            defaultValue: "Observed \(instant)",
            comment: "When the read-only workload inventory was taken."
        )
    }

    static func workloadsObservedAt(_ instant: String) -> Self {
        .init(
            "workloads.observed.accessibility",
            defaultValue: "Workloads observed at \(instant)",
            comment: "Accessibility label for the inventory timestamp."
        )
    }

    static func lastChecked(_ instant: String) -> Self {
        .init(
            "updates.last.checked",
            defaultValue: "Last checked \(instant)",
            comment: "When software updates were last looked for."
        )
    }

    static func locallySavedSamples(_ count: Int) -> Self {
        .init(
            "telemetry.saved.samples",
            defaultValue: "\(count) locally saved samples",
            comment: "How many device-local telemetry samples a chart draws."
        )
    }

    static func clusterLink(_ first: String, _ second: String) -> Self {
        .init(
            "cluster.link.between",
            defaultValue: "\(first) to \(second)",
            comment: "One observed fabric link between two named members."
        )
    }

    static func conflictAndRecovery(_ summary: String, _ recovery: String) -> Self {
        .init(
            "preflight.conflict",
            defaultValue: "\(summary). \(recovery)",
            comment: "A preflight blocker and what to do about it."
        )
    }

    // MARK: - Longer evidence and consequence copy

    static func targetEvidence(name: String, topology: String, freshness: String) -> Self {
        .init(
            "models.target.evidence",
            defaultValue: "\(name), \(topology), \(freshness)",
            comment: "Accessibility label for one target row in the Models library."
        )
    }

    static func modelRowSummary(
        version: String,
        task: String,
        download: String,
        capabilities: String,
        topology: String
    ) -> Self {
        .init(
            "models.row.summary",
            defaultValue: """
                Version \(version). Task \(task). Download \(download). \
                Capabilities \(capabilities). Topology \(topology).
                """,
            comment: "Accessibility label reading one model row as a sentence."
        )
    }

    static func workloadRowSummary(name: String, version: String, summary: String) -> Self {
        .init(
            "workloads.row.summary",
            defaultValue: "\(name), version \(version), \(summary)",
            comment: "Accessibility label for one external workload row."
        )
    }

    static func trustedOfPaired(trusted: Int, paired: Int) -> Self {
        .init(
            "devices.trusted.of.paired",
            defaultValue: "\(trusted) trusted of \(paired) paired devices",
            comment: "How many paired devices carry a trusted grant."
        )
    }

    static func deviceListCachedAt(_ instant: String) -> Self {
        .init(
            "devices.cached.at",
            defaultValue: "Showing the device list cached at \(instant).",
            comment: "The device list is stale and says so."
        )
    }

    static func confirmRevoking(_ device: String) -> Self {
        .init(
            "devices.confirm.revoke",
            defaultValue: """
                Confirm revoking \(device). The Spark will enforce owner safety rules.
                """,
            comment: "Accessibility label for the revocation confirmation."
        )
    }

    static func nothingChangedOn(_ spark: String) -> Self {
        .init(
            "preflight.nothing.changed",
            defaultValue: """
                Nothing on \(spark) has been changed. Fix the point above and check again.
                """,
            comment: "A read-only preflight found a blocker and changed nothing."
        )
    }

    static func didNotAnswerCheck(_ spark: String) -> Self {
        .init(
            "preflight.no.answer",
            defaultValue: """
                \(spark) did not answer the check this app makes before installing, so \
                nothing was installed.
                """,
            comment: "The preflight could not reach the Spark."
        )
    }

    static func remoteOperation(id: String, state: String) -> Self {
        .init(
            "remote.operation.state",
            defaultValue: "Remote operation \(id) — \(state)",
            comment: "Identifier and state of a durable remote-access operation."
        )
    }

    static func showingSavedDataFrom(_ instant: String) -> Self {
        .init(
            "dashboard.saved.data",
            defaultValue: """
                Showing saved data from \(instant) while SparkPilot checks for an update.
                """,
            comment: "Cached dashboard state, labelled as cached."
        )
    }

    static func acceptSignedRecipe(_ revision: String) -> Self {
        .init(
            "services.accept.recipe",
            defaultValue: "I accept signed recipe \(revision)",
            comment: "Owner acceptance of one optional-service recipe revision."
        )
    }

    static func sampledAt(_ instant: String) -> Self {
        .init(
            "telemetry.sampled.at",
            defaultValue: "Sampled \(instant)",
            comment: "When a telemetry reading was taken."
        )
    }

    static func profileDisabledAfterMemoryEvent(_ profile: String) -> Self {
        .init(
            "models.profile.disabled",
            defaultValue: "\(profile) is disabled after a memory safety event.",
            comment: "Why a profile cannot be started without review."
        )
    }

    static func reviewReEnabling(profile: String, model: String) -> Self {
        .init(
            "models.review.reenable",
            defaultValue: "Review re-enabling \(profile) for \(model)",
            comment: "Open the review that can re-enable a disabled profile."
        )
    }

    static func reEnable(profile: String, model: String) -> Self {
        .init(
            "models.reenable",
            defaultValue: "Re-enable \(profile) for \(model)",
            comment: "Confirm re-enabling a disabled profile."
        )
    }

    static func placementEvidence(name: String, state: String) -> Self {
        .init(
            "models.placement.evidence",
            defaultValue: "\(name), \(state), saved model evidence",
            comment: "Accessibility label for a cached placement row."
        )
    }

    static var changeHostnameConfirmation: Self {
        .init(
            "settings.change.hostname.generic",
            defaultValue: "Change this Spark's hostname?",
            comment: "Confirmation title when the new hostname is not known yet."
        )
    }

    static func changeHostnameTo(_ hostname: String) -> Self {
        .init(
            "settings.change.hostname",
            defaultValue: "Change hostname to \(hostname).local?",
            comment: "Confirmation title naming the new hostname."
        )
    }

    static func checkedAt(_ instant: String) -> Self {
        .init(
            "network.checked.at",
            defaultValue: "Checked \(instant)",
            comment: "When the network snapshot was taken."
        )
    }

    static func prefixLength(_ length: Int) -> Self {
        .init(
            "network.prefix.length",
            defaultValue: "Prefix /\(length)",
            comment: "IPv4 network prefix length in a stepper."
        )
    }

    // MARK: - Counted copy uses catalogue plural variations

    static func showingSparks(visible: Int, total: Int) -> Self {
        .init(
            "fleet.showing.count",
            defaultValue: "Showing \(visible) of \(total) Sparks",
            comment: "How many Sparks pass the current search and filters."
        )
    }

    static func noSparksMatch(_ total: Int) -> Self {
        .init(
            "fleet.none.match",
            defaultValue: """
                \(total) Sparks are paired with this device. None of them match the \
                current search and filters.
                """,
            comment: "Every paired Spark was filtered out."
        )
    }

    // MARK: - Motion and charts

    static func trendSummary(
        latest: String,
        lowest: String,
        highest: String,
        samples: Int
    ) -> Self {
        .init(
            "chart.trend.summary",
            defaultValue: """
                Latest \(latest), lowest \(lowest), highest \(highest), across \
                \(samples) locally saved samples
                """,
            comment: "Accessible summary of a sparkline, which has no readable shape."
        )
    }

    static func connectionStatic(_ state: String) -> Self {
        .init(
            "fleet.connection.static",
            defaultValue: "Connection \(state)",
            comment: """
                Static description of an animated connection line, read when \
                Reduced Motion is on and the animation is suppressed.
                """
        )
    }

    // MARK: - Public composition failures are shared by both platform entry points

    public static func releaseTrustRootUnavailable(_ detail: String) -> Self {
        .init(
            "composition.trust.root.unavailable",
            defaultValue: """
                This build could not load its release trust root, so it cannot check \
                that a Spark Runtime download is genuine. (\(detail))
                """,
            comment: "Shown when the app cannot verify runtime downloads at all."
        )
    }
}
