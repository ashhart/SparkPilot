import Foundation
import SparkBootstrap

/// Separates observed inventory, unknown facts and installation changes, with no continuation action when preflight blocks installation.
struct ExistingSparkPreflightPresentation: Equatable {
    /// Facts the Spark stated, in the owner's terms.
    let found: [String]
    /// Names facts the Spark could not establish instead of presenting missing evidence as an empty inventory.
    let notEstablished: [String]
    /// Exactly what the signed package adds (§10.2 step 7).
    let willAdd: [String]
    /// Provide workload-preservation guidance only when existing workloads were observed.
    let workloadAssurance: String?
    let conflicts: [PreflightConflict]
    /// Distinguish an unanswered preflight check from a verified clear result.
    let checkFailed: Bool

    var canContinue: Bool { !checkFailed && conflicts.isEmpty }

    /// Omit the install action entirely when preflight is blocked.
    var continueTitle: String? {
        canContinue ? String(localized: "Install Spark Runtime") : nil
    }

    init(preflight: HostPreflight) {
        let survey = preflight.survey
        checkFailed = !survey.isWellFormed
        conflicts = preflight.conflicts

        var found: [String] = []
        var unknown: [String] = []

        if let system = survey.operatingSystem {
            found.append(system)
        } else {
            unknown.append(String(localized: "Which version of DGX OS this Spark runs"))
        }

        if survey.hasSparkRuntimeInstalled, let version = survey.runtimePackageVersion {
            found.append(String(localized: .runtimeAlreadyInstalled(version)))
        }

        if let memory = survey.memoryTotalKilobytes {
            found.append(String(localized: .memoryFitted(Self.gigabytes(fromKilobytes: memory))))
        }
        if let free = survey.diskFreeKilobytes, let total = survey.diskTotalKilobytes {
            found.append(
                String(
                    localized: .storageFreeOfTotal(
                        free: Self.gigabytes(fromKilobytes: free),
                        total: Self.gigabytes(fromKilobytes: total)
                    )
                )
            )
        } else {
            unknown.append(String(localized: "How much disk space is free"))
        }

        if let services = survey.runningServices {
            found.append(String(localized: .systemServicesRunning(services)))
        } else {
            unknown.append(String(localized: "Which system services are running"))
        }

        switch survey.containerCount {
        case .some(let count) where count > 0:
            let names = survey.containers.prefix(3).map(\.name).formatted(.list(type: .and))
            found.append(
                String(
                    localized: names.isEmpty
                        ? .containersRunning(count)
                        : .containersRunningNamed(count: count, names: names)
                )
            )
        case .some:
            found.append(String(localized: "No containers running"))
        case .none:
            unknown.append(String(localized: "Which containers are running on this Spark"))
        }

        if let ports = survey.listeningPorts, !ports.isEmpty {
            found.append(
                String(
                    localized: .listeningOnPorts(
                        ports.prefix(8).map(String.init).formatted(.list(type: .and))
                    )
                )
            )
        } else if survey.listeningPorts == nil {
            unknown.append(String(localized: "Which ports are in use"))
        }

        // Limit survey cluster evidence to local observations without claiming peer reachability.
        for port in survey.fabricPorts {
            switch (port.carrier, port.speedMbps) {
            case (.present, .some(let speed)):
                found.append(
                    String(
                        localized: .fabricPortLinkedAt(
                            interface: port.interface,
                            gigabits: speed / 1000
                        )
                    )
                )
            case (.present, .none):
                found.append(
                    String(localized: .fabricPortCabledSpeedUnreported(port.interface))
                )
            case (.absent, _):
                found.append(String(localized: .fabricPortNotCabled(port.interface)))
            case (.unknown, _):
                unknown.append(String(localized: .whetherFabricPortIsCabled(port.interface)))
            }
        }
        if let netplan = survey.netplanFileCount, netplan > 0 {
            found.append(String(localized: .netplanFilesPresent(netplan)))
        }

        self.found = found
        self.notEstablished = unknown

        // Name the installed components so the owner can compare them with existing services (§10.2).
        willAdd = [
            String(localized: "The signed spark-runtime package under /usr/lib/spark-runtime"),
            String(localized: "Two services, sparkd and spark-privd, started at boot"),
            String(localized: "Its own state under /var/lib/spark-runtime"),
            String(
                localized: "A local API on port 7443, reachable from your devices on this network"
            ),
        ]

        // Describe preserved external ownership only when external workloads were observed.
        let hasWorkloads = (survey.containerCount ?? 0) > 0
        workloadAssurance =
            hasWorkloads
            ? String(
                localized:
                    "Anything already running on this Spark will keep running. It stays externally managed: SparkPilot will show it but never start, stop, or replace it."
            )
            : nil
    }

    /// Shows the refusal reason when the machine changes after the owner approves its preflight inventory.
    init(blockedBy conflicts: [PreflightConflict]) {
        found = []
        notEstablished = []
        willAdd = []
        workloadAssurance = nil
        self.conflicts = conflicts
        checkFailed = false
    }

    /// A Spark that would not answer the check at all.
    init(checkFailed: Bool) {
        found = []
        notEstablished = []
        willAdd = []
        workloadAssurance = nil
        conflicts = []
        self.checkFailed = checkFailed
    }

    private static func gigabytes(fromKilobytes kilobytes: Int) -> String {
        let gigabytes = Double(kilobytes) / 1_048_576
        return gigabytes >= 100
            ? Measurement(value: gigabytes.rounded(), unit: UnitInformationStorage.gigabytes)
                .formatted(
                    .measurement(
                        width: .abbreviated,
                        numberFormatStyle: .number.precision(.fractionLength(0))
                    )
                )
            : Measurement(value: gigabytes, unit: UnitInformationStorage.gigabytes)
                .formatted(
                    .measurement(
                        width: .abbreviated,
                        numberFormatStyle: .number.precision(.fractionLength(1))
                    )
                )
    }

}
