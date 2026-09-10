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
@Test func clusterReviewRequiresTwoDistinctPairedTargets() async throws {
    let first = externalClusterTestExternalTarget(1, name: "Spark One")
    let second = externalClusterTestExternalTarget(2, name: "Spark Two")
    let provider = ExternalClusterTestExternalPreviewProvider(
        result: .success(
            ExternalClusterEvidence(
                preview: externalClusterTestExternalPreview(first: first, second: second),
                fabricByNodeID: [
                    first.nodeID: externalClusterTestExternalFabric(peer: second.nodeID),
                    second.nodeID: externalClusterTestExternalFabric(peer: first.nodeID),
                ],
                localRegistrationEligible: true
            )
        )
    )
    let model = ExternalClusterPreviewModel(targets: [first, second], provider: provider)

    #expect(!model.canReview)
    model.toggle(first.id)
    #expect(!model.canReview)
    model.toggle(first.id)
    #expect(model.selectedTargetIDs.isEmpty)
    model.toggle(first.id)
    model.toggle(second.id)
    #expect(model.canReview)

    await model.review()

    #expect(await provider.recordedRequests().first?.1 == [first.id, second.id])
    #expect(model.presentation?.configurationLabel == "Externally Configured")
}

@MainActor
@Test func twoSelectedStandaloneSparksCanEnterTheManagedTransactionFlow() async throws {
    let first = externalClusterTestExternalTarget(1, name: "Spark One")
    let second = externalClusterTestExternalTarget(2, name: "Spark Two")
    let authorizer = ExternalClusterTestManagedClusterAuthorizerFixture()
    let model = ExternalClusterPreviewModel(
        targets: [first, second],
        name: "Studio cluster",
        provider: ExternalClusterTestExternalPreviewProvider(
            result: .failure(ExternalClusterPreviewError.signedEvidenceMismatch)
        ),
        clusterAuthorizer: authorizer
    )
    model.toggle(first.id)
    model.toggle(second.id)
    #expect(model.canAuthorize)

    await model.authorizeNewCluster()

    #expect(model.errorMessage == nil)
    #expect(model.actionMessage == "The two Sparks are linked, trusted and ready as one cluster.")
    #expect(model.selectedTargetIDs.isEmpty)
    #expect(model.launchModel != nil)
    let requests = await authorizer.recordedRequests()
    #expect(requests.count == 1)
    #expect(requests.first?.0 == "Studio cluster")
    #expect(requests.first?.1 == first.nodeID.rawValue)
    #expect(requests.first?.2 == [first.id, second.id])
}

@MainActor
@Test func reversedUiOrderPersistsTheExplicitOriginalSparkAsCoordinator() async throws {
    let first = externalClusterTestExternalTarget(1, name: "Spark One")
    let second = externalClusterTestExternalTarget(2, name: "Spark Two")
    let library = SparkLibrary(store: MemoryLibraryStore())
    library.reconcile(externalClusterTestExternalLibraryTarget(1, name: first.displayName))
    library.reconcile(externalClusterTestExternalLibraryTarget(2, name: second.displayName))
    let authorizer = ExternalClusterTestManagedClusterAuthorizerFixture()
    let model = ExternalClusterPreviewModel(
        targets: [second, first],
        name: "Studio cluster",
        library: library,
        trustLookup: { externalClusterTestExternalTrust($0, role: .owner) },
        provider: ExternalClusterTestExternalPreviewProvider(
            result: .failure(ExternalClusterPreviewError.signedEvidenceMismatch)
        ),
        clusterAuthorizer: authorizer
    )
    model.toggle(second.id)
    model.toggle(first.id)
    model.coordinatorTargetID = second.id

    await model.authorizeNewCluster()

    #expect(await authorizer.recordedRequests().first?.1 == second.nodeID.rawValue)
    #expect(await authorizer.recordedRequests().first?.2 == [second.id, first.id])
    let cluster = try #require(library.entries.first { $0.clusterID != nil })
    #expect(cluster.coordinatorNodeID == second.nodeID)
    #expect(cluster.members.first { $0.nodeID == second.nodeID }?.role == .leader)
    #expect(cluster.members.first { $0.nodeID == first.nodeID }?.role == .worker)
}

@MainActor
@Test func unqualifiedClusterLaunchStaysHiddenAndCannotReachTheCoordinator() async {
    let targets = [
        externalClusterTestExternalTarget(1, name: "Spark One"),
        externalClusterTestExternalTarget(2, name: "Spark Two"),
    ]
    let runtime = ExternalClusterTestManagedClusterRuntimeFixture(isAvailable: false)
    let model = ManagedClusterLaunchModel(
        clusterID: UUID(uuidString: "00000000-0000-4000-8000-000000000099")!,
        targets: targets,
        coordinator: runtime
    )

    await model.refresh()
    #expect(model.availability == .unavailable)
    #expect(!model.isVisible)
    #expect(await runtime.recordedListRequests() == 1)
    await model.start(recipeID: "owner/model", profileID: "safe")
    #expect(await runtime.recordedStartRequests() == 0)
}

@MainActor
@Test func qualifiedClusterExposesMonitoringWithoutAFreeFormStartAction() async {
    let targets = [
        externalClusterTestExternalTarget(1, name: "Spark One"),
        externalClusterTestExternalTarget(2, name: "Spark Two"),
    ]
    let runtime = ExternalClusterTestManagedClusterRuntimeFixture(isAvailable: true)
    let model = ManagedClusterLaunchModel(
        clusterID: UUID(uuidString: "00000000-0000-4000-8000-000000000099")!,
        targets: targets,
        coordinator: runtime
    )

    await model.refresh()
    #expect(model.isVisible)
    #expect(model.launchID == nil)
    #expect(model.statuses.isEmpty)

    await model.start(recipeID: "owner/model", profileID: "safe")
    #expect(await runtime.recordedStartRequests() == 1)
    #expect(model.statuses.count == 2)
}

@MainActor
@Test func existingLaunchIsReconstructedRefreshedAndStoppedAfterCapabilityRevocation() async {
    let targets = [
        externalClusterTestExternalTarget(1, name: "Spark One"),
        externalClusterTestExternalTarget(2, name: "Spark Two"),
    ]
    let statuses = targets.indices.map {
        externalClusterTestManagedMemberStatus($0, targets: targets)
    }
    let runtime = ExternalClusterTestManagedClusterRuntimeFixture(
        isAvailable: false,
        listedStatuses: statuses
    )
    let model = ManagedClusterLaunchModel(
        clusterID: UUID(uuidString: "00000000-0000-4000-8000-000000000099")!,
        targets: targets,
        coordinator: runtime
    )

    await model.refresh()
    #expect(model.availability == .unavailable)
    #expect(model.launchID == UUID(uuidString: "00000000-0000-4000-8000-000000000098"))
    #expect(model.isVisible)
    #expect(await runtime.recordedListRequests() == 1)

    await model.refreshStatus()
    #expect(await runtime.recordedStatusRequests() == 1)
    #expect(model.statuses.count == 2)

    await model.stop()
    #expect(await runtime.recordedStopRequests() == 1)
    #expect(model.statuses.allSatisfy { $0.status.state == .stopped })
}
