import Foundation
import SparkAPI

/// PLAN 41.9 fixes the wording for a memory stop and the three things the owner may do next.
struct SparkMemoryStopPresentation: Equatable, Sendable {
    /// Only what this decision needs, so the resolver is testable without a decoded catalogue.
    struct Profile: Equatable, Sendable {
        let id: String
        let contextLength: Int
        let isSafe: Bool
    }

    let title: String
    let message: String
    /// The profile "Restart at 32K" would load; absent when nothing smaller is installed.
    let restartProfileID: String?
    let restartTitle: String?

    /// The runtime refuses a load it cannot fit; the guard reports pressure it will not load into.
    static let codes = ["MODEL_INSUFFICIENT_MEMORY", "MEMORY_PRESSURE_ACTIVE"]

    static func resolve(errorCode: String?, profiles: [Profile]) -> SparkMemoryStopPresentation? {
        guard let errorCode, codes.contains(errorCode) else { return nil }
        guard let stopped = stoppedProfile(profiles) else { return nil }
        let smaller =
            profiles
            .filter { $0.isSafe && $0.contextLength < stopped.contextLength }
            .max { $0.contextLength < $1.contextLength }
        let selected = contextLabel(stopped.contextLength)
        guard let smaller else {
            return SparkMemoryStopPresentation(
                title: String(localized: "Spark stopped the model to protect the system."),
                message: String(localized: .memoryStopNoSmallerContext(selected)),
                restartProfileID: nil,
                restartTitle: nil
            )
        }
        let alternative = contextLabel(smaller.contextLength)
        return SparkMemoryStopPresentation(
            title: String(localized: "Spark stopped the model to protect the system."),
            message: String(
                localized: .memoryStopWithSmallerContext(selected: selected, smaller: alternative)
            ),
            restartProfileID: smaller.id,
            restartTitle: String(localized: .restartAtContext(alternative))
        )
    }

    /// The profile the Spark marked unsafe after the event, or the largest one it was offered.
    private static func stoppedProfile(_ profiles: [Profile]) -> Profile? {
        let unsafe = profiles.filter { !$0.isSafe }
        let candidates = unsafe.isEmpty ? profiles : unsafe
        return candidates.max { $0.contextLength < $1.contextLength }
    }

    /// Context windows are quoted in the owner's shorthand when they are whole thousands.
    static func contextLabel(_ tokens: Int) -> String {
        guard tokens >= 1_024, tokens % 1_024 == 0 else { return tokens.formatted() }
        return String(localized: .contextShorthand((tokens / 1_024).formatted()))
    }

    static func profiles(_ profiles: [SparkModelProfile]) -> [Profile] {
        profiles.map {
            Profile(id: $0.id, contextLength: $0.maxModelLength, isSafe: $0.safe)
        }
    }
}
