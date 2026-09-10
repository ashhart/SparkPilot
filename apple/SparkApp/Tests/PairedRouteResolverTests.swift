import Foundation
@_spi(SparkTestSupport) import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
@_spi(SparkTestSupport) import SparkTransport
import Testing
@testable import SparkAppComposition

private enum PairedRouteTestError: Error { case signingReached }

private let pairedRouteNode = UUID(uuidString: "00000000-0000-4000-8000-000000000099")!
private let pairedRouteTrust = NodeTrust(
    nodeID: pairedRouteNode.uuidString.lowercased(),
    nodeName: "Test Spark",
    tlsFingerprint: String(repeating: "a", count: 64),
    authorityFingerprint: String(repeating: "b", count: 64),
    authorityPublicKey: String(repeating: "c", count: 64),
    pairedAt: Date()
)

/// Mirrors the owner phone: signed Tailscale hints have no cached certificate of their own.
@MainActor
@Test func defaultRemoteResolverUsesTheExistingPairingInsteadOfRefusingEveryHint() async throws {
    let workflows = RetailOnboardingWorkflows(
        library: SparkLibrary(store: MemoryLibraryStore()),
        signerProvider: { node in
            #expect(node == pairedRouteNode)
            throw PairedRouteTestError.signingReached
        },
        nodeTrustReader: { id in id == pairedRouteTrust.nodeID ? pairedRouteTrust : nil }
    )
    do {
        _ = try await workflows.identityResolver.resolveIdentity(
            route: URL(string: "https://100.100.100.1:7443")!,
            expectedNodeID: SparkNodeID(rawValue: pairedRouteNode)
        )
        Issue.record("The test signer must be used before attempting the paired connection")
    } catch PairedRouteTestError.signingReached {
        // The default path reached the paired signer, rather than the permanently unbound stub.
    } catch {
        Issue.record("The default remote route never reached paired authentication: \(error)")
    }
}

private struct PairedRouteIdentityReader: NetworkHandoffIdentityChecking {
    let document: SparkIdentity
    func identity(route: URL) async throws -> SparkIdentity { document }
}

@MainActor
@Test func pairedRemoteIdentityRequiresBothNodeAndAuthority() async throws {
    for mismatch in ["none", "node", "authority"] {
        let node = mismatch == "node" ? UUID() : pairedRouteNode
        let authority = mismatch == "authority" ? "wrong" : pairedRouteTrust.authorityFingerprint
        let document = try JSONDecoder().decode(
            SparkIdentity.self,
            from: Data(
                """
                {"node_id":"\(node)","cluster_id":null,"name":"Test Spark","role":"standalone",
                 "authority_fingerprint":"\(authority)","runtime_version":"0.1.12","dgx_os_version":null}
                """.utf8
            )
        )
        let resolver = PairedIdentityResolver(nodeTrustReader: { _ in pairedRouteTrust }) { trust in
            #expect(trust.tlsFingerprint == pairedRouteTrust.tlsFingerprint)
            return PairedRouteIdentityReader(document: document)
        }
        do {
            let result = try await resolver.resolveIdentity(
                route: URL(string: "https://100.100.100.1:7443")!,
                expectedNodeID: SparkNodeID(rawValue: pairedRouteNode)
            )
            #expect(mismatch == "none")
            #expect(result.nodeID.rawValue == pairedRouteNode)
        } catch AuthenticatedIdentityError.nodeMismatch {
            #expect(mismatch == "node")
        } catch AuthenticatedIdentityError.pinRejected {
            #expect(mismatch == "authority")
        }
    }
}

@MainActor
@Test func unknownRemoteRouteCannotCreateItsOwnTrust() async throws {
    let resolver = PairedIdentityResolver(
        nodeTrustReader: { _ in nil },
        checker: { _ in
            Issue.record("Unpaired routes must never reach the transport")
            throw PairedRouteTestError.signingReached
        }
    )
    await #expect(throws: AuthenticatedIdentityError.unbound) {
        try await resolver.resolveIdentity(
            route: URL(string: "https://100.100.100.1:7443")!,
            expectedNodeID: SparkNodeID(rawValue: pairedRouteNode)
        )
    }
}

@MainActor
@Test func remoteOnlyColdLaunchUsesPairedTransportWithoutACachedRoutePin() async throws {
    var signerUsed = false
    let library = SparkLibrary(store: MemoryLibraryStore())
    let model = RetailOnboardingModel(
        library: library,
        savedRouteDiscovery: CompositionLibraryTestStaticSavedSparkRouteDiscovery(routes: []),
        signerProvider: { _ in
            signerUsed = true
            throw PairedRouteTestError.signingReached
        },
        nodeTrustReader: { _ in pairedRouteTrust }
    )
    let entry = library.reconcile(
        AuthenticatedTarget(
            nodeID: SparkNodeID(rawValue: pairedRouteNode),
            clusterID: nil,
            name: "Test Spark",
            role: .standalone,
            authorityFingerprint: pairedRouteTrust.authorityFingerprint,
            displayName: "test-spark",
            routes: [
                CachedRoute(
                    baseURL: URL(string: "https://100.100.100.1:7443")!,
                    kind: .privateOverlay
                )
            ]
        )
    ).entry
    await model.openLibraryEntry(entry.id)?.value
    #expect(signerUsed, "A remote hint must use the node's existing pairing on a cold launch")
    #expect(model.dashboardModel == nil, "A failed signer must not publish a dashboard")
}

private struct PairedRouteTransport: PinnedHTTPTransport {
    let pin = pairedRouteTrust.tlsFingerprint
    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data = Data(
            """
            {"node_id":"\(pairedRouteNode)","cluster_id":null,"name":"Test Spark","role":"standalone",
             "authority_fingerprint":"\(pairedRouteTrust.authorityFingerprint)","runtime_version":"0.1.12","dgx_os_version":null}
            """.utf8
        )
        return (
            data,
            HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
        )
    }
}

@MainActor
@Test func remoteOnlyColdLaunchRetainsTheAuthenticatedClientForTheDashboard() async throws {
    let library = SparkLibrary(store: MemoryLibraryStore())
    let resolver = PairedIdentityResolver(nodeTrustReader: { _ in pairedRouteTrust }) { _ in
        SparkAPIClient(transport: PairedRouteTransport())
    }
    let model = RetailOnboardingModel(
        library: library,
        identityResolver: resolver,
        savedRouteDiscovery: CompositionLibraryTestStaticSavedSparkRouteDiscovery(routes: []),
        nodeTrustReader: { _ in pairedRouteTrust }
    )
    let route = URL(string: "https://100.100.100.1:7443")!
    let entry = library.reconcile(
        AuthenticatedTarget(
            nodeID: SparkNodeID(rawValue: pairedRouteNode),
            clusterID: nil,
            name: "Test Spark",
            role: .standalone,
            authorityFingerprint: pairedRouteTrust.authorityFingerprint,
            displayName: "test-spark",
            routes: [CachedRoute(baseURL: route, kind: .privateOverlay)]
        )
    ).entry
    await model.openLibraryEntry(entry.id)?.value
    #expect(model.libraryOpenFailure == nil)
    #expect(model.dashboardModel?.route == route)
    #expect(library.entry(id: entry.id)?.connectionState == .connectedRemote)
}
