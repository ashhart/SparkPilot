import Foundation
import SparkAPI
import Testing
@testable import SparkAppComposition

private actor TestNetworkStatusReader: SparkNetworkStatusReading {
    private var calls = 0
    private var shouldFail = false

    func networkInterfaces(route: URL) async throws -> NetworkInterfacesSnapshot {
        calls += 1
        if shouldFail { throw TestError.unavailable }
        return NetworkInterfacesSnapshot(
            apiVersion: 1,
            observedAt: Date(timeIntervalSince1970: 1_788_000_000),
            interfaces: [
                NetworkInterfaceStatus(
                    name: "enp1s0",
                    type: "ethernet",
                    state: "connected",
                    connectionName: "Main LAN",
                    macAddress: "02:00:00:00:00:42",
                    mtu: 1500,
                    linkSpeedMbps: 10_000,
                    addresses: [
                        NetworkAddress(family: "ipv4", address: "192.168.100.63/24")
                    ],
                    gateway: "192.168.100.1",
                    dnsServers: ["192.168.100.1"],
                    wifiSSID: nil,
                    wifiSignalPercent: nil,
                    internet: InternetReachability(
                        reachable: true,
                        gatewayReachable: true,
                        dnsReachable: true,
                        checkedAt: Date(timeIntervalSince1970: 1_788_000_000)
                    )
                )
            ]
        )
    }

    func failNextRefresh() {
        shouldFail = true
    }

    func callCount() -> Int { calls }

    private enum TestError: Error {
        case unavailable
    }
}

@MainActor
@Test func networkStatusLoadsOnceAndKeepsTheLastGoodSnapshotOnFailure() async {
    let reader = TestNetworkStatusReader()
    let model = SparkNetworkStatusModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: reader
    )

    await model.loadIfNeeded()
    await model.loadIfNeeded()
    #expect(await reader.callCount() == 1)
    #expect(model.snapshot?.interfaces.first?.linkSpeedMbps == 10_000)
    #expect(model.snapshot?.interfaces.first?.internet.reachable == true)

    await reader.failNextRefresh()
    await model.refresh()
    #expect(await reader.callCount() == 2)
    #expect(model.snapshot?.interfaces.first?.name == "enp1s0")
    #expect(model.errorMessage?.contains("unavailable") == true)
}
