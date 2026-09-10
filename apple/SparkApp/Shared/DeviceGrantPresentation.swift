import Foundation
import SparkAPI

/// Provides text for every trust, role and platform state so device grants remain understandable without colour.
enum DeviceGrantPresentation {
    /// Whether this device may still reach the Spark.
    static func trustLabel(revoked: Bool) -> String {
        revoked ? String(localized: "Revoked") : String(localized: "Trusted")
    }

    /// Keep Apple's product names verbatim.
    static func platformLabel(_ platform: GeneratedAPI.DevicePlatform) -> String {
        switch platform {
        case .ios: "iPhone"
        case .ipados: "iPad"
        case .macos: "Mac"
        }
    }

    static func roleLabel(_ role: GeneratedAPI.Role) -> String {
        switch role {
        case .owner: String(localized: "Owner")
        case .administrator: String(localized: "Administrator")
        case .developer: String(localized: "Developer")
        case .user: String(localized: "User")
        case .observer: String(localized: "Observer")
        case .guest: String(localized: "Guest")
        }
    }

    /// Formats supported RFC 3339 timestamps and marks unparseable values unknown instead of displaying wire text.
    static func timestampLabel(_ timestamp: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: timestamp)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: timestamp)
        }
        guard let date else { return String(localized: "Not reported") }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}
