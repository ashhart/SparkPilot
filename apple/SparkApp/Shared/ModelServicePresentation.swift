import Foundation

/// Provides distinct text for every model-service state so row colours are not required to understand status.
enum ModelServicePresentation {
    /// Whether the readings on screen came from the Spark just now.
    static func freshnessLabel(_ freshness: ModelLibraryEvidenceFreshness) -> String {
        switch freshness {
        case .current: String(localized: "Live")
        case .stale: String(localized: "Saved")
        case .unavailable: String(localized: "Unavailable")
        }
    }

    static func stateLabel(_ state: ModelServiceRunState) -> String {
        switch state {
        case .running: String(localized: "Running")
        case .installed: String(localized: "Installed")
        case .readyToInstall: String(localized: "Available")
        case .needsAttention: String(localized: "Needs attention")
        case .unavailable: String(localized: "Unavailable")
        case .unknown: String(localized: "Unknown")
        }
    }

    /// Distinguishes a runtime's unavailable capability from an unknown state it has not reported.
    static func stateDetail(_ state: ModelServiceRunState) -> String {
        switch state {
        case .running: String(localized: "Service is running now.")
        case .installed: String(localized: "Installed but not currently serving.")
        case .readyToInstall:
            String(localized: "Downloads when you install and start a compatible model.")
        case .needsAttention:
            String(localized: "Open this Spark to inspect and recover the service.")
        case .unavailable: String(localized: "This runtime cannot provide this service.")
        case .unknown: String(localized: "The Spark did not return enough evidence.")
        }
    }

    static func ownershipLabel(_ ownership: ModelServiceOwnership) -> String? {
        switch ownership {
        case .sparkPilot: String(localized: "Managed by SparkPilot")
        case .external: String(localized: "Existing installation, left unchanged")
        case .unknown: nil
        }
    }

    static func updateHeadline(_ totalKnownUpdates: Int?) -> String {
        guard let count = totalKnownUpdates else { return String(localized: "Check required") }
        return count == 0
            ? String(localized: "Up to date")
            : String(localized: .updatesAvailable(count))
    }

    static func updateCount(_ count: Int?) -> String {
        guard let count else { return String(localized: "Unknown") }
        return count == 0
            ? String(localized: "Current")
            : String(localized: .updatesAvailable(count))
    }

    /// Formats supported RFC 3339 update timestamps in the reader's locale and marks unparseable values unknown.
    static func checkedAtLabel(_ checkedAt: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: checkedAt) else {
            return String(localized: "Not reported")
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Joins optional clauses through display.joined so translators control their separator and order.
    static func joined(_ first: String?, _ second: String?) -> String {
        switch (first, second) {
        case (.some(let first), .some(let second)):
            String(localized: .joined(first, second))
        case (.some(let only), nil), (nil, .some(let only)):
            only
        case (nil, nil):
            ""
        }
    }
}
