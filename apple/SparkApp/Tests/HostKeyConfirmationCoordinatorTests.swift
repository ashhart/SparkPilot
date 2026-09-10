import Foundation
import SparkBootstrap
import Testing

@testable import SparkAppComposition

/// Verifies that first-use host-key confirmation never accepts before the owner answers.

private let fingerprint = SSHHostKeyFingerprint(
    keyType: "ssh-ed25519",
    publicKeyBlob: Data(repeating: 0x2a, count: 32)
)

@MainActor
@Test func theOwnerIsShownTheHostAndFingerprintAndTheAnswerIsRelayed() async throws {
    let coordinator = HostKeyConfirmationCoordinator()
    let confirmer = coordinator.confirmer

    async let decision = confirmer.confirmFirstUse(
        host: "spark-a1b2.local",
        fingerprint: fingerprint
    )

    // Let the ask reach the coordinator before answering it.
    while coordinator.pending == nil { await Task.yield() }
    let pending = try #require(coordinator.pending)
    #expect(pending.host == "spark-a1b2.local")
    #expect(pending.fingerprint == fingerprint)
    #expect(
        pending.displayString == fingerprint.displayString,
        "the owner compares this against what the Spark prints, so it is OpenSSH's format"
    )

    coordinator.confirm()
    #expect(await decision)
    #expect(coordinator.pending == nil, "the prompt is dismissed once answered")
}

@MainActor
@Test func decliningIsRelayedAsARefusal() async throws {
    let coordinator = HostKeyConfirmationCoordinator()
    async let decision = coordinator.confirmer.confirmFirstUse(
        host: "spark-a1b2.local",
        fingerprint: fingerprint
    )
    while coordinator.pending == nil { await Task.yield() }
    coordinator.decline()

    #expect(await decision == false)
    #expect(coordinator.pending == nil)
}

@MainActor
@Test func aSecondQuestionWhileTheFirstIsUnansweredIsRefusedNotStacked() async throws {
    // Reject a second live prompt so an answer cannot apply to a different host than the one displayed.
    let coordinator = HostKeyConfirmationCoordinator()
    async let first = coordinator.confirmer.confirmFirstUse(
        host: "spark-a1b2.local",
        fingerprint: fingerprint
    )
    while coordinator.pending == nil { await Task.yield() }

    let second = await coordinator.confirmer.confirmFirstUse(
        host: "spark-c3d4.local",
        fingerprint: fingerprint
    )
    #expect(second == false, "the second question is refused rather than replacing the first")
    #expect(
        coordinator.pending?.host == "spark-a1b2.local",
        "the owner is still looking at the question they were asked"
    )

    coordinator.confirm()
    #expect(await first)
}

@MainActor
@Test func aQuestionNobodyCouldAnswerGivesWayOnceItsConnectionIsGone() async throws {
    // Decline expired connection prompts so later installation attempts can present a fresh question.
    nonisolated(unsafe) var now = Date(timeIntervalSince1970: 1_000)
    let coordinator = HostKeyConfirmationCoordinator(now: { now })
    async let first = coordinator.confirmer.confirmFirstUse(
        host: "spark-a1b2.local",
        fingerprint: fingerprint
    )
    while coordinator.pending == nil { await Task.yield() }

    now = now.addingTimeInterval(HostKeyConfirmationCoordinator.unansweredQuestionLifetime + 1)
    async let second = coordinator.confirmer.confirmFirstUse(
        host: "spark-c3d4.local",
        fingerprint: fingerprint
    )
    while coordinator.pending?.host != "spark-c3d4.local" { await Task.yield() }

    #expect(await first == false, "the stale question is declined, never answered for free")
    coordinator.confirm()
    #expect(await second)
}

@MainActor
@Test func onlyTheMostRecentlyShownSurfacePresentsTheQuestion() {
    // Bind host-key alerts only to the newest registered surface so covered screens cannot hide the prompt.
    let coordinator = HostKeyConfirmationCoordinator()
    let setup = UUID()
    let settings = UUID()

    coordinator.registerPresenter(setup)
    #expect(coordinator.presents(setup))

    coordinator.registerPresenter(settings)
    #expect(coordinator.presents(settings))
    #expect(!coordinator.presents(setup), "a covered screen must not try to present")

    coordinator.unregisterPresenter(settings)
    #expect(coordinator.presents(setup))
}

@MainActor
@Test func answeringWhenNobodyIsAskingIsHarmless() {
    // Ignore confirmation after dismissal without retaining approval for a later prompt.
    let coordinator = HostKeyConfirmationCoordinator()
    coordinator.confirm()
    coordinator.decline()
    #expect(coordinator.pending == nil)
}

@MainActor
@Test func theCoordinatorDrivesTheRealPolicyEndToEnd() async throws {
    // Verify the complete policy: confirm first use, remember matching keys and reject changed keys without prompting.
    let coordinator = HostKeyConfirmationCoordinator()
    let store = InMemoryHostKeyStore()
    let policy = HostKeyPolicy(store: store, confirmer: coordinator.confirmer)

    async let firstDecision = policy.decide(host: "spark-a1b2.local", presented: fingerprint)
    while coordinator.pending == nil { await Task.yield() }
    coordinator.confirm()
    #expect(try await firstDecision == .confirmed)

    // Known now: no question, so nothing to answer.
    let second = try await policy.decide(host: "spark-a1b2.local", presented: fingerprint)
    #expect(second == .known)
    #expect(coordinator.pending == nil, "a known host is not put back to the owner")

    // A different key for the same host is never a prompt.
    let changed = SSHHostKeyFingerprint(
        keyType: "ssh-ed25519",
        publicKeyBlob: Data(repeating: 0x7f, count: 32)
    )
    await #expect(throws: HostKeyError.self) {
        _ = try await policy.decide(host: "spark-a1b2.local", presented: changed)
    }
    #expect(
        coordinator.pending == nil,
        "a changed key must not invite the owner to say yes to it"
    )
}
