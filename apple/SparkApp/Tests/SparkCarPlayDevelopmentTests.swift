import Foundation
import SparkAPI
import SparkCore
import SparkLibrary
import SparkProjects
import Testing
@testable import SparkAppComposition

private actor CarTerminal: ProjectTerminalConnecting {
    var sent: [String] = []
    var frames: [String] = []
    var cancelled = false
    var failSend = false
    func start() { cancelled = false }
    func send(_ text: String) throws {
        sent.append(text)
        if failSend { throw URLError(.networkConnectionLost) }
    }
    func receive() async throws -> String {
        while frames.isEmpty {
            if cancelled { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
        return frames.removeFirst()
    }
    func cancel() { cancelled = true }
    func feed(_ text: String) { frames.append(text) }
    func loseReply() { failSend = true }
}
@MainActor private final class CarProvider: SparkCarPlayDevelopmentProviding {
    var socket = CarTerminal()
    var connections: [SparkCarPlayDevelopmentTarget] = []
    var route = "local"
    func routeIdentity(_ target: SparkCarPlayDevelopmentTarget) -> String { route }
    var currentState: String? = "running"
    var wait: CheckedContinuation<Void, Never>?
    var suspendState = false
    func connect(_ target: SparkCarPlayDevelopmentTarget) async throws
        -> any ProjectTerminalConnecting
    {
        connections.append(target)
        return socket
    }
    func state(_ target: SparkCarPlayDevelopmentTarget) async throws -> String? {
        if suspendState { await withCheckedContinuation { wait = $0 } }
        return currentState
    }
}
private struct CarStreamer: SparkChatStreaming {
    func stream(target: SparkChatTarget, request: ChatCompletionRequest) async throws
        -> AsyncThrowingStream<ChatStreamEvent, any Error>
    {
        AsyncThrowingStream { $0.finish() }
    }
}
@MainActor private final class CarTargets: SparkChatTargetProviding {
    var ready = true
    var refreshCount = 0
    var refreshDelay: Duration?
    var remote = false
    func catalogue() -> SparkChatTargetCatalogue {
        SparkChatTargetCatalogue(
            targets: ready
                ? [
                    SparkChatTarget(
                        id: "spark",
                        displayName: "Spark",
                        nodeID: SparkNodeID(
                            rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
                        ),
                        route: URL(string: "https://fixture.invalid")!,
                        tlsFingerprint: "fixture",
                        authorityFingerprint: "fixture",
                        modelID: "model",
                        modelName: "Model",
                        connection: remote ? .connectedRemote : .connectedWiFi
                    )
                ] : [],
            pairedTargetCount: 1
        )
    }
    func refresh() async {
        refreshCount += 1
        if let refreshDelay { try? await Task.sleep(for: refreshDelay) }
        ready = true
    }
    func voiceTargets() -> [SparkVoiceTarget] { [] }
}

@MainActor @Suite(.serialized)
struct SparkCarPlayDevelopmentTests {
    private func target(
        _ terminal: String = "terminal",
        harness: ProjectDevelopmentHarness = .ohMyPi
    ) -> SparkCarPlayDevelopmentTarget {
        let record = SparkDevelopmentRecord(
            id: UUID(),
            targetID: "spark",
            projectID: "project",
            projectName: "App",
            sparkName: "Spark",
            selection: ProjectDevelopmentSelection(
                harness: harness,
                modelID: "model",
                clusterID: nil
            ),
            launchKey: UUID(),
            terminal: GeneratedAPI.ProjectTerminal(
                terminalId: terminal,
                projectId: "project",
                state: .running,
                createdAt: "2026-09-06"
            ),
            draft: ""
        )
        return SparkCarPlayDevelopmentTarget(record: record)!
    }
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "carplay-next-tests-" + UUID().uuidString)!
    }
    private func adapter(
        _ provider: CarProvider,
        defaults: UserDefaults? = nil,
        now: @escaping () -> Date = Date.init,
        authorize: @escaping (SparkCarPlayDevelopmentTarget) -> Bool = { _ in true }
    ) -> SparkCarPlayDevelopmentAdapter {
        SparkCarPlayDevelopmentAdapter(
            provider: provider,
            defaults: defaults ?? self.defaults(),
            now: now,
            authorize: authorize
        )
    }
    private func settle(_ predicate: @escaping () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(predicate(), "Asynchronous state did not settle")
    }
    private func quietVoice(_ chat: SparkChatModel) -> SparkVoiceSession {
        let voice = SparkVoiceSession(
            chat: chat,
            dictationOnly: false,
            conversation: true,
            readsAloud: true,
            warmsFillers: false
        )
        voice.deviceSpeechAvailable = { false }
        return voice
    }
    @Test func instructionsUseTheExactExistingHarnessAndTerminal() async throws {
        let provider = CarProvider()
        let adapter = adapter(provider)
        let target = target("existing-opencode", harness: .openCode)
        defer { adapter.detach() }
        try await adapter.attach(target)
        let answer = await adapter.submit("Now add the settings page")
        #expect(provider.connections == [target])
        #expect(answer.contains("sent"))
        #expect(await provider.socket.sent == ["\u{1b}[200~Now add the settings page\u{1b}[201~\r"])
        _ = await adapter.submit("Now add a test")
        #expect(await provider.socket.sent.count == 2)
        #expect(provider.connections.count == 1)
    }
    @Test func leavingOnlyDetachesAndReturningNeverReplaysInput() async throws {
        let provider = CarProvider()
        let saved = defaults()
        let target = target()
        let first = adapter(provider, defaults: saved)
        try await first.attach(target)
        _ = await first.submit("Add a test")
        first.detach()
        let second = adapter(provider, defaults: saved)
        defer { second.detach() }
        try await second.attach(target)
        #expect(await provider.socket.sent.count == 1)
        #expect(provider.connections.allSatisfy { $0.terminalID == target.terminalID })
    }
    @Test func aLostDeliveryIsNotRetriedAfterReconnectionOrRelaunch() async throws {
        let provider = CarProvider()
        let saved = defaults()
        let target = target()
        let first = adapter(provider, defaults: saved)
        try await first.attach(target)
        await provider.socket.loseReply()
        let result = await first.submit("Fix it")
        #expect(result.contains("not send"))
        first.detach()
        let second = adapter(provider, defaults: saved)
        defer { second.detach() }
        try await second.attach(target)
        let again = await second.submit("Fix it")
        #expect(again.contains("uncertain"))
        #expect(await provider.socket.sent.count == 1)
    }
    @Test func anEndedSessionIsNeverSilentlyRestarted() async {
        let provider = CarProvider()
        provider.currentState = "stopped"
        let adapter = adapter(provider)
        await #expect(throws: (any Error).self) { try await adapter.attach(target()) }
        #expect(provider.connections.isEmpty)
        #expect(!adapter.connected)
    }
    @Test func cancellationWhileCheckingCannotAttachALateSocket() async throws {
        let provider = CarProvider()
        provider.suspendState = true
        let adapter = adapter(provider)
        let opening = Task { try await adapter.attach(target()) }
        try await settle { provider.wait != nil }
        adapter.detach()
        provider.wait?.resume()
        provider.wait = nil
        await #expect(throws: CancellationError.self) { try await opening.value }
        #expect(provider.connections.isEmpty)
    }
    @Test func changedAuthorizationPreventsSendingEvenAfterAConnection() async throws {
        var allowed = true
        let provider = CarProvider()
        let adapter = adapter(provider, authorize: { _ in allowed })
        defer { adapter.detach() }
        try await adapter.attach(target())
        allowed = false
        _ = await adapter.submit("Do this")
        #expect(await provider.socket.sent.isEmpty)
    }
    @Test func escapeSequencesCannotBecomeTerminalKeystrokesFromVoice() async throws {
        let provider = CarProvider()
        let adapter = adapter(provider)
        defer { adapter.detach() }
        try await adapter.attach(target())
        _ = await adapter.submit("hi\u{1b}[201~rm -rf")
        _ = await adapter.submit(String(repeating: "a", count: 7001))
        #expect(await provider.socket.sent.isEmpty)
    }
    @Test func readbackKeepsOutputThatArrivesDuringSpeech() async throws {
        var now = Date(timeIntervalSince1970: 100)
        let provider = CarProvider()
        let adapter = adapter(provider, now: { now })
        defer { adapter.detach() }
        try await adapter.attach(target())
        await provider.socket.feed("Implemented settings.\r\n")
        try await settle { adapter.lastOutputAt != nil }
        now.addTimeInterval(4)
        #expect(adapter.collectReadback()?.contains("Implemented settings") == true)
        await provider.socket.feed("Tests passed.\r\n")
        try await Task.sleep(for: .milliseconds(30))
        adapter.didReadOutput()
        now.addTimeInterval(15)
        #expect(adapter.collectReadback()?.contains("Tests passed") == true)
    }
    @Test func redrawsDoNotDuplicateReadbackOrClaimCompletion() {
        let output = ProjectTerminalReadback()
        output.feed("\u{1b}[2J\u{1b}[HWorking on tests")
        output.markRead()
        output.feed("\u{1b}[HWorking on tests")
        #expect(output.unread.isEmpty)
        output.feed("\u{1b}[2J\u{1b}[HAdded settings and tests passed.")
        #expect(output.unread == "Added settings and tests passed.")
        #expect(!output.latest.contains("Working"))
    }
    @Test func statusBeforeChatCreatesPlaybackWithoutMicrophoneCapture() async throws {
        let chat = SparkChatModel(provider: CarTargets(), streamer: CarStreamer())
        let car = SparkCarPlayConversation(
            bridge: SparkCarPlayBridge(),
            coordinator: SparkVoiceCoordinator(),
            chatModel: chat,
            makeSession: quietVoice
        )
        defer { car.disconnect() }
        car.speakStatus()
        try await settle { car.session != nil }
        #expect(car.lastAnswer != nil)
    }
    @Test func carEntryRefreshesStaleTargets() async throws {
        let targets = CarTargets()
        targets.ready = false
        let chat = SparkChatModel(provider: targets, streamer: CarStreamer())
        let car = SparkCarPlayConversation(
            bridge: SparkCarPlayBridge(),
            coordinator: SparkVoiceCoordinator(),
            chatModel: chat,
            makeSession: quietVoice
        )
        defer { car.disconnect() }
        car.start(.chat)
        try await settle { targets.refreshCount > 0 }
        #expect(targets.ready)
    }
    @Test func stopFencesPendingPreparation() async throws {
        let chat = SparkChatModel(provider: CarTargets(), streamer: CarStreamer())
        var madeVoice = false
        let car = SparkCarPlayConversation(
            bridge: SparkCarPlayBridge(),
            coordinator: SparkVoiceCoordinator(),
            chatModel: chat,
            makeSession: { chat in
                madeVoice = true
                return quietVoice(chat)
            }
        )
        car.start(.chat)
        car.stop()
        try await Task.sleep(for: .milliseconds(40))
        #expect(!madeVoice)
        #expect(car.session == nil)
        #expect(car.state == .idle)
    }
    @Test func remoteUseHasAnExplicitTargetBoundApproval() async throws {
        let targets = CarTargets()
        targets.remote = true
        let chat = SparkChatModel(provider: targets, streamer: CarStreamer())
        let car = SparkCarPlayConversation(
            bridge: SparkCarPlayBridge(),
            coordinator: SparkVoiceCoordinator(),
            chatModel: chat,
            policy: SparkExecutionPolicyModel(defaults: defaults()),
            makeSession: quietVoice
        )
        defer { car.disconnect() }
        car.start(.chat)
        try await settle { car.pendingApproval != nil }
        let approval = try #require(car.pendingApproval)
        #expect(car.session == nil)
        car.approve(approval.id)
        try await settle { car.session != nil }
        #expect(car.pendingApproval == nil)
    }
    @Test func staleApprovalCannotAuthorizeAnotherModel() async throws {
        let targets = CarTargets()
        targets.remote = true
        let chat = SparkChatModel(provider: targets, streamer: CarStreamer())
        let car = SparkCarPlayConversation(
            bridge: SparkCarPlayBridge(),
            coordinator: SparkVoiceCoordinator(),
            chatModel: chat,
            policy: SparkExecutionPolicyModel(defaults: defaults()),
            makeSession: quietVoice
        )
        defer { car.disconnect() }
        car.start(.chat)
        try await settle { car.pendingApproval != nil }
        let approval = try #require(car.pendingApproval)
        car.stop()
        car.approve(approval.id)
        #expect(car.session == nil)
    }
    @Test func releasedVehicleRestrictionRecoversWithoutRequestingGPS() {
        var reducer = SparkDrivingStateReducer()
        let now = Date()
        _ = reducer.apply(
            SparkDrivingSignals(
                carPlayConnected: true,
                keyboardRestrictedByCar: true,
                observedAt: now
            )
        )
        #expect(
            reducer.apply(
                SparkDrivingSignals(
                    carPlayConnected: true,
                    keyboardRestrictedByCar: false,
                    observedAt: now.addingTimeInterval(60)
                )
            ) == .parked
        )
    }
    @Test func anOldAudioOwnerCannotRestartAfterHandoff() {
        let chat = SparkChatModel(provider: CarTargets(), streamer: CarStreamer())
        let coordinator = SparkVoiceCoordinator()
        let first = quietVoice(chat)
        let second = quietVoice(chat)
        coordinator.claim(first, as: .phone)
        coordinator.claim(second, as: .carPlay)
        let stopped = first.operation
        first.listen()
        first.readAloud("old output")
        #expect(first.operation == stopped)
        #expect(coordinator.holds(second))
        second.stop()
        coordinator.release(second)
    }
    @Test func stopPhrasesAreCommandsButNormalInstructionsAreNot() {
        #expect(SparkCarPlayConversation.isStopPhrase("Stop."))
        #expect(!SparkCarPlayConversation.isStopPhrase("Stop the build from failing"))
        #expect(
            SparkCarPlayConversation.voiceState(for: .speaking, error: nil, working: false)
                == .speaking
        )
    }
    @Test func replyArrivingDuringAMicrophoneTurnMustWaitForTheOwner() async throws {
        // The readback queue stays pending until playback actually completes.
        var now = Date(timeIntervalSince1970: 100)
        let provider = CarProvider()
        let adapter = adapter(provider, now: { now })
        defer { adapter.detach() }
        try await adapter.attach(target())
        await provider.socket.feed("First reply.\r\n")
        try await settle { adapter.lastOutputAt != nil }
        now.addTimeInterval(4)
        let queued = adapter.collectReadback()
        #expect(queued != nil)
        now.addTimeInterval(20)
        #expect(adapter.collectReadback() == queued)
        adapter.didReadOutput()
        #expect(adapter.collectReadback() == nil)
    }
    @Test func startingASecondVoiceDoesNotDetachItsNewSessionLate() async throws {
        let provider = CarProvider()
        let adapter = adapter(provider)
        let first = target("one")
        let second = target("two")
        try await adapter.attach(first)
        adapter.detach()
        provider.socket = CarTerminal()
        try await adapter.attach(second)
        try await Task.sleep(for: .milliseconds(20))
        #expect(adapter.connected)
        #expect(adapter.target?.terminalID == "two")
        #expect(await provider.socket.cancelled == false)
        adapter.detach()
    }

    @Test func routeChangesCannotSendOverAnOldSocket() async throws {
        let provider = CarProvider()
        let adapter = adapter(provider)
        defer { adapter.detach() }
        try await adapter.attach(target())
        provider.route = "remote"
        let answer = await adapter.submit("Add a setting")
        #expect(answer.contains("connection changed"))
        #expect(await provider.socket.sent.isEmpty)
    }

    @Test func existingPhoneConversationIsSelectedWithoutCreatingOrReplacingIt() async throws {
        let chat = SparkChatModel(provider: CarTargets(), streamer: CarStreamer())
        let workspace = SparkChatWorkspace(initialModel: chat)
        let first = workspace.selected
        first.model.draft = "Keep this phone draft"
        workspace.newChat()
        let second = workspace.selected
        let car = SparkCarPlayConversation(
            bridge: SparkCarPlayBridge(),
            coordinator: SparkVoiceCoordinator(),
            workspace: workspace,
            makeSession: quietVoice
        )
        defer { car.disconnect() }
        car.start(.conversation(first.id))
        try await settle { car.session != nil }
        #expect(car.session?.chat === first.model)
        #expect(workspace.selectedID == first.id)
        #expect(first.model.draft == "Keep this phone draft")
        car.start(.conversation(second.id))
        try await settle { car.session?.chat === second.model }
        #expect(workspace.conversations.count == 2)
    }
    @Test func coldBootstrapRetriesAndIsSharedWithThePhone() throws {
        let bridge = SparkCarPlayBridge()
        let model = RetailOnboardingModel(library: SparkLibrary(store: MemoryLibraryStore()))
        var attempts = 0
        bridge.configure(appLock: AppLockModel(defaults: defaults())) {
            attempts += 1
            if attempts == 1 { throw URLError(.notConnectedToInternet) }
            return model
        }
        #expect(throws: (any Error).self) { try bridge.ensureReady() }
        #expect(bridge.onboarding == nil)
        try bridge.ensureReady()
        #expect(try bridge.composedOnboarding() === model)
        #expect(attempts == 2)
    }
    @Test func policyChangedOnPhoneAppliesBeforeTheNextCarTurn() async throws {
        let saved = defaults()
        let car = SparkCarPlayConversation(
            bridge: SparkCarPlayBridge(),
            coordinator: SparkVoiceCoordinator(),
            chatModel: SparkChatModel(provider: CarTargets(), streamer: CarStreamer()),
            policy: SparkExecutionPolicyModel(defaults: saved),
            makeSession: quietVoice
        )
        defer { car.disconnect() }
        SparkExecutionPolicyModel(defaults: saved).choice = .onDeviceOnly
        car.start(.chat)
        try await settle {
            if case .attention = car.state { return true }
            return false
        }
        #expect(car.session == nil)
    }
    @Test func readbackNeverUsesAnotherSparksVoice() async {
        let source = CarTargets()
        let target = SparkVoiceTarget(source.catalogue().targets[0])
        let voice = SparkVoiceSession(
            chat: SparkChatModel(provider: source, streamer: CarStreamer()),
            dictationOnly: false,
            readsAloud: true,
            initialTarget: target
        )
        voice.voiceTargetFilter = { _ in false }
        voice.deviceSpeechAvailable = { true }
        await voice.prepare()
        #expect(voice.target == nil)
        #expect(voice.output == .device)
    }
    @Test func appLockHidesTheSelectedProjectAndPreventsVoice() async throws {
        let saved = defaults()
        saved.set(true, forKey: AppLockModel.enabledKey)
        let bridge = SparkCarPlayBridge()
        bridge.configure(appLock: AppLockModel(defaults: saved)) {
            RetailOnboardingModel(library: SparkLibrary(store: MemoryLibraryStore()))
        }
        let car = SparkCarPlayConversation(
            bridge: bridge,
            coordinator: SparkVoiceCoordinator(),
            chatModel: SparkChatModel(provider: CarTargets(), streamer: CarStreamer()),
            makeSession: quietVoice
        )
        defer { car.disconnect() }
        car.start(.development(target()))
        try await settle {
            if case .attention = car.state { return true }
            return false
        }
        #expect(car.title == "SparkPilot")
        #expect(car.session == nil)
        #expect(car.chatChoices.isEmpty && car.developmentTargets.isEmpty)
    }

    @Test func slowPreparationTimesOutAndCannotStartListeningLater() async throws {
        let targets = CarTargets()
        targets.refreshDelay = .seconds(5)
        let car = SparkCarPlayConversation(
            bridge: SparkCarPlayBridge(),
            coordinator: SparkVoiceCoordinator(),
            chatModel: SparkChatModel(provider: targets, streamer: CarStreamer()),
            preparationTimeout: .milliseconds(20),
            makeSession: quietVoice
        )
        defer { car.disconnect() }
        car.start(.chat)
        try await settle {
            if case .attention = car.state { return true }
            return false
        }
        #expect(car.session == nil)
        try await Task.sleep(for: .milliseconds(40))
        #expect(car.session == nil)
    }

}
