import Foundation

#if os(iOS)
    import UIKit
#endif

/// What the system says about the two permissions voice needs, plus the cases neither covers.
enum SparkVoicePermission: Equatable, Sendable {
    case notDetermined
    case granted
    case microphoneDenied
    case speechDenied
    case speechRestricted
    case speechUnavailable
}

/// One notice for a permission state: what happened, what it is for, and the way out.
struct SparkVoicePermissionNotice: Equatable, Sendable {
    let title: String
    let message: String
    let actionTitle: String?
    let opensSettings: Bool
}

/// Turns a permission state into copy. No state is allowed to be a dead end.
enum SparkVoicePermissionPresentation {
    static let purpose = String(
        localized: "The microphone is used only while you are talking to your Spark."
    )

    /// The name of the per-device setting, in the same words the consent string uses.
    static let appleServiceSettingTitle = String(localized: "Use Apple's speech service")

    /// What the app promises about where speech is turned into text, which the setting changes.
    static func recognitionPromise(allowsAppleServers: Bool) -> String {
        guard allowsAppleServers else {
            return String(
                localized:
                    "What you say is turned into text on this device, so your Spark can answer it. It is not sent anywhere else."
            )
        }
        return String(
            localized:
                "What you say is turned into text on this device where it can be. Where it cannot, you have allowed it to be sent to Apple's speech service instead."
        )
    }

    static func notice(
        for permission: SparkVoicePermission,
        allowsAppleServers: Bool = SparkVoiceRecognitionPolicy.allowsAppleServers()
    ) -> SparkVoicePermissionNotice? {
        switch permission {
        case .granted:
            nil
        case .notDetermined:
            .init(
                title: String(localized: "SparkPilot needs your microphone"),
                message: purpose,
                actionTitle: String(localized: "Allow microphone access"),
                opensSettings: false
            )
        case .microphoneDenied:
            .init(
                title: String(localized: "Please enable the microphone for SparkPilot"),
                message: purpose,
                actionTitle: String(localized: "Open Settings"),
                opensSettings: true
            )
        case .speechDenied:
            .init(
                title: String(localized: "Please enable speech recognition for SparkPilot"),
                message: recognitionPromise(allowsAppleServers: allowsAppleServers),
                actionTitle: String(localized: "Open Settings"),
                opensSettings: true
            )
        case .speechRestricted:
            .init(
                title: String(localized: "Speech recognition is restricted on this device"),
                message: String(
                    localized:
                        "A profile or Screen Time limit is blocking it. You can still type in the chat."
                ),
                actionTitle: nil,
                opensSettings: false
            )
        case .speechUnavailable:
            .init(
                title: String(localized: "Speech recognition is unavailable here"),
                message: unavailableMessage(allowsAppleServers: allowsAppleServers),
                actionTitle: nil,
                opensSettings: false
            )
        }
    }

    /// Why nothing can be transcribed here, without promising a fallback that is turned off.
    static func unavailableMessage(allowsAppleServers: Bool) -> String {
        guard allowsAppleServers else {
            return String(
                localized:
                    "This device cannot turn English speech into text on its own, and SparkPilot keeps what you say here. You can still type in the chat."
            )
        }
        return String(
            localized:
                "No speech recognition is available here at the moment. You can still type in the chat."
        )
    }

    /// The privacy pane for this app, so a denied permission always has a way back.
    static var settingsURL: URL? {
        #if os(iOS)
            return URL(string: UIApplication.openSettingsURLString)
        #else
            return URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            )
        #endif
    }
}
