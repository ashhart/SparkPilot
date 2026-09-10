import Foundation
import SparkAPI
import Testing
@testable import SparkAppComposition

@MainActor
@Suite struct TailscaleHandoffTests {
    @Test func aSuccessfulDNSCheckAlsoRemembersTheTailscaleIP() async {
        let status = RemoteStatus(
            enabled: true,
            mode: .privateOverlay,
            health: .healthy,
            hostname: "family-spark.example.ts.net",
            privateOverlayAddress: "100.96.4.2"
        )
        let proof = AppShellTestTestRemoteRouteRegistration()
        let model = RemoteAccessModel(
            route: URL(string: "https://spark.local:7443")!,
            runtime: AppShellTestFakeRemote(status: status),
            routeRegistration: proof
        )
        await model.refresh()
        #expect(model.isPrivateRouteVerified)
        #expect(proof.registeredHosts == ["family-spark.example.ts.net", "100.96.4.2"])
    }

    @Test func aTailscaleAddressWithoutMagicDNSStillConnects() async {
        let status = RemoteStatus(
            enabled: true,
            mode: .privateOverlay,
            health: .healthy,
            hostname: nil,
            privateOverlayAddress: "100.96.4.2"
        )
        let proof = AppShellTestTestRemoteRouteRegistration()
        let model = RemoteAccessModel(
            route: URL(string: "https://spark.local:7443")!,
            runtime: AppShellTestFakeRemote(status: status),
            routeRegistration: proof
        )
        await model.refresh()
        #expect(proof.registeredHosts == ["100.96.4.2"])
        #expect(model.verifiedPrivateRouteHostname == "100.96.4.2")
    }

    @Test func theInstalledAppOpensWithoutSendingThePersonToTheStore() async {
        var applicationOpens = 0
        var storeOpens = 0
        let handoff = TailscaleAppHandoff(
            canOpenApplication: { true },
            openApplication: {
                applicationOpens += 1
                return true
            },
            openStore: {
                storeOpens += 1
                return true
            }
        )
        #expect(await handoff.open() == .application)
        #expect(applicationOpens == 1)
        #expect(storeOpens == 0)
    }

    @Test(arguments: [true, false])
    func missingOrUnopenableAppsFallBackToTheStore(registered: Bool) async {
        var applicationOpens = 0
        var storeOpens = 0
        let handoff = TailscaleAppHandoff(
            canOpenApplication: { registered },
            openApplication: {
                applicationOpens += 1
                return false
            },
            openStore: {
                storeOpens += 1
                return true
            }
        )
        #expect(await handoff.open() == .appStore)
        #expect(applicationOpens == (registered ? 1 : 0))
        #expect(storeOpens == 1)
    }

    @Test func aBlockedStoreOpenIsAnExplicitFailure() async {
        let handoff = TailscaleAppHandoff(
            canOpenApplication: { false },
            openApplication: { false },
            openStore: { false }
        )
        #expect(await handoff.open() == .unavailable)
    }

    @Test func aProofThatFinishesAfterLeavingTheAppCannotRestoreAConnectedBadge() async {
        let status = RemoteStatus(
            enabled: true,
            mode: .privateOverlay,
            health: .healthy,
            hostname: "100.96.4.2"
        )
        let proof = SuspendedHandoffProof()
        let model = RemoteAccessModel(
            route: URL(string: "https://spark.local:7443")!,
            runtime: AppShellTestFakeRemote(status: status),
            routeRegistration: proof
        )
        let task = Task { await model.refresh() }
        await proof.waitUntilStarted()
        model.invalidatePrivateRouteVerification()
        proof.finish()
        await task.value
        #expect(!model.isPrivateRouteVerified)
    }

    @Test func returningDuringAnEarlierCheckStillVerifiesTheConnectionAgain() async {
        let status = RemoteStatus(
            enabled: true,
            mode: .privateOverlay,
            health: .healthy,
            hostname: "100.96.4.2"
        )
        let proof = SuspendedHandoffProof()
        let model = RemoteAccessModel(
            route: URL(string: "https://spark.local:7443")!,
            runtime: AppShellTestFakeRemote(status: status),
            routeRegistration: proof
        )
        let initial = Task { await model.refresh() }
        await proof.waitUntilStarted()
        model.invalidatePrivateRouteVerification()
        let returned = Task { await model.refreshAfterReturning() }
        await Task.yield()
        proof.finish()
        await initial.value
        await returned.value
        #expect(proof.calls == 2)
        #expect(model.isPrivateRouteVerified)
    }

    @Test func returningAwayFromHomeChecksTheKnownTailscaleRouteWhenLocalDNSIsUnavailable() async {
        let status = RemoteStatus(
            enabled: true,
            mode: .privateOverlay,
            health: .healthy,
            hostname: "100.96.4.2"
        )
        let remote = HandoffRemote(status: status, failure: .offline)
        let proof = AppShellTestTestRemoteRouteRegistration()
        let model = RemoteAccessModel(
            route: URL(string: "https://spark.local:7443")!,
            runtime: remote,
            routeRegistration: proof
        )
        model.status = status
        model.isShowingCachedStatus = true
        await model.refresh()
        #expect(model.isPrivateRouteVerified)
        #expect(!model.isShowingCachedStatus)
        #expect(proof.registeredHosts == ["100.96.4.2"])
        #expect(await remote.hosts == ["spark.local", "100.96.4.2"])
    }

    @Test(arguments: [HandoffRemote.Failure.revoked, .certificate])
    func rejectionOrChangedIdentityDoesNotGetRetriedOnAnotherAddress(
        _ failure: HandoffRemote.Failure
    ) async {
        let status = RemoteStatus(
            enabled: true,
            mode: .privateOverlay,
            health: .healthy,
            hostname: "100.96.4.2"
        )
        let remote = HandoffRemote(status: status, failure: failure)
        let model = RemoteAccessModel(
            route: URL(string: "https://spark.local:7443")!,
            runtime: remote
        )
        model.status = status
        await model.refresh()
        #expect(!model.isPrivateRouteVerified)
        #expect(await remote.hosts == ["spark.local"])
    }

    @Test func anUnreachableSparkNeverBecomesConnectedFromItsCachedStatus() async {
        let status = RemoteStatus(
            enabled: true,
            mode: .privateOverlay,
            health: .healthy,
            hostname: "100.96.4.2"
        )
        let remote = HandoffRemote(status: status, failure: .everywhere)
        let model = RemoteAccessModel(
            route: URL(string: "https://spark.local:7443")!,
            runtime: remote
        )
        model.status = status
        await model.refresh()
        #expect(!model.isPrivateRouteVerified)
        #expect(model.isShowingCachedStatus)
    }
}

@MainActor
private final class SuspendedHandoffProof: RemoteAccessRouteRegistering {
    private var started = false
    private(set) var calls = 0
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var pending: CheckedContinuation<Void, Never>?
    func registerPrivateOverlay(hostname: String, basedOn currentRoute: URL) async throws {
        calls += 1
        guard calls == 1 else { return }
        started = true
        startWaiter?.resume()
        startWaiter = nil
        await withCheckedContinuation { pending = $0 }
    }
    func waitUntilStarted() async {
        if !started { await withCheckedContinuation { startWaiter = $0 } }
    }
    func finish() {
        pending?.resume()
        pending = nil
    }
    func unregisterPrivateOverlay(currentRoute: URL) {}
}

actor HandoffRemote: RemoteAccessReading {
    enum Failure: Sendable { case offline, everywhere, revoked, certificate }
    let status: RemoteStatus
    let failure: Failure
    private(set) var hosts: [String] = []
    init(status: RemoteStatus, failure: Failure) {
        self.status = status
        self.failure = failure
    }
    func remoteStatus(route: URL) async throws -> RemoteStatus {
        hosts.append(route.host() ?? "")
        if route.host() == "100.96.4.2", failure != .everywhere { return status }
        switch failure {
        case .offline, .everywhere: throw URLError(.cannotFindHost)
        case .revoked: throw APIError(.reported, statusCode: 403, code: "DEVICE_REVOKED")
        case .certificate: throw URLError(.serverCertificateUntrusted)
        }
    }
    func operation(route: URL, id: UUID) async throws -> SparkAPI.Operation {
        throw URLError(.cannotConnectToHost)
    }
}
