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
@Test func remoteDisableNeedsConfirmationAndCanBeCancelled() async {
    let remote = AppShellTestFakeRemote(
        status: RemoteStatus(enabled: true, mode: .privateOverlay, health: .healthy)
    )
    let presence = AppTestPresenceAuthorizer()
    let model = RemoteAccessModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: remote,
        userPresenceAuthorizer: presence
    )
    await model.refresh()

    await model.prepareDisable()
    #expect(model.isConfirmingDisable)
    #expect(await presence.recordedAuthorizationCount() == 0)
    #expect(await remote.recordedDisableKeys().isEmpty)

    model.cancelDisableConfirmation()
    #expect(!model.isConfirmingDisable)
    #expect(await presence.recordedAuthorizationCount() == 0)
    #expect(await remote.recordedDisableKeys().isEmpty)
}

@MainActor
@Test func existingTailscaleRouteRequiresReviewAndPresenceBeforeEnablement() async {
    let remote = AppShellTestFakeRemote(
        status: RemoteStatus(
            enabled: false,
            mode: .disabled,
            health: .disabled,
            availableModes: [.privateOverlay],
            privateOverlayProvider: "tailscale"
        )
    )
    let presence = AppTestPresenceAuthorizer()
    let routeRegistration = AppShellTestTestRemoteRouteRegistration()
    let model = RemoteAccessModel(
        route: URL(string: "https://tailscale-enable.spark.test:7443")!,
        runtime: remote,
        routeRegistration: routeRegistration,
        userPresenceAuthorizer: presence
    )
    await model.refresh()

    #expect(model.canEnablePrivateOverlay)
    await model.preparePrivateOverlayEnable()
    #expect(model.isConfirmingEnable)
    #expect(await presence.recordedAuthorizationCount() == 0)
    #expect(await remote.recordedEnableKeys().isEmpty)

    await model.confirmEnable()

    #expect(await presence.recordedAuthorizationCount() == 1)
    #expect(await remote.recordedEnableKeys().count == 1)
    #expect(model.cardState?.enabled == true)
    #expect(model.cardState?.mode == .privateOverlay)
    #expect(model.cardState?.hostname == "100.96.4.2")
    #expect(routeRegistration.registeredHosts == ["100.96.4.2"])
    #expect(model.errorMessage == nil)
}

@MainActor
@Test func anUnauthenticatedOverlayIsNeverReportedAsReadyOnThisAppleDevice() async {
    let remote = AppShellTestFakeRemote(
        status: RemoteStatus(
            enabled: false,
            mode: .disabled,
            health: .disabled,
            availableModes: [.privateOverlay],
            privateOverlayProvider: "tailscale"
        )
    )
    let routeRegistration = AppShellTestTestRemoteRouteRegistration()
    routeRegistration.registrationError = AppShellTestFakeRemoteUnreachable()
    let model = RemoteAccessModel(
        route: URL(string: "https://local.spark.test:7443")!,
        runtime: remote,
        routeRegistration: routeRegistration,
        userPresenceAuthorizer: AppTestPresenceAuthorizer()
    )
    await model.refresh()
    await model.preparePrivateOverlayEnable()

    await model.confirmEnable()

    #expect(routeRegistration.registeredHosts.isEmpty)
    #expect(model.cardState?.enabled == true, "the Spark's durable setting still changed")
    #expect(!model.isPrivateRouteVerified)
    #expect(model.verifiedPrivateRouteHostname == nil)
    #expect(model.errorMessage != nil)
}

@MainActor
@Test func recheckRepairsADegradedOverlayWhenTheRouteRecovers() async {
    let remote = AppShellTestFakeRemote(
        status: RemoteStatus(
            enabled: true,
            mode: .privateOverlay,
            health: .degraded,
            hostname: "100.96.4.2",
            availableModes: [.privateOverlay],
            privateOverlayProvider: "tailscale"
        ),
        // A recheck re-probes: the route is back at a reassigned address.
        refreshedStatus: RemoteStatus(
            enabled: true,
            mode: .privateOverlay,
            health: .healthy,
            hostname: "100.100.7.9",
            availableModes: [.privateOverlay],
            privateOverlayProvider: "tailscale"
        )
    )
    let model = RemoteAccessModel(
        route: URL(string: "https://degraded.spark.test:7443")!,
        runtime: remote,
        routeRegistration: AppShellTestTestRemoteRouteRegistration(),
        userPresenceAuthorizer: AppTestPresenceAuthorizer()
    )
    await model.refresh()
    #expect(model.isRemoteRouteUnhealthy, "an enabled degraded route offers the recheck")

    await model.recheckRemoteHealth()

    #expect(!model.isRemoteRouteUnhealthy)
    #expect(model.status?.health == .healthy)
    #expect(model.status?.hostname == "100.100.7.9", "the reassigned address is adopted")
}

@MainActor
@Test func failedRemoteRefreshKeepsLastKnownStatusAndMarksItCached() async {
    let remote = AppShellTestFakeRemote(
        status: RemoteStatus(
            enabled: true,
            mode: .privateOverlay,
            health: .healthy,
            hostname: "100.96.4.2",
            availableModes: [.privateOverlay],
            privateOverlayProvider: "tailscale"
        )
    )
    let model = RemoteAccessModel(
        route: URL(string: "https://remote-cache.spark.test:7443")!,
        runtime: remote,
        userPresenceAuthorizer: AppTestPresenceAuthorizer()
    )
    await model.refresh()
    await remote.setStatusUnreadable(true)

    await model.refresh()

    #expect(model.cardState?.enabled == true)
    #expect(model.cardState?.hostname == "100.96.4.2")
    #expect(model.isShowingCachedStatus)
    #expect(model.errorMessage?.contains("last known") == true)
}

@MainActor
@Test func localOnlyStatusNeverOffersAnUnprovenRemoteMode() async {
    let model = RemoteAccessModel(
        route: URL(string: "https://local-only.spark.test:7443")!,
        runtime: AppShellTestFakeRemote(
            status: RemoteStatus(enabled: false, mode: .disabled, health: .disabled)
        ),
        userPresenceAuthorizer: AppTestPresenceAuthorizer()
    )

    await model.refresh()

    #expect(!model.canEnablePrivateOverlay)
    #expect(model.showsEnableUnavailableNotice)
    #expect(model.cardState?.mode == .disabled)
}

@MainActor
@Test func privateRouteVerificationRequiresThisDeviceAndExpiresOnFailedRefresh() async {
    let remote = AppShellTestFakeRemote(
        status: RemoteStatus(
            enabled: true,
            mode: .privateOverlay,
            health: .healthy,
            hostname: "100.96.4.2",
            availableModes: [.privateOverlay],
            privateOverlayProvider: "tailscale"
        )
    )
    let registration = AppShellTestTestRemoteRouteRegistration()
    registration.registrationError = AppShellTestFakeRemoteUnreachable()
    let model = RemoteAccessModel(
        route: URL(string: "https://private-proof-\(UUID().uuidString).spark.test:7443")!,
        runtime: remote,
        routeRegistration: registration,
        userPresenceAuthorizer: AppTestPresenceAuthorizer()
    )
    await model.refresh()
    #expect(model.status?.health == .healthy)
    #expect(!model.isPrivateRouteVerified, "the Spark's own check proves no client route")
    registration.registrationError = nil
    await model.recheckRemoteHealth()
    #expect(model.isPrivateRouteVerified)
    #expect(registration.registeredHosts == ["100.96.4.2"])
    await remote.setStatusUnreadable(true)
    await model.refresh()
    #expect(model.isShowingCachedStatus)
    #expect(!model.isPrivateRouteVerified, "cached health must not display a verified route")
    #expect(model.verifiedPrivateRouteHostname == nil)
}

@MainActor
@Test func cachedOverlayAvailabilityDoesNotEnableConfiguration() async {
    let remote = AppShellTestFakeRemote(
        status: RemoteStatus(
            enabled: false,
            mode: .disabled,
            health: .disabled,
            availableModes: [.privateOverlay],
            privateOverlayProvider: "tailscale"
        )
    )
    let model = RemoteAccessModel(
        route: URL(string: "https://overlay-prerequisite-\(UUID().uuidString).spark.test:7443")!,
        runtime: remote,
        userPresenceAuthorizer: AppTestPresenceAuthorizer()
    )
    await model.refresh()
    #expect(model.canEnablePrivateOverlay)
    await remote.setStatusUnreadable(true)
    await model.refresh()
    #expect(!model.canEnablePrivateOverlay)
    #expect(!model.showsEnableUnavailableNotice, "unknown is not missing Tailscale")
}

@MainActor
@Test func remoteStatusSurvivesAnOfflineRelaunchFromDeviceLocalCache() async {
    let route = URL(string: "https://remote-relaunch-\(UUID().uuidString).spark.test:7443")!
    let live = AppShellTestFakeRemote(
        status: RemoteStatus(
            enabled: true,
            mode: .privateOverlay,
            health: .healthy,
            hostname: "100.96.4.2",
            availableModes: [.privateOverlay],
            privateOverlayProvider: "tailscale"
        )
    )
    let first = RemoteAccessModel(
        route: route,
        runtime: live,
        userPresenceAuthorizer: AppTestPresenceAuthorizer()
    )
    await first.loadIfNeeded()

    let offline = AppShellTestFakeRemote(
        status: RemoteStatus(enabled: false, mode: .disabled, health: .disabled),
        statusIsUnreadable: true
    )
    let relaunched = RemoteAccessModel(
        route: route,
        runtime: offline,
        userPresenceAuthorizer: AppTestPresenceAuthorizer()
    )
    await relaunched.loadIfNeeded()

    #expect(relaunched.cardState?.enabled == true)
    #expect(relaunched.cardState?.hostname == "100.96.4.2")
    #expect(relaunched.isShowingCachedStatus)
}

@MainActor
@Test func confirmedRemoteDisableAuthorizesAndSendsTypedPresence() async {
    let remote = AppShellTestFakeRemote(
        status: RemoteStatus(enabled: true, mode: .privateOverlay, health: .healthy)
    )
    let presence = AppTestPresenceAuthorizer()
    let routeRegistration = AppShellTestTestRemoteRouteRegistration()
    let model = RemoteAccessModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: remote,
        routeRegistration: routeRegistration,
        userPresenceAuthorizer: presence
    )
    await model.refresh()
    await model.prepareDisable()
    await model.confirmDisable()

    #expect(await presence.recordedAuthorizationCount() == 1)
    #expect(await remote.recordedDisableKeys().count == 1)
    #expect(model.lastOperation?.state == .succeeded)
    #expect(model.errorMessage == nil)
    #expect(model.cardState?.enabled == false)
    #expect(routeRegistration.unregisterCount == 1)
}
