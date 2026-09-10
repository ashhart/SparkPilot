import Foundation
import FoundationModels

/// What Apple Intelligence can do on this device, in the terms an owner needs rather than a framework's.
public enum SparkAppleIntelligenceState: String, CaseIterable, Sendable, Equatable {
    case ready
    case deviceNotEligible
    case turnedOff
    case modelDownloading
    case unknown

    /// Say what is true of this device and what the owner can do about it, without implying their Spark is at fault.
    public var explanation: String {
        switch self {
        case .ready:
            String(
                localized:
                    "Apple Intelligence is ready on this device, so Siri can pass your words to SparkPilot."
            )
        case .deviceNotEligible:
            String(
                localized:
                    "This device does not support Apple Intelligence. Shortcuts still run every SparkPilot action, and your Spark answers them."
            )
        case .turnedOff:
            String(
                localized:
                    "Apple Intelligence is turned off. Turn it on in Settings to use Siri, or run SparkPilot actions from Shortcuts instead."
            )
        case .modelDownloading:
            String(
                localized:
                    "Apple Intelligence is still preparing on this device. Siri answers once it finishes; Shortcuts actions work now."
            )
        case .unknown:
            String(
                localized:
                    "This device did not report whether Apple Intelligence is ready. Shortcuts actions still reach your Spark."
            )
        }
    }

    /// A short label for a settings row, kept separate from the sentence that explains it.
    public var summary: String {
        switch self {
        case .ready: String(localized: "Ready")
        case .deviceNotEligible: String(localized: "Not supported")
        case .turnedOff: String(localized: "Turned off")
        case .modelDownloading: String(localized: "Preparing")
        case .unknown: String(localized: "Unknown")
        }
    }
}

/// Read Apple's own availability instead of inferring it from a device model or an OS version.
public enum SparkAppleIntelligence {
    /// Apple Intelligence never generates an answer here: a Spark is the model runtime, and this probe only explains what Siri itself can do.
    public static var state: SparkAppleIntelligenceState {
        state(of: SystemLanguageModel.default.availability)
    }

    public static func state(
        of availability: SystemLanguageModel.Availability
    ) -> SparkAppleIntelligenceState {
        switch availability {
        case .available:
            return .ready
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .turnedOff
            case .modelNotReady: return .modelDownloading
            @unknown default: return .unknown
            }
        @unknown default:
            return .unknown
        }
    }
}
