import CryptoKit
import Foundation
@_spi(SparkTestSupport) import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
@_spi(SparkTestSupport) import SparkTransport
import Testing
@testable import SparkAppComposition

@MainActor
@Test func partialStopKeepsTheUnprovedMemberVisibleAndRetryable() async {
    let targets = [
        externalClusterTestExternalTarget(1, name: "Spark One"),
        externalClusterTestExternalTarget(2, name: "Spark Two"),
    ]
    let running = targets.indices.map {
        externalClusterTestManagedMemberStatus($0, targets: targets)
    }
    let firstStopped = [
        externalClusterTestManagedMemberStatus(0, targets: targets, state: .stopped)
    ]
    let runtime = ExternalClusterTestManagedClusterRuntimeFixture(
        isAvailable: false,
        listedStatuses: running,
        stopStatuses: firstStopped
    )
    let model = ManagedClusterLaunchModel(
        clusterID: UUID(uuidString: "00000000-0000-4000-8000-000000000099")!,
        targets: targets,
        coordinator: runtime
    )

    await model.refresh()
    await model.stop()

    #expect(model.statuses.count == 2)
    #expect(model.statuses.first { $0.targetID == targets[0].id }?.status.state == .stopped)
    #expect(model.statuses.first { $0.targetID == targets[1].id }?.status.state == .running)
    #expect(model.canStop)
    #expect(model.errorMessage?.contains("not proved") == true)

    await model.stop()
    #expect(await runtime.recordedStopRequests() == 2)
}

@MainActor
@Test func partialLaunchRemainsVisibleAndStoppableAfterCapabilityRevocation() async {
    let targets = [
        externalClusterTestExternalTarget(1, name: "Spark One"),
        externalClusterTestExternalTarget(2, name: "Spark Two"),
    ]
    let runtime = ExternalClusterTestManagedClusterRuntimeFixture(
        isAvailable: false,
        listedStatuses: [
            externalClusterTestManagedMemberStatus(0, targets: targets, state: .degraded)
        ]
    )
    let model = ManagedClusterLaunchModel(
        clusterID: UUID(uuidString: "00000000-0000-4000-8000-000000000099")!,
        targets: targets,
        coordinator: runtime
    )

    await model.refresh()
    #expect(model.availability == .unavailable)
    #expect(model.isVisible)
    #expect(model.statuses.count == 1)
    #expect(model.missingMemberNames == ["Spark Two"])
    #expect(model.canStop)

    await model.stop()
    #expect(await runtime.recordedStopRequests() == 1)
}

@MainActor
@Test func singleNodeRecoveryStopsTheDistributedLaunchBeforePreparingAReview() async throws {
    let targets = [
        externalClusterTestExternalTarget(1, name: "Spark One"),
        externalClusterTestExternalTarget(2, name: "Spark Two"),
    ]
    let recorder = ExternalClusterTestManagedRecoveryOrderRecorder()
    let statuses = [
        externalClusterTestManagedMemberStatus(
            0,
            targets: targets,
            state: .degraded,
            failureCode: "WORKER_LOST"
        )
    ]
    let runtime = ExternalClusterTestManagedClusterRuntimeFixture(
        isAvailable: false,
        listedStatuses: statuses,
        stopObserver: { await recorder.record("stop") }
    )
    let loader = try ExternalClusterTestManagedRecoveryLoaderFixture(recorder: recorder)
    let clusterID = UUID(uuidString: "00000000-0000-4000-8000-000000000099")!
    let candidate = ManagedClusterSingleNodeCandidate(
        targetID: targets[0].id,
        targetName: targets[0].displayName,
        nodeID: targets[0].nodeID,
        route: targets[0].route,
        tlsFingerprint: String(repeating: "a", count: 64),
        authorityFingerprint: "authority",
        clusterID: SparkClusterID(rawValue: clusterID),
        recipeRevision: "signed-r7"
    )
    let model = ManagedClusterLaunchModel(
        clusterID: clusterID,
        targets: targets,
        coordinator: runtime,
        recoveryCandidateResolver: { spec, candidates in
            await recorder.record("candidate")
            #expect(spec.recipeID == "verified-recipe")
            #expect(spec.profileID == "safe-profile")
            #expect(candidates.map(\.nodeID) == [targets[0].nodeID])
            return candidate
        },
        recoveryLoaderFactory: { _ in loader }
    )

    await model.refresh()
    #expect(model.canPrepareSingleNodeRecovery)
    await model.prepareSingleNodeRecovery()

    #expect(await recorder.recordedEvents() == ["candidate", "stop", "preview"])
    #expect(loader.receivedModelID == "verified-recipe")
    #expect(loader.receivedProfileID == "safe-profile")
    #expect(loader.receivedRecipeRevision == "signed-r7")
    #expect(model.pendingRecoveryConfirmation != nil)
    #expect(model.recoveryMessage?.contains("Review") == true)
    #expect(model.recoveryMessage?.contains("running") == false)

    await model.confirmSingleNodeRecovery()

    #expect(await recorder.recordedEvents() == ["candidate", "stop", "preview", "apply"])
    #expect(model.pendingRecoveryConfirmation == nil)
    #expect(model.recoveryMessage?.contains("running") == true)
}

@MainActor
@Test func singleNodeRecoveryDoesNotStopWhenNoCompatibleSignedCandidateExists() async {
    let targets = [
        externalClusterTestExternalTarget(1, name: "Spark One"),
        externalClusterTestExternalTarget(2, name: "Spark Two"),
    ]
    let statuses = [
        externalClusterTestManagedMemberStatus(
            0,
            targets: targets,
            state: .degraded,
            failureCode: "WORKER_LOST"
        )
    ]
    let runtime = ExternalClusterTestManagedClusterRuntimeFixture(
        isAvailable: false,
        listedStatuses: statuses
    )
    let model = ManagedClusterLaunchModel(
        clusterID: UUID(uuidString: "00000000-0000-4000-8000-000000000099")!,
        targets: targets,
        coordinator: runtime,
        recoveryCandidateResolver: { _, _ in nil },
        recoveryLoaderFactory: { _ in
            Issue.record("a loader must not be built without a compatible candidate")
            throw ManagedClusterLaunchError.unavailable
        }
    )

    await model.refresh()
    await model.prepareSingleNodeRecovery()

    #expect(await runtime.recordedStopRequests() == 0)
    #expect(model.pendingRecoveryConfirmation == nil)
    #expect(model.errorMessage?.contains("No remaining Spark") == true)
}

@Test func clusterFailureCopyNeverShowsRawRuntimeCodes() {
    let targets = [
        externalClusterTestExternalTarget(1, name: "Spark One"),
        externalClusterTestExternalTarget(2, name: "Spark Two"),
    ]
    let status = externalClusterTestManagedLaunchStatus(
        0,
        targets: targets,
        state: .degraded,
        failureCode: "COORDINATOR_LOST_PROMOTION_REQUIRED"
    )

    let copy = ManagedClusterLaunchFailureCopy.presentation(for: status)
    #expect(copy?.title == "Coordinator unavailable")
    #expect(copy?.detail.contains("COORDINATOR_LOST") == false)
}

@MainActor
@Test func reopeningTheClusterScreenReconstructsManagedMembersFromTheLibrary() async throws {
    let library = SparkLibrary(store: MemoryLibraryStore())
    let clusterID = SparkClusterID(
        rawValue: UUID(uuidString: "00000000-0000-4000-8000-000000000099")!
    )
    let targets = [
        externalClusterTestExternalTarget(1, name: "Spark One"),
        externalClusterTestExternalTarget(2, name: "Spark Two"),
    ]
    for (index, target) in targets.enumerated() {
        library.reconcile(
            AuthenticatedTarget(
                nodeID: target.nodeID,
                clusterID: clusterID,
                name: target.displayName,
                role: index == 0 ? .leader : .worker,
                authorityFingerprint: "authority",
                displayName: target.displayName,
                routes: [CachedRoute(baseURL: target.route, kind: .localWiFi)]
            )
        )
    }
    let statuses = targets.indices.map {
        externalClusterTestManagedMemberStatus($0, targets: targets)
    }
    let runtime = ExternalClusterTestManagedClusterRuntimeFixture(
        isAvailable: false,
        listedStatuses: statuses
    )

    let reopened = ExternalClusterPreviewModel(
        targets: [],
        library: library,
        trustLookup: { externalClusterTestExternalTrust($0, role: .owner) },
        clusterRuntime: runtime
    )
    let launchModel = try #require(reopened.launchModels.first)
    await launchModel.refresh()

    #expect(reopened.launchModels.count == 1)
    #expect(launchModel.clusterID == clusterID.rawValue)
    #expect(launchModel.launchID == UUID(uuidString: "00000000-0000-4000-8000-000000000098"))
}
