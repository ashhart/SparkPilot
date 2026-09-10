import Foundation
import SparkCore
import SparkDesignSystem
import SparkIntelligence
import Testing

@testable import SparkAppComposition

@MainActor
private func policyModel(
    _ choice: SparkExecutionPolicyModel.Choice,
    asksBeforeRemote: Bool = true
) -> SparkExecutionPolicyModel {
    let defaults = UserDefaults(suiteName: "policy-\(UUID().uuidString)")!
    let model = SparkExecutionPolicyModel(defaults: defaults)
    model.choice = choice
    model.asksBeforeRemoteExecution = asksBeforeRemote
    return model
}

@MainActor
private func chatModel(
    connection: TargetConnectionState,
    policy: SparkExecutionPolicyModel
) -> SparkChatModel {
    let target = SparkChatTarget(
        id: "entry",
        displayName: "Desk Spark",
        nodeID: SparkNodeID(rawValue: UUID()),
        route: URL(string: "https://spark.local")!,
        tlsFingerprint: String(repeating: "a", count: 64),
        authorityFingerprint: String(repeating: "b", count: 64),
        modelID: "vendor/model",
        modelName: "Compact 8B",
        connection: connection
    )
    let model = SparkChatModel(
        catalogue: SparkChatTargetCatalogue(targets: [target], pairedTargetCount: 1),
        streamer: ChatTestStaticChatStreamer(events: [])
    )
    model.executionPolicy = policy
    model.draft = "hello"
    return model
}

@MainActor
@Test func onDeviceOnlyRefusesToSendAPromptToASparkAndSaysWhy() {
    let model = chatModel(connection: .connectedWiFi, policy: policyModel(.onDeviceOnly))
    #expect(model.send() == nil)
    #expect(model.executionPolicyRefusal?.contains("on this device only") == true)
    #expect(model.draft == "hello", "a refused send must not consume what was typed")
}

@MainActor
@Test func aRemoteRouteWaitsForConfirmationBeforeAnythingLeaves() {
    let model = chatModel(
        connection: .connectedRemote,
        policy: policyModel(.anyPairedTarget)
    )
    #expect(model.send() == nil)
    #expect(model.pendingRemoteExecution?.contains("remote connection") == true)
    #expect(model.draft == "hello")
    model.cancelRemoteExecution()
    #expect(model.pendingRemoteExecution == nil)
}

@MainActor
@Test func aLocalRouteIsNeverHeldUpByThePolicy() {
    let model = chatModel(connection: .connectedWiFi, policy: policyModel(.sparkOnly))
    #expect(model.executionDecision() == .allowed)
}

@MainActor
@Test func turningOffTheRemoteQuestionLetsARemoteChatProceed() {
    let model = chatModel(
        connection: .connectedRemote,
        policy: policyModel(.anyPairedTarget, asksBeforeRemote: false)
    )
    #expect(model.executionDecision() == .allowed)
}

@MainActor
@Test func thePolicySurvivesRelaunchAndMapsOntoTheRoutingPolicy() {
    let defaults = UserDefaults(suiteName: "policy-persist-\(UUID().uuidString)")!
    let first = SparkExecutionPolicyModel(defaults: defaults)
    first.choice = .myHardwareOnly
    first.asksBeforeRemoteExecution = false

    let second = SparkExecutionPolicyModel(defaults: defaults)
    #expect(second.choice == .myHardwareOnly)
    #expect(second.asksBeforeRemoteExecution == false)
    #expect(second.policy == RoutingPolicy(constraint: .myHardwareOnly))
}

@MainActor
@Test func everyPolicyChoiceExplainsItselfAndMapsToAConstraint() {
    for choice in SparkExecutionPolicyModel.Choice.allCases {
        #expect(!choice.title.isEmpty)
        #expect(!choice.detail.isEmpty)
    }
    #expect(SparkExecutionPolicyModel.Choice.anyPairedTarget.constraint == nil)
    #expect(SparkExecutionPolicyModel.Choice.sparkOnly.constraint == .sparkOnly)
    #expect(SparkExecutionPolicyModel.Choice.onDeviceOnly.constraint == .onDeviceOnly)
}
