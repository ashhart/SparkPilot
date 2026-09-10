import Foundation
import Observation

/// What a guest may read of the grant behind one Spark: the outcome of asking that Spark.
public enum GuestGrantReading: Equatable, Sendable {
    case shared([String])
    case notAGuest
    case unknown
}

/// The models each Spark's owner shared with this device, kept per node so chat can read them.
@MainActor
@Observable
public final class GuestAccessRegistry {
    public static let shared = GuestAccessRegistry()

    private var allowedModelsByNode: [String: [String]] = [:]

    public init() {}

    /// The owner's allow-list for this node, or nil when this device is not known to be its guest.
    public func allowedModels(forNode nodeID: String) -> [String]? {
        allowedModelsByNode[nodeID.lowercased()]
    }

    public func record(allowedModels: [String], forNode nodeID: String) {
        allowedModelsByNode[nodeID.lowercased()] = allowedModels
    }

    public func forget(node nodeID: String) {
        allowedModelsByNode[nodeID.lowercased()] = nil
    }

    public func apply(_ reading: GuestGrantReading, toNode nodeID: String) {
        switch reading {
        case .shared(let models): record(allowedModels: models, forNode: nodeID)
        case .notAGuest: forget(node: nodeID)
        case .unknown: break
        }
    }
}
