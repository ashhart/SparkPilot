import Foundation
import SparkCore
import SparkDesignSystem
import Testing

@testable import SparkAppComposition

private func target(
    connection: TargetConnectionState,
    cluster: SparkClusterID? = nil
) -> SparkChatTarget {
    SparkChatTarget(
        id: "entry",
        displayName: "Desk Spark",
        nodeID: SparkNodeID(rawValue: UUID()),
        clusterID: cluster,
        route: URL(string: "https://spark.local")!,
        tlsFingerprint: String(repeating: "a", count: 64),
        authorityFingerprint: String(repeating: "b", count: 64),
        modelID: "vendor/model",
        modelName: "Compact 8B",
        connection: connection
    )
}

@Test func aLocalChatDisclosesTheSparkAndItsTransport() {
    let location = target(connection: .connectedWiFi).executionLocation
    #expect(location.label == "On Desk Spark")
    #expect(location.detail == "Local Wi-Fi")
    #expect(location.transport.leavesThisDevice)
}

@Test func aDirectCableChatNamesTheTenGigabitRoute() {
    #expect(target(connection: .connectedDirect).executionLocation.detail == "Direct 10 GbE")
}

@Test func aRemoteChatSaysItIsARemoteConnectionRatherThanLookingLocal() {
    let location = target(connection: .connectedRemote).executionLocation
    #expect(location.label == "Remote connection to Desk Spark")
    #expect(location.detail == "Secure remote connection")
    #expect(location.symbol != ExecutionLocationValue.spark(nodeName: "Desk Spark").symbol)
}

@Test func aClusterChatDisclosesTheClusterNotAMemberNode() {
    let location = target(
        connection: .connectedWiFi,
        cluster: SparkClusterID(rawValue: UUID())
    ).executionLocation
    #expect(location.label == "On Desk Spark")
    #expect(location.symbol == "rectangle.stack.3d.up")
}

@Test func theOnDeviceLabelNamesThisAppleDeviceAndSendsNothing() {
    let location = ExecutionLocationValue.appleSystem
    #expect(!location.transport.leavesThisDevice)
    #expect(location.detail == "Nothing leaves this device")
    #expect(location.label.hasPrefix("On this "))
}

@Test func theSpokenTargetNamesTheTransportNotJustTheSparkName() {
    let spoken = target(connection: .connectedRemote).executionAccessibilityLabel
    #expect(spoken.contains("Remote connection to Desk Spark"))
    #expect(spoken.contains("Compact 8B"))
}
