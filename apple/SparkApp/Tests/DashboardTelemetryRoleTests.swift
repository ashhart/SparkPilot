import Foundation
import SparkAPI
import Testing

@testable import SparkAppComposition

/// The Spark shows live telemetry to administrators and its owner; a device paired with another role is told so, not "paused".
@MainActor
@Test func aRoleTheSparkDoesNotShowTelemetryToIsToldWhoMaySeeIt() async {
    let runtime = DashboardTestFakeRuntimeReader(
        telemetryFailure: APIError(.reported, statusCode: 403, code: "ROLE_FORBIDDEN")
    )
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        operationStore: DashboardTestTestOperationStore(),
        operationDelay: { _ in }
    )

    await model.refreshTelemetry(reportFailure: true)

    let message = model.telemetryErrorMessage ?? ""
    #expect(message.contains("administrators"), "got: \(message)")
    #expect(!message.contains("paused"), "a refusal by role is not a pause")
}
