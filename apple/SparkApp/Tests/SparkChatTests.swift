import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import SwiftUI
import Testing
@testable import SparkAppComposition

@MainActor
@Test func emptyFleetOffersAnHonestSetupState() {
    let catalogue = SparkChatTargetCatalogue.empty

    #expect(catalogue.emptyState == .emptyFleet)
    #expect(catalogue.emptyState?.title == "Add a Spark to start chatting")
    #expect(catalogue.emptyState?.message.contains("pairs with a Spark") == true)
}

@MainActor
@Test func pairedFleetWithoutAnActiveModelDoesNotOfferATarget() {
    let catalogue = SparkChatTargetCatalogue(
        targets: [],
        pairedTargetCount: 1,
        unavailableTargets: [
            SparkChatUnavailableTarget(name: "Desk Spark", reason: .noActiveModel)
        ]
    )

    #expect(catalogue.emptyState == .noActiveModel)
    #expect(catalogue.emptyState?.message.contains("Load an installed chat model") == true)
}

@MainActor
@Test func localProviderRequiresPairingAndCurrentActiveModelEvidence() throws {
    let fixture = try chatTestFixtureLibrary()
    let paired = LocalSparkChatTargetProvider(
        library: fixture.library,
        trustLookup: { _ in chatTestTrust(for: fixture.target) },
        now: { fixture.now }
    ).catalogue()

    #expect(paired.targets.map(\.modelID) == ["open/compact-8b"])
    #expect(paired.targets.first?.displayName == "Desk Spark")

    let unpaired = LocalSparkChatTargetProvider(
        library: fixture.library,
        trustLookup: { _ in nil },
        now: { fixture.now }
    ).catalogue()
    #expect(unpaired.targets.isEmpty)
    #expect(unpaired.emptyState == .authenticationUnavailable)

    let unloaded = try chatTestFixtureLibrary(inferenceState: "unloaded", modelID: nil)
    let withoutActiveModel = LocalSparkChatTargetProvider(
        library: unloaded.library,
        trustLookup: { _ in chatTestTrust(for: unloaded.target) },
        now: { unloaded.now }
    ).catalogue()
    #expect(withoutActiveModel.targets.isEmpty)
    #expect(withoutActiveModel.emptyState == .noActiveModel)
}

@MainActor
@Test func aReachableLoadingSparkShowsStartupWithoutOfferingChat() throws {
    let fixture = try chatTestFixtureLibrary(inferenceState: "loading")
    let catalogue = LocalSparkChatTargetProvider(
        library: fixture.library,
        trustLookup: { _ in chatTestTrust(for: fixture.target) },
        now: { fixture.now }
    ).catalogue()
    #expect(catalogue.targets.isEmpty)
    #expect(catalogue.emptyState?.title == "Model is starting")
    #expect(catalogue.emptyState != .offline)
}

@MainActor
@Test func aReachableSparkWithStaleInferenceChecksStatusWithoutOfferingChat() throws {
    let fixture = try chatTestFixtureLibrary()
    let nodeID = SparkNodeID(rawValue: fixture.target.nodeID)
    let entryID = SparkTargetIdentity.node(nodeID).description
    let instant = fixture.now.addingTimeInterval(16)
    let health: Health = try chatTestDecodeChatFixture(
        """
        {"api_version":1,"node_id":"\(fixture.target.nodeID)","runtime_version":"0.2.0","status":"ok"}
        """
    )
    _ = fixture.library.recordOperationalEvidence(
        TargetOperationalEvidence(
            identity: .node(nodeID),
            respondingNodeID: nodeID,
            health: TimedOperationalEvidence(health, observedAt: instant)
        ),
        for: entryID,
        at: instant
    )
    let snapshot = try #require(fixture.library.operationalSnapshot(for: entryID, at: instant))
    #expect(snapshot.evidence.health.state == .current)
    #expect(snapshot.evidence.inference.state == .stale)
    let catalogue = LocalSparkChatTargetProvider(
        library: fixture.library,
        trustLookup: { _ in chatTestTrust(for: fixture.target) },
        now: { instant }
    ).catalogue()
    #expect(catalogue.targets.isEmpty)
    #expect(catalogue.emptyState?.title == "Checking model status")
    #expect(catalogue.emptyState != .offline)
}

@MainActor
@Test func chatTargetNeverShowsAModelIdentifierWhenInventoryIsMissing() {
    let identity = ModelPlacementIdentity(modelID: "open/compact-8b", recipeRevision: "recipe-1")
    let modelName = LocalSparkChatTargetProvider.ownerFacingModelName(
        for: identity,
        placements: []
    )

    #expect(modelName == "Active model")
    #expect(!modelName.contains(identity.modelID))
}

@MainActor
@Test func staleOrOfflineEvidenceCannotBecomeAChatTarget() {
    let catalogue = SparkChatTargetCatalogue(
        targets: [],
        pairedTargetCount: 2,
        unavailableTargets: [
            SparkChatUnavailableTarget(name: "Desk Spark", reason: .offline),
            SparkChatUnavailableTarget(name: "Studio Spark", reason: .offline),
        ]
    )

    #expect(catalogue.emptyState == .offline)
    #expect(catalogue.emptyState?.message.contains("last model information is old") == true)
}

@MainActor
@Test func localProviderDropsPreviouslyReadyTargetWhenItGoesOffline() throws {
    let fixture = try chatTestFixtureLibrary()
    let entryID = SparkTargetIdentity.node(SparkNodeID(rawValue: fixture.target.nodeID)).description
    fixture.library.markUnreachable(entryID: entryID, at: fixture.now)

    let catalogue = LocalSparkChatTargetProvider(
        library: fixture.library,
        trustLookup: { _ in chatTestTrust(for: fixture.target) },
        now: { fixture.now }
    ).catalogue()

    #expect(catalogue.targets.isEmpty)
    #expect(catalogue.emptyState == .offline)
}

@MainActor
@Test func voiceTargetsRemainAvailableWithoutALoadedChatModelButStillRequirePairing() throws {
    let fixture = try chatTestFixtureLibrary(inferenceState: "unloaded", modelID: nil)
    let provider = LocalSparkChatTargetProvider(
        library: fixture.library,
        trustLookup: { _ in chatTestTrust(for: fixture.target) },
        now: { fixture.now }
    )
    #expect(provider.catalogue().targets.isEmpty)
    #expect(provider.voiceTargets().count == 1)
    #expect(provider.voiceTargets().first?.nodeID.rawValue == fixture.target.nodeID)
    let unpaired = LocalSparkChatTargetProvider(library: fixture.library, trustLookup: { _ in nil })
    #expect(unpaired.voiceTargets().isEmpty)
}

@MainActor
@Test func chatVisionComesFromCurrentRuntimeModelMetadata() throws {
    for capability: Bool? in [nil, false, true] {
        let fixture = try chatTestFixtureLibrary(vision: capability)
        let provider = LocalSparkChatTargetProvider(
            library: fixture.library,
            trustLookup: { _ in chatTestTrust(for: fixture.target) },
            now: { fixture.now }
        )
        #expect(provider.catalogue().targets.first?.visionSupported == capability)
    }
}

@Test @MainActor func chatCatalogueKeepsInstalledUnloadedModelsAvailableForLaunching() throws {
    let fixture = try chatTestFixtureLibrary(inferenceState: "unloaded", modelID: nil)
    let provider = LocalSparkChatTargetProvider(
        library: fixture.library,
        trustLookup: { _ in chatTestTrust(for: fixture.target) },
        now: { fixture.now }
    )
    let catalogue = provider.catalogue()
    #expect(catalogue.targets.isEmpty)
    #expect(catalogue.installedTargets.count == 1)
    #expect(catalogue.installedTargets.first?.modelID == "open/compact-8b")
}
