import Foundation

/// One line for the Kokoro install screens from the Spark's operation stage and fraction.
enum SparkVoiceInstallPresentation {
    /// Use readable voice-install stages and humanise unknown tokens.
    static func stageLabel(_ stage: String?) -> String? {
        guard let stage, !stage.isEmpty else { return nil }
        switch stage {
        case "pending": return String(localized: "Preparing")
        case "pulling_image":
            return String(localized: "Downloading the Kokoro voice service to your Spark")
        case "starting": return String(localized: "Starting the voice service")
        case "stopping": return String(localized: "Stopping the voice service")
        case "removing": return String(localized: "Removing the voice service")
        default:
            let words = stage.replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
            return words.prefix(1).uppercased() + words.dropFirst()
        }
    }

    /// What to expect at this stage, so a long download is not a dead spinner.
    static func hint(stage: String?) -> String? {
        switch stage {
        case "pending", "pulling_image":
            return String(
                localized:
                    "About 3 GB on first install, with the voices included; this usually takes a few minutes and the Spark reports no percentage for it. You can close this screen; the install continues on the Spark."
            )
        case "starting":
            return String(localized: "The voice service is loading its voices; under a minute.")
        default:
            return nil
        }
    }

    static func line(stage: String?, fraction: Double?) -> String? {
        let label = stageLabel(stage)
        guard let fraction else { return label }
        guard let label else {
            return String(localized: .percentComplete(fraction.localisedPercent))
        }
        return String(
            localized: .stageWithPercent(stage: label, percent: fraction.localisedPercent)
        )
    }
}
