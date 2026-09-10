import Foundation

/// One capture's recognition settings, so where speech is turned into text can be read as a value.
struct SparkVoiceRecognitionMode: Equatable, Sendable {
    let requiresOnDeviceRecognition: Bool
    /// False when nothing here can transcribe without sending audio the owner has not allowed.
    let isPermitted: Bool
}

/// Where speech is turned into text: on this device, or on Apple's servers if the owner allows it.
enum SparkVoiceRecognitionPolicy {
    static let allowsAppleServersKey = "spark.voice.allowsAppleServers"

    /// Off until the owner turns it on, so the default build never sends what you say to Apple.
    static func allowsAppleServers(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: allowsAppleServersKey)
    }

    static func setAllowsAppleServers(_ value: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(value, forKey: allowsAppleServersKey)
    }

    /// How a request must be configured for this device and this choice.
    static func mode(
        supportsOnDevice: Bool,
        allowsAppleServers: Bool
    ) -> SparkVoiceRecognitionMode {
        guard allowsAppleServers else {
            return SparkVoiceRecognitionMode(
                requiresOnDeviceRecognition: true,
                isPermitted: supportsOnDevice
            )
        }
        return SparkVoiceRecognitionMode(
            requiresOnDeviceRecognition: supportsOnDevice,
            isPermitted: true
        )
    }
}
