import Foundation
import Observation
import SparkAPI
import SparkLibrary

/// A car chooses a real saved conversation or an existing terminal session.
enum SparkCarPlayFocus: Equatable, Sendable {
    case chat
    case conversation(UUID)
    case development(SparkCarPlayDevelopmentTarget)
}

struct SparkCarPlayChatChoice: Identifiable, Equatable {
    let id: UUID
    let title: String
}
struct SparkCarPlayApproval {
    let id = UUID()
    let focus: SparkCarPlayFocus
    let route: String
    let spoken: String?
}

@MainActor @Observable
final class SparkCarPlayConversation {
    private(set) var state: SparkCarPlayVoiceState = .idle
    private(set) var focus: SparkCarPlayFocus = .chat
    private(set) var session: SparkVoiceSession?
    private(set) var lastAnswer: String?
    private(set) var developmentTargets: [SparkCarPlayDevelopmentTarget] = []
    private(set) var chatChoices: [SparkCarPlayChatChoice] = []
    private(set) var isLoadingTargets = false
    private(set) var endedByOwner = false
    private(set) var pendingApproval: SparkCarPlayApproval?
    private(set) var development: SparkCarPlayDevelopmentAdapter?
    private let bridge: SparkCarPlayBridge
    private let coordinator: SparkVoiceCoordinator
    private let makeSession: (SparkChatModel) -> SparkVoiceSession
    private let policy: SparkExecutionPolicyModel
    private var chatModel: SparkChatModel?
    private let suppliedChat: SparkChatModel?
    private let suppliedWorkspace: SparkChatWorkspace?
    private var operation: Task<Void, Never>?
    private var monitoring: Task<Void, Never>?
    private var generation = UUID()
    private var preparationDeadline: Task<Void, Never>?
    private let preparationTimeout: Duration
    private var active = false
    private var approvedRoute: String?
    private var readbackInFlight = false

    init(
        bridge: SparkCarPlayBridge = .shared,
        coordinator: SparkVoiceCoordinator = .shared,
        development: SparkCarPlayDevelopmentAdapter? = nil,
        chatModel: SparkChatModel? = nil,
        workspace: SparkChatWorkspace? = nil,
        preparationTimeout: Duration = .seconds(20),
        policy: SparkExecutionPolicyModel = SparkExecutionPolicyModel(),
        makeSession: @escaping (SparkChatModel) -> SparkVoiceSession = {
            SparkVoiceSession(
                chat: $0,
                dictationOnly: false,
                conversation: true,
                readsAloud: true,
                warmsFillers: false
            )
        }
    ) {
        self.preparationTimeout = preparationTimeout
        self.bridge = bridge
        self.coordinator = coordinator
        self.development = development
        suppliedChat = chatModel
        suppliedWorkspace = workspace
        self.chatModel = chatModel
        self.policy = policy
        self.makeSession = makeSession
    }
    var detail: String { SparkCarPlayCopy.detail(for: state) }
    var title: String {
        if lockBlocker != nil { return SparkCarPlayCopy.appName }
        if case .development(let target) = focus {
            return target.projectName + " · " + target.harness.name
        }
        if case .conversation(let id) = focus {
            return chatChoices.first { $0.id == id }?.title ?? SparkCarPlayCopy.talkTitle
        }
        return SparkCarPlayCopy.talkTitle
    }
    func developmentBlocker() -> String? {
        if !SparkEngineeringMode.isEnabled() { return SparkCarPlayCopy.engineeringOff }
        return lockBlocker
    }
    private var lockBlocker: String? {
        if let lock = bridge.appLock, lock.isEnabled && lock.isLocked {
            return SparkCarPlayCopy.lockedPhone
        }
        return nil
    }
    func loadDevelopmentTargets() {
        guard !isLoadingTargets else { return }
        isLoadingTargets = true
        Task { [weak self] in
            await self?.refreshChoices()
            self?.isLoadingTargets = false
        }
    }
    func refreshChoices() async {
        do { try bridge.ensureReady() } catch { state = .attention(SparkCarPlayCopy.notReady) }
        guard let library = bridge.onboarding?.library else { return }
        if development == nil {
            development = SparkCarPlayDevelopmentAdapter(
                provider: SignedCarPlayDevelopmentProvider(library: library),
                authorize: { [weak self] target in self?.permits(.development(target)) == true }
            )
        }
        synchronizeChoices()
    }
    func synchronizeChoices() {
        guard lockBlocker == nil, let library = bridge.onboarding?.library else {
            developmentTargets = []
            chatChoices = []
            return
        }
        developmentTargets = SparkCarPlayDevelopmentAdapter.targets(
            workspace: SparkDevelopmentWorkspace.shared(library: library)
        )
        chatChoices = SparkChatWorkspace.shared(library: library).sortedConversations.map {
            SparkCarPlayChatChoice(id: $0.id, title: $0.title)
        }
    }
    func newChat() {
        guard lockBlocker == nil else {
            attention(SparkCarPlayCopy.lockedPhone)
            return
        }
        guard let library = bridge.onboarding?.library else { return }
        let workspace = SparkChatWorkspace.shared(library: library)
        workspace.newChat()
        start(.conversation(workspace.selectedID))
    }

    func start(_ focus: SparkCarPlayFocus) { begin(focus, spoken: nil, retainingApproval: false) }
    private func begin(_ focus: SparkCarPlayFocus, spoken: String?, retainingApproval: Bool) {
        stop()
        if !retainingApproval { approvedRoute = nil }
        self.focus = focus
        endedByOwner = false
        active = true
        state = .working
        let id = generation
        armPreparationDeadline(id)
        operation = Task { [weak self] in
            guard let self else { return }
            await refreshChoices()
            guard valid(id) else { return }
            guard let chat = resolveChat() else {
                attention(SparkCarPlayCopy.notReady)
                return
            }
            if let blocker = lockBlocker {
                attention(blocker)
                return
            }
            await chat.refreshTargetEvidence()
            chat.refreshTargets()
            guard valid(id) else { return }
            if case .development = focus, let blocker = developmentBlocker() {
                attention(blocker)
                return
            }
            guard admit(focus, spoken: spoken) else { return }
            if case .development(let target) = focus {
                do {
                    guard let development else {
                        attention(SparkCarPlayCopy.notReady)
                        return
                    }
                    try await development.attach(target)
                } catch {
                    guard valid(id) else { return }
                    attention(APIError.message(for: error))
                    return
                }
            }
            guard valid(id) else { return }
            let voice = makeVoice(chat)
            await voice.prepare()
            guard valid(id), session === voice, coordinator.holds(voice) else { return }
            preparationDeadline?.cancel()
            monitor(id)
            if let spoken { voice.receive(spoken) } else { voice.listen() }
        }
    }
    private func armPreparationDeadline(_ id: UUID) {
        preparationDeadline?.cancel()
        let duration = preparationTimeout
        preparationDeadline = Task { [weak self] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard let self, self.valid(id) else { return }
            self.stop()
            self.attention(
                String(
                    localized:
                        "The Spark is taking too long to respond. Try again when the connection is ready."
                )
            )
        }
    }
    private func valid(_ id: UUID) -> Bool { generation == id && active && !Task.isCancelled }
    private func makeVoice(_ chat: SparkChatModel) -> SparkVoiceSession {
        if let session, session.chat === chat { return session }
        let voice = makeSession(chat)
        session = voice
        coordinator.claim(voice, as: .carPlay)
        voice.voiceTargetFilter = { [weak self] target in
            guard let self, self.permits(self.focus) else { return false }
            if case .development(let project) = self.focus {
                return target.id == project.targetID
                    && target.route
                        == self.bridge.onboarding?.library.entry(id: project.targetID)?
                        .connectRoute?.baseURL
            }
            return target.id == chat.selectedTarget?.id
                && target.route == chat.selectedTarget?.route
        }
        voice.spokenRequestRouter = { [weak self] text in self?.route(text) ?? .handled }
        voice.externalRequests = {
            if case .development = self.focus { return true }
            return false
        }()
        voice.resumesListeningAfterReadAloud = true
        return voice
    }
    func stop() {
        generation = UUID()
        preparationDeadline?.cancel()
        preparationDeadline = nil
        active = false
        operation?.cancel()
        operation = nil
        monitoring?.cancel()
        monitoring = nil
        if let session {
            if coordinator.holds(session) {
                session.stop()
                coordinator.release(session)
            }
        }
        session = nil
        readbackInFlight = false
        pendingApproval = nil
        state = .idle
        development?.detach()
    }
    func disconnect() {
        stop()
        approvedRoute = nil
    }
    func interrupt() {
        if case .development = focus, development?.connected != true {
            start(focus)
            return
        }
        guard let session, active, coordinator.holds(session) else {
            start(focus)
            return
        }
        generation = UUID()
        operation?.cancel()
        operation = nil
        session.listen()
        monitor(generation)
    }
    func primaryVoiceAction() {
        if session?.phase == .listening { session?.finishListening() } else { interrupt() }
    }
    func endVoice() {
        stop()
        approvedRoute = nil
        endedByOwner = true
    }
    func approve(_ approvalID: UUID) {
        guard let approval = pendingApproval, approval.id == approvalID,
            routeKey(approval.focus) == approval.route
        else {
            pendingApproval = nil
            return
        }
        approvedRoute = approval.route
        begin(approval.focus, spoken: approval.spoken, retainingApproval: true)
    }
    func repeatLastAnswer() {
        guard let lastAnswer else {
            speakStatus()
            return
        }
        play(lastAnswer, thenListen: false)
    }
    func readLatestOutput() {
        guard development?.isWorking != true else { return }
        guard let text = development?.collectReadback(force: true) else {
            play(String(localized: "There is no new terminal output yet."), thenListen: true)
            return
        }
        readbackInFlight = true
        play(String(localized: .carPlaySessionOutput(text: text)), thenListen: true)
    }
    func speakStatus() {
        stop()
        active = true
        endedByOwner = false
        let id = generation
        state = .working
        armPreparationDeadline(id)
        operation = Task { [weak self] in
            guard let self else { return }
            await refreshChoices()
            await bridge.onboarding?.refreshSavedSparks()
            guard valid(id) else { return }
            guard lockBlocker == nil else {
                attention(SparkCarPlayCopy.lockedPhone)
                return
            }
            var text = String(localized: "No Sparks are paired yet.")
            if let entries = bridge.onboarding?.library.entries, !entries.isEmpty {
                text = entries.map { entry in
                    let online = [.connectedWiFi, .connectedDirect, .connectedRemote].contains(
                        entry.connectionState
                    )
                    var status =
                        entry.displayName + ": "
                        + (online
                            ? String(localized: "connected") : String(localized: "not reachable"))
                    if online,
                        let snapshot = bridge.onboarding?.library.operationalSnapshot(
                            for: entry.id,
                            at: Date()
                        ),
                        snapshot.evidence.inference.state == .current
                    {
                        status += ". " + FleetPresentationBuilder.activeModel(snapshot)
                    } else {
                        status = String(
                            localized: .carPlayUnavailableModel(status: status)
                        )
                    }
                    return status
                }.joined(separator: ". ")
            }
            if case .development = focus, let development {
                text += ". " + (await development.checkStatus())
            }
            guard valid(id) else { return }
            await prepareAndPlay(text, thenListen: false, id: id, deviceOnly: true)
        }
    }
    private func play(_ text: String, thenListen: Bool) {
        guard !text.isEmpty else { return }
        let id = generation
        operation = Task { [weak self] in
            await self?.prepareAndPlay(text, thenListen: thenListen, id: id)
        }
    }
    private func prepareAndPlay(
        _ text: String,
        thenListen: Bool,
        id: UUID,
        deviceOnly: Bool = false
    ) async {
        guard valid(id), let chat = resolveChat() else { return }
        let voice = makeVoice(chat)
        if deviceOnly { voice.voiceTargetFilter = { _ in false } }
        if voice.phase == .checking { await voice.prepare() }
        guard valid(id), session === voice, coordinator.holds(voice) else { return }
        preparationDeadline?.cancel()
        lastAnswer = text
        voice.resumesListeningAfterReadAloud = thenListen
        voice.readAloud(text)
        monitor(id)
    }
    private func attention(_ message: String) { state = .attention(message) }
    private func resolveChat() -> SparkChatModel? {
        if let suppliedChat {
            chatModel = suppliedChat
            return suppliedChat
        }
        guard
            let workspace = suppliedWorkspace
                ?? bridge.onboarding.map({ SparkChatWorkspace.shared(library: $0.library) })
        else { return nil }
        if case .conversation(let id) = focus {
            guard workspace.conversations.contains(where: { $0.id == id }) else { return nil }
            workspace.select(id)
        }
        chatModel = workspace.selected.model
        return chatModel
    }
    private func routeKey(_ focus: SparkCarPlayFocus) -> String? {
        if case .development(let target) = focus {
            guard let route = bridge.onboarding?.library.entry(id: target.targetID)?.connectRoute
            else { return nil }
            return target.id + "::" + route.baseURL.absoluteString
        }
        guard let target = chatModel?.selectedTarget else { return nil }
        return target.id + "::" + target.modelID + "::" + target.route.absoluteString
    }
    private func decision(_ focus: SparkCarPlayFocus) -> SparkExecutionDecision {
        policy.reload()
        if let blocker = lockBlocker { return .refused(blocker) }
        if case .development(let target) = focus {
            if let blocker = developmentBlocker() { return .refused(blocker) }
            guard let route = bridge.onboarding?.library.entry(id: target.targetID)?.connectRoute
            else { return .refused(SparkCarPlayCopy.noSpark) }
            return policy.decision(for: route.kind == .privateOverlay ? .remote : .localNetwork)
        }
        guard let target = chatModel?.selectedTarget else {
            return .refused(SparkCarPlayCopy.noSpark)
        }
        return policy.decision(for: target.executionLocation.transport)
    }
    private func permits(_ focus: SparkCarPlayFocus) -> Bool {
        switch decision(focus) {
        case .allowed: true
        case .needsConfirmation: approvedRoute != nil && approvedRoute == routeKey(focus)
        case .refused: false
        }
    }
    private func admit(_ focus: SparkCarPlayFocus, spoken: String?) -> Bool {
        guard !permits(focus) else { return true }
        if case .needsConfirmation = decision(focus), let key = routeKey(focus) {
            pendingApproval = SparkCarPlayApproval(focus: focus, route: key, spoken: spoken)
            attention(String(localized: "Use this Spark over your remote connection?"))
        } else if case .refused(let reason) = decision(focus) {
            attention(reason)
        }
        return false
    }
    private func route(_ spoken: String) -> SparkVoiceRoute {
        if Self.isStopPhrase(spoken) {
            endVoice()
            return .handled
        }
        guard active, let voice = session, coordinator.holds(voice) else { return .handled }
        guard admit(focus, spoken: spoken) else { return .handled }
        guard case .development = focus else { return .chat }
        let command = spoken.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if ["read the latest output", "read latest output", "what has it done", "read that back"]
            .contains(command)
        {
            readLatestOutput()
            return .handled
        }
        if command == "i checked the delivery", let target = development?.target {
            development?.clearDeliveryWarning(for: target)
            play(
                String(localized: "Delivery warning cleared. What would you like to do next?"),
                thenListen: true
            )
            return .handled
        }
        let id = generation
        voice.phase = .thinking
        operation = Task { [weak self] in
            guard let self, let development else { return }
            let text = await development.submit(spoken)
            guard valid(id), coordinator.holds(voice) else { return }
            await prepareAndPlay(text, thenListen: true, id: id)
        }
        return .handled
    }
    private func monitor(_ id: UUID) {
        monitoring?.cancel()
        monitoring = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick(id)
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }
    private func tick(_ id: UUID) {
        guard valid(id), let session else { return }
        guard coordinator.holds(session) else {
            stop()
            return
        }
        if let blocker = lockBlocker {
            stop()
            attention(blocker)
            return
        }
        if readbackInFlight, session.phase == .listening || session.phase == .ready {
            development?.didReadOutput()
            readbackInFlight = false
        }
        if case .development = focus, development?.connected == false,
            let error = development?.error
        {
            if session.phase == .listening { session.stop() }
            state = .attention(error)
            return
        }
        if case .development = focus {
        } else if session.phase == .speaking,
            let answer = session.chat.messages.last, answer.role == .assistant,
            answer.hasAnswer, !answer.isPartial
        {
            lastAnswer = answer.content
        }
        state = Self.voiceState(
            for: session.phase,
            error: session.error,
            working: development?.isWorking == true
        )
        guard case .development = focus, session.phase == .listening,
            session.transcript.isEmpty, !readbackInFlight
        else { return }
        if let text = development?.collectReadback() {
            readbackInFlight = true
            play(String(localized: .carPlaySessionOutput(text: text)), thenListen: true)
        }
    }
    /// Map the session's phase to the car's four states; a tester can call this without audio.
    static func voiceState(
        for phase: SparkVoiceSession.Phase,
        error: String?,
        working: Bool
    ) -> SparkCarPlayVoiceState {
        if working { return .working }
        switch phase {
        case .listening: return .listening
        case .heardYou, .thinking, .checking, .downloading: return .working
        case .speaking: return .speaking
        case .failed, .permissionNeeded, .needsDownload:
            return .attention(error ?? SparkCarPlayCopy.stopped)
        case .ready: return .idle
        }
    }

    /// The words that end a conversation; said alone, they are never sent to the Spark.
    static func isStopPhrase(_ spoken: String) -> Bool {
        let words = spoken.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
        let phrases = [
            "stop", "stop listening", "that s all", "that is all", "thats all", "goodbye",
            "pause", "never mind", "nevermind", "cancel", "thanks that s all",
            "thank you that s all",
            "ok stop", "okay stop", "stop talking",
        ]
        return phrases.contains(words)
    }

}
