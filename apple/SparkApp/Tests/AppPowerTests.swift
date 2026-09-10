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
@Test func confirmedPowerActionsUsePresenceAndExplainWhatHappensNext() async {
    let power = AppShellTestFakePower()
    let presence = AppTestPresenceAuthorizer()
    let model = SparkPowerControlModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: power,
        userPresenceAuthorizer: presence
    )

    model.request(.shutdown)
    await model.confirm()

    #expect(await presence.recordedAuthorizationCount() == 1)
    #expect(await power.recordedCalls().map(\.0) == [.shutdown])
    #expect(model.acceptedAction == .shutdown)
    #expect(model.successMessage?.contains("physical power button") == true)
    #expect(model.errorMessage == nil)
}

@MainActor
@Test func decliningPowerConfirmationSendsNoPowerRequest() async {
    let power = AppShellTestFakePower()
    let model = SparkPowerControlModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: power,
        userPresenceAuthorizer: AppTestPresenceAuthorizer(outcome: .decline)
    )

    model.request(.reboot)
    await model.confirm()

    #expect(await power.recordedCalls().isEmpty)
    #expect(model.errorMessage?.contains("Nothing changed") == true)
}

@MainActor
@Test func ambiguousPowerRetryReusesItsIdempotencyKey() async {
    let power = AppShellTestFakePower(failures: [.network])
    let model = SparkPowerControlModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: power,
        userPresenceAuthorizer: AppTestPresenceAuthorizer()
    )

    model.request(.reboot)
    await model.confirm()
    #expect(model.errorMessage?.contains("did not accept") == true)

    model.request(.reboot)
    await model.confirm()
    let calls = await power.recordedCalls()
    #expect(calls.count == 2)
    #expect(calls[0].1 == calls[1].1)
    #expect(model.acceptedAction == .reboot)
}

@MainActor
@Test func definitivePowerRejectionUsesANewIdempotencyKey() async {
    let power = AppShellTestFakePower(failures: [.rejected])
    let model = SparkPowerControlModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: power,
        userPresenceAuthorizer: AppTestPresenceAuthorizer()
    )

    model.request(.shutdown)
    await model.confirm()
    #expect(model.errorMessage?.contains("Only the owner") == true)

    model.request(.shutdown)
    await model.confirm()
    let calls = await power.recordedCalls()
    #expect(calls.count == 2)
    #expect(calls[0].1 != calls[1].1)
}

@MainActor
@Test func remoteModelProjectsStatusOntoTheCard() async {
    let model = RemoteAccessModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: AppShellTestFakeRemote(
            status: RemoteStatus(
                enabled: true,
                mode: .privateOverlay,
                health: .healthy,
                hostname: "a7f2.spark.example"
            )
        )
    )
    await model.refresh()

    #expect(model.cardState?.enabled == true)
    #expect(model.cardState?.mode == .privateOverlay)
    #expect(model.cardState?.hostname == "a7f2.spark.example")
    #expect(!model.showsEnableUnavailableNotice, "already enabled")

    let offModel = RemoteAccessModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: AppShellTestFakeRemote(
            status: RemoteStatus(enabled: false, mode: .disabled, health: .disabled)
        ),
        userPresenceAuthorizer: AppTestPresenceAuthorizer()
    )
    #expect(!offModel.showsEnableUnavailableNotice, "unknown status does not offer setup")
    await offModel.refresh()
    #expect(offModel.showsEnableUnavailableNotice, "known-off status explains unavailable setup")
}
