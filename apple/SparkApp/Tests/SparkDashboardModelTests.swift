import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing
@testable import SparkAppComposition

@Test func visibleDashboardUsesThePlanOneHertzTelemetryCadence() {
    #expect(SparkDashboardRefreshPolicy.liveTelemetryInterval == .seconds(1))
}

@MainActor
@Test func dashboardReportsRuntimeModelsAndVLLMHealth() async {
    let cache = DashboardTestTestTelemetryCache()
    let model = SparkDashboardModel(
        route: URL(string: "https://spark-a1b2.local:7443")!,
        runtime: DashboardTestFakeRuntimeReader(),
        operationStore: DashboardTestTestOperationStore(),
        telemetryCache: cache
    )

    await model.refresh()

    #expect(model.runtimeStatus == "Healthy")
    #expect(model.vllmStatus == "Healthy")
    #expect(model.models.count == 1)
    #expect(model.models[0].installState == .installed)
    #expect(model.nodeName == "My Spark")
    #expect(model.telemetryIsLive)
    #expect(model.gpuTelemetry == "64%")
    #expect(model.cpuTelemetry == "27%")
    #expect(model.temperatureTelemetry == "55°C")
    #expect(model.powerTelemetry == "50 W")
    #expect(model.unifiedMemoryTelemetry.contains("used"))
    #expect(model.unifiedMemoryTelemetryDetail.contains("available"))
    #expect(model.gpuMemoryTelemetry.contains("used"))
    #expect(model.gpuMemoryTelemetryDetail.contains("total"))
    #expect(model.memoryStallTelemetry == "0.12%")
    #expect(model.storageTelemetry.contains("used"))
    #expect(model.inferenceTelemetry == "42.5 tok/s")
    #expect(model.usageTelemetry.contains("800"))
    #expect(model.uptimeTelemetry == "2m")
    #expect(cache.snapshots[model.targetID] == model.telemetry)
}

@MainActor
@Test func liveTelemetryClearsAnOlderCriticalMemoryBanner() async {
    let model = SparkDashboardModel(
        route: URL(string: "https://spark-a1b2.local:7443")!,
        runtime: DashboardTestFakeRuntimeReader(
            statusMemoryPressure: "critical",
            telemetryMemoryPressure: "normal"
        ),
        operationStore: DashboardTestTestOperationStore(),
        telemetryCache: DashboardTestTestTelemetryCache()
    )

    await model.refresh()

    #expect(model.telemetryIsLive)
    #expect(model.pressurePresentation == nil)
}

@MainActor
@Test func cancelledDashboardRefreshDoesNotReportACertificateOrReachabilityFailure() async {
    let model = SparkDashboardModel(
        route: URL(string: "https://spark-a1b2.local:7443")!,
        runtime: DashboardTestFakeRuntimeReader(cancelRefresh: true),
        operationStore: DashboardTestTestOperationStore(),
        telemetryCache: DashboardTestTestTelemetryCache()
    )

    await model.refresh()

    #expect(model.errorMessage == nil)
    #expect(model.identityIssue == nil)
}

@MainActor
@Test func dashboardFailsClosedWhenTheContainerRuntimeIsUnavailable() async {
    let runtime = DashboardTestFakeRuntimeReader(containerRuntime: false)
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        operationStore: DashboardTestTestOperationStore(),
        telemetryCache: DashboardTestTestTelemetryCache()
    )

    await model.refresh()

    #expect(model.vllmStatus == "Setup required")
    await model.prepareInstall(modelID: "open/model-8b")
    #expect(model.pendingConfirmation == nil)
}

@MainActor
@Test func dashboardDoesNotPublishModelsWithoutSignedCatalogueCapability() async {
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: DashboardTestFakeRuntimeReader(signedCatalogue: false),
        operationStore: DashboardTestTestOperationStore(),
        telemetryCache: DashboardTestTestTelemetryCache()
    )

    await model.refresh()

    #expect(model.models.isEmpty)
    #expect(model.modelCatalogueStatus == "Unavailable")
    #expect(model.modelCatalogueDetail.contains("verified model catalogue"))
}
