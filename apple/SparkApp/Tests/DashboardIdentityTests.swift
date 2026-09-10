import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing
@testable import SparkAppComposition

@MainActor
@Test func secondRefreshIdentityMismatchNeverPublishesAttackerData() async {
    let runtime = DashboardTestMutableIdentityRuntime(nodeID: dashboardTestDashboardCoordinatorID)
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        targetID: "node:\(dashboardTestDashboardCoordinatorID)",
        expectedIdentity: SparkDashboardIdentityExpectation(
            coordinatorNodeID: dashboardTestDashboardNodeID(dashboardTestDashboardCoordinatorID),
            authorityFingerprint: "authority-a",
            clusterID: nil
        ),
        operationStore: DashboardTestTestOperationStore()
    )

    await model.refresh()
    #expect(model.status?.identity.name == "My Spark")
    #expect(model.models.first?.id == "open/good-model")

    await runtime.replaceIdentity(
        nodeID: dashboardTestDashboardAttackerID,
        authorityFingerprint: "authority-attacker",
        nodeName: "Attacker Spark",
        modelID: "attacker/stolen-model"
    )
    await model.refresh()

    #expect(model.identityIssue == .coordinatorMismatch)
    #expect(model.errorMessage?.contains("identity") == true)
    #expect(model.status?.identity.name == "My Spark")
    #expect(model.models.first?.id == "open/good-model")
    #expect(model.inference?.modelID == "open/good-model")
    #expect(
        model.health?.nodeID == dashboardTestDashboardNodeID(dashboardTestDashboardCoordinatorID)
    )
}

@MainActor
@Test func matchingCoordinatorIdentityAcceptsAChangedRoute() async {
    let runtime = DashboardTestMutableIdentityRuntime(nodeID: dashboardTestDashboardCoordinatorID)
    let changedRoute = URL(string: "https://10.0.0.42:7443")!
    let model = SparkDashboardModel(
        route: changedRoute,
        runtime: runtime,
        expectedIdentity: SparkDashboardIdentityExpectation(
            coordinatorNodeID: dashboardTestDashboardNodeID(dashboardTestDashboardCoordinatorID),
            authorityFingerprint: "authority-a",
            clusterID: nil
        ),
        operationStore: DashboardTestTestOperationStore()
    )

    await model.refresh()

    #expect(model.identityIssue == nil)
    #expect(
        model.status?.identity.nodeID
            == dashboardTestDashboardNodeID(dashboardTestDashboardCoordinatorID)
    )
    #expect(await runtime.routes.contains(changedRoute))
}

@MainActor
@Test func authorityMismatchDoesNotPublishResponsesFromTheSameNodeID() async {
    let runtime = DashboardTestMutableIdentityRuntime(nodeID: dashboardTestDashboardCoordinatorID)
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        expectedIdentity: SparkDashboardIdentityExpectation(
            coordinatorNodeID: dashboardTestDashboardNodeID(dashboardTestDashboardCoordinatorID),
            authorityFingerprint: "authority-a",
            clusterID: nil
        ),
        operationStore: DashboardTestTestOperationStore()
    )
    await model.refresh()

    await runtime.replaceIdentity(
        nodeID: dashboardTestDashboardCoordinatorID,
        authorityFingerprint: "authority-replaced",
        nodeName: "Rekeyed Spark",
        modelID: "attacker/rekeyed-model"
    )
    await model.refresh()

    #expect(model.identityIssue == .authorityMismatch)
    #expect(model.status?.identity.name == "My Spark")
    #expect(model.models.first?.id == "open/good-model")
}

@MainActor
@Test func clusterTargetValidatesItsCoordinatorInsteadOfItsLogicalTargetID() async {
    let clusterID = "11111111-2222-4333-8444-555555555555"
    let runtime = DashboardTestMutableIdentityRuntime(
        nodeID: dashboardTestDashboardCoordinatorID,
        clusterID: clusterID
    )
    let model = SparkDashboardModel(
        route: URL(string: "https://cluster-leader.local:7443")!,
        runtime: runtime,
        targetID: "cluster:\(clusterID)",
        expectedIdentity: SparkDashboardIdentityExpectation(
            coordinatorNodeID: dashboardTestDashboardNodeID(dashboardTestDashboardCoordinatorID),
            authorityFingerprint: "authority-a",
            clusterID: SparkClusterID(rawValue: UUID(uuidString: clusterID)!)
        ),
        operationStore: DashboardTestTestOperationStore()
    )

    await model.refresh()

    #expect(model.identityIssue == nil)
    #expect(
        model.status?.identity.nodeID
            == dashboardTestDashboardNodeID(dashboardTestDashboardCoordinatorID)
    )
    #expect(
        model.status?.identity.clusterID == SparkClusterID(rawValue: UUID(uuidString: clusterID)!)
    )
}
