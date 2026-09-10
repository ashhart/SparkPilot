import Foundation
import Network
import SparkDiscovery
import Testing

@testable import SparkAppComposition

private func discovered(_ name: String) -> DiscoveredSpark {
    DiscoveredSpark(
        id: "spark-\(name)._spark-runtime._tcp.local.",
        displayName: name,
        endpoint: .hostPort(host: NWEndpoint.Host(name), port: 7_443),
        interface: nil,
        shortNodeID: "a1b2c3d4"
    )
}

/// QA-03: "Continue with This Spark" drew a green success tick over an address nothing had contacted; only a Spark that answered discovery may be shown as found.
@Test func aTypedAddressIsNeverDrawnAsAConnectedSpark() {
    let typed = DiscoveredSpark(
        id: "manual:192.0.2.1:7443",
        displayName: "192.0.2.1",
        endpoint: .hostPort(host: "192.0.2.1", port: 7_443),
        interface: nil,
        shortNodeID: nil
    )

    #expect(PairThisDeviceEvidence.resolve(typed) == .addressTypedByHand)
    #expect(!PairThisDeviceEvidence.resolve(typed).showsConnectedArtwork)
    #expect(PairThisDeviceEvidence.resolve(typed).saysNothingHasBeenChecked)
}

/// QA-03: a Spark that answered on the network keeps the confirmation it earned.
@Test func aSparkFoundOnTheNetworkKeepsItsConnectedArtwork() {
    #expect(PairThisDeviceEvidence.resolve(discovered("desk-spark")) == .foundOnNetwork)
    #expect(PairThisDeviceEvidence.resolve(discovered("desk-spark")).showsConnectedArtwork)
    #expect(!PairThisDeviceEvidence.resolve(discovered("desk-spark")).saysNothingHasBeenChecked)
    #expect(PairThisDeviceEvidence.resolve(nil) == .noTarget)
    #expect(!PairThisDeviceEvidence.resolve(nil).showsConnectedArtwork)
}

/// QA-03: the address the owner actually typed is the one that arrives unverified, so the marker cannot drift from what the flow mints.
@MainActor
@Test func theAddressTypedIntoAddSparkArrivesWithoutEvidence() {
    let model = RetailOnboardingModel()
    model.chooseSparkToAdd()

    #expect(model.chooseExistingSpark(host: "192.0.2.1"))
    #expect(PairThisDeviceEvidence.resolve(model.pairingDeviceTarget) == .addressTypedByHand)
}

/// QA-06: "Pair with Invitation" sits at the bottom of a long form and its refusal rendered near the top, off-screen from where it was tapped.
@Test func aPairingFailureIsPlacedUnderTheActionThatCausedIt() {
    #expect(PairThisDeviceErrorPlacement.resolve(nil) == .aboveTheForm)
    #expect(PairThisDeviceErrorPlacement.resolve(.joinCode) == .underJoinCode)
    #expect(PairThisDeviceErrorPlacement.resolve(.invitation) == .underInvitation)
}

/// QA-06: the view renders the message in exactly the place the resolved position names.
@Test func thePairingErrorIsRenderedAtEveryResolvedPosition() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
    let source = try String(
        contentsOf: appRoot.appending(path: "Shared/AdditionalDevicePairingView.swift"),
        encoding: .utf8
    )

    for placement in [".aboveTheForm", ".underJoinCode", ".underInvitation"] {
        #expect(source.contains("pairingError(at: \(placement))"))
    }
}
