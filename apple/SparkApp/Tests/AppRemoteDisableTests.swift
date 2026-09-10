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

/// Unsuccessful remote-status reads must remain unknown rather than claiming remote access is disabled.
@MainActor
@Test func anUnreadableSparkReportsNoRemoteAccessStateAtAll() async {
    let remote = AppShellTestFakeRemote(
        status: RemoteStatus(enabled: true, mode: .privateOverlay, health: .healthy),
        statusIsUnreadable: true
    )
    let model = RemoteAccessModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: remote,
        userPresenceAuthorizer: AppTestPresenceAuthorizer(),
        operationDelay: { _ in }
    )

    await model.refresh()

    #expect(model.status == nil)
    #expect(!model.isRefreshing)
    #expect(
        model.cardState == nil,
        "an unreachable Spark was reported as having remote access disabled"
    )
    #expect(model.errorMessage != nil, "the failure is still surfaced")
}

@MainActor
@Test func requestedRemoteDisableIsPolledToTerminalWithoutDuplicateSubmission() async {
    let remote = AppShellTestFakeRemote(
        status: RemoteStatus(enabled: true, mode: .privateOverlay, health: .healthy),
        operationStates: [.requested, .running, .succeeded]
    )
    let model = RemoteAccessModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: remote,
        userPresenceAuthorizer: AppTestPresenceAuthorizer(),
        operationDelay: { _ in }
    )
    await model.refresh()

    await model.prepareDisable()
    await model.confirmDisable()

    #expect(await remote.recordedDisableKeys().count == 1)
    #expect(await remote.recordedOperationReadCount() == 2)
    #expect(model.lastOperation?.state == .succeeded)
    #expect(model.cardState?.enabled == false)
    #expect(model.errorMessage == nil)
}

@MainActor
@Test func remoteDisablePollingIsBoundedAndKeepsTheKeyForAnHonestRetry() async {
    let remote = AppShellTestFakeRemote(
        status: RemoteStatus(enabled: true, mode: .privateOverlay, health: .healthy),
        operationStates: [.requested, .running, .running]
    )
    let model = RemoteAccessModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: remote,
        userPresenceAuthorizer: AppTestPresenceAuthorizer(),
        maximumOperationPolls: 2,
        operationDelay: { _ in }
    )
    await model.refresh()

    await model.prepareDisable()
    await model.confirmDisable()

    #expect(await remote.recordedOperationReadCount() == 2)
    #expect(model.errorMessage?.contains("still turning off") == true)
    #expect(model.cardState?.enabled == true)

    await model.prepareDisable()
    await model.confirmDisable()

    let keys = await remote.recordedDisableKeys()
    #expect(keys.count == 2)
    #expect(keys[0] == keys[1])
    #expect(model.cardState?.enabled == false)
}

@MainActor
@Test func declinedPresenceSendsNoRemoteDisableRequest() async {
    let remote = AppShellTestFakeRemote(
        status: RemoteStatus(enabled: true, mode: .privateOverlay, health: .healthy)
    )
    let model = RemoteAccessModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: remote,
        userPresenceAuthorizer: AppTestPresenceAuthorizer(outcome: .decline)
    )
    await model.refresh()
    await model.prepareDisable()
    await model.confirmDisable()

    #expect(await remote.recordedDisableKeys().isEmpty)
    #expect(model.errorMessage?.contains("could not confirm you are present") == true)
    #expect(model.cardState?.enabled == true)
}

@MainActor
@Test func ambiguousRemoteDisableRetryReusesItsIdempotencyKey() async {
    let remote = AppShellTestFakeRemote(
        status: RemoteStatus(enabled: true, mode: .privateOverlay, health: .healthy),
        failures: [.network]
    )
    let model = RemoteAccessModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: remote,
        userPresenceAuthorizer: AppTestPresenceAuthorizer()
    )
    await model.refresh()

    await model.prepareDisable()
    await model.confirmDisable()
    #expect(model.errorMessage?.contains("Check the connection") == true)

    await model.prepareDisable()
    await model.confirmDisable()
    let keys = await remote.recordedDisableKeys()
    #expect(keys.count == 2)
    #expect(keys[0] == keys[1])
    #expect(model.lastOperation?.state == .succeeded)
}

@MainActor
@Test func remoteDisableRendersOptimisticallyAndRollsBackAfterNetworkFailure() async {
    let remote = AppShellTestFakeRemote(
        status: RemoteStatus(enabled: true, mode: .privateOverlay, health: .healthy),
        failures: [.network],
        suspendsDisable: true
    )
    let model = RemoteAccessModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: remote,
        userPresenceAuthorizer: AppTestPresenceAuthorizer()
    )
    await model.refresh()
    await model.prepareDisable()

    let disableTask = Task { await model.confirmDisable() }
    await remote.waitForDisableSubmission()

    #expect(model.isOptimisticallyDisabled)
    #expect(model.cardState?.enabled == false)

    await remote.resumeDisable()
    await disableTask.value

    #expect(!model.isOptimisticallyDisabled)
    #expect(model.cardState?.enabled == true)
    #expect(model.errorMessage?.contains("Check the connection") == true)
}

@MainActor
@Test func definitiveRemoteDisableRejectionClearsItsIdempotencyKey() async {
    let remote = AppShellTestFakeRemote(
        status: RemoteStatus(enabled: true, mode: .privateOverlay, health: .healthy),
        failures: [.rejected]
    )
    let model = RemoteAccessModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: remote,
        userPresenceAuthorizer: AppTestPresenceAuthorizer()
    )
    await model.refresh()

    await model.prepareDisable()
    await model.confirmDisable()
    #expect(model.errorMessage?.contains("Only an owner device") == true)

    await model.prepareDisable()
    await model.confirmDisable()
    let keys = await remote.recordedDisableKeys()
    #expect(keys.count == 2)
    #expect(keys[0] != keys[1])
}

@MainActor
@Test func legacyRemoteGrantEnrollsPresenceAndRetriesWithFreshProof() async {
    let remote = AppShellTestFakeRemote(
        status: RemoteStatus(enabled: true, mode: .privateOverlay, health: .healthy),
        failures: [.presenceNotRegistered]
    )
    let presence = AppTestPresenceAuthorizer()
    let model = RemoteAccessModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: remote,
        userPresenceAuthorizer: presence
    )
    await model.refresh()

    await model.prepareDisable()
    await model.confirmDisable()

    #expect(await presence.recordedAuthorizationCount() == 3)
    #expect(await remote.recordedEnrollmentKeys().count == 1)
    let disableKeys = await remote.recordedDisableKeys()
    #expect(disableKeys.count == 2)
    #expect(disableKeys[0] == disableKeys[1])
    #expect(model.lastOperation?.state == .succeeded)
    #expect(model.errorMessage == nil)
}
