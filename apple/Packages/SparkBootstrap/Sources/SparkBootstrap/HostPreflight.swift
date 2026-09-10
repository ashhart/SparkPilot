import Foundation

/// Present non-overridable preflight conflicts with actionable guidance for ports, packages, units and paths (§10.2).
public struct PreflightConflict: Sendable, Equatable, Identifiable {
    /// Keep preflight conflicts within the four defined blocking categories (§10.2).
    public enum Kind: String, Sendable, Equatable {
        case port
        case package
        case serviceUnit
        case filesystem
    }

    public let kind: Kind
    /// What was found, in the owner's terms.
    public let summary: String
    /// What they can do about it. Never "install anyway".
    public let recovery: String

    public var id: String { "\(kind.rawValue):\(summary)" }
}

/// Keep survey evidence and its installation verdict together in one value.
public struct HostPreflight: Sendable, Equatable {
    public let survey: HostSurvey
    public let conflicts: [PreflightConflict]

    /// Block installation when the survey is unreadable or contains a concrete conflict.
    public var canInstall: Bool {
        survey.isWellFormed && conflicts.isEmpty
    }

    public init(survey: HostSurvey) {
        self.survey = survey
        self.conflicts = PreflightConflict.evaluate(survey)
    }
}

extension PreflightConflict {
    /// Block foreign-resource collisions on first install while allowing runtime-owned repair resources and individually unknown survey facts.
    static func evaluate(_ survey: HostSurvey) -> [PreflightConflict] {
        guard !survey.hasSparkRuntimeInstalled else { return [] }
        var conflicts: [PreflightConflict] = []

        if let listening = survey.listeningPorts {
            let taken = HostSurvey.requiredPorts.filter(listening.contains)
            if !taken.isEmpty {
                let ports = taken.map(String.init).formatted(.list(type: .and))
                conflicts.append(
                    PreflightConflict(
                        kind: .port,
                        summary: String(
                            localized: .portsAlreadyInUse(count: taken.count, ports: ports)
                        ),
                        recovery: String(
                            localized: .portsAlreadyInUseRecovery(count: taken.count, ports: ports)
                        )
                    )
                )
            }
        }

        if let owner = survey.installPathOwner, owner != "spark-runtime" {
            conflicts.append(
                PreflightConflict(
                    kind: .package,
                    summary: String(localized: .packageOwnsInstallPath(owner)),
                    recovery: String(localized: .packageOwnsInstallPathRecovery(owner))
                )
            )
        }

        let units = [
            ("sparkd", survey.sparkdUnit),
            ("spark-privd", survey.privilegedHelperUnit),
        ]
        .filter { $0.1 == .present }
        .map(\.0)
        if !units.isEmpty {
            let names = units.formatted(.list(type: .and))
            conflicts.append(
                PreflightConflict(
                    kind: .serviceUnit,
                    summary: String(
                        localized: .unexplainedServiceUnits(count: units.count, names: names)
                    ),
                    recovery: String(
                        localized: .unexplainedServiceUnitsRecovery(
                            count: units.count,
                            names: names
                        )
                    )
                )
            )
        }

        if survey.stateDirectory == .present || survey.installDirectory == .present {
            let directory =
                survey.stateDirectory == .present
                ? "/var/lib/spark-runtime" : "/usr/lib/spark-runtime"
            conflicts.append(
                PreflightConflict(
                    kind: .filesystem,
                    summary: String(localized: .leftoverRuntimeDirectory(directory)),
                    recovery: String(localized: .leftoverRuntimeDirectoryRecovery(directory))
                )
            )
        }

        return conflicts
    }
}
