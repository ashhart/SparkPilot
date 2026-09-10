import Foundation
import Observation
import SparkAPI
import SparkLanguageModel
import SparkLibrary
import SparkTransport

@MainActor
@Observable
public final class SparkChatModel {
    public internal(set) var catalogue: SparkChatTargetCatalogue
    public private(set) var selectedTargetID: String? { didSet { onChange?() } }
    public private(set) var selectedModelID: String? { didSet { onChange?() } }
    public internal(set) var modelLaunchState: SparkChatModelLaunchState = .idle
    /// The Spark's stage and fraction for the load in progress, shown under the launch line.
    public internal(set) var modelLaunchProgress: SparkModelLaunchProgress?
    public internal(set) var pendingModelLaunch: SparkModelLaunchPlan?
    public internal(set) var modelLaunchError: String?
    @ObservationIgnored let modelLauncher: (any SparkModelLaunching)?
    @ObservationIgnored var modelLaunchTask: Task<Void, Never>?
    @ObservationIgnored var modelLaunchAttempt = UUID()
    @ObservationIgnored var queuedModelMessage:
        (
            prompt: String, draft: String, attachments: [SparkChatAttachment],
            reply: SparkChatReplyReference?, retry: Bool
        )?
    public internal(set) var messages: [SparkChatMessage] = [] { didSet { onChange?() } }
    public var draft = "" { didSet { onChange?() } }
    public internal(set) var replyDraft: SparkChatReplyReference? { didSet { onChange?() } }
    #if DEBUG
        var usesSampleData = false
    #endif
    public var allowsWebAccess = false
    public var web: Bool { SparkChatWebAccess.isOn(self) }
    public private(set) var generationState: SparkChatGenerationState = .ready {
        didSet { onChange?() }
    }
    @ObservationIgnored var onChange: (@MainActor () -> Void)? {
        didSet { attachmentDraft.onChange = onChange }
    }
    @ObservationIgnored var preservesTargetWhenUnavailable = false
    @ObservationIgnored private let attachmentDraft = SparkChatAttachmentDraft()
    @ObservationIgnored let personal = SparkChatPersonalContextModel()

    public internal(set) var pendingAttachments: [SparkChatAttachment] {
        get { attachmentDraft.pendingAttachments }
        set { attachmentDraft.pendingAttachments = newValue }
    }
    public var isImportingAttachments: Bool { attachmentDraft.isImportingAttachments }
    public var attachmentError: String? {
        get { attachmentDraft.attachmentError }
        set { attachmentDraft.attachmentError = newValue }
    }

    @ObservationIgnored let provider: (any SparkChatTargetProviding)?
    @ObservationIgnored private let streamer: any SparkChatStreaming
    @ObservationIgnored private var generationTask: Task<Void, Never>?
    @ObservationIgnored private var activeGenerationID: UUID?
    @ObservationIgnored private var activeAssistantID: UUID?
    @ObservationIgnored private var retryPrompt: String?
    /// The owner's §39.2 execution policy; absent in fixtures that do not exercise it.
    @ObservationIgnored var executionPolicy: SparkExecutionPolicyModel?
    /// A send held back until the owner confirms a remote route (§39.2, §52.1).
    public internal(set) var pendingRemoteExecution: String?
    /// Why the policy refused, so the refusal is explainable rather than a silent no-op (§39.11).
    public internal(set) var executionPolicyRefusal: String?
    /// A spoken turn held back with `pendingRemoteExecution`; confirming sends it, not the draft.
    @ObservationIgnored var pendingVoicePrompt: String?
    /// The answer exactly as it arrived, so the plain-style pass always rewrites from the source.
    @ObservationIgnored private var streamedAnswer = ""
    @ObservationIgnored private var plainTextStream = SparkChatPlainTextStream()
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored let settings: SparkChatSettings
    /// nil follows the app-wide setting; a value is this conversation's own decision.
    public private(set) var plainStyleOverride: Bool? { didSet { onChange?() } }

    public init(
        catalogue: SparkChatTargetCatalogue = .empty,
        streamer: any SparkChatStreaming,
        now: @escaping @MainActor () -> Date = Date.init,
        modelLauncher: (any SparkModelLaunching)? = nil,
        settings: SparkChatSettings = .shared
    ) {
        self.catalogue = catalogue
        self.streamer = streamer
        self.now = now
        self.provider = nil
        self.modelLauncher = modelLauncher
        self.settings = settings
        let initial = (modelLauncher == nil ? catalogue.targets : catalogue.modelChoices).first
        self.selectedTargetID = initial?.id
        self.selectedModelID = initial?.modelID
    }

    public init(
        provider: any SparkChatTargetProviding,
        streamer: any SparkChatStreaming,
        now: @escaping @MainActor () -> Date = Date.init,
        modelLauncher: (any SparkModelLaunching)? = nil,
        settings: SparkChatSettings = .shared
    ) {
        self.provider = provider
        self.streamer = streamer
        self.now = now
        self.settings = settings
        let catalogue = provider.catalogue()
        self.catalogue = catalogue
        self.modelLauncher = modelLauncher
        let initial = (modelLauncher == nil ? catalogue.targets : catalogue.modelChoices).first
        self.selectedTargetID = initial?.id
        self.selectedModelID = initial?.modelID
    }

    var voiceTargets: [SparkVoiceTarget] {
        provider?.voiceTargets() ?? catalogue.targets.map(SparkVoiceTarget.init)
    }

    func makeSibling() -> SparkChatModel {
        let sibling =
            if let provider {
                SparkChatModel(
                    provider: provider,
                    streamer: streamer,
                    now: now,
                    modelLauncher: modelLauncher,
                    settings: settings
                )
            } else {
                SparkChatModel(
                    catalogue: catalogue,
                    streamer: streamer,
                    now: now,
                    modelLauncher: modelLauncher,
                    settings: settings
                )
            }
        sibling.executionPolicy = executionPolicy
        #if DEBUG
            sibling.usesSampleData = usesSampleData
        #endif
        return sibling
    }

    func restore(
        messages: [SparkChatMessage],
        draft: String,
        targetID: String?,
        at date: Date,
        pendingAttachments: [SparkChatAttachment] = [],
        modelID: String? = nil,
        sharesPersonalContext: Bool = false,
        replyDraft: SparkChatReplyReference? = nil
    ) {
        personal.isSharing = sharesPersonalContext
        self.messages = messages.map { $0.restoredAfterInterruption(at: date) }
        self.draft = draft
        self.replyDraft = replyDraft
        self.pendingAttachments = pendingAttachments
        self.selectedTargetID = targetID
        self.selectedModelID =
            modelID ?? availableModelChoices.first(where: { $0.id == targetID })?.modelID
        if let last = self.messages.last,
            last.role == .user || last.isPartial || !last.hasAnswer
        {
            retryPrompt = self.messages.last(where: { $0.role == .user })?.content
            generationState = .cancelled
        }
    }

    func refreshTargetEvidence() async {
        await provider?.refresh()
    }

    public var selectedTarget: SparkChatTarget? {
        guard let selectedTargetID else { return nil }
        return availableModelChoices.first {
            $0.id == selectedTargetID && (selectedModelID == nil || $0.modelID == selectedModelID)
        }
    }

    public var availableModelChoices: [SparkChatTarget] {
        modelLauncher == nil ? catalogue.targets : catalogue.modelChoices
    }

    public var isPreparingModel: Bool { modelLaunchState != .idle }

    public var isSelectedModelReady: Bool {
        catalogue.targets.contains { $0.id == selectedTargetID && $0.modelID == selectedModelID }
    }

    public var canSend: Bool {
        selectedTarget != nil && !isPreparingModel
            && (!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !pendingAttachments.isEmpty)
            && !isImportingAttachments && attachmentBlocker == nil
            && generationState != .streaming
    }

    public var canRetry: Bool {
        retryPrompt != nil && selectedTarget != nil && generationState != .streaming
            && !isPreparingModel
            && attachmentBlocker == nil
    }

    public var attachmentBlocker: String? {
        attachmentDraft.blocker(messages: messages, target: selectedTarget)
    }

    public func importFiles(_ urls: [URL]) async {
        await attachmentDraft.importFiles(
            urls,
            allowed: generationState != .streaming && !isPreparingModel
        )
    }

    public func importSharedFiles(_ files: [SparkSharedFile]) async {
        await attachmentDraft.importSharedFiles(
            files,
            allowed: generationState != .streaming && !isPreparingModel
        )
    }

    public func cancelAttachmentImport() { attachmentDraft.cancelAttachmentImport() }

    func importPhotos(_ photos: [SparkChatPhotoSource]) async {
        guard photoLibraryBlocker == nil else {
            attachmentError = photoLibraryBlocker
            return
        }
        await attachmentDraft.importPhotos(
            photos,
            allowed: generationState != .streaming && !isPreparingModel
        )
    }

    public func removeAttachment(id: UUID) { attachmentDraft.removeAttachment(id: id) }

    func removeEveryAttachment() { pendingAttachments.removeAll() }

    public func newConversation() {
        resetConversation()
    }

    public func replaceCatalogue(_ replacement: SparkChatTargetCatalogue) {
        let priorSelection = selectedTargetID
        catalogue = replacement
        if let priorSelection,
            availableModelChoices.contains(where: {
                $0.id == priorSelection
                    && (modelLauncher == nil || selectedModelID == nil
                        || $0.modelID == selectedModelID)
            })
        {
            if modelLauncher == nil || selectedModelID == nil {
                selectedModelID =
                    availableModelChoices.first(where: { $0.id == priorSelection })?.modelID
            }
            return
        }
        cancelModelLaunch()
        if preservesTargetWhenUnavailable, priorSelection != nil {
            // Keep an offline conversation and its retry prompt bound to the saved Spark identity.
            if generationState == .streaming {
                cancelAndInvalidateGeneration()
                generationState = .cancelled
            }
            return
        }
        if generationState == .streaming {
            // Cancelling an unavailable target must also release the streaming state.
            cancelAndInvalidateGeneration()
        }
        // Discard the former Spark's retry prompt when selecting another target.
        generationState = .ready
        retryPrompt = nil
        if !preservesTargetWhenUnavailable || priorSelection == nil {
            if let priorSelection, let replacement = availableModelChoices.first,
                priorSelection != replacement.id
            {
                resetConversation()
            }
            selectedTargetID = availableModelChoices.first?.id ?? priorSelection
            selectedModelID = availableModelChoices.first?.modelID ?? selectedModelID
        }
    }

    public func selectTarget(id: String) {
        guard let target = availableModelChoices.first(where: { $0.id == id }) else { return }
        selectTarget(target)
    }

    public func selectTarget(_ target: SparkChatTarget) {
        guard availableModelChoices.contains(target),
            selectedTargetID != target.id || selectedModelID != target.modelID
        else { return }
        if selectedTargetID != target.id { resetConversation() }
        cancelModelLaunch()
        if generationState == .streaming { cancelAndInvalidateGeneration() }
        selectedTargetID = target.id
        selectedModelID = target.modelID
        generationState = .ready
        retryPrompt = nil
    }

    public var usesPlainStyle: Bool { plainStyleOverride ?? settings.isPlainStyleEnabled }

    /// nil hands the decision back to the app-wide setting.
    public func setPlainStyleOverride(_ value: Bool?) {
        guard plainStyleOverride != value else { return }
        plainStyleOverride = value
    }

    func restorePlainStyleOverride(_ value: Bool?) {
        plainStyleOverride = value
    }

    @discardableResult
    public func send() -> Task<Void, Never>? {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return nil }
        switch executionDecision() {
        case .refused(let reason):
            executionPolicyRefusal = reason
            return nil
        case .needsConfirmation(let reason):
            pendingRemoteExecution = reason
            return nil
        case .allowed:
            executionPolicyRefusal = nil
        }
        guard personal.isFresh || personal.isEmpty else { return readPersonalContextThenSend() }
        if modelLauncher != nil { return prepareModelForMessage(prompt: prompt, retry: false) }
        // Clear the draft only after generation starts successfully.
        guard
            let task = startGeneration(prompt: prompt, appendUserMessage: true, replyTo: replyDraft)
        else {
            return nil
        }
        draft = ""
        replyDraft = nil
        pendingAttachments.removeAll()
        return task
    }

    @discardableResult
    public func retry() -> Task<Void, Never>? {
        guard canRetry, let retryPrompt else { return nil }
        if modelLauncher != nil { return prepareModelForMessage(prompt: retryPrompt, retry: true) }
        if let last = messages.last, last.role == .assistant,
            last.isPartial || !last.hasAnswer
        {
            messages.removeLast()
        }
        return startGeneration(prompt: retryPrompt, appendUserMessage: false)
    }

    public func cancel() {
        if isPreparingModel { cancelModelLaunch() }
        guard generationState == .streaming else { return }
        cancelAndInvalidateGeneration()
        generationState = .cancelled
    }

    public func resetConversation() {
        personal.reset()
        cancelModelLaunch()
        cancelAndInvalidateGeneration()
        cancelAttachmentImport()
        messages = []
        pendingAttachments = []
        attachmentError = nil
        draft = ""
        replyDraft = nil
        retryPrompt = nil
        pendingRemoteExecution = nil
        pendingVoicePrompt = nil
        executionPolicyRefusal = nil
        generationState = .ready
    }

    func startGeneration(
        prompt: String,
        appendUserMessage: Bool,
        usingPendingAttachments: Bool = true,
        attachments: [SparkChatAttachment]? = nil,
        replyTo: SparkChatReplyReference? = nil
    ) -> Task<Void, Never>? {
        guard let target = selectedTarget, generationState != .streaming, attachmentBlocker == nil
        else { return nil }
        let userMessage = SparkChatMessage(
            role: .user,
            content: prompt,
            attachments: attachments ?? (usingPendingAttachments ? pendingAttachments : []),
            replyTo: replyTo
        )
        let candidate = appendUserMessage ? messages + [userMessage] : messages
        let transcript = SparkChatTranscript.messages(
            candidate,
            system: SparkChatInstructionAssembly.systemMessage(extra: instructionSections)
                ?? personal.systemMessage()
        )
        guard SparkChatTranscript.fits(transcript, contextLength: target.contextLength) else {
            attachmentError = SparkAttachmentError.contextTooLarge.errorDescription
            return nil
        }
        personal.consume()
        if appendUserMessage { messages.append(userMessage) }
        streamedAnswer = ""
        plainTextStream = SparkChatPlainTextStream()
        retryPrompt = prompt
        generationState = .streaming
        let generationID = UUID()
        activeGenerationID = generationID
        let assistantID = UUID()
        activeAssistantID = assistantID
        messages.append(
            SparkChatMessage(
                id: assistantID,
                role: .assistant,
                content: "",
                targetName: target.displayName,
                modelName: target.modelName,
                isPartial: true,
                responsePhase: .waiting,
                generationStartedAt: now()
            )
        )
        let request = ChatCompletionRequest(
            model: target.modelID,
            messages: transcript,
            stream: true,
            thinkingTokenBudget: SparkModelDefaults.thinkingBudget(
                targetID: target.id,
                modelID: target.modelID
            ),
            streamOptionsIncludeUsage: true
        )
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runGeneration(
                target: target,
                request: request,
                assistantID: assistantID,
                generationID: generationID
            )
        }
        generationTask = task
        return task
    }

    private func runGeneration(
        target: SparkChatTarget,
        request: ChatCompletionRequest,
        assistantID: UUID,
        generationID: UUID
    ) async {
        do {
            try Task.checkCancellation()
            guard activeGenerationID == generationID else { return }
            let usesWeb = web
            let answer = try await streamer.answer(
                target: target,
                request: request,
                webAccess: usesWeb
            )
            // The pages one answer read belong to the conversation that asked, not to the model.
            try Task.checkCancellation()
            guard activeGenerationID == generationID else { throw CancellationError() }
            if usesWeb, let index = messages.firstIndex(where: { $0.id == assistantID }) {
                messages[index].sources = answer.webSources
            }
            events: for try await event in answer.events {
                try Task.checkCancellation()
                guard activeGenerationID == generationID else { throw CancellationError() }
                if case .done = event { break events }
                if case .sources(let sources) = event,
                    let index = messages.firstIndex(where: { $0.id == assistantID })
                {
                    messages[index].sources = sources
                }
                if case .usage(let prompt, let completion, let total) = event,
                    let index = messages.firstIndex(where: { $0.id == assistantID })
                {
                    messages[index].usage = SparkChatTokenUsage(
                        promptTokens: prompt,
                        completionTokens: completion,
                        totalTokens: total
                    )
                }
                if case .chunk(_, _, let delta, let reasoning, let finishReason) = event,
                    let index = messages.firstIndex(where: { $0.id == assistantID }),
                    messages[index].responsePhase != .complete
                {
                    let observedAt = now()
                    // A reasoning model's working, kept out of the answer.
                    if let reasoning, !reasoning.isEmpty {
                        messages[index].reasoning.append(reasoning)
                        if messages[index].responsePhase == .waiting,
                            !reasoning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        {
                            messages[index].responsePhase = .thinking
                            messages[index].reasoningStartedAt = observedAt
                        }
                    }
                    if let delta, !delta.isEmpty {
                        streamedAnswer.append(delta)
                        messages[index].content = presentedAnswer(isComplete: false)
                        if !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            messages[index].finishReasoning(at: observedAt)
                            messages[index].responsePhase = .answering
                        }
                    }
                    if let finishReason, !finishReason.isEmpty {
                        messages[index].finishReason = finishReason
                        messages[index].finishReasoning(at: observedAt)
                        messages[index].responsePhase = .complete
                        messages[index].isPartial = false
                    }
                }
            }
            guard !Task.isCancelled else { throw CancellationError() }
            guard activeGenerationID == generationID else { return }
            finishAssistant(id: assistantID, phase: .complete)
            if messages.first(where: { $0.id == assistantID })?.hasAnswer == true {
                retryPrompt = nil
            }
            generationState = .ready
        } catch is CancellationError {
            if activeGenerationID == generationID {
                finishAssistant(id: assistantID, phase: .cancelled)
                removeEmptyAssistant(id: assistantID)
                generationState = .cancelled
            }
        } catch {
            if activeGenerationID == generationID {
                finishAssistant(id: assistantID, phase: .failed)
                removeEmptyAssistant(id: assistantID)
                generationState = .failed(SparkChatFailure.resolve(error))
            }
        }
        if activeGenerationID == generationID {
            generationTask = nil
            activeGenerationID = nil
            activeAssistantID = nil
        }
    }

    /// Plain style rewrites nothing while it is switched off, so the answer is the model's own text.
    private func presentedAnswer(isComplete: Bool) -> String {
        guard usesPlainStyle else { return streamedAnswer }
        return plainTextStream.rendered(streamedAnswer, isComplete: isComplete)
    }

    private func finishAssistant(id: UUID, phase: SparkChatResponsePhase) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        // The last paragraph only becomes safe to rewrite once no more text can arrive.
        if id == activeAssistantID { messages[index].content = presentedAnswer(isComplete: true) }
        messages[index].generationEndedAt = now()
        messages[index].finishReasoning(at: now())
        messages[index].responsePhase = phase
        messages[index].isPartial = phase != .complete
    }

    private func removeEmptyAssistant(id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }),
            !messages[index].hasAnswer, !messages[index].hasReasoning
        else {
            return
        }
        messages.remove(at: index)
    }

    private func cancelAndInvalidateGeneration() {
        generationTask?.cancel()
        if let activeAssistantID {
            finishAssistant(id: activeAssistantID, phase: .cancelled)
            removeEmptyAssistant(id: activeAssistantID)
        }
        generationTask = nil
        activeGenerationID = nil
        activeAssistantID = nil
    }
}
