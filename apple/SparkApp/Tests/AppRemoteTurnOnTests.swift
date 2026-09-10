import Foundation
import SparkAPI
@testable import SparkAppComposition
import SparkCore
import SparkLibrary
import SparkSecurity
import Testing

/// One tap turns remote access on: the Spark sets Tailscale up, the app shows the sign-in link, then records the route.

private let magicDNSName = "spark-example.tail1234.ts.net"
private let signInLink = "https://login.tailscale.com/a/0123456789abcdef"

private struct TurnOnOperationStep: Sendable {
    let state: SparkAPI.Operation.OperationState
    let stage: String?
    let errorCode: String?
}

/// Scripts the Spark: a review without blockers, an enable that walks the listed stages, and a setup document.
private actor TurnOnFakeRemote: RemoteAccessReading {
    private var status: RemoteStatus
    private var steps: [TurnOnOperationStep]
    private let setupLink: String?
    private let setupState: RemoteOverlaySetupState
    private let blocker: GeneratedAPI.ModelActionPreviewMessage?
    private(set) var enableKeys: [UUID] = []
    private(set) var setupReads = 0
    private(set) var previewCount = 0

    init(
        steps: [TurnOnOperationStep],
        setupLink: String? = signInLink,
        setupState: RemoteOverlaySetupState = .loginRequired,
        blocker: GeneratedAPI.ModelActionPreviewMessage? = nil
    ) {
        self.status = RemoteStatus(enabled: false, mode: .disabled, health: .disabled)
        self.steps = steps
        self.setupLink = setupLink
        self.setupState = setupState
        self.blocker = blocker
    }

    func remoteStatus(route: URL) async throws -> RemoteStatus { status }

    func remoteOverlaySetup(route: URL) async throws -> RemoteOverlaySetup {
        setupReads += 1
        return RemoteOverlaySetup(
            state: setupState,
            authorizationURL: setupLink.flatMap(URL.init(string:))
        )
    }

    func previewRemoteEnable(
        route: URL,
        body: RemotePreviewRequest,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.ModelActionPreview {
        previewCount += 1
        let blockers =
            blocker.map { "[\(String(decoding: try! JSONEncoder().encode($0), as: UTF8.self))]" }
            ?? "[]"
        return appShellTestRemoteAccessPreview(
            action: "remote.enable",
            hostname: nil,
            blockers: blockers
        )
    }

    func enableRemote(
        route: URL,
        body: EnableRemoteRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        enableKeys.append(idempotencyKey)
        return try next()
    }

    func operation(route: URL, id: UUID) async throws -> SparkAPI.Operation {
        try next()
    }

    private func next() throws -> SparkAPI.Operation {
        let step =
            steps.isEmpty
            ? TurnOnOperationStep(state: .succeeded, stage: nil, errorCode: nil)
            : steps.removeFirst()
        if step.state == .succeeded {
            status = RemoteStatus(
                enabled: true,
                mode: .privateOverlay,
                health: .healthy,
                hostname: magicDNSName,
                availableModes: [.privateOverlay],
                privateOverlayProvider: "tailscale",
                privateOverlayAddress: "100.96.4.2"
            )
        }
        let stage = step.stage.map { "\"\($0)\"" } ?? "null"
        let errorCode = step.errorCode.map { "\"\($0)\"" } ?? "null"
        return try appShellTestDecode(
            "{\"id\":\"63e82da2-7fb7-4b4b-9584-4a528000ac94\",\"kind\":\"remote.enable\","
                + "\"state\":\"\(step.state.rawValue)\",\"stage\":\(stage),"
                + "\"error_code\":\(errorCode),\"cancellable\":false}"
        )
    }
}

@MainActor
private func turnOnModel(
    remote: TurnOnFakeRemote,
    registration: AppShellTestTestRemoteRouteRegistration =
        AppShellTestTestRemoteRouteRegistration(),
    presence: AppTestPresenceAuthorizer = AppTestPresenceAuthorizer()
) -> RemoteAccessModel {
    RemoteAccessModel(
        route: URL(string: "https://spark-example.local:7443")!,
        runtime: remote,
        routeRegistration: registration,
        userPresenceAuthorizer: presence,
        maximumSignInPolls: 20,
        operationDelay: { _ in }
    )
}

private let signInThenSuccess = [
    TurnOnOperationStep(state: .running, stage: "preparing_overlay", errorCode: nil),
    TurnOnOperationStep(state: .running, stage: "awaiting_owner_login", errorCode: nil),
    TurnOnOperationStep(state: .running, stage: "awaiting_owner_login", errorCode: nil),
    TurnOnOperationStep(state: .running, stage: "verifying_route", errorCode: nil),
    TurnOnOperationStep(state: .succeeded, stage: "publishing_route", errorCode: nil),
]

@MainActor
@Test func oneTapTurnOnShowsTheSignInLinkWhileWaitingAndRecordsTheTailscaleRoute() async {
    let remote = TurnOnFakeRemote(steps: signInThenSuccess)
    let registration = AppShellTestTestRemoteRouteRegistration()
    let presence = AppTestPresenceAuthorizer()
    let model = turnOnModel(remote: remote, registration: registration, presence: presence)
    await model.refresh()
    #expect(model.canTurnOn)

    var phases: [RemoteAccessTurnOnPhase] = []
    var sawLink = false
    let observer = Task { @MainActor in
        while phases.last != .done,
            !phases.contains(where: { if case .failed = $0 { true } else { false } })
        {
            if phases.last != model.turnOnPhase { phases.append(model.turnOnPhase) }
            if model.signInURL?.absoluteString == signInLink { sawLink = true }
            await Task.yield()
        }
    }
    await model.turnOn()
    _ = await observer.result

    #expect(model.turnOnPhase == .done)
    #expect(phases.contains(.awaitingSignIn), "\(phases)")
    #expect(sawLink, "the sign-in link is offered while the Spark waits for the owner")
    #expect(!model.isConfirmingEnable, "no second confirmation dialog: one tap is the action")
    #expect(await presence.recordedAuthorizationCount() == 1)
    #expect(await remote.enableKeys.count == 1)
    #expect(await remote.setupReads >= 1)
    #expect(model.status?.hostname == magicDNSName)
    #expect(registration.registeredHosts == [magicDNSName, "100.96.4.2"])
    #expect(model.isPrivateRouteVerified)
    #expect(model.signInURL == nil, "the one-time link is not kept after sign-in")
    #expect(model.errorMessage == nil)
}

@MainActor
@Test func aSignInThatTimesOutEndsInATryAgainActionAndKeepsRemoteOff() async {
    let remote = TurnOnFakeRemote(steps: [
        TurnOnOperationStep(state: .running, stage: "awaiting_owner_login", errorCode: nil),
        TurnOnOperationStep(
            state: .failed,
            stage: "awaiting_owner_login",
            errorCode: "PRIVATE_OVERLAY_LOGIN_TIMEOUT"
        ),
    ])
    let model = turnOnModel(remote: remote)
    await model.refresh()

    await model.turnOn()

    guard case .failed(let action) = model.turnOnPhase else {
        Issue.record("expected a next action, got \(model.turnOnPhase)")
        return
    }
    #expect(action.kind == .tryAgain)
    #expect(action.title.localizedCaseInsensitiveContains("expired"))
    #expect(action.message.localizedCaseInsensitiveContains("Local access is unchanged") == false)
    #expect(action.message.localizedCaseInsensitiveContains("waiting to be signed in"))
    #expect(model.status?.enabled == false)
    #expect(model.canTurnOn, "Try Again is possible straight away")

    let first = await remote.enableKeys
    await model.turnOn()
    let second = await remote.enableKeys
    #expect(second.count == 2)
    #expect(first.first != second.last, "a definitive failure retires its idempotency key")
}

@MainActor
@Test func aReviewBlockerEndsInItsRecoveryTextWithoutAskingForPresence() async {
    let remote = TurnOnFakeRemote(
        steps: [],
        blocker: GeneratedAPI.ModelActionPreviewMessage(
            code: "PRIVATE_OVERLAY_UNAVAILABLE",
            ownerExplanation: "Tailscale cannot be set up on this Spark from the app.",
            recoveryAction: "Install Tailscale on the Spark yourself, then try again."
        )
    )
    let presence = AppTestPresenceAuthorizer()
    let model = turnOnModel(remote: remote, presence: presence)
    await model.refresh()

    await model.turnOn()

    guard case .failed(let action) = model.turnOnPhase else {
        Issue.record("expected a next action, got \(model.turnOnPhase)")
        return
    }
    #expect(action.message.contains("Install Tailscale on the Spark yourself"))
    #expect(await presence.recordedAuthorizationCount() == 0)
    #expect(await remote.enableKeys.isEmpty)
}

@MainActor
@Test func whenThisDeviceIsNotOnTheTailnetTurnOnSucceedsAndSaysToOpenTailscaleHere() async {
    let remote = TurnOnFakeRemote(steps: signInThenSuccess)
    let registration = AppShellTestTestRemoteRouteRegistration()
    registration.registrationError = AppShellTestFakeRemoteUnreachable()
    let model = turnOnModel(remote: remote, registration: registration)
    await model.refresh()

    await model.turnOn()

    guard case .failed(let action) = model.turnOnPhase else {
        Issue.record("expected a next action, got \(model.turnOnPhase)")
        return
    }
    #expect(action.kind == .openTailscaleOnThisDevice)
    #expect(
        model.status?.enabled == true,
        "the Spark's setting changed; only this device is not on the tailnet yet"
    )
    #expect(action.message.localizedCaseInsensitiveContains("Tailscale app on this device"))
}

@MainActor
@Test func aForgedSignInLinkIsNeverOffered() async {
    let remote = TurnOnFakeRemote(
        steps: signInThenSuccess,
        setupLink: "https://login.tailscale.com.evil.example/a/0123"
    )
    let model = turnOnModel(remote: remote)
    await model.refresh()
    var offered: URL?
    let observer = Task { @MainActor in
        while model.turnOnPhase != .done,
            !{ if case .failed = model.turnOnPhase { return true } else { return false } }()
        {
            if let url = model.signInURL { offered = url }
            await Task.yield()
        }
    }
    await model.turnOn()
    _ = await observer.result
    #expect(offered == nil)
}

@Test func theExplanationSaysWhatTailscaleIsHowSecureItIsAndWhatYouNeedInPlainWords() {
    let text = RemoteAccessExplanation.sections.flatMap { [$0.title] + $0.points }.joined(
        separator: "\n"
    )
    for expectation in [
        "private network", "WireGuard", "encrypted end to end",
        "Your Tailscale access rules",
        "No port on your router", "checks the Spark's own certificate", "signs every request",
        "A Tailscale account", "Tailscale app on this iPhone, iPad or Mac", "sign the Spark in",
        "keeps it running", ".ts.net", "7443/v1", "not the .local name",
        "leaves your home", "relay", "cannot read", "may relay encrypted traffic",
    ] {
        #expect(text.contains(expectation), "missing: \(expectation)")
    }
    #expect(
        RemoteAccessExplanation.sections.map(\.title) == [
            "What Tailscale is", "What it does for your Spark", "How secure it is",
            "What leaves your home", "What you need", "What changes",
        ]
    )
    for term in ["WireGuard", "Tailnet", "Tailscale name"] {
        #expect(
            RemoteAccessExplanation.glossary.contains { $0.term == term },
            "\(term) needs a gloss"
        )
    }
    for jargon in ["CGNAT", "overlay", "JWT", "envelope", "SPKI", "idempotency"] {
        #expect(!text.localizedCaseInsensitiveContains(jargon), "\(jargon) is jargon")
    }
    #expect(RemoteAccessExplanation.oneTapSummary.contains("install its app on this device"))
    #expect(RemoteAccessExplanation.oneTapSummary.contains("check the private connection"))
    #expect(RemoteAccessExplanation.signInInstructions.contains("ten minutes"))
}

@MainActor
@Test func everyNextActionNamesWhatHappenedAndWhatToDo() {
    for code in [
        "PRIVATE_OVERLAY_LOGIN_TIMEOUT", "PRIVATE_OVERLAY_SETUP_FAILED",
        "PRIVATE_OVERLAY_ROUTE_UNVERIFIED", "OPERATION_CANCELLED", "SOMETHING_NEW",
    ] {
        let action = RemoteAccessModel.nextAction(forOperationCode: code)
        #expect(!action.title.isEmpty && !action.message.isEmpty, "\(code)")
        #expect(!action.title.contains("_"), "\(code): a raw code leaked into the title")
    }
    #expect(
        RemoteAccessModel.nextAction(forOperationCode: "PRIVATE_OVERLAY_ROUTE_UNVERIFIED").kind
            == .checkAgain
    )
    let forbidden = RemoteAccessModel.nextAction(
        for: APIError(.local(message: "owner only"), statusCode: 403, code: "ROLE_FORBIDDEN")
    )
    #expect(forbidden.kind == .none)
    #expect(forbidden.title.localizedCaseInsensitiveContains("owner"))
}

@MainActor
@Test func aFailedEnableSaysWhatTheSparkReportsIsStillRunning() async {
    // BH-29: prepare() installs Tailscale and starts tailscaled before the sign-in it waits for.
    let remote = TurnOnFakeRemote(
        steps: [
            TurnOnOperationStep(state: .running, stage: "awaiting_owner_login", errorCode: nil),
            TurnOnOperationStep(
                state: .failed,
                stage: "awaiting_owner_login",
                errorCode: "PRIVATE_OVERLAY_SETUP_FAILED"
            ),
        ],
        setupState: .loginRequired
    )
    let model = turnOnModel(remote: remote)
    await model.refresh()
    await model.turnOn()

    guard case .failed(let action) = model.turnOnPhase else {
        Issue.record("expected a next action, got \(model.turnOnPhase)")
        return
    }
    #expect(
        action.message.localizedCaseInsensitiveContains("Local access is unchanged") == false,
        "the app asserted nothing changed while tailscaled was left enabled and running"
    )
    #expect(action.message.contains("waiting to be signed in"))
    #expect(action.message.contains("sudo tailscale logout"), "no plain way to undo what remains")
}

@MainActor
@Test func aFailureOnASparkWithNoTailscaleSaysNothingWasLeftBehind() {
    let clean = RemoteAccessModel.nextAction(
        forOperationCode: "PRIVATE_OVERLAY_SETUP_FAILED",
        overlay: RemoteOverlaySetup(state: .notInstalled)
    )
    #expect(clean.message.contains("left nothing behind"))
    #expect(clean.message.contains("sudo tailscale logout") == false)
    let unread = RemoteAccessModel.nextAction(forOperationCode: "PRIVATE_OVERLAY_SETUP_FAILED")
    #expect(
        unread.message.contains("could not read what Tailscale is doing"),
        "an unread state must not be reported as a clean rollback"
    )
    let joined = RemoteAccessModel.nextAction(
        forOperationCode: "OPERATION_CANCELLED",
        overlay: RemoteOverlaySetup(state: .ready)
    )
    #expect(joined.message.contains("Nothing changed") == false)
    #expect(joined.message.contains("is on your tailnet"))
}

@MainActor
@Test func theProductionTailscaleClockCompletesTheSignedOperation() async {
    let remote = TurnOnFakeRemote(steps: [
        TurnOnOperationStep(state: .running, stage: "awaiting_owner_login", errorCode: nil),
        TurnOnOperationStep(state: .succeeded, stage: "publishing_route", errorCode: nil),
    ])
    let model = RemoteAccessModel(
        route: URL(string: "https://clock-fixture.local:7443")!,
        runtime: remote,
        routeRegistration: AppShellTestTestRemoteRouteRegistration(),
        userPresenceAuthorizer: AppTestPresenceAuthorizer()
    )
    await model.refresh()
    await model.turnOn()
    #expect(model.turnOnPhase == .done)
    #expect(model.isPrivateRouteVerified)
}
