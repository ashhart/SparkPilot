import CryptoKit
import Foundation
import Network
import SparkAPI
import SparkAppComposition
import SparkDiscovery
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing

@MainActor
@Test func appLabelIsLocalPersistentAndIndependentOfReportedSparkName() {
    let (model, library, entryID, _) = makeIdentitySettings()

    model.draftLabel = "Workshop Spark"
    model.saveLabel()

    #expect(model.displayName == "Workshop Spark")
    #expect(library.entry(id: entryID)?.displayName == "Workshop Spark")
    #expect(library.entry(id: entryID)?.name == "DGX Spark")
    #expect(model.labelMessage == "Name saved.")
}

@MainActor
@Test func hostnameChangeRequiresConfirmationBeforePresenceOrNetwork() async {
    let runtime = FakeHostname()
    let presence = AppTestPresenceAuthorizer()
    let (model, _, _, _) = makeIdentitySettings(runtime: runtime, presence: presence)

    model.draftHostname = "spark1"
    model.requestHostnameChange()

    #expect(model.pendingHostname == "spark1")
    #expect(await presence.recordedAuthorizationCount() == 0)
    #expect(await runtime.recordedCalls().isEmpty)
    model.cancelHostnameChange()
    #expect(await runtime.recordedCalls().isEmpty)
}

@MainActor
@Test func confirmedHostnameChangePollsToSuccessAndUpdatesLocalDiscoveryMetadata() async {
    let runtime = FakeHostname()
    let presence = AppTestPresenceAuthorizer()
    let (model, library, entryID, nodeID) = makeIdentitySettings(
        runtime: runtime,
        presence: presence
    )

    model.draftHostname = "Spark1.local"
    model.requestHostnameChange()
    await model.confirmHostnameChange()

    #expect(await presence.recordedAuthorizationCount() == 1)
    #expect(await runtime.recordedCalls().map(\.0) == ["spark1"])
    #expect(model.hostname == "spark1")
    #expect(model.hostnameForDisplay == "spark1.local")
    #expect(library.entry(id: entryID)?.member(nodeID: nodeID)?.hostname == "spark1")
    #expect(model.hostnameMessage?.contains("spark1.local") == true)
}

@MainActor
@Test func nonOwnerCanRenameTheLocalCardButCannotChangeTheHostname() async {
    let runtime = FakeHostname()
    let (model, library, entryID, _) = makeIdentitySettings(
        runtime: runtime,
        canChangeHostname: false
    )

    model.draftLabel = "My lab"
    model.saveLabel()
    model.draftHostname = "spark2"
    model.requestHostnameChange()

    #expect(library.entry(id: entryID)?.displayName == "My lab")
    #expect(model.pendingHostname == nil)
    #expect(model.errorMessage?.contains("Only the owner") == true)
    #expect(await runtime.recordedCalls().isEmpty)
}

@MainActor
@Test func powerControlsRequireConfirmationBeforeAuthenticationOrNetwork() async {
    let power = AppShellTestFakePower()
    let presence = AppTestPresenceAuthorizer()
    let model = SparkPowerControlModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: power,
        userPresenceAuthorizer: presence
    )

    model.request(.shutdown)
    #expect(model.pendingAction == .shutdown)
    #expect(await presence.recordedAuthorizationCount() == 0)
    #expect(await power.recordedCalls().isEmpty)

    model.cancelConfirmation()
    #expect(model.pendingAction == nil)
    #expect(await presence.recordedAuthorizationCount() == 0)
    #expect(await power.recordedCalls().isEmpty)
}
