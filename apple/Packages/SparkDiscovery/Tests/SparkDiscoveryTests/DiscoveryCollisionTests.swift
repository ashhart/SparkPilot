import Foundation
import Network
import Testing
@testable import SparkDiscovery

@Test func copiedNodeHintCannotEvictAnotherDiscoveryEndpoint() {
    var merger = DiscoveryMerger()
    let now = Date()
    let first = NodeAdvertisement(
        instance: "Family Spark",
        endpoint: .hostPort(host: "192.0.2.1", port: 7443),
        interfaceKind: .wifi,
        txt: NodeTXT(raw: "node=7a836150"),
        discoveredAt: now
    )
    let other = NodeAdvertisement(
        instance: "Family Spark",
        endpoint: .hostPort(host: "192.0.2.2", port: 7443),
        interfaceKind: .wifi,
        txt: NodeTXT(raw: "node=7a836150"),
        discoveredAt: now.addingTimeInterval(1)
    )
    _ = merger.upsert(first)
    let candidates = merger.upsert(other)
    #expect(candidates.count == 2)
    #expect(candidates.contains(first))
}
