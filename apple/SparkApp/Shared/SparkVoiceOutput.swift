import Foundation

/// Which voice reads a reply out: the Spark's Kokoro voice, this device's own, or none.
enum SparkVoiceOutput: Equatable, Sendable { case kokoro, device, silent }

/// Why the Spark's Kokoro voice is not the one speaking.
enum SparkVoiceAvailability: String, CaseIterable, Equatable, Sendable {
    case noSparkPaired
    case sparkUnreachable
    case kokoroMissing
    /// The owner chose on this device only, so no Spark may hear or answer a spoken turn.
    case onDeviceOnlyPolicy
}

/// Says which of the three it is, so a paired Spark is never told to pair a Spark.
enum SparkVoiceAvailabilityCopy {
    static func message(for reason: SparkVoiceAvailability) -> String {
        switch reason {
        case .noSparkPaired:
            String(localized: "Pair a Spark to install and use Kokoro voice.")
        case .sparkUnreachable:
            String(
                localized:
                    "Your paired Spark is not answering, so its Kokoro voice cannot be used yet."
            )
        case .onDeviceOnlyPolicy:
            String(
                localized:
                    "Your execution policy is on this device only, so voice cannot use a Spark. Change it in Settings to talk to a Spark."
            )
        case .kokoroMissing:
            String(
                localized: "Kokoro voice is not installed on this Spark, so it cannot speak yet."
            )
        }
    }

    /// What happens instead, said before the reply starts rather than after silence.
    static let deviceFallback = String(
        localized: "This device's own voice will read the reply until then."
    )

    /// Names whose voice it is when the name beside it belongs to the system, not to Kokoro.
    static let deviceVoiceTitle = String(localized: "This device's voice")
}

/// The voice used for replies; independent of permission to send microphone audio to Apple.
enum SparkVoiceOutputPreference: String, CaseIterable, Identifiable {
    case spark, device
    static let key = "spark.voice.output"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .spark: String(localized: "Kokoro on Spark")
        case .device: String(localized: "Apple voice on this device")
        }
    }
    static func saved(in defaults: UserDefaults = .standard) -> Self {
        Self(rawValue: defaults.string(forKey: key) ?? "") ?? .spark
    }

    /// Whether the owner has ever been asked which voice reads replies; the first read-aloud asks once.
    static let chosenKey = "spark.voice.output.chosen"
    static func hasChosen(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: chosenKey)
    }

    static func choose(_ preference: Self, in defaults: UserDefaults = .standard) {
        defaults.set(preference.rawValue, forKey: key)
        defaults.set(true, forKey: chosenKey)
    }
}
