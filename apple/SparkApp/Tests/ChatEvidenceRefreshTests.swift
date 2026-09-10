import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing
@testable import SparkAppComposition

@MainActor
@Test func chatEvidenceRefreshReadsOnlyHealthAndStatusDuringModelStartup() async throws {
    let clock = ModelLibraryTestChatEvidenceClock()
    let runtime = ModelLibraryTestModelLibraryRuntimeStub(
        presentedNodeID: modelLibraryTestChatEvidenceNodeID.rawValue.uuidString,
        authorityFingerprint: "authority-a",
        inferenceState: "loading"
    )
    let fixture = try modelLibraryTestChatEvidenceFixture(runtime: runtime, clock: clock)

    await fixture.provider.refreshChatEvidence()

    let snapshot = try #require(
        fixture.library.operationalSnapshot(for: fixture.entryID, at: clock.now())
    )
    #expect(snapshot.connectionState == .connectedWiFi)
    #expect(snapshot.activeInference?.state == .loading)
    #expect(snapshot.evidence.inference.state == .current)
    #expect(await runtime.requestedEndpoints() == ["health", "status"])
}

@MainActor
@Test func chatEvidencePublishesReachabilityWhileStatusWaitsAndDatesStatusAtCompletion()
    async throws
{
    let clock = ModelLibraryTestChatEvidenceClock()
    let runtime = ModelLibraryTestModelLibraryRuntimeStub(
        presentedNodeID: modelLibraryTestChatEvidenceNodeID.rawValue.uuidString,
        authorityFingerprint: "authority-a",
        pauseStatus: true
    )
    let fixture = try modelLibraryTestChatEvidenceFixture(runtime: runtime, clock: clock)
    let refresh = Task { await fixture.provider.refreshChatEvidence() }
    for _ in 0..<2_000 {
        if await runtime.isStatusPaused() { break }
        await Task.yield()
    }
    #expect(await runtime.isStatusPaused())
    let waiting = fixture.library.operationalSnapshot(for: fixture.entryID, at: clock.now())
    #expect(waiting?.evidence.health.state == .current)
    #expect(waiting?.connectionState == .connectedWiFi)
    #expect(waiting?.evidence.inference.state == .missing)

    clock.advance(by: 20)
    await runtime.resumeStatus()
    await refresh.value

    let completed = try #require(
        fixture.library.operationalSnapshot(for: fixture.entryID, at: clock.now())
    )
    #expect(completed.evidence.inference.state == .current)
    #expect(completed.evidence.inference.observedAt == clock.now())
    #expect(completed.activeInference?.state == .ready)
    #expect(await runtime.requestedEndpoints() == ["health", "status"])
}

@MainActor
@Test func chatEvidenceStatusFailureRetainsProvenReachabilityWithoutFreshInference() async throws {
    let clock = ModelLibraryTestChatEvidenceClock()
    let runtime = ModelLibraryTestModelLibraryRuntimeStub(
        presentedNodeID: modelLibraryTestChatEvidenceNodeID.rawValue.uuidString,
        authorityFingerprint: "authority-a",
        statusFails: true
    )
    let fixture = try modelLibraryTestChatEvidenceFixture(runtime: runtime, clock: clock)

    await fixture.provider.refreshChatEvidence()

    let snapshot = try #require(
        fixture.library.operationalSnapshot(for: fixture.entryID, at: clock.now())
    )
    #expect(snapshot.connectionState == .connectedWiFi)
    #expect(snapshot.evidence.health.state == .current)
    #expect(snapshot.evidence.inference.state == .missing)
    #expect(snapshot.activeInference == nil)
}

@MainActor
@Test(arguments: ["node", "authority", "unexpected-cluster", "missing-cluster"])
func chatEvidenceRejectsIdentityAndTopologyMismatches(mismatch: String) async throws {
    let clock = ModelLibraryTestChatEvidenceClock()
    let runtime = ModelLibraryTestModelLibraryRuntimeStub(
        presentedNodeID: mismatch == "node"
            ? UUID().uuidString : modelLibraryTestChatEvidenceNodeID.rawValue.uuidString,
        authorityFingerprint: mismatch == "authority" ? "wrong-authority" : "authority-a",
        statusClusterID: mismatch == "unexpected-cluster" ? UUID() : nil
    )
    let fixture = try modelLibraryTestChatEvidenceFixture(
        runtime: runtime,
        clock: clock,
        expectedClusterID: mismatch == "missing-cluster" ? SparkClusterID(rawValue: UUID()) : nil
    )

    await fixture.provider.refreshChatEvidence()

    #expect(fixture.library.entry(id: fixture.entryID)?.issue == .identityMismatch)
    #expect(
        fixture.library.operationalSnapshot(for: fixture.entryID, at: clock.now())?.connectionState
            == .identityMismatch
    )
    #expect(
        fixture.library.entry(id: fixture.entryID)?.cachedOperationalSnapshot?.activeInference
            == nil
    )
}

@MainActor
@Test(arguments: [false, true])
func chatEvidenceLateResponseCannotPublishAfterCancellationOrRemoval(removeEntry: Bool) async throws
{
    let clock = ModelLibraryTestChatEvidenceClock()
    let runtime = ModelLibraryTestModelLibraryRuntimeStub(
        presentedNodeID: modelLibraryTestChatEvidenceNodeID.rawValue.uuidString,
        authorityFingerprint: "authority-a",
        pauseStatus: true
    )
    let fixture = try modelLibraryTestChatEvidenceFixture(runtime: runtime, clock: clock)
    let refresh = Task { await fixture.provider.refreshChatEvidence() }
    for _ in 0..<2_000 {
        if await runtime.isStatusPaused() { break }
        await Task.yield()
    }
    #expect(await runtime.isStatusPaused())
    if removeEntry { fixture.library.remove(entryID: fixture.entryID) }
    refresh.cancel()
    clock.advance(by: 20)
    await runtime.resumeStatus()
    await refresh.value

    if removeEntry {
        #expect(fixture.library.entries.isEmpty)
    } else {
        let entry = try #require(fixture.library.entry(id: fixture.entryID))
        #expect(entry.cachedOperationalSnapshot?.activeInference == nil)
        #expect(entry.cachedAt == modelLibraryTestLibraryEvidenceDate)
        #expect(entry.connectionState == .connectedWiFi)
    }
}

@MainActor
@Test func chatPollingPromotesALoadingModelOnlyAfterTheAuthenticatedStatusRefresh() async throws {
    let clock = ModelLibraryTestChatEvidenceClock()
    let runtime = ModelLibraryTestModelLibraryRuntimeStub(
        presentedNodeID: modelLibraryTestChatEvidenceNodeID.rawValue.uuidString,
        authorityFingerprint: "authority-a"
    )
    let fixture = try modelLibraryTestChatEvidenceFixture(runtime: runtime, clock: clock)
    let inventory = try await runtime.models(route: URL(string: "https://studio-spark.local:7443")!)
    let loading: ActiveInference = try modelLibraryTestLibraryDecode(
        #"{"state":"loading","model_id":"spark/model-8b","profile_id":"balanced","context_length":8192,"active_requests":0,"queue_depth":0,"tokens_per_second":0,"time_to_first_token_ms":0}"#
    )
    fixture.library.recordOperationalEvidence(
        TargetOperationalEvidence(
            identity: .node(modelLibraryTestChatEvidenceNodeID),
            respondingNodeID: modelLibraryTestChatEvidenceNodeID,
            inventory: TimedOperationalEvidence(inventory, observedAt: clock.now()),
            inference: TimedOperationalEvidence(loading, observedAt: clock.now())
        ),
        for: fixture.entryID,
        at: clock.now()
    )
    let provider = LocalSparkChatTargetProvider(
        library: fixture.library,
        trustLookup: { _ in
            NodeTrust(
                nodeID: modelLibraryTestChatEvidenceNodeID.rawValue.uuidString.lowercased(),
                nodeName: "Studio Spark",
                tlsFingerprint: String(repeating: "a", count: 64),
                authorityFingerprint: "authority-a",
                authorityPublicKey: "fixture-key",
                pairedAt: modelLibraryTestLibraryEvidenceDate
            )
        },
        now: { clock.now() },
        runtimeResolver: { entry in
            ModelLibraryRuntimeConnection(
                route: entry.preferredRoute!.baseURL,
                expectedNodeID: modelLibraryTestChatEvidenceNodeID,
                expectedClusterID: nil,
                expectedAuthorityFingerprint: "authority-a",
                runtime: runtime
            )
        }
    )
    let chat = SparkChatModel(provider: provider, streamer: PinnedSparkChatStreamer())
    chat.draft = "Hello"
    #expect(chat.catalogue.emptyState == .modelLoading)
    #expect(!chat.canSend)

    let polling = Task { await chat.runTargetRefreshes(interval: .seconds(3_600)) }
    for _ in 0..<2_000 {
        if chat.canSend { break }
        await Task.yield()
    }
    polling.cancel()
    await polling.value

    #expect(chat.canSend)
    #expect(chat.selectedTarget?.nodeID == modelLibraryTestChatEvidenceNodeID)
    #expect(chat.selectedTarget?.modelID == "spark/model-8b")
    #expect(chat.draft == "Hello")
    let endpoints = await runtime.requestedEndpoints()
    #expect(Array(endpoints.prefix(3)) == ["models", "health", "status"])
    // The first chat refresh also discovers installed, unloaded models for launching.
    #expect(
        Array(endpoints.dropFirst(3)).sorted()
            == [
                "capabilities", "catalogueStatus", "health", "models", "openWebUI", "operations",
                "status", "workloads",
            ]
    )
}

@MainActor
@Test func chatEvidenceFailedHealthMarksTheTargetOffline() async throws {
    let clock = ModelLibraryTestChatEvidenceClock()
    let runtime = ModelLibraryTestModelLibraryRuntimeStub(
        presentedNodeID: modelLibraryTestChatEvidenceNodeID.rawValue.uuidString,
        authorityFingerprint: "authority-a"
    )
    let fixture = try modelLibraryTestChatEvidenceFixture(runtime: runtime, clock: clock)
    await runtime.setShouldFail(true)

    await fixture.provider.refreshChatEvidence()

    #expect(fixture.library.entry(id: fixture.entryID)?.connectionState == .offlineCached)
    #expect(await runtime.requestedEndpoints() == ["health"])
}
