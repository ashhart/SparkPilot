import Foundation
import Network
import SparkDiscovery
import Testing

@testable import SparkAppComposition

private func node(_ name: String, cluster: String? = nil) -> DiscoveredSpark {
    DiscoveredSpark(
        id: name,
        displayName: name,
        endpoint: .hostPort(host: NWEndpoint.Host(name), port: 7_443),
        interface: nil,
        shortNodeID: nil,
        clusterID: cluster
    )
}

private func machine(_ name: String) -> BootstrapSpark {
    BootstrapSpark(
        displayName: name,
        endpoint: .hostPort(host: NWEndpoint.Host(name), port: 22)
    )
}

/// PLAN 10.2.3: one flat "Sparks Nearby" list cannot say which of the three a row is.
@Test func discoveryResultsAreGroupedTheWayPlan10_2_3Names() {
    let groups = AddSparkResultGroups.resolve(
        nodes: [node("desk-spark"), node("lab-spark", cluster: "cluster-1")],
        bootstrap: [machine("fresh-dgx")]
    )

    #expect(groups.runtime.map(\.displayName) == ["desk-spark"])
    #expect(groups.clusters.map(\.displayName) == ["lab-spark"])
    #expect(groups.dgx.map(\.displayName) == ["fresh-dgx"])
    #expect(!groups.isEmpty)
}

/// A Spark already advertising its runtime is not also offered as a machine to install on.
@Test func aSparkFoundOnBothServicesIsListedOnlyUnderItsRuntime() {
    let groups = AddSparkResultGroups.resolve(
        nodes: [node("desk-spark")],
        bootstrap: [machine("Desk-Spark.local"), machine("fresh-dgx")]
    )

    #expect(groups.runtime.map(\.displayName) == ["desk-spark"])
    #expect(groups.dgx.map(\.displayName) == ["fresh-dgx"])
}

/// An empty TXT cluster field is not a cluster.
@Test func anEmptyClusterHintKeepsASparkStandalone() {
    let groups = AddSparkResultGroups.resolve(nodes: [node("desk", cluster: "")], bootstrap: [])

    #expect(groups.runtime.count == 1)
    #expect(groups.clusters.isEmpty)
}

/// PLAN 10.2.2: browsing must start on both services when the owner asks to add a Spark.
@Test func addingASparkBrowsesBothRuntimeAndSetupServices() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let coordinator = try String(
        contentsOf: appRoot.appending(path: "Shared/RetailOnboardingFlowCoordinator.swift"),
        encoding: .utf8
    )
    let addSpark = try #require(coordinator.range(of: "func chooseSparkToAdd() {"))
    let body = coordinator[addSpark.upperBound...].prefix(400)
    #expect(body.contains("localDiscovery.start()"))
    #expect(body.contains("bootstrapDiscovery.start()"))

}

@Test func sshNamesAreHintsAndOrdinaryComputersAreNotPresentedAsConfirmedSparks() {
    let groups = AddSparkResultGroups.resolve(
        nodes: [],
        bootstrap: [machine("Spark-a8bf SSH"), machine("Pat’s MacBook Pro"), machine("Mac Studio")]
    )
    #expect(groups.possibleSparks.map(\.displayName) == ["Spark-a8bf SSH"])
    #expect(groups.otherDevices.count == 2)
}

@Test func sshSuffixDoesNotDuplicateAnAdvertisedRuntime() {
    let groups = AddSparkResultGroups.resolve(
        nodes: [node("spark-example")],
        bootstrap: [machine("Spark-a8bf.local SSH")]
    )
    #expect(groups.dgx.isEmpty)
}

@MainActor
@Test func existingSparksGoStraightToInspectionAndCanLeaveBeforeInstalling() {
    let model = RetailOnboardingModel()
    let spark = machine("spark-example")
    model.chooseBootstrapSpark(spark)
    #expect(model.state.phase == .runtimeInstall)
    #expect(model.bootstrapTarget == spark)
    #expect(model.needsExistingSparkReview)
    model.goBack()
    #expect(model.isChoosingSpark)
    #expect(model.bootstrapTarget == nil)
}

@MainActor
@Test func manualExistingSparkSetupUsesSSHAndRequiresInspection() throws {
    let target = try #require(ExistingSparkAddress.bootstrap(" 192.0.2.10 "))
    #expect(target.endpoint == .hostPort(host: "192.0.2.10", port: 22))
    let model = RetailOnboardingModel()
    model.chooseBootstrapSpark(target)
    #expect(model.state.phase == .runtimeInstall)
    #expect(model.needsExistingSparkReview)
    #expect(model.pairingDeviceTarget == nil)
    model.goBack()
    #expect(model.isChoosingSpark)
}

@Test func existingSparkSetupValidatesAddressesAndPreservesExplicitSSHPorts() throws {
    let target = try #require(ExistingSparkAddress.bootstrap("spark.local:2222"))
    #expect(target.endpoint == .hostPort(host: "spark.local", port: 2222))
    #expect(ExistingSparkAddress.bootstrap("[fd00::1]:2222") != nil)
    for invalid in [
        "", "not a host", "https://spark.local", "owner:password@spark.local", "spark.local:65536",
        "spark.local:0",
    ] {
        #expect(ExistingSparkAddress.bootstrap(invalid) == nil)
    }
    let pairing = try #require(ExistingSparkAddress.discovered("spark.local"))
    #expect(pairing.endpoint == .hostPort(host: "spark.local", port: 7443))
}
