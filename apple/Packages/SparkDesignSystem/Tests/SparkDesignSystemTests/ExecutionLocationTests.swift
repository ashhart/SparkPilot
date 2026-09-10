import Foundation
import SparkDesignSystem
import Testing

/// Name the actual execution target and its transport through both symbol and label (§39.2, §52.1).
@Test func executionLocationVocabularyCoversEveryTarget() {
    let onDevice = ExecutionLocationValue.appleSystem
    #expect(onDevice.label.hasPrefix("On this "))
    #expect(!onDevice.symbol.isEmpty)
    #expect(!onDevice.transport.leavesThisDevice)

    let spark = ExecutionLocationValue.spark(nodeName: "Studio Spark")
    #expect(spark.label == "On Studio Spark")
    #expect(spark.symbol == "server.rack")

    let anonymous = ExecutionLocationValue.spark(nodeName: nil)
    #expect(anonymous.label == "On your Spark")

    let cluster = ExecutionLocationValue.sparkCluster(nodeCount: 2)
    #expect(cluster.label == "On Spark cluster · 2 nodes")

    let remote = ExecutionLocationValue.spark(nodeName: "Studio Spark", transport: .remote)
    #expect(remote.label == "Remote connection to Studio Spark")
    #expect(remote.detail == "Secure remote connection")
}

/// Every transport says out loud whether the prompt leaves the Apple device (§52.1).
@Test func everyTransportStatesWhetherDataLeavesTheDevice() {
    for transport in SparkExecutionTransport.allCases {
        #expect(!transport.detail.isEmpty)
        #expect(transport.leavesThisDevice == (transport != .onThisDevice))
    }
}

@Test func executionLabelsNeverMentionCloudProviders() {
    for value in [
        ExecutionLocationValue.appleSystem,
        ExecutionLocationValue.spark(nodeName: nil),
        ExecutionLocationValue.sparkCluster(nodeCount: 2),
    ] {
        #expect(!value.label.localizedCaseInsensitiveContains("cloud"))
        #expect(!value.label.localizedCaseInsensitiveContains("http"))
    }
}
