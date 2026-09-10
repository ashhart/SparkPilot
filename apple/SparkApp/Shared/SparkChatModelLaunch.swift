import Foundation
import SparkAPI
import SparkLanguageModel
import SparkLibrary

/// Loading a model before a queued message is sent, kept out of the chat model's own file.
@MainActor
extension SparkChatModel {
    func prepareModelForMessage(prompt: String, retry: Bool) -> Task<Void, Never>? {
        guard let launcher = modelLauncher, let target = selectedTarget, !isPreparingModel else {
            return nil
        }
        let attempt = UUID()
        modelLaunchAttempt = attempt
        queuedModelMessage = (prompt, draft, pendingAttachments, replyDraft, retry)
        modelLaunchError = nil
        modelLaunchState = .preparing
        // Keep fast readiness checks quiet while preserving admission and the send lock.
        let revealCheck = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, self.modelLaunchAttempt == attempt,
                self.modelLaunchState == .preparing
            else { return }
            self.modelLaunchState = .checking
        }
        let task = Task { [weak self] in
            defer { revealCheck.cancel() }
            guard let self else { return }
            do {
                let plan = try await launcher.prepare(target: target, profileID: nil)
                guard !Task.isCancelled, modelLaunchAttempt == attempt else {
                    launcher.discard(plan)
                    // A newer attempt owns the state; only this one's own leftovers are cleared.
                    releaseModelLaunch(attempt: attempt)
                    return
                }
                if plan.requiresApproval {
                    pendingModelLaunch = plan
                    modelLaunchState = .awaitingApproval
                } else {
                    await loadModelAndSend(plan, attempt: attempt)
                }
            } catch {
                failModelLaunch(error, attempt: attempt)
            }
        }
        modelLaunchTask = task
        return task
    }

    @discardableResult
    public func confirmModelLaunch() -> Task<Void, Never>? {
        guard let plan = pendingModelLaunch, plan.confirmation?.canApply == true else { return nil }
        pendingModelLaunch = nil
        let attempt = modelLaunchAttempt
        let task = Task { [weak self] in
            guard let self else { return }
            await loadModelAndSend(plan, attempt: attempt)
        }
        modelLaunchTask = task
        return task
    }

    public func cancelModelLaunch() {
        modelLaunchAttempt = UUID()
        modelLaunchTask?.cancel()
        modelLaunchTask = nil
        if let plan = pendingModelLaunch { modelLauncher?.discard(plan) }
        pendingModelLaunch = nil
        queuedModelMessage = nil
        modelLaunchState = .idle
        modelLaunchProgress = nil
        modelLaunchError = nil
    }

    func loadModelAndSend(_ plan: SparkModelLaunchPlan, attempt: UUID) async {
        guard modelLaunchAttempt == attempt else { return }
        guard let launcher = modelLauncher else {
            releaseModelLaunch(attempt: attempt)
            return
        }
        if !plan.alreadyReady { modelLaunchState = .loading }
        defer {
            if modelLaunchAttempt == attempt {
                modelLaunchState = .idle
                queuedModelMessage = nil
                modelLaunchProgress = nil
                modelLaunchTask = nil
            }
        }
        do {
            let ready = try await launcher.apply(plan) { [weak self] progress in
                guard let self, self.modelLaunchAttempt == attempt else { return }
                self.modelLaunchProgress = progress
            }
            try Task.checkCancellation()
            guard modelLaunchAttempt == attempt, selectedTargetID == ready.id,
                selectedModelID == ready.modelID, let queued = queuedModelMessage
            else { return }
            catalogue = catalogue.replacingTargets(on: ready)
            modelLaunchState = .idle
            queuedModelMessage = nil
            if queued.retry, let last = messages.last, last.role == .assistant,
                last.isPartial || !last.hasAnswer
            {
                messages.removeLast()
            }
            guard
                let generation = startGeneration(
                    prompt: queued.prompt,
                    appendUserMessage: !queued.retry,
                    attachments: queued.attachments,
                    replyTo: queued.reply
                )
            else { return }
            if !queued.retry {
                if draft == queued.draft { draft = "" }
                if replyDraft == queued.reply { replyDraft = nil }
                if pendingAttachments == queued.attachments { pendingAttachments = [] }
            }
            await generation.value
        } catch {
            failModelLaunch(error, attempt: attempt)
        }
    }

    /// Give the composer back, unless a newer attempt has already taken the launch state over.
    func releaseModelLaunch(attempt: UUID) {
        guard modelLaunchAttempt == attempt else { return }
        modelLaunchState = .idle
        queuedModelMessage = nil
        modelLaunchProgress = nil
        modelLaunchTask = nil
    }

    func failModelLaunch(_ error: any Error, attempt: UUID) {
        guard modelLaunchAttempt == attempt else { return }
        modelLaunchState = .idle
        queuedModelMessage = nil
        if !(error is CancellationError) {
            modelLaunchError =
                (error as? LocalizedError)?.errorDescription
                ?? String(
                    localized:
                        "The model could not be started; your message has been kept. Try again after checking the Spark."
                )
        }
    }
}
