import Foundation
import SparkCore
import SparkLibrary
import Testing

@testable import SparkAppComposition

/// The path line says which way the Spark is reached and names the remote host, in plain words.

@Test func everyTransportHasAPlainLabelAndOnlyRemotePathsNameTheirHost() {
    let local = SparkConnectionPath.resolve(kind: .localWiFi, host: "spark-example.local")
    #expect(local.label == "On your network")
    #expect(local.host == nil)
    #expect(!local.isRemote)

    let cable = SparkConnectionPath.resolve(kind: .directEthernet, host: "spark-direct.local")
    #expect(cable.label == "On your network")

    let tailscale = SparkConnectionPath.resolve(
        kind: .privateOverlay,
        host: "spark-example.tail1234.ts.net"
    )
    #expect(tailscale.label == "Over Tailscale")
    #expect(tailscale.host == "spark-example.tail1234.ts.net")
    #expect(tailscale.isRemote)
    #expect(tailscale.accessibilityLabel == "Over Tailscale, spark-example.tail1234.ts.net")

    for path in [local, cable, tailscale] {
        for jargon in ["overlay", "CGNAT", "MagicDNS", "WireGuard"] {
            #expect(
                !path.label.localizedCaseInsensitiveContains(jargon),
                "\(jargon) in \(path.label)"
            )
        }
    }
}

@Test func aURLAloneStillTellsTailscaleFromTheLocalNetwork() {
    func transport(_ url: String) -> SparkConnectionPath.Transport {
        SparkConnectionPath.resolve(url: URL(string: url)!).transport
    }
    #expect(transport("https://spark-example.tail1234.ts.net:7443") == .tailscale)
    #expect(transport("https://100.96.4.2:7443") == .tailscale)
    #expect(transport("https://spark-example.local:7443") == .local)
    #expect(transport("https://192.168.50.158:7443") == .local)
}

@Test func ipv6RoutesAndSimilarLookingHostnamesAreClassifiedAsAddresses() {
    func transport(_ host: String) -> SparkConnectionPath.Transport {
        SparkConnectionPath.resolve(url: URL(string: "https://\(host):7443")!).transport
    }
    #expect(transport("[fd7a:115c:a1e0::1234]") == .tailscale)
    #expect(transport("[FD7A:115C:A1E0:0000:0000:0000:0000:0001]") == .tailscale)
    #expect(transport("[fd7a:115c:a1e1::1234]") == .local)
    #expect(transport("[fe90::1]") == .local)
    #expect(transport("[2001:db8::1]") == .unknown)
    #expect(transport("fd-family.example.com") == .unknown)
    #expect(transport("fc-family.example.com") == .unknown)
    #expect(transport("spark.tail123.ts.net.") == .tailscale)
}

@MainActor
@Test func theFleetCardCarriesThePathForTheRouteInUse() {
    let snapshot = FleetPresentationTestFleetFixtures.online()
    let overlay = TargetOperationalSnapshot(
        identity: snapshot.identity,
        displayName: snapshot.displayName,
        members: snapshot.members,
        preferredRoute: snapshot.preferredRoute,
        connectionState: .connectedRemote,
        lastSuccessfulContact: snapshot.lastSuccessfulContact,
        evaluatedAt: snapshot.evaluatedAt,
        evidence: snapshot.evidence,
        runtime: snapshot.runtime,
        vllmHealth: snapshot.vllmHealth,
        unifiedMemory: snapshot.unifiedMemory,
        disk: snapshot.disk,
        installedModelCount: snapshot.installedModelCount,
        activeInference: snapshot.activeInference,
        operations: snapshot.operations,
        placements: snapshot.placements,
        warnings: snapshot.warnings,
        blockers: snapshot.blockers,
        technicalDetails: snapshot.technicalDetails,
        routeInUse: PreferredRouteSummary(
            kind: .privateOverlay,
            host: "studio-spark.tail1234.ts.net",
            port: 7_443,
            interfaceName: "tailscale",
            lastSuccessfulAt: snapshot.evaluatedAt,
            isMetered: false
        )
    )
    let cards = FleetPresentationBuilder.build(targets: [
        FleetPresentationTestFleetFixtures.input(snapshot),
        FleetPresentationTestFleetFixtures.input(overlay),
    ]).cards
    let local = cards.first { $0.connection.pathLabel == "On your network" }
    let remote = cards.first { $0.connection.pathLabel == "Over Tailscale" }
    #expect(local?.connection.pathHost == nil)
    #expect(remote?.connection.pathHost == "studio-spark.tail1234.ts.net")
    #expect(FleetCardAction.open.title == "Connect")
}

/// BH-54: a hostname's shape cannot say which way traffic goes; only the route kind can.
@Test func anUnrecognisedRemoteHostIsNeverLabelledOnYourNetwork() {
    func transport(_ url: String) -> SparkConnectionPath.Transport {
        SparkConnectionPath.resolve(url: URL(string: url)!).transport
    }
    #expect(transport("https://a7f2-spark.example.com:7443") == .unknown)
    #expect(transport("https://spark.trycloudflare.com") == .unknown)
    #expect(transport("https://203.0.113.9:7443") == .unknown)
    #expect(transport("https://spark-example.local:7443") == .local)
    #expect(transport("https://spark-example.local.:7443") == .local)
    #expect(transport("https://localhost:7443") == .local)
    #expect(transport("https://127.0.0.1:7443") == .local)
    #expect(transport("https://192.168.50.158:7443") == .local)
    #expect(transport("https://10.4.0.9:7443") == .local)
    #expect(transport("https://172.20.0.9:7443") == .local)
    #expect(transport("https://169.254.10.4:7443") == .local)
    #expect(transport("https://100.96.4.2:7443") == .tailscale)
    #expect(transport("https://spark-example.tail1234.ts.net:7443") == .tailscale)
}

@MainActor
@Test func theLibraryRouteKindDecidesThePathEvenWhenTheHostLooksLocal() throws {
    let node = FleetPresentationTestFleetFixtures.nodeID(9)
    let tunnel = CachedRoute(
        baseURL: URL(string: "https://spark-example.local:7443")!,
        kind: .privateOverlay
    )
    let entry = LibraryEntry(
        logicalKey: .node(node),
        name: "Studio Spark",
        members: [
            LibraryMember(nodeID: node, name: "Studio Spark", role: .standalone, routes: [tunnel])
        ]
    )
    let path = try #require(
        SparkConnectionPath.resolve(entry: entry, activeRouteURL: tunnel.baseURL)
    )
    #expect(path.transport == .tailscale, "the hostname's shape decided the label")
    #expect(path.label == "Over Tailscale")
}
