import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import Testing
@testable import SparkAppComposition

/// The workspace sheet shows the last running model at once; a fresh chat still waits for current evidence.
@MainActor
@Test func theLastRunningModelIsRememberedAfterItsEvidenceHasAged() throws {
    let fixture = try chatTestFixtureLibrary()
    let later = fixture.now.addingTimeInterval(120)
    let provider = LocalSparkChatTargetProvider(
        library: fixture.library,
        trustLookup: { _ in chatTestTrust(for: fixture.target) },
        now: { later }
    )
    #expect(provider.catalogue().targets.isEmpty)
    let remembered = provider.rememberedTargets()
    #expect(remembered.map(\.modelID) == ["open/compact-8b"])
    #expect(remembered.first?.modelName == "Compact 8B")
    #expect(remembered.first?.displayName == "Desk Spark")
}

@MainActor
@Test func aSparkWithoutAnActiveModelIsNotRemembered() throws {
    let fixture = try chatTestFixtureLibrary(inferenceState: "unloaded", modelID: nil)
    let provider = LocalSparkChatTargetProvider(
        library: fixture.library,
        trustLookup: { _ in chatTestTrust(for: fixture.target) },
        now: { fixture.now }
    )
    #expect(provider.rememberedTargets().isEmpty)
}
