import Foundation
import SparkDesignSystem

/// Apply the owner's §39.2 execution policy before any prompt leaves this Apple device.
@MainActor
extension SparkChatModel {
    public func refreshTargets() {
        guard let provider else { return }
        replaceCatalogue(provider.catalogue())
    }

    /// Refresh only the authenticated evidence needed for chat while its screen is active.
    public func runTargetRefreshes(interval: Duration = .seconds(8)) async {
        guard let provider else { return }
        while !Task.isCancelled {
            refreshTargets()
            await provider.refresh()
            guard !Task.isCancelled else { return }
            refreshTargets()
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
        }
    }

    func executionDecision() -> SparkExecutionDecision {
        guard let policy = executionPolicy, let target = selectedTarget else { return .allowed }
        return policy.decision(for: target.executionLocation.transport)
    }

    /// A voice turn uses the same signed chat path, and the same policy, without consuming a draft.
    @discardableResult
    func sendVoiceMessage(_ text: String) -> Task<Void, Never>? {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isPreparingModel, isSelectedModelReady else { return nil }
        switch executionDecision() {
        case .refused(let reason):
            executionPolicyRefusal = reason
            return nil
        case .needsConfirmation(let reason):
            pendingVoicePrompt = prompt
            pendingRemoteExecution = reason
            return nil
        case .allowed:
            executionPolicyRefusal = nil
        }
        guard personal.isFresh || personal.isEmpty else {
            return readPersonalContextThenSpeak(text)
        }
        return startGeneration(
            prompt: prompt,
            appendUserMessage: true,
            usingPendingAttachments: false
        )
    }

    /// Send after the owner has read which route the answer would travel.
    @discardableResult
    public func confirmRemoteExecution() -> Task<Void, Never>? {
        guard pendingRemoteExecution != nil else { return nil }
        pendingRemoteExecution = nil
        if let spoken = pendingVoicePrompt {
            pendingVoicePrompt = nil
            return startGeneration(
                prompt: spoken,
                appendUserMessage: true,
                usingPendingAttachments: false
            )
        }
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return nil }
        if modelLauncher != nil { return prepareModelForMessage(prompt: prompt, retry: false) }
        guard
            let task = startGeneration(prompt: prompt, appendUserMessage: true, replyTo: replyDraft)
        else {
            return nil
        }
        draft = ""
        replyDraft = nil
        removeEveryAttachment()
        return task
    }

    public func cancelRemoteExecution() {
        pendingRemoteExecution = nil
        pendingVoicePrompt = nil
    }

    public func dismissExecutionPolicyRefusal() { executionPolicyRefusal = nil }
}
