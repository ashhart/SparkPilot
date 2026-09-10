import Foundation

/// Decide the one primary action on the Software updates card from what the Spark reported.
enum SparkSettingsUpdatesPresentation {
    enum PrimaryAction: Equatable {
        case install, restart, nothing
    }

    static func primaryAction(
        systemPackages: Int?,
        firmware: Int?,
        runtimeUpdateAvailable: Bool,
        rebootRequired: Bool,
        canRestart: Bool
    ) -> PrimaryAction {
        if (systemPackages ?? 0) > 0 || (firmware ?? 0) > 0 || runtimeUpdateAvailable {
            return .install
        }
        if rebootRequired, canRestart { return .restart }
        return .nothing
    }

    /// The line under "A restart is required." that says what the restart finishes.
    static func restartDetail(primary: PrimaryAction) -> String {
        switch primary {
        case .restart:
            String(localized: "The installed updates finish when the Spark restarts.")
        case .install:
            String(localized: "Restart the Spark after installing to finish every update.")
        case .nothing:
            String(localized: "Restart the Spark from its Power controls to finish the update.")
        }
    }
}
