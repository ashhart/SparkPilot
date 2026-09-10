import Foundation

/// Decides in Swift whether a hardware audio format can carry a tap.
enum SparkVoiceAudioFormat {
    static let minimumSampleRate = 8_000.0
    static let maximumSampleRate = 192_000.0
    static let maximumChannelCount: UInt32 = 32
    static let minimumBufferSize: UInt32 = 256
    static let maximumBufferSize: UInt32 = 8_192
    static let levelGain = 12.0

    /// An unusable format has to be refused before `installTap` raises an uncatchable exception.
    static func isUsable(sampleRate: Double, channelCount: UInt32) -> Bool {
        guard sampleRate.isFinite, channelCount >= 1, channelCount <= maximumChannelCount else {
            return false
        }
        return sampleRate >= minimumSampleRate && sampleRate <= maximumSampleRate
    }

    /// About fifty milliseconds of audio, rounded down to a power of two the engine accepts.
    static func tapBufferSize(sampleRate: Double) -> UInt32 {
        guard sampleRate.isFinite, sampleRate > 0 else { return minimumBufferSize }
        let target = max(
            Double(minimumBufferSize),
            min(sampleRate * 0.05, Double(maximumBufferSize))
        )
        var size = minimumBufferSize
        while size * 2 <= maximumBufferSize, Double(size * 2) <= target { size *= 2 }
        return size
    }

    /// A displayable 0…1 loudness from a buffer's root mean square, never negative and never NaN.
    static func level(rootMeanSquare value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 0 }
        return min(1, value * levelGain)
    }
}

/// One owner-facing sentence per capture failure, so audio setup never ends in silence.
enum SparkVoiceCaptureFailurePresentation {
    static func message(for failure: SparkVoiceCapture.Failure) -> String {
        switch failure {
        case .permission:
            String(localized: "Voice needs the microphone and speech recognition to hear you.")
        case .audioUnavailable:
            String(
                localized:
                    "This device would not start the microphone. Unplug or reconnect any headset, then try again."
            )
        case .recognitionUnavailable:
            String(
                localized:
                    "On-device English speech recognition is unavailable here. You can still type in the chat."
            )
        case .noSpeech:
            String(localized: "No speech was heard. Tap Start talking to try again.")
        case .tooLong:
            String(localized: "That turn reached the time limit. Tap Start talking to carry on.")
        }
    }
}
