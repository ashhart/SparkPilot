#if os(iOS)
    @preconcurrency import AVFoundation
#endif
import Foundation

/// What the system said about an audio interruption: a call took the audio, or gave it back.
enum SparkVoiceInterruption: Equatable, Sendable {
    case began
    case ended(resume: Bool)

    /// The raw values AVAudioSession documents, so the decision can be replayed off an iPhone.
    static let beganRawValue: UInt = 0
    static let endedRawValue: UInt = 1
    static let shouldResumeRawValue: UInt = 1

    /// Read the notification's payload; anything the system does not describe is not an interruption.
    static func parse(typeRawValue: UInt?, optionRawValue: UInt?) -> SparkVoiceInterruption? {
        guard let typeRawValue else { return nil }
        #if os(iOS)
            guard let type = AVAudioSession.InterruptionType(rawValue: typeRawValue) else {
                return nil
            }
            switch type {
            case .began: return .began
            case .ended:
                let options = AVAudioSession.InterruptionOptions(rawValue: optionRawValue ?? 0)
                return .ended(resume: options.contains(.shouldResume))
            @unknown default: return nil
            }
        #else
            switch typeRawValue {
            case beganRawValue: return .began
            case endedRawValue:
                return .ended(resume: (optionRawValue ?? 0) & shouldResumeRawValue != 0)
            default: return nil
            }
        #endif
    }

    /// The payload as the notification carries it.
    static func parse(userInfo: [AnyHashable: Any]?) -> SparkVoiceInterruption? {
        #if os(iOS)
            return parse(
                typeRawValue: userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                optionRawValue: userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            )
        #else
            return nil
        #endif
    }
}

/// What a voice screen does about an interruption, so the decision can be read as a value.
enum SparkVoiceInterruptionResponse: Equatable, Sendable {
    case ignore
    case stop
    case resume
}
