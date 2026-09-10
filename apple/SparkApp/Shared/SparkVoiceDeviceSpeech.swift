@preconcurrency import AVFoundation
import Foundation

/// Reads text with a voice already installed on this device, for when no Spark can be reached.
@MainActor
final class SparkVoiceDeviceSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var utteranceID: UUID?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// The system voice for the current language, falling back to any installed voice.
    nonisolated static func systemVoice() -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())
            ?? AVSpeechSynthesisVoice.speechVoices().first
    }

    nonisolated static var isAvailable: Bool { systemVoice() != nil }

    /// The name the owner would recognise in Settings, so the screen can say who is speaking.
    nonisolated static var voiceName: String {
        let name = systemVoice()?.name ?? ""
        return name.isEmpty ? SparkVoiceAvailabilityCopy.deviceVoiceTitle : name
    }

    func speak(_ text: String) async throws {
        stop()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let id = UUID()
        utteranceID = id
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = Self.systemVoice()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                synthesizer.speak(utterance)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.utteranceID == id else { return }
                self?.stop()
            }
        }
    }

    func stop() {
        let pending = continuation
        continuation = nil
        utteranceID = nil
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        pending?.resume(throwing: CancellationError())
    }

    private func finish(_ failure: (any Error)?) {
        let pending = continuation
        continuation = nil
        utteranceID = nil
        guard let pending else { return }
        if let failure { pending.resume(throwing: failure) } else { pending.resume() }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in self?.finish(nil) }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in self?.finish(CancellationError()) }
    }
}
