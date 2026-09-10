import Foundation
import SparkCore
import SparkLibrary
import Testing

@testable import SparkAppComposition

/// The Spark's own OpenAI-compatible address follows the path in use and says so when it differs from home.

@Test func theSparkAPIAddressIsTheRouteInUseWithV1AndSaysWhichPathItIsOn() throws {
    let local = try #require(SparkAPIAddress(route: URL(string: "https://spark-example.local:7443")!))
    #expect(local.baseURL.absoluteString == "https://spark-example.local:7443/v1")
    #expect(local.path.transport == .local)
    #expect(local.note.contains("On your network"))
    #expect(local.note.contains("https://spark-example.local:7443/v1"))
    #expect(local.note.contains("Tailscale name"))

    let tailscale = try #require(
        SparkAPIAddress(route: URL(string: "https://spark-example.tail1234.ts.net:7443")!)
    )
    #expect(tailscale.baseURL.absoluteString == "https://spark-example.tail1234.ts.net:7443/v1")
    #expect(tailscale.path.transport == .tailscale)
    #expect(tailscale.path.host == "spark-example.tail1234.ts.net")
    #expect(tailscale.note.contains("over Tailscale"))
    #expect(tailscale.note.contains("https://spark-example.tail1234.ts.net:7443/v1"))
    #expect(tailscale.note.contains("local address"))
}

@Test func aRouteWithoutAHostHasNoAPIAddress() {
    #expect(SparkAPIAddress(route: URL(fileURLWithPath: "/tmp")) == nil)
}

@Test func theOverlayAddressKeepsTheSparksPortAndUsesItsTailscaleName() throws {
    let local = URL(string: "https://192.168.50.158:7443")!
    let overlay = try #require(
        SparkAPIAddress.overlay(hostname: "spark-example.tail1234.ts.net", basedOn: local)
    )
    #expect(overlay.baseURL.absoluteString == "https://spark-example.tail1234.ts.net:7443/v1")
    #expect(overlay.path.transport == .tailscale)
    #expect(
        SparkAPIAddress.overlay(hostname: "100.96.4.2", basedOn: local)?.path.transport
            == .tailscale
    )
    #expect(SparkAPIAddress.overlay(hostname: "spark.evil.example", basedOn: local) == nil)
    #expect(SparkAPIAddress.overlay(hostname: "", basedOn: local) == nil)
}

@Test func theHarnessNoteNamesEverySettingThatCarriesTheAddressAndTheBridgeThatDoesNot() {
    for setting in [
        "OPENAI_BASE_URL", "ANTHROPIC_BASE_URL", "model_providers.spark.base_url",
        "provider.spark.options.baseURL", "providers.spark.base_url",
        "providers.spark.baseUrl",
    ] {
        #expect(SparkAPIAddress.harnessNote.contains(setting), "missing \(setting)")
    }
    #expect(SparkAPIAddress.bridgeNote.contains("127.0.0.1"))
    #expect(SparkAPIAddress.bridgeNote.localizedCaseInsensitiveContains("does not change"))
}

@MainActor
@Test func chatAndDeveloperTargetsCarryTheRouteInUseNotTheRankFirstOne() throws {
    let fixture = try chatTestFixtureLibrary()
    let nodeID = SparkNodeID(rawValue: fixture.target.nodeID)
    let entryID = SparkTargetIdentity.node(nodeID).description
    let overlay = CachedRoute(
        baseURL: URL(string: "https://spark-example.tail1234.ts.net:7443")!,
        kind: .privateOverlay,
        interfaceName: "tailscale",
        lastSuccess: nil
    )
    fixture.library.markReachable(
        entryID: entryID,
        nodeID: nodeID,
        route: overlay,
        at: fixture.now.addingTimeInterval(1)
    )

    let catalogue = LocalSparkChatTargetProvider(
        library: fixture.library,
        trustLookup: { _ in chatTestTrust(for: fixture.target) },
        now: { fixture.now.addingTimeInterval(2) }
    ).catalogue()

    let target = try #require(catalogue.targets.first)
    #expect(target.route.host() == "spark-example.tail1234.ts.net")
    #expect(
        fixture.library.entry(id: entryID)?.preferredRoute?.kind == .localWiFi,
        "rank order still prefers the local route; the target follows the route that answered"
    )
    let address = try #require(SparkAPIAddress(route: target.route))
    #expect(address.path.transport == .tailscale)
    #expect(address.baseURL.absoluteString == "https://spark-example.tail1234.ts.net:7443/v1")
}
