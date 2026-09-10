import Foundation

/// Stable catalogue keys with typed interpolation arguments, resolved from the application bundle.
extension LocalizedStringResource {
    static func warningOf(_ reason: String) -> Self {
        .init(
            "fleet.warning.of",
            defaultValue: "Warning: \(reason)",
            comment: "One warning in a Fleet card's spoken label."
        )
    }

    static func connectedOfTotal(connected: Int, total: Int) -> Self {
        .init(
            "fleet.connected.of.total",
            defaultValue: "\(connected) of \(total)",
            comment: "How many paired Sparks answered, out of how many there are."
        )
    }

    static func diskFree(_ amount: String) -> Self {
        .init(
            "workloads.disk.free",
            defaultValue: "\(amount) free",
            comment: "Free disk space on one Spark; the amount is already formatted."
        )
    }

    static func gigabitEthernet(_ speed: Int) -> Self {
        .init(
            "cluster.link.gbe",
            defaultValue: "\(speed) GbE",
            comment: "Link speed in gigabit Ethernet. GbE is the interface's own unit."
        )
    }

    static func megabitEthernet(_ speed: Int) -> Self {
        .init(
            "cluster.link.mbe",
            defaultValue: "\(speed) MbE",
            comment: "Link speed in megabit Ethernet. MbE is the interface's own unit."
        )
    }

    static func versionLabelled(_ version: String) -> Self {
        .init(
            "models.version.labelled",
            defaultValue: "Version \(version)",
            comment: "A model's recipe version in a summary line."
        )
    }

    static func taskLabelled(_ task: String) -> Self {
        .init(
            "models.task.labelled",
            defaultValue: "Task \(task)",
            comment: "What a model is for, in a summary line."
        )
    }

    static func capacityEvidenceAt(_ instant: String) -> Self {
        .init(
            "models.capacity.evidence",
            defaultValue: "Capacity evidence: \(instant)",
            comment: "When the capacity a recommendation rests on was measured."
        )
    }

    static func duplicateShortIdentifier(_ name: String) -> Self {
        .init(
            "discovery.duplicate.identifier",
            defaultValue: """
                More than one paired Spark advertises the same short identifier, so \
                \(name) cannot be told apart from the others.
                """,
            comment: "Two Sparks share a Bonjour name, so neither can be opened safely."
        )
    }

    static func couldNotBeOpened(_ target: String) -> Self {
        .init(
            "discovery.could.not.open",
            defaultValue: "\(target) could not be opened.",
            comment: "A discovered Spark could not be opened, for a reason not otherwise known."
        )
    }

    static func modelsAcrossTargets(models: Int, targets: Int) -> Self {
        .init(
            "models.across.targets",
            defaultValue: "\(models) models across \(targets) targets",
            comment: "How many models the cross-target library knows, and on how many Sparks."
        )
    }

    static func summaryWithCurrentEvidence(summary: String, current: Int) -> Self {
        .init(
            "models.summary.evidence",
            defaultValue: "\(summary). \(current) with current authenticated evidence.",
            comment: "The library summary, and how many Sparks answered recently."
        )
    }

    static func currentAsOf(_ instant: String) -> Self {
        .init(
            "models.evidence.current",
            defaultValue: "Current as of \(instant)",
            comment: "This target answered, and this is when."
        )
    }

    static func cachedFrom(_ instant: String) -> Self {
        .init(
            "models.evidence.cached",
            defaultValue: "Cached from \(instant)",
            comment: "This target did not answer; these are saved values."
        )
    }

    static func actionComplete(_ action: String) -> Self {
        .init(
            "settings.action.complete",
            defaultValue: "\(action) complete.",
            comment: "A named settings action finished."
        )
    }

    static func updatesAvailable(_ count: Int) -> Self {
        .init(
            "settings.updates.available",
            defaultValue: "\(count) available",
            comment: "How many software updates the Spark reports."
        )
    }

    static func evidenceCurrentFrom(_ instant: String) -> Self {
        .init(
            "models.evidence.current.spoken",
            defaultValue: "Current authenticated evidence from \(instant)",
            comment: "Spoken form of the current-evidence badge, read as one sentence."
        )
    }

    static func evidenceStaleFrom(_ instant: String) -> Self {
        .init(
            "models.evidence.cached.spoken",
            defaultValue: "Stale cached evidence from \(instant)",
            comment: "Spoken form of the stale-evidence badge, read as one sentence."
        )
    }

    static func memoryAvailableWithPressure(available: String, pressure: String) -> Self {
        .init(
            "telemetry.memory.available.pressure",
            defaultValue: "\(available) available · \(pressure) pressure",
            comment: "Unified memory still free, and how hard the Spark is pressing on it."
        )
    }

    static func requestsActive(_ active: Int) -> Self {
        .init(
            "telemetry.requests.active",
            defaultValue: "\(active) active",
            comment: "How many inference requests are running right now."
        )
    }

    static func requestsQueued(_ queued: Int) -> Self {
        .init(
            "telemetry.requests.queued",
            defaultValue: "\(queued) queued",
            comment: "How many inference requests are waiting to start."
        )
    }

    static func requestsActiveQueueUnavailable(_ active: Int) -> Self {
        .init(
            "telemetry.requests.active.queue.unavailable",
            defaultValue: "\(active) active · Queue unavailable",
            comment: "Requests are running, but the Spark did not report the queue."
        )
    }

    static func requestsActiveAndQueued(active: Int, queued: Int) -> Self {
        .init(
            "telemetry.requests.active.queued",
            defaultValue: "\(active) active · \(queued) queued",
            comment: "How many inference requests are running, and how many are waiting."
        )
    }

    static func tokensUsed(_ tokens: Int64) -> Self {
        .init(
            "telemetry.tokens",
            defaultValue: "\(tokens) tokens",
            comment: "Total tokens this Spark has produced today."
        )
    }

    static func requestsToday(_ requests: Int64) -> Self {
        .init(
            "telemetry.requests.today",
            defaultValue: "\(requests) requests today",
            comment: "How many local requests this Spark served today."
        )
    }

    static func requestsTodayWithFailures(requests: Int64, failures: Int64) -> Self {
        .init(
            "telemetry.requests.today.failures",
            defaultValue: "\(requests) requests · \(failures) failed today",
            comment: "How many local requests this Spark served today, and how many failed."
        )
    }

    static func cachedForAge(_ age: String) -> Self {
        .init(
            "telemetry.source.cached.age",
            defaultValue: "Cached \(age)",
            comment: "These metrics are saved, and this is how old they are."
        )
    }

    static func servingModels(_ models: String) -> Self {
        .init(
            "services.engine.serving",
            defaultValue: "Serving \(models)",
            comment: "Which models an inference engine currently has loaded."
        )
    }

    static func verifiedRecipesAvailable(_ count: Int) -> Self {
        .init(
            "services.recipes.available",
            defaultValue: "\(count) verified recipes available",
            comment: "How many signed recipes the catalogue offers when nothing is installed."
        )
    }

    static func showWorkloadDetailsFor(_ target: String) -> Self {
        .init(
            "workloads.details.target",
            defaultValue: "Show workload details for \(target)",
            comment: "Accessibility label on a Spark's column in the workload grid."
        )
    }

    static func showPlacementDetails(model: String, target: String, state: String) -> Self {
        .init(
            "workloads.details.placement",
            defaultValue: "Show \(model) on \(target). \(state)",
            comment:
                "Accessibility label on one model-on-one-Spark cell, and how that cell is doing."
        )
    }

    static func workloadsAcrossTargets(workloads: Int, targets: Int) -> Self {
        .init(
            "workloads.across.targets",
            defaultValue: "\(workloads) workloads across \(targets) targets",
            comment: "How many workloads the grid shows, and on how many Sparks."
        )
    }

    static func workloadSummaryNeedingAttention(summary: String, attention: Int) -> Self {
        .init(
            "workloads.summary.attention",
            defaultValue: "\(summary). \(attention) need attention.",
            comment: "The workload summary, and how many rows have a problem."
        )
    }

    static func confirmRevokingAccess(_ device: String) -> Self {
        .init(
            "devices.revoke.confirm",
            defaultValue: "Confirm revoking access for \(device).",
            comment: "Local authentication reason shown before a device is revoked."
        )
    }

    static func revokingAccessFor(_ device: String) -> Self {
        .init(
            "devices.revoke.inflight",
            defaultValue: "Revoking access for \(device)",
            comment: "Accessibility label while a revocation is running."
        )
    }

    static func revokeAccessFor(_ device: String) -> Self {
        .init(
            "devices.revoke.action",
            defaultValue: "Revoke access for \(device)",
            comment: "Accessibility label on the button that revokes one device."
        )
    }

    static func deviceListNotRefreshed(_ detail: String) -> Self {
        .init(
            "devices.refresh.failed.detail",
            defaultValue: """
                The device list could not be refreshed. Cached devices remain \
                unchanged. \(detail)
                """,
            comment: "The device list is stale, with the reason the Spark gave."
        )
    }

    static func revocationNotConfirmed(_ detail: String) -> Self {
        .init(
            "devices.revoke.unconfirmed.detail",
            defaultValue: "The Spark did not confirm the revocation. \(detail)",
            comment: "A revocation was not acknowledged, with the reason the Spark gave."
        )
    }

    static func joinNetwork(_ network: String) -> Self {
        .init(
            "setup.join.network",
            defaultValue: "Join \(network)",
            comment: "Heading over the Wi-Fi password field, naming the network being joined."
        )
    }

    static func modelOnTarget(model: String, target: String) -> Self {
        .init(
            "intent.model.on.target",
            defaultValue: "\(model) on \(target)",
            comment: "How a model is named in Shortcuts when several Sparks could run it."
        )
    }

    static func linkSpeedGigabits(_ gigabits: String) -> Self {
        .init(
            "network.link.gigabits",
            defaultValue: "\(gigabits) Gb/s",
            comment: "Network link speed in gigabits per second."
        )
    }

    static func linkSpeedMegabits(_ megabits: String) -> Self {
        .init(
            "network.link.megabits",
            defaultValue: "\(megabits) Mb/s",
            comment: "Network link speed in megabits per second."
        )
    }

    static func hostnameAlreadySet(_ hostname: String) -> Self {
        .init(
            "identity.hostname.unchanged",
            defaultValue: "The hostname is already \(hostname).local.",
            comment: "The requested hostname is the one the Spark already has."
        )
    }

    static func hostnameChangedTo(_ hostname: String) -> Self {
        .init(
            "identity.hostname.changed",
            defaultValue: """
                Hostname changed to \(hostname).local. It may take a moment to \
                appear on the network.
                """,
            comment: "The Spark accepted a new hostname, and it takes a moment to propagate."
        )
    }

    static func executionTargetAndModel(target: String, model: String) -> Self {
        .init(
            "chat.execution.target.model",
            defaultValue: "Execution target, \(target). Active model, \(model).",
            comment: "Accessibility label on the chat header, naming where a reply comes from."
        )
    }

    static func youSaid(_ content: String) -> Self {
        .init(
            "chat.message.you",
            defaultValue: "You said, \(content)",
            comment: "Accessibility label on the reader's own chat message."
        )
    }

    static func sparkSaidUsing(target: String, model: String, content: String) -> Self {
        .init(
            "chat.message.spark.named",
            defaultValue: "\(target) using \(model) said, \(content)",
            comment: "Accessibility label on a finished reply, naming the Spark and the model."
        )
    }

    static func sparkPartiallySaidUsing(target: String, model: String, content: String) -> Self {
        .init(
            "chat.message.spark.named.partial",
            defaultValue: "Partial response. \(target) using \(model) said, \(content)",
            comment:
                "Accessibility label on a reply still arriving, naming the Spark and the model."
        )
    }

    static func sparkSaid(_ content: String) -> Self {
        .init(
            "chat.message.spark",
            defaultValue: "The Spark said, \(content)",
            comment: "Accessibility label on a finished reply when the Spark or model is unnamed."
        )
    }

    static func sparkPartiallySaid(_ content: String) -> Self {
        .init(
            "chat.message.spark.partial",
            defaultValue: "Partial response. The Spark said, \(content)",
            comment:
                "Accessibility label on a reply still arriving when the Spark or model is unnamed."
        )
    }

    static func workloadVerifiedAgainst(workload: String, model: String, profile: String) -> Self {
        .init(
            "workload.adopt.verified",
            defaultValue: "SparkPilot verified \(workload) against \(model), \(profile).",
            comment: "What was checked before adopting a workload the Spark was already running."
        )
    }

    static func publishedOn(_ endpoints: String) -> Self {
        .init(
            "workload.published.on",
            defaultValue: "Published on \(endpoints)",
            comment: "Which endpoints a workload answers on, in its spoken summary."
        )
    }

    static func workloadsUnreadableBecause(_ reason: String) -> Self {
        .init(
            "workload.inventory.unavailable.reason",
            defaultValue: "Workloads could not be read from this Spark: \(reason).",
            comment: "The workload list is unavailable, with the reason the Spark gave."
        )
    }

    /// Keep ports as identifiers so locale grouping cannot turn port 30000 into 30,000.
    static func openAICompatibleAPIOnPort(_ port: String) -> Self {
        .init(
            "workload.api.openai.port",
            defaultValue: "OpenAI-compatible API on port \(port)",
            comment: "A verified workload serves an OpenAI-shaped API on this port."
        )
    }

    static func fabricPortLinkedAt(interface: String, gigabits: Int) -> Self {
        .init(
            "preflight.fabric.linked",
            defaultValue: "Fabric port \(interface) linked at \(gigabits) GbE",
            comment: "A cluster fabric port has a cable and reported its speed."
        )
    }

    static func fabricPortCabledSpeedUnreported(_ interface: String) -> Self {
        .init(
            "preflight.fabric.cabled",
            defaultValue: "Fabric port \(interface) has a cable, speed not reported",
            comment: "A cluster fabric port has a cable but did not say how fast the link is."
        )
    }

    static func fabricPortNotCabled(_ interface: String) -> Self {
        .init(
            "preflight.fabric.uncabled",
            defaultValue: "Fabric port \(interface) has no cable",
            comment: "A cluster fabric port has nothing plugged into it."
        )
    }

    static func whetherFabricPortIsCabled(_ interface: String) -> Self {
        .init(
            "preflight.fabric.unknown",
            defaultValue: "Whether fabric port \(interface) has a cable",
            comment: "Listed as something the read-only survey could not establish."
        )
    }

    static func lastGoodSampleAt(_ instant: String) -> Self {
        .init(
            "inference.sample.last.good",
            defaultValue: "Last good sample \(instant)",
            comment: "The counters are not live; this is when the last one arrived."
        )
    }

    static func networkNameAndSignal(name: String, signal: String) -> Self {
        .init(
            "network.wifi.name.signal",
            defaultValue: "\(name) · \(signal)",
            comment: "A Wi-Fi network's name and how strong its signal is."
        )
    }

    static func historyLastReading(_ age: String) -> Self {
        .init(
            "telemetry.history.stale",
            defaultValue: "Last reading \(age) ago",
            comment: "How old the newest recorded telemetry reading is."
        )
    }

    static func historyMinuteBucket(_ samples: Int) -> Self {
        .init(
            "telemetry.history.minute",
            defaultValue: "An average of \(samples) readings over one minute.",
            comment: "How a one-minute history point was worked out, and from how many readings."
        )
    }

    static func trendLowHighLatest(low: String, high: String, latest: String) -> Self {
        .init(
            "telemetry.history.trend.spoken",
            defaultValue: "Low \(low), high \(high), now \(latest)",
            comment: "What a trend chart's shape shows, for a reader who cannot see it."
        )
    }

    // MARK: - Fleet overview

    static func countOfTotal(_ count: Int, _ total: Int) -> Self {
        .init(
            "fleet.count.of.total",
            defaultValue: "\(count) of \(total)",
            comment: "A count followed by the total number of items."
        )
    }
}

extension LocalizedStringResource {
    static func developmentNames(_ primary: String, _ secondary: String) -> Self {
        .init(
            "development.names",
            defaultValue: "\(primary) · \(secondary)",
            comment: "A workspace, Spark, model or agent name followed by its related name."
        )
    }

    static func developmentPreparing(_ spark: String) -> Self {
        .init(
            "development.preparation.preparing",
            defaultValue:
                "\(spark) is readying its coding tools in the background, so this workspace opens faster.",
            comment:
                "Footer under the Spark picker while that Spark pulls its development image and coding agent."
        )
    }

    static func developmentPrepared(_ spark: String) -> Self {
        .init(
            "development.preparation.ready",
            defaultValue: "Coding tools are ready on \(spark).",
            comment:
                "Footer under the Spark picker once its development image and coding agent are cached."
        )
    }

    static func developmentPreparationFailed(_ spark: String) -> Self {
        .init(
            "development.preparation.failed",
            defaultValue:
                "\(spark) could not ready its coding tools yet; the workspace fetches them when it opens.",
            comment:
                "Footer under the Spark picker when preparation failed; the first session still downloads what it needs."
        )
    }
}
