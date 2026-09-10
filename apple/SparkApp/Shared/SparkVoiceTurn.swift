import Foundation

/// One conversational turn: listen, hear the end of speech, fill the gap, speak, listen again.
extension SparkVoiceSession {
    func listen() {
        guard canUseAudio() else { return }
        stop()
        if !dictationOnly, output == .silent {
            phase = .needsDownload
            return
        }
        guard
            dictationOnly || externalRequests
                || (chat.isSelectedModelReady && !chat.isPreparingModel
                    && chat.generationState != .streaming)
        else {
            fail(
                String(
                    localized:
                        "Wait for the current reply and choose an available Spark to start voice chat."
                )
            )
            return
        }
        let target = chat.selectedTarget
        let id = operation
        transcript = ""
        phase = .listening
        work = Task { [weak self] in
            guard let self else { return }
            do {
                try await capture.start { [weak self] text, level in
                    guard self?.operation == id else { return }
                    self?.transcript = text
                    self?.level = level
                } completion: { [weak self] result in
                    guard let self, operation == id else { return }
                    level = 0
                    switch result {
                    case .success(let text):
                        guard dictationOnly || externalRequests || chat.selectedTarget == target
                        else {
                            fail(
                                String(
                                    localized: "The selected Spark changed. Start a new voice turn."
                                )
                            )
                            return
                        }
                        receive(text)
                    case .failure(let failure):
                        captureFailed(failure)
                    }
                }
            } catch {
                guard operation == id, !Task.isCancelled else { return }
                capture.stop()
                captureFailed(error)
            }
        }
    }

    func finishListening() { capture.finish() }

    /// A call takes the audio session away; when it hands it back, the conversation goes on.
    func interrupted(by interruption: SparkVoiceInterruption) {
        let response = Self.response(
            to: interruption,
            phase: phase,
            conversation: conversation,
            wasInterrupted: wasInterrupted
        )
        switch response {
        case .ignore:
            if case .ended = interruption { wasInterrupted = false }
        case .stop:
            stop()
            wasInterrupted = true
        case .resume:
            wasInterrupted = false
            listen()
        }
    }

    /// Ask for a permission the owner has not answered yet, then start the turn if it was granted.
    func requestPermission() {
        stop()
        work = Task { [weak self] in
            guard let self else { return }
            permission = await SparkVoiceCapture.permission(requesting: true)
            guard !Task.isCancelled else { return }
            if permission == .granted {
                listen()
            } else {
                phase = .permissionNeeded
            }
        }
    }

    func readAloud(_ content: String) {
        guard canUseAudio() else { return }
        stop()
        switch output {
        case .kokoro: readAloudWithKokoro(content)
        case .device: readAloudOnThisDevice(content)
        case .silent: phase = .needsDownload
        }
    }

    /// Speak with a voice already on this device, so a reply that is here is never left unread.
    private func readAloudOnThisDevice(_ content: String) {
        let id = operation
        phase = .speaking
        work = Task { [weak self] in
            guard let self else { return }
            do {
                try SparkVoiceAudioSession.activate(
                    resumesListeningAfterReadAloud ? .conversation : .playbackOnly
                )
                try await speakOnDevice(Self.spokenText(content))
                guard operation == id, !Task.isCancelled else { return }
                finishReadingAloud()
            } catch is CancellationError {
                return
            } catch {
                guard operation == id, !Task.isCancelled else { return }
                fail(Self.playbackFailure)
            }
        }
    }

    private func readAloudWithKokoro(_ content: String) {
        guard installed, let target else {
            phase = .needsDownload
            return
        }
        let id = operation
        let selectedVoice = voice
        phase = .speaking
        work = Task { [weak self] in
            guard let self else { return }
            do {
                try SparkVoiceAudioSession.activate(
                    resumesListeningAfterReadAloud ? .conversation : .playbackOnly
                )
                for chunk in Self.speechChunks(Self.spokenText(content)) {
                    try Task.checkCancellation()
                    let data = try await service.speech(chunk, voice: selectedVoice, target: target)
                    guard operation == id, !Task.isCancelled else { return }
                    try await player.play(data)
                }
                guard operation == id, !Task.isCancelled else { return }
                player.stop()
                finishReadingAloud()
            } catch {
                guard operation == id, !Task.isCancelled else { return }
                fail(Self.playbackFailure)
            }
        }
    }

    /// A car keeps the conversation going; a phone screen rests until the owner taps.
    private func finishReadingAloud() {
        if resumesListeningAfterReadAloud {
            listen()
        } else {
            SparkVoiceAudioSession.deactivate()
            phase = .ready
        }
    }

    func preview(_ voice: SparkKokoroVoice) {
        guard isVoiceAvailable(voice) else { return }
        if previewingVoice == voice {
            stop()
            return
        }
        stop()
        guard installed, let target else {
            phase = .needsDownload
            return
        }
        let id = operation
        phase = .speaking
        previewingVoice = voice
        work = Task { [weak self] in
            guard let self else { return }
            do {
                try SparkVoiceAudioSession.activate(.playbackOnly)
                let data = try await service.speech(Self.previewLine, voice: voice, target: target)
                guard operation == id, !Task.isCancelled else { return }
                try await player.play(data)
                guard operation == id, !Task.isCancelled else { return }
                phase = .ready
                previewingVoice = nil
            } catch {
                guard operation == id, !Task.isCancelled else { return }
                fail(String(localized: "This voice could not play. Try again."))
            }
        }
    }

    func receive(_ text: String) {
        if dictationOnly {
            let separator = chat.draft.isEmpty ? "" : " "
            chat.draft += separator + text
            didDictate = true
            stop()
            return
        }
        let spoken = text
        stop()
        // The Spark's own filler heard back through the microphone is not a question.
        if conversation, SparkVoiceFillers.isFiller(spoken) {
            listen()
            return
        }
        transcript = spoken
        if let spokenRequestRouter, spokenRequestRouter(spoken) == .handled { return }
        chat.dismissExecutionPolicyRefusal()
        guard let target, let generation = chat.sendVoiceMessage(spoken) else {
            fail(Self.unsentMessage(chat))
            return
        }
        ownsChatRequest = true
        let id = operation
        let selectedVoice = voice
        phase = .heardYou
        startFiller(id: id)
        work = Task { [weak self] in
            guard let self else { return }
            await generation.value
            guard operation == id, !Task.isCancelled else { return }
            ownsChatRequest = false
            guard chat.generationState == .ready, let answer = chat.messages.last,
                answer.role == .assistant, answer.hasAnswer, !answer.isPartial
            else {
                await endFiller()
                guard operation == id, !Task.isCancelled else { return }
                fail(String(localized: "The reply did not finish. You can continue in the chat."))
                return
            }
            await speak(
                Self.spokenText(answer.content),
                voice: selectedVoice,
                target: target,
                id: id
            )
        }
    }

    /// Speak the answer, waiting only for a filler that has already begun.
    private func speak(
        _ content: String,
        voice selectedVoice: SparkKokoroVoice,
        target: SparkVoiceTarget,
        id: UUID
    ) async {
        do {
            if output == .device {
                await endFiller()
                guard operation == id, !Task.isCancelled else { return }
                try SparkVoiceAudioSession.activate(.conversation)
                phase = .speaking
                armBargeIn(id: id)
                try await speakOnDevice(content)
                guard operation == id, !Task.isCancelled else { return }
                listen()
                return
            }
            let chunks = Self.speechChunks(content)
            var first = true
            for chunk in chunks {
                try Task.checkCancellation()
                let data = try await service.speech(chunk, voice: selectedVoice, target: target)
                guard operation == id, !Task.isCancelled else { return }
                if first {
                    await endFiller()
                    guard operation == id, !Task.isCancelled else { return }
                    phase = .speaking
                    armBargeIn(id: id)
                    first = false
                }
                try await player.play(data)
            }
            guard operation == id, !Task.isCancelled else { return }
            listen()
        } catch {
            await endFiller()
            guard operation == id, !Task.isCancelled else { return }
            fail(Self.playbackFailure)
        }
    }

    /// Start a cached filler after a short grace period, so a fast answer is never talked over.
    private func startFiller(id: UUID) {
        fillerStarted = false
        guard output == .kokoro, conversation, fillers.isPrepared else {
            phase = .thinking
            return
        }
        fillerWork = Task { [weak self] in
            try? await Task.sleep(for: .seconds(SparkVoiceTurnTiming.fillerDelay))
            guard let self, operation == id, !Task.isCancelled else { return }
            phase = .thinking
            guard let filler = fillers.next(for: voice) else { return }
            fillerStarted = true
            fillerPhrase = filler.phrase.text
            try? await player.play(filler.audio)
            guard operation == id else { return }
            fillerPhrase = nil
        }
    }

    /// Let a filler finish so the owner never hears half a sentence; skip one that never started.
    private func endFiller() async {
        guard let work = fillerWork else { return }
        if !fillerStarted { work.cancel() }
        await work.value
        fillerWork = nil
        fillerStarted = false
        fillerPhrase = nil
    }

    /// Watch for the owner talking over the reply, but only where echo cancellation is real.
    private func armBargeIn(id: UUID) {
        guard conversation else { return }
        do {
            try capture.startBargeIn { [weak self] in
                guard let self, operation == id else { return }
                listen()
            }
            isBargeInArmed = capture.isEchoCancelling
            if !isBargeInArmed { capture.stop() }
        } catch {
            isBargeInArmed = false
        }
    }

    func captureFailed(_ failure: any Error) {
        guard let voiceFailure = failure as? SparkVoiceCapture.Failure else {
            fail(SparkVoiceCaptureFailurePresentation.message(for: .audioUnavailable))
            return
        }
        switch voiceFailure {
        case .permission(let state):
            permission = state
            phase = .permissionNeeded
        case .recognitionUnavailable:
            permission = .speechUnavailable
            phase = .permissionNeeded
        default:
            fail(SparkVoiceCaptureFailurePresentation.message(for: voiceFailure))
        }
    }

    /// Why a spoken message stayed here: the policy's words, a confirmation to give, or a fault.
    static func unsentMessage(_ chat: SparkChatModel) -> String {
        if let refusal = chat.executionPolicyRefusal { return refusal }
        if chat.pendingVoicePrompt != nil {
            return String(
                localized:
                    "That answer would travel over a remote connection. Confirm it in the chat on your phone before it is sent."
            )
        }
        return String(
            localized: "Your message could not be sent. Check the selected Spark and try again."
        )
    }

    func fail(_ message: String) {
        previewingVoice = nil
        fillerWork?.cancel()
        fillerWork = nil
        fillerStarted = false
        fillerPhrase = nil
        isBargeInArmed = false
        capture.stop()
        player.stop()
        deviceSpeaker.stop()
        error = message
        phase = .failed
    }

    static var playbackFailure: String {
        String(localized: "The reply could not be read aloud. The full text is in your chat.")
    }

    static var previewLine: String {
        String(
            localized:
                "Hello! I’m happy you’re here. Take a breath, make yourself comfortable, and tell me what you’d like to work on today."
        )
    }
}
