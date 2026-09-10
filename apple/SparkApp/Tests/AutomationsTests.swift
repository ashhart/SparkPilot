import Foundation
import SparkAPI
import SparkLibrary
import SparkSecurity
import Testing

@testable import SparkAppComposition

private final class AutomationPresenceSession: UserPresenceProofSigning, @unchecked Sendable {
    let keyInfo = UserPresenceKeyInfo(publicKeySPKI: Data([1]), protection: .softwareTestOnly)

    func proof(for request: UserPresenceCanonicalRequest) async throws -> UserPresenceProof {
        throw UserPresenceProofError.signingFailed
    }
}

private actor AutomationPresenceAuthorizer: UserPresenceAuthorizing {
    private var reasons: [String] = []

    func keyInfo() async throws -> UserPresenceKeyInfo {
        UserPresenceKeyInfo(publicKeySPKI: Data([1]), protection: .softwareTestOnly)
    }

    func authorize(localizedReason: String) async throws -> any UserPresenceProofSigning {
        reasons.append(localizedReason)
        return AutomationPresenceSession()
    }

    func count() -> Int { reasons.count }
}

private func automation(
    id: String = "a1",
    webAccess: Bool = false,
    enabled: Bool = true
) -> GeneratedAPI.Automation {
    GeneratedAPI.Automation(
        id: id,
        name: "Daily brief",
        instructions: "Tell me what happened overnight.",
        schedule: GeneratedAPI.AutomationSchedule(
            preset: .daily,
            expression: "0 7 * * *",
            timezone: "Europe/London"
        ),
        modelId: "a-model",
        profileId: nil,
        webAccess: webAccess,
        delivery: GeneratedAPI.AutomationDelivery(notify: true),
        enabled: enabled,
        nextRunAt: 1_767_596_400,
        lastRunAt: nil,
        lastRunState: .none,
        createdAt: 0,
        updatedAt: 0
    )
}

private func settings(
    policy: GeneratedAPI.WebAccessSettingsPolicy
) -> GeneratedAPI.WebAccessSettings {
    GeneratedAPI.WebAccessSettings(
        policy: policy,
        harnessAccess: false,
        allowDomains: [],
        denyDomains: [],
        searchBackend: .searxng,
        searxngUrl: "http://127.0.0.1:18119",
        braveCredentialId: nil,
        localSearchState: .running,
        limits: GeneratedAPI.WebAccessLimits(
            maxToolCalls: 8,
            maxFetchBytes: 2_097_152,
            maxRunBytes: 8_388_608,
            maxRunSeconds: 120,
            maxRequestSeconds: 20
        ),
        updatedAt: 0
    )
}

private actor AutomationRuntime: SparkAutomationManaging, DeviceManagementProviding {
    var items: [GeneratedAPI.Automation]
    var web: GeneratedAPI.WebAccessSettings
    var failure: APIError?
    var webOperationFailure: String?
    private var needsEnrollment = false
    private(set) var enrollments = 0
    private(set) var policyKeys: [UUID] = []
    private(set) var operationReads = 0
    private(set) var credentialWrites: [GeneratedAPI.AddProviderCredentialRequest] = []
    private(set) var createdWithPresence: [Bool] = []
    private(set) var updatedWithPresence: [Bool] = []
    private(set) var settingsWrites: [GeneratedAPI.WebAccessSettingsRequest] = []
    private(set) var runCalls: [String] = []

    init(
        items: [GeneratedAPI.Automation] = [],
        web: GeneratedAPI.WebAccessSettings = settings(policy: .automationsAndChats),
        failure: APIError? = nil
    ) {
        self.items = items
        self.web = web
        self.failure = failure
    }

    func models(route: URL) async throws -> ModelCatalogue {
        try JSONDecoder().decode(ModelCatalogue.self, from: Data(#"{"items":[]}"#.utf8))
    }
    func providerCredentials(route: URL) async throws -> [GeneratedAPI.ProviderCredential] { [] }
    func addProviderCredential(
        route: URL,
        request: GeneratedAPI.AddProviderCredentialRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> GeneratedAPI.ProviderCredential {
        if let failure { throw failure }
        credentialWrites.append(request)
        return .init(
            id: "brave-test",
            provider: request.provider,
            displayName: request.displayName,
            createdAt: "2026-09-05T00:00:00Z"
        )
    }

    func listAutomations(route: URL) async throws -> GeneratedAPI.AutomationList {
        if let failure { throw failure }
        return GeneratedAPI.AutomationList(items: items, maxAutomations: 32, observedAt: 0)
    }

    func createAutomation(
        route: URL,
        request: GeneratedAPI.AutomationRequest,
        idempotencyKey: UUID,
        userPresence: (any UserPresenceProofSigning)?
    ) async throws -> GeneratedAPI.Automation {
        if let failure { throw failure }
        createdWithPresence.append(userPresence != nil)
        let created = automation(id: "new", webAccess: request.webAccess ?? false)
        items.append(created)
        return created
    }

    func updateAutomation(
        route: URL,
        id: String,
        request: GeneratedAPI.AutomationUpdateRequest,
        idempotencyKey: UUID,
        userPresence: (any UserPresenceProofSigning)?
    ) async throws -> GeneratedAPI.Automation {
        if let failure { throw failure }
        updatedWithPresence.append(userPresence != nil)
        return automation(
            id: id,
            webAccess: request.webAccess ?? false,
            enabled: request.enabled ?? true
        )
    }

    func deleteAutomation(
        route: URL,
        id: String,
        idempotencyKey: UUID
    ) async throws -> GeneratedAPI.AutomationList {
        if let failure { throw failure }
        items.removeAll { $0.id == id }
        return GeneratedAPI.AutomationList(items: items, maxAutomations: 32, observedAt: 0)
    }

    func runAutomation(route: URL, id: String, idempotencyKey: UUID) async throws
        -> SparkAPI
        .Operation
    {
        if let failure { throw failure }
        runCalls.append(id)
        return SparkAPI.Operation(
            id: UUID(),
            kind: "automation.run",
            state: .queued,
            cancellable: true
        )
    }

    func listAutomationRuns(route: URL, id: String) async throws -> GeneratedAPI.AutomationRunList {
        GeneratedAPI.AutomationRunList(items: [], observedAt: 0)
    }

    func getWebAccessSettings(route: URL) async throws -> GeneratedAPI.WebAccessSettings { web }

    func setWebAccessSettings(
        route: URL,
        request: GeneratedAPI.WebAccessSettingsRequest,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> SparkAPI.Operation {
        policyKeys.append(idempotencyKey)
        if needsEnrollment { throw APIError(.reported, code: "USER_PRESENCE_NOT_REGISTERED") }
        if let failure { throw failure }
        settingsWrites.append(request)
        return SparkAPI.Operation(
            id: UUID(),
            kind: "settings.web_access",
            state: .queued,
            cancellable: false
        )
    }

    func operation(route: URL, id: UUID) async throws -> SparkAPI.Operation {
        operationReads += 1
        return SparkAPI.Operation(
            id: id,
            kind: "settings.web_access",
            state: webOperationFailure == nil ? .succeeded : .failed,
            errorCode: webOperationFailure,
            cancellable: false
        )
    }

    func failWebOperation(_ code: String) { webOperationFailure = code }
    func requireEnrollment() { needsEnrollment = true }
    func devices(route: URL) async throws -> [GeneratedAPI.Device] { [] }
    func revokeDevice(
        route: URL,
        deviceID: String,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws { throw APIError(.reported, code: "ROLE_FORBIDDEN") }
    func enrollPresenceKey(
        route: URL,
        idempotencyKey: UUID,
        userPresence: any UserPresenceProofSigning
    ) async throws -> String {
        enrollments += 1
        needsEnrollment = false
        return "test-enrollment"
    }

    func presenceCounts() -> (created: [Bool], updated: [Bool]) {
        (createdWithPresence, updatedWithPresence)
    }

    func writes() -> [GeneratedAPI.WebAccessSettingsRequest] { settingsWrites }
    func runs() -> [String] { runCalls }
}

private let route = URL(string: "https://spark.invalid")!

@Test @MainActor func automationSelectionUsesTheChosenSparkAndRefusesWrongTargetOrRole()
    async throws
{
    let library = try #require(FleetSampleFleet.library(["--spark-sample-fleet=2"]))
    let ids = library.entries.map(\.id)
    var requested: [String] = []
    var returnedID = ids[1]
    var role = "administrator"
    var offline = false
    let selection = SparkAutomationSelection(library: library) { id in
        requested.append(id)
        if offline { throw URLError(.notConnectedToInternet) }
        return SparkAutomationsModel(
            route: route,
            targetID: returnedID,
            runtime: AutomationRuntime(),
            localDeviceRole: role
        )
    }
    await selection.open(ids[1], create: true)
    #expect(requested == [ids[1]])
    #expect(selection.destinationID == ids[1])
    #expect(selection.model?.targetID == ids[1])
    await selection.open(ids[0], create: true)
    #expect(selection.destinationID == nil)
    #expect(selection.model == nil)
    #expect(selection.errorMessage != nil)
    returnedID = ids[0]
    role = "user"
    await selection.open(ids[0], create: true)
    #expect(selection.destinationID == nil)
    #expect(selection.errorMessage?.contains("administrator") == true)
    await selection.open(ids[0], create: false)
    #expect(selection.destinationID == ids[0])
    #expect(selection.model?.canManage == false)
    offline = true
    await selection.open(ids[1], create: false)
    #expect(selection.destinationID == nil)
    #expect(selection.model == nil)
    #expect(selection.errorMessage != nil)
}

@Test @MainActor func cancelledAutomationSelectionCannotOpenAfterThePickerCloses() async throws {
    let library = try #require(FleetSampleFleet.library(["--spark-sample-fleet=1"]))
    let id = try #require(library.entries.first?.id)
    var finish: CheckedContinuation<Void, Never>?
    let selection = SparkAutomationSelection(library: library) { target in
        await withCheckedContinuation { finish = $0 }
        return SparkAutomationsModel(
            route: route,
            targetID: target,
            runtime: AutomationRuntime(),
            localDeviceRole: "owner"
        )
    }
    let opening = Task { await selection.open(id, create: true) }
    while finish == nil { await Task.yield() }
    selection.cancel()
    finish?.resume()
    await opening.value
    #expect(selection.destinationID == nil)
    #expect(selection.model == nil)
    #expect(selection.openingID == nil)
}

@MainActor
private func model(
    runtime: AutomationRuntime,
    authorizer: AutomationPresenceAuthorizer,
    role: String? = "owner"
) -> SparkAutomationsModel {
    SparkAutomationsModel(
        route: route,
        targetID: "t1",
        runtime: runtime,
        localDeviceRole: role,
        userPresenceAuthorizer: authorizer
    )
}

// MARK: - The form

@Test func anAutomationNeedsANameInstructionsAndAModelBeforeItCanBeSaved() {
    var draft = SparkAutomationDraft()
    #expect(!draft.canSave)
    draft.name = "Daily brief"
    #expect(!draft.canSave)
    draft.instructions = "Tell me what happened overnight."
    #expect(!draft.canSave)
    draft.modelID = "a-model"
    #expect(draft.canSave)
    #expect(draft.blocker == nil)
}

@Test func everyPresetComposesTheFiveFieldExpressionTheSparkStores() {
    var draft = SparkAutomationDraft()
    draft.hour = 7
    draft.minute = 0
    #expect(draft.expression == "0 7 * * *")
    draft.repeats = .weekdays
    #expect(draft.expression == "0 7 * * 1-5")
    draft.repeats = .weekly
    draft.weekday = 1
    #expect(draft.expression == "0 7 * * 1")
    draft.repeats = .everyNHours
    draft.everyHours = 6
    draft.minute = 30
    #expect(draft.expression == "30 */6 * * *")
}

@Test func aTypedScheduleThatIsNotFiveFieldsIsRefusedBeforeItReachesTheSpark() {
    var draft = SparkAutomationDraft()
    draft.name = "Watch the news"
    draft.instructions = "Check the headlines."
    draft.modelID = "a-model"
    draft.repeats = .custom
    for bad in ["", "0 7 * *", "every morning", "0 7 * * * *", "0 7 * * mon"] {
        draft.customExpression = bad
        #expect(!draft.canSave, "\(bad) was accepted")
    }
    draft.customExpression = "0 7,19 * * 1-5"
    #expect(draft.canSave)
}

@Test func editingAnAutomationRecoversWhatTheOwnerChose() {
    let draft = SparkAutomationDraft.editing(automation(webAccess: true))
    #expect(draft.name == "Daily brief")
    #expect(draft.repeats == .daily)
    #expect(draft.hour == 7)
    #expect(draft.minute == 0)
    #expect(draft.timezone == "Europe/London")
    #expect(draft.webAccess)
}

// MARK: - The model

@MainActor
@Test func turningWebAccessOnAsksForAFreshPresenceProofAndTurningItOffDoesNot() async {
    let runtime = AutomationRuntime()
    let authorizer = AutomationPresenceAuthorizer()
    let model = model(runtime: runtime, authorizer: authorizer)
    await model.load()

    var draft = SparkAutomationDraft()
    draft.name = "Daily brief"
    draft.instructions = "Tell me what happened overnight."
    draft.modelID = "a-model"
    #expect(await model.create(draft))
    #expect(await runtime.presenceCounts().created == [false])
    #expect(await authorizer.count() == 0)

    draft.webAccess = true
    #expect(await model.create(draft))
    #expect(await runtime.presenceCounts().created == [false, true])
    #expect(await authorizer.count() == 1)
}

@MainActor
@Test func pausingAnAutomationNeedsNoPresenceProof() async {
    let runtime = AutomationRuntime(items: [automation()])
    let authorizer = AutomationPresenceAuthorizer()
    let model = model(runtime: runtime, authorizer: authorizer)
    await model.load()
    #expect(await model.setEnabled("a1", to: false))
    #expect(await authorizer.count() == 0)
}

@MainActor
@Test func onlyTheOwnerChangesWhatTheSparkMayReadOnTheInternet() async {
    let runtime = AutomationRuntime()
    let authorizer = AutomationPresenceAuthorizer()
    let administrator = model(runtime: runtime, authorizer: authorizer, role: "administrator")
    await administrator.load()
    #expect(
        !(await administrator.setWebAccess(
            policy: .automationsAndChats,
            harnessAccess: true,
            backend: .searxng
        ))
    )
    #expect(await runtime.writes().isEmpty)

    let owner = model(runtime: runtime, authorizer: authorizer)
    await owner.load()
    #expect(
        await owner.setWebAccess(
            policy: .automations,
            harnessAccess: false,
            backend: .searxng
        )
    )
    #expect(await runtime.writes().count == 1)
    #expect(await runtime.writes()[0].policy == .automations)
    #expect(await runtime.writes()[0].harnessAccess == false)
    #expect(await authorizer.count() == 1)
}

@MainActor
@Test func theSummaryTellsTheOwnerWhatThisSparkAllows() async {
    for (policy, fragment) in [
        (GeneratedAPI.WebAccessSettingsPolicy.off, "does not let"),
        (.automations, "Chats may not"),
        (.automationsAndChats, "Automations and conversations"),
    ] {
        let runtime = AutomationRuntime(web: settings(policy: policy))
        let model = model(runtime: runtime, authorizer: AutomationPresenceAuthorizer())
        await model.load()
        #expect(model.webAccessSummary.contains(fragment), "\(policy) reads wrong")
    }
}

@MainActor
@Test func aRefusedChangeSaysWhatToDoRatherThanEchoingTheRuntime() async {
    let runtime = AutomationRuntime(
        failure: APIError(.reported, statusCode: 403, code: "ROLE_FORBIDDEN")
    )
    let model = model(runtime: runtime, authorizer: AutomationPresenceAuthorizer())
    await model.load()
    #expect(model.errorMessage == "This device is not allowed to change automations.")
    #expect(!(model.errorMessage ?? "").contains("ROLE_FORBIDDEN"))
}

@MainActor
@Test func runNowGoesThroughTheSparkAndNotTheDevice() async {
    let runtime = AutomationRuntime(items: [automation()])
    let model = model(runtime: runtime, authorizer: AutomationPresenceAuthorizer())
    await model.load()
    #expect(await model.runNow("a1"))
    #expect(await runtime.runs() == ["a1"])
}

@MainActor
@Test func searchSetupWaitsForTheDurableFailureAndKeepsTheOldPolicy() async {
    let runtime = AutomationRuntime(web: settings(policy: .off))
    let owner = model(runtime: runtime, authorizer: AutomationPresenceAuthorizer())
    await owner.load()
    await runtime.failWebOperation("WEB_SEARCH_UNAVAILABLE")
    let saved = await owner.setWebAccess(
        policy: .automationsAndChats,
        harnessAccess: false,
        backend: .searxng
    )
    #expect(!saved)
    #expect(await runtime.operationReads == 1)
    #expect(owner.webAccess?.policy == .off)
    #expect(owner.errorMessage?.contains("Repair search") == true)
    #expect(!owner.isChanging)
}

@MainActor
@Test func firstWebSetupEnrollsTheConfirmationKeyAndRetriesTheSameChange() async {
    let runtime = AutomationRuntime(web: settings(policy: .off))
    let authorizer = AutomationPresenceAuthorizer()
    let owner = model(runtime: runtime, authorizer: authorizer)
    await owner.load()
    await runtime.requireEnrollment()
    #expect(
        await owner.setWebAccess(
            policy: .automationsAndChats,
            harnessAccess: false,
            backend: .searxng
        )
    )
    #expect(await runtime.enrollments == 1)
    #expect(await runtime.writes().count == 1)
    let keys = await runtime.policyKeys
    #expect(keys.count == 2)
    #expect(Set(keys).count == 1)
    #expect(await authorizer.count() == 3)
}

@MainActor
@Test func braveKeyUsesItsProviderAndDoesNotEnterThePolicyPayload() async {
    let runtime = AutomationRuntime()
    let authorizer = AutomationPresenceAuthorizer()
    let owner = model(runtime: runtime, authorizer: authorizer)
    let id = await owner.addSearchCredential(
        name: "Family search",
        secret: " synthetic-search-key "
    )
    #expect(id == "brave-test")
    #expect(owner.searchCredentials.first?.displayName == "Family search")
    #expect(await authorizer.count() == 1)
    let writes = await runtime.credentialWrites
    #expect(writes.first?.provider == "brave-search")
    #expect(writes.first?.secret == "synthetic-search-key")
    #expect(await runtime.writes().isEmpty)
}

@MainActor
@Test func aFailedSearchKeySaveKeepsTheListUnchangedAndDoesNotEchoTheKey() async {
    let runtime = AutomationRuntime(failure: APIError(.reported, code: "CREDENTIAL_WRITE_FAILED"))
    let owner = model(runtime: runtime, authorizer: AutomationPresenceAuthorizer())
    #expect(
        await owner.addSearchCredential(name: "Family search", secret: "synthetic-private-value")
            == nil
    )
    #expect(owner.searchCredentials.isEmpty)
    #expect(owner.errorMessage != nil)
    #expect(owner.errorMessage?.contains("synthetic-private-value") == false)
}

private func webCall(
    outcome: GeneratedAPI.AutomationToolCallOutcome,
    code: String?
) -> GeneratedAPI.AutomationToolCall {
    GeneratedAPI.AutomationToolCall(
        index: 0,
        tool: .webFetch,
        url: "https://example.com/a",
        outcome: outcome,
        errorCode: code,
        resultBytes: 0,
        durationMs: 12
    )
}

@Test func aRefusedFetchIsNotShownAsThoughTheSiteWasNeverContacted() throws {
    // BH-40: deciding whether a page may be read is itself an outbound GET to that host.
    #expect(SparkAutomationCopy.robotsNote.contains("still contacted"))
    let refused = try #require(
        SparkAutomationCopy.outcome(of: webCall(outcome: .refused, code: "WEB_FETCH_ROBOTS_DENIED"))
    )
    #expect(refused.hasPrefix("Refused"))
    let failed = try #require(
        SparkAutomationCopy.outcome(of: webCall(outcome: .failed, code: "WEB_SEARCH_UNAVAILABLE"))
    )
    #expect(
        failed.contains("Refused") == false,
        "a call that was allowed and then failed was labelled a refusal"
    )
    #expect(SparkAutomationCopy.outcome(of: webCall(outcome: .succeeded, code: nil)) == nil)
}
