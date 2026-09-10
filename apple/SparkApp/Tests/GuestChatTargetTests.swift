import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing
@testable import SparkAppComposition

private func guestTrust(
    for target: ChatTestChatTargetFixtureDocument.Target,
    role: String = "guest"
) -> NodeTrust {
    NodeTrust(
        nodeID: target.nodeID.uuidString.lowercased(),
        nodeName: target.displayName,
        tlsFingerprint: target.tlsFingerprint,
        authorityFingerprint: target.authorityFingerprint,
        authorityPublicKey: "fixture-public-key",
        pairedAt: Date(timeIntervalSince1970: 1_787_000_000),
        localDeviceRole: role
    )
}

@MainActor
private func guestProvider(
    _ fixture: (library: SparkLibrary, target: ChatTestChatTargetFixtureDocument.Target, now: Date),
    role: String = "guest",
    registry: GuestAccessRegistry,
    reader: @escaping GuestGrantReader = { _ in .unknown }
) -> LocalSparkChatTargetProvider {
    let target = fixture.target
    return LocalSparkChatTargetProvider(
        library: fixture.library,
        trustLookup: { _ in guestTrust(for: target, role: role) },
        now: { fixture.now },
        runtimeResolver: { _ in
            ModelLibraryRuntimeConnection(
                route: target.route,
                expectedNodeID: SparkNodeID(rawValue: target.nodeID),
                expectedClusterID: nil,
                expectedAuthorityFingerprint: target.authorityFingerprint,
                runtime: ModelLibraryTestModelLibraryRuntimeStub(
                    presentedNodeID: target.nodeID.uuidString,
                    authorityFingerprint: target.authorityFingerprint
                )
            )
        },
        guestAccess: registry,
        guestGrantReader: reader
    )
}

@MainActor
@Test func aGuestIsNotOfferedAModelTheOwnerKept() throws {
    let fixture = try chatTestFixtureLibrary()
    let registry = GuestAccessRegistry()
    registry.record(allowedModels: ["open/other-14b"], forNode: fixture.target.nodeID.uuidString)

    let catalogue = guestProvider(fixture, registry: registry).catalogue()

    #expect(catalogue.targets.isEmpty)
    #expect(catalogue.modelChoices.isEmpty)
    #expect(catalogue.unavailableTargets.map(\.reason) == [.notShared])
    #expect(catalogue.emptyState == .notShared)
    #expect(catalogue.emptyState?.action == .checkAgain)
    #expect(catalogue.emptyState?.message.contains("hasn't shared the model") == true)
}

@MainActor
@Test func aGuestSeesTheRunningModelWhenTheOwnerSharedIt() throws {
    let fixture = try chatTestFixtureLibrary()
    let registry = GuestAccessRegistry()
    registry.record(allowedModels: ["open/compact-8b"], forNode: fixture.target.nodeID.uuidString)

    let catalogue = guestProvider(fixture, registry: registry).catalogue()

    #expect(catalogue.targets.map(\.modelID) == ["open/compact-8b"])
    #expect(catalogue.emptyState == nil)
}

@MainActor
@Test func anOwnerIsNeverNarrowedByAGuestRecord() throws {
    let fixture = try chatTestFixtureLibrary()
    let registry = GuestAccessRegistry()
    registry.record(allowedModels: ["open/other-14b"], forNode: fixture.target.nodeID.uuidString)

    let catalogue = guestProvider(fixture, role: "owner", registry: registry).catalogue()

    #expect(catalogue.targets.map(\.modelID) == ["open/compact-8b"])
}

@MainActor
@Test func theProviderReadsAGuestsGrantWhenItRefreshes() async throws {
    let fixture = try chatTestFixtureLibrary()
    let registry = GuestAccessRegistry()
    let provider = guestProvider(fixture, registry: registry) { _ in .shared(["open/other-14b"]) }

    #expect(provider.catalogue().targets.count == 1)

    await provider.refresh()

    #expect(registry.allowedModels(forNode: fixture.target.nodeID.uuidString) == ["open/other-14b"])
    #expect(provider.catalogue().targets.isEmpty)
    #expect(provider.catalogue().emptyState == .notShared)
}

@MainActor
@Test func aSparkThatSaysThisDeviceIsNoGuestIsForgotten() async throws {
    let fixture = try chatTestFixtureLibrary()
    let registry = GuestAccessRegistry()
    registry.record(allowedModels: ["open/other-14b"], forNode: fixture.target.nodeID.uuidString)
    let provider = guestProvider(fixture, registry: registry) { _ in .notAGuest }

    await provider.refresh()

    #expect(registry.allowedModels(forNode: fixture.target.nodeID.uuidString) == nil)
    #expect(provider.catalogue().targets.map(\.modelID) == ["spark/model-8b"])
}
