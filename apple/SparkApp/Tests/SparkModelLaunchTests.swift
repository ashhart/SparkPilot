import Foundation
import SparkAPI
import SparkCore
import Testing
@testable import SparkAppComposition

private func launchTarget(model: String = "nemotron") -> SparkChatTarget {
    SparkChatTarget(
        id: "desk",
        displayName: "Desk Spark",
        nodeID: SparkNodeID(rawValue: UUID(uuidString: "63e82da2-7fb7-4b4b-9584-4a528000ac94")!),
        route: URL(string: "https://spark.example:8443")!,
        tlsFingerprint: String(repeating: "a", count: 64),
        authorityFingerprint: String(repeating: "b", count: 64),
        modelID: model,
        modelName: model == "nemotron" ? "Nemotron" : "Other model",
        contextLength: 65_536
    )
}

private actor LaunchChatRecorder: SparkChatStreaming {
    var requests: [ChatCompletionRequest] = []
    func stream(target: SparkChatTarget, request: ChatCompletionRequest) async throws
        -> AsyncThrowingStream<ChatStreamEvent, any Error>
    {
        requests.append(request)
        return AsyncThrowingStream { continuation in
            continuation.yield(.chunk(id: nil, model: nil, delta: "Ready", finishReason: "stop"))
            continuation.finish()
        }
    }
}

@MainActor
private final class LaunchRecorder: SparkModelLaunching {
    var replace = false
    var fails = false
    var hold = false
    var holdPreparation = false
    var alreadyReady = false
    var started = false
    var applyCount = 0
    var prepareCount = 0
    var selectedProfile: String?
    var continuation: CheckedContinuation<Void, Never>?
    func profiles(for target: SparkChatTarget) async throws -> [SparkModelProfile] {
        try JSONDecoder().decode(
            [SparkModelProfile].self,
            from: Data(
                #"[{"id":"agent","display_name":"Agent 64K","max_model_length":65536,"max_sequences":8,"expected_peak_bytes":1000000,"safe":true},{"id":"long","display_name":"Long context","max_model_length":131072,"max_sequences":4,"expected_peak_bytes":2000000,"safe":true}]"#
                    .utf8
            )
        )
    }
    func prepare(target: SparkChatTarget, profileID: String?) async throws -> SparkModelLaunchPlan {
        prepareCount += 1
        if holdPreparation { await withCheckedContinuation { continuation = $0 } }
        selectedProfile = profileID
        if alreadyReady { return SparkModelLaunchPlan(target: target, alreadyReady: true) }
        var preview = try lifecyclePreview(action: replace ? "replace" : "load")
        if replace { preview.consequences.modelToStop = "other" }
        return SparkModelLaunchPlan(
            target: target,
            confirmation: ModelActionConfirmation(
                idempotencyKey: UUID(),
                modelID: target.modelID,
                lifecycleAction: .load,
                retryRequest: ModelOperationRetryRequest(
                    profileID: profileID ?? "agent",
                    replaceActive: replace
                ),
                preview: preview
            )
        )
    }
    func apply(_ plan: SparkModelLaunchPlan) async throws -> SparkChatTarget {
        applyCount += 1
        started = true
        if hold { await withCheckedContinuation { continuation = $0 } }
        if fails { throw SparkModelLaunchError(message: "The preview changed; review again.") }
        return plan.target
    }
    func finish() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private func waitForLaunch(_ condition: () -> Bool) async throws {
    for _ in 0..<1000 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Model launch did not reach the expected state")
}

@Suite("Model launch and chat handoff")
struct SparkModelLaunchTests {
    @Test @MainActor func aBriefModelCheckDoesNotFlashAStatusAndAStoppedCheckStaysHidden()
        async throws
    {
        let launcher = LaunchRecorder()
        launcher.holdPreparation = true
        launcher.alreadyReady = true
        let model = SparkChatModel(
            catalogue: SparkChatTargetCatalogue(targets: [launchTarget()], pairedTargetCount: 1),
            streamer: LaunchChatRecorder(),
            modelLauncher: launcher
        )
        model.draft = "Hi"
        let task = try #require(model.send())
        try await waitForLaunch { launcher.prepareCount == 1 }
        #expect(model.isPreparingModel)
        #expect(model.modelLaunchState.message == nil)
        #expect(model.send() == nil)
        model.cancelModelLaunch()
        launcher.finish()
        await task.value
        try await Task.sleep(for: .milliseconds(450))
        #expect(model.modelLaunchState == .idle)
        #expect(model.modelLaunchState.message == nil)
        #expect(model.draft == "Hi")
    }

    @Test @MainActor func aSlowModelCheckRemainsVisibleAndSendsOnlyOnce() async throws {
        let launcher = LaunchRecorder()
        launcher.holdPreparation = true
        launcher.alreadyReady = true
        let recorder = LaunchChatRecorder()
        let model = SparkChatModel(
            catalogue: SparkChatTargetCatalogue(targets: [launchTarget()], pairedTargetCount: 1),
            streamer: recorder,
            modelLauncher: launcher
        )
        model.draft = "Hi"
        let task = try #require(model.send())
        try await waitForLaunch { model.modelLaunchState == .checking }
        #expect(model.modelLaunchState.message != nil)
        #expect(await recorder.requests.isEmpty)
        launcher.finish()
        await task.value
        #expect(model.modelLaunchState == .idle)
        #expect(await recorder.requests.count == 1)
    }

    @Test @MainActor func idleModelLoadsBeforeSendingAndRepeatedSendDoesNotDuplicate() async throws
    {
        let launcher = LaunchRecorder()
        launcher.hold = true
        let recorder = LaunchChatRecorder()
        let model = SparkChatModel(
            catalogue: SparkChatTargetCatalogue(
                targets: [],
                pairedTargetCount: 1,
                installedTargets: [launchTarget()]
            ),
            streamer: recorder,
            modelLauncher: launcher
        )
        model.draft = "Explain this document"
        await model.importSharedFiles([
            SparkSharedFile(name: "notes.txt", data: Data("Remember this".utf8))
        ])
        #expect(model.canSend)
        let task = try #require(model.send())
        try await waitForLaunch { launcher.started }
        #expect(model.modelLaunchState == .loading)
        #expect(await recorder.requests.isEmpty)
        #expect(model.messages.isEmpty)
        #expect(model.draft == "Explain this document")
        #expect(model.pendingAttachments.count == 1)
        #expect(model.send() == nil)
        launcher.finish()
        await task.value
        #expect(launcher.applyCount == 1)
        #expect(await recorder.requests.count == 1)
        #expect(await recorder.requests.first?.model == "nemotron")
        let sent = chatTestSpoken(try #require(await recorder.requests.first))
        #expect(sent.first?.content.contains("Remember this") == true)
        #expect(model.draft.isEmpty)
        #expect(model.pendingAttachments.isEmpty)
    }

    @Test @MainActor func replacingAnotherModelRequiresApprovalAndKeepsTheSelectedModel()
        async throws
    {
        let launcher = LaunchRecorder()
        launcher.replace = true
        let recorder = LaunchChatRecorder()
        let model = SparkChatModel(
            catalogue: SparkChatTargetCatalogue(
                targets: [launchTarget(model: "other")],
                pairedTargetCount: 1,
                installedTargets: [launchTarget()]
            ),
            streamer: recorder,
            modelLauncher: launcher
        )
        model.selectTarget(launchTarget())
        model.draft = "Use Nemotron"
        await model.send()?.value
        #expect(model.modelLaunchState == .awaitingApproval)
        #expect(model.pendingModelLaunch?.confirmation?.preview.consequences.modelToStop == "other")
        #expect(launcher.applyCount == 0)
        #expect(await recorder.requests.isEmpty)
        await model.confirmModelLaunch()?.value
        #expect(launcher.applyCount == 1)
        #expect(await recorder.requests.first?.model == "nemotron")
        #expect(model.selectedModelID == "nemotron")
    }

    @Test @MainActor func cancellingReplacementKeepsTheDraftAndDoesNotUnload() async {
        let launcher = LaunchRecorder()
        launcher.replace = true
        let recorder = LaunchChatRecorder()
        let model = SparkChatModel(
            catalogue: SparkChatTargetCatalogue(
                targets: [],
                pairedTargetCount: 1,
                installedTargets: [launchTarget()]
            ),
            streamer: recorder,
            modelLauncher: launcher
        )
        model.draft = "Keep my message"
        await model.send()?.value
        model.cancelModelLaunch()
        #expect(model.draft == "Keep my message")
        #expect(model.pendingModelLaunch == nil)
        #expect(launcher.applyCount == 0)
        #expect(await recorder.requests.isEmpty)
    }

    @Test @MainActor func stalePreviewOrLoadFailureNeverSendsOrLosesTheDraft() async {
        let launcher = LaunchRecorder()
        launcher.fails = true
        let recorder = LaunchChatRecorder()
        let model = SparkChatModel(
            catalogue: SparkChatTargetCatalogue(
                targets: [],
                pairedTargetCount: 1,
                installedTargets: [launchTarget()]
            ),
            streamer: recorder,
            modelLauncher: launcher
        )
        model.draft = "Keep this"
        await model.send()?.value
        #expect(model.modelLaunchError != nil)
        #expect(model.draft == "Keep this")
        #expect(model.messages.isEmpty)
        #expect(await recorder.requests.isEmpty)
        #expect(model.canSend)
    }

    @Test @MainActor func switchingModelWhileLoadingCannotSendAnOldPromptToTheNewModel()
        async throws
    {
        let launcher = LaunchRecorder()
        launcher.hold = true
        let recorder = LaunchChatRecorder()
        let model = SparkChatModel(
            catalogue: SparkChatTargetCatalogue(
                targets: [],
                pairedTargetCount: 1,
                installedTargets: [launchTarget(), launchTarget(model: "other")]
            ),
            streamer: recorder,
            modelLauncher: launcher
        )
        model.draft = "Only for Nemotron"
        let task = try #require(model.send())
        try await waitForLaunch { launcher.started }
        model.selectTarget(launchTarget(model: "other"))
        launcher.finish()
        await task.value
        #expect(await recorder.requests.isEmpty)
        #expect(model.messages.isEmpty)
        #expect(model.draft == "Only for Nemotron")
        #expect(model.selectedModelID == "other")
    }

    @Test @MainActor func quickLaunchUsesTheChosenPresetAndWaitsBeforeReplacingAnotherModel()
        async throws
    {
        let launcher = LaunchRecorder()
        launcher.replace = true
        let model = SparkQuickLaunchModel(launcher: launcher) { [launchTarget()] }
        await model.refresh()
        model.selectedProfileID = "long"
        await model.prepare()
        #expect(launcher.selectedProfile == "long")
        #expect(launcher.applyCount == 0)
        #expect(model.pendingPlan != nil)
        let reviewID = model.pendingPlan?.id
        await model.refresh()
        #expect(model.selectedProfileID == "long")
        #expect(model.pendingPlan?.id == reviewID)
        await model.apply()
        #expect(model.ready)
        #expect(launcher.applyCount == 1)
    }

    @Test @MainActor func olderSavedChatResolvesItsModelAfterReconnecting() async {
        let recorder = LaunchChatRecorder()
        let model = SparkChatModel(
            catalogue: SparkChatTargetCatalogue(targets: [], pairedTargetCount: 1),
            streamer: recorder,
            modelLauncher: LaunchRecorder()
        )
        model.preservesTargetWhenUnavailable = true
        model.restore(messages: [], draft: "Saved offline", targetID: "desk", at: Date())
        model.replaceCatalogue(
            SparkChatTargetCatalogue(
                targets: [],
                pairedTargetCount: 1,
                installedTargets: [launchTarget()]
            )
        )
        await model.send()?.value
        #expect(model.selectedModelID == "nemotron")
        #expect(await recorder.requests.count == 1)
        #expect(model.draft.isEmpty)
    }

    @Test @MainActor func unloadingOrReplacingTheEngineDoesNotChangeASavedChatSelection() {
        let launcher = LaunchRecorder()
        let model = SparkChatModel(
            catalogue: SparkChatTargetCatalogue(targets: [launchTarget()], pairedTargetCount: 1),
            streamer: LaunchChatRecorder(),
            modelLauncher: launcher
        )
        model.preservesTargetWhenUnavailable = true
        model.replaceCatalogue(
            SparkChatTargetCatalogue(
                targets: [launchTarget(model: "other")],
                pairedTargetCount: 1,
                installedTargets: [launchTarget()]
            )
        )
        #expect(model.selectedModelID == "nemotron")
        #expect(model.selectedTarget?.modelID == "nemotron")
        #expect(!model.isSelectedModelReady)
    }
}

@MainActor
@Test func withdrawingATargetDuringLoadNeverLeavesTheComposerPreparingForever() async throws {
    let launcher = LaunchRecorder()
    launcher.hold = true
    let recorder = LaunchChatRecorder()
    let model = SparkChatModel(
        catalogue: .init(targets: [], pairedTargetCount: 1, installedTargets: [launchTarget()]),
        streamer: recorder,
        modelLauncher: launcher
    )
    model.draft = "Keep this message"
    let task = try #require(model.send())
    try await waitForLaunch { launcher.started }
    model.replaceCatalogue(.empty)
    launcher.finish()
    await task.value
    #expect(model.modelLaunchState == .idle)
    #expect(model.queuedModelMessage == nil)
    #expect(model.draft == "Keep this message")
    #expect(await recorder.requests.isEmpty)
    model.replaceCatalogue(.init(targets: [launchTarget()], pairedTargetCount: 1))
    #expect(model.canSend)
}

@MainActor
@Test func thinkingBudgetIsRememberedForOnlyTheSelectedSparkAndModel() throws {
    let name = "thinking-budget-" + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    #expect(
        SparkModelDefaults.thinkingBudget(targetID: "one", modelID: "nemo", defaults: defaults)
            == 256
    )
    SparkModelDefaults.saveThinkingBudget(0, targetID: "one", modelID: "nemo", defaults: defaults)
    #expect(
        SparkModelDefaults.thinkingBudget(targetID: "one", modelID: "nemo", defaults: defaults) == 0
    )
    #expect(
        SparkModelDefaults.thinkingBudget(targetID: "two", modelID: "nemo", defaults: defaults)
            == 256
    )
    #expect(
        SparkModelDefaults.thinkingBudget(targetID: "one", modelID: "other", defaults: defaults)
            == 256
    )
}

/// ADR-043: a fresh install takes the recipe's first safe preset, and a remembered id the recipe dropped is reported.
@MainActor
@Test func theDefaultPresetIsTheRecipesFirstSafeProfileAndAStaleSavedChoiceIsNamed() throws {
    let suite = "spark-model-defaults-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let profiles = try JSONDecoder().decode(
        [SparkModelProfile].self,
        from: Data(
            #"[{"id":"unsafe-2m","display_name":"Too large","max_model_length":2097152,"max_sequences":1,"expected_peak_bytes":1,"safe":false},{"id":"agent-256k","display_name":"Agent 256K","max_model_length":262144,"max_sequences":16,"expected_peak_bytes":1,"safe":true},{"id":"long-1m","display_name":"Long 1M","max_model_length":1048576,"max_sequences":4,"expected_peak_bytes":1,"safe":true}]"#
                .utf8
        )
    )
    #expect(SparkModelDefaults.defaultProfile(profiles: profiles) == "agent-256k")
    #expect(
        SparkModelDefaults.preferred(
            targetID: "one",
            modelID: "nemo",
            profiles: profiles,
            defaults: defaults
        )
            == "agent-256k"
    )
    #expect(
        SparkModelDefaults.staleSavedProfile(
            targetID: "one",
            modelID: "nemo",
            profiles: profiles,
            defaults: defaults
        ) == nil
    )
    SparkModelDefaults.save(
        "long-1m",
        targetID: "one",
        modelID: "nemo",
        defaults: defaults
    )
    #expect(
        SparkModelDefaults.preferred(
            targetID: "one",
            modelID: "nemo",
            profiles: profiles,
            defaults: defaults
        ) == "long-1m"
    )
    SparkModelDefaults.save(
        "long-256k",
        targetID: "one",
        modelID: "nemo",
        defaults: defaults
    )
    #expect(
        SparkModelDefaults.preferred(
            targetID: "one",
            modelID: "nemo",
            profiles: profiles,
            defaults: defaults
        )
            == "agent-256k"
    )
    #expect(
        SparkModelDefaults.staleSavedProfile(
            targetID: "one",
            modelID: "nemo",
            profiles: profiles,
            defaults: defaults
        )
            == "long-256k"
    )
    #expect(
        String(localized: .savedPresetNoLongerOffered("long-256k"))
            == "The preset you saved for this model (long-256k) is no longer offered."
    )
}
