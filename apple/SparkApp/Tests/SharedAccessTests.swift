import Foundation
import SparkAPI
import SparkBootstrap
import SparkSecurity
import Testing

@testable import SparkAppComposition

private let ownerNodeID = "ca890ed7-7c8c-4b2c-9218-b77ef24f569a"
private let authorityKey = String(repeating: "c", count: 64)
private let authorityFingerprint =
    "c2f480d4dda9f4522b9f6d590011636d904accfe59f12f9d66a0221c2558e3a2"

private func sharedTrust(role: String = "owner") -> NodeTrust {
    NodeTrust(
        nodeID: ownerNodeID,
        nodeName: "Alex's Spark",
        tlsFingerprint: String(repeating: "a", count: 64),
        authorityFingerprint: authorityFingerprint,
        authorityPublicKey: authorityKey,
        pairedAt: Date(timeIntervalSince1970: 1_780_000_000),
        localDeviceRole: role
    )
}

private func evenings() -> SharedAccessLimitsDraft {
    SharedAccessLimitsDraft(
        guestName: "Sam",
        allowedModels: ["qwen3-8b"],
        startMinute: 1_080,
        endMinute: 1_320,
        weekdaysOnly: false,
        timeZone: "Europe/London",
        maxConcurrentRequests: 1,
        dailyTokenBudget: 20_000
    )
}

private func schedule(_ days: [GeneratedAPI.GuestDaySchedule]) -> GeneratedAPI.GuestSchedule {
    GeneratedAPI.GuestSchedule(days: days)
}

private func usage(
    requests: Int = 0,
    refusals: Int = 0,
    prompt: Int = 0,
    completion: Int = 0
) -> GeneratedAPI.GuestUsage {
    GeneratedAPI.GuestUsage(
        requests: requests,
        refusals: refusals,
        promptTokens: prompt,
        completionTokens: completion,
        totalTokens: prompt + completion
    )
}

private func guestRecord(
    state: GeneratedAPI.SharedAccessState = .active,
    models: [String] = ["qwen3-8b"],
    used: Int = 0,
    budget: Int = 20_000,
    hours: [GeneratedAPI.GuestDaySchedule]? = nil
) -> GeneratedAPI.SharedAccessSelf {
    GeneratedAPI.SharedAccessSelf(
        displayName: "Sam",
        state: state,
        allowedModels: models,
        allowedHours: schedule(hours ?? evenings().schedule),
        timeZone: "Europe/London",
        maxConcurrentRequests: 1,
        dailyTokenBudget: budget,
        expiresAt: nil,
        today: usage(requests: 3, prompt: used, completion: 0),
        budgetResetsAt: 1_782_950_400
    )
}

private func ownerGuest(
    state: GeneratedAPI.SharedAccessState = .pending,
    deviceID: String? = "b1b2b3b4-0000-4000-8000-000000000001",
    refusals: [String: Int] = [:]
) -> GeneratedAPI.SharedAccessGuest {
    GeneratedAPI.SharedAccessGuest(
        invitationId: "f2d1c0b9-a897-4655-8443-2211ffeeddcc",
        deviceId: deviceID,
        displayName: "Sam",
        state: state,
        allowedModels: ["qwen3-8b"],
        allowedHours: schedule(evenings().schedule),
        timeZone: "Europe/London",
        maxConcurrentRequests: 1,
        dailyTokenBudget: 20_000,
        expiresAt: nil,
        joinedAt: "2026-07-01T10:00:00Z",
        confirmedAt: nil,
        revokedAt: nil,
        lastSeenAt: "2026-07-01T18:00:00Z",
        today: usage(requests: 4, prompt: 300, completion: 200),
        thisWeek: usage(requests: 20, refusals: 3, prompt: 1_000, completion: 900),
        refusalsThisWeek: refusals
    )
}

private final class SharedAccessPresenceSession: UserPresenceProofSigning, @unchecked Sendable {
    let keyInfo: UserPresenceKeyInfo
    private let signer = SoftwareSigner()

    init() {
        keyInfo = UserPresenceKeyInfo(
            publicKeySPKI: signer.publicKeySPKI,
            protection: .softwareTestOnly
        )
    }

    func proof(for request: UserPresenceCanonicalRequest) async throws -> UserPresenceProof {
        try UserPresenceProof.sign(request) { try signer.sign($0) }
    }
}

private actor SharedAccessAuthorizer: UserPresenceAuthorizing {
    private let signer = SoftwareSigner()
    private(set) var reasons: [String] = []

    func keyInfo() async throws -> UserPresenceKeyInfo {
        UserPresenceKeyInfo(publicKeySPKI: signer.publicKeySPKI, protection: .softwareTestOnly)
    }

    func authorize(localizedReason: String) async throws -> any UserPresenceProofSigning {
        reasons.append(localizedReason)
        return SharedAccessPresenceSession()
    }
}

private final class FakeSharedAccess: SharedAccessProviding, OwnSharedAccessProviding,
    @unchecked Sendable
{
    var overview = GeneratedAPI.SharedAccessOverview(guests: [])
    var own: GeneratedAPI.SharedAccessSelf?
    var ownFailure: (any Error)?
    var issued: GeneratedAPI.SharedAccessInvitation?
    var createFailure: (any Error)?
    private(set) var updates: [(String, GeneratedAPI.UpdateSharedAccess)] = []
    private(set) var revocations: [String] = []
    private(set) var presenceCount = 0

    func sharedAccess(route: URL) async throws -> GeneratedAPI.SharedAccessOverview { overview }

    func ownSharedAccess(route: URL) async throws -> GeneratedAPI.SharedAccessSelf {
        if let ownFailure { throw ownFailure }
        guard let own else { throw APIError(.malformedResponse, statusCode: 404) }
        return own
    }

    func createSharedAccessInvitation(
        route: URL,
        limits: GeneratedAPI.CreateSharedAccessInvitation,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> GeneratedAPI.SharedAccessInvitation {
        presenceCount += 1
        if let createFailure { throw createFailure }
        guard let issued else { throw APIError(.malformedResponse, statusCode: 500) }
        return issued
    }

    func updateSharedAccess(
        route: URL,
        deviceID: String,
        change: GeneratedAPI.UpdateSharedAccess,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> GeneratedAPI.SharedAccessGuest {
        presenceCount += 1
        updates.append((deviceID, change))
        return ownerGuest(state: .active)
    }

    func revokeSharedAccess(
        route: URL,
        deviceID: String,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> GeneratedAPI.SharedAccessRevocation {
        presenceCount += 1
        revocations.append(deviceID)
        return GeneratedAPI.SharedAccessRevocation(
            deviceId: deviceID,
            state: .revoked,
            revokedAt: "2026-07-01T19:00:00Z"
        )
    }
}

@Test func theLimitsFormRefusesWhatTheSparkWouldRefuse() {
    #expect(evenings().isReady)

    var noModels = evenings()
    noModels.allowedModels = []
    #expect(noModels.problem?.contains("at least one model") == true)

    var noName = evenings()
    noName.guestName = "   "
    #expect(noName.problem != nil)

    var backwards = evenings()
    backwards.startMinute = 1_320
    backwards.endMinute = 1_080
    #expect(backwards.problem != nil)

    var noBudget = evenings()
    noBudget.dailyTokenBudget = 0
    #expect(noBudget.problem != nil)

    var tooMany = evenings()
    tooMany.maxConcurrentRequests = 9
    #expect(tooMany.problem != nil)

    var unknownZone = evenings()
    unknownZone.timeZone = "Middle/Earth"
    #expect(unknownZone.problem != nil)
}

@Test func theFormBuildsTheSevenDayScheduleTheRuntimeStores() {
    let everyDay = evenings().schedule
    #expect(everyDay.count == 7)
    #expect(everyDay.allSatisfy { $0.windows.count == 1 })
    #expect(everyDay.first?.windows.first?.startMinute == 1_080)

    var weekdays = evenings()
    weekdays.weekdaysOnly = true
    let openDays = weekdays.schedule.filter { !$0.windows.isEmpty }
    #expect(openDays.count == 5)
    #expect(openDays.allSatisfy { $0.weekday < 5 })
}

@Test func editingStartsFromTheLimitsTheSparkAlreadyHolds() {
    let row = SharedAccessGuestRow(guest: ownerGuest(state: .active))
    let draft = row.draft
    #expect(draft.guestName == "Sam")
    #expect(draft.allowedModels == ["qwen3-8b"])
    #expect(draft.startMinute == 1_080)
    #expect(draft.endMinute == 1_320)
    #expect(draft.dailyTokenBudget == 20_000)
    #expect(draft.isReady)
}

@MainActor
@Test func theShareMessageTellsTheFriendWhatToInstallAndThatTheOwnerConfirms() throws {
    let invitation = PairingInvitation(
        version: 2,
        nodeID: ownerNodeID,
        authorityFingerprint: authorityFingerprint,
        invitationID: "63e82da2-7fb7-4b4b-9584-4a528000ac94",
        nonce: "bm9uY2U",
        role: "guest",
        expiresAt: "2099-01-01T00:00:00Z",
        signature: "c2lnbmF0dXJl",
        nodeName: "Alex's Spark",
        tlsFingerprint: String(repeating: "a", count: 64),
        remoteHostname: "spark-example.tail1234.ts.net",
        sharedAccess: SharedAccessSummary(
            displayName: "Sam",
            allowedModels: ["qwen3-8b"],
            allowedHours: SharedAccessSummary.allHours(),
            timeZone: "Europe/London",
            maxConcurrentRequests: 1,
            dailyTokenBudget: 20_000
        )
    )
    let package = AdditionalDevicePairingPackage(
        nodeName: "Alex's Spark",
        tlsFingerprint: String(repeating: "a", count: 64),
        authorityPublicKey: authorityKey,
        invitation: invitation
    )
    let share = SharedAccessShare(
        link: try package.qrPayload(),
        nodeName: "Alex's Spark",
        guestName: "Sam",
        expiresAt: nil,
        reachableRemotely: true
    )

    #expect(share.message.contains("SparkPilot"))
    #expect(share.message.contains("Tailscale"))
    #expect(share.message.contains(share.link))
    #expect(share.message.contains("confirm"))
    #expect(share.subject.contains("Alex's Spark"))
    #expect(!share.message.lowercased().contains("password"))
    #expect(!share.message.lowercased().contains("token"))
}

@MainActor
@Test func aGuestSeesChatItsOwnUsageAndNothingElse() {
    let experience = GuestExperience(record: guestRecord(used: 400))
    #expect(experience.canChat)
    #expect(experience.unavailableReason == nil)
    #expect(experience.remainingToday == 19_600)
    #expect(!experience.showsOwnerControls)
    #expect(!experience.showsDeviceList)
    #expect(!experience.showsDashboard)
    #expect(!experience.showsAutomations)
    #expect(experience.allowedModels == ["qwen3-8b"])
}

@MainActor
@Test func theGuestIsToldWhatIsLimitedAndWhy() {
    let waiting = GuestExperience(record: guestRecord(state: .pending))
    #expect(!waiting.canChat)
    #expect(waiting.unavailableReason?.contains("hasn't confirmed") == true)

    let paused = GuestExperience(record: guestRecord(state: .paused))
    #expect(paused.unavailableReason?.contains("paused") == true)

    let stopped = GuestExperience(record: guestRecord(state: .revoked))
    #expect(stopped.unavailableReason?.contains("stopped sharing") == true)

    let noModels = GuestExperience(record: guestRecord(models: []))
    #expect(noModels.unavailableReason?.contains("any models") == true)

    let spent = GuestExperience(record: guestRecord(used: 20_000))
    #expect(spent.unavailableReason?.contains("today's share") == true)

    let closed = GuestExperience(
        record: guestRecord(hours: (0..<7).map { .init(weekday: $0, windows: []) })
    )
    #expect(!closed.hasOpenHours)
    #expect(closed.unavailableReason?.contains("hours") == true)
}

@MainActor
@Test func aDeviceThatIsNotAGuestKeepsTheWholeApp() async {
    let runtime = FakeSharedAccess()
    runtime.ownFailure = APIError(.malformedResponse, statusCode: 403, code: "ROLE_FORBIDDEN")
    let model = GuestExperienceModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime
    )
    await model.load()
    #expect(!model.isGuest)
    #expect(model.experience == nil)
    #expect(model.errorMessage == nil)
}

@MainActor
@Test func theOwnerConfirmsPausesAndStopsSharingWithPresenceEachTime() async {
    let runtime = FakeSharedAccess()
    runtime.overview = GeneratedAPI.SharedAccessOverview(guests: [ownerGuest()])
    let authorizer = SharedAccessAuthorizer()
    let model = SharedAccessModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        userPresenceAuthorizer: authorizer
    )
    await model.refresh()
    let row = try! #require(model.rows.first)
    #expect(model.pendingCount == 1)
    #expect(row.state == .pending)

    await model.confirm(row)
    #expect(runtime.updates.first?.1.state == .active)

    await model.pause(row)
    #expect(runtime.updates.last?.1.state == .paused)

    model.revocationConfirmation = row
    await model.revoke(row)
    #expect(runtime.revocations == [row.id])
    #expect(model.revocationConfirmation == nil, "the confirmation closes when it is acted on")
    #expect(runtime.presenceCount == 3, "every change carries a fresh presence proof")
    #expect(await authorizer.reasons.count == 3)
}

@MainActor
@Test func editingLimitsSendsThemWithoutChangingTheLifecycle() async {
    let runtime = FakeSharedAccess()
    runtime.overview = GeneratedAPI.SharedAccessOverview(guests: [ownerGuest(state: .active)])
    let model = SharedAccessModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        userPresenceAuthorizer: SharedAccessAuthorizer()
    )
    await model.refresh()
    let row = try! #require(model.rows.first)

    var draft = row.draft
    draft.dailyTokenBudget = 5_000
    draft.allowedModels = ["qwen3-8b", "gemma3-12b"]
    await model.applyLimits(draft, to: row)

    let sent = try! #require(runtime.updates.last?.1)
    #expect(sent.state == nil, "an edit is not a state change")
    #expect(sent.limits?.dailyTokenBudget == 5_000)
    #expect(sent.limits?.allowedModels.count == 2)
}

@MainActor
@Test func anInvalidEditNeverReachesTheSpark() async {
    let runtime = FakeSharedAccess()
    runtime.overview = GeneratedAPI.SharedAccessOverview(guests: [ownerGuest(state: .active)])
    let model = SharedAccessModel(
        route: URL(string: "https://spark.local:7443")!,
        runtime: runtime,
        userPresenceAuthorizer: SharedAccessAuthorizer()
    )
    await model.refresh()
    let row = try! #require(model.rows.first)

    var draft = row.draft
    draft.allowedModels = []
    await model.applyLimits(draft, to: row)
    #expect(runtime.updates.isEmpty)
    #expect(model.errorMessage?.contains("at least one model") == true)
}

@MainActor
@Test func theOwnerRowSummarisesUsageAndTheReasonsForRefusals() {
    let row = SharedAccessGuestRow(
        guest: ownerGuest(
            state: .active,
            refusals: ["GUEST_OUTSIDE_HOURS": 5, "GUEST_MODEL_NOT_ALLOWED": 2]
        )
    )
    #expect(row.usedToday == 500)
    #expect(row.usedThisWeek == 1_900)
    #expect(row.refusalsThisWeek == 3)
    #expect(row.topRefusals.first?.reason == "GUEST_OUTSIDE_HOURS")
    #expect(SharedAccessRefusal.label("GUEST_OUTSIDE_HOURS").contains("outside the hours"))
    #expect(SharedAccessRefusal.label("GUEST_BUDGET_EXHAUSTED").contains("daily budget"))
    #expect(row.hoursLabel.isEmpty == false)
}

@MainActor
@Test func anInvitationForAnotherSparkIsNeverTurnedIntoALink() {
    let issued = GeneratedAPI.SharedAccessInvitation(
        invitation: GeneratedAPI.PairingInvitation(
            version: 2,
            nodeId: "11111111-2222-3333-4444-555555555555",
            authorityFingerprint: authorityFingerprint,
            invitationId: "63e82da2-7fb7-4b4b-9584-4a528000ac94",
            nonce: "bm9uY2U",
            role: .guest,
            expiresAt: "2099-01-01T00:00:00Z",
            signature: "c2lnbmF0dXJl",
            additionalProperties: [:]
        ),
        nodeName: "Someone else's Spark",
        tlsFingerprint: String(repeating: "a", count: 64),
        authorityPublicKey: authorityKey
    )
    #expect(throws: SharedAccessInvitationError.self) {
        _ = try SharedAccessInvitationModel.share(
            from: issued,
            trust: sharedTrust(),
            guestName: "Sam"
        )
    }
}

private func joinPackage(remoteHostname: String? = "spark-example.tail1234.ts.net")
    -> AdditionalDevicePairingPackage
{
    AdditionalDevicePairingPackage(
        nodeName: "Alex's Spark",
        tlsFingerprint: String(repeating: "a", count: 64),
        authorityPublicKey: authorityKey,
        invitation: PairingInvitation(
            version: 2,
            nodeID: ownerNodeID,
            authorityFingerprint: authorityFingerprint,
            invitationID: "63e82da2-7fb7-4b4b-9584-4a528000ac94",
            nonce: "bm9uY2U",
            role: "guest",
            expiresAt: "2099-01-01T00:00:00Z",
            signature: "c2lnbmF0dXJl",
            localEndpoint: "https://alex-s-Spark-8cd8b1ab.local:7443",
            remoteEndpoint: remoteHostname.map { "https://\($0):7443" },
            nodeName: "Alex's Spark",
            tlsFingerprint: String(repeating: "a", count: 64),
            remoteHostname: remoteHostname,
            sharedAccess: nil
        ),
        localHint: "https://192.168.100.63:7443"
    )
}

@Test func joiningTriesTheLocalRouteThenTheTailnetOne() {
    let routes = SharedAccessJoin.candidateRoutes(for: joinPackage())
    #expect(routes.first?.kind == .local)
    #expect(routes.first?.url.absoluteString == "https://alex-s-Spark-8cd8b1ab.local:7443")
    #expect(routes.contains { $0.kind == .tailnet })
    #expect(
        routes.last?.url.absoluteString == "https://192.168.100.63:7443",
        "the unsigned local hint is tried last"
    )
    #expect(routes.allSatisfy { $0.url.scheme == "https" })
}

@Test func aJoinWithNoTailnetNameSaysToJoinTheOwnersWiFi() {
    let package = joinPackage(remoteHostname: nil)
    let routes = SharedAccessJoin.candidateRoutes(for: package)
    #expect(routes.allSatisfy { $0.kind == .local })
    #expect(SharedAccessJoin.preparationAdvice(for: package).contains("Wi-Fi"))
    #expect(SharedAccessJoin.unreachableMessage(tried: routes).contains("Tailscale"))
}

@Test func anUnreachableJoinNamesThePathThatFailed() {
    let both = SharedAccessJoin.candidateRoutes(for: joinPackage())
    let message = SharedAccessJoin.unreachableMessage(tried: both)
    #expect(message.contains("your network"))
    #expect(message.contains("Tailscale"))
    #expect(SharedAccessJoin.unreachableMessage(tried: []).contains("no address"))

    let tailnetOnly = both.filter { $0.kind == .tailnet }
    #expect(SharedAccessJoin.unreachableMessage(tried: tailnetOnly).contains("over Tailscale"))
}

@Test func aRefusalIsNotMistakenForAnUnreachableSpark() {
    #expect(SharedAccessJoin.reachabilityFailure(URLError(.cannotConnectToHost)))
    #expect(SharedAccessJoin.reachabilityFailure(nil))
    #expect(
        !SharedAccessJoin.reachabilityFailure(
            APIError(.malformedResponse, statusCode: 409, code: "INVITATION_ALREADY_USED")
        )
    )
}

@Test func aGuestRefusalNamesTheLimitRatherThanBlamingTheDevice() {
    for code in [
        "GUEST_MODEL_NOT_ALLOWED",
        "GUEST_OUTSIDE_HOURS",
        "GUEST_BUDGET_EXHAUSTED",
        "GUEST_CONCURRENCY_LIMIT",
        "GUEST_AWAITING_OWNER",
        "GUEST_ACCESS_PAUSED",
        "GUEST_ACCESS_REVOKED",
        "GUEST_ACCESS_EXPIRED",
        "GUEST_SCHEDULE_UNAVAILABLE",
        "GUEST_PARAMETER_NOT_ALLOWED",
    ] {
        let failure = SparkChatFailure.resolve(
            APIError(.malformedResponse, statusCode: 403, code: code)
        )
        #expect(failure.title == "Shared access limit", "\(code)")
        #expect(!failure.message.contains("Pair this device again"), "\(code)")
        #expect(!failure.message.isEmpty, "\(code)")
    }

    let ordinary = SparkChatFailure.resolve(
        APIError(.malformedResponse, statusCode: 403, code: "ROLE_FORBIDDEN")
    )
    #expect(ordinary.title != "Shared access limit")
}

@Test func theInviteFooterSaysTheGuestSeesTheNameTheOwnerTyped() {
    // BH-34: display_name is signed into the invitation and returned on the guest's own route.
    let footer = SharedAccessInviteCopy.guestNameFooter
    #expect(footer.contains("Only you can see this name") == false)
    #expect(footer.contains("Your guest sees this name"))
    let guest = GuestExperience(record: guestRecord())
    #expect(guest.guestName == "Sam", "the guest's own app shows the owner's label back to them")
}
