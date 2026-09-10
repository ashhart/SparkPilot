import Foundation

/// Track system-owned local-network permission and provide recovery after denial.
public enum LocalNetworkPermissionState: Sendable, Equatable {
    /// Permission has not been requested yet.
    case notDetermined
    /// Access is available (either granted or undeterminable on this OS).
    case granted
    /// Access was denied; recovery requires visiting Settings.
    case denied
    /// Access is restricted (parental controls, MDM).
    case restricted
}

/// Recovery guidance shown when local-network access is denied (UX table §62).
public struct PermissionRecovery: Sendable, Equatable {
    public let title: String
    public let message: String
    public let actionLabel: String
    public let action: Action

    public enum Action: Sendable, Equatable {
        case openApplicationSettings
        case reviewRestrictions
    }

    public init(state: LocalNetworkPermissionState) {
        if state == .restricted {
            self.title = String(localized: "Local Network Access is Restricted")
            self.message = String(
                localized: """
                    A system restriction (parental controls or device management) is \
                    preventing Spark from finding nearby hardware.
                    """
            )
            self.actionLabel = String(localized: "Review Restrictions")
            self.action = .reviewRestrictions
        } else {
            self.title = String(localized: "Spark Needs Local Network Access")
            self.message = String(
                localized: """
                    Spark finds your DGX Spark on your local network. Enable Local \
                    Network access for Spark in Settings to discover it.
                    """
            )
            self.actionLabel = String(localized: "Open Settings")
            self.action = .openApplicationSettings
        }
    }
}
