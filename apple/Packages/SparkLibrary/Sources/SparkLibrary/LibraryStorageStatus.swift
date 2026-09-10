import Foundation
import Observation
import SparkCore

/// Distinguishes durable storage from session-only state after store failures.
public enum LibraryStorageStatus: Equatable, Sendable {
    /// Entries are written to a store that survives relaunch.
    case persistent
    /// Entries exist only for this session and will not survive relaunch.
    case sessionOnly(reason: String)

    public var isSessionOnly: Bool {
        if case .sessionOnly = self { return true }
        return false
    }
}
