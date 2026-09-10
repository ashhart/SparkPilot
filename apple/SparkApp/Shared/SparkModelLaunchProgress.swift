import Foundation

public enum SparkChatModelLaunchState: Equatable {
    case idle, preparing, checking, awaitingApproval, loading

    public var message: String? {
        switch self {
        case .idle, .preparing: nil
        case .checking: String(localized: "Checking the selected model…")
        case .awaitingApproval: String(localized: "Review this launch before sending your message.")
        case .loading:
            String(
                localized:
                    "Model unloaded. Loading it now; your message will send when it is ready."
            )
        }
    }
}

/// What the Spark reports while a chat-triggered load runs, so the composer shows the dashboard's stage.
public struct SparkModelLaunchProgress: Equatable, Sendable {
    public let stage: String
    public let fraction: Double?
    public let detail: String?

    public init(stage: String, fraction: Double?, detail: String? = nil) {
        self.stage = stage
        self.fraction = fraction
        self.detail = detail
    }

    public var line: String {
        guard let fraction else { return stage }
        return String(
            localized: .stageWithPercent(stage: stage, percent: fraction.localisedPercent)
        )
    }
}

extension Double {
    /// A whole percentage that never reads 100 before the work is done.
    var percentFloor: Int { Int((min(1, max(0, self)) * 100).rounded(.down)) }

    /// The percentage as the reader's locale writes it, glyph and position included (§51.2).
    var localisedPercent: String {
        // Floor rather than round, so progress is never overstated (§62.3's no fake progress).
        (Double(percentFloor) / 100).formatted(.percent.precision(.fractionLength(0)))
    }
}
