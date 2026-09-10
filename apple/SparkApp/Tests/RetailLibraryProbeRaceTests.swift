import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import Testing

@testable import SparkAppComposition

/// The first probe is slow and fails; every later one answers at once, so their order is fixed.
actor ProbeRaceIdentityResolver: AuthenticatedIdentityResolving {
    private let identity: AuthenticatedIdentity
    private var calls = 0

    init(identity: AuthenticatedIdentity) { self.identity = identity }

    func startedCount() -> Int { calls }

    func resolveIdentity(
        route: URL,
        expectedNodeID: SparkNodeID?
    ) async throws -> AuthenticatedIdentity {
        calls += 1
        guard calls > 1 else {
            try? await Task.sleep(for: .milliseconds(120))
            throw URLError(.cannotConnectToHost)
        }
        return identity
    }
}

/// BH-43: a sweep, a pull-to-refresh and a card's own check all probe the same entry.
@MainActor
struct RetailLibraryProbeRaceTests {
    private func fixture() throws -> (RetailOnboardingModel, ProbeRaceIdentityResolver) {
        let resolver = ProbeRaceIdentityResolver(
            identity: try compositionLibraryTestAuthenticated(
                compositionLibraryTestIdentityJSON(node: 1)
            )
        )
        let model = try compositionLibraryTestMakeModel(resolver: resolver)
        model.library.reconcile(
            compositionLibraryTestSeedTarget(node: 1, host: "spark-a1b2.local")
        )
        return (model, resolver)
    }

    @Test func anOlderProbeResultNeverOverwritesANewerOne() async throws {
        let (model, resolver) = try fixture()
        let entryID = model.library.entries[0].id
        let sweep = Task { @MainActor in await model.updateFromProbe(entryID: entryID) }
        var spins = 0
        while await resolver.startedCount() < 1, spins < 10_000 {
            await Task.yield()
            spins += 1
        }
        let open = model.openLibraryEntry(entryID)
        await open?.value
        #expect(model.library.entry(id: entryID)?.connectionState != .offlineCached)
        _ = await sweep.value
        #expect(
            model.library.entry(id: entryID)?.connectionState != .offlineCached,
            "the slower probe's failure overwrote the newer success"
        )
    }

    @Test func overlappingChecksOfOneSparkShareASingleProbe() async throws {
        let (model, resolver) = try fixture()
        let entryID = model.library.entries[0].id
        async let sweep = model.updateFromProbe(entryID: entryID)
        async let pull = model.updateFromProbe(entryID: entryID)
        async let card = model.updateFromProbe(entryID: entryID)
        let results = await [sweep, pull, card]
        #expect(results == [false, false, false], "each caller answered from its own probe")
        #expect(
            await resolver.startedCount() == 1,
            "one Spark was probed three times at once"
        )
    }
}

/// BH-43: two overlapping checks of one card must not clear its spinner after the first ends.
@MainActor
struct FleetCheckCounterTests {
    @Test func theCheckSpinnerStaysUntilTheLastCheckOfThatSparkEnds() throws {
        let model = FleetModel(library: SparkLibrary(store: MemoryLibraryStore()))
        model.beginCheck("entry-1")
        model.beginCheck("entry-1")
        model.endCheck("entry-1")
        #expect(model.checking.contains("entry-1"), "a probe is still running for this Spark")
        model.endCheck("entry-1")
        #expect(!model.checking.contains("entry-1"))
        model.endCheck("entry-1")
        #expect(!model.checking.contains("entry-1"))
        model.beginCheck("entry-2")
        model.forget("entry-2")
        #expect(!model.checking.contains("entry-2"))
        model.beginCheck("entry-2")
        #expect(model.checking.contains("entry-2"), "forget left a stale count behind")
    }
}
