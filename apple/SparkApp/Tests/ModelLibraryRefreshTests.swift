import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing
@testable import SparkAppComposition

@MainActor
@Test func repeatedOperationCursorNeverPublishesAnIncompleteHistory() async throws {
    let nodeID = SparkNodeID(rawValue: UUID(uuidString: "93e82da2-7fb7-4b4b-9584-4a528000ac94")!)
    let entry = modelLibraryTestLibraryEntry(nodeID: nodeID)
    let store = MemoryLibraryStore()
    try store.save([entry])
    let library = SparkLibrary(store: store)
    library.load()
    let repeatedPage: OperationPage = try modelLibraryTestLibraryDecode(
        """
        {"items":[{"id":"a2944316-f58d-43cc-8725-ae351e782a58","kind":"model.install","state":"succeeded","progress":1,"stage":null,"error_code":null,"cancellable":false}],"next_cursor":"same-cursor"}
        """
    )
    let runtime = ModelLibraryTestModelLibraryRuntimeStub(
        presentedNodeID: nodeID.rawValue.uuidString.lowercased(),
        authorityFingerprint: "authority-a",
        operationPages: [repeatedPage, repeatedPage]
    )
    let provider = SignedCrossTargetModelLibraryProvider(
        library: library,
        now: { modelLibraryTestLibraryEvidenceDate },
        runtimeResolver: { _ in
            ModelLibraryRuntimeConnection(
                route: URL(string: "https://studio-spark.local:7443")!,
                expectedNodeID: nodeID,
                expectedClusterID: nil,
                expectedAuthorityFingerprint: "authority-a",
                runtime: runtime
            )
        }
    )

    _ = try await provider.fetchSnapshot()

    let snapshot = try #require(library.entry(id: entry.id)?.cachedOperationalSnapshot)
    #expect(snapshot.operations.isEmpty)
    #expect(snapshot.evidence.operations.state == .missing)
}

@MainActor
@Test func injectedProviderReadsFreshEvidenceThenFallsBackToSharedSnapshot() async throws {
    let nodeID = SparkNodeID(rawValue: UUID(uuidString: "63e82da2-7fb7-4b4b-9584-4a528000ac94")!)
    let entry = modelLibraryTestLibraryEntry(nodeID: nodeID)
    let store = MemoryLibraryStore()
    try store.save([entry])
    let library = SparkLibrary(store: store)
    library.load()
    let runtime = ModelLibraryTestModelLibraryRuntimeStub(
        presentedNodeID: nodeID.rawValue.uuidString.lowercased(),
        authorityFingerprint: "authority-a"
    )
    let provider = SignedCrossTargetModelLibraryProvider(
        library: library,
        now: { modelLibraryTestLibraryEvidenceDate },
        runtimeResolver: { _ in
            ModelLibraryRuntimeConnection(
                route: URL(string: "https://studio-spark.local:7443")!,
                expectedNodeID: nodeID,
                expectedClusterID: nil,
                expectedAuthorityFingerprint: "authority-a",
                runtime: runtime
            )
        }
    )

    let fresh = try await provider.fetchSnapshot()
    #expect(
        fresh.targets.first?.freshness == .current(observedAt: modelLibraryTestLibraryEvidenceDate)
    )
    #expect(fresh.models.first?.recommendation?.targetName == "Studio Spark")
    #expect(fresh.models.first?.profiles.first?.maxModelLength == 32_768)
    #expect(fresh.models.first?.profiles.first?.maxSequences == 4)
    let freshOperations = try #require(
        library.entry(id: entry.id)?.cachedOperationalSnapshot?.operations
    )
    #expect(freshOperations.map(\.kind) == ["model.install"])
    #expect(
        library.entry(id: entry.id)?.cachedOperationalSnapshot?.evidence.operations.state
            == .current
    )

    await runtime.setShouldFail(true)
    let relaunchedProvider = SignedCrossTargetModelLibraryProvider(
        library: library,
        now: { modelLibraryTestLibraryEvidenceDate },
        runtimeResolver: { _ in
            ModelLibraryRuntimeConnection(
                route: URL(string: "https://studio-spark.local:7443")!,
                expectedNodeID: nodeID,
                expectedClusterID: nil,
                expectedAuthorityFingerprint: "authority-a",
                runtime: runtime
            )
        }
    )
    let cached = try await relaunchedProvider.fetchSnapshot()
    #expect(
        cached.targets.first?.freshness == .stale(observedAt: modelLibraryTestLibraryEvidenceDate)
    )
    #expect(cached.models.first?.recommendation == nil)
    #expect(cached.models.first?.coverage.cachedRunningTargets == ["Studio Spark"])
}

@MainActor
@Test func authenticatedRouteChurnKeepsOneTargetAndOneSignedModel() async throws {
    let nodeID = SparkNodeID(rawValue: UUID(uuidString: "b63e82da-7fb7-4b4b-9584-4a528000ac94")!)
    let entry = modelLibraryTestLibraryEntry(nodeID: nodeID)
    let store = MemoryLibraryStore()
    try store.save([entry])
    let library = SparkLibrary(store: store)
    library.load()
    let runtime = ModelLibraryTestModelLibraryRuntimeStub(
        presentedNodeID: nodeID.rawValue.uuidString.lowercased(),
        authorityFingerprint: "authority-a"
    )
    let provider = SignedCrossTargetModelLibraryProvider(
        library: library,
        now: { modelLibraryTestLibraryEvidenceDate },
        runtimeResolver: { currentEntry in
            ModelLibraryRuntimeConnection(
                route: currentEntry.preferredRoute!.baseURL,
                expectedNodeID: nodeID,
                expectedClusterID: nil,
                expectedAuthorityFingerprint: "authority-a",
                runtime: runtime
            )
        }
    )

    let initial = try await provider.fetchSnapshot()
    library.markReachable(
        entryID: entry.id,
        nodeID: nodeID,
        route: CachedRoute(
            baseURL: URL(string: "https://192.168.100.63:7443")!,
            kind: .directEthernet,
            lastSuccess: modelLibraryTestLibraryEvidenceDate
        ),
        at: modelLibraryTestLibraryEvidenceDate
    )
    let rebound = try await provider.fetchSnapshot()

    #expect(initial.targets.count == 1)
    #expect(initial.models.count == 1)
    #expect(rebound.targets.count == 1)
    #expect(rebound.models.count == 1)
    #expect(rebound.models.first?.id == initial.models.first?.id)
    #expect(library.entries.count == 1)
    #expect(library.entry(id: entry.id)?.cachedOperationalSnapshot?.identity == .node(nodeID))
}

@MainActor
@Test func providerRejectsCatalogueWhenAuthenticatedIdentityDoesNotMatchLibrary() async throws {
    let expected = SparkNodeID(rawValue: UUID(uuidString: "63e82da2-7fb7-4b4b-9584-4a528000ac94")!)
    let presented = "73e82da2-7fb7-4b4b-9584-4a528000ac94"
    let store = MemoryLibraryStore()
    try store.save([modelLibraryTestLibraryEntry(nodeID: expected)])
    let library = SparkLibrary(store: store)
    library.load()
    let runtime = ModelLibraryTestModelLibraryRuntimeStub(
        presentedNodeID: presented,
        authorityFingerprint: "authority-a"
    )
    let provider = SignedCrossTargetModelLibraryProvider(
        library: library,
        now: { modelLibraryTestLibraryEvidenceDate },
        runtimeResolver: { _ in
            ModelLibraryRuntimeConnection(
                route: URL(string: "https://studio-spark.local:7443")!,
                expectedNodeID: expected,
                expectedClusterID: nil,
                expectedAuthorityFingerprint: "authority-a",
                runtime: runtime
            )
        }
    )

    let snapshot = try await provider.fetchSnapshot()
    #expect(snapshot.targets.first?.freshness == .unavailable)
    #expect(snapshot.models.isEmpty)
}

@MainActor
@Test func wideSurfaceRefreshAdvancesFleetAndWorkloadsWithoutOpeningModels() async throws {
    let nodeID = SparkNodeID(rawValue: UUID(uuidString: "83e82da2-7fb7-4b4b-9584-4a528000ac94")!)
    let entry = modelLibraryTestLibraryEntry(nodeID: nodeID)
    let store = MemoryLibraryStore()
    try store.save([entry])
    let library = SparkLibrary(store: store, now: { modelLibraryTestLibraryEvidenceDate })
    library.load()
    let runtime = ModelLibraryTestModelLibraryRuntimeStub(
        presentedNodeID: nodeID.rawValue.uuidString.lowercased(),
        authorityFingerprint: "authority-a"
    )
    let provider = SignedCrossTargetModelLibraryProvider(
        library: library,
        now: { modelLibraryTestLibraryEvidenceDate },
        runtimeResolver: { _ in
            ModelLibraryRuntimeConnection(
                route: URL(string: "https://studio-spark.local:7443")!,
                expectedNodeID: nodeID,
                expectedClusterID: nil,
                expectedAuthorityFingerprint: "authority-a",
                runtime: runtime
            )
        }
    )
    let modelLibrary = CrossTargetModelLibraryModel(provider: provider)
    let fleet = FleetModel(library: library, now: { modelLibraryTestLibraryEvidenceDate })
    let workloads = WorkloadComparisonModel(snapshot: .empty)

    await runtime.setShouldFail(true)
    await OperationalSurfaceRefresh.run(
        modelLibrary: modelLibrary,
        library: library,
        workloads: workloads,
        at: modelLibraryTestLibraryEvidenceDate
    )
    #expect(fleet.presentation.cards.first?.installedModels == "Unknown")
    #expect(workloads.snapshot.rows.isEmpty)

    await runtime.setShouldFail(false)
    await OperationalSurfaceRefresh.run(
        modelLibrary: modelLibrary,
        library: library,
        workloads: workloads,
        at: modelLibraryTestLibraryEvidenceDate
    )
    // Check source defaults here and singular plural forms in compiled-product tests.
    #expect(fleet.presentation.cards.first?.installedModels.hasPrefix("1 model") == true)
    #expect(workloads.snapshot.rows.map(\.name) == ["Model 8B"])
    #expect(workloads.snapshot.targets.map(\.name) == ["Studio Spark"])
}

/// Cancelled refreshes must leave hasLoaded false so loadIfNeeded can retry without relaunching.
@MainActor
@Test func aCancelledRefreshDoesNotCountAsHavingLoaded() async {
    let provider = ModelLibraryTestCancellingLibraryProvider()
    let model = CrossTargetModelLibraryModel(provider: provider)

    await model.loadIfNeeded()

    #expect(!model.hasLoaded, "a cancelled read was recorded as a completed load")
    #expect(model.errorMessage == nil, "leaving the screen is not an error to report")

    await model.loadIfNeeded()
    #expect(await provider.callCount() == 2, "the retry was refused after a cancelled pass")
}

/// A definitive failure must settle with an error rather than trigger indefinite retries.
@MainActor
@Test func aFailedRefreshSettlesAndExplainsItself() async {
    let model = CrossTargetModelLibraryModel(provider: ModelLibraryTestFailingLibraryProvider())

    await model.loadIfNeeded()

    #expect(model.hasLoaded)
    #expect(model.errorMessage != nil)
}
