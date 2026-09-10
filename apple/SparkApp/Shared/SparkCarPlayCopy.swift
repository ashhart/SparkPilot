import Foundation

/// Typed, stable keys for the two spoken readback sentences.
extension LocalizedStringResource {
    static func carPlaySessionOutput(text: String) -> Self {
        .init(
            "carplay.session.output",
            defaultValue: "Latest session output: \(text)",
            comment: "Introduces terminal output read aloud; this is not a completion report."
        )
    }
    static func carPlayUnavailableModel(status: String) -> Self {
        .init(
            "carplay.model.unavailable",
            defaultValue: "\(status). Current model status is unavailable.",
            comment: "A Spark connection summary followed by missing current model evidence."
        )
    }
}
