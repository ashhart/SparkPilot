import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing
@testable import SparkAppComposition

@MainActor
@Test func aSparkThatObservesWorkloadsShowsWhatElseIsRunningOnIt() async {
    let model = SparkDashboardModel(
        route: URL(string: "https://spark-a1b2.local:7443")!,
        runtime: DashboardTestFakeRuntimeReader(
            workloadInventory: dashboardTestHostWorkloadInventory(workloads: [
                dashboardTestExternalDeepSeek
            ]),
            advertisesWorkloadInventory: true
        ),
        operationStore: DashboardTestTestOperationStore(),
        telemetryCache: DashboardTestTestTelemetryCache()
    )

    await model.refresh()

    let inventory = try! #require(model.workloadInventory)
    #expect(inventory.available)
    #expect(inventory.workloads.count == 1)
    #expect(model.workloadErrorMessage == nil)
    let sections = SparkWorkloadPresentation.sections(inventory)
    #expect(sections.count == 1)
    #expect(sections[0].id == SparkWorkloadPresentation.externalSectionID)
}

@MainActor
@Test func aRuntimeWithoutTheInventoryCapabilityIsNotAskedToPretend() async {
    // An unsupported workload capability hides the surface rather than presenting an empty inventory.
    let model = SparkDashboardModel(
        route: URL(string: "https://spark-a1b2.local:7443")!,
        runtime: DashboardTestFakeRuntimeReader(
            workloadInventory: dashboardTestHostWorkloadInventory(workloads: [
                dashboardTestExternalDeepSeek
            ]),
            advertisesWorkloadInventory: false
        ),
        operationStore: DashboardTestTestOperationStore(),
        telemetryCache: DashboardTestTestTelemetryCache()
    )

    await model.refresh()

    #expect(model.workloadInventory == nil)
    #expect(model.workloadErrorMessage == nil)
}

@MainActor
@Test func aFailedWorkloadReadIsReportedRatherThanShownAsAnIdleSpark() async {
    // A failed supported workload read must show unavailable evidence rather than imply the Spark is idle.
    let model = SparkDashboardModel(
        route: URL(string: "https://spark-a1b2.local:7443")!,
        runtime: DashboardTestFakeRuntimeReader(
            workloadInventory: nil,
            advertisesWorkloadInventory: true
        ),
        operationStore: DashboardTestTestOperationStore(),
        telemetryCache: DashboardTestTestTelemetryCache()
    )

    await model.refresh()

    #expect(model.workloadInventory == nil)
    #expect(model.workloadErrorMessage == "Workloads on this Spark could not be listed.")
}

@MainActor
@Test func aFailedWorkloadReadDoesNotBlankHealthModelsOrInference() async {
    // Keep primary dashboard data visible when supplementary workload inventory fails.
    let model = SparkDashboardModel(
        route: URL(string: "https://spark-a1b2.local:7443")!,
        runtime: DashboardTestFakeRuntimeReader(
            workloadInventory: nil,
            advertisesWorkloadInventory: true
        ),
        operationStore: DashboardTestTestOperationStore(),
        telemetryCache: DashboardTestTestTelemetryCache()
    )

    await model.refresh()

    #expect(model.runtimeStatus == "Healthy")
    #expect(model.models.count == 1)
    #expect(model.errorMessage == nil)
}

@MainActor
@Test func aSparkThatCouldNotInspectItsHostSaysSoRatherThanShowingNothing() async {
    let model = SparkDashboardModel(
        route: URL(string: "https://spark-a1b2.local:7443")!,
        runtime: DashboardTestFakeRuntimeReader(
            workloadInventory: dashboardTestHostWorkloadInventory(available: false),
            advertisesWorkloadInventory: true
        ),
        operationStore: DashboardTestTestOperationStore(),
        telemetryCache: DashboardTestTestTelemetryCache()
    )

    await model.refresh()

    let inventory = try! #require(model.workloadInventory)
    #expect(!inventory.available)
    #expect(SparkWorkloadPresentation.unavailableMessage(inventory) != nil)
    #expect(SparkWorkloadPresentation.emptyMessage(inventory) == nil)
}

@MainActor
@Test func aDeviceThatMayNotReadWorkloadsIsNotShownAPermanentFailure() async {
    // Distinguish role denial from workload-read failure because capabilities describe the node rather than the device grant.
    let model = SparkDashboardModel(
        route: URL(string: "https://spark-a1b2.local:7443")!,
        runtime: DashboardTestFakeRuntimeReader(
            workloadInventory: dashboardTestHostWorkloadInventory(workloads: [
                dashboardTestExternalDeepSeek
            ]),
            advertisesWorkloadInventory: true,
            refusesWorkloadInventory: true
        ),
        operationStore: DashboardTestTestOperationStore(),
        telemetryCache: DashboardTestTestTelemetryCache()
    )

    await model.refresh()

    #expect(model.workloadInventory == nil)
    #expect(model.workloadErrorMessage == nil)
    // The rest of the dashboard is unaffected.
    #expect(model.runtimeStatus == "Healthy")
}

@Test func aRefusalIsDistinguishedFromEveryOtherFailure() {
    #expect(
        SparkDashboardModel.isRefusal(
            APIError(.local(message: "no"), statusCode: 403, code: "ROLE_FORBIDDEN")
        )
    )
    #expect(
        !SparkDashboardModel.isRefusal(
            APIError(.local(message: "no"), statusCode: 503, code: "SERVICE_UNAVAILABLE")
        )
    )
    #expect(!SparkDashboardModel.isRefusal(PendingRuntimeError.unconfigured))
    #expect(!SparkDashboardModel.isRefusal(URLError(.notConnectedToInternet)))
}
