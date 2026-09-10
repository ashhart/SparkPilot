import Foundation
@_spi(SparkTestSupport) import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
@_spi(SparkTestSupport) import SparkTransport
import Testing
@testable import SparkAppComposition

private let reconnectNode = UUID(uuidString: "00000000-0000-4000-8000-000000000099")!
private let reconnectTrust = NodeTrust(
    nodeID: reconnectNode.uuidString.lowercased(), nodeName: "Test Spark",
    tlsFingerprint: String(repeating: "a", count: 64),
    authorityFingerprint: String(repeating: "b", count: 64),
    authorityPublicKey: String(repeating: "c", count: 64), pairedAt: Date()
)

/// The network changes; the Spark's identity and the phone's pairing do not.
private final class ReconnectNetwork: PinnedHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    let pin = reconnectTrust.tlsFingerprint
    private var away = false
    private var recordedRequests: [URL] = []
    var requests: [URL] { lock.withLock { recordedRequests } }

    func leaveHome() { lock.withLock { away = true } }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let isAway = lock.withLock { recordedRequests.append(url); return away }
        if isAway && url.host == "spark-home.local" { throw URLError(.cannotConnectToHost) }
        let data = Data("""
            {"node_id":"\(reconnectNode)","cluster_id":null,"name":"Test Spark","role":"standalone",
             "authority_fingerprint":"\(reconnectTrust.authorityFingerprint)","runtime_version":"0.1.12","dgx_os_version":null}
            """.utf8)
        return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor
private func reconnectModel(network: ReconnectNetwork) -> (
    RetailOnboardingModel, PairedIdentityResolver, String
) {
    let library = SparkLibrary(store: MemoryLibraryStore())
    let resolver = PairedIdentityResolver(nodeTrustReader: { _ in reconnectTrust }) { _ in
        SparkAPIClient(transport: network)
    }
    let model = RetailOnboardingModel(
        library: library, identityResolver: resolver,
        savedRouteDiscovery: CompositionLibraryTestStaticSavedSparkRouteDiscovery(routes: []),
        nodeTrustReader: { _ in reconnectTrust }
    )
    // The persisted library and trust represent yesterday's completed pairing.
    let entry = library.reconcile(AuthenticatedTarget(
        nodeID: SparkNodeID(rawValue: reconnectNode), clusterID: nil,
        name: "Test Spark", role: .standalone,
        authorityFingerprint: reconnectTrust.authorityFingerprint,
        displayName: "spark-home",
        routes: [CachedRoute(baseURL: URL(string: "https://spark-home.local:7443")!, kind: .localWiFi)]
    )).entry
    return (model, resolver, entry.id)
}

@Suite(.serialized)
@MainActor
struct TailscaleReconnectReproductionTests {
    @Test(arguments: ["100.100.7.9", "spark.example.ts.net"])
    func tailscaleReconnectControlAuthenticatesANewRouteWithoutPairing(host: String) async throws {
        let network = ReconnectNetwork()
        let (model, resolver, entryID) = reconnectModel(network: network)
        await model.openLibraryEntry(entryID)?.value
        #expect(model.dashboardModel?.route.host == "spark-home.local")
        model.closeDashboard()
        network.leaveHome()
        await model.openLibraryEntry(entryID)?.value
        #expect(model.dashboardModel == nil)
        #expect(model.libraryOpenFailure != nil)

        // Control: the existing registration service can authenticate the new address.
        let registration = LibraryRemoteAccessRouteRegistration(
            library: model.library, identityResolver: resolver, targetID: entryID
        )
        try await registration.registerPrivateOverlay(
            hostname: host, basedOn: URL(string: "https://spark-home.local:7443")!
        )
        await model.openLibraryEntry(entryID)?.value
        #expect(model.dashboardModel?.route.host == host)
        #expect(model.library.entries.count == 1)
        #expect(model.libraryOpenFailure == nil)
        #expect(model.library.entry(id: entryID)?.connectionState == .connectedRemote)
    }

    @MainActor
    @Test(arguments: ["100.100.7.9", "spark.example.ts.net"])
    func tailscaleReconnectRemovingAndReaddingEntersSetupDespiteRetainedPairing(host: String) async throws {
        let network = ReconnectNetwork()
        let (model, resolver, entryID) = reconnectModel(network: network)
        await model.openLibraryEntry(entryID)?.value
        #expect(model.dashboardModel?.route.host == "spark-home.local")
        model.closeDashboard()
        network.leaveHome()
        await model.openLibraryEntry(entryID)?.value
        #expect(model.dashboardModel == nil)
        #expect(model.libraryOpenFailure != nil)

        model.removeLibraryEntry(entryID)
        #expect(model.library.entries.isEmpty)
        // Prove the same saved trust still authenticates the reachable remote Spark after removal.
        let remote = URL(string: "https://\(host):7443")!
        let identity = try await resolver.resolveIdentity(
            route: remote, expectedNodeID: SparkNodeID(rawValue: reconnectNode)
        )
        #expect(identity.nodeID.rawValue == reconnectNode)
        let requestsBeforeReadding = network.requests.count

        #expect(model.chooseExistingSpark(host: host))
        #expect(model.pairingDeviceTarget != nil, "The address opens QR/invitation pairing")
        model.finishInterruptedFirstOwnerSetup()
        #expect(model.state.phase == .runtimeInstall)
        #expect(model.needsExistingSparkReview)
        #expect(model.bootstrapTarget != nil)
        #expect(model.library.entries.isEmpty)
        #expect(network.requests.count == requestsBeforeReadding,
                "Re-adding and resuming setup never attempt the existing paired connection")
        withKnownIssue("Re-adding a paired Spark by its Tailscale address enters installation recovery") {
            #expect(model.dashboardModel?.route == remote,
                    "A previously paired phone cannot reconnect through this address-entry flow")
        }
    }

}
