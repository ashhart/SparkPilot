@preconcurrency import AVFoundation
import Foundation

/// Owns the audio session for a whole conversation so a category change never restarts a live tap.
@MainActor
enum SparkVoiceAudioSession {
    enum Use: Equatable { case conversation, playbackOnly }

    private(set) static var current: Use?
    /// Set while a car is connected: play-and-record, default mode, the car's mic and speakers.
    static var routesThroughCar = false {
        didSet { if oldValue != routesThroughCar { current = nil } }
    }

    /// Configure and activate once per use; a category change under a live tap is what broke it.
    static func activate(_ use: Use) throws {
        #if os(iOS)
            guard current != use else { return }
            let audio = AVAudioSession.sharedInstance()
            switch use {
            case .conversation where routesThroughCar:
                try audio.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP])
            case .conversation:
                try audio.setCategory(
                    .playAndRecord,
                    mode: .voiceChat,
                    options: [.defaultToSpeaker, .allowBluetoothHFP]
                )
            case .playbackOnly:
                try audio.setCategory(.playback, mode: .spokenAudio)
            }
            try audio.setActive(true)
            current = use
        #else
            current = use
        #endif
    }

    static func deactivate() {
        current = nil
        #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: .notifyOthersOnDeactivation
            )
        #endif
    }
}

@MainActor
final class SparkVoicePlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var continuation: CheckedContinuation<Void, any Error>?
    private var playbackID: UUID?

    /// Play one clip to completion. The session category is already set for the conversation.
    func play(_ data: Data) async throws {
        stopPlayback()
        let id = UUID()
        playbackID = id
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let player = try AVAudioPlayer(data: data)
            self.player = player
            player.delegate = self
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                if !player.play() {
                    self.continuation = nil
                    continuation.resume(throwing: SparkVoiceCapture.Failure.audioUnavailable)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.playbackID == id else { return }
                self?.stop()
            }
        }
    }

    var isPlaying: Bool { player?.isPlaying == true }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self, weak player] in
            guard let self, let player, self.player === player else { return }
            let continuation = self.continuation
            self.continuation = nil
            self.player = nil
            if flag {
                continuation?.resume()
            } else {
                continuation?.resume(throwing: SparkVoiceCapture.Failure.audioUnavailable)
            }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        Task { @MainActor [weak self, weak player] in
            guard let self, let player, self.player === player else { return }
            self.stop()
        }
    }

    func stop() { stopPlayback() }

    private func stopPlayback() {
        playbackID = nil
        player?.stop()
        player = nil
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}
