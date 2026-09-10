import Foundation

/// Declare typed stable-key bootstrap copy in the main bundle, with counts separate from locale-formatted lists for pluralisation.
extension LocalizedStringResource {
    static func portsAlreadyInUse(count: Int, ports: String) -> Self {
        .init(
            "preflight.conflict.port",
            defaultValue: """
                Something on this Spark is already using \(count) port \(ports), \
                which Spark Runtime needs.
                """,
            comment: "A port Spark Runtime needs is taken. The count varies the noun."
        )
    }

    static func portsAlreadyInUseRecovery(count: Int, ports: String) -> Self {
        .init(
            "preflight.conflict.port.recovery",
            defaultValue: """
                Stop or move whatever is listening on \(count) port \(ports), then \
                check this Spark again. Spark Runtime will not take a port from a \
                service you are already running.
                """,
            comment: "How to clear a taken port. The count varies the noun."
        )
    }

    static func packageOwnsInstallPath(_ package: String) -> Self {
        .init(
            "preflight.conflict.package",
            defaultValue:
                "The package \(package) already owns the folder Spark Runtime installs into.",
            comment: "Another Debian package owns the install path."
        )
    }

    static func packageOwnsInstallPathRecovery(_ package: String) -> Self {
        .init(
            "preflight.conflict.package.recovery",
            defaultValue: """
                Remove \(package) from this Spark, or install Spark Runtime on a \
                different machine. Installing over another package's files would break it.
                """,
            comment: "How to clear a package that owns the install path."
        )
    }

    static func unexplainedServiceUnits(count: Int, names: String) -> Self {
        .init(
            "preflight.conflict.unit",
            defaultValue: """
                This Spark already has \(count) service called \(names), but no \
                Spark Runtime package that would explain it.
                """,
            comment: "Service units exist with no package behind them. The count varies the noun."
        )
    }

    static func unexplainedServiceUnitsRecovery(count: Int, names: String) -> Self {
        .init(
            "preflight.conflict.unit.recovery",
            defaultValue: """
                Remove \(count) the service \(names), then check this Spark again. \
                Installing would replace a service this app did not put there.
                """,
            comment: "How to clear an unexplained service unit. The count varies the noun."
        )
    }

    static func leftoverRuntimeDirectory(_ directory: String) -> Self {
        .init(
            "preflight.conflict.directory",
            defaultValue: """
                This Spark has a \(directory) folder left over from something else — \
                no Spark Runtime package is installed.
                """,
            comment: "A runtime directory exists with no package behind it."
        )
    }

    static func leftoverRuntimeDirectoryRecovery(_ directory: String) -> Self {
        .init(
            "preflight.conflict.directory.recovery",
            defaultValue: """
                Check what is in \(directory) and move or remove it, then check this \
                Spark again. Installing on top of it could adopt state this app \
                cannot account for.
                """,
            comment: "How to clear a leftover runtime directory."
        )
    }

    static func releaseNeedsNewerDGXOS(found: String, minimum: String) -> Self {
        .init(
            "release.incompatible.minimum",
            defaultValue: "This Spark runs DGX OS \(found); the release needs \(minimum) or later.",
            comment: "The Spark's DGX OS is older than the signed release supports."
        )
    }

    static func releaseSupportsOlderDGXOS(found: String, maximum: String) -> Self {
        .init(
            "release.incompatible.maximum",
            defaultValue: "This Spark runs DGX OS \(found); the release supports up to \(maximum).",
            comment: "The Spark's DGX OS is newer than the signed release supports."
        )
    }

    static func confirmAddingDevice(to spark: String) -> Self {
        .init(
            "pairing.confirm.adding.device",
            defaultValue: "Confirm adding this Apple device to \(spark).",
            comment: "Local authentication reason shown when claiming first ownership."
        )
    }
}
