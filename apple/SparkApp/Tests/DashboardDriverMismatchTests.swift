import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import Testing
@testable import SparkAppComposition

private let restartTitle = "Restart the Spark to finish the driver update"
private let restartMessage =
    "The NVIDIA driver on the Spark was updated, but the running kernel still has the old driver loaded. Restart the Spark, then launch the model again."

/// What sparkd records after spark-privd refuses a start with GPU_DRIVER_MISMATCH.
private func driverMismatchOperation() throws -> SparkAPI.Operation {
    try dashboardTestLifecycleOperation(
        kind: "model.load",
        state: "failed",
        progress: 0.55,
        stage: "starting",
        errorCode: "GPU_DRIVER_MISMATCH"
    )
}

@Test func driverMismatchCodeIsPresentedAsARestartTask() throws {
    let operation = try driverMismatchOperation()
    #expect(SparkDashboardFailurePresentation.ownerOperationErrorTitle(operation) == restartTitle)
    #expect(SparkDashboardFailurePresentation.ownerOperationError(operation) == restartMessage)
    let recovery = SparkDashboardFailurePresentation.terminalRecoveryAction(for: operation)
    #expect(recovery == .restartSpark)
    #expect(
        ModelOperationRecoveryAction.restartSpark.accessibilityLabel(modelName: "Compact 8B")
            == "Restart the Spark, then launch Compact 8B again"
    )

    let other = try dashboardTestLifecycleOperation(
        kind: "model.load",
        state: "failed",
        progress: nil,
        errorCode: "MODEL_LOAD_FAILED"
    )
    #expect(SparkDashboardFailurePresentation.ownerOperationErrorTitle(other) == nil)
    let otherRecovery = SparkDashboardFailurePresentation.terminalRecoveryAction(for: other)
    #expect(otherRecovery == .retryTerminalFailure)
}

@MainActor
@Test func driverMismatchLoadFailureOffersARestartInsteadOfARetry() async throws {
    let runtime = DashboardTestLifecycleRuntime(loadResponses: [try driverMismatchOperation()])
    let model = SparkDashboardModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        operationStore: DashboardTestTestOperationStore(),
        operationDelay: { _ in }
    )
    await model.refresh()
    await model.prepareLoad(modelID: "open/model-8b", replaceActive: false)
    await model.applyConfirmation()

    let state = try #require(model.lifecycleState(for: "open/model-8b"))
    #expect(state.technicalErrorCode == "GPU_DRIVER_MISMATCH")
    #expect(state.errorTitle == restartTitle)
    #expect(state.errorMessage == restartMessage)
    #expect(state.recoveryAction == .restartSpark)
}

private func driverMismatchTarget() -> SparkChatTarget {
    SparkChatTarget(
        id: "desk",
        displayName: "Desk Spark",
        nodeID: SparkNodeID(rawValue: UUID(uuidString: "63e82da2-7fb7-4b4b-9584-4a528000ac94")!),
        route: URL(string: "https://spark.example:8443")!,
        tlsFingerprint: String(repeating: "a", count: 64),
        authorityFingerprint: String(repeating: "b", count: 64),
        modelID: "nemotron",
        modelName: "Nemotron",
        contextLength: 65_536
    )
}

/// A launcher whose apply fails the way the dashboard reports a driver mismatch.
@MainActor
private final class DriverMismatchLauncher: SparkModelLaunching {
    func profiles(for target: SparkChatTarget) async throws -> [SparkModelProfile] {
        try JSONDecoder().decode(
            [SparkModelProfile].self,
            from: Data(
                #"[{"id":"agent","display_name":"Agent 64K","max_model_length":65536,"max_sequences":8,"expected_peak_bytes":1000000,"safe":true}]"#
                    .utf8
            )
        )
    }

    func prepare(target: SparkChatTarget, profileID: String?) async throws -> SparkModelLaunchPlan {
        SparkModelLaunchPlan(target: target, confirmation: nil)
    }

    func apply(_ plan: SparkModelLaunchPlan) async throws -> SparkChatTarget {
        throw SparkModelLaunchError(title: restartTitle, message: restartMessage)
    }

    func discard(_ plan: SparkModelLaunchPlan) {}
}

@MainActor
@Test func quickLaunchShowsTheRestartHeadlineAboveTheReason() async throws {
    let model = SparkQuickLaunchModel(launcher: DriverMismatchLauncher()) {
        [driverMismatchTarget()]
    }
    await model.refresh()
    #expect(model.selectedProfile?.id == "agent")

    await model.prepare()

    #expect(model.errorTitle == restartTitle)
    #expect(model.errorMessage == restartMessage)
    #expect(!model.ready)
    // Choosing again clears the headline with the message.
    await model.select("desk/nemotron")
    #expect(model.errorTitle == nil)
}
