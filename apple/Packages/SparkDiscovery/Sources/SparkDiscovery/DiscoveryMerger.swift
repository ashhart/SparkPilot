import Foundation

/// Collapse repeated observations of one endpoint without trusting advertised identity hints.
public struct DiscoveryMerger: Sendable {
    private var byKey: [String: NodeAdvertisement] = [:]

    public init() {}

    /// Keep the newest observation of each endpoint until signed identity validation can group nodes.
    public mutating func upsert(_ advertisement: NodeAdvertisement) -> [NodeAdvertisement] {
        if let existing = byKey[advertisement.mergeKey] {
            // Keep the existing entry when observation timestamps tie.
            if advertisement.discoveredAt >= existing.discoveredAt {
                byKey[advertisement.mergeKey] = advertisement
            }
        } else {
            byKey[advertisement.mergeKey] = advertisement
        }
        return Array(byKey.values)
    }

    /// Drop advertisements that have not been refreshed within `staleInterval`.
    public mutating func removeStale(olderThan interval: TimeInterval, now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-interval)
        byKey = byKey.filter { $0.value.discoveredAt >= cutoff }
    }

    public var all: [NodeAdvertisement] {
        Array(byKey.values)
    }

    public var count: Int {
        byKey.count
    }
}
