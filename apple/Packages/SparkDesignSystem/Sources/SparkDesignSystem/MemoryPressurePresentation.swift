import Foundation

/// Map server-internal draining and recovery onto the public critical pressure state until verification completes.
public enum MemoryPressureLevel: String, Sendable, Equatable, CaseIterable {
    case normal
    case warning
    case critical
    case emergency
}

/// Offer smaller profiles or manual diagnostics without automatic retry (§33.5).
public enum MemoryRecoveryAction: Equatable, Sendable {
    case wait
    case chooseSmallerModel
    case getDiagnostics

    /// Phrase recovery guidance as complete advice rather than labels for unwired controls.
    public var guidance: String {
        switch self {
        case .wait:
            return String(localized: "Wait for memory to free up before loading another model.")
        case .chooseSmallerModel:
            return String(
                localized: "Try a smaller profile, or a smaller model, from your library."
            )
        case .getDiagnostics:
            return String(localized: "Check this Spark's memory readings to see what filled it.")
        }
    }
}

/// Resolved presentation for one pressure level (UX state matrix §62).
public struct MemoryPressurePresentation: Equatable, Sendable {
    public let title: String
    public let message: String
    public let actions: [MemoryRecoveryAction]

    public init(title: String, message: String, actions: [MemoryRecoveryAction]) {
        self.title = title
        self.message = message
        self.actions = actions
    }
}

/// Translate pressure states into concrete recovery guidance without runtime jargon.
public enum MemoryPressurePresentationResolver {
    /// `nil` for normal pressure: no banner when there is nothing to do.
    public static func resolve(_ level: MemoryPressureLevel) -> MemoryPressurePresentation? {
        switch level {
        case .normal:
            return nil
        case .warning:
            return MemoryPressurePresentation(
                title: String(localized: "Memory Is Filling Up"),
                message: String(localized: "Spark paused new model loads until memory frees up."),
                actions: [.wait]
            )
        case .critical:
            return MemoryPressurePresentation(
                title: String(localized: "Freeing Memory"),
                message: String(
                    localized: "Spark is stopping the current model to keep the system stable."
                ),
                actions: [.chooseSmallerModel, .getDiagnostics]
            )
        case .emergency:
            return MemoryPressurePresentation(
                title: String(localized: "A Model Was Stopped"),
                message:
                    String(
                        localized:
                            "Spark stopped the model to protect your system. It will not restart on its own."
                    ),
                actions: [.chooseSmallerModel, .getDiagnostics]
            )
        }
    }
}
