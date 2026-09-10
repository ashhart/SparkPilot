import Foundation
import Network
import Testing
@testable import SparkDiscovery

@MainActor
@Test func discoveryServiceUsesInjectedTimeForStalePruning() {
    let discoveredAt = Date(timeIntervalSince1970: 1_790_000_000)
    let advertisement = NodeAdvertisement(
        instance: "clocked-node",
        endpoint: .service(
            name: "clocked-node",
            type: "_spark-runtime._tcp",
            domain: "local.",
            interface: nil
        ),
        interfaceKind: .wifi,
        txt: NodeTXT(raw: "node=12345678"),
        discoveredAt: discoveredAt
    )

    let freshService = SparkDiscoveryService(now: {
        discoveredAt.addingTimeInterval(30)
    })
    freshService.staleInterval = 30
    freshService.processAdvertisements([advertisement])
    #expect(freshService.nodes.count == 1, "the cutoff keeps its inclusive boundary")

    let staleService = SparkDiscoveryService(now: {
        discoveredAt.addingTimeInterval(31)
    })
    staleService.staleInterval = 30
    staleService.processAdvertisements([advertisement])
    #expect(staleService.nodes.isEmpty)
}
