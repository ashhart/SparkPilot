import Foundation
import SparkAPI
import SparkSecurity
import Testing
@testable import SparkAppComposition

private actor PreferencesRemote: RemoteAccessReading {
    var preferences = GeneratedAPI.RemoteOverlayPreferences(
        provider: .tailscale,
        enabled: true,
        acceptDns: false
    )
    var lanUnavailable = false
    var preferenceRoutes: [URL] = []
    var healthChecks = 0
    var changes: [GeneratedAPI.ConfigureRemoteOverlayRequest] = []
    var keys: [UUID] = []
    let fails: Bool
    let unreadable: Bool
    var acknowledgementsToLose: Int
    private var receipts: Set<UUID> = []

    init(fails: Bool = false, unreadable: Bool = false, losesAcknowledgement: Bool = false) {
        self.fails = fails
        self.unreadable = unreadable
        self.acknowledgementsToLose = losesAcknowledgement ? 2 : 0
    }

    func disconnectLAN() { lanUnavailable = true }

    private func requireConnection(_ route: URL) throws {
        if lanUnavailable && route.host == "spark.local" { throw URLError(.cannotConnectToHost) }
    }

    func remoteStatus(route: URL) async throws -> RemoteStatus {
        try requireConnection(route)
        return RemoteStatus(
            enabled: true,
            mode: .privateOverlay,
            health: .healthy,
            hostname: "100.96.4.2"
        )
    }

    func refreshRemoteHealth(route: URL) async throws -> RemoteStatus {
        healthChecks += 1
        return try await remoteStatus(route: route)
    }

    func remoteOverlayPreferences(route: URL) async throws -> GeneratedAPI.RemoteOverlayPreferences
    {
        try requireConnection(route)
        preferenceRoutes.append(route)
        if unreadable { throw URLError(.cannotConnectToHost) }
        return preferences
    }

    func configureRemoteOverlay(
        route: URL,
        body: GeneratedAPI.ConfigureRemoteOverlayRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        try requireConnection(route)
        preferenceRoutes.append(route)
        keys.append(idempotencyKey)
        if receipts.insert(idempotencyKey).inserted {
            changes.append(body)
            if !fails {
                if let enabled = body.enabled { preferences.enabled = enabled }
                if let dns = body.acceptDns { preferences.acceptDns = dns }
            }
        }
        if acknowledgementsToLose > 0 {
            acknowledgementsToLose -= 1
            throw URLError(.networkConnectionLost)
        }
        return try await operation(route: route, id: idempotencyKey)
    }

    func operation(route: URL, id: UUID) async throws -> SparkAPI.Operation {
        try requireConnection(route)
        return try appShellTestDecode(
            "{\"id\":\"\(id)\",\"kind\":\"remote.configure\",\"state\":\"\(fails ? "failed" : "succeeded")\",\"cancellable\":false}"
        )
    }
}

@MainActor
@Suite struct TailscalePreferencesTests {
    private func model(
        _ remote: PreferencesRemote,
        presence: AppTestPresenceAuthorizer = AppTestPresenceAuthorizer()
    ) -> RemoteAccessModel {
        RemoteAccessModel(
            route: URL(string: "https://spark.local:7443")!,
            runtime: remote,
            userPresenceAuthorizer: presence,
            operationDelay: { _ in }
        )
    }

    @Test func unreadPreferencesNeverBecomeAnOffSwitch() async {
        let remote = PreferencesRemote(unreadable: true)
        let model = model(remote)
        await model.refresh()
        #expect(model.overlayPreferences == nil)
        #expect(!model.canConfigureOverlayPreferences)
        await model.setOverlayDNS(true)
        #expect(await remote.changes.isEmpty)
    }

    @Test func dnsUsesFreshPresenceAndChangesOnlyTheSparkDNSPreference() async {
        let remote = PreferencesRemote()
        let presence = AppTestPresenceAuthorizer()
        let model = model(remote, presence: presence)
        await model.refresh()
        await model.setOverlayDNS(true)
        #expect(await remote.changes == [.init(acceptDns: true)])
        #expect(await presence.recordedAuthorizationCount() == 1)
        #expect(model.overlayPreferences?.enabled == true)
        #expect(model.overlayPreferences?.acceptDns == true)
        #expect(model.lastOperation?.state == .succeeded)
        #expect(await remote.healthChecks == 1)
        #expect(model.verifiedPrivateRouteHostname == "100.96.4.2")
    }

    @Test func pausingRequiresConfirmationAndResumingKeepsDNS() async {
        let remote = PreferencesRemote()
        let model = model(remote)
        await model.refresh()
        await model.pauseOverlayVPN(confirmed: false)
        #expect(await remote.changes.isEmpty)
        await model.pauseOverlayVPN(confirmed: true)
        #expect(model.overlayPreferences?.enabled == false)
        await model.resumeOverlayVPN()
        #expect(await remote.changes == [.init(enabled: false), .init(enabled: true)])
        #expect(model.overlayPreferences?.acceptDns == false)
    }

    @Test func aFailedChangeKeepsTheObservedSettingAndExplainsTheFailure() async {
        let remote = PreferencesRemote(fails: true)
        let model = model(remote)
        await model.refresh()
        await model.setOverlayDNS(true)
        #expect(model.overlayPreferences?.acceptDns == false)
        #expect(model.overlayPreferencesError != nil)
        #expect(model.lastOperation?.state == .failed)
        #expect(model.canConfigureOverlayPreferences)
    }

    @Test func losingTheAcknowledgementRetriesOneOperationWithTheSameKey() async {
        let remote = PreferencesRemote(losesAcknowledgement: true)
        let model = model(remote)
        await model.refresh()
        await model.setOverlayDNS(true)
        #expect(model.overlayPreferences == nil)
        #expect(model.canRetryOverlayPreferenceChange)
        #expect(!model.canConfigureOverlayPreferences)
        await model.retryOverlayPreferenceChange()
        let keys = await remote.keys
        #expect(keys.count == 3)
        #expect(Set(keys).count == 1)
        #expect(await remote.changes.count == 1)
        #expect(model.overlayPreferences?.acceptDns == true)
        #expect(model.overlayPreferencesError == nil)
    }

    @Test func preferencesAndChangesFollowTheAuthenticatedTailscaleFallback() async {
        let remote = PreferencesRemote()
        let model = model(remote)
        await model.refresh()
        await remote.disconnectLAN()
        await model.refresh()
        #expect(model.overlayPreferences != nil)
        await model.setOverlayDNS(true)
        #expect(model.overlayPreferences?.acceptDns == true)
        #expect(model.lastOperation?.state == .succeeded)
        #expect(await remote.preferenceRoutes.last?.host == "100.96.4.2")
    }

    @Test func cancelledPresenceDoesNotSendOrLeaveTheControlsLocked() async {
        let remote = PreferencesRemote()
        let model = model(remote, presence: AppTestPresenceAuthorizer(outcome: .decline))
        await model.refresh()
        await model.pauseOverlayVPN(confirmed: true)
        #expect(await remote.changes.isEmpty)
        #expect(model.overlayPreferences?.enabled == true)
        #expect(model.canConfigureOverlayPreferences)
        #expect(!model.canRetryOverlayPreferenceChange)
    }
}
