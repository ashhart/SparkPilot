import Foundation

/// Everything the car says, in one place, so the spoken product reads as one voice.
enum SparkCarPlayCopy {
    static var appName: String { String(localized: "SparkPilot") }
    static var talkTitle: String { String(localized: "Talk to Spark") }
    static var developTitle: String { String(localized: "Develop by voice") }
    static var statusTitle: String { String(localized: "What is Spark doing?") }
    static var repeatTitle: String { String(localized: "Say that again") }
    static var stopTitle: String { String(localized: "Stop") }
    static var listening: String { String(localized: "Listening") }
    static var working: String { String(localized: "Thinking") }
    static var speaking: String { String(localized: "Speaking") }
    static var stopped: String { String(localized: "Paused") }
    static var developSection: String { String(localized: "Your projects") }
    static var chatSection: String { String(localized: "Conversation") }
    static var noProjects: String {
        String(localized: "Open a project in Engineering Mode on your iPhone to develop by voice.")
    }
    static var engineeringOff: String {
        String(localized: "Turn on Engineering Mode on your iPhone to develop by voice.")
    }
    static var lockedPhone: String {
        String(localized: "Unlock SparkPilot on your iPhone first.")
    }
    static var noSpark: String {
        String(localized: "Pair a Spark on your iPhone before using it in the car.")
    }
    static var notReady: String {
        String(localized: "SparkPilot is still opening on your iPhone. Try again in a moment.")
    }
    static func detail(for state: SparkCarPlayVoiceState) -> String {
        switch state {
        case .idle: String(localized: "Tap to start talking")
        case .listening: listening
        case .working: working
        case .speaking: speaking
        case .attention(let message): message
        }
    }
}

/// The four states a car voice screen can show; CarPlay draws them, the app decides them.
enum SparkCarPlayVoiceState: Equatable, Sendable {
    case idle
    case listening
    case working
    case speaking
    /// Something the driver should hear about, said once and shown until the next turn.
    case attention(String)

    var identifier: String {
        switch self {
        case .idle: "idle"
        case .listening: "listening"
        case .working: "working"
        case .speaking: "speaking"
        case .attention: "attention"
        }
    }
}
