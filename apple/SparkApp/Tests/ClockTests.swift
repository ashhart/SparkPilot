import Foundation
import SparkAPI
import SparkCore
import SparkDiscovery
import SparkLibrary
import Testing
@testable import SparkAppComposition

private func clockNodeID(_ hex: UInt64) -> SparkNodeID {
    SparkNodeID(rawValue: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012llx", hex))!)
}

private func clockIdentity(node: UInt64) throws -> AuthenticatedIdentity {
    let json = """
        {"node_id":"\(clockNodeID(node).rawValue.uuidString)","cluster_id":null,"name":"Clocked Spark","role":"standalone","authority_fingerprint":"fp123","runtime_version":"0.1.0","dgx_os_version":null}
        """
    let identity = try JSONDecoder().decode(SparkIdentity.self, from: Data(json.utf8))
    return AuthenticatedIdentity(identity: identity)
}

private actor ClockIdentityResolver: AuthenticatedIdentityResolving {
    let result: Result<AuthenticatedIdentity, AuthenticatedIdentityError>

    init(_ result: Result<AuthenticatedIdentity, AuthenticatedIdentityError>) {
        self.result = result
    }

    func resolveIdentity(
        route: URL,
        expectedNodeID: SparkNodeID?
    ) async throws -> AuthenticatedIdentity {
        try result.get()
    }
}

private actor GenericFailingClockIdentityResolver: AuthenticatedIdentityResolving {
    func resolveIdentity(
        route: URL,
        expectedNodeID: SparkNodeID?
    ) async throws -> AuthenticatedIdentity {
        throw URLError(.cannotConnectToHost)
    }
}

private typealias LegacyRetailOnboardingInitializer =
    @MainActor (
        any SetupNetworkJoining,
        any CurrentWiFiNetworkReading,
        any RuntimeBootstrapInstalling,
        @escaping SparkOOBEServiceFactory,
        SparkDiscoveryService,
        BootstrapDiscoveryService,
        NetworkHandoffMonitor,
        SparkLibrary,
        any AuthenticatedIdentityResolving,
        any SparkRuntimeReading,
        @escaping @MainActor () -> Void
    ) -> RetailOnboardingModel

@MainActor
@Test func legacyRetailOnboardingInitializerRetainsItsFunctionType() {
    let initializer: LegacyRetailOnboardingInitializer = RetailOnboardingModel.init
    _ = initializer
}

@MainActor
@Test func completedOnboardingUsesOneInjectedInstantForPersistedMetadata() throws {
    let reachedAt = Date(timeIntervalSince1970: 1_790_000_000)
    let library = SparkLibrary(store: MemoryLibraryStore())
    let model = RetailOnboardingModel(library: library, now: { reachedAt })
    model.machineName = "clocked-spark"

    let route = URL(string: "https://clocked-spark.local:7443")!
    let outcome = model.recordCompletedSetup(
        route: route,
        authenticated: try clockIdentity(node: 1)
    )

    #expect(outcome?.entry.cachedAt == reachedAt)
    #expect(outcome?.entry.lastSeen == reachedAt)
    #expect(outcome?.entry.members.first?.lastSeen == reachedAt)
    #expect(outcome?.entry.members.first?.routes.first?.lastSuccess == reachedAt)
}

@MainActor
@Test func probeMismatchPersistsTheInjectedInstant() async throws {
    let mismatchAt = Date(timeIntervalSince1970: 1_790_000_000)
    let library = SparkLibrary(store: MemoryLibraryStore())
    let seedRoute = CachedRoute(
        baseURL: URL(string: "https://clocked-spark.local:7443")!,
        kind: .localWiFi
    )
    let entry = library.reconcile(
        AuthenticatedTarget(
            nodeID: clockNodeID(1),
            clusterID: nil,
            name: "Clocked Spark",
            role: .standalone,
            authorityFingerprint: "fp123",
            displayName: "clocked-spark",
            routes: [seedRoute]
        )
    ).entry
    let model = RetailOnboardingModel(
        library: library,
        identityResolver: ClockIdentityResolver(
            .failure(.nodeMismatch(presented: clockNodeID(2)))
        ),
        now: { mismatchAt }
    )

    let probe = model.openLibraryEntry(entry.id)
    await probe?.value

    #expect(library.entry(id: entry.id)?.issue == .identityMismatch)
    #expect(library.entry(id: entry.id)?.cachedAt == mismatchAt)
}

@MainActor
@Test func successfulProbePersistsTheInjectedInstant() async throws {
    let probedAt = Date(timeIntervalSince1970: 1_790_000_000)
    let library = SparkLibrary(store: MemoryLibraryStore())
    let seedRoute = CachedRoute(
        baseURL: URL(string: "https://clocked-spark.local:7443")!,
        kind: .localWiFi
    )
    let entry = library.reconcile(
        AuthenticatedTarget(
            nodeID: clockNodeID(1),
            clusterID: nil,
            name: "Clocked Spark",
            role: .standalone,
            authorityFingerprint: "fp123",
            displayName: "clocked-spark",
            routes: [seedRoute]
        )
    ).entry
    let model = RetailOnboardingModel(
        library: library,
        identityResolver: ClockIdentityResolver(.success(try clockIdentity(node: 1))),
        now: { probedAt }
    )

    let probe = model.openLibraryEntry(entry.id)
    await probe?.value

    let refreshed = library.entry(id: entry.id)
    #expect(refreshed?.cachedAt == probedAt)
    #expect(refreshed?.lastSeen == probedAt)
    #expect(refreshed?.members.first?.lastSeen == probedAt)
    #expect(refreshed?.members.first?.routes.first?.lastSuccess == probedAt)
}

@MainActor
@Test func pinRejectedProbePersistsTheInjectedInstant() async {
    let failedAt = Date(timeIntervalSince1970: 1_790_000_000)
    let library = SparkLibrary(store: MemoryLibraryStore())
    let entry = library.reconcile(
        AuthenticatedTarget(
            nodeID: clockNodeID(1),
            clusterID: nil,
            name: "Clocked Spark",
            role: .standalone,
            authorityFingerprint: "fp123",
            displayName: "clocked-spark",
            routes: [
                CachedRoute(
                    baseURL: URL(string: "https://clocked-spark.local:7443")!,
                    kind: .localWiFi
                )
            ]
        )
    ).entry
    let model = RetailOnboardingModel(
        library: library,
        identityResolver: ClockIdentityResolver(.failure(.pinRejected)),
        now: { failedAt }
    )

    let probe = model.openLibraryEntry(entry.id)
    await probe?.value

    #expect(library.entry(id: entry.id)?.cachedAt == failedAt)
    #expect(library.entry(id: entry.id)?.members.first?.reachable == false)
}

@MainActor
@Test func genericFailedProbePersistsTheInjectedInstant() async {
    let failedAt = Date(timeIntervalSince1970: 1_790_000_000)
    let library = SparkLibrary(store: MemoryLibraryStore())
    let entry = library.reconcile(
        AuthenticatedTarget(
            nodeID: clockNodeID(1),
            clusterID: nil,
            name: "Clocked Spark",
            role: .standalone,
            authorityFingerprint: "fp123",
            displayName: "clocked-spark",
            routes: [
                CachedRoute(
                    baseURL: URL(string: "https://clocked-spark.local:7443")!,
                    kind: .localWiFi
                )
            ]
        )
    ).entry
    let model = RetailOnboardingModel(
        library: library,
        identityResolver: GenericFailingClockIdentityResolver(),
        now: { failedAt }
    )

    let probe = model.openLibraryEntry(entry.id)
    await probe?.value

    #expect(library.entry(id: entry.id)?.cachedAt == failedAt)
    #expect(library.entry(id: entry.id)?.members.first?.reachable == false)
}
