import Foundation

/// Stable catalogue keys with typed interpolation arguments, resolved from the application bundle.
extension LocalizedStringResource {
    static func memoryUsed(_ amount: String) -> Self {
        .init(
            "telemetry.memory.used",
            defaultValue: "\(amount) used",
            comment: "How much of a memory or storage pool is in use."
        )
    }

    static func memoryOfTotal(used: String, total: String) -> Self {
        .init(
            "telemetry.memory.of.total",
            defaultValue: "\(used) of \(total) total",
            comment: "Accelerator memory in use against the amount fitted."
        )
    }

    static func storageFreeOfTotal(free: String, total: String) -> Self {
        .init(
            "telemetry.storage.free",
            defaultValue: "\(free) free of \(total)",
            comment: "Free filesystem space against its capacity."
        )
    }

    static var stallAverageWithoutFull: Self {
        .init(
            "telemetry.stall.partial.only",
            defaultValue: "10-second partial-stall average · Full-stall PSI unavailable",
            comment: "The kernel gave the partial-stall average and withheld the full one."
        )
    }

    static func stallAverageWithFull(_ percent: String) -> Self {
        .init(
            "telemetry.stall.full",
            defaultValue: "10-second partial-stall average · \(percent) fully stalled",
            comment: "Both stall averages are available."
        )
    }

    static func tokensPerSecond(_ value: String) -> Self {
        .init(
            "telemetry.tokens.per.second",
            defaultValue: "\(value) tok/s",
            comment: "Generation throughput while the engine is serving."
        )
    }

    // MARK: - Measured-value keys supply units and word order around locale-formatted numbers

    static func tokensPerSecondSpelled(_ value: String) -> Self {
        .init(
            "measure.tokens.per.second.spelled",
            defaultValue: "\(value) tokens per second",
            comment: "Generation throughput, spelled out rather than abbreviated."
        )
    }

    static func milliseconds(_ value: String) -> Self {
        .init(
            "measure.milliseconds",
            defaultValue: "\(value) milliseconds",
            comment: "A latency, spelled out rather than abbreviated."
        )
    }

    static func requestsPerMinute(_ value: String) -> Self {
        .init(
            "measure.requests.per.minute",
            defaultValue: "\(value) req/min",
            comment: "Inference request rate."
        )
    }

    static func powerLimit(_ value: String) -> Self {
        .init(
            "measure.power.limit",
            defaultValue: " of \(value)",
            comment: "Appended to a power draw to name the configured ceiling."
        )
    }

    static func configuredPowerLimit(_ value: String) -> Self {
        .init(
            "measure.power.limit.configured",
            defaultValue: "\(value) configured limit",
            comment: "The accelerator's configured power ceiling."
        )
    }

    // MARK: - Read-only preflight counts use catalogue plural forms

    static func runtimeAlreadyInstalled(_ version: String) -> Self {
        .init(
            "preflight.runtime.installed",
            defaultValue: "Spark Runtime \(version) is already installed",
            comment: "The survey found a runtime already on the Spark."
        )
    }

    static func memoryFitted(_ amount: String) -> Self {
        .init(
            "preflight.memory",
            defaultValue: "\(amount) of memory",
            comment: "How much unified memory the Spark reports."
        )
    }

    static func systemServicesRunning(_ count: Int) -> Self {
        .init(
            "preflight.services.running",
            defaultValue: "\(count) system services running",
            comment: "How many systemd services the survey counted."
        )
    }

    static func containersRunning(_ count: Int) -> Self {
        .init(
            "preflight.containers",
            defaultValue: "\(count) containers",
            comment: "How many containers are running, with no names available."
        )
    }

    static func containersRunningNamed(count: Int, names: String) -> Self {
        .init(
            "preflight.containers.named",
            defaultValue: "\(count) containers: \(names)",
            comment: "How many containers are running, and the first few by name."
        )
    }

    static func listeningOnPorts(_ ports: String) -> Self {
        .init(
            "preflight.ports",
            defaultValue: "Listening on \(ports)",
            comment: "Which ports the Spark already has open."
        )
    }

    static func netplanFilesPresent(_ count: Int) -> Self {
        .init(
            "preflight.netplan",
            defaultValue: "\(count) network configuration files already on this Spark",
            comment: "How many Netplan files the survey found."
        )
    }

    // MARK: - Dashboard action labels name their target model

    static func checkOperationStatus(_ model: String) -> Self {
        .init(
            "dashboard.retry.status",
            defaultValue: "Check operation status for \(model)",
            comment: "Retry label when the app lost track of an operation."
        )
    }

    static func hoursAgo(_ hours: Int) -> Self {
        .init(
            "fleet.elapsed.hours",
            defaultValue: "\(hours) hours ago",
            comment: "How long ago a Spark last answered."
        )
    }

    static func daysAgo(_ days: Int) -> Self {
        .init(
            "fleet.elapsed.days",
            defaultValue: "\(days) days ago",
            comment: "How long ago a Spark last answered."
        )
    }

    static func modelsInstalled(_ count: Int) -> Self {
        .init(
            "fleet.models.installed",
            defaultValue: "\(count) models installed",
            comment: "How many models are installed on one Spark."
        )
    }

    static func clusterMembersReachable(prefix: String, total: Int, reachable: Int) -> Self {
        .init(
            "fleet.cluster.members.reachable",
            defaultValue: "\(prefix) of \(total) Sparks · \(reachable) reachable",
            comment: "A cluster card's membership and how many answered."
        )
    }

    // MARK: - Cross-target models

    static func runningOnTargets(_ targets: String) -> Self {
        .init(
            "models.running.on",
            defaultValue: "Running on \(targets)",
            comment: "Which Sparks are serving this model. The list is already joined."
        )
    }
}
