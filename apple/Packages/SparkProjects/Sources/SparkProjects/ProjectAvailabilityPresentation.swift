import Foundation
import Observation
import SparkAPI

/// QA-14: which Spark the picker opens on, so it is one that answers rather than the first in the alphabet.
public enum ProjectTargetSelection {
    /// Best first: a Spark that answers, then one that is on its way, then one that is not usable at all. Ties keep the listed order.
    static func rank(_ status: ProjectTargetStatus) -> Int {
        switch status {
        case .available: 0
        case .runtimeUpdateRequired: 1
        case .runtimeUnsupported: 2
        case .connecting: 3
        case .offline: 4
        case .unavailable: 5
        case .identityMismatch: 6
        }
    }

    public static func preferred(_ targets: [ProjectTarget]) -> String? {
        targets.min { rank($0.status) < rank($1.status) }?.id
    }
}

enum ProjectAvailabilityPresentation {
    /// QA-14: the few words the Spark picker shows beside a name; nil when there is nothing to warn about.
    static func shortState(for status: ProjectTargetStatus) -> String? {
        switch status {
        case .available: nil
        case .connecting: String(localized: "Connecting")
        case .offline: String(localized: "Offline")
        case .identityMismatch: String(localized: "Identity changed")
        case .runtimeUpdateRequired: String(localized: "Needs a runtime update")
        case .runtimeUnsupported: String(localized: "Runtime too old")
        case .unavailable: String(localized: "Projects unavailable")
        }
    }

    static func message(
        for status: ProjectTargetStatus,
        hasCache: Bool
    ) -> String {
        switch status {
        case .connecting:
            return hasCache
                ? String(localized: "This Spark is connecting. Cached projects are read-only.")
                : String(localized: "This Spark is still connecting.")
        case .offline:
            return hasCache
                ? String(localized: "This Spark is offline. Cached projects are read-only.")
                : String(localized: "This Spark is offline.")
        case .runtimeUpdateRequired:
            return hasCache
                ? String(localized: "Spark Runtime needs an update. Cached projects are read-only.")
                : String(localized: "Spark Runtime needs an update before Projects can open.")
        case .runtimeUnsupported:
            return hasCache
                ? String(
                    localized: "Projects need a newer Spark Runtime. Cached projects are read-only."
                )
                : String(localized: "Projects need a newer Spark Runtime.")
        case .unavailable:
            return hasCache
                ? String(localized: "Projects are unavailable. Cached projects are read-only.")
                : String(localized: "Projects are unavailable on this Spark.")
        case .identityMismatch:
            return String(localized: "This Spark's identity changed. Cached projects are hidden.")
        case .available:
            return ""
        }
    }
}
