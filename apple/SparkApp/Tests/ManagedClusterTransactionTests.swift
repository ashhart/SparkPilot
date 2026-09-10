import CryptoKit
import Foundation
@_spi(SparkTestSupport) import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
@_spi(SparkTestSupport) import SparkTransport
import Testing
@testable import SparkAppComposition

@Test func signedCoordinatorCommitsOnlyAfterBothPeerAndCollectiveProofs() async throws {
    let first = externalClusterTestExternalTarget(1, name: "Spark One")
    let second = externalClusterTestExternalTarget(2, name: "Spark Two")
    let firstRecorder = ExternalClusterTestManagedTransactionRecorder()
    let secondRecorder = ExternalClusterTestManagedTransactionRecorder()
    let journal = ExternalClusterTestMemoryManagedClusterJournal()
    let coordinator = SignedManagedClusterCoordinator(
        runtimeResolver: { target in
            let isFirst = target == first
            return (
                SparkAPIClient(
                    transport: ExternalClusterTestManagedTransactionTransport(
                        target: target,
                        peer: isFirst ? second : first,
                        recorder: isFirst ? firstRecorder : secondRecorder
                    ),
                    signer: ExternalClusterTestManagedRequestSigner()
                ),
                externalClusterTestExternalTrust(target.nodeID.rawValue.uuidString, role: .owner)
            )
        },
        presenceAuthorizer: ExternalClusterTestManagedPresenceAuthorizer(),
        deviceID: UUID(uuidString: "00000000-0000-4000-8000-000000000090")!,
        now: { ISO8601DateFormatter().date(from: "2026-08-31T09:00:00Z")! },
        journal: journal
    )

    let outcome = try await coordinator.authorize(
        name: "Studio cluster",
        coordinatorNodeID: first.nodeID.rawValue,
        targets: [second, first]
    )

    #expect(outcome.memberNodeIDs == [first.nodeID.rawValue, second.nodeID.rawValue])
    #expect(outcome.statusByNodeID.count == 2)
    #expect(journal.savedHistory().map { $0.finalizedNodeIDs.count } == [0, 1, 2])
    #expect(try journal.load() == nil)
    for paths in [await firstRecorder.recordedPaths(), await secondRecorder.recordedPaths()] {
        #expect(
            paths == [
                "/api/v1/cluster/descriptor",
                "/api/v1/cluster/transactions/prepare",
                "/api/v1/cluster/transactions/activate",
                "/api/v1/cluster/transactions/prove",
                "/api/v1/cluster/transactions/collective",
                "/api/v1/cluster/transactions/commit",
                "/api/v1/cluster/transactions/finalize",
            ]
        )
    }
}

@Test func interruptedFinalizeJournalConvergesAfterEveryRelaunchBoundary() async throws {
    let first = externalClusterTestExternalTarget(1, name: "Spark One")
    let second = externalClusterTestExternalTarget(2, name: "Spark Two")
    let seedJournal = ExternalClusterTestMemoryManagedClusterJournal()
    let seedCoordinator = SignedManagedClusterCoordinator(
        runtimeResolver: { target in
            let isFirst = target == first
            return (
                SparkAPIClient(
                    transport: ExternalClusterTestManagedTransactionTransport(
                        target: target,
                        peer: isFirst ? second : first,
                        recorder: ExternalClusterTestManagedTransactionRecorder()
                    ),
                    signer: ExternalClusterTestManagedRequestSigner()
                ),
                externalClusterTestExternalTrust(target.nodeID.rawValue.uuidString, role: .owner)
            )
        },
        presenceAuthorizer: ExternalClusterTestManagedPresenceAuthorizer(),
        deviceID: UUID(uuidString: "00000000-0000-4000-8000-000000000090")!,
        now: { ISO8601DateFormatter().date(from: "2026-08-31T09:00:00Z")! },
        journal: seedJournal
    )
    _ = try await seedCoordinator.authorize(
        name: "Studio cluster",
        coordinatorNodeID: first.nodeID.rawValue,
        targets: [first, second]
    )
    let crashBoundaries = seedJournal.savedHistory()
    #expect(crashBoundaries.map { $0.finalizedNodeIDs.count } == [0, 1, 2])

    for boundary in crashBoundaries {
        let firstRecorder = ExternalClusterTestManagedTransactionRecorder()
        let secondRecorder = ExternalClusterTestManagedTransactionRecorder()
        let recoveryJournal = ExternalClusterTestMemoryManagedClusterJournal(boundary)
        let relaunched = SignedManagedClusterCoordinator(
            runtimeResolver: { target in
                let isFirst = target == first
                return (
                    SparkAPIClient(
                        transport: ExternalClusterTestManagedTransactionTransport(
                            target: target,
                            peer: isFirst ? second : first,
                            recorder: isFirst ? firstRecorder : secondRecorder
                        ),
                        signer: ExternalClusterTestManagedRequestSigner()
                    ),
                    externalClusterTestExternalTrust(
                        target.nodeID.rawValue.uuidString,
                        role: .owner
                    )
                )
            },
            presenceAuthorizer: ExternalClusterTestManagedPresenceAuthorizer(),
            deviceID: UUID(uuidString: "00000000-0000-4000-8000-000000000090")!,
            now: { ISO8601DateFormatter().date(from: "2026-08-31T09:00:00Z")! },
            journal: recoveryJournal
        )

        let reconciliation = try #require(try await relaunched.reconcilePending())
        guard case .ready(let outcome) = reconciliation.resolution else {
            Issue.record("The interrupted transaction did not converge to ready")
            continue
        }
        #expect(outcome.statusByNodeID.count == 2)
        #expect(try recoveryJournal.load() == nil)
        #expect(await firstRecorder.recordedPaths().contains { $0.hasSuffix("/finalize") })
        #expect(await secondRecorder.recordedPaths().contains { $0.hasSuffix("/finalize") })
    }
}

@Test func relaunchCompensatesBothMembersWhenFinalizeCannotConverge() async throws {
    let first = externalClusterTestExternalTarget(1, name: "Spark One")
    let second = externalClusterTestExternalTarget(2, name: "Spark Two")
    let seedJournal = ExternalClusterTestMemoryManagedClusterJournal()
    let seed = SignedManagedClusterCoordinator(
        runtimeResolver: { target in
            let isFirst = target == first
            return (
                SparkAPIClient(
                    transport: ExternalClusterTestManagedTransactionTransport(
                        target: target,
                        peer: isFirst ? second : first,
                        recorder: ExternalClusterTestManagedTransactionRecorder()
                    ),
                    signer: ExternalClusterTestManagedRequestSigner()
                ),
                externalClusterTestExternalTrust(target.nodeID.rawValue.uuidString, role: .owner)
            )
        },
        presenceAuthorizer: ExternalClusterTestManagedPresenceAuthorizer(),
        deviceID: UUID(uuidString: "00000000-0000-4000-8000-000000000090")!,
        now: { ISO8601DateFormatter().date(from: "2026-08-31T09:00:00Z")! },
        journal: seedJournal
    )
    _ = try await seed.authorize(
        name: "Studio cluster",
        coordinatorNodeID: first.nodeID.rawValue,
        targets: [first, second]
    )
    let afterFirstFinalize = try #require(
        seedJournal.savedHistory().first { $0.finalizedNodeIDs.count == 1 }
    )
    let recoveryJournal = ExternalClusterTestMemoryManagedClusterJournal(afterFirstFinalize)
    let firstRecorder = ExternalClusterTestManagedTransactionRecorder()
    let secondRecorder = ExternalClusterTestManagedTransactionRecorder()
    let relaunched = SignedManagedClusterCoordinator(
        runtimeResolver: { target in
            let isFirst = target == first
            return (
                SparkAPIClient(
                    transport: ExternalClusterTestManagedTransactionTransport(
                        target: target,
                        peer: isFirst ? second : first,
                        recorder: isFirst ? firstRecorder : secondRecorder,
                        failFinalize: !isFirst
                    ),
                    signer: ExternalClusterTestManagedRequestSigner()
                ),
                externalClusterTestExternalTrust(target.nodeID.rawValue.uuidString, role: .owner)
            )
        },
        presenceAuthorizer: ExternalClusterTestManagedPresenceAuthorizer(),
        deviceID: UUID(uuidString: "00000000-0000-4000-8000-000000000090")!,
        now: { ISO8601DateFormatter().date(from: "2026-08-31T09:00:00Z")! },
        journal: recoveryJournal
    )

    let reconciliation = try #require(try await relaunched.reconcilePending())
    #expect(reconciliation.resolution == .rolledBack)
    #expect(try recoveryJournal.load() == nil)
    #expect(await firstRecorder.recordedPaths().contains { $0.hasSuffix("/rollback") })
    #expect(await secondRecorder.recordedPaths().contains { $0.hasSuffix("/rollback") })
}

@Test func authoritativeRolesOverrideUuidAndDisplayOrderForWorkerFirstLaunch() async throws {
    let coordinatorTarget = externalClusterTestExternalTarget(2, name: "Alpha coordinator")
    let workerTarget = externalClusterTestExternalTarget(1, name: "Zulu worker")
    let recorder = ExternalClusterTestManagedLaunchOrderRecorder()
    let coordinator = SignedManagedClusterRuntimeCoordinator(
        runtimeResolver: { target in
            (
                SparkAPIClient(
                    transport: ExternalClusterTestManagedLaunchTransport(
                        target: target,
                        coordinator: coordinatorTarget,
                        worker: workerTarget,
                        recorder: recorder
                    ),
                    signer: ExternalClusterTestManagedRequestSigner()
                ),
                externalClusterTestExternalTrust(target.nodeID.rawValue.uuidString, role: .owner)
            )
        },
        presenceAuthorizer: ExternalClusterTestManagedPresenceAuthorizer()
    )

    let statuses = try await coordinator.start(
        clusterID: UUID(uuidString: "00000000-0000-4000-8000-000000000099")!,
        launchID: UUID(uuidString: "00000000-0000-4000-8000-000000000098")!,
        recipeID: "verified-recipe",
        profileID: "safe-profile",
        targets: [coordinatorTarget, workerTarget]
    )

    #expect(
        await recorder.recordedNodeIDs()
            == [workerTarget.nodeID.rawValue, coordinatorTarget.nodeID.rawValue]
    )
    #expect(statuses.map(\.targetID) == [workerTarget.id, coordinatorTarget.id])
}

@Test func signedCoordinatorRollsBackBothMembersWhenPeerProofFails() async throws {
    let first = externalClusterTestExternalTarget(1, name: "Spark One")
    let second = externalClusterTestExternalTarget(2, name: "Spark Two")
    let firstRecorder = ExternalClusterTestManagedTransactionRecorder()
    let secondRecorder = ExternalClusterTestManagedTransactionRecorder()
    let coordinator = SignedManagedClusterCoordinator(
        runtimeResolver: { target in
            let isFirst = target == first
            return (
                SparkAPIClient(
                    transport: ExternalClusterTestManagedTransactionTransport(
                        target: target,
                        peer: isFirst ? second : first,
                        recorder: isFirst ? firstRecorder : secondRecorder,
                        failProof: !isFirst
                    ),
                    signer: ExternalClusterTestManagedRequestSigner()
                ),
                externalClusterTestExternalTrust(target.nodeID.rawValue.uuidString, role: .owner)
            )
        },
        presenceAuthorizer: ExternalClusterTestManagedPresenceAuthorizer(),
        deviceID: UUID(uuidString: "00000000-0000-4000-8000-000000000090")!,
        now: { ISO8601DateFormatter().date(from: "2026-08-31T09:00:00Z")! },
        journal: ExternalClusterTestMemoryManagedClusterJournal()
    )

    await #expect(throws: ManagedClusterError.linkProofFailed("Spark Two")) {
        try await coordinator.authorize(
            name: "Studio cluster",
            coordinatorNodeID: first.nodeID.rawValue,
            targets: [first, second]
        )
    }

    for paths in [await firstRecorder.recordedPaths(), await secondRecorder.recordedPaths()] {
        #expect(paths.contains("/api/v1/cluster/transactions/rollback"))
        #expect(!paths.contains("/api/v1/cluster/transactions/collective"))
        #expect(!paths.contains("/api/v1/cluster/transactions/commit"))
    }
}
